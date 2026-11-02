-- Xendit at the POS counter for walk-in sales - per "my goal for now is to implement xendit on my local pos..
-- this is for my new transaction walkin orders".
--
-- A walk-in has no order yet while the customer pays (the WI- order is only made when the sale completes),
-- so a POS payment isn't tied to an order the way a pay.html payment is:
--   1. Cashier picks the XENDIT tender. The POS calls the Edge Function xendit-pos-payment, which makes a
--      QR Ph payment request for that amount (_xendit_pos_prepare) and the POS shows it as a QR code.
--   2. The customer scans it in GCash, Maya or their bank app. The POS polls until Xendit says Paid, then adds
--      the tender and completes the sale as usual, so the WI- order carries it as payment method XENDIT.
--      The payment request ID is kept in "InvoiceID" and recorded through _xendit_record_invoice_status, like
--      every other Xendit payment. QR Ph limit: 1.00 to 50,000.00 per payment.
--   3. The POS saves its receipt no. on the payment (_xendit_pos_link), which ties it to the WI- order on the
--      Xendit Payments page. A Paid row with no receipt = paid but the sale wasn't finished - staff follow up.
--
-- A POS row goes in with ApplyStatus 'Applied' ("POS walk-in") from the start: the sale itself records the
-- money, so _apply_xendit_payment must never touch it (it returns straight away for 'Applied'), and the
-- "payment received" Messenger message skips it (no AutomatedOrderNo).
--
-- SWITCH: XenditSettings."PosEnabled" (default OFF, on the Xendit Payments page), separate from the customer
-- switch "Enabled". The POS adds the XENDIT tender itself when it opens, so every POS on this build shows the
-- button; while this switch is off, pressing it only shows a "switched off" message.
--
-- Also blocks pay.html for WI- orders: they have no Automated Order record, so a payment taken there could
-- not be added to the order (ApplyStatus 'Failed' with the money already taken).
--
-- Run AFTER supabase_xendit_payments.sql, supabase_xendit_expire_old_invoices.sql,
-- supabase_xendit_payment_receipt_message.sql, supabase_xendit_payment_receipt_page.sql,
-- supabase_xendit_receipt_numbers.sql and supabase_pos_walkin_orders_direct.sql. Safe to re-run.
-- Needs the Edge Function xendit-pos-payment, js/xenditPayments.js ?v=xendit7 and the POS build with XenditPayForm.

alter table public."XenditSettings" add column if not exists "PosEnabled" boolean not null default false;

alter table public."XenditPayments" add column if not exists "Source" text not null default 'Online';  -- Online / POS
alter table public."XenditPayments" add column if not exists "PosWarehouseId" text;
alter table public."XenditPayments" add column if not exists "PosReceiptNo" text;
alter table public."XenditPayments" add column if not exists "PosCashier" text;
alter table public."XenditPayments" add column if not exists "PosTerminal" text;

create index if not exists "IX_XenditPayments_PosReceipt" on public."XenditPayments" ("PosWarehouseId", "PosReceiptNo") where "PosReceiptNo" is not null;

-- ---------------------------------------------------------------------------
-- 1. Edge Function only (it checks the POS key first): start a counter payment.

create or replace function public._xendit_pos_prepare(p_amount numeric, p_warehouse_id text, p_cashier text, p_terminal text, p_is_test boolean)
returns table(payment_id uuid, external_id text, order_ref text, amount numeric, branch text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_warehouse text;
  v_branch text;
  v_short text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  if not coalesce((select s."PosEnabled" from public."XenditSettings" s where s."Id" = 1), false) then
    raise exception 'Xendit at the POS is switched off. Turn it on in the portal: Xendit Payments > Settings.';
  end if;
  if v_amount < 1 or v_amount > 50000 then
    raise exception 'A QR Ph payment must be between 1.00 and 50,000.00.';
  end if;

  select w."ID", w."Name" into v_warehouse, v_branch
    from public."Warehouses" w where w."ID" = nullif(trim(coalesce(p_warehouse_id, '')), '');

  return query
    insert into public."XenditPayments" as x (
      "ExternalID", "OrderRef", "Purpose", "Amount", "IsTest", "Source",
      "ApplyStatus", "AppliedIn", "AppliedAmount",
      "PosWarehouseId", "PosCashier", "PosTerminal"
    ) values (
      'RSPS-POS-' || v_short, 'POS-' || upper(v_short), 'Walk-in payment', v_amount, coalesce(p_is_test, true), 'POS',
      'Applied', 'POS walk-in', v_amount,
      v_warehouse, left(nullif(trim(coalesce(p_cashier, '')), ''), 100), left(nullif(trim(coalesce(p_terminal, '')), ''), 100)
    )
    returning x."PaymentID", x."ExternalID", x."OrderRef", x."Amount", v_branch::text;
end;
$$;

revoke all on function public._xendit_pos_prepare(numeric, text, text, text, boolean) from public, anon, authenticated;
grant execute on function public._xendit_pos_prepare(numeric, text, text, text, boolean) to service_role;

-- A POS payment's current row (never returns an online payment, so the POS key can't read those).
drop function if exists public._xendit_pos_get_payment(uuid);

create or replace function public._xendit_pos_get_payment(p_payment_id uuid)
returns table(payment_id uuid, invoice_id text, status text, amount numeric, paid_amount numeric, payment_channel text, payment_method text, expires_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select x."PaymentID", x."InvoiceID", x."Status", x."Amount", x."PaidAmount", x."PaymentChannel", x."PaymentMethod", x."ExpiresAtUtc"
    from public."XenditPayments" x
   where x."PaymentID" = p_payment_id and x."Source" = 'POS';
$$;

revoke all on function public._xendit_pos_get_payment(uuid) from public, anon, authenticated;
grant execute on function public._xendit_pos_get_payment(uuid) to service_role;

-- The sale's receipt no. - this is what ties the payment to its WI- order.
create or replace function public._xendit_pos_link(p_payment_id uuid, p_receipt_no text)
returns void
language sql
security definer
set search_path = public
as $$
  update public."XenditPayments"
     set "PosReceiptNo" = left(nullif(trim(coalesce(p_receipt_no, '')), ''), 50)
   where "PaymentID" = p_payment_id and "Source" = 'POS';
$$;

revoke all on function public._xendit_pos_link(uuid, text) from public, anon, authenticated;
grant execute on function public._xendit_pos_link(uuid, text) to service_role;

-- ---------------------------------------------------------------------------
-- 2. pay.html: same as supabase_xendit_payments.sql, except a POS walk-in (WI-) counts as "not payable online".

create or replace function public._xendit_resolve_order(p_ref text)
returns table(order_ref text, automated_order_no text, online_order_id text, order_status text,
              is_cancelled boolean, is_portal boolean, total numeric, amount_paid numeric, balance numeric,
              customer_name text, customer_phone text, customer_email text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_ref text := upper(trim(coalesce(p_ref, '')));
  v_ao public."AutomatedOrders"%rowtype;
  v_has_ao boolean := false;
  v_oo public."OnlineOrders"%rowtype;
  v_has_oo boolean := false;
  v_paid numeric;
  v_total numeric;
  v_status text;
  -- Paid at Xendit but not on the order yet (failed / still applying) - counted as paid so the
  -- customer is never asked to pay it again.
  v_unapplied numeric;
begin
  if v_ref = '' then
    return;
  end if;

  select * into v_ao from public."AutomatedOrders" where upper("OrderNo") = v_ref;
  v_has_ao := found;
  if v_has_ao then
    select * into v_oo from public."OnlineOrders"
     where "OrderID" = coalesce(nullif(trim(v_ao."PancakeReceiptNo"), ''), v_ao."OrderNo");
    v_has_oo := found;
  else
    select * into v_oo from public."OnlineOrders" where "OrderID" = trim(p_ref);
    v_has_oo := found;
    if not v_has_oo then
      return;
    end if;
    select * into v_ao from public."AutomatedOrders" where "PancakeReceiptNo" = v_oo."OrderID" limit 1;
    v_has_ao := found;
  end if;

  select coalesce(sum(coalesce(x."PaidAmount", x."Amount")), 0) into v_unapplied
    from public."XenditPayments" x
   where x."Status" = 'Paid' and x."ApplyStatus" in ('Pending', 'Failed')
     and (x."AutomatedOrderNo" = v_ao."OrderNo" or x."OnlineOrderID" = v_oo."OrderID");

  if v_has_oo then
    v_paid := coalesce(v_oo."AmountPaid", 0);
    v_total := coalesce(v_oo."AmountPaid", 0) + coalesce(v_oo."Balance", 0);
    v_status := v_oo."Status";
  else
    v_paid := coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = v_ao."OrderNo"), 0);
    v_total := coalesce(public._automated_order_total(v_ao."OrderNo"), 0);
    v_status := v_ao."Status";
  end if;
  v_paid := v_paid + v_unapplied;

  return query select
    case when v_has_ao then v_ao."OrderNo" else v_oo."OrderID" end::text,
    case when v_has_ao then v_ao."OrderNo" end::text,
    case when v_has_oo then v_oo."OrderID" end::text,
    v_status::text,
    lower(trim(coalesce(v_status, ''))) in ('canceled', 'cancelled', 'cancel', 'returned', 'returning'),
    case when v_has_oo then public._is_portal_only_online_order(v_oo."OrderID") and v_oo."PosReceiptNo" is null else true end,
    round(v_total, 2),
    round(v_paid, 2),
    round(greatest(v_total - v_paid, 0), 2),
    coalesce(nullif(trim(v_ao."CustomerName"), ''), v_oo."CustomerName")::text,
    coalesce(nullif(trim(v_ao."CustomerPhone"), ''), v_oo."ShippingPhone")::text,
    nullif(trim(coalesce(v_ao."CustomerEmail", '')), '')::text;
end;
$$;

revoke all on function public._xendit_resolve_order(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Xendit Payments page: the POS switch, and POS rows with their receipt / WI- order.

drop function if exists public.admin_get_xendit_settings(text, text);

create or replace function public.admin_get_xendit_settings(p_admin_username text, p_admin_password text)
returns table(enabled boolean, show_on_order_now boolean, updated_by text, updated_at timestamptz, pos_enabled boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return query
    select s."Enabled", s."ShowOnOrderNow", s."UpdatedBy", s."UpdatedAtUtc", s."PosEnabled"
      from public."XenditSettings" s where s."Id" = 1;
end;
$$;

grant execute on function public.admin_get_xendit_settings(text, text) to anon;

create or replace function public.admin_set_xendit_pos_enabled(p_admin_username text, p_admin_password text, p_pos_enabled boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  update public."XenditSettings"
     set "PosEnabled" = coalesce(p_pos_enabled, false),
         "UpdatedBy" = p_admin_username,
         "UpdatedAtUtc" = now()
   where "Id" = 1;
end;
$$;

grant execute on function public.admin_set_xendit_pos_enabled(text, text, boolean) to anon;

drop function if exists public.admin_list_xendit_payments(text, text, text, int);

create or replace function public.admin_list_xendit_payments(p_admin_username text, p_admin_password text,
                                                            p_search text default null, p_limit int default 200)
returns table(payment_id uuid, created_at timestamptz, order_ref text, online_order_id text, purpose text,
              amount numeric, is_test boolean, status text, invoice_url text, expires_at timestamptz,
              create_error text, paid_amount numeric, payment_method text, payment_channel text, paid_at timestamptz,
              apply_status text, apply_error text, applied_in text, applied_amount numeric, external_id text,
              receipt_message_status text, receipt_no text,
              source text, pos_receipt_no text, pos_cashier text, walkin_order_id text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return query
    select x."PaymentID", x."CreatedAtUtc", x."OrderRef", x."OnlineOrderID", x."Purpose", x."Amount", x."IsTest",
           x."Status", x."InvoiceUrl", x."ExpiresAtUtc", x."CreateError", x."PaidAmount", x."PaymentMethod",
           x."PaymentChannel", x."PaidAtUtc", x."ApplyStatus", x."ApplyError", x."AppliedIn", x."AppliedAmount", x."ExternalID",
           x."ReceiptMessageStatus", x."ReceiptNo",
           x."Source", x."PosReceiptNo", x."PosCashier", w."OrderID"::text
      from public."XenditPayments" x
      left join public."OnlineOrders" w
        on x."PosReceiptNo" is not null and w."PosReceiptNo" = x."PosReceiptNo" and w."PosWarehouseId" = x."PosWarehouseId"
     where v_search is null
        or x."OrderRef" ilike '%' || v_search || '%'
        or x."OnlineOrderID" ilike '%' || v_search || '%'
        or x."ExternalID" ilike '%' || v_search || '%'
        or x."ReceiptNo" ilike '%' || v_search || '%'
        or x."PosReceiptNo" ilike '%' || v_search || '%'
        or w."OrderID" ilike '%' || v_search || '%'
     order by x."CreatedAtUtc" desc
     limit greatest(coalesce(p_limit, 200), 1);
end;
$$;

grant execute on function public.admin_list_xendit_payments(text, text, text, int) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'setting' as section, 'POS switch' as item, case when s."PosEnabled" then 'ON' else 'OFF' end as value
  from public."XenditSettings" s where s."Id" = 1
union all
select 'column', c.column_name::text, c.data_type::text
  from information_schema.columns c
 where c.table_schema = 'public' and c.table_name = 'XenditPayments'
   and c.column_name in ('Source', 'PosWarehouseId', 'PosReceiptNo', 'PosCashier', 'PosTerminal')
union all
select 'function', p.proname::text,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon'
            when has_function_privilege('service_role', p.oid, 'EXECUTE') then 'service_role only'
            else 'internal' end
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('_xendit_pos_prepare', '_xendit_pos_get_payment', '_xendit_pos_link', 'admin_set_xendit_pos_enabled');
