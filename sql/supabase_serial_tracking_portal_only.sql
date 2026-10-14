-- Serials are created in the Web Portal only - per "yes all local pos dont create serials.. only in
-- the portal can" and "will it sure that we are not creating serial in local POS? even if is
-- production local POS".
--
-- Lock 1 is in the POS itself: the new build has no code that creates a serial anymore
-- (ProductSerialTrackingForm.CreateSerialRecords / CreateSoldSerialRecords were removed). This file is
-- Lock 2, for any POS still running an OLD build (which can still create serials at a production
-- warehouse and push them up):
--
--   BEFORE INSERT trigger on "ItemSerialTracking": a NEW serial (SerialNo not already in the cloud)
--   inserted straight through the REST API - the role the POS pushes as (anon, or service_role when
--   the machine has AQUARIUMPOS_SUPABASE_SERVICE_ROLE_KEY set), or authenticated - is dropped (the
--   insert silently does nothing, so the old POS marks it synced and stops retrying) and logged in
--   private."ItemSerialTrackingPosRejected" so you can see which store is still on an old build.
--
-- NOT affected:
--   - Updates to existing serials from the POS (e.g. marking a serial SOLD at a sale) - those are PATCHes,
--     not inserts, and the POS only POSTs a serial the cloud doesn't have yet.
--   - The portal: Production Orders > Post Output, Online/Advance Order To Ship, the Serial Inventory
--     Journal all create serials inside SECURITY DEFINER functions, which run as the function owner
--     (postgres), not as anon/service_role - checked: no portal page inserts into the table directly.
--   - The SQL editor (runs as postgres).
--
-- Rejected rows only exist in that one POS's local database and never sync anywhere. To review them,
-- run supabase_check_serial_pos_rejected.sql.
--
-- Run AFTER supabase_item_serial_tracking.sql. Safe to re-run.

create schema if not exists private;

-- Log of serials an (old-build) POS tried to create. In the "private" schema so the REST API can't
-- read or write it directly; the trigger inserts as the calling role, so those roles get INSERT only.
create table if not exists private."ItemSerialTrackingPosRejected" (
  "Id" bigint generated always as identity primary key,
  "RejectedAtUtc" timestamptz not null default now(),
  "DbRole" text not null,
  "SerialNo" text,
  "ItemCode" text,
  "VariantCode" text,
  "Location" text,
  "Status" text,
  "SourceDocumentNo" text,
  "CreatedBy" text,
  "Row" jsonb not null
);

grant usage on schema private to anon, authenticated, service_role;
grant insert on private."ItemSerialTrackingPosRejected" to anon, authenticated, service_role;

create or replace function public._item_serial_portal_only_insert()
returns trigger
language plpgsql
-- NOT security definer on purpose: current_user must be the caller's role. Inside the portal's
-- SECURITY DEFINER functions it's the owner (postgres); a direct REST insert is anon/service_role.
set search_path = public
as $$
begin
  if current_user in ('anon', 'authenticated', 'service_role')
     and not exists (select 1 from public."ItemSerialTracking" s where s."SerialNo" = new."SerialNo") then
    insert into private."ItemSerialTrackingPosRejected"
      ("DbRole", "SerialNo", "ItemCode", "VariantCode", "Location", "Status", "SourceDocumentNo", "CreatedBy", "Row")
    values
      (current_user, new."SerialNo", new."ItemCode", new."VariantCode", new."Location", new."Status",
       new."SourceDocumentNo", new."CreatedBy", to_jsonb(new));
    return null; -- drop the row
  end if;
  return new;
end;
$$;

drop trigger if exists "TR_ItemSerialTracking_PortalOnlyInsert" on public."ItemSerialTracking";
create trigger "TR_ItemSerialTracking_PortalOnlyInsert"
  before insert on public."ItemSerialTracking"
  for each row execute function public._item_serial_portal_only_insert();

-- Confirms the trigger is in place (one row).
select t.tgname as trigger_name,
       t.tgenabled <> 'D' as enabled,
       (select count(*) from private."ItemSerialTrackingPosRejected") as rejected_so_far
from pg_trigger t
where t.tgrelid = 'public."ItemSerialTracking"'::regclass
  and t.tgname = 'TR_ItemSerialTracking_PortalOnlyInsert';
