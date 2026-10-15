-- Online Orders: move an order to another branch (warehouse) - per "in the online order.. can we modify the
-- warehouse ? sometimes the location is changing so the origin of orders will be moved to different branch".
--
-- Before: only a Confirmed portal order (AO-) could change branch (admin_set_portal_order_branch,
-- Amaya / GMA). A Pancake order's branch is OnlineOrders."LocationID" = Pancake's warehouse_id, and the
-- every-minute sync puts back whatever Pancake has, so it couldn't be changed from the portal at all.
--
-- staff_change_online_order_branch(order, new warehouse id, dry run):
--   * Who: Super User, Production Manager, Sales User or Store Manager.
--   * Which orders: any open online order, portal (AO-) or Pancake - not a walk-in (its branch is the
--     store that sold it), and not once it's To Ship / Shipped / Delivered / Cancelled / Returned.
--   * Pancake orders: Pancake is changed FIRST (PATCH warehouse_id, same retrying helper as To Ship -
--     _pancake_patch_online_order_status), then re-read to make sure Pancake really took it; only then is
--     the portal's copy updated. If Pancake refuses, nothing changes and the error says so.
--     Portal (AO-) orders: changed here only (+ AutomatedOrders."Location" when the branch is Amaya / GMA).
--   * Follows on its own: the Item Ledger sale (its change queue already reposts on a LocationID change -
--     supabase_item_ledger_sales_change_queue.sql), the stock check, Stock FactBox and Ready to Ship
--     serial search (all read the order's branch).
--   * Kept, with a warning (per "Keep them, show a warning"): serials RESERVED for the order that sit at
--     another branch, and a Production Order built for it at another branch. Those units are physically
--     there - transfer them (Release Reservation -> Transfer Order -> Reserve for Order) or ship from there.
--   * p_dry_run = true (default) only returns the warnings - the page shows them before asking to confirm.
--   * Every move is logged in OnlineOrderBranchChanges.
--
-- Run AFTER supabase_serial_order_reservation.sql (reservations) and supabase_pancake_patch_retry.sql.
-- Safe to re-run. Needs js/onlineOrders.js ?v=branchmove1.

create table if not exists public."OnlineOrderBranchChanges" (
  "Id" bigint generated always as identity primary key,
  "OrderID" varchar(50) not null,
  "FromWarehouseId" varchar(50),
  "ToWarehouseId" varchar(50) not null,
  "Warnings" text[],
  "ChangedBy" varchar(100) not null,
  "ChangedAtUtc" timestamptz not null default now()
);

create index if not exists "IX_OnlineOrderBranchChanges_Order" on public."OnlineOrderBranchChanges" ("OrderID");

alter table public."OnlineOrderBranchChanges" enable row level security;
revoke all on public."OnlineOrderBranchChanges" from anon, authenticated;

drop function if exists public.staff_change_online_order_branch(text, text, text, text, boolean);

create or replace function public.staff_change_online_order_branch(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_warehouse_id text,
  p_dry_run boolean default true
)
returns table(changed boolean, from_warehouse text, to_warehouse text, warnings text[])
language plpgsql
security definer
set search_path = public, extensions
-- Pancake PATCH (up to 3 tries) + a re-read, kept under the API gateway's ~60s limit.
set statement_timeout = '50000'
set lock_timeout = '10000'
as $$
declare
  v_order_id text := trim(coalesce(p_order_id, ''));
  v_order public."OnlineOrders"%rowtype;
  v_status text;
  v_portal boolean;
  v_from_name text;
  v_to_id text;
  v_to_name text;
  v_warnings text[] := '{}';
  v_line text;
  v_get extensions.http_response;
  v_body jsonb;
  v_pancake_wh text;
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
    raise exception 'Only a Super User, Production Manager, Sales User or Store Manager can move an order to another branch.';
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
    raise exception 'Order % is a walk-in - its branch is the store that sold it and can''t be moved.', v_order_id;
  end if;
  if v_status in ('to ship', 'shipped', 'delivered', 'completed', 'canceled', 'cancelled', 'returned', 'returning') then
    raise exception 'Order % is %, its branch can only be changed before To Ship.', v_order_id, v_order."Status";
  end if;

  select w."ID", w."Name" into v_to_id, v_to_name
  from public."Warehouses" w where w."ID" = trim(coalesce(p_warehouse_id, '')) and w."IsActive";
  if v_to_id is null then
    raise exception 'Pick an active warehouse to move the order to.';
  end if;
  select w."Name" into v_from_name from public."Warehouses" w where w."ID" = v_order."LocationID";
  if v_order."LocationID" = v_to_id then
    raise exception 'Order % is already at %.', v_order_id, v_to_name;
  end if;

  -- Kept with the order, but staff should know (per "Keep them, show a warning").
  for v_line in
    select format('%s serial(s) reserved for this order are at %s: %s - transfer them to %s (Release Reservation, Transfer Order, Reserve for Order) or ship from %s.',
                  count(*), coalesce(nullif(trim(s."Location"), ''), 'no location'),
                  string_agg(s."SerialNo", ', ' order by s."SerialNo"), v_to_name,
                  coalesce(nullif(trim(s."Location"), ''), 'there'))
    from public."ItemSerialTracking" s
    where s."Status" = 'RESERVED' and s."ReservedForOrderId" = v_order_id
      and lower(trim(coalesce(s."Location", ''))) <> lower(trim(v_to_name))
    group by s."Location"
  loop
    v_warnings := v_warnings || v_line;
  end loop;

  for v_line in
    select format('Production Order %s (%s) builds this order at %s - its output lands there, not at %s.',
                  po."No", po."Status", coalesce(w."Name", po."WarehouseId"), v_to_name)
    from public."ProductionOrders" po
    left join public."Warehouses" w on w."ID" = po."WarehouseId"
    where po."SourceOnlineOrderId" = v_order_id
      and po."Status" <> 'Finished'
      and coalesce(po."WarehouseId", '') <> v_to_id
  loop
    v_warnings := v_warnings || v_line;
  end loop;

  if coalesce(p_dry_run, true) then
    return query select false, coalesce(v_from_name, v_order."LocationID")::text, v_to_name::text, v_warnings;
    return;
  end if;

  v_portal := coalesce(v_order."Source", '') = 'Portal' or v_order_id ilike 'AO-%';

  if not v_portal then
    begin
      perform public._pancake_patch_online_order_status(v_order_id, jsonb_build_object('warehouse_id', v_to_id));
    exception when others then
      raise exception 'Pancake did not accept the branch change, nothing was changed: %', sqlerrm;
    end;

    -- Make sure Pancake really moved it - otherwise the next sync would put the old branch back.
    begin
      select * into v_get from extensions.http_get(
        'https://pos.pages.fm/api/v1/shops/1328301944/orders/' || v_order_id || '?api_key=' || public._pancake_api_key());
      v_body := v_get.content::jsonb;
      v_pancake_wh := coalesce(v_body -> 'data' ->> 'warehouse_id', v_body -> 'order' ->> 'warehouse_id', v_body ->> 'warehouse_id');
    exception when others then
      v_pancake_wh := null; -- couldn't re-read; the PATCH itself succeeded
    end;
    if v_pancake_wh is not null and v_pancake_wh <> v_to_id then
      raise exception 'Pancake kept order % at its old warehouse - change it in Pancake instead. Nothing was changed on the portal.', v_order_id;
    end if;
  end if;

  update public."OnlineOrders"
     set "LocationID" = v_to_id, "Last_Updated_At" = now()
   where "OrderID" = v_order_id;

  if v_portal then
    update public."AutomatedOrders"
       set "Location" = case when v_to_name ilike '%gma%' then 'GMA' when v_to_name ilike '%amaya%' then 'Amaya' else "Location" end,
           "UpdatedAtUtc" = now()
     where "PancakeReceiptNo" = v_order_id and "PancakeSyncStatus" = 'Portal';
  end if;

  insert into public."OnlineOrderBranchChanges" ("OrderID", "FromWarehouseId", "ToWarehouseId", "Warnings", "ChangedBy")
  values (v_order_id, v_order."LocationID", v_to_id, v_warnings, p_admin_username);

  return query select true, coalesce(v_from_name, v_order."LocationID")::text, v_to_name::text, v_warnings;
end;
$$;

grant execute on function public.staff_change_online_order_branch(text, text, text, text, boolean) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'function' as section, p.proname::text as item, pg_get_function_identity_arguments(p.oid) as detail
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'staff_change_online_order_branch'
union all
select 'table', c.relname::text, 'rows: ' || (select count(*) from public."OnlineOrderBranchChanges")
from pg_class c where c.relname = 'OnlineOrderBranchChanges';
