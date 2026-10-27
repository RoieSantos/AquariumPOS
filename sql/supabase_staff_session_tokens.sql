-- Staff session tokens (2026-10-27) - portal speed fix.
--
-- Every portal RPC re-sent the login password and the database re-checked it with bcrypt
-- (~75 ms of CPU per call). A page like Online Orders makes ~12 calls and the Dashboard ~15, so
-- on the small database most of each call's time was waiting for other calls' bcrypt checks.
--
-- Now: the password is checked once at login (verify_login, unchanged), then staff_create_session
-- hands the browser a random token ('stok_...'). The browser sends that token where it used to
-- send the password - same p_password / p_admin_password parameters, so none of the ~100 RPCs or
-- the Edge Functions change. The password checks inside is_staff_authorized / is_admin_authorized /
-- the other is_*_authorized functions are switched to _staff_secret_ok, which accepts a valid
-- token with a quick indexed lookup and still accepts the real password (bcrypt) otherwise.
--
-- Token rules:
--   - Only a SHA-256 hash of the token is stored, never the token itself.
--   - Valid 24 hours, extended on each page load (staff_refresh_session).
--   - Tied to the password hash at creation: a password change or admin reset ends every session.
--   - A deactivated account stops working at once (the callers still check IsActive).
--
-- Safe to re-run. Step 4 rewrites the LIVE definitions (pg_get_functiondef), so it never brings
-- back an older version of a function from an old .sql file; on a re-run nothing matches any more.
-- verify_login, change_own_password and record_time_punch are left alone - they need the real password.

-- 1. Sessions table - only the security-definer functions below touch it.
create table if not exists public."StaffSessions" (
  "TokenHash"    text primary key,
  "Username"     text not null,
  "PasswordHash" text not null,
  "CreatedAtUtc" timestamptz not null default now(),
  "ExpiresAtUtc" timestamptz not null
);
create index if not exists "StaffSessions_Username_idx" on public."StaffSessions" ("Username");
alter table public."StaffSessions" enable row level security;
revoke all on table public."StaffSessions" from anon, authenticated;

-- 2. The one shared check: session token first (no bcrypt), real password second.
create or replace function public._staff_secret_ok(p_secret text, p_password_hash text)
returns boolean
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if p_secret is null or p_password_hash is null then
    return false;
  end if;

  if left(p_secret, 5) = 'stok_' and exists (
    select 1 from public."StaffSessions" s
    where s."TokenHash" = encode(digest(p_secret, 'sha256'), 'hex')
      and s."PasswordHash" = p_password_hash
      and s."ExpiresAtUtc" > now()
  ) then
    return true;
  end if;

  return p_password_hash = crypt(p_secret, p_password_hash);
end;
$$;

-- 3. Session lifecycle.

-- Called right after a successful verify_login. Re-checks the password (same lockout rules as
-- verify_login, so it can't be used to guess passwords) and returns a new token, or null.
create or replace function public.staff_create_session(p_username text, p_password text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_password_hash text;
  v_is_active boolean;
  v_locked_until timestamptz;
  v_token text;
begin
  select "PasswordHash", "IsActive", "LockedUntilUtc"
    into v_password_hash, v_is_active, v_locked_until
    from public."StaffUsers"
    where "Username" = p_username;

  if not found or not v_is_active or (v_locked_until is not null and v_locked_until > now()) then
    return null;
  end if;

  if p_password is null or left(p_password, 5) = 'stok_'
     or v_password_hash is distinct from crypt(p_password, v_password_hash) then
    update public."StaffUsers"
      set "FailedAttempts" = "FailedAttempts" + 1,
          "LockedUntilUtc" = case when "FailedAttempts" + 1 >= 5 then now() + interval '15 minutes' else "LockedUntilUtc" end
      where "Username" = p_username;
    return null;
  end if;

  -- Housekeeping: drop expired sessions (the table stays tiny).
  delete from public."StaffSessions" where "ExpiresAtUtc" < now();

  v_token := 'stok_' || encode(gen_random_bytes(24), 'hex');
  insert into public."StaffSessions" ("TokenHash", "Username", "PasswordHash", "ExpiresAtUtc")
  values (encode(digest(v_token, 'sha256'), 'hex'), p_username, v_password_hash, now() + interval '24 hours');
  return v_token;
end;
$$;

-- Page-load re-check (auth.js refreshPortalSession) for a token session - the same row shape as
-- verify_login, so the browser picks up permission changes on the next page. Accepts ONLY tokens
-- (never passwords, so no bcrypt and no way around verify_login's lockout), doesn't touch
-- FailedAttempts, and slides the 24 h expiry forward at most once an hour.
create or replace function public.staff_refresh_session(p_username text, p_token text)
returns table(success boolean, display_name text, warehouse_name text, is_super_user boolean, is_sales_user boolean, is_serial_admin boolean, is_delivery_team boolean, is_online_order_staff boolean, is_production_member boolean, is_payroll_officer boolean, is_store_manager boolean, is_conversations_staff boolean, must_change_password boolean, message text, staff_roles text[])
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_token_hash text := encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
  v_expires timestamptz;
begin
  select s."ExpiresAtUtc" into v_expires
    from public."StaffSessions" s
    join public."StaffUsers" u on u."Username" = s."Username" and u."PasswordHash" = s."PasswordHash"
    where s."TokenHash" = v_token_hash
      and s."Username" = p_username
      and s."ExpiresAtUtc" > now()
      and u."IsActive";

  if not found or left(coalesce(p_token, ''), 5) <> 'stok_' then
    return query select false, null::text, null::text, false, false, false, false, false, false, false, false, false, false, 'Session expired. Please sign in again.'::text, '{}'::text[];
    return;
  end if;

  if v_expires < now() + interval '23 hours' then
    update public."StaffSessions" set "ExpiresAtUtc" = now() + interval '24 hours' where "TokenHash" = v_token_hash;
  end if;

  return query
  select true, u."DisplayName"::text, u."WarehouseName"::text,
         coalesce(u."SuperUser", false), coalesce(u."SalesUser", false), coalesce(u."SerialAdmin", false),
         coalesce(u."DeliveryTeam", false), coalesce(u."OnlineOrderStaff", false), coalesce(u."ProductionMember", false),
         coalesce(u."PayrollOfficer", false), coalesce(u."StoreManager", false), coalesce(u."ConversationsStaff", false),
         coalesce(u."MustChangePassword", false), 'OK'::text, coalesce(u."StaffRoles", '{}'::text[])
  from public."StaffUsers" u
  where u."Username" = p_username;
end;
$$;

grant execute on function public.staff_create_session(text, text) to anon, authenticated;
grant execute on function public.staff_refresh_session(text, text) to anon, authenticated;

-- 4. Switch every live password check (is_staff_authorized, is_admin_authorized, is_conversations_
-- authorized, ...) to _staff_secret_ok - in place, from the live definition.
do $$
declare
  r record;
  v_def text;
begin
  for r in
    select p.oid, p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
    where p.prosrc like '%v_password_hash = crypt(p_password, v_password_hash)%'
      and p.proname not in ('verify_login', '_staff_secret_ok')
  loop
    v_def := pg_get_functiondef(r.oid);
    v_def := replace(v_def, 'v_password_hash = crypt(p_password, v_password_hash)',
                            'public._staff_secret_ok(p_password, v_password_hash)');
    execute v_def;
    raise notice 'Switched % to session tokens', r.proname;
  end loop;
end;
$$;

-- Result: every function that now accepts session tokens (should list is_staff_authorized,
-- is_admin_authorized and the other is_*_authorized checks), plus any still doing bcrypt directly.
select 'accepts session tokens' as section, p.proname::text as function_name
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
where p.prosrc like '%_staff_secret_ok(p_password, v_password_hash)%'
union all
select 'still password-only (expected: verify_login, change_own_password, record_time_punch, hash helpers)', p.proname::text
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
where p.prosrc like '%crypt(%'
  and p.prosrc not like '%_staff_secret_ok(p_password, v_password_hash)%'
  and p.proname not in ('_staff_secret_ok', 'staff_create_session')
order by 1, 2;
