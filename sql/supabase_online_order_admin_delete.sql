-- Super User "Delete Order" on the Online Order card - per "can you allow a super user to delete a
-- order .. this is for cleaning purposes only" - and multi-select "Delete Selected" on the list - per
-- "can we do multi selection deletion on the list?". Generalizes the one-off
-- supabase_delete_online_order_1821.sql into RPCs behind buttons.
--
--   admin_delete_online_order(user, pass, order_id)      Super User only (is_admin_authorized) - card button.
--   admin_delete_online_orders(user, pass, order_ids[])  Same, for the list's Delete Selected; returns one
--                                                        row per order (deleted / refusal reason).
--
-- Refuses an order (nothing deleted for it) when it already touched stock:
--   * ItemLedgerEntries rows with DocumentType 'Sales Order' for it - ledger rows are never deleted,
--     that case needs a reversing entry instead.
--   * Serials sold against it (ItemSerialTracking.SoldOnlineOrderId) - they'd be left pointing at an
--     order that no longer exists.
-- Otherwise deletes the order and every portal row keyed on it (same list as the 1821 script, plus
-- ItemLedgerOrderDirty).
--
-- OnlineOrdersDeleted remembers each deleted OrderID, and BEFORE INSERT triggers on OnlineOrders /
-- OnlineOrderLines silently skip it - otherwise the desktop POS (SyncOnlineOrdersToSupabaseAsync posts
-- every local order missing in Supabase) or the next Pancake sync would put it straight back. Applies to
-- every role, on purpose - this is for junk/test orders. To bring one back, delete its
-- OnlineOrdersDeleted row and let the sync re-pull it.
--
-- Uploaded files (status photos / line attachments) stay in Storage - only their rows are removed.
-- Safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. Deleted orders (tombstones).
create table if not exists public."OnlineOrdersDeleted" (
  "OrderID" text primary key,
  "CustomerName" text,
  "Status" text,
  "DeletedBy" text,
  "DeletedAtUtc" timestamptz not null default now()
);

alter table public."OnlineOrdersDeleted" enable row level security;
revoke all on public."OnlineOrdersDeleted" from anon, authenticated;

create or replace function public._skip_deleted_online_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public."OnlineOrdersDeleted" d where d."OrderID" = NEW."OrderID"::text) then
    return null;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_skip_deleted_online_order on public."OnlineOrders";
create trigger trg_skip_deleted_online_order
  before insert on public."OnlineOrders"
  for each row
  execute function public._skip_deleted_online_order();

drop trigger if exists trg_skip_deleted_online_order_line on public."OnlineOrderLines";
create trigger trg_skip_deleted_online_order_line
  before insert on public."OnlineOrderLines"
  for each row
  execute function public._skip_deleted_online_order();

-- ---------------------------------------------------------------------------
-- 2. Shared delete (no auth check - only called by the RPCs below). Raises when the order can't go.
create or replace function public._delete_online_order_core(p_order_id text, p_deleted_by text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id text := trim(coalesce(p_order_id, ''));
  v_customer text;
  v_status text;
  v_count int;
begin
  if v_id = '' then
    raise exception 'Order is required.';
  end if;

  select "CustomerName", "Status" into v_customer, v_status
  from public."OnlineOrders" where "OrderID" = v_id
  for update;
  if not found then
    raise exception 'Order % not found.', v_id;
  end if;

  select count(*) into v_count from public."ItemLedgerEntries"
  where "DocumentType" = 'Sales Order' and "DocumentNo" = v_id;
  if v_count > 0 then
    raise exception 'Order % already posted stock (% Item Ledger entr%) - it can''t be deleted. Reverse the stock first.',
      v_id, v_count, case when v_count = 1 then 'y' else 'ies' end;
  end if;

  select count(*) into v_count from public."ItemSerialTracking" where "SoldOnlineOrderId" = v_id;
  if v_count > 0 then
    raise exception 'Order % has % serial(s) sold against it - it can''t be deleted.', v_id, v_count;
  end if;

  insert into public."OnlineOrdersDeleted" ("OrderID", "CustomerName", "Status", "DeletedBy")
  values (v_id, v_customer, v_status, p_deleted_by)
  on conflict ("OrderID") do update
    set "CustomerName" = excluded."CustomerName", "Status" = excluded."Status",
        "DeletedBy" = excluded."DeletedBy", "DeletedAtUtc" = now();

  delete from public."DeliveryStops"               where "OrderID" = v_id;  -- FK to OnlineOrders
  delete from public."OnlineOrderLineReleases"     where "OrderID" = v_id;
  delete from public."OnlineOrderLineAttachments"  where "OrderID" = v_id;
  delete from public."OnlineOrderLines"            where "OrderID" = v_id;
  delete from public."OnlineOrderLinesRemoved"     where "OrderID" = v_id;  -- after Lines: its delete trigger refills this
  delete from public."OnlineOrderAssignedMessages" where "OrderID" = v_id;
  delete from public."OnlineOrderStatusPhotos"     where "OrderID" = v_id;
  delete from public."OnlineOrderPayments"         where "OrderID" = v_id;
  delete from public."OnlineOrderPaymentScans"     where "OrderID" = v_id;
  delete from public."OnlineOrderProductionDone"   where "OrderID" = v_id;
  delete from public."OnlineOrderProductionRework" where "OrderID" = v_id;
  delete from public."OnlineOrderShipments"        where "OrderID" = v_id;
  delete from public."ItemLedgerOrderSync"         where "OrderID" = v_id;
  delete from public."ItemLedgerOrderDirty"        where "OrderID" = v_id;

  delete from public."OnlineOrders" where "OrderID" = v_id;
end;
$$;

revoke all on function public._delete_online_order_core(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Single delete (Online Order card's Delete Order button).
drop function if exists public.admin_delete_online_order(text, text, text);

create or replace function public.admin_delete_online_order(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Only a Super User can delete an order.';
  end if;
  perform public._delete_online_order_core(p_order_id, p_admin_username);
end;
$$;

grant execute on function public.admin_delete_online_order(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 4. Bulk delete (list's Delete Selected). Each order is its own sub-transaction: a refused one
-- (stock posted / serials sold / not found) comes back with the reason and the rest still go.
drop function if exists public.admin_delete_online_orders(text, text, text[]);

create or replace function public.admin_delete_online_orders(
  p_admin_username text,
  p_admin_password text,
  p_order_ids text[]
)
returns table (order_id text, deleted boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Only a Super User can delete orders.';
  end if;

  for v_id in
    select distinct trim(x) from unnest(coalesce(p_order_ids, '{}'::text[])) x
    where coalesce(trim(x), '') <> ''
  loop
    begin
      perform public._delete_online_order_core(v_id, p_admin_username);
      order_id := v_id; deleted := true; message := null;
    exception when others then
      order_id := v_id; deleted := false; message := sqlerrm;
    end;
    return next;
  end loop;
end;
$$;

grant execute on function public.admin_delete_online_orders(text, text, text[]) to anon;
