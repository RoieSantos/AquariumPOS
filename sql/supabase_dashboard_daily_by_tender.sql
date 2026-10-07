-- Per "in the dashboard we have Today's Walk-in sales and Todays Online sales.. Below that we can see
-- the break down per branch. is it possible we break it down too by the tender types?"
--
-- Follow-up "in today's walkin sales can you do By Branch By tender so they will have relationship" -
-- rows are per warehouse too, so the Walk-In card nests each branch's tenders under it.
--
-- One row per warehouse x online/walk-in x payment method for TODAY, shown under the per-branch breakdown on the
-- two "Sales - Today" cards. Uses exactly the same "today" rules (and warehouse filter) as
-- admin_get_dashboard_daily_by_warehouse, and the per-order payment rows the Payment Method report
-- already stores (OnlineOrderPayments, filled every 5 minutes by cron_sync_order_payments).
--
-- The card's headline is the order total (MoneyToCollect), not what's been paid, so one extra row per
-- card - method_code null, "Unpaid / not synced yet" - carries the difference (balances still owed,
-- plus orders the 5-minute payment sync hasn't read yet), so the rows add up to the headline.
--   order_count = orders that used that method (a split payment counts under each method).
--
-- Super users only. Run AFTER supabase_payment_method_report.sql. Safe to re-run.

drop function if exists public.admin_get_dashboard_daily_by_tender(text, text, text);

create or replace function public.admin_get_dashboard_daily_by_tender(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_name text default null
)
returns table(warehouse_name text, is_walkin boolean, method_code text, method_name text, amount numeric, order_count int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_wh text := nullif(trim(coalesce(p_warehouse_name, '')), '');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with orders as (
      select o."OrderID" as order_id,
             coalesce(nullif(trim(w."Name"), ''), '(No warehouse)') as wh,
             coalesce(o."ReceivedAtShop", false) as walkin,
             coalesce(o."MoneyToCollect", 0) as total
      from public."OnlineOrders" o
      left join public."Warehouses" w on w."ID" = o."LocationID"
      where lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
        and (v_wh is null or w."Name" = v_wh)
        and (
          (o."ReceivedAtShop" is true and o."Date" = v_today)
          or (o."ReceivedAtShop" is not true
              and coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = v_today)
        )
    ),
    paid as (
      select x.wh, x.walkin, p."MethodCode" as code, sum(p."Amount") as amount, count(*) as cnt
      from orders x
      join public."OnlineOrderPayments" p on p."OrderID" = x.order_id
      group by x.wh, x.walkin, p."MethodCode"
    ),
    rest as (
      select x.wh, x.walkin,
             sum(x.total) - coalesce((select sum(pd.amount) from paid pd
                                      where pd.wh = x.wh and pd.walkin = x.walkin), 0) as amount,
             count(*) filter (where not exists (
               select 1 from public."OnlineOrderPayments" p where p."OrderID" = x.order_id)) as cnt
      from orders x
      group by x.wh, x.walkin
    )
    select pd.wh::text, pd.walkin, pd.code::text, public._payment_method_label(pd.code)::text,
           pd.amount::numeric, pd.cnt::int
    from paid pd
    union all
    select r.wh::text, r.walkin, null::text, 'Unpaid / not synced yet'::text, r.amount::numeric, r.cnt::int
    from rest r
    where r.amount > 0
    order by 1, 2, 5 desc;
end;
$$;

grant execute on function public.admin_get_dashboard_daily_by_tender(text, text, text) to anon;
