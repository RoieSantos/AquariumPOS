-- Per "i want see how much is from each warehouse" on the Dashboard's Daily cards (Today's Online
-- Sales / Today's Walk-In Sales / Expense Today) - one row per warehouse with today's figures,
-- shown as a small breakdown under each card's total.
--
-- Uses exactly the same "today" rules as the cards' own totals, so the rows always add up to them:
--   * online sales  - admin_get_online_order_financial_summary: ConfirmedAtUtc (Manila) falling back
--                     to Date, ReceivedAtShop not true, not cancelled. Warehouse = OnlineOrders.LocationID.
--   * walk-in sales - same function: Date = today, ReceivedAtShop true, not cancelled.
--   * expense       - admin_get_expense_entry_summary: ExpenseEntryHeader.NetAmount + ExpenseJournalEntries.Amount
--                     dated today. Warehouse = their "Warehouse" (a name, not an ID).
-- Anything with no warehouse shows as "(No warehouse)". Warehouses with nothing today are left out.
--
-- Super users only (the Daily cards are part of the super-user finance grid). Safe to re-run.

drop function if exists public.admin_get_dashboard_daily_by_warehouse(text, text, text);

create or replace function public.admin_get_dashboard_daily_by_warehouse(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_name text default null
)
returns table(
  warehouse_name text,
  online_sales numeric, online_order_count int,
  walkin_sales numeric, walkin_order_count int,
  expense numeric, expense_count int
)
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
    with sales as (
      select coalesce(nullif(trim(w."Name"), ''), '(No warehouse)') as wh,
             coalesce(sum(o."MoneyToCollect") filter (
               where o."ReceivedAtShop" is not true
                 and coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = v_today), 0) as online_sales,
             count(*) filter (
               where o."ReceivedAtShop" is not true
                 and coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = v_today) as online_count,
             coalesce(sum(o."MoneyToCollect") filter (
               where o."ReceivedAtShop" is true and o."Date" = v_today), 0) as walkin_sales,
             count(*) filter (
               where o."ReceivedAtShop" is true and o."Date" = v_today) as walkin_count
      from public."OnlineOrders" o
      left join public."Warehouses" w on w."ID" = o."LocationID"
      where lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
        and (v_wh is null or w."Name" = v_wh)
        -- Cheap pre-filter: either rule can only match an order dated or confirmed today.
        and (o."Date" = v_today or (o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date = v_today)
      group by 1
    ),
    exp as (
      select coalesce(nullif(trim(e.wh), ''), '(No warehouse)') as wh,
             sum(e.amount) as expense,
             count(*) as expense_count
      from (
        select h."Warehouse" as wh, h."NetAmount" as amount
        from public."ExpenseEntryHeader" h
        where h."Date" = v_today and (v_wh is null or h."Warehouse" = v_wh)
        union all
        select j."Warehouse", j."Amount"
        from public."ExpenseJournalEntries" j
        where j."EntryDate" = v_today and (v_wh is null or j."Warehouse" = v_wh)
      ) e
      group by 1
    )
    select coalesce(s.wh, x.wh)::text,
           coalesce(s.online_sales, 0)::numeric, coalesce(s.online_count, 0)::int,
           coalesce(s.walkin_sales, 0)::numeric, coalesce(s.walkin_count, 0)::int,
           coalesce(x.expense, 0)::numeric, coalesce(x.expense_count, 0)::int
    from sales s
    full join exp x on x.wh = s.wh
    order by 1;
end;
$$;

grant execute on function public.admin_get_dashboard_daily_by_warehouse(text, text, text) to anon;
