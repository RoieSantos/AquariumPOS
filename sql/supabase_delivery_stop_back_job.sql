-- =============================================================================
-- Delivery: "Back job" flag on a stop - per "can we put a boolean there 'Back job' if its a back job it
-- allows no delivery fee".
--
-- A back job (a return trip to fix / redo / finish an earlier job) is not charged a delivery fee, so a
-- stop marked Back job can be printed (Print / Print Invoice / Print Job Order) with no fee. Every other
-- stop still needs a fee before printing (delivery.js stopHasDeliveryFee).
--
-- New:
--   DeliveryStops."IsBackJob" (+ who/when set it)
--   staff_set_delivery_stop_back_job  - tick / untick (Super User only)
--   staff_list_delivery_back_job_stops - the back-job stop ids in a date range (delivery.js loads it next
--                                       to admin_list_delivery_stops, so that big function is left as is)
--
-- Portal only, nothing goes to Pancake. Safe to re-run. Needs js/delivery.js ?v=backjob2.
-- Ends with one check result.
-- =============================================================================

set lock_timeout = '10s';

alter table public."DeliveryStops" add column if not exists "IsBackJob" boolean not null default false;
alter table public."DeliveryStops" add column if not exists "BackJobSetBy" varchar(100);
alter table public."DeliveryStops" add column if not exists "BackJobSetAtUtc" timestamptz;

reset lock_timeout;

comment on column public."DeliveryStops"."IsBackJob" is 'Back job (return trip, no delivery fee) - the stop can be printed without a delivery fee. See supabase_delivery_stop_back_job.sql.';

-- ---------------------------------------------------------------------------
-- 1. Tick / untick.

drop function if exists public.staff_set_delivery_stop_back_job(text, text, uuid, boolean);

create or replace function public.staff_set_delivery_stop_back_job(
  p_username text,
  p_password text,
  p_stop_id uuid,
  p_is_back_job boolean
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_username, p_password)
     or not exists (
       select 1 from public."StaffUsers" u
       where u."Username" = p_username and u."IsActive" and u."SuperUser"
     ) then
    raise exception 'Only a Super User can mark a delivery as a Back job.';
  end if;

  update public."DeliveryStops"
     set "IsBackJob"       = coalesce(p_is_back_job, false),
         "BackJobSetBy"    = p_username,
         "BackJobSetAtUtc" = now()
   where "StopID" = p_stop_id;

  if not found then
    raise exception 'Delivery stop not found - refresh the page.';
  end if;

  return coalesce(p_is_back_job, false);
end;
$$;

revoke all on function public.staff_set_delivery_stop_back_job(text, text, uuid, boolean) from public;
grant execute on function public.staff_set_delivery_stop_back_job(text, text, uuid, boolean) to anon;

-- ---------------------------------------------------------------------------
-- 2. Back-job stops in a date range [start, end) - same range / auth as admin_list_delivery_stops.

drop function if exists public.staff_list_delivery_back_job_stops(text, text, date, date);

create or replace function public.staff_list_delivery_back_job_stops(
  p_username text,
  p_password text,
  p_start_date date,
  p_end_date date
)
returns table(stop_id uuid)
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
    select s."StopID"
    from public."DeliveryStops" s
    where s."DeliveryDate" >= p_start_date and s."DeliveryDate" < p_end_date
      and s."IsBackJob";
end;
$$;

revoke all on function public.staff_list_delivery_back_job_stops(text, text, date, date) from public;
grant execute on function public.staff_list_delivery_back_job_stops(text, text, date, date) to anon;

-- ---------------------------------------------------------------------------
-- Verification - one result.

select 'setup' as section, x.item, x.ok as detail
from (values
  ('column DeliveryStops.IsBackJob',
     exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'DeliveryStops' and column_name = 'IsBackJob')::text),
  ('function staff_set_delivery_stop_back_job',
     (to_regprocedure('public.staff_set_delivery_stop_back_job(text, text, uuid, boolean)') is not null)::text),
  ('function staff_list_delivery_back_job_stops',
     (to_regprocedure('public.staff_list_delivery_back_job_stops(text, text, date, date)') is not null)::text)
) as x(item, ok)
union all
select 'back job ' || s."DeliveryDate"::text,
       coalesce(s."OrderID", 'ADV-' || s."AdvanceTransactionNo", s."AutomatedOrderNo"),
       'set by ' || coalesce(s."BackJobSetBy", '?')
from public."DeliveryStops" s
where s."IsBackJob";
