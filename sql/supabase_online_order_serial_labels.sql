-- staff_get_online_order_serial_labels on its own - per "error on loading the factbox in the list":
-- "Could not find the function public.staff_get_online_order_serial_labels(...) in the schema cache".
--
-- It was only defined in supabase_online_order_ship_new_serials.sql, which this database never got
-- (or only partly). Do NOT re-run that whole file to fix this: it also re-creates
-- admin_update_online_order_status, and newer files (supabase_online_order_status_message_gma.sql, ...)
-- have replaced that since - re-running it would roll them back. This file adds only the read function.
--
-- Every serial tied to an Online / Walk-in order (ItemSerialTracking."SoldOnlineOrderId" = order id),
-- for the order card's Show Serials / Print Serial Labels and the Serials FactBox (card + list) in
-- docs/js/onlineOrders.js. Read-only, safe to re-run. Ends with one result: the function's signature.

drop function if exists public.staff_get_online_order_serial_labels(text, text, text);

create or replace function public.staff_get_online_order_serial_labels(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(serial_no text, item_code text, description text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select s."SerialNo"::text, s."ItemCode"::text, coalesce(nullif(trim(s."ItemDescription"), ''), s."ItemCode")::text
    from public."ItemSerialTracking" s
    where s."SoldOnlineOrderId" = p_order_id
      and coalesce(s."Status", '') <> 'REVERSED'
    order by s."ItemCode", s."SerialNo";
end;
$$;

grant execute on function public.staff_get_online_order_serial_labels(text, text, text) to anon;

notify pgrst, 'reload schema';

select p.oid::regprocedure::text as function_signature
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'staff_get_online_order_serial_labels';
