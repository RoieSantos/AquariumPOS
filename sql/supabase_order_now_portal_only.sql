-- Order Now goes portal only - no Pancake order at all. Per "i dont want to push it to pancake anymore..
-- i only want to mantain the portal moving forward".
--
-- Before: submit_automated_order saved the AO- order with PancakeSyncStatus 'Pending', then
-- js/orderNow.js called public_sync_automated_order_to_pancake and the process-pending-automated-orders
-- cron (every minute) pushed every 'Pending' order to Pancake.
--
-- Now (same flow as AI bot / GMA "+ New Order" orders, supabase_bot_orders_portal_confirm.sql):
--   1. submit_automated_order saves the order as 'Not Pushed' with UpdatedBy = 'Order Now' (patched
--      into the LIVE function text - it has been redefined across several files).
--   2. It shows in Online Orders -> New tab (staff_list_new_online_orders lists every 'Not Pushed'
--      order, Created By "Order Now"). Staff review it and click Confirm Order -> admin_confirm_bot_order
--      creates the OnlineOrders row (OrderID = AO number, Source 'Portal', Created By 'Order Now').
--   3. Online payment (pay.html / Xendit) works on it before AND after confirming - a draft's payment
--      goes to AutomatedOrderPayments and Confirm Order carries it over.
--   4. The Messenger "Order Received" message (customers who came from a Messenger link) is still sent
--      - public_send_order_now_confirmation, called by the page right after submit; the cron is now only
--      a safety net for that message. NOTE: the message itself still goes out through Pancake's inbox
--      API (_send_order_confirmation_message) - it creates nothing in Pancake, it only sends the chat
--      message.
--   5. Old Order Now orders still 'Pending' / 'Failed' (never reached Pancake, last 14 days, not
--      cancelled / completed) are moved to 'Not Pushed' so they show in the New tab too.
--
-- Run AFTER supabase_submit_automated_order_price_validation.sql / supabase_automated_order_drop_phone_
-- fallback.sql, supabase_automated_order_async_pancake_sync.sql and supabase_online_orders_new_tab_edit.sql.
-- Safe to re-run. Ends with one result query (what changed).

-- ---------------------------------------------------------------------------
-- 1. submit_automated_order: save as 'Not Pushed' / 'Order Now'. Stops with an error, before anything
--    else in this file runs, if the expected text isn't there.
do $patch$
declare
  v_sig regprocedure := 'public.submit_automated_order(text, text, text, text, text, text, text, text, text, jsonb)'::regprocedure;
  v_def text := pg_get_functiondef(v_sig);
  v_new text;
begin
  if v_def like '%''Order Now''%' then
    raise notice 'submit_automated_order already patched - skipped.';
    return;
  end if;

  v_new := replace(v_def,
    $s$update public."AutomatedOrders" set "EstimatedTotal" = v_total where "OrderNo" = v_order_no;$s$,
    $s$-- Portal only (supabase_order_now_portal_only.sql): no Pancake push - waits in Online Orders -> New
  -- for staff to Confirm Order.
  update public."AutomatedOrders"
     set "EstimatedTotal" = v_total, "PancakeSyncStatus" = 'Not Pushed', "UpdatedBy" = 'Order Now'
   where "OrderNo" = v_order_no;$s$);
  if v_new = v_def then raise exception 'submit_automated_order patch: EstimatedTotal update not found - nothing changed.'; end if;

  execute v_new;
end
$patch$;

-- ---------------------------------------------------------------------------
-- 2. Messenger "Order Received" message only - claims the order first ('Sending') so the page and the
--    cron can never both send it. Only for a recent Order Now order.
create or replace function public._send_order_now_confirmation_once(p_order_no text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  update public."AutomatedOrders"
     set "ConfirmationMessageStatus" = 'Sending'
   where "OrderNo" = p_order_no
     and "ConfirmationMessageStatus" = 'Pending'
     and "UpdatedBy" = 'Order Now'
     and "CreatedAtUtc" > now() - interval '1 day';
  if found then
    perform public._send_order_confirmation_message(p_order_no);
  end if;
end;
$$;

revoke execute on function public._send_order_now_confirmation_once(text) from public, anon, authenticated;

create or replace function public.public_send_order_now_confirmation(p_order_no text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._send_order_now_confirmation_once(p_order_no);
end;
$$;

grant execute on function public.public_send_order_now_confirmation(text) to anon;

-- Old name, still called by Order Now pages cached from before this change - no Pancake push any more.
create or replace function public.public_sync_automated_order_to_pancake(p_order_no text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._send_order_now_confirmation_once(p_order_no);
end;
$$;

grant execute on function public.public_sync_automated_order_to_pancake(text) to anon;

-- ---------------------------------------------------------------------------
-- 3. process-pending-automated-orders cron: no Pancake push - only sends an Order Now message the page
--    missed (older than a minute, so the page's own call goes first).
create or replace function public.cron_process_pending_automated_orders()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_no text;
begin
  for v_order_no in
    select "OrderNo" from public."AutomatedOrders"
    where "ConfirmationMessageStatus" = 'Pending'
      and "UpdatedBy" = 'Order Now'
      and "CreatedAtUtc" between now() - interval '1 day' and now() - interval '1 minute'
    order by "CreatedAtUtc"
    limit 25
  loop
    perform public._send_order_now_confirmation_once(v_order_no);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Recent Order Now orders that never reached Pancake -> New tab.
drop table if exists _order_now_moved;
create temp table _order_now_moved ("OrderNo" text, "CustomerName" text, "CreatedAtUtc" timestamptz);

with moved as (
  update public."AutomatedOrders"
     set "PancakeSyncStatus" = 'Not Pushed',
         "PancakeSyncError" = null,
         "UpdatedBy" = coalesce(nullif(trim("UpdatedBy"), ''), 'Order Now')
   where "PancakeSyncStatus" in ('Pending', 'Failed')
     and "PancakeOrderId" is null
     and coalesce("Status", '') not in ('Cancelled', 'Completed')
     and "CreatedAtUtc" > now() - interval '14 days'
     and not exists (select 1 from public."OnlineOrders" oo where oo."OrderID" = "AutomatedOrders"."OrderNo")
  returning "OrderNo", "CustomerName", "CreatedAtUtc"
)
insert into _order_now_moved select * from moved;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Result
select 'submit_automated_order patched' as section,
       (pg_get_functiondef('public.submit_automated_order(text, text, text, text, text, text, text, text, text, jsonb)'::regprocedure) like '%''Order Now''%')::text as detail,
       null::timestamptz as created_at_utc
union all
select 'moved to New tab', "OrderNo" || ' - ' || coalesce("CustomerName", ''), "CreatedAtUtc"
from _order_now_moved
union all
select 'older orders still marked Pending (no longer pushed - ignored)', count(*)::text, null
from public."AutomatedOrders"
where "PancakeSyncStatus" = 'Pending';
