-- Production Orders: a maker only when their part is on the order - per "can you not allow a maker if
-- their specific category is not present in the production order".
--
--   Tank Maker  - only when the order has at least one 'tank' line (aquarium / sump ...)
--   Stand Maker - only when the order has at least one 'stand' line (stand / top cover)
--
-- (Part per line is _production_line_part - supabase_production_orders.sql.)
--
-- Enforced by a DEFERRED constraint trigger on both tables, so it's checked at commit - after
-- staff_save_production_order has written the header AND the lines - and it also catches a line being
-- removed / changed so a part disappears while its maker is still set. The order card
-- (docs/js/productionOrders.js) already disables and clears the picker; this is the server-side guard.
--
-- Also clears any maker already assigned to an order that has none of their part (otherwise the next
-- change to that order would be refused).
--
-- Run AFTER supabase_production_orders.sql. Safe to re-run.

-- 1. One-off cleanup of existing mismatches.
update public."ProductionOrders" o
  set "TankMaker" = null, "TankDoneAtUtc" = null
  where o."TankMaker" is not null
    and not exists (select 1 from public."ProductionOrderLines" l where l."ProdOrderNo" = o."No" and l."Part" = 'tank');

update public."ProductionOrders" o
  set "StandMaker" = null, "StandDoneAtUtc" = null
  where o."StandMaker" is not null
    and not exists (select 1 from public."ProductionOrderLines" l where l."ProdOrderNo" = o."No" and l."Part" = 'stand');

-- 2. The check.
create or replace function public._production_order_check_makers()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_no text;
  v_tank text;
  v_stand text;
begin
  if tg_table_name = 'ProductionOrders' then
    v_no := new."No";
  elsif tg_op = 'DELETE' then
    v_no := old."ProdOrderNo";
  else
    v_no := new."ProdOrderNo";
  end if;

  select o."TankMaker", o."StandMaker" into v_tank, v_stand
  from public."ProductionOrders" o where o."No" = v_no;
  if not found then
    return null; -- the order itself was deleted
  end if;

  if v_tank is not null and not exists (
    select 1 from public."ProductionOrderLines" l where l."ProdOrderNo" = v_no and l."Part" = 'tank'
  ) then
    raise exception 'Production order % has no aquarium / sump lines - it can''t have a Tank Maker. Remove the Tank Maker or add a tank line.', v_no;
  end if;

  if v_stand is not null and not exists (
    select 1 from public."ProductionOrderLines" l where l."ProdOrderNo" = v_no and l."Part" = 'stand'
  ) then
    raise exception 'Production order % has no stand / top cover lines - it can''t have a Stand Maker. Remove the Stand Maker or add a stand line.', v_no;
  end if;

  return null;
end;
$$;

revoke execute on function public._production_order_check_makers() from public, anon, authenticated;

drop trigger if exists "TR_ProductionOrders_CheckMakers" on public."ProductionOrders";
create constraint trigger "TR_ProductionOrders_CheckMakers"
  after insert or update of "TankMaker", "StandMaker" on public."ProductionOrders"
  deferrable initially deferred
  for each row execute function public._production_order_check_makers();

drop trigger if exists "TR_ProductionOrderLines_CheckMakers" on public."ProductionOrderLines";
create constraint trigger "TR_ProductionOrderLines_CheckMakers"
  after insert or update of "Part", "ProdOrderNo" or delete on public."ProductionOrderLines"
  deferrable initially deferred
  for each row execute function public._production_order_check_makers();
