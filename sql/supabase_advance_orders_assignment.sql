-- SUPERSEDED by supabase_advance_order_production.sql (advance orders now have their own assignment
-- flow - most have no linked online order). Don't run this one after that file.
--
-- Advance Orders: show the linked Online Order's status + makers - per "since advance order is a
-- ordering too.. can we implement same assignment process".
--
-- Every advance order is already pushed to Pancake as a normal online order by the POS
-- (SyncAdvanceOrderToCloudAsync, note "Advance Order Ref: <receipt>"), and that Pancake order syncs
-- into public."OnlineOrders" like any other. So the full assignment flow (Assign Tank/Stand Maker ->
-- Assigned -> My Assignments -> Production Done -> To Ship -> Shipped) already works on it - the
-- Advance Orders tab just couldn't see or reach it. This adds the linked order's Status,
-- Tank Maker and Stand Maker (display names) to admin_list_advance_orders; the portal's Assign
-- button then hands off to the existing Online Order assign dialog (no second assignment pipeline).
--
-- Also includes the "latest update first" sort from supabase_advance_orders_sort_latest_update.sql,
-- so this file SUPERSEDES that one - run this instead (running both in either order is harmless
-- only if this one runs LAST). Safe to re-run.

drop function if exists public.admin_list_advance_orders(text, text, text, text, int, int);

create or replace function public.admin_list_advance_orders(p_admin_username text, p_admin_password text, p_search text default null, p_transaction_no text default null, p_page int default 1, p_page_size int default 50)
returns table(
  transaction_no text,
  receipt_no text,
  user_id text,
  customer_name text,
  order_description text,
  order_date date,
  order_time text,
  net_amount numeric,
  downpayment numeric,
  balance numeric,
  online_order_id text,
  fully_paid boolean,
  date_paid timestamptz,
  warehouse text,
  synced_at_utc timestamptz,
  online_status text,           -- linked OnlineOrders."Status" (null = not synced from Pancake yet)
  tank_maker text,              -- username
  tank_maker_name text,
  stand_maker text,
  stand_maker_name text,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select a."TransactionNo"::text, a."ReceiptNo"::text, a."UserID"::text, a."CustomerName"::text, a."Order_Description"::text,
           a."Date", a."Time"::text, a."NetAmount", a."Downpayment", a."Balance",
           a."OnlineOrderID"::text,
           coalesce(a."FullyPaid", false) or coalesce(a."Balance", 0) <= 0,
           a."DatePaid", a."Warehouse"::text, a."SyncedAtUtc",
           o."Status"::text,
           o."AssignedTankMaker"::text, tank."DisplayName"::text,
           o."AssignedStandMaker"::text, stand."DisplayName"::text,
           count(*) over()
    from public."AdvanceOrders" a
    left join public."OnlineOrders" o
      on nullif(trim(a."OnlineOrderID"), '') is not null and o."OrderID"::text = trim(a."OnlineOrderID")
    left join public."StaffUsers" tank on tank."Username" = o."AssignedTankMaker"
    left join public."StaffUsers" stand on stand."Username" = o."AssignedStandMaker"
    where (p_transaction_no is not null and trim(p_transaction_no) <> '' and a."TransactionNo" = p_transaction_no)
       or (
         (p_transaction_no is null or trim(p_transaction_no) = '')
         and (
           p_search is null or trim(p_search) = ''
           or a."TransactionNo" ilike '%' || p_search || '%'
           or a."ReceiptNo" ilike '%' || p_search || '%'
           or a."CustomerName" ilike '%' || p_search || '%'
           or a."UserID" ilike '%' || p_search || '%'
           or a."OnlineOrderID" ilike '%' || p_search || '%'
         )
       )
    -- Latest activity first: the later of when it was fully paid ("DatePaid") and when it was
    -- placed ("Date" + "Time", Manila). "Time" is free text from the POS, so it's only used when it
    -- looks like a clock time (e.g. 14:05, 2:05:33 PM); otherwise the order counts from midnight.
    order by greatest(
               a."DatePaid",
               (a."Date" + case when trim(coalesce(a."Time", '')) ~* '^\d{1,2}:\d{2}(:\d{2})?(\.\d+)?\s*([ap]m)?$'
                                then trim(a."Time")::time else time '00:00' end) at time zone 'Asia/Manila'
             ) desc nulls last,
             case when a."TransactionNo" ~ '^\d+$' then a."TransactionNo"::numeric end desc nulls last,
             a."TransactionNo" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_advance_orders(text, text, text, text, int, int) to anon;

notify pgrst, 'reload schema';

-- Read-only check: how many advance orders are linked to a synced Online Order (assignable from the
-- portal) vs. not pushed to Pancake yet / not synced back yet.
select case
         when nullif(trim(a."OnlineOrderID"), '') is null then '1. no Pancake order id yet (POS has not pushed it)'
         when o."OrderID" is null then '2. has Pancake id, but not in OnlineOrders yet (waiting for sync)'
         else '3. linked - assignable (' || coalesce(o."Status", 'no status') || ')'
       end as link_state,
       count(*) as orders
from public."AdvanceOrders" a
left join public."OnlineOrders" o
  on nullif(trim(a."OnlineOrderID"), '') is not null and o."OrderID"::text = trim(a."OnlineOrderID")
group by 1
order by 1;
