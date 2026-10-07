-- Read-only. Every order that SHOULD have taken stock out of the Item Ledger but has no Sales Order
-- entries - per walk-in 112445 (Shipped, both lines resolve, reconciled 14:08:00 with no error, yet 0
-- entries and never revisited). Same filter as step 2 of supabase_item_ledger_sales_race_fix.sql.
--
-- The timestamp columns show what the order looked like vs. when it was last reconciled, to tell WHY it
-- was skipped: if every *_at is before reconciled_at, the reconcile saw data that was written but not
-- visible yet (a commit that landed after the reconcile, stamped earlier) - the picker then never comes back.
-- walkin = ReceivedAtShop, so it shows whether this only hits walk-ins.
--
-- Nothing is written. Safe to re-run.

select
  o."OrderID"                                                   as order_id,
  coalesce(o."ReceivedAtShop", false)                           as walkin,
  o."Status"                                                    as status,
  o."Date"                                                      as order_date,
  o."Time"                                                      as order_time,
  o."LocationID"                                                as location,
  (o."ConfirmedAtUtc"  at time zone 'Asia/Manila')::timestamp(0) as confirmed_at,
  (o."SyncedAtUtc"     at time zone 'Asia/Manila')::timestamp(0) as order_synced_at,
  (o."Last_Updated_At" at time zone 'Asia/Manila')::timestamp(0) as pancake_updated_at,
  (select (min(l."SyncedAtUtc") at time zone 'Asia/Manila')::timestamp(0) from public."OnlineOrderLines" l where l."OrderID" = o."OrderID") as lines_first_synced_at,
  (select (max(l."SyncedAtUtc") at time zone 'Asia/Manila')::timestamp(0) from public."OnlineOrderLines" l where l."OrderID" = o."OrderID") as lines_last_synced_at,
  (s."ReconciledAtUtc" at time zone 'Asia/Manila')::timestamp(3) as reconciled_at,
  s."LastError"                                                 as last_error
from public."OnlineOrders" o
cross join (select "SalesPostingStartUtc" as start_utc from public."ItemLedgerSetup") st
left join public."ItemLedgerOrderSync" s on s."OrderID" = o."OrderID"
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
order by o."Date" desc, o."OrderID" desc;
