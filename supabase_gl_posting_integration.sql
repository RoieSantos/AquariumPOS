-- Wires the existing document flows into the General Ledger, and links Purchase Orders to Vendor
-- Bills - per "yes i want you to build this [PO -> Vendor Bill link]" and "General ledger entries
-- this will see all my purchase / expense".
--
-- RUN supabase_general_ledger.sql FIRST - this file calls _gl_post/_gl_reverse and references
-- GLSetup, all of which that file creates.
--
-- Rewrites four existing functions from supabase_vendor_tables.sql and
-- supabase_item_cost_and_po_line_cost.sql so that documents post to the ledger as a side effect of
-- being created. Each keeps its original signature and behaviour; the G/L posting is added, and in
-- one case (posting a PO) a new blocking rule is introduced. They stay the single entry point for
-- their document, so nothing can create a bill or payment that bypasses the books.
--
-- The columns these ledger entries hang off are added here rather than in the G/L file because
-- they belong to the existing document tables:
--   VendorBills."PONo"          - the PO -> Bill link that did not exist before.
--   VendorBills."AccountNo"     - what the bill was for (Inventory for a PO bill, otherwise the
--                                 configured default expense account).
--   Vendor{Bills,Payments}."GLTransactionNo" - the transaction each document posted, so a void can
--                                 reverse precisely that transaction rather than reconstructing it.

alter table public."VendorBills" add column if not exists "PONo" varchar(50);
alter table public."VendorBills" add column if not exists "AccountNo" varchar(20);
alter table public."VendorBills" add column if not exists "GLTransactionNo" bigint;
alter table public."VendorPayments" add column if not exists "GLTransactionNo" bigint;

create index if not exists "IX_VendorBills_PONo" on public."VendorBills" ("PONo");

-- ============================================================================
-- Vendor Bill -> G/L
-- ============================================================================

-- The bill-raising work, WITHOUT an authorization check, so it can be shared by two callers whose
-- gates differ: admin_create_vendor_bill (super users, from Vendor Setup) and
-- staff_post_purchase_order (any staff, when a posted PO auto-raises its bill). Calling the admin
-- wrapper from the staff path would reject a normal staff member mid-posting.
--
-- Underscore-prefixed and never granted to anon, matching _next_no_series_number and the _gl_*
-- helpers - it is reachable only from other security-definer functions that have already
-- authorized their caller.
--
-- Posts: Dr <bill account>, Cr Accounts Payable.
create or replace function public._create_vendor_bill(
  p_vendor_code text,
  p_bill_date date,
  p_due_date date,
  p_reference_no text,
  p_amount numeric,
  p_notes text,
  p_account_no text,
  p_po_no text,
  p_created_by text
)
returns table(success boolean, message text, bill_no text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bill_no text;
  v_account_no text;
  v_payable_account text;
  v_transaction_no bigint;
begin
  if not exists (select 1 from public."Vendors" where "VendorCode" = p_vendor_code) then
    return query select false, 'That vendor no longer exists.'::text, null::text; return;
  end if;

  if p_bill_date is null then
    return query select false, 'Bill Date is required.'::text, null::text; return;
  end if;

  if coalesce(p_amount, 0) <= 0 then
    return query select false, 'Amount must be greater than zero.'::text, null::text; return;
  end if;

  select coalesce(nullif(trim(coalesce(p_account_no, '')), ''), s."DefaultExpenseAccountNo"), s."PayableAccountNo"
    into v_account_no, v_payable_account
  from public."GLSetup" s limit 1;

  if v_account_no is null or v_payable_account is null then
    return query select false, 'G/L Setup is incomplete - an Accounts Payable and a default expense account are required before bills can be raised.'::text, null::text; return;
  end if;

  v_bill_no := public._next_no_series_number('VENDOR-BILL', '');

  insert into public."VendorBills" ("BillNo", "VendorCode", "BillDate", "DueDate", "ReferenceNo", "Amount", "Notes", "CreatedBy", "AccountNo", "PONo")
  values (v_bill_no, p_vendor_code, p_bill_date, p_due_date, nullif(trim(p_reference_no), ''), p_amount, nullif(trim(p_notes), ''), p_created_by, v_account_no, nullif(trim(coalesce(p_po_no, '')), ''));

  v_transaction_no := public._gl_post(
    p_bill_date,
    'Vendor Bill',
    v_bill_no,
    'Bill ' || v_bill_no || ' - ' || p_vendor_code,
    'Vendor',
    p_vendor_code,
    jsonb_build_array(
      jsonb_build_object('account_no', v_account_no, 'amount', p_amount),
      jsonb_build_object('account_no', v_payable_account, 'amount', -p_amount)
    ),
    p_created_by
  );

  update public."VendorBills" set "GLTransactionNo" = v_transaction_no where "BillNo" = v_bill_no;

  return query select true, 'Bill added.'::text, v_bill_no;
end;
$$;

-- Vendor Setup's entry point: authorize, then do the work above. Gains p_account_no and p_po_no,
-- both optional, so the existing screen keeps working unchanged - it simply gets the default
-- expense account. Signature changes, so the old one is dropped first.
drop function if exists public.admin_create_vendor_bill(text, text, text, date, date, text, numeric, text);

create or replace function public.admin_create_vendor_bill(
  p_admin_username text,
  p_admin_password text,
  p_vendor_code text,
  p_bill_date date,
  p_due_date date default null,
  p_reference_no text default null,
  p_amount numeric default null,
  p_notes text default null,
  p_account_no text default null,
  p_po_no text default null
)
returns table(success boolean, message text, bill_no text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text, null::text; return;
  end if;

  return query select * from public._create_vendor_bill(
    p_vendor_code, p_bill_date, p_due_date, p_reference_no, p_amount, p_notes,
    p_account_no, p_po_no, p_admin_username
  );
end;
$$;

grant execute on function public.admin_create_vendor_bill(text, text, text, date, date, text, numeric, text, text, text) to anon;

-- Voiding posts a REVERSING transaction rather than deleting the original entries - the ledger is
-- append-only, so the history shows both the bill and its cancellation.
create or replace function public.admin_void_vendor_bill(
  p_admin_username text,
  p_admin_password text,
  p_bill_no text
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bill record;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text; return;
  end if;

  select * into v_bill from public."VendorBills" where "BillNo" = p_bill_no;

  if not found then
    return query select false, 'That bill no longer exists.'::text; return;
  end if;

  if v_bill."IsVoid" then
    return query select false, 'That bill is already void.'::text; return;
  end if;

  if exists (select 1 from public."VendorPayments" where "BillNo" = p_bill_no and not "IsVoid") then
    return query select false, 'This bill still has payments applied to it - void those payments first.'::text; return;
  end if;

  update public."VendorBills" set "IsVoid" = true where "BillNo" = p_bill_no;

  -- Bills raised before the G/L existed have no transaction to reverse; voiding those still works,
  -- it just has no ledger effect.
  if v_bill."GLTransactionNo" is not null then
    perform public._gl_reverse(
      v_bill."GLTransactionNo",
      (now() at time zone 'Asia/Manila')::date,
      'Void of bill ' || p_bill_no,
      p_admin_username
    );
  end if;

  return query select true, 'Bill voided.'::text;
end;
$$;

-- ============================================================================
-- Vendor Payment -> G/L
-- ============================================================================

-- Posts: Dr Accounts Payable, Cr Cash or Digital depending on the payment Method.
create or replace function public.admin_create_vendor_payment(
  p_admin_username text,
  p_admin_password text,
  p_vendor_code text,
  p_bill_no text default null,
  p_payment_date date default null,
  p_amount numeric default null,
  p_method text default null,
  p_reference_no text default null,
  p_notes text default null
)
returns table(success boolean, message text, payment_no text)
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
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text, null::text; return;
  end if;

  if not exists (select 1 from public."Vendors" where "VendorCode" = p_vendor_code) then
    return query select false, 'That vendor no longer exists.'::text, null::text; return;
  end if;

  if p_bill_no is not null and trim(p_bill_no) <> '' then
    if not exists (select 1 from public."VendorBills" where "BillNo" = p_bill_no and "VendorCode" = p_vendor_code and not "IsVoid") then
      return query select false, 'That bill does not belong to this vendor, or is void.'::text, null::text; return;
    end if;
  end if;

  if p_payment_date is null then
    return query select false, 'Payment Date is required.'::text, null::text; return;
  end if;

  if coalesce(p_amount, 0) <= 0 then
    return query select false, 'Amount must be greater than zero.'::text, null::text; return;
  end if;

  select s."PayableAccountNo", s."CashAccountNo", s."DigitalAccountNo"
    into v_payable_account, v_cash_account, v_digital_account
  from public."GLSetup" s limit 1;

  -- Method is free text on the existing screen, so anything that is not recognisably digital is
  -- treated as cash - the safer default for a shop, and visible in the ledger either way.
  v_credit_account := case
    when lower(coalesce(p_method, '')) similar to '%(gcash|bank|transfer|digital|online|maya|card)%' then v_digital_account
    else v_cash_account
  end;

  if v_payable_account is null or v_credit_account is null then
    return query select false, 'G/L Setup is incomplete - Accounts Payable and Cash/Digital accounts are required before payments can be recorded.'::text, null::text; return;
  end if;

  v_payment_no := public._next_no_series_number('VENDOR-PAYMENT', '');

  insert into public."VendorPayments" ("PaymentNo", "VendorCode", "BillNo", "PaymentDate", "Amount", "Method", "ReferenceNo", "Notes", "CreatedBy")
  values (v_payment_no, p_vendor_code, nullif(trim(p_bill_no), ''), p_payment_date, p_amount, nullif(trim(p_method), ''), nullif(trim(p_reference_no), ''), nullif(trim(p_notes), ''), p_admin_username);

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
    p_admin_username
  );

  update public."VendorPayments" set "GLTransactionNo" = v_transaction_no where "PaymentNo" = v_payment_no;

  return query select true, 'Payment recorded.'::text, v_payment_no;
end;
$$;

grant execute on function public.admin_create_vendor_payment(text, text, text, text, date, numeric, text, text, text) to anon;

create or replace function public.admin_void_vendor_payment(
  p_admin_username text,
  p_admin_password text,
  p_payment_no text
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_payment record;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text; return;
  end if;

  select * into v_payment from public."VendorPayments" where "PaymentNo" = p_payment_no;

  if not found then
    return query select false, 'That payment no longer exists.'::text; return;
  end if;

  if v_payment."IsVoid" then
    return query select false, 'That payment is already void.'::text; return;
  end if;

  update public."VendorPayments" set "IsVoid" = true where "PaymentNo" = p_payment_no;

  if v_payment."GLTransactionNo" is not null then
    perform public._gl_reverse(
      v_payment."GLTransactionNo",
      (now() at time zone 'Asia/Manila')::date,
      'Void of payment ' || p_payment_no,
      p_admin_username
    );
  end if;

  return query select true, 'Payment voided.'::text;
end;
$$;

-- ============================================================================
-- Purchase Order posting -> Vendor Bill -> G/L
-- ============================================================================

-- Replaces the version in supabase_item_cost_and_po_line_cost.sql. Everything it did is kept
-- (archive header and lines, last-cost writeback, delete the open PO) and two things are added:
--
--   1. A BLOCKING CHECK, per direct decision: posting is refused if any RECEIVED line has no unit
--      cost. Without it the auto-raised bill would understate what is genuinely owed, and an
--      understated payable is far harder to notice later than a refusal now. Lines that were
--      ordered but never received are exempt - they cost nothing and are not billed.
--
--   2. An automatic Vendor Bill for the received value, which in turn posts
--      Dr Inventory / Cr Accounts Payable through admin_create_vendor_bill above.
--
-- The bill is dated by the PO's OrderDate, matching admin_get_purchase_summary's OrderDate basis,
-- so the dashboard's Total Purchase card and the ledger can never disagree about which month a
-- purchase belongs to.
--
-- A PO where nothing at all was received raises no bill (there is nothing to owe) but still posts
-- and archives normally.
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
  v_uncosted_items text;
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

  select string_agg(distinct "ItemCode", ', ')
    into v_uncosted_items
  from public."PurchaseOrderLines"
  where "PONo" = p_po_no
    and coalesce("QtyReceived", 0) > 0
    and "UnitCost" is null;

  if v_uncosted_items is not null then
    raise exception 'Cannot post - these received items have no unit cost: %. Enter a cost on each line first, or the vendor bill would understate what is owed.', v_uncosted_items;
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
    -- expense account. Cost of Goods Sold is recognised when the item sells - which is the sales
    -- posting this build deliberately leaves for later.
    -- The internal helper, not admin_create_vendor_bill: posting a PO is is_staff_authorized, so
    -- routing through the super-user wrapper would fail for ordinary staff. The caller has
    -- already been authorized above.
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

    -- _create_vendor_bill reports failure in its result rather than raising, so it is checked
    -- explicitly - otherwise a G/L Setup problem would silently post the PO with no bill and no
    -- ledger entry, which is exactly the split the whole feature exists to prevent. Raising here
    -- rolls the entire posting back.
    if not v_bill.success then
      raise exception 'Purchase Order was not posted - could not raise the vendor bill: %', v_bill.message;
    end if;
  end if;
end;
$$;

grant execute on function public.staff_post_purchase_order(text, text, text) to anon;

-- Surfaces the PO -> Bill link on the posted PO, so a posted order can be traced to what is owed.
create or replace function public.staff_get_posted_purchase_order_bill(
  p_admin_username text,
  p_admin_password text,
  p_po_no text
)
returns table(bill_no text, bill_date date, amount numeric, is_void boolean, paid_amount numeric, balance numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select b."BillNo"::text, b."BillDate", b."Amount", b."IsVoid",
           coalesce((select sum(p."Amount") from public."VendorPayments" p where p."BillNo" = b."BillNo" and not p."IsVoid"), 0)::numeric,
           (b."Amount" - coalesce((select sum(p."Amount") from public."VendorPayments" p where p."BillNo" = b."BillNo" and not p."IsVoid"), 0))::numeric
    from public."VendorBills" b
    where b."PONo" = p_po_no
    order by b."BillDate", b."BillNo";
end;
$$;

grant execute on function public.staff_get_posted_purchase_order_bill(text, text, text) to anon;
