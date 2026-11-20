-- Advance Orders: a voided order's payment applied to a NEW order - per "they are voiding the transaction then
-- the payment now is floating. can we apply that payment into a new order?"
--
-- The POS (VoidOrderCredit.cs) now asks on Void Order: Refund, or Keep as credit for a new order. A kept credit
-- writes no refund - the money stays on the voided receipt until the cashier presses "Voided Order Credit" at
-- checkout of the new order, which moves it ("CREDIT TO <new>" on the voided receipt, "CREDIT FROM <old>" on the
-- new one, same tender) so the drawer / Dashboard tender split never change. An order voided the old way
-- (refund written, money never actually given back) can be used too, with a Super User.
--
-- Portal side, just the record: the three new header columns the POS syncs for voided orders, and the
-- Advance Orders tab's void read (badge / card) returns them.
--   VoidCredit        - kept as credit at the void (null = it was a refund)
--   VoidCreditUsed    - how much of this void's money went to new orders
--   VoidCreditUsedOn  - which receipts
--
-- Run AFTER supabase_advance_order_void.sql (re-run this one if that file is ever re-run). Run it BEFORE the POS build with "Keep as credit" goes out -
-- that build sends these columns for every voided order and the sync would fail without them.
-- Safe to re-run. Ends with ONE result: OK / FIX.

set lock_timeout = '10s';

alter table public."AdvanceOrders" add column if not exists "VoidCredit" numeric(18, 2);
alter table public."AdvanceOrders" add column if not exists "VoidCreditUsed" numeric(18, 2);
alter table public."AdvanceOrders" add column if not exists "VoidCreditUsedOn" varchar(200);

-- Same as supabase_advance_order_void.sql section 7 + the credit columns (return type changes -> drop first).
drop function if exists public.staff_get_advance_order_voids(text, text, text[]);

create or replace function public.staff_get_advance_order_voids(p_admin_username text, p_admin_password text, p_nos text[])
returns table(transaction_no text, voided_at timestamptz, voided_by text, void_reason text, void_refund numeric, errors text,
              void_credit numeric, void_credit_used numeric, void_credit_used_on text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_branch text;
begin
  if public.is_admin_authorized(p_admin_username, p_admin_password) then
    v_branch := null;
  elsif public.is_staff_authorized(p_admin_username, p_admin_password) and public._advance_order_is_viewer(p_admin_username) then
    v_branch := public._advance_order_viewer_branch(p_admin_username);
  else
    raise exception 'Not authorized.';
  end if;

  return query
    select a."TransactionNo"::text, a."VoidedAtUtc", a."VoidedBy"::text, a."VoidReason"::text, a."VoidRefund", v."Errors",
           a."VoidCredit", a."VoidCreditUsed", a."VoidCreditUsedOn"::text
    from public."AdvanceOrders" a
    left join public."AdvanceOrderVoids" v on v."TransactionNo" = a."TransactionNo"
    where a."IsVoid"
      and a."TransactionNo" = any(coalesce(p_nos, '{}'))
      and (v_branch is null or lower(trim(coalesce(a."Warehouse", ''))) = v_branch);
end;
$$;

grant execute on function public.staff_get_advance_order_voids(text, text, text[]) to anon;

notify pgrst, 'reload schema';

select case
  when (select count(*) from information_schema.columns
        where table_schema = 'public' and table_name = 'AdvanceOrders'
          and column_name in ('VoidCredit', 'VoidCreditUsed', 'VoidCreditUsedOn')) = 3
   and exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'staff_get_advance_order_voids'
                 and pg_get_function_result(p.oid) like '%void_credit_used_on%')
  then 'OK - void credit columns + staff_get_advance_order_voids ready'
  else 'FIX - something is missing, re-run this file'
end as result;
