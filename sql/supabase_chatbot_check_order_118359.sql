-- Read-only check: why couldn't Vic show order/receipt "118359" to Ralph on Messenger?
-- get_order_status finds an order by exact OrderID, or a walk-in by its full POS receipt no.
-- (first word of OnlineOrders."Note", e.g. RS-0000118359). Then orderBelongsToChat only shares it if
-- the chat's saved CustomerPhone matches the order's ShippingPhone / WalkinCustomerPhone.
-- Change the number below if checking another one. Safe to re-run.

with q as (select '118359'::text as num)
select 'order by OrderID' as section, o."OrderID"::text as ref,
       coalesce(o."WalkinCustomerName", o."CustomerName")::text as name,
       concat_ws(' / ', o."ShippingPhone", o."WalkinCustomerPhone")::text as phone,
       concat('walk-in=', o."ReceivedAtShop", ', note=', left(coalesce(o."Note", ''), 40))::text as detail
  from public."OnlineOrders" o, q where o."OrderID" = q.num
union all
select 'walk-in by receipt no. (ends in number)', o."OrderID"::text,
       coalesce(o."WalkinCustomerName", o."CustomerName")::text,
       concat_ws(' / ', o."ShippingPhone", o."WalkinCustomerPhone")::text,
       concat('receipt=', split_part(trim(coalesce(o."Note", '')), ' ', 1), ', date=', o."Date")::text
  from public."OnlineOrders" o, q
 where split_part(trim(coalesce(o."Note", '')), ' ', 1) ~* ('^RS-0*' || q.num || '$')
union all
select 'chat (name like Ralph)', c."Psid"::text,
       coalesce(c."CustomerName", c."FacebookName")::text,
       coalesce(c."CustomerPhone", '(no phone saved)')::text,
       null
  from public."ChatbotConversations" c
 where coalesce(c."CustomerName", '') ilike '%ralph%' or coalesce(c."FacebookName", '') ilike '%ralph%';
