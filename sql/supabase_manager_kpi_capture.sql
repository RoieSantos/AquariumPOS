-- Manager KPI - data capture (per the "Manager KPI Scorecard System Requirements"). Records the things the KPI
-- needs that the system didn't keep before; history only builds from the day this is run:
--
--   1. InventoryCountLog - every counted line when a Physical / Serial Inventory Journal is POSTED (expected,
--      counted, difference). Posting deletes the journal lines and only writes ledger entries for lines that
--      differed, so "correct counts / total counted" (Inventory Accuracy) was impossible without this.
--      The two live posting functions are patched IN PLACE from their live definition (same approach as
--      supabase_staff_session_tokens.sql) - one insert added per posted line, nothing else changes.
--   2. StaffStatusLog - a row whenever a staff member's IsActive / WarehouseName / StoreManager changes, plus a
--      baseline row per staff now. Needed for Employee Retention (who was on the team at the start of a month).
--   3. BranchChecklistEntries - the daily Opening / Closing / Store Cleaning checklist, one per branch per day,
--      each with a required photo (public bucket "branch-checklist-photos", same signed-upload flow as Defect
--      Items). Store Managers submit for their own branch, for TODAY only (no back-dating); Super Users can
--      submit for any branch today and remove a wrong entry.
--   4. ManagerLeadershipRatings - the owner's monthly 1-5 rating of each branch manager on 6 areas.
--   5. ManagerKpiSettings - the date each log started, so months before it show "no data" instead of a fail.
--
-- Run BEFORE supabase_manager_kpi.sql. Safe to re-run. Ends with ONE result.

-- ============================================================================
-- 0. Settings + shared caller check
-- ============================================================================

create table if not exists public."ManagerKpiSettings" (
  "Key" text primary key,
  "Value" text not null,
  "UpdatedAtUtc" timestamptz not null default now()
);
alter table public."ManagerKpiSettings" enable row level security;
revoke all on table public."ManagerKpiSettings" from anon, authenticated;

insert into public."ManagerKpiSettings" ("Key", "Value")
values ('COUNT_LOG_START', ((now() at time zone 'Asia/Manila')::date)::text),
       ('STAFF_LOG_START', ((now() at time zone 'Asia/Manila')::date)::text),
       ('CHECKLIST_START', ((now() at time zone 'Asia/Manila')::date)::text)
on conflict ("Key") do nothing;

-- Who is calling: Super User (any branch) or Store Manager (own branch). Raises otherwise.
create or replace function public._kpi_caller(p_username text, p_password text)
returns table(is_super boolean, is_manager boolean, branch text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;
  return query
    select coalesce(s."SuperUser", false), coalesce(s."StoreManager", false), nullif(trim(s."WarehouseName"), '')::text
    from public."StaffUsers" s
    where s."Username" = p_username and coalesce(s."IsActive", true)
      and (coalesce(s."SuperUser", false) or coalesce(s."StoreManager", false));
  if not found then
    raise exception 'Not authorized.';
  end if;
end;
$$;
revoke all on function public._kpi_caller(text, text) from public, anon, authenticated;

-- ============================================================================
-- 1. Inventory count log + patch the two posting functions
-- ============================================================================

create table if not exists public."InventoryCountLog" (
  "Id" bigserial primary key,
  "Journal" text not null,              -- 'Phys' / 'Serial'
  "DocumentNo" text,
  "PostingDate" date not null,
  "WarehouseId" text not null,
  "ItemCode" text not null,
  "VariantId" text,
  "QtyExpected" numeric not null,
  "QtyCounted" numeric not null,
  "Difference" numeric not null,
  "PostedBy" text,
  "PostedAtUtc" timestamptz not null default now()
);
create index if not exists "InventoryCountLog_wh_date_idx" on public."InventoryCountLog" ("WarehouseId", "PostingDate");
alter table public."InventoryCountLog" enable row level security;
revoke all on table public."InventoryCountLog" from anon, authenticated;

do $$
declare
  v_def text;
  v_marker constant text := 'v_ids := v_ids || v_row.line_id;';
begin
  -- Physical Inventory Journal
  v_def := pg_get_functiondef('public.admin_post_phys_inventory_journal(text, text, text, date, text, boolean)'::regprocedure);
  if position('InventoryCountLog' in v_def) = 0 then
    if (length(v_def) - length(replace(v_def, v_marker, ''))) / length(v_marker) <> 1 then
      raise exception 'admin_post_phys_inventory_journal changed shape - patch it by hand.';
    end if;
    v_def := replace(v_def, v_marker,
      'insert into public."InventoryCountLog" ("Journal", "DocumentNo", "PostingDate", "WarehouseId", "ItemCode", "VariantId", "QtyExpected", "QtyCounted", "Difference", "PostedBy")
      values (''Phys'', v_doc_no, coalesce(p_posting_date, public._ile_today()), v_row.warehouse_id, v_row.item_code, v_row.variant_id,
              v_row.qty_counted - coalesce(v_row.quantity, 0), v_row.qty_counted, coalesce(v_row.quantity, 0), p_admin_username);
      ' || v_marker);
    execute v_def;
  end if;

  -- Serial Inventory Journal
  v_def := pg_get_functiondef('public.admin_post_serial_inventory_journal(text, text, text, date, text, boolean)'::regprocedure);
  if position('InventoryCountLog' in v_def) = 0 then
    if (length(v_def) - length(replace(v_def, v_marker, ''))) / length(v_marker) <> 1 then
      raise exception 'admin_post_serial_inventory_journal changed shape - patch it by hand.';
    end if;
    v_def := replace(v_def, v_marker,
      'insert into public."InventoryCountLog" ("Journal", "DocumentNo", "PostingDate", "WarehouseId", "ItemCode", "VariantId", "QtyExpected", "QtyCounted", "Difference", "PostedBy")
      values (''Serial'', v_doc_no, coalesce(p_posting_date, public._ile_today()), v_row.warehouse_id, v_row.item_code, v_row.variant_id,
              coalesce(v_row.qty_ledger, 0), v_row.qty_counted, coalesce(v_row.ledger_quantity, 0), p_admin_username);
      ' || v_marker);
    execute v_def;
  end if;
end;
$$;

-- ============================================================================
-- 2. Staff status log
-- ============================================================================

create table if not exists public."StaffStatusLog" (
  "Id" bigserial primary key,
  "Username" text not null,
  "IsActive" boolean not null,
  "WarehouseName" text,
  "StoreManager" boolean not null default false,
  "Reason" text not null,               -- 'Baseline' / 'Created' / 'Changed'
  "ChangedAtUtc" timestamptz not null default now()
);
create index if not exists "StaffStatusLog_user_idx" on public."StaffStatusLog" ("Username", "ChangedAtUtc");
alter table public."StaffStatusLog" enable row level security;
revoke all on table public."StaffStatusLog" from anon, authenticated;

create or replace function public._staff_status_log_trg()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if tg_op = 'INSERT'
     or new."IsActive" is distinct from old."IsActive"
     or nullif(trim(new."WarehouseName"), '') is distinct from nullif(trim(old."WarehouseName"), '')
     or coalesce(new."StoreManager", false) is distinct from coalesce(old."StoreManager", false) then
    insert into public."StaffStatusLog" ("Username", "IsActive", "WarehouseName", "StoreManager", "Reason")
    values (new."Username", coalesce(new."IsActive", true), nullif(trim(new."WarehouseName"), ''), coalesce(new."StoreManager", false),
            case when tg_op = 'INSERT' then 'Created' else 'Changed' end);
  end if;
  return new;
end;
$$;

drop trigger if exists staff_status_log on public."StaffUsers";
create trigger staff_status_log
  after insert or update on public."StaffUsers"
  for each row execute function public._staff_status_log_trg();

insert into public."StaffStatusLog" ("Username", "IsActive", "WarehouseName", "StoreManager", "Reason")
select s."Username", coalesce(s."IsActive", true), nullif(trim(s."WarehouseName"), ''), coalesce(s."StoreManager", false), 'Baseline'
from public."StaffUsers" s
where not exists (select 1 from public."StaffStatusLog" l where l."Username" = s."Username");

-- ============================================================================
-- 3. Daily branch checklist (Opening / Closing / Store Cleaning) with photo
-- ============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('branch-checklist-photos', 'branch-checklist-photos', true, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create table if not exists public."BranchChecklistEntries" (
  "Id" bigserial primary key,
  "Warehouse" text not null,
  "CheckDate" date not null,
  "ChecklistType" text not null check ("ChecklistType" in ('Opening', 'Closing', 'Cleaning')),
  "PhotoPath" text not null,
  "PhotoUrl" text not null,
  "Note" text,
  "DoneBy" text not null,
  "DoneAtUtc" timestamptz not null default now(),
  unique ("Warehouse", "CheckDate", "ChecklistType")
);
alter table public."BranchChecklistEntries" enable row level security;
revoke all on table public."BranchChecklistEntries" from anon, authenticated;

-- The branch a caller may act on: Store Manager = own branch only; Super User = the one asked for.
create or replace function public._kpi_branch_for(p_username text, p_password text, p_warehouse text)
returns text
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_wh text;
begin
  select * into c from public._kpi_caller(p_username, p_password);
  if c.is_super then
    v_wh := nullif(trim(p_warehouse), '');
    if v_wh is null then
      raise exception 'Pick a branch.';
    end if;
    if not exists (select 1 from public."Warehouses" w where trim(w."Name") = v_wh) then
      raise exception 'Unknown branch: %', v_wh;
    end if;
    return v_wh;
  end if;
  if c.branch is null then
    raise exception 'Your account has no branch set - ask a Super User to set your branch in User Setup.';
  end if;
  return c.branch;
end;
$$;
revoke all on function public._kpi_branch_for(text, text, text) from public, anon, authenticated;

drop function if exists public.staff_create_checklist_photo_upload(text, text, text);

create or replace function public.staff_create_checklist_photo_upload(
  p_admin_username text,
  p_admin_password text,
  p_file_name text
)
returns table(storage_path text, upload_token text, public_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bucket text := 'branch-checklist-photos';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text;
  v_safe_name text;
  v_path text;
  v_response extensions.http_response;
  v_body jsonb;
  v_token text;
begin
  perform 1 from public._kpi_caller(p_admin_username, p_admin_password);

  select decrypted_secret into v_service_role_key
  from vault.decrypted_secrets where name = 'supabase_service_role_key' limit 1;
  if v_service_role_key is null or trim(v_service_role_key) = '' then
    raise exception 'Vault secret "supabase_service_role_key" is not configured - see supabase_configure_service_role_key.sql.';
  end if;

  v_safe_name := regexp_replace(coalesce(nullif(trim(p_file_name), ''), 'photo.jpg'), '[^A-Za-z0-9._-]+', '_', 'g');
  v_path := to_char(now() at time zone 'utc', 'YYYYMMDD') || '/' || to_char(now() at time zone 'utc', 'HH24MISSMS') || '_' || v_safe_name;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
  select * into v_response from extensions.http((
    'POST',
    v_base_url || '/storage/v1/object/upload/sign/' || v_bucket || '/' || v_path,
    array[extensions.http_header('Authorization', 'Bearer ' || v_service_role_key),
          extensions.http_header('apikey', v_service_role_key)],
    'application/json',
    '{}'
  )::extensions.http_request);

  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Could not prepare photo upload (HTTP %): %', v_response.status, v_response.content;
  end if;

  v_body := v_response.content::jsonb;
  v_token := coalesce(nullif(v_body ->> 'token', ''), nullif(split_part(coalesce(v_body ->> 'url', ''), 'token=', 2), ''));
  if v_token is null or v_token = '' then
    raise exception 'Storage did not return an upload token.';
  end if;

  storage_path := v_path;
  upload_token := v_token;
  public_url := v_base_url || '/storage/v1/object/public/' || v_bucket || '/' || v_path;
  return next;
end;
$$;

grant execute on function public.staff_create_checklist_photo_upload(text, text, text) to anon;

-- Tick one checklist for TODAY (Manila) with its photo. Re-submitting replaces the photo / note.
drop function if exists public.staff_submit_branch_checklist(text, text, text, text, text, text, text);

create or replace function public.staff_submit_branch_checklist(
  p_admin_username text,
  p_admin_password text,
  p_warehouse text,
  p_type text,
  p_photo_path text,
  p_photo_url text,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_wh text := public._kpi_branch_for(p_admin_username, p_admin_password, p_warehouse);
  v_today date := (now() at time zone 'Asia/Manila')::date;
begin
  if p_type not in ('Opening', 'Closing', 'Cleaning') then
    raise exception 'Unknown checklist: %', p_type;
  end if;
  if nullif(trim(p_photo_path), '') is null or nullif(trim(p_photo_url), '') is null then
    raise exception 'A photo is required.';
  end if;
  if p_photo_url not like 'https://hymcmesqgpliyyeghpgq.supabase.co/storage/v1/object/public/branch-checklist-photos/%' then
    raise exception 'Invalid photo.';
  end if;

  insert into public."BranchChecklistEntries" ("Warehouse", "CheckDate", "ChecklistType", "PhotoPath", "PhotoUrl", "Note", "DoneBy")
  values (v_wh, v_today, p_type, p_photo_path, p_photo_url, nullif(trim(p_note), ''), p_admin_username)
  on conflict ("Warehouse", "CheckDate", "ChecklistType") do update
    set "PhotoPath" = excluded."PhotoPath", "PhotoUrl" = excluded."PhotoUrl", "Note" = excluded."Note",
        "DoneBy" = excluded."DoneBy", "DoneAtUtc" = now();
end;
$$;

grant execute on function public.staff_submit_branch_checklist(text, text, text, text, text, text, text) to anon;

-- A month of checklist entries for one branch, plus the days the branch was open (had a sale or a POS
-- end-of-day) - those are the days a checklist is required.
drop function if exists public.staff_get_branch_checklist(text, text, date, text);

create or replace function public.staff_get_branch_checklist(
  p_admin_username text,
  p_admin_password text,
  p_month date,
  p_warehouse text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_wh text;
  v_from date := date_trunc('month', coalesce(p_month, (now() at time zone 'Asia/Manila')::date))::date;
  v_to date;
begin
  select * into c from public._kpi_caller(p_admin_username, p_admin_password);
  if c.is_super and nullif(trim(p_warehouse), '') is null then
    -- Super User with no branch picked: their own branch if set, else the first selling branch.
    v_wh := coalesce(c.branch, (select min(trim(w."Name")) from public."Warehouses" w
                                where trim(w."Name") not ilike 'TESTING%' and trim(w."Name") <> 'Warehouse'));
  else
    v_wh := public._kpi_branch_for(p_admin_username, p_admin_password, p_warehouse);
  end if;
  v_to := (v_from + interval '1 month')::date;

  return jsonb_build_object(
    'branch', v_wh,
    'month', v_from,
    'today', (now() at time zone 'Asia/Manila')::date,
    'can_pick_branch', c.is_super,
    'branches', case when c.is_super then coalesce((
        select jsonb_agg(n order by n) from (select distinct trim(w."Name") as n from public."Warehouses" w
                                             where trim(w."Name") not ilike 'TESTING%') z), '[]'::jsonb)
      else jsonb_build_array(v_wh) end,
    'checklist_start', (select "Value" from public."ManagerKpiSettings" where "Key" = 'CHECKLIST_START'),
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object('date', e."CheckDate", 'type', e."ChecklistType", 'photo_url', e."PhotoUrl",
                                          'note', e."Note", 'done_by', coalesce(s."DisplayName", e."DoneBy"), 'done_at', e."DoneAtUtc")
                       order by e."CheckDate", e."ChecklistType")
      from public."BranchChecklistEntries" e
      left join public."StaffUsers" s on s."Username" = e."DoneBy"
      where e."Warehouse" = v_wh and e."CheckDate" >= v_from and e."CheckDate" < v_to), '[]'::jsonb),
    'open_days', coalesce((select jsonb_agg(d order by d) from public._kpi_open_days(v_wh, v_from, v_to) d), '[]'::jsonb),
    'eod_days', coalesce((
      select jsonb_agg(distinct h."DeclDate") from public."TenderDeclarationHeader" h
      where trim(h."Warehouse") = v_wh and h."DeclDate" >= v_from and h."DeclDate" < v_to), '[]'::jsonb)
  );
end;
$$;

-- Days a branch was open in [p_from, p_to): a sale (walk-in or online) or a POS end-of-day declaration.
create or replace function public._kpi_open_days(p_wh text, p_from date, p_to date)
returns setof date
language sql
stable
security definer
set search_path = public, extensions
as $$
  select distinct d from (
    select case when o."ReceivedAtShop" is true then o."Date"
                else coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") end as d
    from public."OnlineOrders" o
    join public."Warehouses" w on w."ID" = o."LocationID"
    where trim(w."Name") = p_wh and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      and o."Date" >= p_from - 7 and o."Date" < p_to + 7
    union
    select h."DeclDate" from public."TenderDeclarationHeader" h
    where trim(h."Warehouse") = p_wh and h."DeclDate" >= p_from and h."DeclDate" < p_to
  ) x
  where d >= p_from and d < p_to and d <= (now() at time zone 'Asia/Manila')::date;
$$;
revoke all on function public._kpi_open_days(text, date, date) from public, anon, authenticated;

grant execute on function public.staff_get_branch_checklist(text, text, date, text) to anon;

-- Super User: remove a wrong / fake checklist entry.
drop function if exists public.admin_delete_branch_checklist(text, text, text, date, text);

create or replace function public.admin_delete_branch_checklist(
  p_admin_username text,
  p_admin_password text,
  p_warehouse text,
  p_date date,
  p_type text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  delete from public."BranchChecklistEntries"
  where "Warehouse" = trim(p_warehouse) and "CheckDate" = p_date and "ChecklistType" = p_type;
end;
$$;

grant execute on function public.admin_delete_branch_checklist(text, text, text, date, text) to anon;

-- ============================================================================
-- 4. Leadership ratings (owner, monthly, per branch manager)
-- ============================================================================

create table if not exists public."ManagerLeadershipRatings" (
  "Month" date not null,
  "Warehouse" text not null,
  "ManagerUsername" text,
  "ProblemSolving" smallint not null check ("ProblemSolving" between 1 and 5),
  "DecisionMaking" smallint not null check ("DecisionMaking" between 1 and 5),
  "TeamCoaching" smallint not null check ("TeamCoaching" between 1 and 5),
  "ProcessImprovement" smallint not null check ("ProcessImprovement" between 1 and 5),
  "CustomerHandling" smallint not null check ("CustomerHandling" between 1 and 5),
  "Initiative" smallint not null check ("Initiative" between 1 and 5),
  "Notes" text,
  "RatedBy" text,
  "RatedAtUtc" timestamptz not null default now(),
  primary key ("Month", "Warehouse")
);
alter table public."ManagerLeadershipRatings" enable row level security;
revoke all on table public."ManagerLeadershipRatings" from anon, authenticated;

drop function if exists public.admin_set_leadership_rating(text, text, date, text, jsonb);

create or replace function public.admin_set_leadership_rating(
  p_admin_username text,
  p_admin_password text,
  p_month date,
  p_warehouse text,
  p_rating jsonb   -- {problem_solving, decision_making, team_coaching, process_improvement, customer_handling, initiative, notes}
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_month date := date_trunc('month', p_month)::date;
  v_wh text := nullif(trim(p_warehouse), '');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_month is null or v_wh is null then
    raise exception 'Pick a month and a branch.';
  end if;

  insert into public."ManagerLeadershipRatings"
    ("Month", "Warehouse", "ManagerUsername", "ProblemSolving", "DecisionMaking", "TeamCoaching",
     "ProcessImprovement", "CustomerHandling", "Initiative", "Notes", "RatedBy", "RatedAtUtc")
  values (v_month, v_wh, public._kpi_branch_manager(v_wh),
          (p_rating->>'problem_solving')::smallint, (p_rating->>'decision_making')::smallint, (p_rating->>'team_coaching')::smallint,
          (p_rating->>'process_improvement')::smallint, (p_rating->>'customer_handling')::smallint, (p_rating->>'initiative')::smallint,
          nullif(trim(p_rating->>'notes'), ''), p_admin_username, now())
  on conflict ("Month", "Warehouse") do update
    set "ManagerUsername" = excluded."ManagerUsername", "ProblemSolving" = excluded."ProblemSolving",
        "DecisionMaking" = excluded."DecisionMaking", "TeamCoaching" = excluded."TeamCoaching",
        "ProcessImprovement" = excluded."ProcessImprovement", "CustomerHandling" = excluded."CustomerHandling",
        "Initiative" = excluded."Initiative", "Notes" = excluded."Notes", "RatedBy" = excluded."RatedBy", "RatedAtUtc" = now();
end;
$$;

grant execute on function public.admin_set_leadership_rating(text, text, date, text, jsonb) to anon;

-- An employee (vs a shared store login / test account): on a payroll run or has a timesheet.
create or replace function public._kpi_is_employee(p_username text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select exists (select 1 from public."PayrollRunLines" l where l."Username" = p_username)
      or exists (select 1 from public."PayrollTimesheetEntries" t where t."Username" = p_username);
$$;
revoke all on function public._kpi_is_employee(text) from public, anon, authenticated;

-- The branch's manager: the active Store Manager(s) set to that branch who are real employees.
create or replace function public._kpi_branch_manager(p_wh text)
returns text
language sql
stable
security definer
set search_path = public, extensions
as $$
  select string_agg(s."Username", ', ' order by s."Username")
  from public."StaffUsers" s
  where coalesce(s."StoreManager", false) and coalesce(s."IsActive", true)
    and trim(s."WarehouseName") = p_wh and public._kpi_is_employee(s."Username");
$$;
revoke all on function public._kpi_branch_manager(text) from public, anon, authenticated;

notify pgrst, 'reload schema';

-- Check - one result.
select 'count log on Phys journal post' as section,
       case when pg_get_functiondef('public.admin_post_phys_inventory_journal(text, text, text, date, text, boolean)'::regprocedure) like '%InventoryCountLog%'
            then 'patched' else 'NOT PATCHED' end as value
union all
select 'count log on Serial journal post',
       case when pg_get_functiondef('public.admin_post_serial_inventory_journal(text, text, text, date, text, boolean)'::regprocedure) like '%InventoryCountLog%'
            then 'patched' else 'NOT PATCHED' end
union all
select 'staff status log baseline rows', (select count(*)::text from public."StaffStatusLog" where "Reason" = 'Baseline')
union all
select 'checklist photo bucket', case when exists (select 1 from storage.buckets where id = 'branch-checklist-photos') then 'ready' else 'MISSING' end
union all
select 'logs started', (select string_agg("Key" || '=' || "Value", ', ' order by "Key") from public."ManagerKpiSettings")
union all
select 'branch managers', (select string_agg(n || ': ' || coalesce(public._kpi_branch_manager(n), '(none)'), '; ' order by n)
                           from (select distinct trim("Name") as n from public."Warehouses" where trim("Name") not ilike 'TESTING%') z);
