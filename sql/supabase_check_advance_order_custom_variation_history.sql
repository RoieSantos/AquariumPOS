-- Read-only: why did older custom-build advance orders get their serials but 2565 (2026-10-21) didn't?
--
-- The POS stamps a custom line (CUSTOM-AQUARIUM / CUSTOM-STAND ...) with the VariationId of its LOCAL
-- placeholder item ("Custom Aquarium" / "Custom Stand" in dbo.Items - ResolveItemMasterVariationIdByAliases
-- in MainForm.cs). The portal only found the item through that VariationId (Variants / Items). If the
-- placeholder's VariationId in the portal changed or vanished (Pancake product deleted / re-created, the
-- item-master move), new orders carry an ID the portal no longer knows -> "item not found" -> no serials.
--
-- Run BEFORE or AFTER supabase_advance_order_custom_build_serials.sql - the 'match_before_fix' column ignores
-- the new fallback either way. One result:
--   section 'by_variation' - per VariationId seen on custom lines (last 120 days): first / last order date,
--                            how many lines, and whether that ID is in Variants / Items now.
--   section 'placeholder'  - the portal's Custom Aquarium / Custom Stand placeholder items and their IDs.

with custom_lines as (
  select a."TransactionNo", a."Date"::date as order_date, upper(trim(l."No")) as category,
         nullif(trim(l."VariationId"), '') as variation_id
  from public."AdvanceOrderLines" l
  join public."AdvanceOrders" a on a."TransactionNo" = l."TransactionNo"
  where upper(coalesce(l."Type", '')) = 'ITEM'
    and left(upper(coalesce(trim(l."No"), '')), 7) in ('CUSTOM-', 'CUSTOM_')
    and upper(trim(l."No")) <> 'CUSTOM-STICKER'
    and a."Date" >= current_date - 120
)
select 'by_variation' as section,
       c.category,
       coalesce(c.variation_id, '(none)') as variation_id,
       min(c.order_date)::text as first_order,
       max(c.order_date)::text as last_order,
       count(*)::text as lines,
       string_agg(distinct c."TransactionNo"::text, ', ') filter (where c.order_date >= current_date - 7) as recent_orders,
       case
         when c.variation_id is null then 'no VariationId'
         when exists (select 1 from public."Variants" v where v."VariationId" = c.variation_id) then 'in Variants'
         when exists (select 1 from public."Items" i where i."VariationId" = c.variation_id) then 'in Items'
         else 'NOT FOUND (no serials asked)'
       end as match_before_fix
from custom_lines c
group by c.category, c.variation_id
union all
select 'placeholder', coalesce(i."CategoryCode", ''), coalesce(i."VariationId", '(none)'),
       i."Code", left(coalesce(i."Name", ''), 60),
       (select count(*)::text from public."Variants" v where v."ItemCode" = i."Code"),
       coalesce(i."IsActive"::text, ''),
       'portal item ' || coalesce(to_char(i."SyncedAtUtc", 'YYYY-MM-DD HH24:MI'), '')
from public."Items" i
where upper(i."Name") in ('CUSTOM AQUARIUM', 'CUSTOM STAND', 'CUSTOM-AQUARIUM', 'CUSTOM-STAND', 'CUSTOM_STAND')
   or upper(i."Code") in ('CUSTOM-AQUARIUM', 'CUSTOM-STAND', 'CUSTOM_STAND')
order by 1, 2, 5 desc;
