-- One-off repair for AO-00019's failed Pancake push ("None of this order's lines matched a known Pancake
-- product") - and any other GMA Conversations order hit by the same bug.
--
-- Cause: GMA Conversations' Custom Aquarium/Stand quote saved its line as ItemCode = 'CUSTOM-AQUARIUM'/
-- 'CUSTOM-STAND'. Order Now and the AI bot save it as CategoryCode = 'CUSTOM-...' with ItemCode empty,
-- which _push_automated_order_to_pancake matches by Items.Name (the row is Code CI-005 / Name
-- CUSTOM-AQUARIUM). An ItemCode of 'CUSTOM-AQUARIUM' is looked up by Items.Code instead, finds nothing,
-- and fails. js/gmaConversations.js now saves it the right way; this fixes lines already saved.
--
-- Run 1 and 2 first to check, then 3, then press Retry on the order in Automated Orders.

-- 1. Custom lines on every not-yet-synced order (AO-00019, AO-00023, ...), and the Items row each would
--    match after the fix. A line with ItemCode = 'CUSTOM-AQUARIUM'/'CUSTOM-STAND' is one step 3 fixes.
select l."OrderNo", l."EntryNo", l."CategoryCode", l."ItemCode", l."ItemName", l."Quantity", l."Price",
       i."Code" as matched_item_code, i."VariationId", i."ProductId"
from public."AutomatedOrderLines" l
join public."AutomatedOrders" o on o."OrderNo" = l."OrderNo"
left join public."Items" i
  on i."Code" = coalesce(nullif(l."ItemCode", ''), nullif(l."CategoryCode", ''))
  or (i."Name" = coalesce(nullif(l."CategoryCode", ''), nullif(l."ItemCode", '')))
where coalesce(o."PancakeSyncStatus", '') <> 'Synced'
  and (upper(coalesce(l."ItemCode", '')) like 'CUSTOM-%' or upper(coalesce(l."CategoryCode", '')) like 'CUSTOM-%')
order by l."OrderNo", l."EntryNo";

-- 2. The custom placeholder rows in Items - each needs a VariationId or ProductId for the push to work.
select "Code", "Name", "VariationId", "ProductId", "IsActive"
from public."Items"
where "Name" in ('CUSTOM-AQUARIUM', 'CUSTOM-STAND', 'CUSTOM-STICKER')
   or "Code" in ('CUSTOM-AQUARIUM', 'CUSTOM-STAND', 'CUSTOM-STICKER');

-- 3. Move the tag to CategoryCode on every not-yet-synced order's custom lines.
update public."AutomatedOrderLines" l
set "CategoryCode" = upper(trim(l."ItemCode")),
    "ItemCode" = null
from public."AutomatedOrders" o
where o."OrderNo" = l."OrderNo"
  and coalesce(o."PancakeSyncStatus", '') <> 'Synced'
  and upper(trim(l."ItemCode")) in ('CUSTOM-AQUARIUM', 'CUSTOM-STAND')
returning l."OrderNo", l."EntryNo", l."CategoryCode", l."ItemName";
