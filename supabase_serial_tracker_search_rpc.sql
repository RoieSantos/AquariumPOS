-- Fixes Serial Tracker (docs/serial-tracker.html) silently hiding older serials. Per "im
-- wondering why Amaya has 38 stocks but when I checked on the serial tracker its 0 - only GMA
-- has" - Inventory Summary's count (38 for Amaya) was correct, sourced live from a server-side
-- aggregate over the WHOLE ItemSerialTracking table. Serial Tracker's loadSerials()
-- (docs/js/serialTracker.js) instead fetched only the 500 MOST RECENTLY CREATED rows across the
-- entire table (order by CreatedAtUtc desc limit 500), then filtered that capped snapshot
-- client-side by search text/status/location. Once the table grew past 500 rows, any older batch
-- of serials (like Amaya's AQ-001 units) fell outside that window and became invisible to every
-- search/filter on the page, even though they still exist and are correctly counted elsewhere.
--
-- This adds a search RPC that filters server-side FIRST, then limits - so a search always finds
-- a matching row regardless of how large the table has grown, instead of only ever seeing
-- whichever 500 rows happen to be newest. See docs/js/serialTracker.js's loadSerials() for the
-- client-side rewire that calls this instead of a plain capped select().
--
-- p_search matches the existing client-side search (SerialNo/ItemCode/ItemDescription,
-- case-insensitive substring). p_status is an exact match, same as the existing status dropdown.
-- p_location_restrict/p_location_filter are two SEPARATE optional exact-match (trim/case
-- insensitive) location gates, AND'd together - mirrors the two independent location filters
-- renderSerials used to apply in sequence: a non-production, non-Serial-Admin user's own-warehouse
-- restriction (p_location_restrict), and Inventory Summary's deep-link ?location= filter
-- (p_location_filter) - both can be active at once, and previously both had to match for a row to
-- show, so this keeps that same combined behavior.
drop function if exists public.staff_search_item_serial_tracking(text, text, text, text, text, text, int);

create or replace function public.staff_search_item_serial_tracking(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_status text default null,
  p_location_restrict text default null,
  p_location_filter text default null,
  p_limit int default 500
)
returns table(
  serial_no text,
  item_code text,
  item_description text,
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
      s."SerialNo"::text, s."ItemCode"::text, s."ItemDescription"::text, s."Location"::text, s."Status"::text,
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
    order by s."CreatedAtUtc" desc nulls last
    limit v_limit;
end;
$$;

grant execute on function public.staff_search_item_serial_tracking(text, text, text, text, text, text, int) to anon;
