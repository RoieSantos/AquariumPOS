-- Advance Orders: custom builds (CUSTOM-AQUARIUM / CUSTOM-STAND ...) need serials at Ready to Ship - per
-- "this order did not ask for serials. but supposedly it need serials" (advance order 2565, MAM JULIE,
-- 2026-10-24; supabase_check_advance_order_serial_lines_2565.sql).
--
-- Cause: _advance_order_line_items only counts a line as serial-tracked once it resolves to a REAL item
-- (VariationId / "No" as an item code / Description as a name). A POS custom-build line has "No" =
-- 'CUSTOM-AQUARIUM' / 'CUSTOM-STAND' (its category), a one-off VariationId that's in no Variants row, and
-- a free-text description - and there is no Items row with Code CUSTOM-AQUARIUM / CUSTOM-STAND. So both
-- lines came back "NO - item not found", quantity_needed was 0, and Ready to Ship skipped the serial picker.
--
-- Now: a line that resolves to nothing but whose "No" starts CUSTOM- / CUSTOM_ (not a sticker, not a SET)
-- uses that "No" as its item code (resolved_by 'custom build') - the same thing Online Orders' Ready to
-- Ship does (admin_get_online_order_serial_requirements falls back to the line's own ItemCode, so custom
-- online builds get RS-CUSTOM-AQUARIUM-<YY>-000001 serials). Real matches still win.
--
-- What else this changes (all callers of _advance_order_line_items):
--   * Ready to Ship / TO FOLLOW / "No serial yet" / Delivery Receipt serial gate: these lines now need a
--     serial - which is the point. A custom advance order's delivery receipt waits for its serial.
--   * Item Ledger (supabase_item_ledger_advance_orders.sql): unchanged in effect - _ile_try_resolve_stock_key
--     skips codes not in Items, so custom builds still post no stock.
--   * Transfer links / request cap: custom codes were already excluded / matched by category.
--
-- Copy of supabase_advance_order_sticker_no_serial.sql's version (the newest) + the 'custom build' fallback.
-- Run AFTER supabase_advance_order_sticker_no_serial.sql. Function only - safe to re-run. Don't re-run
-- supabase_advance_order_serials.sql or supabase_advance_order_sticker_no_serial.sql afterwards (they'd put
-- the old version back) - if you must, run this one again after.

create or replace function public._advance_order_line_items(p_no text)
returns table(
  line_no text,
  category text,         -- AdvanceOrderLines."No" (the POS's Category column)
  description text,
  quantity int,
  item_code text,        -- resolved real item code (or the CUSTOM- category for a custom build), null = couldn't resolve
  variation_id text,
  resolved_by text,      -- variation / item code / name / custom build / null
  needs_serial boolean,
  reason text
)
language sql
stable
security definer
set search_path = public
as $$
  select l."LineNo"::text,
         nullif(trim(l."No"), '')::text,
         nullif(trim(l."Description"), '')::text,
         greatest(ceil(coalesce(l."Quantity", 0)), 0)::int,
         r.code::text,
         coalesce(nullif(trim(l."VariationId"), ''), nullif(trim(r.item_variation), ''))::text,
         r.how::text,
         (r.code is not null and not s.is_set and not s.is_sticker and (
            coalesce(cl."IsProductionCategory", false) or coalesce(ci."IsProductionCategory", false)
            or upper(r.code) like 'AQ-%' or left(upper(r.code), 7) in ('CUSTOM-', 'CUSTOM_'))),
         case
           when s.is_set then 'no - SET (mother item; its parts carry the serials)'
           when s.is_sticker then 'no - custom sticker (cut to size, no serial)'
           when r.how = 'custom build' then 'YES - custom build (' || r.code || ', no Items row - serial uses the POS category)'
           when r.code is null and (coalesce(cl."IsProductionCategory", false)
                                    or left(upper(coalesce(trim(l."No"), '')), 7) in ('CUSTOM-', 'CUSTOM_'))
             then 'NO - item not found (needs a serial, but no Items / Variants match its VariationId or name)'
           when r.code is null then 'no - item not found, not a production category'
           when coalesce(cl."IsProductionCategory", false) then 'YES - category ' || trim(l."No")
           when coalesce(ci."IsProductionCategory", false) then 'YES - item category ' || r.category
           when upper(r.code) like 'AQ-%' then 'YES - AQ- code'
           when left(upper(r.code), 7) in ('CUSTOM-', 'CUSTOM_') then 'YES - CUSTOM code'
           else 'no - not a production category'
         end
  from public."AdvanceOrderLines" l
  left join public."Categories" cl on cl."Code" = trim(l."No")
  left join lateral (
    select x.code, x.category, x.item_variation, x.how
    from (
      -- 1. by VariationId
      select coalesce(nullif(trim(v."ItemCode"), ''), nullif(trim(v."MainItemCode"), '')) as code,
             coalesce(v."CategoryCode", vi."CategoryCode") as category, v."VariationId" as item_variation,
             'variation' as how, 1 as rank
      from public."Variants" v
      left join public."Items" vi on vi."Code" = coalesce(nullif(trim(v."ItemCode"), ''), nullif(trim(v."MainItemCode"), ''))
      where nullif(trim(l."VariationId"), '') is not null and v."VariationId" = trim(l."VariationId")
      union all
      select i."Code", i."CategoryCode", i."VariationId", 'variation', 2
      from public."Items" i
      where nullif(trim(l."VariationId"), '') is not null and i."VariationId" = trim(l."VariationId")
      -- 2. "No" really is an item code (older lines)
      union all
      select i."Code", i."CategoryCode", i."VariationId", 'item code', 3
      from public."Items" i
      where i."Code" = trim(l."No")
      -- 3. Description = an item / variant name
      union all
      select i."Code", i."CategoryCode", i."VariationId", 'name', 4
      from public."Items" i
      where nullif(trim(l."Description"), '') is not null
        and (upper(trim(i."Name")) = upper(trim(l."Description")) or upper(trim(i."Description")) = upper(trim(l."Description")))
      union all
      select coalesce(nullif(trim(v."ItemCode"), ''), nullif(trim(v."MainItemCode"), '')),
             coalesce(v."CategoryCode", vi."CategoryCode"), v."VariationId", 'name', 5
      from public."Variants" v
      left join public."Items" vi on vi."Code" = coalesce(nullif(trim(v."ItemCode"), ''), nullif(trim(v."MainItemCode"), ''))
      where nullif(trim(l."Description"), '') is not null and upper(trim(v."VariantName")) = upper(trim(l."Description"))
      -- 4. Custom build with no item at all: its CUSTOM- category is the item code (like Online Orders).
      --    Stickers / SETs are excluded below (is_sticker / is_set), so they still need no serial.
      union all
      select upper(trim(l."No")), null, null, 'custom build', 6
      where left(upper(coalesce(trim(l."No"), '')), 7) in ('CUSTOM-', 'CUSTOM_')
    ) x
    where x.code is not null
    order by x.rank
    limit 1
  ) r on true
  left join public."Categories" ci on ci."Code" = r.category
  -- A SET (e.g. "AQUARIUM SET") is the mother item - the POS lists its parts (tank / sump / stand) as
  -- their own lines, and those carry the serials. By the line's category or the resolved item's.
  cross join lateral (
    select (upper(coalesce(trim(l."No"), '')) ~ '(^|[\s_-])SET$'
            or upper(coalesce(trim(r.category), '')) ~ '(^|[\s_-])SET$') as is_set,
           'CUSTOM-STICKER' in (upper(coalesce(trim(l."No"), '')), upper(coalesce(trim(r.code), '')),
                                upper(coalesce(trim(r.category), ''))) as is_sticker
  ) s
  where l."TransactionNo" = p_no
    and upper(coalesce(l."Type", '')) = 'ITEM'
    and coalesce(l."Quantity", 0) > 0;
$$;

revoke execute on function public._advance_order_line_items(text) from public, anon, authenticated;

-- Verification - one result: advance order 2565's lines should now say "YES - custom build".
select li.line_no, li.category, li.item_code, li.resolved_by, li.needs_serial, li.reason
from public._advance_order_line_items('2565') li
order by li.line_no;
