-- Advance Orders: custom stickers never need a serial - per "can we allow regular check out for stickers?
-- no need to maintain serials for this custom stickers".
--
-- The POS saves an advance line's Category in AdvanceOrderLines."No", so every line from the POS's Custom
-- Stickers dialog (stickers, rubber matting, glass, acrylic, allum top cover) has "No" = 'CUSTOM-STICKER'.
-- _advance_order_line_items counted any 'CUSTOM-' code as serial-tracked, so once a CUSTOM-STICKER Items
-- row exists (supabase_fix_custom_sticker_pancake_push.sql) the portal's Ready to Ship would ask for a
-- serial per sticker. Now a sticker line (by its "No" or its resolved item / category) is never
-- serial-tracked. Same change in the POS's Pay In Full (AdvanceOrdersHeaderForm.cs).
--
-- Same function as supabase_advance_order_serials.sql otherwise - the Item Ledger posting
-- (supabase_item_ledger_advance_orders.sql) reads item_code / reason only and is unaffected.
--
-- Run AFTER supabase_advance_order_serials.sql. Function only - safe to re-run. If
-- supabase_advance_order_serials.sql is ever re-run, run this one again afterwards.
-- !! Superseded by supabase_advance_order_custom_build_serials.sql (2026-10-24, custom builds need serials) -
-- if you re-run this file, run that one again after it.

-- also used by the read-only check files).
create or replace function public._advance_order_line_items(p_no text)
returns table(
  line_no text,
  category text,         -- AdvanceOrderLines."No" (the POS's Category column)
  description text,
  quantity int,
  item_code text,        -- resolved real item code, null = couldn't resolve
  variation_id text,
  resolved_by text,      -- variation / item code / name / null
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
