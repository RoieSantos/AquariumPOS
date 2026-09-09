-- Generic "No. Series" running-number setup (NAV/Business Central style), edited from General
-- Setup (js/generalSetup.js). A series defines a Prefix + zero-padding + Starting No.; the actual
-- last-issued number is tracked separately per series in NoSeriesLine, scoped by an arbitrary
-- ScopeKey (e.g. a warehouse name) when the series is flagged WarehouseScoped - each distinct
-- scope gets its own independent counter, e.g. Transfer Order numbering restarts at the series'
-- Starting No. for every destination warehouse.
--
-- Ships with one seeded series, 'TRANSFER-ORDER' (Prefix 'TR-', Padding 4, Starting No. 1,
-- WarehouseScoped true), replacing the Transfer Order number's previous approach of scanning
-- Transfer_Header for the current max under a prefix (see staff_next_transfer_no in
-- supabase_warehouses_items_tables.sql, which now delegates to _next_no_series_number below).
-- Run this file before/alongside supabase_warehouses_items_tables.sql.

create table if not exists public."NoSeries" (
    "SeriesCode" varchar(50) primary key,
    "Description" varchar(200),
    "Prefix" varchar(20) not null default '',
    "Padding" smallint not null default 4,
    "StartingNo" int not null default 1,
    "WarehouseScoped" boolean not null default false,
    "UpdatedBy" varchar(100),
    "UpdatedAtUtc" timestamptz not null default now()
);

create table if not exists public."NoSeriesLine" (
    "SeriesCode" varchar(50) not null references public."NoSeries"("SeriesCode") on delete cascade,
    "ScopeKey" varchar(200) not null default '',
    "LastNo" int not null default 0,
    primary key ("SeriesCode", "ScopeKey")
);

alter table public."NoSeries" enable row level security;
alter table public."NoSeriesLine" enable row level security;
revoke all on public."NoSeries" from anon, authenticated;
revoke all on public."NoSeriesLine" from anon, authenticated;

insert into public."NoSeries" ("SeriesCode", "Description", "Prefix", "Padding", "StartingNo", "WarehouseScoped")
select 'TRANSFER-ORDER', 'Transfer Order Document No. (restarts per destination warehouse)', 'TR-', 4, 1, true
where not exists (select 1 from public."NoSeries" where "SeriesCode" = 'TRANSFER-ORDER');

comment on table public."NoSeries" is 'Running-number series setups (Prefix/Padding/Starting No.), managed from the General Setup portal page.';
comment on table public."NoSeriesLine" is 'Last-issued number per series, per scope (e.g. per warehouse when the series is WarehouseScoped).';

drop function if exists public.admin_list_no_series(text, text);

create or replace function public.admin_list_no_series(p_admin_username text, p_admin_password text)
returns table(
  series_code text,
  description text,
  prefix text,
  padding smallint,
  starting_no int,
  warehouse_scoped boolean,
  updated_by text,
  updated_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "SeriesCode"::text, "Description"::text, "Prefix"::text, "Padding", "StartingNo",
           "WarehouseScoped", "UpdatedBy"::text, "UpdatedAtUtc"
    from public."NoSeries"
    order by "SeriesCode";
end;
$$;

drop function if exists public.admin_upsert_no_series(text, text, text, text, text, smallint, int, boolean);

create or replace function public.admin_upsert_no_series(
  p_admin_username text,
  p_admin_password text,
  p_series_code text,
  p_description text,
  p_prefix text,
  p_padding smallint,
  p_starting_no int,
  p_warehouse_scoped boolean
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

  if p_series_code is null or trim(p_series_code) = '' then
    raise exception 'Series Code is required.';
  end if;
  if coalesce(p_padding, 0) < 1 or p_padding > 10 then
    raise exception 'Padding must be between 1 and 10 digits.';
  end if;
  if coalesce(p_starting_no, 0) < 0 then
    raise exception 'Starting No. cannot be negative.';
  end if;

  insert into public."NoSeries" ("SeriesCode", "Description", "Prefix", "Padding", "StartingNo", "WarehouseScoped", "UpdatedBy", "UpdatedAtUtc")
  values (upper(trim(p_series_code)), p_description, coalesce(p_prefix, ''), p_padding, coalesce(p_starting_no, 1), coalesce(p_warehouse_scoped, false), p_admin_username, now())
  on conflict ("SeriesCode") do update
    set "Description" = excluded."Description",
        "Prefix" = excluded."Prefix",
        "Padding" = excluded."Padding",
        "StartingNo" = excluded."StartingNo",
        "WarehouseScoped" = excluded."WarehouseScoped",
        "UpdatedBy" = excluded."UpdatedBy",
        "UpdatedAtUtc" = excluded."UpdatedAtUtc";
end;
$$;

drop function if exists public._next_no_series_number(text, text, int);

-- Internal helper - NOT granted to anon. Only callable from other SECURITY DEFINER functions
-- (e.g. staff_next_transfer_no) that have already authorized the caller themselves; this function
-- does no authorization of its own. Atomically increments the counter row for (series, scope) via
-- a plain UPDATE ... RETURNING (row-level lock, safe under concurrent callers). p_seed_no lets a
-- caller carry forward a legacy/previously-issued max so numbering continues rather than
-- restarting when a scope's counter row doesn't exist yet - ignored once the row already exists.
create or replace function public._next_no_series_number(p_series_code text, p_scope_key text, p_seed_no int default null)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_series record;
  v_scope text;
  v_next_no int;
begin
  select * into v_series from public."NoSeries" where "SeriesCode" = p_series_code;
  if not found then
    raise exception 'No. Series "%" is not set up.', p_series_code;
  end if;

  v_scope := case when v_series."WarehouseScoped" then coalesce(p_scope_key, '') else '' end;

  insert into public."NoSeriesLine" ("SeriesCode", "ScopeKey", "LastNo")
  values (p_series_code, v_scope, greatest(coalesce(p_seed_no, 0), v_series."StartingNo" - 1))
  on conflict ("SeriesCode", "ScopeKey") do nothing;

  update public."NoSeriesLine"
    set "LastNo" = "LastNo" + 1
    where "SeriesCode" = p_series_code and "ScopeKey" = v_scope
    returning "LastNo" into v_next_no;

  return v_series."Prefix" || v_scope || lpad(v_next_no::text, v_series."Padding", '0');
end;
$$;

grant execute on function public.admin_list_no_series(text, text) to anon;
grant execute on function public.admin_upsert_no_series(text, text, text, text, text, smallint, int, boolean) to anon;
-- _next_no_series_number deliberately NOT granted to anon - internal use only.
