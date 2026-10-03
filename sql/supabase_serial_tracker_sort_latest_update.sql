-- Serial Tracker: latest update first - per "please sort the serial tracker for the latest update first in
-- line". staff_search_item_serial_tracking listed (and kept the newest 500 by) CreatedAtUtc, so a serial
-- that was just sold / moved / edited stayed where it was created. Now ordered by the last change -
-- UpdatedAtUtc, else CreatedAtUtc - newest first, and the 500-row cap keeps the most recently changed.
-- Same body as supabase_serial_variant_sku_colour.sql otherwise; same signature, so create or replace is
-- enough. Re-running that file would put the old order back - run this after it.

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
    -- Latest change first (supabase_serial_tracker_sort_latest_update.sql).
    order by coalesce(s."UpdatedAtUtc", s."CreatedAtUtc") desc nulls last, s."SerialNo" desc
    limit v_limit;
end;
$$;

grant execute on function public.staff_search_item_serial_tracking(text, text, text, text, text, text, int, text, text) to anon;
