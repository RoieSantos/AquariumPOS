-- Serial Tracker + Production Shelf Map: show the variant SKU and Black / Clear sealant tag - per
-- "in the serial tracker and production shelf map.. why are we not writing base on the SKU its not
-- identifying black or clear sealant".
--
-- Serials posted from a Production Order already carry the right VariantCode (the order line's
-- variant), but the colour only lives in that variant's SKU ("AQ-028-BlackSealant") - its
-- VariantName is just "AQ-028 - STANDARD-75G (...)" and the serial's ItemDescription is the order
-- line's free-text description. Serial Tracker's search RPC never joined Variants, so it had nothing
-- to show; only legacy POS serials looked right because their description happened to include the SKU.
--
-- Both RPCs now return variant_sku + colour, with colour from the SAME rule the Production Order card
-- uses (_production_colour over VariantName, SKU, the variant's own item name, then the description).
--
-- Run AFTER supabase_serial_item_counts_by_variant.sql, supabase_production_shelf_serial_sku_colour.sql
-- and supabase_production_variant_colour.sql (for _production_colour). Safe to re-run.

-- ---------------------------------------------------------------------------
-- Serial Tracker (docs/js/serialTracker.js)
-- ---------------------------------------------------------------------------
drop function if exists public.staff_search_item_serial_tracking(text, text, text, text, text, text, int, text, text);

create or replace function public.staff_search_item_serial_tracking(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_status text default null,
  p_location_restrict text default null,
  p_location_filter text default null,
  p_limit int default 500,
  p_category_code text default null,
  p_variant_filter text default null
)
returns table(
  serial_no text,
  item_code text,
  item_description text,
  variant_code text,
  location text,
  status text,
  source_document_no text,
  sold_receipt_no text,
  sold_online_order_id text,
  created_at_utc timestamptz,
  updated_at_utc timestamptz,
  updated_by text,
  variant_sku text,
  colour text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 500), 1), 2000);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      s."SerialNo"::text, s."ItemCode"::text, s."ItemDescription"::text, s."VariantCode"::text, s."Location"::text, s."Status"::text,
      s."SourceDocumentNo"::text, s."SoldReceiptNo"::text, s."SoldOnlineOrderId"::text,
      s."CreatedAtUtc", s."UpdatedAtUtc", s."UpdatedBy"::text,
      nullif(trim(v."SKU"), '')::text,
      public._production_colour(v."VariantName", v."SKU", vi."Name", s."ItemDescription")
    from public."ItemSerialTracking" s
    left join public."Variants" v on v."VariationId" = nullif(trim(s."VariantCode"), '')
    left join public."Items" vi on vi."Code" = v."ItemCode"
    where (p_search is null or trim(p_search) = '' or
           s."SerialNo" ilike '%' || p_search || '%' or
           s."ItemCode" ilike '%' || p_search || '%' or
           s."ItemDescription" ilike '%' || p_search || '%' or
           v."SKU" ilike '%' || p_search || '%')
      and (p_status is null or trim(p_status) = '' or s."Status" = p_status)
      and (p_location_restrict is null or trim(p_location_restrict) = '' or lower(trim(s."Location")) = lower(trim(p_location_restrict)))
      and (p_location_filter is null or trim(p_location_filter) = '' or lower(trim(s."Location")) = lower(trim(p_location_filter)))
      and (p_category_code is null or trim(p_category_code) = '' or exists (
        select 1 from public."Items" i
        where i."Code" = s."ItemCode"
          and trim(coalesce(i."CategoryCode", '')) = trim(p_category_code)
      ))
      and (p_variant_filter is null or trim(p_variant_filter) = '' or coalesce(trim(s."VariantCode"), '') = trim(p_variant_filter))
    order by s."CreatedAtUtc" desc nulls last
    limit v_limit;
end;
$$;

grant execute on function public.staff_search_item_serial_tracking(text, text, text, text, text, text, int, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Production Shelf Map (docs/js/productionShelfMap.js) - same as
-- supabase_production_shelf_serial_sku_colour.sql plus `colour`.
-- ---------------------------------------------------------------------------
drop function if exists public.staff_list_production_location_serials(text, text, text);

create or replace function public.staff_list_production_location_serials(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text
)
returns table(running_serial_no bigint, serial_no text, item_code text, item_description text,
              variant_code text, variant_name text, source_document_no text, created_at timestamptz,
              main_item_code text, variant_sku text, colour text)
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
           nullif(trim(v."MainItemCode"), '')::text,
           nullif(trim(v."SKU"), '')::text,
           public._production_colour(v."VariantName", v."SKU", vi."Name", s."ItemDescription")
    from public."ItemSerialTracking" s
    left join public."Items" i on i."Code" = s."ItemCode"
    left join public."Variants" v on v."VariationId" = s."VariantCode"
    left join public."Items" vi on vi."Code" = v."ItemCode"
    where s."Status" = 'IN_STOCK'
      and s."Location" = v_warehouse_name
    order by s."ItemCode", s."SerialNo";
end;
$$;

grant execute on function public.staff_list_production_location_serials(text, text, text) to anon;

notify pgrst, 'reload schema';
