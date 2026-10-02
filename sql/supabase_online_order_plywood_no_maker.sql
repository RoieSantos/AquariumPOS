-- Plywood lines don't need a maker - per "plywood-custom dont need makers can you check".
--
-- _online_order_line_part treated every line whose name/item code/product id contains "custom" as
-- maker work, so CI-003 "PLYWOOD-CUSTOM" (marine plywood cut to size for a stand) was counted as a
-- custom TANK line and the order asked for a Tank Maker. Plywood lines now return null (no maker),
-- the same as a non-custom line. The CUSTOM_STAND line on the same order still needs its Stand Maker.
--
-- Everything that decides makers goes through this one function, so this covers the Assign popup /
-- order card (has_aquarium_line / has_stand_line), the Assigned filter and counts, Production Done /
-- My Assignments (_online_order_production_roles), walk-in production status and the stock-ship check.
-- The "Custom" badge (has_custom_line) is a plain "contains custom" test and is unchanged.
--
-- Run AFTER supabase_production_line_part_standard_fix.sql. Function only - safe to re-run.

create or replace function public._online_order_line_part(p_description text, p_item_code text, p_product_display_id text)
returns text
language sql
immutable
as $$
  select case
    when not (coalesce(p_description, '') ilike '%custom%' or coalesce(p_item_code, '') ilike '%custom%'
              or coalesce(p_product_display_id, '') ilike '%custom%') then null
    -- Plywood is cut to size, not built - no Tank or Stand Maker.
    when (coalesce(p_description, '') || ' ' || coalesce(p_item_code, '') || ' ' || coalesce(p_product_display_id, '')) ~* 'plywood' then null
    when (coalesce(p_description, '') || ' ' || coalesce(p_item_code, '')) ~* '(stand(?!ard)|top[[:space:]_-]*cover)' then 'stand'
    else 'tank'
  end;
$$;

revoke execute on function public._online_order_line_part(text, text, text) from public, anon, authenticated;

-- CHECK (optional): open orders with a plywood line - maker_part should now be null on those lines.
-- select ol."OrderID", ol."ItemCode", ol."Description",
--        public._online_order_line_part(ol."Description", ol."ItemCode", ol."product_display_id") as maker_part
-- from public."OnlineOrderLines" ol
-- join public."OnlineOrders" o on o."OrderID" = ol."OrderID"
-- where (ol."Description" ilike '%plywood%' or ol."ItemCode" ilike '%plywood%')
--   and o."Status" not in ('Shipped', 'Received', 'Cancelled');
