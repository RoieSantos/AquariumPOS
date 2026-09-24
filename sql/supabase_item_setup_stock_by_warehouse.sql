-- Item Setup item card: "Stock by Location" - the actual on-hand quantity per warehouse (Amaya,
-- GMA, ...), like the Inventory-by-Location FactBox on Business Central's item card.
--
-- Read straight from ItemLedgerEntries (the portal's stock source of truth - see
-- supabase_item_ledger_entries.sql), all variants of the item combined. A warehouse is listed if it
-- is an active stock warehouse OR has any ledger balance for this item (so stock sitting in a
-- non-stock warehouse is never hidden). Staff-level auth, same as staff_list_item_units_of_measure.
--
-- Run this in the Supabase SQL Editor (needs supabase_item_ledger_entries.sql already applied).

drop function if exists public.staff_get_item_stock_by_warehouse(text, text, text);

create or replace function public.staff_get_item_stock_by_warehouse(
  p_admin_username text,
  p_admin_password text,
  p_item_code text
)
returns table(warehouse_id text, warehouse_name text, quantity numeric)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select w."ID"::text, coalesce(w."Name", w."ID")::text, coalesce(b.qty, 0)::numeric
    from public."Warehouses" w
    left join (
      select e."WarehouseId" as wid, sum(e."Quantity") as qty
      from public."ItemLedgerEntries" e
      where e."ItemCode" = p_item_code
      group by e."WarehouseId"
    ) b on b.wid = w."ID"
    where (coalesce(w."IsActive", true) and w."IsStockWarehouse") or coalesce(b.qty, 0) <> 0
    order by w."Name";
end;
$$;

grant execute on function public.staff_get_item_stock_by_warehouse(text, text, text) to anon;
