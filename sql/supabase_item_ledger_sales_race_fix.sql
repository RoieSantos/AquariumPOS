-- Fixes orders that never took their stock out of the Item Ledger even though every condition passes - per
-- "there is a order that did not deduct an item ledger entries" (order 105080: Shipped, has a warehouse,
-- its one line (M-013) resolves, no error - yet no Sales Order entries, and never revisited).
--
-- CAUSE: a race between two every-minute cron jobs. The order refresh (cron_refresh_open_online_orders /
-- _refresh_open_online_order, _sync_online_order_detail) stamps "SyncedAtUtc" = now() - the START of its
-- transaction - then spends seconds on Pancake calls before committing. When the sales-posting cron
-- (cron_post_online_order_sales, supabase_item_ledger_sales.sql) reconciles the order during that window,
-- it still sees the old/empty row (no status, no lines), posts nothing, and stamps ReconciledAtUtc =
-- now(). The refresh then commits with a SyncedAtUtc EARLIER than that ReconciledAtUtc, so "changed since
-- last reconcile" (SyncedAtUtc > ReconciledAtUtc) is never true and the order is never looked at again.
-- 105080: ReconciledAtUtc 16:43:00.08, right on the minute when both jobs start.
--
-- FIX: the picker treats anything written up to 5 minutes before the last reconcile as possibly unseen,
-- so an order is reconciled again for a few minutes after each change. Reconciling is local-only (no
-- Pancake calls) and posts only the difference, so the extra passes post nothing twice.
--
-- Run AFTER supabase_item_ledger_sales.sql. Replaces one function (the cron job calls it by name - no
-- reschedule). Then step 2 catches up every order already missed this way.

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
  -- How far back a write can be stamped relative to when it became visible (a refresh's Pancake calls).
  v_margin constant interval := interval '5 minutes';
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
        or o."SyncedAtUtc" > s."ReconciledAtUtc" - v_margin
        or o."Last_Updated_At" > s."ReconciledAtUtc" - v_margin
        or exists (
          select 1 from public."OnlineOrderLines" l
          where l."OrderID" = o."OrderID" and l."SyncedAtUtc" > s."ReconciledAtUtc" - v_margin
        )
      )
    -- Never-reconciled and freshly changed orders first, so the margin's repeat passes can't crowd them out.
    order by (s."OrderID" is null) desc, o."Last_Updated_At" desc nulls last
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

-- ---------------------------------------------------------------------------
-- 2. Catch up orders already missed this way: re-reconcile every counted order since the cutover that has
--    no Sales Order entries yet but does have a stocked line. Posts only what's missing. Returns one row
--    per order with how many entries it wrote (0 = nothing to post, e.g. only custom/non-stock lines).
select o."OrderID", public._ile_reconcile_online_order(o."OrderID") as entries_posted
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
order by o."OrderID";
