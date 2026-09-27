-- Fix: Pancake's API names status 11 "waitting" (their spelling), not "restocking" - so the sync
-- saved assigned orders as "waitting" instead of 'Assigned' (supabase_online_order_assigned_status.sql's
-- trigger didn't know that token). Adds it to the trigger's mapping and fixes the rows already saved.
-- Safe to run while the sync is running (replaces a function, then updates rows - no table DDL).

create or replace function public._normalize_online_order_status()
returns trigger
language plpgsql
as $$
begin
  if lower(trim(coalesce(new."Status", ''))) in (
    public._online_order_assigned_pancake_code(), 'assigned', 'restocking', 'waitting', 'waiting_for_goods', 'waiting for goods', 'wait_goods'
  ) then
    new."Status" := 'Assigned';
  end if;
  return new;
end;
$$;

-- Existing rows: the trigger fires on this update and turns them into 'Assigned'.
update public."OnlineOrders"
set "Status" = 'Assigned'
where lower(trim(coalesce("Status", ''))) = 'waitting';
