-- Walk-in orders: 10mm / 12mm glass tag - per "in the walk-in orders can we also put a tag if that
-- order is custom and needs 10mm 12mm glass".
--
-- OnlineOrders."GlassThickness" is filled by the Pancake sync's GLASS THICKNESS BACKFILL
-- (supabase_pancake_manual_sync.sql), which deliberately skips ReceivedAtShop orders (one extra
-- Pancake detail call per order) - so walk-ins never got a glass tag. Their lines ARE synced into
-- OnlineOrderLines though (the ORDER LINES BACKFILL isn't walk-in-filtered), so this derives the
-- same value from those lines instead - no extra Pancake calls:
--   same rule as the sync: line name/description + note + product_display_id with whitespace
--   stripped, '12mm' wins over '10mm', null when neither appears.
-- Walk-in orders only - online orders keep the sync's own Pancake-derived value untouched.
--
-- The "Custom" tag already works for walk-ins (admin_list_online_orders computes has_custom_line
-- from the same OnlineOrderLines) - nothing to change there.
--
-- Safe to re-run.

create or replace function public._walkin_order_glass_thickness(p_order_id text)
returns text
language sql
stable
set search_path = public
as $$
  select case
           when bool_or(regexp_replace(coalesce(l."Description", '') || ' ' || coalesce(l."Note", '') || ' ' || coalesce(l."product_display_id", ''), '\s+', '', 'g') ilike '%12mm%') then '12mm'
           when bool_or(regexp_replace(coalesce(l."Description", '') || ' ' || coalesce(l."Note", '') || ' ' || coalesce(l."product_display_id", ''), '\s+', '', 'g') ilike '%10mm%') then '10mm'
         end
  from public."OnlineOrderLines" l
  where l."OrderID" = p_order_id;
$$;

-- Keeps it current as the sync writes/edits/removes a walk-in order's lines.
create or replace function public._walkin_order_lines_glass_trigger()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id text := case when tg_op = 'DELETE' then old."OrderID" else new."OrderID" end;
begin
  update public."OnlineOrders" o
     set "GlassThickness" = public._walkin_order_glass_thickness(v_order_id)
   where o."OrderID" = v_order_id
     and o."ReceivedAtShop" is true
     and o."GlassThickness" is distinct from public._walkin_order_glass_thickness(v_order_id);
  return null;
end;
$$;

drop trigger if exists trg_walkin_order_lines_glass on public."OnlineOrderLines";
create trigger trg_walkin_order_lines_glass
after insert or update or delete on public."OnlineOrderLines"
for each row execute function public._walkin_order_lines_glass_trigger();

-- Also when an order flips to walk-in after its lines were already synced.
create or replace function public._walkin_order_header_glass_trigger()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new."ReceivedAtShop" is true then
    new."GlassThickness" := public._walkin_order_glass_thickness(new."OrderID");
  end if;
  return new;
end;
$$;

drop trigger if exists trg_walkin_order_header_glass on public."OnlineOrders";
create trigger trg_walkin_order_header_glass
before insert or update of "ReceivedAtShop" on public."OnlineOrders"
for each row execute function public._walkin_order_header_glass_trigger();

-- One-time backfill for existing walk-in orders.
update public."OnlineOrders" o
   set "GlassThickness" = public._walkin_order_glass_thickness(o."OrderID")
 where o."ReceivedAtShop" is true
   and o."GlassThickness" is distinct from public._walkin_order_glass_thickness(o."OrderID");

-- Check (read-only): walk-in orders now tagged, and how many walk-ins have no warehouse.
select count(*) filter (where "GlassThickness" = '12mm') as walkin_12mm,
       count(*) filter (where "GlassThickness" = '10mm') as walkin_10mm,
       count(*) filter (where "LocationID" is null)      as walkin_without_location,
       count(*)                                          as walkin_total
from public."OnlineOrders"
where "ReceivedAtShop" is true;
