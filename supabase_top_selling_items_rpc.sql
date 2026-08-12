-- Top Selling Items report (Web Portal, all active staff) - per "can we show top ranking items
-- base on how many they been sold... i want to see daily / weekly and monthly report in chart
-- form". No existing RPC/feature does this.
--
-- Data source: public."OnlineOrderLines" joined to public."OnlineOrders" - the only line-item-
-- level sales data in Supabase. This covers Pancake-driven online orders AND in-store orders
-- received at the shop ("ReceivedAtShop" = true), the same source the dashboard's existing
-- Walk-In Sales cards already rely on - not a narrow slice of sales.
--
-- Day/week/month granularity is entirely a CLIENT-side concern - this RPC just filters a plain
-- date range (p_date_from/p_date_to), same shape already used by admin_get_order_confirmation_
-- timing and admin_list_expense_entries. The portal (docs/js/topSellingItems.js) computes the
-- range from a selected granularity + an anchor date (Daily = that day; Weekly = the Mon-Sun week
-- containing it; Monthly = the calendar month containing it) and Prev/Next shifts the anchor.
--
-- o."Date" is already Asia/Manila-local (same as admin_get_order_confirmation_timing's "created"
-- side) - no timezone conversion needed for the range filter.
--
-- Revenue sums "GrossAmount" (Price * Quantity, always populated by every sync path in
-- supabase_pancake_manual_sync.sql), not "NetAmount" (left untouched/unreliable for lines per
-- that file's own sync comments).
--
-- Gated with is_staff_authorized (any active staff), matching the existing Reports page
-- (docs/js/reports.js has no isSuperUser check) - this is a sales-insight report, not restricted
-- financial data.

drop function if exists public.admin_get_top_selling_items(text, text, date, date, int);

create or replace function public.admin_get_top_selling_items(
  p_admin_username text,
  p_admin_password text,
  p_date_from date,
  p_date_to date,
  p_limit int default 10
)
returns table(
  item_code text,
  item_name text,
  category_code text,
  qty_sold numeric,
  revenue numeric,
  order_count bigint,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 10), 1), 100);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      l."ItemCode"::text,
      coalesce(i."Name", l."Description")::text,
      i."CategoryCode"::text,
      sum(l."Quantity") as qty_sold,
      sum(l."GrossAmount") as revenue,
      count(distinct l."OrderID")::bigint as order_count,
      -- Post-GROUP BY row count (before LIMIT applies) - the true number of distinct items sold
      -- in this range, so the client can show "Top 10 of 47 items sold".
      count(*) over()::bigint as total_count
    from public."OnlineOrderLines" l
    join public."OnlineOrders" o on o."OrderID" = l."OrderID"
    left join public."Items" i on i."Code" = l."ItemCode"
    where l."ItemCode" is not null
      and o."Date" >= p_date_from and o."Date" <= p_date_to
      and lower(trim(coalesce(o."Status", ''))) not in ('cancelled', 'canceled')
    group by l."ItemCode", coalesce(i."Name", l."Description"), i."CategoryCode"
    order by qty_sold desc
    limit v_limit;
end;
$$;

grant execute on function public.admin_get_top_selling_items(text, text, date, date, int) to anon;
