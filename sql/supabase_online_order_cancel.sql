-- Online Orders: Cancel Order on the order card - per "can the user cancel an order".
--
-- Before: only a New (unconfirmed) order could be cancelled (New tab), or a Confirmed GMA order from its
-- conversation card (admin_cancel_gma_order_in_pancake). Once in Online Orders there was no cancel.
--
-- staff_cancel_online_order(order, reason, dry run):
--   * Who: Super User, Production Manager, Sales User or Store Manager (same as moving an order's branch).
--   * Which orders: open online orders before To Ship (Confirmed / Printed / Assigned ...), portal (AO-) or
--     Pancake. Not walk-ins (already a POS sale - refund / exchange it at the POS) and not once it's To
--     Ship or later (serials are tagged, it may be on a delivery).
--   * A reason is required; every cancel is logged in OnlineOrderCancellations (who / when / why / the
--     status it had).
--   * Pancake orders: Pancake first (status 6 = Canceled, same as admin_cancel_gma_order_in_pancake, via
--     the retrying _pancake_patch_online_order_status that keeps bank_payments); if Pancake refuses,
--     nothing changes. Then the portal's copy is set Cancelled right away (the sync agrees on its next pass).
--     Portal (AO-) orders: changed here only (+ the source AutomatedOrders row).
--   * Follows on its own: serials RESERVED for the order go back In Stock (TR_OnlineOrders_SerialReservation,
--     supabase_serial_order_reservation.sql); the Item Ledger sale follows the order (change queue).
--   * Warnings shown before confirming (p_dry_run = true, the default): makers already assigned / parts
--     already Production Done, an open Production Order built for it (it stays - its output becomes normal
--     stock), payments on the order (refund them separately), reserved serials (released).
--   * The customer is NOT messaged - tell them yourself.
--
-- Run AFTER supabase_serial_order_reservation.sql and supabase_pancake_patch_retry.sql. Safe to re-run.
-- Needs js/onlineOrders.js ?v=cancelorder1.

create table if not exists public."OnlineOrderCancellations" (
  "Id" bigint generated always as identity primary key,
  "OrderID" varchar(50) not null,
  "PrevStatus" varchar(50),
  "Reason" text not null,
  "Warnings" text[],
  "CancelledBy" varchar(100) not null,
  "CancelledAtUtc" timestamptz not null default now()
);

create index if not exists "IX_OnlineOrderCancellations_Order" on public."OnlineOrderCancellations" ("OrderID");

alter table public."OnlineOrderCancellations" enable row level security;
revoke all on public."OnlineOrderCancellations" from anon, authenticated;

drop function if exists public.staff_cancel_online_order(text, text, text, text, boolean);

create or replace function public.staff_cancel_online_order(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_reason text,
  p_dry_run boolean default true
)
returns table(cancelled boolean, prev_status text, warnings text[])
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '50000'
set lock_timeout = '10000'
as $$
declare
  v_order_id text := trim(coalesce(p_order_id, ''));
  v_order public."OnlineOrders"%rowtype;
  v_status text;
  v_portal boolean;
  v_warnings text[] := '{}';
  v_line text;
  v_n int;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if not exists (
    select 1 from public."StaffUsers" s
    where s."Username" = p_admin_username and s."IsActive"
      and (s."SuperUser" or coalesce(s."SalesUser", false) or coalesce(s."StoreManager", false)
           or 'ProductionManager' = any(coalesce(s."StaffRoles", '{}')))
  ) then
    raise exception 'Only a Super User, Production Manager, Sales User or Store Manager can cancel an order.';
  end if;

  begin
    select * into v_order from public."OnlineOrders" where "OrderID" = v_order_id for update;
  exception when lock_not_available then
    raise exception 'Order % is busy (a sync or another update is still running on it). Wait a minute, refresh and try again.', v_order_id;
  end;
  if not found then
    raise exception 'Order % not found.', v_order_id;
  end if;

  v_status := lower(trim(coalesce(v_order."Status", '')));
  if v_order."ReceivedAtShop" is true then
    raise exception 'Order % is a walk-in - it''s already a POS sale. Refund or exchange it at the POS instead.', v_order_id;
  end if;
  if v_status in ('canceled', 'cancelled') then
    raise exception 'Order % is already cancelled.', v_order_id;
  end if;
  if v_status in ('to ship', 'pending transfer', 'in-transit', 'shipped', 'delivered', 'received', 'completed', 'returned', 'returning') then
    raise exception 'Order % is %, it can only be cancelled before To Ship.', v_order_id, v_order."Status";
  end if;

  -- What staff should know before confirming.
  select count(*) into v_n from public."OnlineOrderProductionDone" d where d."OrderID" = v_order_id;
  if v_n > 0 then
    v_warnings := v_warnings || format('%s part(s) already marked Production Done by the makers - the built units stay at the branch.', v_n);
  elsif nullif(trim(coalesce(v_order."AssignedTankMaker", '')), '') is not null
        or nullif(trim(coalesce(v_order."AssignedStandMaker", '')), '') is not null then
    v_warnings := v_warnings || 'Makers are assigned - tell them to stop.'::text;
  end if;

  for v_line in
    select format('Production Order %s (%s) was built for this order - it stays; its output becomes normal stock.', po."No", po."Status")
    from public."ProductionOrders" po
    where po."SourceOnlineOrderId" = v_order_id and po."Status" <> 'Finished'
  loop
    v_warnings := v_warnings || v_line;
  end loop;

  select count(*) into v_n from public."ItemSerialTracking" s
  where s."Status" = 'RESERVED' and s."ReservedForOrderId" = v_order_id;
  if v_n > 0 then
    v_warnings := v_warnings || format('%s reserved serial(s) go back In Stock.', v_n);
  end if;

  if coalesce(v_order."AmountPaid", 0) > 0 then
    v_warnings := v_warnings || format('The customer has paid %s - refund it separately.', to_char(v_order."AmountPaid", 'FM999,999,990.00'));
  end if;

  if coalesce(p_dry_run, true) then
    return query select false, v_order."Status"::text, v_warnings;
    return;
  end if;

  if nullif(trim(coalesce(p_reason, '')), '') is null then
    raise exception 'A reason is required to cancel an order.';
  end if;

  v_portal := coalesce(v_order."Source", '') = 'Portal' or v_order_id ilike 'AO-%';

  if not v_portal then
    begin
      perform public._pancake_patch_online_order_status(v_order_id, jsonb_build_object('status', '6'));
    exception when others then
      raise exception 'Pancake did not accept the cancel, nothing was changed: %', sqlerrm;
    end;
  end if;

  -- Fires TR_OnlineOrders_SerialReservation (reserved serials back In Stock) and the ledger change queue.
  update public."OnlineOrders"
     set "Status" = 'Cancelled', "Last_Updated_At" = now()
   where "OrderID" = v_order_id;

  if v_portal then
    update public."AutomatedOrders"
       set "Status" = 'Cancelled', "UpdatedAtUtc" = now()
     where "PancakeReceiptNo" = v_order_id and "PancakeSyncStatus" = 'Portal';
  end if;

  insert into public."OnlineOrderCancellations" ("OrderID", "PrevStatus", "Reason", "Warnings", "CancelledBy")
  values (v_order_id, v_order."Status", trim(p_reason), v_warnings, p_admin_username);

  return query select true, v_order."Status"::text, v_warnings;
end;
$$;

grant execute on function public.staff_cancel_online_order(text, text, text, text, boolean) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'function' as section, p.proname::text as item, pg_get_function_identity_arguments(p.oid) as detail
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'staff_cancel_online_order'
union all
select 'table', c.relname::text, 'rows: ' || (select count(*) from public."OnlineOrderCancellations")
from pg_class c where c.relname = 'OnlineOrderCancellations';
