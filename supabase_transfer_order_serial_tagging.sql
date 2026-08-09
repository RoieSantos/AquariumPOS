-- Serial tagging for Transfer Order shipments - lets staff pick which specific physical serial-
-- tracked units (see supabase_item_serial_tracking.sql) are going out on a given Ship action, for
-- items under a Production Category (the same "Categories"."IsProductionCategory" flag Stock
-- Counts now filters on locally - see StockCountsForm.cs / GlobalSettings.CategoriesSupabaseEndpoint).
-- Picking only from EXISTING available (IN_STOCK) serials - staff cannot generate new ones from
-- this flow, per direct instruction; if there aren't enough available serials, Ship is blocked
-- until more exist (created via Stock Counts or the desktop's Serial Tracker).
--
-- Tagging a serial onto a shipment sets Status = 'IN_TRANSIT' (a new value alongside the existing
-- IN_STOCK/SOLD/RESERVED/RETURNED) and Location = the destination warehouse's plain name (no
-- "In Transit to " decoration, per direct instruction - Location is always exactly a warehouse
-- name so it stays exact-match filterable, e.g. Serial Tracker's per-warehouse view in
-- serialTracker.js; Status is what conveys "on the truck, not actually in stock yet").
--
-- This DOES feed back to the desktop's own local dbo.ItemSerialTracking, but on a delay and via
-- last-writer-wins, not instantly: OnlinefunctionsEvents.SyncItemSerialTrackingFromSupabaseAsync
-- (MainForm's 5-minute MasterDataSyncTimer_Tick) polls this table for rows whose UpdatedAtUtc is
-- newer than the local copy's own COALESCE(UpdatedAtUtc, CreatedAtUtc), and only then overwrites
-- local's Status/Location/etc - matched by SerialNo, not RunningSerialNo, since every store runs
-- its own separate local database with its own independent RunningSerialNo identity sequence. If
-- the receiving store's database has never seen this SerialNo before (e.g. it was created and
-- shipped from a different store), the pull INSERTs a brand-new local row instead of skipping it,
-- so that store's own GetAvailableSerials/PromptForAquariumSaleSerials can find and sell it -
-- required at every warehouse now, not just production ones (see
-- ShouldRequireAquariumSerialSelection in MainForm.cs). Symmetrically, the local -> Supabase push
-- (SyncItemSerialTrackingToSupabaseAsync) now checks this table's UpdatedAtUtc before PATCHing and
-- skips (leaving the row dirty) if Supabase is already newer, instead of blindly clobbering an
-- IN_TRANSIT tag with a stale local snapshot. Unlike Categories (a single owner - the Portal - so
-- Supabase always wins there), this table is written from both sides, so neither direction can be
-- a blind "wins" - whichever side's UpdatedAtUtc is actually newer wins, per row.

drop function if exists public.staff_get_item_production_flags(text, text, text[]);

-- Batch lookup so the Manage modal (transferOrders.js's openManageModal) can determine, for every
-- item already on an order's lines, whether it needs serial tagging before Ship - joins Items ->
-- Categories fresh each call rather than trusting Transfer_Line's own CategoryCode column (not
-- actually populated by saveNewTransfer today, so it can't be relied on).
create or replace function public.staff_get_item_production_flags(
  p_admin_username text,
  p_admin_password text,
  p_item_codes text[]
)
returns table(item_no text, is_production_category boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_item_codes is null or array_length(p_item_codes, 1) is null then
    return;
  end if;

  return query
    select i."Code"::text, coalesce(c."IsProductionCategory", false)
    from public."Items" i
    left join public."Categories" c on c."Code" = i."CategoryCode"
    where i."Code" = any(p_item_codes);
end;
$$;

drop function if exists public.staff_claim_serials_for_transfer_shipment(text, text, text, text, bigint[]);

-- Atomically claims every requested RunningSerialNo in one UPDATE - Postgres's ordinary row-level
-- locking makes this race-safe against a concurrent claim on the same serial (two staff shipping
-- the same item at once: whichever UPDATE commits first wins, the loser's WHERE simply no longer
-- matches once it re-checks "Status" = 'IN_STOCK'). If fewer rows matched than were requested,
-- something wasn't actually available anymore - raising here rolls back the whole UPDATE
-- (all-or-nothing, nothing left half-claimed) so the caller (shipTransferOrder in
-- transferOrders.js) can block the whole Ship action cleanly and have the user re-pick.
create or replace function public.staff_claim_serials_for_transfer_shipment(
  p_admin_username text,
  p_admin_password text,
  p_document_no text,
  p_to_warehouse_name text,
  p_running_serial_nos bigint[]
)
returns table(running_serial_no bigint, serial_no text, item_code text, variant_code text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_location text;
  v_requested_count int;
  v_claimed_count int;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_requested_count := coalesce(array_length(p_running_serial_nos, 1), 0);
  if v_requested_count = 0 then
    raise exception 'No serials specified to claim.';
  end if;

  -- Location is always exactly a warehouse name, never decorated text - Status (IN_TRANSIT here)
  -- is what conveys "on the truck, not actually in stock there yet", so an exact-match Location
  -- lookup (e.g. Serial Tracker's per-warehouse filter in serialTracker.js) still finds it. Uses
  -- the destination since that's the warehouse this serial is now associated with in the pipeline.
  v_location := nullif(trim(p_to_warehouse_name), '');

  with claimed as (
    update public."ItemSerialTracking"
      set "Status" = 'IN_TRANSIT',
          "Location" = v_location,
          "SourceDocumentNo" = p_document_no,
          "UpdatedAtUtc" = now()
      where "RunningSerialNo" = any(p_running_serial_nos) and "Status" = 'IN_STOCK'
      returning "RunningSerialNo"
  )
  select count(*) into v_claimed_count from claimed;

  if v_claimed_count < v_requested_count then
    raise exception 'Only % of % requested serial(s) were still available - someone may have just claimed one. Refresh and try again.', v_claimed_count, v_requested_count;
  end if;

  return query
    select "RunningSerialNo", "SerialNo"::text, "ItemCode"::text, "VariantCode"::text
    from public."ItemSerialTracking"
    where "RunningSerialNo" = any(p_running_serial_nos);
end;
$$;

grant execute on function public.staff_get_item_production_flags(text, text, text[]) to anon;
grant execute on function public.staff_claim_serials_for_transfer_shipment(text, text, text, text, bigint[]) to anon;
