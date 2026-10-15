-- Serial history - per "do we have enough guards for the serials?" -> "can we implement the history for now".
--
-- A serial only kept its LAST change (UpdatedAtUtc / UpdatedBy), so when a unit built for an order was sold
-- to a walk-in there was no trail of who took it, when, or from where. Now every change is logged:
--
--   private."ItemSerialTrackingHistory" - one row per insert / delete, and per update that changes a field
--     that matters: Status, Location, item / variant, Sold order / receipt, Reserved-for order, Source doc.
--     (A sync re-saving the same values, or only the timestamp moving, adds nothing.)
--     Each row: old -> new of those fields, UpdatedBy as the writer stamped it, and WHERE it came from:
--       Source  'Portal'               - a portal function (Ready to Ship, Post Output, Reserve, ...)
--               'Web page (direct)'    - a portal page writing the table straight (Serial Tracker Mark In
--                                        Stock / Sold / Edit Location, Transfer Order receive)
--               'POS'                  - the desktop POS sync (anon / service key, no browser)
--               'SQL / scheduled job'  - the Supabase SQL editor or a cron job
--       Via     the PostgREST path when there is one, e.g. /rpc/admin_update_online_order_status or
--               /ItemSerialTracking - so you can tell WHICH portal action did it.
--   Written by an AFTER trigger that is NOT security definer (current_user must be the caller's role -
--   same trick as supabase_serial_tracking_portal_only.sql). The table lives in the "private" schema, so
--   the REST API can't read or forge it; the calling roles only get INSERT.
--   A one-time BASELINE row per existing serial records where things stood when history started.
--
--   staff_get_serial_history(serial_no) - newest first, for the Serial Tracker's serial card.
--
-- Run AFTER supabase_serial_order_reservation.sql (the trigger reads "ReservedForOrderId"). Safe to re-run
-- (the baseline only adds serials that have no history yet). Needs serialTracker.js ?v=history1.

create schema if not exists private;
grant usage on schema private to anon, authenticated, service_role;

create table if not exists private."ItemSerialTrackingHistory" (
  "Id" bigint generated always as identity primary key,
  "ChangedAtUtc" timestamptz not null default now(),
  "Action" varchar(10) not null,              -- INSERT / UPDATE / DELETE / BASELINE
  "RunningSerialNo" bigint,
  "SerialNo" varchar(120),
  "ItemCode" varchar(100),
  "VariantCode" varchar(200),
  "OldStatus" varchar(255),
  "NewStatus" varchar(255),
  "OldLocation" varchar(255),
  "NewLocation" varchar(255),
  "OldSoldOnlineOrderId" varchar(100),
  "NewSoldOnlineOrderId" varchar(100),
  "OldSoldReceiptNo" varchar(100),
  "NewSoldReceiptNo" varchar(100),
  "OldReservedForOrderId" varchar(100),
  "NewReservedForOrderId" varchar(100),
  "OldSourceDocumentNo" varchar(100),
  "NewSourceDocumentNo" varchar(100),
  "UpdatedBy" varchar(200),
  "DbRole" varchar(64),
  "Source" varchar(40),
  "Via" text
);

create index if not exists "IX_ItemSerialTrackingHistory_Serial" on private."ItemSerialTrackingHistory" ("SerialNo", "ChangedAtUtc" desc);
create index if not exists "IX_ItemSerialTrackingHistory_Changed" on private."ItemSerialTrackingHistory" ("ChangedAtUtc" desc);

alter table private."ItemSerialTrackingHistory" enable row level security;
-- Insert-only for the API roles (the trigger runs as them); no select / update / delete.
revoke all on private."ItemSerialTrackingHistory" from anon, authenticated, service_role;
grant insert on private."ItemSerialTrackingHistory" to anon, authenticated, service_role;
drop policy if exists "Trigger insert" on private."ItemSerialTrackingHistory";
create policy "Trigger insert" on private."ItemSerialTrackingHistory"
  for insert to anon, authenticated, service_role with check (true);

create or replace function public._item_serial_history()
returns trigger
language plpgsql
-- NOT security definer on purpose: current_user must be the caller's role (anon / service_role for REST,
-- the owner inside the portal's SECURITY DEFINER functions).
set search_path = public
as $$
declare
  v_path text;
  v_ua text := '';
  v_source text;
begin
  if tg_op = 'UPDATE'
     and new."Status" is not distinct from old."Status"
     and new."Location" is not distinct from old."Location"
     and new."ItemCode" is not distinct from old."ItemCode"
     and new."VariantCode" is not distinct from old."VariantCode"
     and new."SoldOnlineOrderId" is not distinct from old."SoldOnlineOrderId"
     and new."SoldReceiptNo" is not distinct from old."SoldReceiptNo"
     and new."ReservedForOrderId" is not distinct from old."ReservedForOrderId"
     and new."SourceDocumentNo" is not distinct from old."SourceDocumentNo" then
    return null; -- nothing that matters changed
  end if;

  begin
    v_path := nullif(current_setting('request.path', true), '');
    begin
      v_ua := lower(coalesce(nullif(current_setting('request.headers', true), '')::jsonb ->> 'user-agent', ''));
    exception when others then
      v_ua := '';
    end;
    v_source := case
      when current_user in ('anon', 'authenticated') and v_ua like '%mozilla%' then 'Web page (direct)'
      when current_user in ('anon', 'authenticated', 'service_role') then 'POS'
      when v_path is not null then 'Portal'
      else 'SQL / scheduled job'
    end;

    insert into private."ItemSerialTrackingHistory"
      ("Action", "RunningSerialNo", "SerialNo", "ItemCode", "VariantCode",
       "OldStatus", "NewStatus", "OldLocation", "NewLocation",
       "OldSoldOnlineOrderId", "NewSoldOnlineOrderId", "OldSoldReceiptNo", "NewSoldReceiptNo",
       "OldReservedForOrderId", "NewReservedForOrderId", "OldSourceDocumentNo", "NewSourceDocumentNo",
       "UpdatedBy", "DbRole", "Source", "Via")
    values
      (tg_op,
       coalesce(new."RunningSerialNo", old."RunningSerialNo"),
       coalesce(new."SerialNo", old."SerialNo"),
       coalesce(new."ItemCode", old."ItemCode"),
       coalesce(new."VariantCode", old."VariantCode"),
       case when tg_op <> 'INSERT' then old."Status" end, case when tg_op <> 'DELETE' then new."Status" end,
       case when tg_op <> 'INSERT' then old."Location" end, case when tg_op <> 'DELETE' then new."Location" end,
       case when tg_op <> 'INSERT' then old."SoldOnlineOrderId" end, case when tg_op <> 'DELETE' then new."SoldOnlineOrderId" end,
       case when tg_op <> 'INSERT' then old."SoldReceiptNo" end, case when tg_op <> 'DELETE' then new."SoldReceiptNo" end,
       case when tg_op <> 'INSERT' then old."ReservedForOrderId" end, case when tg_op <> 'DELETE' then new."ReservedForOrderId" end,
       case when tg_op <> 'INSERT' then old."SourceDocumentNo" end, case when tg_op <> 'DELETE' then new."SourceDocumentNo" end,
       left(case when tg_op = 'DELETE' then old."UpdatedBy" else coalesce(new."UpdatedBy", new."CreatedBy") end, 200),
       left(current_user, 64), v_source, left(v_path, 500));
  exception when others then
    -- History must never block a real serial change (a sale, a ship, a sync).
    raise warning 'serial history not written for %: %', coalesce(new."SerialNo", old."SerialNo"), sqlerrm;
  end;
  return null;
end;
$$;

drop trigger if exists "TR_ItemSerialTracking_History" on public."ItemSerialTracking";
create trigger "TR_ItemSerialTracking_History"
  after insert or update or delete on public."ItemSerialTracking"
  for each row execute function public._item_serial_history();

-- Where every existing serial stood when history started (once per serial).
insert into private."ItemSerialTrackingHistory"
  ("ChangedAtUtc", "Action", "RunningSerialNo", "SerialNo", "ItemCode", "VariantCode", "NewStatus", "NewLocation",
   "NewSoldOnlineOrderId", "NewSoldReceiptNo", "NewReservedForOrderId", "NewSourceDocumentNo", "UpdatedBy", "DbRole", "Source")
select coalesce(s."UpdatedAtUtc", s."CreatedAtUtc", now()), 'BASELINE', s."RunningSerialNo", s."SerialNo", s."ItemCode", s."VariantCode",
       s."Status", s."Location", s."SoldOnlineOrderId", s."SoldReceiptNo",
       case when s."Status" = 'RESERVED' then s."ReservedForOrderId" end, s."SourceDocumentNo",
       left(coalesce(s."UpdatedBy", s."CreatedBy"), 200), current_user, 'Before history started'
from public."ItemSerialTracking" s
where not exists (select 1 from private."ItemSerialTrackingHistory" h where h."SerialNo" = s."SerialNo");

-- ---------------------------------------------------------------------------
-- Read: one serial's history, newest first (Serial Tracker card).
drop function if exists public.staff_get_serial_history(text, text, text);

create or replace function public.staff_get_serial_history(
  p_admin_username text,
  p_admin_password text,
  p_serial_no text
)
returns table(changed_at timestamptz, action text, old_status text, new_status text,
              old_location text, new_location text, old_order text, new_order text,
              old_receipt text, new_receipt text, old_reserved_for text, new_reserved_for text,
              old_source_doc text, new_source_doc text, updated_by text, source text, via text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select h."ChangedAtUtc", h."Action"::text, h."OldStatus"::text, h."NewStatus"::text,
           h."OldLocation"::text, h."NewLocation"::text, h."OldSoldOnlineOrderId"::text, h."NewSoldOnlineOrderId"::text,
           h."OldSoldReceiptNo"::text, h."NewSoldReceiptNo"::text, h."OldReservedForOrderId"::text, h."NewReservedForOrderId"::text,
           h."OldSourceDocumentNo"::text, h."NewSourceDocumentNo"::text, h."UpdatedBy"::text, h."Source"::text, h."Via"
    from private."ItemSerialTrackingHistory" h
    where h."SerialNo" = trim(coalesce(p_serial_no, ''))
    order by h."ChangedAtUtc" desc, h."Id" desc
    limit 200;
end;
$$;

grant execute on function public.staff_get_serial_history(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'trigger' as section, t.tgname::text as item, (t.tgenabled <> 'D')::text as detail
from pg_trigger t
where t.tgrelid = 'public."ItemSerialTracking"'::regclass and t.tgname = 'TR_ItemSerialTracking_History'
union all
select 'history rows', h."Action"::text, count(*)::text
from private."ItemSerialTrackingHistory" h
group by h."Action"
order by 1, 2;
