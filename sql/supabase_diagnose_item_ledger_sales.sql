-- Read-only checks for Item Ledger sales posting (supabase_item_ledger_sales.sql). Nothing here
-- writes anything; run any of these in the SQL editor whenever stock looks off.

-- 1. Is sales posting on, and is the cron job alive?
select "SalesPostingStartUtc" as sales_posting_started_at from public."ItemLedgerSetup";
select jobname, schedule, active from cron.job where jobname = 'item-ledger-sales-posting';

-- 2. Orders whose last reconcile FAILED (usually an order with no/unknown warehouse). They are left
--    alone until the order changes again, so fix the cause on the order/warehouse and it retries.
select s."OrderID", o."Status", o."LocationID", s."ReconciledAtUtc", s."LastError"
from public."ItemLedgerOrderSync" s
left join public."OnlineOrders" o on o."OrderID" = s."OrderID"
where s."LastError" is not null
order by s."ReconciledAtUtc" desc
limit 200;

-- 3. Lines on counted orders that could NOT be tied to a stocked item, so they took no stock. Custom
--    aquariums/services showing up here is expected (they aren't inventory). A real stocked product
--    showing up means its Pancake code or variation doesn't match an Items/Variants row.
select l."OrderID", o."Date", o."Status", l."LineID", l."ItemCode", l."VariationId", l."Quantity", l."Description"
from public."OnlineOrderLines" l
join public."OnlineOrders" o on o."OrderID" = l."OrderID"
cross join (select "SalesPostingStartUtc" as start_utc from public."ItemLedgerSetup") st
where st.start_utc is not null
  and public._ile_order_counts_as_sale(o."Status")
  and coalesce(o."ConfirmedAtUtc" >= st.start_utc, o."Date" > (st.start_utc at time zone 'Asia/Manila')::date, false)
  and coalesce(l."Quantity", 0) > 0
  and not exists (
    select 1
    from public._ile_try_resolve_stock_key(
      coalesce((select v."ItemCode" from public."Variants" v where v."VariationId" = l."VariationId"), l."ItemCode"),
      nullif(trim(coalesce(l."VariationId", '')), '')
    )
  )
order by o."Date" desc, l."OrderID"
limit 200;

-- 4. Negative stock - more has left than the ledger has received. Usually a sale before its receipt
--    was entered, or an opening balance that was too low.
select e."ItemCode", e."VariantId", e."WarehouseId", w."Name" as warehouse, sum(e."Quantity") as on_hand
from public."ItemLedgerEntries" e
left join public."Warehouses" w on w."ID" = e."WarehouseId"
group by e."ItemCode", e."VariantId", e."WarehouseId", w."Name"
having sum(e."Quantity") < 0
order by sum(e."Quantity")
limit 200;

-- 5. Does the catalogue stock figure agree with the ledger? (Should return no rows. Rows mean
--    something else - e.g. the desktop's Items push - overwrote Items."QuantityInStock".)
select i."Code", i."QuantityInStock" as catalogue_qty, round(coalesce(t.total, 0))::int as ledger_qty
from public."Items" i
left join (select "ItemCode", sum("Quantity") as total from public."ItemLedgerEntries" group by "ItemCode") t on t."ItemCode" = i."Code"
where i."QuantityInStock" is distinct from round(coalesce(t.total, 0))::int
order by i."Code"
limit 200;
