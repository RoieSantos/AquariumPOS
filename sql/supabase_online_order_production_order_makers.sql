-- Online Orders: show the Tank Maker / Stand Maker assigned on the linked Production Order(s) on the
-- order itself - per "help me tag the assigned maker too even though its on production".
--
-- staff_list_online_order_production_orders (supabase_online_order_production_order_tag.sql) only
-- returned the PRD no. + status, so an order whose units are being built on a Production Order showed
-- the PRD badge but a blank Tank Maker / Stand Maker column (e.g. a stock order with no custom line,
-- where the order itself never needs a maker). This adds each PO's makers (username + display name)
-- and when each part was marked done. A maker is only returned when the PO actually has a line for
-- that part, so a stale picker value on a stand-only PO doesn't show as a Tank Maker.
--
--   staff_list_online_order_production_orders(order_ids[]) - order_id, production_order_no, status,
--     tank_maker, tank_maker_name, tank_done_at_utc, stand_maker, stand_maker_name, stand_done_at_utc,
--     newest first per order.
--
-- Supersedes the definition in supabase_online_order_production_order_tag.sql (don't re-run that one
-- after this). Run AFTER supabase_production_orders.sql. Safe to re-run.

drop function if exists public.staff_list_online_order_production_orders(text, text, text[]);

create or replace function public.staff_list_online_order_production_orders(
  p_admin_username text,
  p_admin_password text,
  p_order_ids text[]
)
returns table(
  order_id text,
  production_order_no text,
  status text,
  tank_maker text,
  tank_maker_name text,
  tank_done_at_utc timestamptz,
  stand_maker text,
  stand_maker_name text,
  stand_done_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select po."SourceOnlineOrderId"::text,
           po."No"::text,
           po."Status"::text,
           case when parts.has_tank then po."TankMaker" end::text,
           case when parts.has_tank then coalesce(nullif(trim(tank."DisplayName"), ''), po."TankMaker") end::text,
           case when parts.has_tank then po."TankDoneAtUtc" end,
           case when parts.has_stand then po."StandMaker" end::text,
           case when parts.has_stand then coalesce(nullif(trim(stand."DisplayName"), ''), po."StandMaker") end::text,
           case when parts.has_stand then po."StandDoneAtUtc" end
    from public."ProductionOrders" po
    cross join lateral (
      select coalesce(bool_or(l."Part" = 'tank'), false) as has_tank,
             coalesce(bool_or(l."Part" = 'stand'), false) as has_stand
      from public."ProductionOrderLines" l
      where l."ProdOrderNo" = po."No"
    ) parts
    left join public."StaffUsers" tank on tank."Username" = po."TankMaker"
    left join public."StaffUsers" stand on stand."Username" = po."StandMaker"
    where po."SourceOnlineOrderId" = any(coalesce(p_order_ids, '{}'))
    order by po."SourceOnlineOrderId", po."CreatedAtUtc" desc;
end;
$$;

grant execute on function public.staff_list_online_order_production_orders(text, text, text[]) to anon;

notify pgrst, 'reload schema';
