-- Time In / Time Out attendance log, per "can I show it on the main login form.. saying
-- timein timeout" - the Face ID / fingerprint sign-in added in supabase_staff_users_table.sql's
-- companion js/webauthnAuth.js is repurposed on staff-login.html as an actual attendance punch:
-- Face ID identifies which employee is tapping the sensor, and this file records that as a real,
-- timestamped row instead of only logging them into the portal.
--
-- Device lock: per "I want a specific device to be able to do login [time in/out]. How can we
-- distinct that sole device?" - a website has no access to a real hardware id (browsers block
-- IMEI/serial/MAC for privacy), so the only thing that can identify "the one shop phone" is a
-- random id WE issue and store in that phone's localStorage (js/webauthnAuth.js's
-- getOrCreateDeviceId()), registered here by a Super User while physically holding that phone.
-- record_time_punch() below re-checks that id against StaffAuthorizedDevices on every single
-- punch (not just once client-side), so even someone who fakes the client-side check by editing
-- localStorage/JS still can't record a punch from an unauthorized device. Scoped to the Time
-- Clock feature only, per explicit choice - normal portal username/password login from other
-- devices (Online Orders, Delivery, etc.) is untouched.
--
-- Run this AFTER supabase_staff_users_table.sql and supabase_payroll_officer_access.sql
-- (uses is_admin_authorized/is_payroll_authorized below).

create table if not exists public."StaffTimeClockPunches" (
    "Id" bigint generated always as identity primary key,
    "Username" varchar(100) not null references public."StaffUsers"("Username"),
    "PunchType" varchar(10) not null check ("PunchType" in ('In', 'Out')),
    "PunchAtUtc" timestamptz not null default timezone('utc', now())
);

create index if not exists idx_stafftimeclockpunches_username_punchat
    on public."StaffTimeClockPunches" ("Username", "PunchAtUtc" desc);

-- Enable RLS with NO policies - same pattern as StaffUsers: blocks all direct REST access, the
-- only way in is through the SECURITY DEFINER functions below.
alter table public."StaffTimeClockPunches" enable row level security;

create table if not exists public."StaffAuthorizedDevices" (
    "DeviceId" uuid primary key,
    "DeviceLabel" text,
    "AuthorizedByUsername" varchar(100) references public."StaffUsers"("Username"),
    "AuthorizedAtUtc" timestamptz not null default timezone('utc', now())
);

alter table public."StaffAuthorizedDevices" enable row level security;

-- Anon-callable (no credentials needed) - only ever answers true/false about whether a given
-- device id is authorized, nothing sensitive. Used by the login page/change-password page to
-- decide what to show before anyone has typed anything.
create or replace function public.is_time_clock_device_authorized(p_device_id uuid)
returns boolean
language sql
security definer
set search_path = public, extensions
as $$
  select exists (select 1 from public."StaffAuthorizedDevices" where "DeviceId" = p_device_id);
$$;

-- Only a Super User can authorize a device, and only while physically holding it (there is no
-- remote/admin-panel way to authorize a device you aren't looking at).
create or replace function public.authorize_time_clock_device(p_admin_username text, p_admin_password text, p_device_id uuid, p_device_label text default null)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  insert into public."StaffAuthorizedDevices" ("DeviceId", "DeviceLabel", "AuthorizedByUsername")
  values (p_device_id, nullif(trim(p_device_label), ''), p_admin_username)
  on conflict ("DeviceId") do update set "DeviceLabel" = excluded."DeviceLabel";

  return query select true, 'Device authorized.'::text;
end;
$$;

create or replace function public.revoke_time_clock_device(p_admin_username text, p_admin_password text, p_device_id uuid)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  delete from public."StaffAuthorizedDevices" where "DeviceId" = p_device_id;
  return query select true, 'Device revoked.'::text;
end;
$$;

-- Lets a Super User see every authorized device from the backend (answers "how can I know that
-- the device is authorized in the backend" - this is that view).
create or replace function public.admin_list_time_clock_devices(p_admin_username text, p_admin_password text)
returns table(device_id uuid, device_label text, authorized_by_username text, authorized_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "DeviceId", "DeviceLabel", "AuthorizedByUsername"::text, "AuthorizedAtUtc"
    from public."StaffAuthorizedDevices"
    order by "AuthorizedAtUtc" desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- record_time_punch: re-verifies username/password server-side (same as every other RPC in this
-- app - see js/auth.js's comment on why the password is resent every call, not just trusted from
-- a prior login) AND re-verifies the device id against StaffAuthorizedDevices on every call - the
-- client-side gate in js/webauthnAuth.js is just UX, this is the actual enforcement. Refuses
-- back-to-back punches of the same type (e.g. tapping "Time In" twice in a row without a "Time
-- Out" in between) so the log stays a clean alternating history.

drop function if exists public.record_time_punch(text, text, text);

create or replace function public.record_time_punch(p_username text, p_password text, p_punch_type text, p_device_id uuid)
returns table(success boolean, message text, punch_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_password_hash text;
  v_is_active boolean;
  v_last_type text;
  v_now timestamptz := timezone('utc', now());
begin
  if p_punch_type not in ('In', 'Out') then
    return query select false, 'Invalid punch type.'::text, null::timestamptz;
    return;
  end if;

  if not public.is_time_clock_device_authorized(p_device_id) then
    return query select false, 'This device is not authorized for Time In / Time Out.'::text, null::timestamptz;
    return;
  end if;

  select "PasswordHash", "IsActive" into v_password_hash, v_is_active
    from public."StaffUsers"
    where "Username" = p_username;

  if not found or not v_is_active or v_password_hash <> crypt(p_password, v_password_hash) then
    return query select false, 'Invalid username or password.'::text, null::timestamptz;
    return;
  end if;

  select "PunchType" into v_last_type
    from public."StaffTimeClockPunches"
    where "Username" = p_username
    order by "PunchAtUtc" desc
    limit 1;

  if v_last_type = p_punch_type then
    return query select false,
      (case when p_punch_type = 'In' then 'You are already timed in.' else 'You are already timed out.' end)::text,
      null::timestamptz;
    return;
  end if;

  insert into public."StaffTimeClockPunches" ("Username", "PunchType", "PunchAtUtc")
  values (p_username, p_punch_type, v_now);

  return query select true,
    (case when p_punch_type = 'In' then 'Timed in successfully.' else 'Timed out successfully.' end)::text,
    v_now;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_list_time_clock_punches: lets a Super User or Payroll Officer review the attendance log
-- (e.g. to cross-check against Payroll Timesheets' manually-entered hours). Defaults to the last
-- 31 days when no range is given.

create or replace function public.admin_list_time_clock_punches(
  p_admin_username text,
  p_admin_password text,
  p_start_date date default null,
  p_end_date date default null
)
returns table(
  username text,
  display_name text,
  employee_no text,
  punch_type text,
  punch_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select p."Username"::text, u."DisplayName"::text, u."EmployeeNo"::text, p."PunchType"::text, p."PunchAtUtc"
    from public."StaffTimeClockPunches" p
    join public."StaffUsers" u on u."Username" = p."Username"
    where p."PunchAtUtc" >= timezone('utc', coalesce(p_start_date, current_date - interval '31 days'))
      and p."PunchAtUtc" < timezone('utc', coalesce(p_end_date, current_date) + interval '1 day')
    order by p."PunchAtUtc" desc;
end;
$$;

grant execute on function public.record_time_punch(text, text, text, uuid) to anon;
grant execute on function public.admin_list_time_clock_punches(text, text, date, date) to anon;
grant execute on function public.is_time_clock_device_authorized(uuid) to anon;
grant execute on function public.authorize_time_clock_device(text, text, uuid, text) to anon;
grant execute on function public.revoke_time_clock_device(text, text, uuid) to anon;
grant execute on function public.admin_list_time_clock_devices(text, text) to anon;
