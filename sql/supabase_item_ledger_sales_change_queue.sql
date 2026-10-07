-- Item Ledger sales: never miss an order change again - per "there is a log of sale but it did not write
-- on the item ledger entry" (walk-in 112445; also 112444, 112443, 112138, 106909, 106908 - all walk-ins,
-- Shipped, every line a stocked item, no error, reconciled once and never again).
--
-- CAUSE: cron_post_online_order_sales picks "orders that changed since they were last reconciled" by
-- comparing timestamps (SyncedAtUtc / line SyncedAtUtc vs ReconciledAtUtc). A sync stamps now() = the START
-- of its transaction and commits later, so a reconcile in between sees the order without its lines, posts
-- nothing, and stamps a LATER ReconciledAtUtc - after which the order looks unchanged forever.
-- supabase_item_ledger_sales_race_fix.sql widened the window by 5 minutes, but any write that takes longer
-- than that to become visible still slips through. Online orders hide the bug because they keep changing
-- (Confirmed -> Printed -> To Ship -> Shipped) and a later pass catches up; a walk-in arrives already
-- Shipped and never changes again, so one miss is permanent.
--
-- FIX: a change queue written by TRIGGERS, inside the same transaction as the change itself. A queue row
-- becomes visible exactly when the change does, so there's no clock to race:
--   1. public."ItemLedgerOrderDirty" - one row per relevant change (order status / warehouse / date /
--      confirmed time, any line insert / quantity / item / variant change / delete).
--   2. Triggers on OnlineOrders and OnlineOrderLines that add those rows (only when a relevant column
--      really changed, so the every-minute sync re-saving identical data adds nothing).
--   3. cron_post_online_order_sales also picks every order with queue rows; after reconciling it deletes
--      ONLY the queue rows it saw before reconciling - a change committed during the reconcile stays
--      queued and is picked up next minute. The old timestamp checks stay as a second net.
--   4. Catch-up: queues every order already missed (the six above), so the next minute's run posts them,
--      dated to their order date. The result grid lists what was queued.
--
-- Run AFTER supabase_item_ledger_sales_race_fix.sql (replaces cron_post_online_order_sales - the cron job
-- calls it by name, no reschedule). Safe to re-run. Brief trigger-creation locks on OnlineOrders /
-- OnlineOrderLines - if it times out waiting for the sync, just run it again.

set lock_timeout = '10s';

-- ---------------------------------------------------------------------------
-- 1. Queue
create table if not exists public."ItemLedgerOrderDirty" (
    "Seq"        bigserial primary key,
    "OrderID"    varchar(100) not null,
    "QueuedAtUtc" timestamptz not null default now()
);

create index if not exists "IX_ItemLedgerOrderDirty_OrderID" on public."ItemLedgerOrderDirty" ("OrderID");

alter table public."ItemLedgerOrderDirty" enable row level security;
revoke all on public."ItemLedgerOrderDirty" from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Triggers. SECURITY DEFINER so any writer (cron, portal RPCs, the desktop's service key) can queue.
--    Nothing is queued until sales posting is switched on.
create or replace function public._ile_queue_order_change()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_id text;
begin
  if not exists (select 1 from public."ItemLedgerSetup" s where s."SalesPostingStartUtc" is not null) then
    return null;
  end if;

  if TG_TABLE_NAME = 'OnlineOrders' then
    if TG_OP = 'UPDATE'
       and new."Status"         is not distinct from old."Status"
       and new."LocationID"     is not distinct from old."LocationID"
       and new."Date"           is not distinct from old."Date"
       and new."ConfirmedAtUtc" is not distinct from old."ConfirmedAtUtc" then
      return null;
    end if;
    v_order_id := new."OrderID";
  else -- OnlineOrderLines
    if TG_OP = 'UPDATE'
       and new."OrderID"     is not distinct from old."OrderID"
       and new."Quantity"    is not distinct from old."Quantity"
       and new."ItemCode"    is not distinct from old."ItemCode"
       and new."VariationId" is not distinct from old."VariationId" then
      return null;
    end if;
    if TG_OP = 'UPDATE' and new."OrderID" is distinct from old."OrderID" then
      insert into public."ItemLedgerOrderDirty" ("OrderID") values (old."OrderID");
    end if;
    v_order_id := case when TG_OP = 'DELETE' then old."OrderID" else new."OrderID" end;
  end if;

  insert into public."ItemLedgerOrderDirty" ("OrderID") values (v_order_id);
  return null;
end;
$$;

revoke execute on function public._ile_queue_order_change() from public, anon, authenticated;

drop trigger if exists "TR_OnlineOrders_ItemLedgerQueue" on public."OnlineOrders";
create trigger "TR_OnlineOrders_ItemLedgerQueue"
  after insert or update on public."OnlineOrders"
  for each row execute function public._ile_queue_order_change();

drop trigger if exists "TR_OnlineOrderLines_ItemLedgerQueue" on public."OnlineOrderLines";
create trigger "TR_OnlineOrderLines_ItemLedgerQueue"
  after insert or update or delete on public."OnlineOrderLines"
  for each row execute function public._ile_queue_order_change();

reset lock_timeout;

-- ---------------------------------------------------------------------------
-- 3. Cron pass: queued orders first, then the old timestamp net (supabase_item_ledger_sales_race_fix.sql).
create or replace function public.cron_post_online_order_sales()
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_start timestamptz;
  v_order_id text;
  v_seqs bigint[];
  v_done int := 0;
  v_margin constant interval := interval '5 minutes';
begin
  select s."SalesPostingStartUtc" into v_start from public."ItemLedgerSetup" s limit 1;
  if v_start is null then
    return 0;
  end if;

  for v_order_id in
    select c.order_id from (
      select d."OrderID" as order_id, 0 as pri, min(d."Seq") as ord
      from public."ItemLedgerOrderDirty" d
      group by d."OrderID"
      union all
      select o."OrderID", 1, null
      from public."OnlineOrders" o
      left join public."ItemLedgerOrderSync" s on s."OrderID" = o."OrderID"
      where (o."ConfirmedAtUtc" >= v_start or o."Date" >= (v_start at time zone 'Asia/Manila')::date - 1)
        and (
          s."OrderID" is null
          or o."SyncedAtUtc" > s."ReconciledAtUtc" - v_margin
          or o."Last_Updated_At" > s."ReconciledAtUtc" - v_margin
          or exists (
            select 1 from public."OnlineOrderLines" l
            where l."OrderID" = o."OrderID" and l."SyncedAtUtc" > s."ReconciledAtUtc" - v_margin
          )
        )
    ) c
    group by c.order_id
    order by min(c.pri), min(c.ord) nulls last
    limit 200
  loop
    -- Held to the end of this run, so a concurrent run can't reconcile the same order on an older view.
    -- _ile_reconcile_online_order takes the same lock again (re-entrant within this transaction).
    if not pg_try_advisory_xact_lock(hashtext('ile_sales|' || v_order_id)) then
      continue; -- someone else has it; its queue rows stay for next minute
    end if;

    -- The queue rows this reconcile is guaranteed to cover (all committed before it reads the order).
    select array_agg(d."Seq") into v_seqs from public."ItemLedgerOrderDirty" d where d."OrderID" = v_order_id;

    begin
      perform public._ile_reconcile_online_order(v_order_id);
    exception when others then
      -- One bad order (unknown warehouse, ...) must not stop the rest. Recorded, and not retried until it
      -- changes again (its queue rows are cleared below either way).
      insert into public."ItemLedgerOrderSync" ("OrderID", "ReconciledAtUtc", "LastError")
      values (v_order_id, now(), sqlerrm)
      on conflict ("OrderID") do update set "ReconciledAtUtc" = now(), "LastError" = excluded."LastError";
    end;

    if v_seqs is not null then
      delete from public."ItemLedgerOrderDirty" d where d."Seq" = any(v_seqs);
    end if;
    v_done := v_done + 1;
  end loop;

  return v_done;
end;
$$;

revoke execute on function public.cron_post_online_order_sales() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Catch-up: queue every counted order since the cutover that has a stocked line but no Sales Order
--    entries (same filter as supabase_diagnose_item_ledger_missed_sales.sql). The every-minute job posts
--    them on its next run. Re-running only queues what is still missing.
with missed as (
  select o."OrderID", o."Date", coalesce(o."ReceivedAtShop", false) as walkin
  from public."OnlineOrders" o
  cross join (select "SalesPostingStartUtc" as start_utc from public."ItemLedgerSetup") st
  where st.start_utc is not null
    and public._ile_order_counts_as_sale(o."Status")
    and coalesce(o."ConfirmedAtUtc" >= st.start_utc, o."Date" > (st.start_utc at time zone 'Asia/Manila')::date, false)
    and coalesce(o."LocationID", '') <> ''
    and not exists (
      select 1 from public."ItemLedgerEntries" e where e."DocumentType" = 'Sales Order' and e."DocumentNo" = o."OrderID"
    )
    and exists (
      select 1 from public."OnlineOrderLines" l
      left join public."Variants" v on v."VariationId" = l."VariationId"
      where l."OrderID" = o."OrderID" and coalesce(l."Quantity", 0) > 0
        and exists (select 1 from public._ile_try_resolve_stock_key(coalesce(v."ItemCode", l."ItemCode"), nullif(trim(coalesce(l."VariationId", '')), '')))
    )
),
queued as (
  insert into public."ItemLedgerOrderDirty" ("OrderID")
  select m."OrderID" from missed m
  returning "OrderID"
)
select m."OrderID" as queued_order_id, m."Date" as order_date, m.walkin,
       'queued - posts within a minute (check Item Ledger Entries)' as note
from missed m
join queued q on q."OrderID" = m."OrderID"
order by m."Date" desc, m."OrderID" desc;
