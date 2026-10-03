-- Serial label reprint count - per "can you show number of times they reprint it" (Serial Tracker's
-- per-row Reprint, Super User / Production Manager only - docs/js/serialTracker.js).
--
--   "SerialLabelReprints"  one row per reprint: serial, when, who.
--
--   staff_log_serial_label_reprint(user, pass, serial_no) -> reprint_count
--     Logs one reprint (Super User / Production Manager only) and returns the serial's new total.
--
--   staff_get_serial_label_reprints(user, pass, serial_nos[]) -> serial_no, reprint_count,
--                                                                last_reprinted_at, last_reprinted_by
--     Totals for the serials on screen. Serials never reprinted are left out.
--
-- Safe to re-run (keeps the logged reprints).

create table if not exists public."SerialLabelReprints" (
  "Id"            bigint generated always as identity primary key,
  "SerialNo"      text not null,
  "ReprintedAtUtc" timestamptz not null default now(),
  "ReprintedBy"   text
);

create index if not exists "IX_SerialLabelReprints_SerialNo" on public."SerialLabelReprints" ("SerialNo");

-- Only reachable through the functions below.
alter table public."SerialLabelReprints" enable row level security;

drop function if exists public.staff_log_serial_label_reprint(text, text, text);

create or replace function public.staff_log_serial_label_reprint(
  p_admin_username text,
  p_admin_password text,
  p_serial_no text
)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_can_reprint boolean;
  v_count integer;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select coalesce(s."SuperUser", false) or 'ProductionManager' = any(coalesce(s."StaffRoles", '{}'))
    into v_can_reprint
  from public."StaffUsers" s where s."Username" = p_admin_username and s."IsActive";

  if not coalesce(v_can_reprint, false) then
    raise exception 'Only a Super User or a Production Manager can reprint serial labels.';
  end if;

  if not exists (select 1 from public."ItemSerialTracking" where "SerialNo" = p_serial_no) then
    raise exception 'Serial % not found.', p_serial_no;
  end if;

  insert into public."SerialLabelReprints" ("SerialNo", "ReprintedBy")
  values (p_serial_no, p_admin_username);

  select count(*)::integer into v_count
  from public."SerialLabelReprints" where "SerialNo" = p_serial_no;

  return v_count;
end;
$$;

grant execute on function public.staff_log_serial_label_reprint(text, text, text) to anon;

drop function if exists public.staff_get_serial_label_reprints(text, text, text[]);

create or replace function public.staff_get_serial_label_reprints(
  p_admin_username text,
  p_admin_password text,
  p_serial_nos text[]
)
returns table(serial_no text, reprint_count integer, last_reprinted_at timestamptz, last_reprinted_by text)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select r."SerialNo"::text,
           count(*)::integer,
           max(r."ReprintedAtUtc"),
           (array_agg(r."ReprintedBy" order by r."ReprintedAtUtc" desc))[1]::text
    from public."SerialLabelReprints" r
    where r."SerialNo" = any(coalesce(p_serial_nos, '{}'))
    group by r."SerialNo";
end;
$$;

grant execute on function public.staff_get_serial_label_reprints(text, text, text[]) to anon;

notify pgrst, 'reload schema';
