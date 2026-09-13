-- Time In / Time Out attendance log, per "can I show it on the main login form.. saying
-- timein timeout" - the Face ID / fingerprint sign-in added in supabase_staff_users_table.sql's
-- companion js/webauthnAuth.js is repurposed on staff-login.html as an actual attendance punch:
-- Face ID identifies which employee is tapping the sensor (via the credential enrolled on that
-- one authorized device - see js/changePassword.js's device-authorization gate), and this file
-- records that as a real, timestamped row instead of only logging them into the portal.
--
-- Run this AFTER supabase_staff_users_table.sql and supabase_payroll_officer_access.sql
-- (uses is_payroll_authorized for the admin listing function below).

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

-- ---------------------------------------------------------------------------
-- record_time_punch: re-verifies username/password server-side (same as every other RPC in this
-- app - see js/auth.js's comment on why the password is resent every call, not just trusted from
-- a prior login). Refuses back-to-back punches of the same type (e.g. tapping "Time In" twice in
-- a row without a "Time Out" in between) so the log stays a clean alternating history.

create or replace function public.record_time_punch(p_username text, p_password text, p_punch_type text)
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

grant execute on function public.record_time_punch(text, text, text) to anon;
grant execute on function public.admin_list_time_clock_punches(text, text, date, date) to anon;
