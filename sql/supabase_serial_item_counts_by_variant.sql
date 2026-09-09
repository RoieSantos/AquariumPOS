-- Fixes two related bugs in Inventory Summary's "By Product" breakdown, reported as: "the other
-- variants is not showing" and "when I click the count hyperlink I think its tagged into the
-- product not variant".
--
-- BUG 1: staff_get_serial_item_counts_by_location (supabase_serial_item_counts_by_location.sql)
-- grouped only by ItemCode + bucket + Location, with no VariantCode in the GROUP BY at all. If a
-- location had more than one variant of the same item (e.g. two different AQ-036 builds), they
-- were silently merged into ONE row - the count shown was the sum across every variant, but the
-- description was just whichever one max(ItemDescription) happened to pick, hiding the rest. This
-- adds VariantCode to the grouping (resolving a proper per-variant name from public."Variants",
-- same VariantCode = VariationId keying supabase_online_order_to_ship_serials.sql already uses)
-- so each variant now gets its own row/count.
--
-- BUG 2: the count's link (buildSerialTrackerLink in docs/js/inventorySummary.js) only ever
-- carried ?item=<code>, never a variant - so clicking through landed on Serial Tracker searching
-- by item code alone, showing every variant's units mixed together regardless of which
-- variant/count was actually clicked. This adds an optional p_variant_filter to
-- staff_search_item_serial_tracking (supabase_serial_tracker_search_rpc.sql) so the deep link can
-- narrow to the exact variant. See docs/js/inventorySummary.js and docs/js/serialTracker.js for
-- the client-side half of this fix.
--
-- Run this AFTER supabase_serial_item_counts_by_location.sql and
-- supabase_serial_tracker_category_filter.sql - staff_search_item_serial_tracking's CURRENT
-- signature (as of that file) already has p_category_code as an 8th param; this adds
-- p_variant_filter as a 9th on top of that, it does not revert to the older 7-param version
-- supabase_serial_tracker_search_rpc.sql originally defined.

drop function if exists public.staff_get_serial_item_counts_by_location(text, text, text, text);

create or replace function public.staff_get_serial_item_counts_by_location(
  p_admin_username text,
  p_admin_password text,
  p_status text default 'IN_STOCK',
  p_category text default null
)
returns table(
  item_code text,
  item_description text,
  variant_code text,
  category text,
  location text,
  unit_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      x.bucketed_item_code::text,
      max(x.bucketed_description)::text,
      x.bucketed_variant_code::text,
      x.bucket::text,
      x.bucketed_location::text,
      count(*)
    from (
      select
        s."ItemCode" as bucketed_item_code,
        nullif(trim(s."VariantCode"), '') as bucketed_variant_code,
        -- Prefer the per-serial ItemDescription snapshot over the resolved Variant's own name -
        -- confirmed live that Variants."VariantName" is often the same generic product-level text
        -- across multiple distinct VariationIds (e.g. two different AQ-036 builds both synced down
        -- as "AQ-036 - STANDARD-5G (16x8x10in, 3MM GLASS)"), which defeated the point of splitting
        -- variants into their own rows below - every row looked identical. ItemDescription is what
        -- was actually captured on the serial at creation time and is what distinguished the two
        -- builds before this file's variant-grouping fix, so it's the more useful text to show.
        -- VariantName is only a fallback for the (blank-ItemDescription) rows that need it.
        coalesce(
          nullif(trim(s."ItemDescription"), ''),
          nullif(trim(v."VariantName"), '')
        ) as bucketed_description,
        coalesce(nullif(trim(s."Location"), ''), '(Unassigned)') as bucketed_location,
        case
          when i."CategoryCode" = 'AQUARIUM' or s."ItemCode" = 'CUSTOM-AQUARIUM' then 'AQUARIUM'
          when i."CategoryCode" = 'STAND' or s."ItemCode" ilike 'CUSTOM%STAND%' then 'STAND'
          when i."CategoryCode" = 'SUMP' or s."ItemCode" ilike 'CUSTOM%SUMP%' then 'SUMP'
          else null
        end as bucket
      from public."ItemSerialTracking" s
      left join public."Items" i on i."Code" = s."ItemCode"
      left join public."Variants" v on v."VariationId" = nullif(trim(s."VariantCode"), '')
      where p_status is null or trim(p_status) = '' or upper(s."Status") = upper(p_status)
    ) x
    where x.bucket is not null
      and (p_category is null or trim(p_category) = '' or x.bucket = upper(p_category))
    group by x.bucketed_item_code, x.bucketed_variant_code, x.bucket, x.bucketed_location
    order by x.bucket, x.bucketed_item_code, x.bucketed_variant_code nulls first, x.bucketed_location;
end;
$$;

grant execute on function public.staff_get_serial_item_counts_by_location(text, text, text, text) to anon;

drop function if exists public.staff_search_item_serial_tracking(text, text, text, text, text, text, int, text);

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
  updated_by text
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
      s."CreatedAtUtc", s."UpdatedAtUtc", s."UpdatedBy"::text
    from public."ItemSerialTracking" s
    where (p_search is null or trim(p_search) = '' or
           s."SerialNo" ilike '%' || p_search || '%' or
           s."ItemCode" ilike '%' || p_search || '%' or
           s."ItemDescription" ilike '%' || p_search || '%')
      and (p_status is null or trim(p_status) = '' or s."Status" = p_status)
      and (p_location_restrict is null or trim(p_location_restrict) = '' or lower(trim(s."Location")) = lower(trim(p_location_restrict)))
      and (p_location_filter is null or trim(p_location_filter) = '' or lower(trim(s."Location")) = lower(trim(p_location_filter)))
      and (p_category_code is null or trim(p_category_code) = '' or exists (
        select 1 from public."Items" i
        where i."Code" = s."ItemCode"
          and trim(coalesce(i."CategoryCode", '')) = trim(p_category_code)
      ))
      -- (Unassigned)-only variants and a specific variant both need to compare cleanly against a
      -- possibly-null column, so both sides are coalesced to '' rather than relying on SQL's
      -- three-valued NULL comparison.
      and (p_variant_filter is null or trim(p_variant_filter) = '' or coalesce(trim(s."VariantCode"), '') = trim(p_variant_filter))
    order by s."CreatedAtUtc" desc nulls last
    limit v_limit;
end;
$$;

grant execute on function public.staff_search_item_serial_tracking(text, text, text, text, text, text, int, text, text) to anon;
