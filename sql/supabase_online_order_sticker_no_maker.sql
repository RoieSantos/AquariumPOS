-- Custom sticker / accessory lines don't need a maker - per "if there is a customer sticker in the order
-- please allow the store manager and super user to ship this order and proceed" (AO-00047 showed Custom,
-- asked for a Tank Maker and its To Ship stayed greyed out even for a Super User).
--
-- 1. _online_order_is_sticker_line (new) - a Custom Accessory/Sticker line: item code / product id
--    containing "sticker" (CUSTOM-STICKER, the placeholder product's code, or the POS Custom Stickers
--    dialog's 'CUSTOM-STICKER' category on advance orders), a description starting "Custom
--    Accessory/Sticker" (the name all three builders give it - GMA Create Order, Order Now, Alice), or a
--    description containing "CUSTOM-STICKER" - the placeholder product's name, e.g. AO-00047's
--    "CUSTOM-STICKER (CI-009 - CUSTOM-STICKER - CI-009)" with item code CI-009 - unless it also names a
--    custom build (CUSTOM-AQUARIUM / TANK / STAND / SUMP / CABINET). A plain "sticker background" in a
--    custom aquarium's spec doesn't count - that tank still needs its Tank Maker.
--
-- 2. _online_order_line_part - treated every line containing "custom" as maker work, so a sticker line
--    (stickers, rubber matting, glass, acrylic, plywood, top covers quoted with the sticker calculator)
--    counted as a custom TANK line. Sticker lines now return null (no maker), like plywood
--    (supabase_online_order_plywood_no_maker.sql) and like the local POS, which already treats a custom
--    sticker/accessory as "not a build" (OnlineOrdersForm.cs).
--
-- 3. _online_order_production_roles (same as supabase_walkin_order_portal_status.sql + this) - a 10mm /
--    12mm order always needs a Tank Maker (supabase_online_order_thick_glass_tank_maker.sql), but the
--    order's GlassThickness flag is set from ANY line's name / notes mentioning 10mm / 12mm - so a sticker
--    quote for 10mm glass / acrylic / plywood flagged the whole order. The glass rule now doesn't count
--    when the 10mm / 12mm only appears on sticker lines. (No line mentions it at all - e.g. the flag came
--    from somewhere else - it still counts, same as before.)
--
-- Effect: an order whose only custom line is a sticker follows the normal flow - the Store Manager /
-- Super User To Ship (Confirmed allowed, js/onlineOrders.js canToShipOrder) and the portal (AO-) To Ship
-- work straight away, no Assign / Production Done. An order that ALSO has a custom aquarium / stand (or
-- a real 10mm / 12mm tank) still needs those makers. The "Custom" badge (has_custom_line) and the
-- "10mm glass" badge stay - they're only labels.
--
-- Everything that decides makers goes through these functions (Assign popup / card, list's Tank Maker
-- column, Production Done, My Assignments, walk-in production, stock-ship check, To Ship gate, advance
-- orders), so this covers all of them.
--
-- Run AFTER supabase_online_order_plywood_no_maker.sql and supabase_walkin_order_portal_status.sql.
-- Functions only - safe to re-run (re-run it if you ran the earlier version without step 3). If
-- supabase_walkin_order_portal_status.sql or supabase_online_order_thick_glass_tank_maker.sql is ever
-- re-run, run this one again afterwards. Check: supabase_check_order_AO-00047_maker.sql.

-- ---------------------------------------------------------------------------
-- 1. Sticker line

create or replace function public._online_order_is_sticker_line(p_description text, p_item_code text, p_product_display_id text)
returns boolean
language sql
immutable
as $$
  select (coalesce(p_item_code, '') || ' ' || coalesce(p_product_display_id, '')) ~* 'sticker'
      or coalesce(p_description, '') ~* '^[[:space:]]*custom[[:space:]]+accessory[[:space:]]*/[[:space:]]*sticker'
      -- Pancake / portal lines named after the placeholder product: "CUSTOM-STICKER (CI-009 - CUSTOM-STICKER
      -- - CI-009)" with item code CI-009. Not when the line is also a custom build (CUSTOM-AQUARIUM ...).
      or (coalesce(p_description, '') ~* 'custom[[:space:]_-]*sticker'
          and coalesce(p_description, '') !~* 'custom[[:space:]_-]*(aquarium|tank|stand|sump|cabinet)');
$$;

revoke execute on function public._online_order_is_sticker_line(text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Line part

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
    -- This file: custom stickers / accessories aren't built by a maker either.
    when public._online_order_is_sticker_line(p_description, p_item_code, p_product_display_id) then null
    when (coalesce(p_description, '') || ' ' || coalesce(p_item_code, '')) ~* '(stand(?!ard)|top[[:space:]_-]*cover)' then 'stand'
    else 'tank'
  end;
$$;

revoke execute on function public._online_order_line_part(text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Production roles

create or replace function public._online_order_production_roles(p_order_id text)
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  with thick as (
    -- Which lines mention 10mm / 12mm (same text test as the GlassThickness flag), split by sticker / not.
    select
      coalesce(bool_or(not public._online_order_is_sticker_line(ol."Description", ol."ItemCode", ol."product_display_id")), false) as on_other,
      coalesce(bool_or(public._online_order_is_sticker_line(ol."Description", ol."ItemCode", ol."product_display_id")), false) as on_sticker
    from public."OnlineOrderLines" ol
    where ol."OrderID" = p_order_id
      and regexp_replace(coalesce(ol."Description", '') || coalesce(ol."Note", '') || coalesce(ol."ItemCode", ''), '[[:space:]]+', '', 'g') ~* '1[02]mm'
  ),
  f as (
    select
      exists (
        select 1 from public."OnlineOrderLines" ol
        where ol."OrderID" = p_order_id and public._online_order_line_part(ol."Description", ol."ItemCode", ol."product_display_id") = 'tank'
      ) or exists (
        -- 10mm / 12mm orders always need a Tank Maker - unless only sticker lines mention it (this file).
        select 1 from public."OnlineOrders" o, thick t
        where o."OrderID" = p_order_id and public._online_order_thick_glass(o."GlassThickness")
          and not (t.on_sticker and not t.on_other)
      ) as tank,
      exists (
        select 1 from public."OnlineOrderLines" ol
        where ol."OrderID" = p_order_id and public._online_order_line_part(ol."Description", ol."ItemCode", ol."product_display_id") = 'stand'
      ) as custom_stand,
      exists (
        select 1 from public."OnlineOrderLines" ol
        where ol."OrderID" = p_order_id and public._online_order_is_stand_line(ol."Description", ol."ItemCode")
      ) as any_stand
  )
  select (case when f.tank then array['tank'] else array[]::text[] end)
      || (case when f.custom_stand or (f.tank and f.any_stand) then array['stand'] else array[]::text[] end)
  from f;
$$;

revoke execute on function public._online_order_production_roles(text) from public, anon, authenticated;
