-- Per "can you show in the dashboard too today's advance order sales" - feeds the Dashboard's
-- "Today's Advance Orders" card (Sales - Today section). One row per warehouse for advance orders
-- placed today (AdvanceOrders."Date" = today, Asia/Manila): total order value (NetAmount), the
-- downpayments taken and the balance still owed. Anything with no warehouse shows as "(No warehouse)";
-- warehouses with no advance orders today are left out.
--
-- Super users only (the card is part of the super-user finance grid), same optional
-- p_warehouse_name filter as admin_get_dashboard_daily_by_warehouse. Safe to re-run.

drop function if exists public.admin_get_dashboard_daily_advance_orders(text, text, text);

create or replace function public.admin_get_dashboard_daily_advance_orders(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_name text default null
)
returns table(
  warehouse_name text,
  order_count int,
  net_amount numeric,
  downpayment numeric,
  balance numeric
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
    select coalesce(nullif(trim(a."Warehouse"), ''), '(No warehouse)')::text,
           count(*)::int,
           coalesce(sum(a."NetAmount"), 0)::numeric,
           coalesce(sum(a."Downpayment"), 0)::numeric,
           coalesce(sum(greatest(coalesce(a."Balance", 0), 0)), 0)::numeric
    from public."AdvanceOrders" a
    where a."Date" = v_today
      and (v_wh is null or a."Warehouse" = v_wh)
    group by 1
    order by 1;
end;
$$;

grant execute on function public.admin_get_dashboard_daily_advance_orders(text, text, text) to anon;
