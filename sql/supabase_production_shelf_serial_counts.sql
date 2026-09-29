-- Production Shelf Map: COUNT mode - per "i dont need to place.. i just want to see the count per
-- serial".
--
-- Racks are no longer filled by putting serials on them. A rack linked to an aquarium (Edit Layout >
-- spot > Item for this spot, e.g. B4 = 75g) simply shows how many serials of that aquarium are
-- IN_STOCK at the shelf's location. This RPC returns every in-stock serial at a location (placed or
-- not) so the page can count them per rack and list them.
--
-- Read only. The placement tables/RPCs from supabase_production_shelf_map.sql are left in place but
-- no longer used by the page.
--
-- main_item_code (per "i want to see if there is black variant and clear variant of 75g on that
-- shelf"): the variant's parent item, so a rack linked to the 75G item with "Any variant" counts
-- every variant of it - Black and Clear - even when a variant has its own item row, and the page
-- can split the count by variant.
--
-- Run AFTER supabase_production_shelf_size_tags.sql. Safe to re-run.

drop function if exists public.staff_list_production_location_serials(text, text, text);

create or replace function public.staff_list_production_location_serials(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text
)
returns table(running_serial_no bigint, serial_no text, item_code text, item_description text,
              variant_code text, variant_name text, source_document_no text, created_at timestamptz,
              main_item_code text)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare
  v_warehouse_name text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  select "Name" into v_warehouse_name from public."Warehouses" where "ID" = p_warehouse_id;
  if v_warehouse_name is null then
    return;
  end if;

  return query
    select s."RunningSerialNo", s."SerialNo"::text, s."ItemCode"::text,
           coalesce(s."ItemDescription", i."Name")::text, s."VariantCode"::text,
           coalesce(nullif(trim(v."VariantName"), ''), v."SKU")::text,
           s."SourceDocumentNo"::text, s."CreatedAtUtc",
           nullif(trim(v."MainItemCode"), '')::text
    from public."ItemSerialTracking" s
    left join public."Items" i on i."Code" = s."ItemCode"
    left join public."Variants" v on v."VariationId" = s."VariantCode"
    where s."Status" = 'IN_STOCK'
      and s."Location" = v_warehouse_name
    order by s."ItemCode", s."SerialNo";
end;
$$;

grant execute on function public.staff_list_production_location_serials(text, text, text) to anon;

notify pgrst, 'reload schema';
