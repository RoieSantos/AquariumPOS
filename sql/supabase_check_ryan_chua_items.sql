-- READ-ONLY. Lists every item tied to vendor Ryan Chua (Aquatinum Corporation), so it can be
-- mapped against their supplier catalogue ("Fish and Aquarium Products Catalogue 2") and their
-- prices loaded into ItemVendors."Cost".
--
-- An item is included if ANY of these is true (see the "link" column):
--   primary  - Items."VendorCode" is Ryan Chua
--   catalog  - it has an ItemVendors row for Ryan Chua
--   bought   - it appears on a posted Purchase Order to Ryan Chua
--
-- The vendor is found by name (Ryan / Chua / Aquatinum), so check vendor_code / vendor_name in the
-- result - if more than one vendor matched, tell Claude which one is right.
--
-- Safe to re-run. Changes nothing. Export the result as CSV (Supabase result pane -> download).

with v as (
  select "VendorCode", "Name"
  from public."Vendors"
  where "Name" ilike '%ryan%' or "Name" ilike '%chua%' or "Name" ilike '%aquatinum%'
     or "VendorCode" ilike '%ryan%' or "VendorCode" ilike '%chua%'
),
bought as (
  select ph."VendorCode", pl."ItemCode",
         count(distinct ph."PONo")  as po_count,
         sum(pl."QtyReceived")      as qty_received_total,
         max(ph."OrderDate")        as last_po_date,
         -- unit cost on the most recent posted PO line for this vendor + item
         (array_agg(pl."UnitCost" order by ph."OrderDate" desc, pl."EntryNo" desc))[1] as last_po_unit_cost
  from public."PostedPurchaseOrderLines" pl
  join public."PostedPurchaseOrders" ph on ph."PONo" = pl."PONo"
  join v on v."VendorCode" = ph."VendorCode"
  group by ph."VendorCode", pl."ItemCode"
),
linked as (
  select i."Code" as item_code, v."VendorCode" as vendor_code
  from public."Items" i join v on v."VendorCode" = i."VendorCode"
  union
  select iv."ItemCode", iv."VendorCode"
  from public."ItemVendors" iv join v on v."VendorCode" = iv."VendorCode"
  union
  select b."ItemCode", b."VendorCode" from bought b
)
select
  v."VendorCode"::text                                        as vendor_code,
  v."Name"::text                                              as vendor_name,
  i."Code"::text                                              as item_code,
  i."Name"::text                                              as item_name,
  nullif(trim(i."Description"), '')::text                     as description,
  i."CategoryCode"::text                                      as category_code,
  coalesce(nullif(trim(c."Description"), ''), i."CategoryCode")::text as category,
  i."BaseUnitOfMeasure"::text                                 as base_uom,
  concat_ws(', ',
    case when i."VendorCode" = l.vendor_code then 'primary' end,
    case when iv."ItemCode" is not null then 'catalog' end,
    case when b."ItemCode" is not null then 'bought' end)     as link,
  i."Cost"                                                    as item_cost,
  iv."VendorItemNo"::text                                     as current_vendor_item_no,
  iv."Cost"                                                   as current_vendor_cost,
  b.last_po_unit_cost,
  b.last_po_date,
  b.po_count,
  b.qty_received_total,
  i."QuantityInStock"                                         as qty_in_stock,
  i."IsActive"                                                as is_active
from linked l
join v on v."VendorCode" = l.vendor_code
join public."Items" i on i."Code" = l.item_code
left join public."Categories" c on c."Code" = i."CategoryCode"
left join public."ItemVendors" iv on iv."ItemCode" = l.item_code and iv."VendorCode" = l.vendor_code
left join bought b on b."ItemCode" = l.item_code and b."VendorCode" = l.vendor_code
order by v."VendorCode", category, i."Name";
