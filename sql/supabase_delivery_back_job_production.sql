-- Delivery calendar "Back job" tick - per "production can tick back job in the delivery calendar" (2026-11-18).
--
-- staff_set_delivery_stop_back_job was Super User only (supabase_delivery_stop_back_job.sql). Now also:
--   - Production Manager (Staff Role), and
--   - Production Member (User Setup access flag).
-- Who ticked / unticked it is still saved on the stop (BackJobSetBy / BackJobSetAtUtc). Everything else
-- unchanged.
--
-- Run AFTER supabase_delivery_stop_back_job.sql. Do NOT re-run that file after this one (it would make
-- Back job Super User only again) - if you must, re-run this file after it. Safe to re-run.
-- Needs js/delivery.js ?v=salesmgr1.

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
       where u."Username" = p_username and u."IsActive"
         and (coalesce(u."SuperUser", false)
              or coalesce(u."ProductionMember", false)
              or 'ProductionManager' = any(coalesce(u."StaffRoles", '{}'::text[])))
     ) then
    raise exception 'Only a Super User, Production Manager or Production Member can mark a delivery as a Back job.';
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

-- Verification - one result.
select 'back job: production allowed' as check_name,
       (pg_get_functiondef('public.staff_set_delivery_stop_back_job(text, text, uuid, boolean)'::regprocedure)
         like '%ProductionMember%')::text as ok;
