-- Item Ledger Entries - SALES. A confirmed order takes its stock out of the ledger, per "On
-- Confirmed". Completes the move of inventory off Pancake: receipts, transfers and now sales all
-- write the portal's own ledger.
--
-- Run AFTER supabase_item_ledger_entries.sql and supabase_item_ledger_hooks.sql. Sales posting
-- stays OFF until you press "Start Posting Sales From Now" on the Item Ledger Entries page, once
-- your starting stock is loaded (supabase_item_ledger_stock_count.sql) - that sets
-- ItemLedgerSetup."SalesPostingStartUtc". Until then this file only creates the pieces.
--
-- HOW IT WORKS - RECONCILE, NOT EVENTS
-- Orders reach public."OnlineOrders" by sync from Pancake, and their lines arrive SEPARATELY (a
-- background backfill), can be edited later, and the order can be cancelled. Hooking "the moment
-- an order is confirmed" would miss all of that. Instead, for each order, the ledger is simply
-- brought into line with what the order currently says:
--     desired = the order's lines (if it counts as a sale)      posted = what the ledger has for it
--     post the DIFFERENCE, per item + variant + warehouse.
-- So: a new confirmed order posts its lines; a line added/changed later posts the delta; a
-- cancellation posts the opposite entries; running it twice posts nothing. A cron job runs it every
-- minute over the orders that changed since they were last reconciled.
--
-- WHAT COUNTS AS A SALE: any stored order whose status is not cancelled/removed/returned/refunded.
-- ('New' orders are never stored by the sync, so everything stored is already at least confirmed.)
-- Walk-in (received at shop) orders count the same way.
--
-- FROM WHICH WAREHOUSE: OnlineOrders."LocationID" (Pancake's order warehouse).
--
-- CUTOVER: only orders confirmed AFTER SalesPostingStartUtc post. Earlier sales are assumed to be
-- reflected in the stock you counted, so posting them again would take the stock out twice. An
-- order with no recorded confirmation time is judged by its order date instead (strictly after the
-- start date).
--
-- WHAT IS DELIBERATELY SKIPPED: a line that can't be tied to a stocked item (a custom aquarium,
-- a service, an unknown product) simply isn't inventory and is ignored; supabase_diagnose_
-- item_ledger_sales.sql lists them so a genuinely stocked item that failed to match is visible.
--
-- KNOWN LIMIT: the line sync only inserts/updates, it never deletes, so a line REMOVED from an
-- order in Pancake stays in OnlineOrderLines and keeps counting. Edits to quantity are fine.

-- ============================================================================
-- 1. Setup + per-order state
-- ============================================================================

create table if not exists public."ItemLedgerSetup" (
    "Id" boolean primary key default true check ("Id"),
    -- NULL = sales posting is off. Set once, by the "Start Posting Sales From Now" button on the
    -- Item Ledger Entries page (or by the optional Pancake opening-balance seed).
    "SalesPostingStartUtc" timestamptz,
    "UpdatedAtUtc" timestamptz not null default now()
);

insert into public."ItemLedgerSetup" ("Id") values (true) on conflict ("Id") do nothing;

alter table public."ItemLedgerSetup" enable row level security;
revoke all on public."ItemLedgerSetup" from anon, authenticated;

-- When each order was last reconciled, so the cron only revisits orders that changed since.
create table if not exists public."ItemLedgerOrderSync" (
    "OrderID" varchar(100) primary key,
    "ReconciledAtUtc" timestamptz not null default now(),
    -- Set when the last attempt failed (e.g. the order's warehouse isn't in Warehouses). The order
    -- isn't retried until it changes again.
    "LastError" text
);

alter table public."ItemLedgerOrderSync" enable row level security;
revoke all on public."ItemLedgerOrderSync" from anon, authenticated;

-- ============================================================================
-- 2. Helpers
-- ============================================================================

create or replace function public._ile_order_counts_as_sale(p_status text)
returns boolean
language sql
immutable
as $$
  select lower(trim(coalesce(p_status, ''))) <> ''
     and lower(trim(p_status)) !~ '(cancel|remov|return|refund|delet)'
$$;

-- _ile_resolve_stock_key without the exceptions: returns no row for a line that can't be tied to a
-- stocked item, instead of failing the whole order.
create or replace function public._ile_try_resolve_stock_key(p_item_code text, p_variant_id text)
returns table(item_code text, variant_id text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if nullif(trim(coalesce(p_item_code, '')), '') is null
     or not exists (select 1 from public."Items" i where i."Code" = trim(p_item_code)) then
    return;
  end if;

  begin
    return query select k.item_code, k.variant_id from public._ile_resolve_stock_key(p_item_code, p_variant_id) k;
  exception when others then
    return;
  end;
end;
$$;

revoke execute on function public._ile_try_resolve_stock_key(text, text) from public, anon, authenticated;

-- ============================================================================
-- 3. Reconcile one order
-- ============================================================================

create or replace function public._ile_reconcile_online_order(p_order_id text)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_start timestamptz;
  v_order record;
  v_found boolean;
  v_counts boolean;
  v_first boolean;
  v_date date;
  v_transaction_no bigint;
  v_row record;
  v_posted int := 0;
  v_location text;
begin
  select s."SalesPostingStartUtc" into v_start from public."ItemLedgerSetup" s limit 1;
  if v_start is null then
    return 0;
  end if;

  -- One reconcile per order at a time, so two overlapping runs can't both post the same delta.
  if not pg_try_advisory_xact_lock(hashtext('ile_sales|' || p_order_id)) then
    return 0;
  end if;

  select o."Status", o."LocationID", o."Date", o."ConfirmedAtUtc" into v_order
    from public."OnlineOrders" o where o."OrderID" = p_order_id;
  v_found := found;

  v_counts := v_found
    and public._ile_order_counts_as_sale(v_order."Status")
    and coalesce(v_order."ConfirmedAtUtc" >= v_start, v_order."Date" > (v_start at time zone 'Asia/Manila')::date, false);

  v_location := coalesce(v_order."LocationID", '');
  if v_counts and v_location = '' then
    raise exception 'Order % has no warehouse (LocationID), so its stock cannot be taken from anywhere.', p_order_id;
  end if;

  v_first := not exists (
    select 1 from public."ItemLedgerEntries" e where e."DocumentType" = 'Sales Order' and e."DocumentNo" = p_order_id
  );

  -- The first posting is dated to the order (never before the cutover day); later corrections are
  -- dated today, when they actually happened.
  v_date := case
    when v_first then greatest(
      coalesce((v_order."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, v_order."Date", public._ile_today()),
      (v_start at time zone 'Asia/Manila')::date)
    else public._ile_today()
  end;

  for v_row in
    with lines as (
      select
        coalesce(v."ItemCode", l."ItemCode") as raw_item,
        nullif(trim(coalesce(l."VariationId", '')), '') as raw_variant,
        l."Quantity" as qty
      from public."OnlineOrderLines" l
      left join public."Variants" v on v."VariationId" = l."VariationId"
      where v_counts and l."OrderID" = p_order_id and coalesce(l."Quantity", 0) > 0
    ),
    desired as (
      select r.item_code, r.variant_id, v_location as warehouse_id, sum(li.qty) as qty
      from lines li
      cross join lateral public._ile_try_resolve_stock_key(li.raw_item, li.raw_variant) r
      group by r.item_code, r.variant_id
    ),
    posted as (
      select e."ItemCode" as item_code, e."VariantId" as variant_id, e."WarehouseId" as warehouse_id, -sum(e."Quantity") as qty
      from public."ItemLedgerEntries" e
      where e."DocumentType" = 'Sales Order' and e."DocumentNo" = p_order_id
      group by e."ItemCode", e."VariantId", e."WarehouseId"
    )
    select
      coalesce(d.item_code, p.item_code) as item_code,
      coalesce(d.variant_id, p.variant_id) as variant_id,
      coalesce(d.warehouse_id, p.warehouse_id) as warehouse_id,
      coalesce(d.qty, 0) - coalesce(p.qty, 0) as delta
    from desired d
    full join posted p
      on d.item_code = p.item_code
     and d.variant_id is not distinct from p.variant_id
     and d.warehouse_id = p.warehouse_id
    where coalesce(d.qty, 0) - coalesce(p.qty, 0) <> 0
  loop
    v_transaction_no := coalesce(v_transaction_no, nextval('public.ile_transaction_no_seq'));

    perform public._ile_post(
      'Sale',
      v_row.item_code,
      v_row.variant_id,
      v_row.warehouse_id,
      -v_row.delta,
      v_date,
      'Sales Order',
      p_order_id,
      case
        when v_first then 'Sold on order ' || p_order_id
        when v_counts then 'Order ' || p_order_id || ' changed'
        else 'Order ' || p_order_id || ' cancelled'
      end,
      v_transaction_no,
      'system'
    );
    v_posted := v_posted + 1;
  end loop;

  insert into public."ItemLedgerOrderSync" ("OrderID", "ReconciledAtUtc", "LastError")
  values (p_order_id, now(), null)
  on conflict ("OrderID") do update set "ReconciledAtUtc" = now(), "LastError" = null;

  return v_posted;
end;
$$;

revoke execute on function public._ile_reconcile_online_order(text) from public, anon, authenticated;

-- ============================================================================
-- 4. Cron: revisit orders that changed
-- ============================================================================

create or replace function public.cron_post_online_order_sales()
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_start timestamptz;
  v_order_id text;
  v_done int := 0;
begin
  select s."SalesPostingStartUtc" into v_start from public."ItemLedgerSetup" s limit 1;
  if v_start is null then
    return 0;
  end if;

  for v_order_id in
    select o."OrderID"
    from public."OnlineOrders" o
    left join public."ItemLedgerOrderSync" s on s."OrderID" = o."OrderID"
    where (o."ConfirmedAtUtc" >= v_start or o."Date" >= (v_start at time zone 'Asia/Manila')::date - 1)
      and (
        s."OrderID" is null
        or o."SyncedAtUtc" > s."ReconciledAtUtc"
        or o."Last_Updated_At" > s."ReconciledAtUtc"
        or exists (
          select 1 from public."OnlineOrderLines" l
          where l."OrderID" = o."OrderID" and l."SyncedAtUtc" > s."ReconciledAtUtc"
        )
      )
    order by o."Last_Updated_At" desc nulls last
    limit 200
  loop
    begin
      perform public._ile_reconcile_online_order(v_order_id);
    exception when others then
      -- One bad order (unknown warehouse, ...) must not stop the rest. It is recorded and left
      -- alone until the order changes again.
      insert into public."ItemLedgerOrderSync" ("OrderID", "ReconciledAtUtc", "LastError")
      values (v_order_id, now(), sqlerrm)
      on conflict ("OrderID") do update set "ReconciledAtUtc" = now(), "LastError" = excluded."LastError";
    end;
    v_done := v_done + 1;
  end loop;

  return v_done;
end;
$$;

revoke execute on function public.cron_post_online_order_sales() from public, anon, authenticated;

do $$
begin
  perform cron.unschedule('item-ledger-sales-posting');
exception when others then
  null; -- job didn't exist yet - nothing to unschedule
end;
$$;

select cron.schedule(
  'item-ledger-sales-posting',
  '* * * * *',
  $$select public.cron_post_online_order_sales();$$
);

drop function if exists public.admin_post_online_order_sales_now(text, text);

-- "Post sales now": runs the same pass on demand instead of waiting for the next minute. Returns
-- how many orders were looked at.
create or replace function public.admin_post_online_order_sales_now(
  p_admin_username text,
  p_admin_password text
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return public.cron_post_online_order_sales();
end;
$$;

grant execute on function public.admin_post_online_order_sales_now(text, text) to anon;

-- ============================================================================
-- 5. Keep Items."QuantityInStock" in step with the ledger
-- ============================================================================

-- Order Now's "In stock", the AI bot's stock answers, Item Setup and the catalogue searches all
-- read Items."QuantityInStock", which used to be fed from Pancake/the desktop. Rather than change
-- every one of those readers, the ledger now maintains that column itself: after every entry the
-- item's total across all warehouses is written back. Rounded because the column is an integer;
-- negative when stock has gone negative.
create or replace function public._ile_sync_item_quantity()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  update public."Items" i
     set "QuantityInStock" = round(coalesce((
       select sum(e."Quantity") from public."ItemLedgerEntries" e where e."ItemCode" = new."ItemCode"
     ), 0))::int
   where i."Code" = new."ItemCode";
  return new;
end;
$$;

drop trigger if exists "TR_ItemLedgerEntries_SyncItemQuantity" on public."ItemLedgerEntries";
create trigger "TR_ItemLedgerEntries_SyncItemQuantity"
  after insert on public."ItemLedgerEntries"
  for each row execute function public._ile_sync_item_quantity();

-- Full recompute, for the seed: items the ledger has never touched are set to 0 so a stale Pancake
-- number can't keep saying "In stock" for something the portal has no stock of.
create or replace function public._ile_sync_all_item_quantities()
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_count int;
begin
  update public."Items" i
     set "QuantityInStock" = round(coalesce(t.total, 0))::int
    from (
      select it."Code" as code, (select sum(e."Quantity") from public."ItemLedgerEntries" e where e."ItemCode" = it."Code") as total
      from public."Items" it
    ) t
   where i."Code" = t.code
     and i."QuantityInStock" is distinct from round(coalesce(t.total, 0))::int;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public._ile_sync_all_item_quantities() from public, anon, authenticated;

notify pgrst, 'reload schema';
