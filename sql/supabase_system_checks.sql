-- System Tests (docs/system-tests.html): read-only health checks of the live data - order statuses,
-- inventory / item ledger, Facebook posts, background jobs, and "is the newest version of each SQL
-- function actually installed". Per "we are moving so fast i just dont want other functionality to get broken".
--
--   admin_run_system_checks(username, password)
--     -> one row per check: section, check_name, status ('pass' | 'warn' | 'fail'), detail.
--     'fail' = something is broken now; 'warn' = worth a look (may be fine).
--   admin_check_portal_rpcs(username, password, names[])
--     -> for each RPC name the portal's pages call: 'missing' (not in the database - its .sql file was
--        never run) or 'ambiguous' (2+ versions with different parameters - PostgREST can refuse the
--        call with PGRST203). Names that are fine are left out.
--
-- Both are super-user only (is_admin_authorized) and STABLE - Postgres itself refuses any
-- INSERT / UPDATE / DELETE inside them, so running the checks can never change data.
-- Each check runs in its own exception block: a check that errors shows up as a 'warn' row
-- instead of stopping the rest.
--
-- To add a check: copy one of the blocks below (section, check name, a query that builds v_status/v_detail).
-- "Database functions" fingerprints: each newest sql/ file's function contains a token no older
-- version has - if it's missing, an older .sql file has overwritten it (or the new one was never run).
--
-- Safe to re-run.

create or replace function public.admin_run_system_checks(
  p_admin_username text,
  p_admin_password text
)
returns table(section text, check_name text, status text, detail text)
language plpgsql
stable
security definer
set search_path = public, extensions
set statement_timeout = '60000'
as $$
declare
  v_status text;
  v_detail text;
  v_count bigint;
  v_rec record;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- =====================================================================================
  -- Order statuses
  -- =====================================================================================

  -- Every status in OnlineOrders is one the portal knows how to show / filter / lock.
  begin
    select count(*), string_agg(format('%s (%s)', s, n), ', ' order by n desc)
      into v_count, v_detail
    from (
      select coalesce(nullif(trim(o."Status"), ''), '(blank)') as s, count(*) as n
      from public."OnlineOrders" o
      where lower(trim(coalesce(o."Status", ''))) not in (
        'new', 'confirmed', 'submitted', 'printed', 'assigned', 'to ship', 'packing', 'packed',
        'shipped', 'delivered', 'completed', 'received', 'canceled', 'cancelled', 'returning',
        'returned', 'deleted', 'in-transit', 'pending transfer', 'waiting', 'restocking'
      )
      group by 1
    ) x;
    section := 'Order statuses'; check_name := 'All online order statuses are known values';
    status := case when v_count = 0 then 'pass' else 'warn' end;
    detail := case when v_count = 0 then 'OK' else 'Unknown status values: ' || v_detail end;
    return next;
  exception when others then
    section := 'Order statuses'; check_name := 'All online order statuses are known values'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;

  -- 'Assigned' means every part that needs a maker has one (_online_order_assignment_complete).
  begin
    select count(*), string_agg(o."OrderID", ', ' order by o."Date" desc)
      into v_count, v_detail
    from public."OnlineOrders" o
    where lower(trim(coalesce(o."Status", ''))) = 'assigned'
      and not public._online_order_assignment_complete(o."OrderID");
    section := 'Order statuses'; check_name := 'Assigned orders really have their makers assigned';
    status := case when v_count = 0 then 'pass' else 'fail' end;
    detail := case when v_count = 0 then 'OK' else v_count || ' order(s) at Assigned with a missing Tank/Stand Maker: ' || left(v_detail, 400) end;
    return next;
  exception when others then
    section := 'Order statuses'; check_name := 'Assigned orders really have their makers assigned'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;

  -- The other direction: makers all set, but the order never moved to Assigned (last 60 days).
  begin
    select count(*), string_agg(o."OrderID", ', ' order by o."Date" desc)
      into v_count, v_detail
    from public."OnlineOrders" o
    where lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'printed')
      and o."Date" >= current_date - 60
      and public._online_order_assignment_complete(o."OrderID");
    section := 'Order statuses'; check_name := 'Fully assigned orders moved to Assigned';
    status := case when v_count = 0 then 'pass' else 'warn' end;
    detail := case when v_count = 0 then 'OK' else v_count || ' Confirmed/Printed order(s) have every maker set but are not Assigned yet: ' || left(v_detail, 400) end;
    return next;
  exception when others then
    section := 'Order statuses'; check_name := 'Fully assigned orders moved to Assigned'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;

  -- To Ship is blocked while custom production isn't done (supabase_online_order_to_ship_production_gate.sql).
  begin
    select count(*), string_agg(o."OrderID", ', ' order by o."Date" desc)
      into v_count, v_detail
    from public."OnlineOrders" o
    where lower(trim(coalesce(o."Status", ''))) = 'to ship'
      and o."Date" >= current_date - 30
      and public._online_order_to_ship_production_block(o."OrderID") is not null;
    section := 'Order statuses'; check_name := 'To Ship orders finished production first';
    status := case when v_count = 0 then 'pass' else 'warn' end;
    detail := case when v_count = 0 then 'OK' else v_count || ' order(s) at To Ship (last 30 days) with production not marked done: ' || left(v_detail, 400) end;
    return next;
  exception when others then
    section := 'Order statuses'; check_name := 'To Ship orders finished production first'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;

  -- Shipping / cancelling an order releases its leftover serial reservations (_serial_release_order_reservations).
  begin
    select count(*), string_agg(distinct s."ReservedForOrderId", ', ')
      into v_count, v_detail
    from public."ItemSerialTracking" s
    join public."OnlineOrders" o on o."OrderID" = s."ReservedForOrderId"
    where s."Status" = 'RESERVED'
      and lower(trim(coalesce(o."Status", ''))) in ('shipped', 'delivered', 'completed', 'received', 'canceled', 'cancelled', 'returned', 'deleted');
    section := 'Order statuses'; check_name := 'Closed orders hold no reserved serials';
    status := case when v_count = 0 then 'pass' else 'fail' end;
    detail := case when v_count = 0 then 'OK' else v_count || ' serial(s) still RESERVED for shipped/cancelled orders: ' || left(v_detail, 400) end;
    return next;
  exception when others then
    section := 'Order statuses'; check_name := 'Closed orders hold no reserved serials'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;

  -- A cancelled order shouldn't keep a unit marked SOLD to it.
  begin
    select count(*), string_agg(distinct s."SoldOnlineOrderId", ', ')
      into v_count, v_detail
    from public."ItemSerialTracking" s
    join public."OnlineOrders" o on o."OrderID" = s."SoldOnlineOrderId"
    where s."Status" = 'SOLD'
      and lower(trim(coalesce(o."Status", ''))) in ('canceled', 'cancelled', 'deleted');
    section := 'Order statuses'; check_name := 'Cancelled orders have no SOLD serials';
    status := case when v_count = 0 then 'pass' else 'warn' end;
    detail := case when v_count = 0 then 'OK' else v_count || ' serial(s) SOLD to cancelled orders: ' || left(v_detail, 400) end;
    return next;
  exception when others then
    section := 'Order statuses'; check_name := 'Cancelled orders have no SOLD serials'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;

  -- Bot / portal orders that failed to push to Pancake (last 30 days).
  begin
    select count(*), string_agg(a."OrderNo" || coalesce(' - ' || left(a."PancakeSyncError", 80), ''), '; ' order by a."CreatedAtUtc" desc)
      into v_count, v_detail
    from public."AutomatedOrders" a
    where a."PancakeSyncStatus" = 'Failed'
      and a."CreatedAtUtc" >= now() - interval '30 days';
    section := 'Order statuses'; check_name := 'Bot / portal orders pushed to Pancake';
    status := case when v_count = 0 then 'pass' else 'warn' end;
    detail := case when v_count = 0 then 'OK' else v_count || ' order(s) failed to push: ' || left(v_detail, 500) end;
    return next;
  exception when others then
    section := 'Order statuses'; check_name := 'Bot / portal orders pushed to Pancake'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;

  -- =====================================================================================
  -- Inventory
  -- =====================================================================================

  -- Every counted sale took its stock out of the ledger (supabase_item_ledger_sales_audit.sql).
  begin
    select count(*), string_agg(a.order_id || ' (' || a.issue || ')', '; ')
      into v_count, v_detail
    from public._ile_sales_audit() a;
    section := 'Inventory'; check_name := 'Every sale is posted to the item ledger';
    status := case when v_count = 0 then 'pass' else 'fail' end;
    detail := case when v_count = 0 then 'OK' else v_count || ' order(s) with a ledger mismatch (the self-heal job retries every 15 min): ' || left(v_detail, 500) end;
    return next;
  exception when others then
    section := 'Inventory'; check_name := 'Every sale is posted to the item ledger'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;

  -- The posting queue drains every minute; anything older than 15 minutes means the job is stuck.
  begin
    select count(*), min(d."QueuedAtUtc")::text
      into v_count, v_detail
    from public."ItemLedgerOrderDirty" d
    where d."QueuedAtUtc" < now() - interval '15 minutes';
    section := 'Inventory'; check_name := 'Item ledger posting queue is moving';
    status := case when v_count = 0 then 'pass' else 'fail' end;
    detail := case when v_count = 0 then 'OK' else v_count || ' order change(s) waiting over 15 minutes (oldest queued ' || v_detail || ' UTC) - is the item-ledger-sales-posting job running?' end;
    return next;
  exception when others then
    section := 'Inventory'; check_name := 'Item ledger posting queue is moving'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;

  -- Ledger entries point at real items and warehouses.
  begin
    select count(*), string_agg(distinct e."ItemCode", ', ')
      into v_count, v_detail
    from public."ItemLedgerEntries" e
    where not exists (select 1 from public."Items" i where i."Code" = e."ItemCode");
    section := 'Inventory'; check_name := 'Ledger entries use known item codes';
    status := case when v_count = 0 then 'pass' else 'warn' end;
    detail := case when v_count = 0 then 'OK' else v_count || ' entry(ies) for item codes not in Items: ' || left(v_detail, 400) end;
    return next;
  exception when others then
    section := 'Inventory'; check_name := 'Ledger entries use known item codes'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;

  begin
    select count(*), string_agg(distinct e."WarehouseId", ', ')
      into v_count, v_detail
    from public."ItemLedgerEntries" e
    where not exists (select 1 from public."Warehouses" w where w."ID"::text = e."WarehouseId");
    section := 'Inventory'; check_name := 'Ledger entries use known warehouses';
    status := case when v_count = 0 then 'pass' else 'fail' end;
    detail := case when v_count = 0 then 'OK' else v_count || ' entry(ies) for unknown warehouse IDs: ' || left(v_detail, 400) end;
    return next;
  exception when others then
    section := 'Inventory'; check_name := 'Ledger entries use known warehouses'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;

  -- On hand below zero = an outflow without its receipt (or a missed receipt).
  begin
    select count(*), string_agg(format('%s%s @ %s: %s', b.item, coalesce(' / ' || b.variant, ''), b.wh, b.qty::numeric(18,2)), '; ')
      into v_count, v_detail
    from (
      select e."ItemCode" as item, e."VariantId" as variant, e."WarehouseId" as wh, sum(e."Quantity") as qty
      from public."ItemLedgerEntries" e
      group by 1, 2, 3
      having sum(e."Quantity") < 0
      order by 4
      limit 1000
    ) b;
    section := 'Inventory'; check_name := 'No negative stock in the item ledger';
    status := case when v_count = 0 then 'pass' else 'warn' end;
    detail := case when v_count = 0 then 'OK' else v_count || ' item/warehouse balance(s) below zero: ' || left(v_detail, 500) end;
    return next;
  exception when others then
    section := 'Inventory'; check_name := 'No negative stock in the item ledger'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;

  -- Serials: known statuses, and every reservation names its order.
  begin
    select count(*), string_agg(format('%s (%s)', x.s, x.n), ', ')
      into v_count, v_detail
    from (
      select coalesce(s."Status", '(blank)') as s, count(*) as n
      from public."ItemSerialTracking" s
      where coalesce(s."Status", '') not in ('IN_STOCK', 'RESERVED', 'SOLD', 'IN_TRANSIT', 'RETURNED')
      group by 1
    ) x;
    section := 'Inventory'; check_name := 'Serial statuses are known values';
    status := case when v_count = 0 then 'pass' else 'warn' end;
    detail := case when v_count = 0 then 'OK' else 'Other serial statuses: ' || v_detail end;
    return next;
  exception when others then
    section := 'Inventory'; check_name := 'Serial statuses are known values'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;

  begin
    select count(*), string_agg(s."SerialNo", ', ')
      into v_count, v_detail
    from public."ItemSerialTracking" s
    where s."Status" = 'RESERVED' and nullif(trim(coalesce(s."ReservedForOrderId", '')), '') is null;
    section := 'Inventory'; check_name := 'Reserved serials name their order';
    status := case when v_count = 0 then 'pass' else 'fail' end;
    detail := case when v_count = 0 then 'OK' else v_count || ' RESERVED serial(s) with no order: ' || left(v_detail, 400) end;
    return next;
  exception when others then
    section := 'Inventory'; check_name := 'Reserved serials name their order'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;

  -- =====================================================================================
  -- Facebook posts (facebook-page-post: delivery Done posts to GMA + Amaya, ship posts)
  -- =====================================================================================
  -- A claim is only released by a FAILED post - if the function died between claiming and finishing
  -- (e.g. timed out writing the caption), the stop / order says "being posted right now" forever and
  -- "Post to Facebook" can never retry it. 15 minutes is far longer than any real post takes.
  begin
    select count(*), string_agg(x.ref, ', ')
      into v_count, v_detail
    from (
      select 'stop ' || c."StopID"::text || ' (GMA)' as ref
      from public."DeliveryStopCompletions" c
      where c."PostClaimedAtUtc" < now() - interval '15 minutes'
        and c."PostedAtUtc" is null and c."FacebookPostId" is null
      union all
      select 'order ' || p."OrderID"
      from public."OnlineOrderShipPosts" p
      where p."PostClaimedAtUtc" < now() - interval '15 minutes'
        and p."PostedAtUtc" is null and p."FacebookPostId" is null
    ) x;
    section := 'Facebook posts'; check_name := 'No post stuck "being posted" (GMA delivery + ship posts)';
    status := case when v_count = 0 then 'pass' else 'fail' end;
    detail := case when v_count = 0 then 'OK' else v_count || ' post(s) claimed over 15 minutes ago but never finished - they can''t be retried until the claim is cleared: ' || left(v_detail, 500) end;
    return next;
  exception when others then
    section := 'Facebook posts'; check_name := 'No post stuck "being posted" (GMA delivery + ship posts)'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;

  -- Amaya columns only exist after supabase_delivery_stop_post_amaya.sql - its own block.
  begin
    select count(*), string_agg(c."StopID"::text, ', ')
      into v_count, v_detail
    from public."DeliveryStopCompletions" c
    where c."AmayaPostClaimedAtUtc" < now() - interval '15 minutes'
      and c."AmayaPostedAtUtc" is null and c."AmayaPostId" is null;
    section := 'Facebook posts'; check_name := 'No post stuck "being posted" (Amaya delivery posts)';
    status := case when v_count = 0 then 'pass' else 'fail' end;
    detail := case when v_count = 0 then 'OK' else v_count || ' Amaya post(s) claimed over 15 minutes ago but never finished: ' || left(v_detail, 500) end;
    return next;
  exception when others then
    section := 'Facebook posts'; check_name := 'No post stuck "being posted" (Amaya delivery posts)'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;

  -- Failed and never retried (last 14 days). The latest error usually names the cause - an expired
  -- or revoked Page token shows up here first.
  begin
    select count(*), max(x.err) filter (where x.rn = 1)
      into v_count, v_detail
    from (
      select y.err, row_number() over (order by y.at desc nulls last) as rn
      from (
        select c."PostError" as err, c."DoneAtUtc" as at
        from public."DeliveryStopCompletions" c
        where c."PostError" is not null and c."PostedAtUtc" is null and c."FacebookPostId" is null
          and c."DoneAtUtc" >= now() - interval '14 days'
        union all
        select p."PostError", p."PostClaimedAtUtc"
        from public."OnlineOrderShipPosts" p
        where p."PostError" is not null and p."PostedAtUtc" is null and p."FacebookPostId" is null
          and coalesce(p."PostClaimedAtUtc", now()) >= now() - interval '14 days'
      ) y
    ) x;
    section := 'Facebook posts'; check_name := 'No failed posts waiting for a retry (last 14 days)';
    status := case when v_count = 0 then 'pass' else 'warn' end;
    detail := case when v_count = 0 then 'OK' else v_count || ' post(s) failed and were not retried. Latest error: ' || left(coalesce(v_detail, ''), 400) end;
    return next;
  exception when others then
    section := 'Facebook posts'; check_name := 'No failed posts waiting for a retry (last 14 days)'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;

  -- Marked Done with a photo, but the post step never even started (app closed right after Done?).
  begin
    select count(*), string_agg(c."StopID"::text, ', ')
      into v_count, v_detail
    from public."DeliveryStopCompletions" c
    where c."PhotoStoragePath" is not null
      and c."PostClaimedAtUtc" is null and c."PostedAtUtc" is null and c."FacebookPostId" is null and c."PostError" is null
      and c."DoneAtUtc" between now() - interval '14 days' and now() - interval '1 hour';
    section := 'Facebook posts'; check_name := 'Done deliveries got posted (last 14 days)';
    status := case when v_count = 0 then 'pass' else 'warn' end;
    detail := case when v_count = 0 then 'OK' else v_count || ' Done stop(s) with a photo were never posted - open the stop and tap "Post to Facebook": ' || left(v_detail, 400) end;
    return next;
  exception when others then
    section := 'Facebook posts'; check_name := 'Done deliveries got posted (last 14 days)'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;

  -- =====================================================================================
  -- Background jobs (pg_cron)
  -- =====================================================================================
  begin
    for v_rec in
      select j.jobname, j.schedule,
             last_run.status as last_status, last_run.start_time as last_start, last_run.return_message as last_message,
             (select count(*) from cron.job_run_details d where d.jobid = j.jobid and d.status = 'failed' and d.start_time >= now() - interval '24 hours') as fails_24h
      from cron.job j
      left join lateral (
        select d.status, d.start_time, d.return_message
        from cron.job_run_details d
        where d.jobid = j.jobid
        -- nulls last: a leftover run row with no start_time sorts FIRST in a plain desc, which made a
        -- job running every minute show as "last ran never".
        order by d.start_time desc nulls last
        limit 1
      ) last_run on true
      where j.active
      order by j.jobname
    loop
      section := 'Background jobs';
      check_name := 'Job ' || coalesce(v_rec.jobname, '(unnamed)') || ' (' || v_rec.schedule || ')';
      if v_rec.last_status = 'failed' then
        status := 'fail';
        detail := 'Last run failed at ' || v_rec.last_start::text || ': ' || left(coalesce(v_rec.last_message, ''), 300);
      elsif v_rec.schedule = '* * * * *' and (v_rec.last_start is null or v_rec.last_start < now() - interval '30 minutes') then
        status := 'fail';
        detail := 'Runs every minute but last ran ' || coalesce(v_rec.last_start::text, 'never (no run log)') || '.';
      elsif v_rec.fails_24h > 0 then
        status := 'warn';
        detail := v_rec.fails_24h || ' failed run(s) in the last 24 hours (latest run OK).';
      else
        status := 'pass';
        detail := 'OK' || coalesce(' - last ran ' || v_rec.last_start::text, '');
      end if;
      return next;
    end loop;
  exception when others then
    section := 'Background jobs'; check_name := 'Read pg_cron job list'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;

  -- =====================================================================================
  -- Database functions: newest version installed
  -- =====================================================================================
  begin
    for v_rec in
      select f.fn, f.marker, f.src_file,
             exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                     where n.nspname = 'public' and p.proname = f.fn) as present,
             exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                     where n.nspname = 'public' and p.proname = f.fn and position(f.marker in p.prosrc) > 0) as current_version
      from (values
-- FINGERPRINTS (generated from sql/: newest file per function + a token only that version has)
      ('admin_list_staff_users', '"StaffRoles"', 'supabase_staff_users_staff_roles.sql'),
      ('admin_create_staff_user', '"ConversationsStaff"', 'supabase_staff_users_conversations_staff_field.sql'),
      ('admin_update_staff_user', '"ConversationsStaff"', 'supabase_staff_users_conversations_staff_field.sql'),
      ('admin_list_delivery_stops', '"OrderNo"', 'supabase_delivery_assign_automated_order_search.sql'),
      ('verify_login', '"StaffRoles"', 'supabase_production_manager_role.sql'),
      ('admin_get_chatbot_conversation_messages', '"ReplyToMid"', 'supabase_chatbot_message_reply_to.sql'),
      ('admin_get_delivery_receipt', '"AutomatedOrderNo"', 'supabase_delivery_assign_automated_order_search.sql'),
      ('admin_list_payroll_employees', '"Amount"', 'supabase_payroll_cash_advances.sql'),
      ('admin_update_payroll_profile', '"HasPaidRestDay"', 'supabase_payroll_paid_rest_day_boolean.sql'),
      ('staff_post_purchase_order', 'create_vendor_payment', 'supabase_purchase_order_paid_on_post.sql'),
      ('admin_update_online_order_status', '"ReservedForOrderId"', 'supabase_serial_order_reservation.sql'),
      ('admin_list_payroll_ledger_entries', '"EmployeeNo"', 'supabase_payroll_ledger_employee_no.sql'),
      ('admin_list_categories', '"SkipTransferStockCheck"', 'supabase_category_skip_transfer_stock_check.sql'),
      ('admin_update_category_flags', '"SkipTransferStockCheck"', 'supabase_category_skip_transfer_stock_check.sql'),
      ('public_search_items', 'chatbot_item_stock_by_variant', 'supabase_chatbot_stock_by_variant.sql'),
      ('admin_list_automated_orders_by_gma_conversation', '"DeliveryFee"', 'supabase_gma_order_delivery_fee.sql'),
      ('admin_create_gma_conversation_order', '"DeliveryFee"', 'supabase_gma_order_delivery_fee.sql'),
      ('staff_receive_purchase_order_lines', 'ile_transaction_no_seq', 'supabase_item_ledger_hooks.sql'),
      ('admin_get_phys_journal_lines', 'is_phys_journal_authorized', 'supabase_phys_journal_store_manager_access.sql'),
      ('admin_assign_online_order_maker', '"OnlineOrderStaff"', 'supabase_online_order_staff_no_assign.sql'),
      ('_online_order_production_roles', 'online_order_is_sticker_line', 'supabase_online_order_sticker_no_maker.sql'),
      ('staff_search_item_serial_tracking', '"ReservedForOrderId"', 'supabase_serial_order_reservation.sql'),
      ('admin_list_automated_order_lines', '"VariantName"', 'supabase_automated_order_lines_sku_variant.sql'),
      ('public_list_order_items', 'chatbot_item_stock_by_variant', 'supabase_chatbot_stock_by_variant.sql'),
      ('admin_update_automated_order', '"DeliveryFee"', 'supabase_gma_order_delivery_fee.sql'),
      ('admin_add_automated_order_payment', '"PancakeSyncStatus"', 'supabase_bot_orders_portal_confirm.sql'),
      ('admin_upsert_chatbot_quick_reply', 'is_conversations_authorized', 'supabase_gma_conversations_staff_rpc_access.sql'),
      ('admin_create_delivery_stop', '"AutomatedOrders"', 'supabase_delivery_assign_automated_order_search.sql'),
      ('admin_update_delivery_stop_geocode', '"ManualDeliveryFee"', 'supabase_delivery_stop_manual_fee.sql'),
      ('admin_calculate_phys_inventory', 'is_phys_journal_authorized', 'supabase_phys_journal_store_manager_access.sql'),
      ('staff_get_online_order_stock_status', '"ReservedForOrderId"', 'supabase_serial_order_reservation.sql'),
      ('admin_get_payroll_payslip', '"CreatedBy"', 'supabase_payroll_payslip_prepared_by.sql'),
      ('admin_create_payroll_employee', '"HasPaidRestDay"', 'supabase_payroll_paid_rest_day_boolean.sql'),
      ('staff_get_production_shelves', 'variant_colour', 'supabase_production_shelf_rack_variant_sku.sql'),
      ('public_get_automated_order_receipt', '"DeliveryFee"', 'supabase_gma_order_delivery_fee.sql'),
      ('_pancake_patch_online_order_status', 'is_portal_only_online_order', 'supabase_bot_orders_portal_confirm.sql'),
      ('admin_get_online_order_detail_live', 'is_portal_only_online_order', 'supabase_bot_orders_portal_confirm.sql'),
      ('admin_list_chatbot_quick_replies', 'is_conversations_authorized', 'supabase_gma_conversations_staff_rpc_access.sql'),
      ('_notify_delivery_stop_changed', '"AutomatedOrderNo"', 'supabase_delivery_assign_automated_order_search.sql'),
      ('admin_sync_online_order_assigned_status', '"ReceivedAtShop"', 'supabase_walkin_order_production.sql'),
      ('_online_order_line_part', 'online_order_is_sticker_line', 'supabase_online_order_sticker_no_maker.sql'),
      ('admin_list_payroll_run_lines', '"PayType"', 'supabase_payroll_hourly_days_worked_display.sql')
      ) as f(fn, marker, src_file)
      order by f.fn
    loop
      section := 'Database functions';
      check_name := v_rec.fn;
      if not v_rec.present then
        status := 'fail'; detail := 'Missing from the database - run ' || v_rec.src_file;
      elsif not v_rec.current_version then
        status := 'fail'; detail := 'Older version installed - an older .sql file overwrote it, or ' || v_rec.src_file || ' was never run. Re-run ' || v_rec.src_file || '.';
      else
        status := 'pass'; detail := 'Matches ' || v_rec.src_file;
      end if;
      return next;
    end loop;
  exception when others then
    section := 'Database functions'; check_name := 'Read function versions'; status := 'warn'; detail := 'Check failed to run: ' || sqlerrm; return next;
  end;
end;
$$;

grant execute on function public.admin_run_system_checks(text, text) to anon, authenticated;

-- RPCs the portal pages call (the System Tests page collects the names from the pages' own scripts).
create or replace function public.admin_check_portal_rpcs(
  p_admin_username text,
  p_admin_password text,
  p_names text[]
)
returns table(rpc_name text, problem text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select n.name::text,
           case when count(p.oid) = 0 then 'missing' else 'ambiguous' end
    from unnest(p_names) as n(name)
    left join pg_proc p
      on p.proname = n.name
     and p.pronamespace = 'public'::regnamespace
    group by n.name
    having count(p.oid) <> 1
    order by 1;
end;
$$;

grant execute on function public.admin_check_portal_rpcs(text, text, text[]) to anon, authenticated;

-- Quick look after running (super-user login needed, so this just confirms the functions exist):
select p.proname as installed_function
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('admin_run_system_checks', 'admin_check_portal_rpcs')
order by 1;
