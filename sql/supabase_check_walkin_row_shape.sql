-- Read-only: what a Pancake-synced walk-in looks like in the portal today (header, lines, payments, ledger),
-- so POS walk-ins written straight to Supabase (supabase_pos_walkin_orders_direct.sql) match it field for
-- field. Shows the 3 newest walk-ins that have a discount or more than one payment method if any, else the
-- 3 newest. Safe to re-run.

with pick as (
  select o."OrderID"
    from public."OnlineOrders" o
   where o."ReceivedAtShop" is true and coalesce(o."Source", '') = ''
   order by (coalesce(o."Discount", 0) <> 0) desc,
            (select count(*) from public."OnlineOrderPayments" p where p."OrderID" = o."OrderID") desc,
            o."Date" desc nulls last, o."Time" desc nulls last
   limit 3
)
select 'header' as section, o."OrderID"::text as order_id,
       concat_ws(' | ',
         'Date=' || o."Date", 'Time=' || o."Time", 'Status=' || o."Status", 'Customer=' || o."CustomerName",
         'Loc=' || o."LocationID", 'MTC=' || o."MoneyToCollect", 'Paid=' || o."AmountPaid", 'Disc=' || o."Discount",
         'Bal=' || o."Balance", 'Fee=' || o."DeliveryFee", 'ForDel=' || o."ForDelivery", 'Addr=' || o."ShippingAddress",
         'Phone=' || o."ShippingPhone", 'CreatedBy=' || o."CreatedBy", 'ConfBy=' || o."ConfirmedBy",
         'ConfAt=' || o."ConfirmedAtUtc", 'Glass=' || o."GlassThickness", 'PrintCount=' || o."PrintCount",
         'Page=' || o."Page_ID", 'LastUpd=' || o."Last_Updated_At", 'Note=' || left(o."Note", 120)) as detail
  from public."OnlineOrders" o join pick using ("OrderID")
union all
select 'line', l."OrderID"::text,
       concat_ws(' | ', 'LineID=' || l."LineID", 'Item=' || l."ItemCode", 'PDID=' || l."product_display_id",
         'Var=' || l."VariationId", 'Qty=' || l."Quantity", 'Price=' || l."Price", 'Disc=' || l."Discount",
         'Gross=' || l."GrossAmount", 'Net=' || l."NetAmount", 'Desc=' || left(l."Description", 60), 'Note=' || left(l."Note", 60))
  from public."OnlineOrderLines" l join pick using ("OrderID")
union all
select 'payment', p."OrderID"::text, concat_ws(' | ', 'Method=' || p."MethodCode", 'Amount=' || p."Amount")
  from public."OnlineOrderPayments" p join pick using ("OrderID")
union all
select 'ledger', e."DocumentNo"::text,
       concat_ws(' | ', 'Type=' || e."EntryType", 'Item=' || e."ItemCode", 'Qty=' || e."Quantity", 'Wh=' || e."WarehouseId", 'Doc=' || e."DocumentType")
  from public."ItemLedgerEntries" e join pick p on p."OrderID" = e."DocumentNo"
order by 2, 1;
