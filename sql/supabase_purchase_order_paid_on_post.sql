-- Purchase Order = paid when posted - per "is it possible that when I post the purchase order the
-- vendor will paid already? right now that is what our practice and operation is".
--
-- This business pays the vendor BEFORE receiving (supabase_purchase_order_payment_method.sql), and a
-- PO can't be posted without its Payment Method (Cash / Online). But posting only raised the vendor
-- bill (Dr Inventory, Cr Accounts Payable) - nothing recorded the payment, so every posted PO sat in
-- "Unpaid vendor bills" (Dashboard My View, Vendors) as if still owed.
--
--   1. _create_vendor_payment - the payment-recording work of admin_create_vendor_payment
--      (supabase_gl_posting_integration.sql) WITHOUT its super-user check, so staff posting a PO can
--      use it. Posts Dr Accounts Payable, Cr Cash (PO "Cash") or Digital / Bank (PO "Online").
--   2. staff_post_purchase_order - supabase_purchase_order_allow_zero_cost_post.sql's version (the
--      latest) plus: right after the auto-raised bill, a vendor payment for the full amount, dated
--      the bill date (the PO's Order Date), method = the PO's Payment Method. The bill is born paid.
--   3. Backfill - every existing non-void PO bill (VendorBills."PONo" set) that still has an open
--      balance and whose posted PO has a Payment Method gets a payment for that open balance, the
--      same way. Bills keyed in by hand on Vendors (no PO) are left alone - those stay real payables.
--
-- A wrongly-paid one can still be undone on Vendors (void the payment - its G/L posting is reversed).
-- Run AFTER supabase_purchase_order_allow_zero_cost_post.sql. Safe to re-run: the backfill only
-- touches bills that still have an open balance, so a second run pays nothing twice. The final
-- result lists the bills paid by this run (plus any skipped because their PO has no Payment Method).

-- ---------------------------------------------------------------------------
-- 1. Internal payment helper. Never granted - only callable from functions that authorized already.
create or replace function public._create_vendor_payment(
  p_vendor_code text,
  p_bill_no text,
  p_payment_date date,
  p_amount numeric,
  p_method text,
  p_reference_no text,
  p_notes text,
  p_created_by text
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_payment_no text;
  v_payable_account text;
  v_cash_account text;
  v_digital_account text;
  v_credit_account text;
  v_transaction_no bigint;
begin
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'Vendor payment amount must be greater than zero.';
  end if;

  select s."PayableAccountNo", s."CashAccountNo", s."DigitalAccountNo"
    into v_payable_account, v_cash_account, v_digital_account
  from public."GLSetup" s limit 1;

  -- Same rule as admin_create_vendor_payment: anything recognisably digital hits Digital / Bank.
  v_credit_account := case
    when lower(coalesce(p_method, '')) similar to '%(gcash|bank|transfer|digital|online|maya|card)%' then v_digital_account
    else v_cash_account
  end;

  if v_payable_account is null or v_credit_account is null then
    raise exception 'G/L Setup is incomplete - Accounts Payable and Cash/Digital accounts are required before payments can be recorded.';
  end if;

  v_payment_no := public._next_no_series_number('VENDOR-PAYMENT', '');

  insert into public."VendorPayments" ("PaymentNo", "VendorCode", "BillNo", "PaymentDate", "Amount", "Method", "ReferenceNo", "Notes", "CreatedBy")
  values (v_payment_no, p_vendor_code, nullif(trim(coalesce(p_bill_no, '')), ''), p_payment_date, p_amount,
          nullif(trim(coalesce(p_method, '')), ''), nullif(trim(coalesce(p_reference_no, '')), ''),
          nullif(trim(coalesce(p_notes, '')), ''), p_created_by);

  v_transaction_no := public._gl_post(
    p_payment_date,
    'Vendor Payment',
    v_payment_no,
    'Payment ' || v_payment_no || ' - ' || p_vendor_code,
    'Vendor',
    p_vendor_code,
    jsonb_build_array(
      jsonb_build_object('account_no', v_payable_account, 'amount', p_amount),
      jsonb_build_object('account_no', v_credit_account, 'amount', -p_amount)
    ),
    p_created_by
  );

  update public."VendorPayments" set "GLTransactionNo" = v_transaction_no where "PaymentNo" = v_payment_no;

  return v_payment_no;
end;
$$;

revoke execute on function public._create_vendor_payment(text, text, date, numeric, text, text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Posting a PO now also pays its bill.
drop function if exists public.staff_post_purchase_order(text, text, text);

create or replace function public.staff_post_purchase_order(
  p_admin_username text,
  p_admin_password text,
  p_po_no text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_header record;
  v_bill_total numeric;
  v_inventory_account text;
  v_bill record;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select * into v_header from public."PurchaseOrders" where "PONo" = p_po_no;

  if not found then
    raise exception 'Purchase Order "%" not found.', p_po_no;
  end if;

  if v_header."PaymentMethod" is null then
    raise exception 'Cannot post - set a Payment Method for this Purchase Order first.';
  end if;

  select coalesce(sum(round(coalesce("UnitCost", 0) * coalesce("QtyReceived", 0), 2)), 0)
    into v_bill_total
  from public."PurchaseOrderLines"
  where "PONo" = p_po_no;

  insert into public."PostedPurchaseOrders" ("PONo", "VendorCode", "OrderDate", "Notes", "CreatedBy", "CreatedAtUtc", "PostedBy")
  select "PONo", "VendorCode", "OrderDate", "Notes", "CreatedBy", "CreatedAtUtc", p_admin_username
  from public."PurchaseOrders"
  where "PONo" = p_po_no;

  insert into public."PostedPurchaseOrderLines" ("PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity", "QtyReceived", "Description", "UnitCost")
  select "PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity", "QtyReceived", "Description", "UnitCost"
  from public."PurchaseOrderLines"
  where "PONo" = p_po_no;

  update public."Items" i
     set "Cost" = latest."UnitCost"
    from (
      select distinct on ("ItemCode") "ItemCode", "UnitCost"
      from public."PurchaseOrderLines"
      where "PONo" = p_po_no
        and "UnitCost" is not null
        and coalesce("QtyReceived", 0) > 0
      order by "ItemCode", "EntryNo" desc
    ) as latest
   where i."Code" = latest."ItemCode";

  delete from public."PurchaseOrders" where "PONo" = p_po_no;

  if v_bill_total > 0 then
    select s."InventoryAccountNo" into v_inventory_account from public."GLSetup" s limit 1;

    -- Goods bought for resale are an asset until sold, so a purchase debits Inventory, not an
    -- expense account. The internal helper, not admin_create_vendor_bill: posting a PO is
    -- is_staff_authorized, so the super-user wrapper would fail for ordinary staff.
    select * into v_bill from public._create_vendor_bill(
      v_header."VendorCode",
      v_header."OrderDate",
      null,
      p_po_no,
      v_bill_total,
      'Auto-raised on posting Purchase Order ' || p_po_no,
      v_inventory_account,
      p_po_no,
      p_admin_username
    );

    -- _create_vendor_bill reports failure in its result rather than raising; raising here rolls the
    -- entire posting back so a PO never posts without its bill.
    if not v_bill.success then
      raise exception 'Purchase Order was not posted - could not raise the vendor bill: %', v_bill.message;
    end if;

    -- Pay first, then receive: by the time a PO posts it has been paid, so the bill is settled in
    -- the same transaction (Dr Accounts Payable, Cr Cash / Digital by the PO's Payment Method).
    perform public._create_vendor_payment(
      v_header."VendorCode",
      v_bill.bill_no,
      v_header."OrderDate",
      v_bill_total,
      v_header."PaymentMethod",
      p_po_no,
      'Paid on posting Purchase Order ' || p_po_no,
      p_admin_username
    );
  end if;
end;
$$;

grant execute on function public.staff_post_purchase_order(text, text, text) to anon;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 3. Backfill existing PO bills, then one result: what this run paid / skipped.
with open_po_bills as (
  select b."BillNo", b."VendorCode", b."BillDate", b."PONo", h."PaymentMethod",
         b."Amount" - coalesce((select sum(p."Amount") from public."VendorPayments" p
                                where p."BillNo" = b."BillNo" and not p."IsVoid"), 0) as open_amount
  from public."VendorBills" b
  left join public."PostedPurchaseOrders" h on h."PONo" = b."PONo"
  where not b."IsVoid"
    and nullif(trim(coalesce(b."PONo", '')), '') is not null
),
paid as (
  select o.*,
         public._create_vendor_payment(o."VendorCode", o."BillNo", o."BillDate", o.open_amount, o."PaymentMethod",
                                       o."PONo", 'Backfill - paid on posting Purchase Order ' || o."PONo", 'system') as payment_no
  from open_po_bills o
  where o.open_amount > 0 and o."PaymentMethod" is not null
)
select 'paid now' as result, "PONo"::text as po_no, "BillNo"::text as bill_no, "PaymentMethod"::text as method,
       open_amount as amount, payment_no::text
from paid
union all
select 'skipped - PO has no Payment Method', "PONo", "BillNo", null, open_amount, null
from open_po_bills
where open_amount > 0 and "PaymentMethod" is null
order by 1, 2;
