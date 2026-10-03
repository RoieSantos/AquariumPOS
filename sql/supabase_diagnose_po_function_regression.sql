-- READ-ONLY diagnostic: Purchase Order item picker does not show items whose vendor is only a
-- secondary vendor (Item Setup > Vendors catalog, public."ItemVendors").
--
-- Suspect: supabase_item_cost_and_po_line_cost.sql (edited 2026-10-02 for the posted-date
-- purchase summary) holds OLD versions of staff_search_items and 8 other PO functions -
-- written before the Item Vendor catalog, Units of Measure, PO line variants and the
-- Payment Method requirement. Re-running that file whole drops/replaces the newer versions.
--
-- One result: for each live function, whether it has each feature that the newer files added.
-- "MISSING" on a feature the function should have = it was reverted.

with fn as (
  select p.proname, pg_get_functiondef(p.oid) as def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in (
      'staff_search_items', 'staff_create_purchase_order', 'staff_add_purchase_order_line',
      'staff_list_purchase_order_lines', 'staff_list_posted_purchase_order_lines',
      'staff_post_purchase_order'
    )
),
checks(proname, feature, marker) as (
  values
    ('staff_search_items',                     'vendor catalog (secondary vendors)', 'ItemVendors'),
    ('staff_search_items',                     'item description column',            'Description'),
    ('staff_create_purchase_order',            'unit of measure',                    'UnitOfMeasureCode'),
    ('staff_create_purchase_order',            'line variant',                       'VariantCode'),
    ('staff_add_purchase_order_line',          'unit of measure',                    'UnitOfMeasureCode'),
    ('staff_add_purchase_order_line',          'line variant',                       'VariantCode'),
    ('staff_list_purchase_order_lines',        'vendor item no',                     'VendorItemNo'),
    ('staff_list_purchase_order_lines',        'unit of measure',                    'UnitOfMeasureCode'),
    ('staff_list_purchase_order_lines',        'line variant',                       'VariantCode'),
    ('staff_list_posted_purchase_order_lines', 'unit of measure',                    'UnitOfMeasureCode'),
    ('staff_list_posted_purchase_order_lines', 'line variant',                       'VariantCode'),
    ('staff_post_purchase_order',              'payment method required',            'PaymentMethod')
)
select c.proname as function_name,
       c.feature,
       case
         when count(f.proname) = 0 then 'FUNCTION NOT FOUND'
         when bool_or(position(c.marker in f.def) > 0) then 'ok'
         else 'MISSING'
       end as status,
       count(f.proname) as overloads
from checks c
left join fn f on f.proname = c.proname
group by c.proname, c.feature
order by c.proname, c.feature;
