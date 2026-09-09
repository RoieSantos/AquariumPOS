-- Adds "UpdatedBy" to ItemSerialTracking, mirroring the local dbo.ItemSerialTracking column of
-- the same name (see ProductSerialTrackingForm.cs) - so the Portal's Serial Tracker page can show
-- "Last Update Date"/"Last Updated By" the same way the desktop app's own Serial Tracker screen
-- now does, and so the value round-trips correctly through the existing two-way sync
-- (SyncItemSerialTrackingToSupabaseAsync/SyncItemSerialTrackingFromSupabaseAsync in
-- OnlinefunctionsEvents.cs) instead of getting silently dropped on either side.
--
-- Run this AFTER supabase_item_serial_tracking.sql.

alter table public."ItemSerialTracking"
    add column if not exists "UpdatedBy" varchar(200);

comment on column public."ItemSerialTracking"."UpdatedBy" is 'Username (desktop or Portal) that last modified this row - set by whichever write path touched it: MarkSerialsSold/UpdateSerialStatus locally, or the Portal''s Serial Admin location edit / Transfer Order ship-claim / receive-release.';

-- staff_claim_serials_for_transfer_shipment (Ship time, tags IN_TRANSIT) - now also stamps
-- "UpdatedBy" with the acting (already-authorized) staff username, same as the other Portal write
-- paths (releaseReceivedSerials in transferOrders.js, saveEditLocation in serialTracker.js).
drop function if exists public.staff_claim_serials_for_transfer_shipment(text, text, text, text, bigint[]);

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

  v_location := nullif(trim(p_to_warehouse_name), '');

  with claimed as (
    update public."ItemSerialTracking"
      set "Status" = 'IN_TRANSIT',
          "Location" = v_location,
          "SourceDocumentNo" = p_document_no,
          "UpdatedAtUtc" = now(),
          "UpdatedBy" = p_admin_username
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

grant execute on function public.staff_claim_serials_for_transfer_shipment(text, text, text, text, bigint[]) to anon;
