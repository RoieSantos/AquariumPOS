-- Ready to Ship asked for 4 serials on a 2-line order (and 2 + 2 on 105852) - per "it has the same problem
-- again.. its now asking for 4 serials but my order is only 2".
--
-- CAUSE: Pancake gives an order's lines new IDs when the order is saved again (confirmed / printed /
-- edited). The portal keeps the lines it saved before until a background re-read (cron_sync_online_order_
-- details / cron_refresh_open_online_orders) removes the old IDs - and that re-read can lag (105852 waited
-- ~10 hours). Until then OnlineOrderLines holds old + new copies of every line, and Ready to Ship's stock
-- check and serial picker count both.
--
-- FIX: staff_refresh_online_order_lines re-reads ONE order from Pancake right now with the same per-order
-- sync the background job uses (_sync_online_order_detail, supabase_online_order_sync_no_long_locks.sql):
-- saves its current lines and removes lines Pancake no longer has. The page calls it at Ready to Ship,
-- before the stock check and the serial picker (js/onlineOrders.js). Raises if Pancake can't be read -
-- the To Ship would need Pancake anyway.
-- Run AFTER supabase_online_order_sync_no_long_locks.sql. Safe to re-run.

create or replace function public.staff_refresh_online_order_lines(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '25000'
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_order_id is null or trim(p_order_id) = '' then
    raise exception 'Order ID is required.';
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
  begin
    perform public._sync_online_order_detail(p_order_id);
  exception when others then
    raise exception 'Could not re-read order % from Pancake (%). Please try again in a moment.', p_order_id, sqlerrm;
  end;
end;
$$;

grant execute on function public.staff_refresh_online_order_lines(text, text, text) to anon;
