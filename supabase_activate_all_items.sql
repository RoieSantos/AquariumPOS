-- One-off: mark every Items row as Active. Use this if supabase_diagnose_automated_order_items.sql
-- showed items exist per category but "active_item_count" is 0/low - i.e. "IsActive" is false or
-- null on rows that should be orderable.
--
-- SCOPE WARNING: "Items"."IsActive" isn't only used by the Order Now wizard - it also gates
-- staff_search_items/staff_list_items_by_category (Transfer Orders, Custom Calculator pickers,
-- etc, see supabase_warehouses_items_tables.sql). Flipping every item to Active means every item
-- in your catalog - including anything you'd deliberately discontinued/hidden - becomes pickable
-- again everywhere those RPCs are used, not just on the public order page. If you only want to
-- unhide specific categories, add a "CategoryCode" filter to the WHERE clause below instead of
-- running this as-is.

update public."Items"
set "IsActive" = true
where "IsActive" is distinct from true;
