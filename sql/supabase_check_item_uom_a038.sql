-- Read-only check: why A-038 PEBBLE-COLORED (1KG) can't be switched from PC to BAG on its PO line.
-- The PO line's UoM picker only offers units in ItemUnitsOfMeasure for the line's item code.
-- Shows the item's base/buy unit, every unit it has with its Qty per, and its open PO lines.

select 'item' as section, i."Code"::text as item_code,
       'base=' || coalesce(i."BaseUnitOfMeasure", '(none)') || ', buy=' || coalesce(i."PurchUnitOfMeasure", '(none)') as detail,
       null::numeric as qty_per
  from public."Items" i
 where i."Code" = 'A-038'
union all
select 'unit', iu."ItemCode"::text, iu."UnitOfMeasureCode"::text, iu."QtyPerUnitOfMeasure"
  from public."ItemUnitsOfMeasure" iu
 where iu."ItemCode" = 'A-038'
union all
select 'po line', l."ItemCode"::text,
       l."PONo" || ' #' || l."EntryNo" || ' uom=' || coalesce(l."UnitOfMeasureCode", '(none)')
         || ' qty=' || l."Quantity" || ' received=' || coalesce(l."QtyReceived", 0),
       l."QtyPerUnitOfMeasure"
  from public."PurchaseOrderLines" l
 where l."ItemCode" = 'A-038'
order by 1, 3;
