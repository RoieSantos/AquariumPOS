-- Walk-in order 112445 (POS receipt RS-0000011110, Shipped) - copy of supabase_diagnose_item_ledger_order.sql
-- with two extra info rows (11, 12).
--
-- Why didn't ONE order take its stock out of the Item Ledger? Read-only - nothing here writes anything
-- (the one helper is a pg_temp function, gone when the session ends).
--
-- Walks every condition _ile_reconcile_online_order / cron_post_online_order_sales
-- (supabase_item_ledger_sales.sql) needs, in order, and says which one the order fails. For all orders
-- at once, see supabase_diagnose_item_ledger_sales.sql instead.
--
-- Put the order number in the "params" line of query 1 and in the commented lines at the end (search for '112445'),
-- then run the whole file in the Supabase SQL editor - it shows one grid.

-- Captures the exact reason a line can't be tied to a stocked item (the real resolver raises; the one
-- the posting uses swallows the error, so the reason is otherwise invisible).
create or replace function pg_temp.ile_line_reason(p_item_code text, p_variant_id text)
returns text
language plpgsql
as $$
declare
  v_item text;
  v_variant text;
begin
  if nullif(trim(coalesce(p_item_code, '')), '') is null then
    return 'NO ITEM CODE on the line - not inventory (custom item / service), or the Pancake product never synced into Items';
  end if;
  if not exists (select 1 from public."Items" i where i."Code" = trim(p_item_code)) then
    return 'Item code "' || p_item_code || '" is not in Items';
  end if;
  select k.item_code, k.variant_id into v_item, v_variant from public._ile_resolve_stock_key(p_item_code, p_variant_id) k;
  return 'OK -> ' || v_item || coalesce(' / variant ' || v_variant, '');
exception when others then
  return 'FAILS: ' || sqlerrm;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. VERDICT - one row per check, then one row per line; the first 'FAIL' is your answer. This is the only
--    result the SQL editor shows when you run the whole file (it only displays the last statement's grid).
with params as (select '112445'::text as order_id),                     -- <<< ORDER-ID
setup as (select s."SalesPostingStartUtc" as start_utc from public."ItemLedgerSetup" s limit 1),
o as (select x.* from public."OnlineOrders" x, params p where x."OrderID" = p.order_id),
sync as (select y.* from public."ItemLedgerOrderSync" y, params p where y."OrderID" = p.order_id),
lines as (
  select l.*, coalesce(v."ItemCode", l."ItemCode") as raw_item, nullif(trim(coalesce(l."VariationId", '')), '') as raw_variant
  from public."OnlineOrderLines" l
  left join public."Variants" v on v."VariationId" = l."VariationId"
  join params p on l."OrderID" = p.order_id
)
select * from (values
  (1, 'Sales posting switched on',
      case when (select start_utc from setup) is not null then 'ok' else 'FAIL' end,
      'Posting starts ' || coalesce(((select start_utc from setup) at time zone 'Asia/Manila')::text, 'NEVER - press "Start Posting Sales From Now" on Item Ledger Entries')),
  (2, 'Order is on Online Orders',
      case when exists (select 1 from o) then 'ok' else 'FAIL' end,
      case when exists (select 1 from o) then 'found' else 'Not synced from Pancake yet - see supabase_online_order_resync_specific.sql' end),
  (3, 'Status counts as a sale',
      case when public._ile_order_counts_as_sale((select "Status" from o)) then 'ok' else 'FAIL' end,
      'Status = "' || coalesce((select "Status" from o), '(blank - an unfilled stub row)') || '" (blank/cancelled/removed/returned/refunded never post)'),
  (4, 'Confirmed after the posting start',
      case when coalesce((select "ConfirmedAtUtc" from o) >= (select start_utc from setup),
                         (select "Date" from o) > ((select start_utc from setup) at time zone 'Asia/Manila')::date, false)
           then 'ok' else 'FAIL' end,
      'ConfirmedAt ' || coalesce(((select "ConfirmedAtUtc" from o) at time zone 'Asia/Manila')::text, '(none)')
        || ', order Date ' || coalesce((select "Date" from o)::text, '(none)')
        || ' - orders before the cutover are assumed already counted in the starting stock'),
  (5, 'Has a warehouse (LocationID)',
      case when coalesce((select "LocationID" from o), '') <> '' then 'ok' else 'FAIL' end,
      'LocationID = ' || coalesce(nullif((select "LocationID" from o), ''), '(blank)')
        || coalesce(' (' || (select w."Name" from public."Warehouses" w where w."ID" = (select "LocationID" from o)) || ')', ' - not in Warehouses!')),
  (6, 'Has saved lines',
      case when exists (select 1 from lines where coalesce("Quantity", 0) > 0) then 'ok' else 'FAIL' end,
      (select count(*) from lines)::text || ' line(s) saved - none means the line sync hasn''t saved them (see supabase_online_order_resync_specific.sql)'),
  (7, 'At least one line is a stocked item',
      case when exists (select 1 from lines li where coalesce(li."Quantity", 0) > 0
                          and exists (select 1 from public._ile_try_resolve_stock_key(li.raw_item, li.raw_variant)))
           then 'ok' else 'FAIL' end,
      'See the Line rows below'),
  (8, 'Last reconcile did not error',
      case when (select "LastError" from sync) is null then 'ok' else 'FAIL' end,
      coalesce('ERROR: ' || (select "LastError" from sync) || ' - not retried until the order changes again; fix, then run query 3',
               case when exists (select 1 from sync) then 'no error' else 'never reconciled yet' end)),
  (9, 'Reconciled since its latest change',
      case when not exists (select 1 from sync) then 'FAIL'
           when (select "SyncedAtUtc" from o) > (select "ReconciledAtUtc" from sync)
             or (select "Last_Updated_At" from o) > (select "ReconciledAtUtc" from sync)
             or exists (select 1 from lines where "SyncedAtUtc" > (select "ReconciledAtUtc" from sync)) then 'WAITING'
           else 'ok' end,
      'Last reconciled ' || coalesce(((select "ReconciledAtUtc" from sync) at time zone 'Asia/Manila')::text, 'never')
        || ' - WAITING/never = the every-minute job should pick it up (query 3 runs it now)'),
  (10, 'Ledger entries posted for this order',
      case when exists (select 1 from public."ItemLedgerEntries" e, params p where e."DocumentType" = 'Sales Order' and e."DocumentNo" = p.order_id)
           then 'ok' else 'NONE' end,
      (select count(*) from public."ItemLedgerEntries" e, params p where e."DocumentType" = 'Sales Order' and e."DocumentNo" = p.order_id)::text || ' entr(ies) - optional query 2 lists them'),
  -- Walk-in extras: was the sale posted under some other document type / the POS receipt no.?
  (11, 'Entries under ANY doc type / receipt no.',
      'info',
      coalesce((select string_agg(e."DocumentType" || ' ' || e."DocumentNo" || ' ' || e."ItemCode" || ' ' || e."Quantity"::text, '; ')
                from public."ItemLedgerEntries" e
                where e."DocumentNo" in ('112445', 'RS-0000011110')), '(none)')),
  (12, 'Order timestamps',
      'info',
      'ReceivedAtShop=' || coalesce((select "ReceivedAtShop" from o)::text, 'null')
        || ', SyncedAt ' || coalesce(((select "SyncedAtUtc" from o) at time zone 'Asia/Manila')::text, 'null')
        || ', LastUpdated ' || coalesce(((select "Last_Updated_At" from o) at time zone 'Asia/Manila')::text, 'null')
        || ', lines last synced ' || coalesce(((select max("SyncedAtUtc") from lines) at time zone 'Asia/Manila')::text, 'null'))
) as t(step, check_name, result, detail)
union all
-- One row per saved line: does it tie to a stocked item, and if not, the exact reason.
select 100 + row_number() over (order by li."LineID")::int,
       'Line: ' || coalesce(li."Description", li."ItemCode", '?') || ' x' || coalesce(li."Quantity", 0)::text,
       case when pg_temp.ile_line_reason(li.raw_item, li.raw_variant) like 'OK%' then 'ok' else 'FAIL' end,
       pg_temp.ile_line_reason(li.raw_item, li.raw_variant)
         || ' | line ItemCode=' || coalesce(li."ItemCode", '(none)') || ', VariationId=' || coalesce(li.raw_variant, '(none)')
from lines li
order by 1;

-- ---------------------------------------------------------------------------
-- 2. (Optional - highlight and run on its own) What the ledger already has for this order.
-- select * from public."ItemLedgerEntries"
-- where "DocumentType" = 'Sales Order' and "DocumentNo" = '112445'
-- order by "EntryNo";

-- ---------------------------------------------------------------------------
-- 3. (After fixing the cause) post it now instead of waiting - uncomment and set the order id.
--    Returns how many ledger entries it wrote. Safe to run twice: it only ever posts the difference.
-- select public._ile_reconcile_online_order('112445');
