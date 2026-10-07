-- Delivery route change -> phone notification to the delivery team - per "once the delivery route
-- has changed or added or modified can you notify the driver or delivery team on their phone".
--
-- Uses the Portal PWA's existing targeted Web Push (supabase_web_push_targeted.sql's
-- _trigger_web_push + the send-web-push Edge Function) - no new Edge Function or deploy needed.
-- Drivers turn it on from the Delivery page (delivery.html now asks Delivery Team / Dispatcher
-- accounts to enable notifications, same popup makers get on Online Orders).
--
-- Recipients: active StaffUsers with "DeliveryTeam" ticked, or the 'Dispatcher' role.
--
-- What notifies (only when the affected date is today or later, Manila time - edits to past days
-- stay quiet):
--   * DeliveryStops (any writer - calendar Assign/Move/Remove, manual address / print note /
--     customer details, job order note, Alice's chatbot scheduling): stop added, removed, moved
--     to another date, or its address / notes / print note / customer details / stop order /
--     truck changed. Geocode-only updates (the browser caching lat/lng) do NOT notify.
--   * DeliveryDateVendors: a vendor pickup added to / removed from a date.
--   * DeliveryRouteSchedule: a weekday's fixed route name set, renamed or cleared (warehouse /
--     vendor tag-only edits on the weekly schedule don't notify - they're delete+reinsert on
--     every save and would spam).
-- Tapping the notification opens delivery.html?date=YYYY-MM-DD on that day.
--
-- Run AFTER supabase_web_push_targeted.sql, supabase_delivery_tables.sql,
-- supabase_delivery_route_schedule.sql, supabase_delivery_date_vendors.sql and
-- supabase_staff_users_delivery_team_field.sql. Safe to re-run.

-- The trigger reads these manual-detail columns - make sure they exist so this file works even if
-- their own files haven't been run (a missing column would break every stop write).
alter table public."DeliveryStops" add column if not exists "ManualAddress" varchar(1000);
alter table public."DeliveryStops" add column if not exists "ManualNotePrint" varchar(2000);
alter table public."DeliveryStops" add column if not exists "ManualCustomerName" varchar(255);
alter table public."DeliveryStops" add column if not exists "ManualContactNumber" varchar(50);

-- ---------------------------------------------------------------------------
-- 1. Shared sender: delivery team recipients, skip past dates, deep-link to the day.

create or replace function public._notify_delivery_team(p_title text, p_body text, p_date date default null)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_recipients text[];
begin
  -- p_date null = not tied to one day (weekly route change) - always send.
  if p_date is not null and p_date < (now() at time zone 'Asia/Manila')::date then
    return;
  end if;

  select coalesce(array_agg("Username"::text), '{}') into v_recipients
  from public."StaffUsers"
  where "IsActive"
    and (coalesce("DeliveryTeam", false) or 'Dispatcher' = any(coalesce("StaffRoles", '{}')));

  perform public._trigger_web_push(
    p_title, p_body,
    case when p_date is null then 'delivery.html' else 'delivery.html?date=' || to_char(p_date, 'YYYY-MM-DD') end,
    v_recipients);
end;
$$;

revoke all on function public._notify_delivery_team(text, text, date) from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. DeliveryStops: added / removed / moved / modified.

create or replace function public._notify_delivery_stop_changed()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row public."DeliveryStops" := case when TG_OP = 'DELETE' then OLD else NEW end;
  v_customer text;
  v_label text;
  v_changes text[] := '{}';
  v_today date := (now() at time zone 'Asia/Manila')::date;
begin
  select coalesce(nullif(trim(v_row."ManualCustomerName"), ''), nullif(trim(o."WalkinCustomerName"), ''), o."CustomerName")
    into v_customer
  from public."OnlineOrders" o where o."OrderID" = v_row."OrderID";

  v_label := 'Order ' || coalesce(v_row."OrderID", '-') || coalesce(' - ' || nullif(trim(v_customer), ''), '');

  if TG_OP = 'INSERT' then
    perform public._notify_delivery_team('Delivery stop added',
      to_char(NEW."DeliveryDate", 'Dy Mon DD') || ': ' || v_label || coalesce(' (' || nullif(trim(NEW."RouteName"), '') || ')', ''),
      NEW."DeliveryDate");

  elsif TG_OP = 'DELETE' then
    perform public._notify_delivery_team('Delivery stop removed',
      to_char(OLD."DeliveryDate", 'Dy Mon DD') || ': ' || v_label,
      OLD."DeliveryDate");

  elsif NEW."DeliveryDate" is distinct from OLD."DeliveryDate" then
    -- Moved: matters if either side is upcoming; link to the new day if it is, else the old one.
    if greatest(NEW."DeliveryDate", OLD."DeliveryDate") >= v_today then
      perform public._notify_delivery_team('Delivery stop moved',
        v_label || ': ' || to_char(OLD."DeliveryDate", 'Dy Mon DD') || ' -> ' || to_char(NEW."DeliveryDate", 'Dy Mon DD'),
        case when NEW."DeliveryDate" >= v_today then NEW."DeliveryDate" else OLD."DeliveryDate" end);
    end if;

  else
    if NEW."ManualAddress" is distinct from OLD."ManualAddress" then v_changes := array_append(v_changes, 'address'); end if;
    if NEW."Notes" is distinct from OLD."Notes" then v_changes := array_append(v_changes, 'notes'); end if;
    if NEW."ManualNotePrint" is distinct from OLD."ManualNotePrint" then v_changes := array_append(v_changes, 'print note'); end if;
    if NEW."ManualCustomerName" is distinct from OLD."ManualCustomerName"
       or NEW."ManualContactNumber" is distinct from OLD."ManualContactNumber" then v_changes := array_append(v_changes, 'customer details'); end if;
    if NEW."StopSequence" is distinct from OLD."StopSequence" then v_changes := array_append(v_changes, 'stop order'); end if;
    if NEW."TruckID" is distinct from OLD."TruckID" then v_changes := array_append(v_changes, 'truck'); end if;

    -- Nothing driver-facing changed (e.g. geocode cache only) - stay quiet.
    if array_length(v_changes, 1) is not null then
      perform public._notify_delivery_team('Delivery stop updated',
        to_char(NEW."DeliveryDate", 'Dy Mon DD') || ': ' || v_label || ' - ' || array_to_string(v_changes, ', ') || ' changed',
        NEW."DeliveryDate");
    end if;
  end if;

  return null;
end;
$$;

drop trigger if exists trg_notify_delivery_stop_changed on public."DeliveryStops";
create trigger trg_notify_delivery_stop_changed
  after insert or update or delete on public."DeliveryStops"
  for each row
  execute function public._notify_delivery_stop_changed();

-- ---------------------------------------------------------------------------
-- 3. DeliveryDateVendors: vendor pickup added / removed on a date.

create or replace function public._notify_delivery_date_vendor_changed()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row public."DeliveryDateVendors" := case when TG_OP = 'DELETE' then OLD else NEW end;
  v_vendor text;
begin
  select coalesce(nullif(trim(v."Name"), ''), v_row."VendorCode") into v_vendor
  from public."Vendors" v where v."VendorCode" = v_row."VendorCode";

  perform public._notify_delivery_team(
    case when TG_OP = 'DELETE' then 'Vendor pickup removed' else 'Vendor pickup added' end,
    to_char(v_row."DeliveryDate", 'Dy Mon DD') || ': ' || coalesce(v_vendor, v_row."VendorCode"),
    v_row."DeliveryDate");

  return null;
end;
$$;

drop trigger if exists trg_notify_delivery_date_vendor_changed on public."DeliveryDateVendors";
create trigger trg_notify_delivery_date_vendor_changed
  after insert or delete on public."DeliveryDateVendors"
  for each row
  execute function public._notify_delivery_date_vendor_changed();

-- ---------------------------------------------------------------------------
-- 4. DeliveryRouteSchedule: a weekday's fixed route name set / renamed / cleared.

create or replace function public._notify_delivery_route_schedule_changed()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_day smallint := case when TG_OP = 'DELETE' then OLD."DayOfWeek" else NEW."DayOfWeek" end;
  v_day_name text := (array['Sundays', 'Mondays', 'Tuesdays', 'Wednesdays', 'Thursdays', 'Fridays', 'Saturdays'])[v_day + 1];
begin
  if TG_OP = 'UPDATE' and NEW."RouteName" is not distinct from OLD."RouteName" then
    return null;
  end if;

  perform public._notify_delivery_team('Weekly delivery route changed',
    case when TG_OP = 'DELETE' then v_day_name || ': route cleared (was ' || coalesce(OLD."RouteName", '-') || ')'
         when TG_OP = 'INSERT' then v_day_name || ' are now ' || coalesce(NEW."RouteName", '-')
         else v_day_name || ': ' || coalesce(OLD."RouteName", '-') || ' -> ' || coalesce(NEW."RouteName", '-') end,
    null);

  return null;
end;
$$;

drop trigger if exists trg_notify_delivery_route_schedule_changed on public."DeliveryRouteSchedule";
create trigger trg_notify_delivery_route_schedule_changed
  after insert or update or delete on public."DeliveryRouteSchedule"
  for each row
  execute function public._notify_delivery_route_schedule_changed();
