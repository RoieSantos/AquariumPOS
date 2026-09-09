-- Adds a Category filter to Serial Tracker (docs/serial-tracker.html) - per direct request
-- ("can you add a filtration there to filter category"). ItemSerialTracking has no CategoryCode of
-- its own, so staff_search_item_serial_tracking now joins to Items on ItemCode to filter by it.
--
-- Explicit drop first (not just create or replace) since appending a new parameter changes the
-- function's signature - CREATE OR REPLACE would otherwise silently create a second, overloaded
-- version instead of actually replacing the old one, same reasoning as every other widening
-- migration in this codebase (see e.g. supabase_item_hide_from_set.sql's admin_list_items).
drop function if exists public.staff_search_item_serial_tracking(text, text, text, text, text, text, int);

create or replace function public.staff_search_item_serial_tracking(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_status text default null,
  p_location_restrict text default null,
  p_location_filter text default null,
  p_limit int default 500,
  p_category_code text default null
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
      and (p_category_code is null or trim(p_category_code) = '' or exists (
        select 1 from public."Items" i
        where i."Code" = s."ItemCode"
          and trim(coalesce(i."CategoryCode", '')) = trim(p_category_code)
      ))
    order by s."CreatedAtUtc" desc nulls last
    limit v_limit;
end;
$$;

grant execute on function public.staff_search_item_serial_tracking(text, text, text, text, text, text, int, text) to anon;

-- ---------------------------------------------------------------------------
-- Category dropdown options - same staff-auth gate as the search RPC above, rather than reusing
-- the anon-open public_list_order_categories() (Order Now's own picker), so this stays consistent
-- with every other RPC this staff-only page calls.
-- ---------------------------------------------------------------------------
drop function if exists public.staff_list_categories(text, text);

create or replace function public.staff_list_categories(p_admin_username text, p_admin_password text)
returns table(code text, description text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select c."Code"::text, coalesce(nullif(trim(c."Description"), ''), c."Code")::text
    from public."Categories" c
    order by 2;
end;
$$;

grant execute on function public.staff_list_categories(text, text) to anon;
