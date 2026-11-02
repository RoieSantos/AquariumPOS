-- Online Order card: "Paid Via" for POS walk-ins - per WI-00197 showing "Not recorded in Pancake" after a
-- Xendit test sale. Portal-only orders only read AutomatedOrderPayments, but a WI- walk-in has its payments in
-- OnlineOrderPayments (pos_create_walkin_order), so every WI- order showed no method, whatever the tender.
-- Now it reads AutomatedOrderPayments, then OnlineOrderPayments, named from Payment Methods. No call to Pancake
-- any more, per "we are not using pancake anymore" (replaces the live lookup in
-- supabase_bot_orders_portal_confirm.sql): an older Pancake order shows what the sync saved before it stopped.
--
-- Also names the XENDIT method, so it doesn't show as "Unnamed (XENDIT)".
--
-- Run AFTER supabase_bot_orders_portal_confirm.sql and supabase_payment_methods_master.sql. Safe to re-run.
-- Needs js/onlineOrders.js ?v=paidvia1 for the new wording; the method itself shows on reopening the order card.

insert into public."PaymentMethods" ("Code", "Name", "MethodType", "Source")
values ('XENDIT', 'Xendit', 'Bank', 'POS')
on conflict ("Code") do update
  set "Name" = coalesce(nullif(trim(public."PaymentMethods"."Name"), ''), excluded."Name");

create or replace function public.admin_get_online_order_payment_methods(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(method text, code text, amount numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_order_id is null or trim(p_order_id) = '' then
    raise exception 'Order ID is required.';
  end if;

  -- Bot (AO-) orders: payments live on AutomatedOrderPayments.
  return query
    select p."Method"::text, p."Method"::text, sum(p."Amount")::numeric
    from public."AutomatedOrderPayments" p
    where p."OrderNo" = trim(p_order_id)
    group by p."Method"
    order by 1;
  if found then
    return;
  end if;

  -- Everything else, walk-ins (WI-) and older orders: the order's own payments.
  return query
    select public._payment_method_label(p."MethodCode"::text), p."MethodCode"::text, sum(p."Amount")::numeric
    from public."OnlineOrderPayments" p
    where p."OrderID" = trim(p_order_id)
    group by p."MethodCode"
    order by 1;
end;
$$;

grant execute on function public.admin_get_online_order_payment_methods(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result: the test sale's payment and the Xendit Payments row it should link to.
select 'order payment' as section, p."OrderID"::text as ref, public._payment_method_label(p."MethodCode"::text) as detail, p."Amount"::numeric as amount
  from public."OnlineOrderPayments" p
 where p."OrderID" = 'WI-00197'
union all
select 'xendit payment', coalesce(x."ReceiptNo", x."OrderRef"),
       x."Status" || ' / receipt ' || coalesce(x."PosReceiptNo", 'NOT LINKED') || ' / warehouse ' || coalesce(x."PosWarehouseId", 'NONE'),
       coalesce(x."PaidAmount", x."Amount")
  from public."XenditPayments" x
 where x."Source" = 'POS' and x."Status" = 'Paid';
