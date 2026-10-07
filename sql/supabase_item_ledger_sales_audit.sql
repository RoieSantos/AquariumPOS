-- Item Ledger sales: self-check + self-heal - per "can we make sure this will never happen again?" after
-- walk-ins 112445 / 112444 / 112443 / 112138 / 106909 / 106908 silently never took their stock out.
--
-- supabase_item_ledger_sales_change_queue.sql closed the hole that caused those (changes are now queued
-- by triggers, so the posting job can't miss one). This is the second, independent line of defence for
-- anything nobody has thought of yet - it doesn't care HOW an order was missed:
--
--   1. _ile_sales_audit(): compares, for every order since the cutover, what the order says should have
--      left stock (its stocked lines, if it counts as a sale) with what the ledger actually has under
--      that order (Sales Order entries) - per item + variant + warehouse, the same rule the posting uses.
--      Any difference = an issue. Also lists counted orders whose posting ERRORED (e.g. no warehouse).
--      Orders still waiting in the queue are left out (they're about to be posted).
--   2. cron_ile_sales_self_heal(), every 15 minutes: re-queues every mismatched order so the next minute's
--      run posts the difference, and logs each one to "ItemLedgerSalesAuditLog" - so a fix that happens
--      on its own is still on record, and a recurring cause shows up as a pattern.
--   3. admin_get_item_ledger_sales_issues(): what the Item Ledger Entries page shows in its message bar -
--      the open issues (amber) plus how many orders were auto-fixed in the last 7 days.
--
-- Also catches cases the queue can't: an item / variant added to Items AFTER an order with it synced
-- (the line couldn't be tied to stock then, can now), or a posting job that was down for a while.
--
-- Run AFTER supabase_item_ledger_sales_change_queue.sql. Safe to re-run. Ends with a check of the
-- current issues (should be empty once the catch-up from the queue file has posted).

-- ---------------------------------------------------------------------------
-- 1. Audit
create or replace function public._ile_sales_audit()
returns table(order_id text, order_date date, walkin boolean, status text, issue text)
language sql
stable
security definer
set search_path = public, extensions
as $$
  with st as (
    select s."SalesPostingStartUtc" as start_utc
    from public."ItemLedgerSetup" s
    where s."SalesPostingStartUtc" is not null
    limit 1
  ),
  orders as (
    select o."OrderID" as oid, o."Date" as odate, coalesce(o."ReceivedAtShop", false) as walkin, o."Status" as status,
           coalesce(o."LocationID", '') as wh,
           public._ile_order_counts_as_sale(o."Status")
             and coalesce(o."ConfirmedAtUtc" >= st.start_utc, o."Date" > (st.start_utc at time zone 'Asia/Manila')::date, false) as counts
    from public."OnlineOrders" o
    cross join st
    where o."ConfirmedAtUtc" >= st.start_utc
       or o."Date" >= (st.start_utc at time zone 'Asia/Manila')::date - 1
  ),
  desired as (
    select o.oid, r.item_code, r.variant_id, o.wh, sum(l."Quantity") as qty
    from orders o
    join public."OnlineOrderLines" l on l."OrderID" = o.oid and coalesce(l."Quantity", 0) > 0
    left join public."Variants" v on v."VariationId" = l."VariationId"
    cross join lateral public._ile_try_resolve_stock_key(coalesce(v."ItemCode", l."ItemCode"), nullif(trim(coalesce(l."VariationId", '')), '')) r
    where o.counts and o.wh <> ''
    group by o.oid, r.item_code, r.variant_id, o.wh
  ),
  posted as (
    select e."DocumentNo" as oid, e."ItemCode" as item_code, e."VariantId" as variant_id, e."WarehouseId" as wh, -sum(e."Quantity") as qty
    from public."ItemLedgerEntries" e
    where e."DocumentType" = 'Sales Order'
      and e."DocumentNo" in (select oid from orders)
    group by e."DocumentNo", e."ItemCode", e."VariantId", e."WarehouseId"
  ),
  mismatched as (
    select distinct coalesce(d.oid, p.oid) as oid
    from desired d
    full join posted p
      on p.oid = d.oid
     and p.item_code = d.item_code
     and p.variant_id is not distinct from d.variant_id
     and p.wh = d.wh
    where coalesce(d.qty, 0) <> coalesce(p.qty, 0)
  ),
  flagged as (
    select m.oid from mismatched m
    union
    select o.oid
    from orders o
    join public."ItemLedgerOrderSync" s on s."OrderID" = o.oid
    where o.counts and s."LastError" is not null
  )
  select o.oid::text, o.odate, o.walkin, o.status::text,
         case
           when s."LastError" is not null then 'Posting failed: ' || s."LastError"
           when not exists (select 1 from posted p where p.oid = o.oid) then 'Sale not posted to the ledger'
           when not o.counts then 'Cancelled/returned but its stock was not put back'
           else 'Ledger quantities do not match the order'
         end
  from flagged f
  join orders o on o.oid = f.oid
  left join public."ItemLedgerOrderSync" s on s."OrderID" = o.oid
  where not exists (select 1 from public."ItemLedgerOrderDirty" d where d."OrderID" = o.oid)
  order by o.odate desc, o.oid desc;
$$;

revoke execute on function public._ile_sales_audit() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Self-heal log + job
create table if not exists public."ItemLedgerSalesAuditLog" (
    "Id"         bigserial primary key,
    "RunAtUtc"   timestamptz not null default now(),
    "OrderID"    varchar(100) not null,
    "OrderDate"  date,
    "Walkin"     boolean,
    "Issue"      text
);

create index if not exists "IX_ItemLedgerSalesAuditLog_RunAt" on public."ItemLedgerSalesAuditLog" ("RunAtUtc");

alter table public."ItemLedgerSalesAuditLog" enable row level security;
revoke all on public."ItemLedgerSalesAuditLog" from anon, authenticated;

-- Re-queues every flagged order (the posting job posts the difference within a minute) and logs it.
-- Errored orders are re-queued too (a fixed warehouse etc. then posts on its own), but logged only the
-- first time in a day so a stuck one doesn't flood the log.
create or replace function public.cron_ile_sales_self_heal()
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_count int := 0;
begin
  create temp table if not exists _ile_heal (order_id text, order_date date, walkin boolean, issue text) on commit drop;
  truncate _ile_heal;

  insert into _ile_heal select a.order_id, a.order_date, a.walkin, a.issue from public._ile_sales_audit() a;

  insert into public."ItemLedgerOrderDirty" ("OrderID") select h.order_id from _ile_heal h;

  insert into public."ItemLedgerSalesAuditLog" ("OrderID", "OrderDate", "Walkin", "Issue")
  select h.order_id, h.order_date, h.walkin, h.issue
  from _ile_heal h
  where h.issue not like 'Posting failed:%'
     or not exists (
       select 1 from public."ItemLedgerSalesAuditLog" g
       where g."OrderID" = h.order_id and g."Issue" = h.issue and g."RunAtUtc" > now() - interval '1 day'
     );

  select count(*) into v_count from _ile_heal;
  return v_count;
end;
$$;

revoke execute on function public.cron_ile_sales_self_heal() from public, anon, authenticated;

do $$
begin
  perform cron.unschedule('item-ledger-sales-self-heal');
exception when others then
  null; -- job didn't exist yet
end;
$$;

select cron.schedule(
  'item-ledger-sales-self-heal',
  '*/15 * * * *',
  $$select public.cron_ile_sales_self_heal();$$
);

-- ---------------------------------------------------------------------------
-- 3. For the Item Ledger Entries page's message bar.
drop function if exists public.admin_get_item_ledger_sales_issues(text, text);

create or replace function public.admin_get_item_ledger_sales_issues(
  p_admin_username text,
  p_admin_password text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return jsonb_build_object(
    'issues', coalesce((
      select jsonb_agg(jsonb_build_object('order_id', a.order_id, 'order_date', a.order_date, 'walkin', a.walkin, 'issue', a.issue))
      from public._ile_sales_audit() a
    ), '[]'::jsonb),
    'auto_fixed_7d', (
      select count(distinct g."OrderID")
      from public."ItemLedgerSalesAuditLog" g
      where g."RunAtUtc" > now() - interval '7 days' and g."Issue" not like 'Posting failed:%'
    )
  );
end;
$$;

grant execute on function public.admin_get_item_ledger_sales_issues(text, text) to anon;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Check (the result the editor shows): open issues right now. Empty = every order since the cutover
-- matches the ledger. Rows here right after running the queue file = the catch-up hasn't posted yet;
-- wait a minute and re-run this file (safe).
select order_id, order_date, walkin, status, issue from public._ile_sales_audit();
