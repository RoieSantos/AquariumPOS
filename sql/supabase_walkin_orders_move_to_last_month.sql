-- One-off: move 14 walk-in orders back to last month - per "i got this transaction no.s in my walk-in
-- orders, can we move the date of this orders in my portal" -> "last month".
--
-- Each order moves back exactly one month and keeps its own day (Oct 14 -> Sep 14), via the portal-only
-- "DateOverride" (the trigger forces "Date" to it so the Pancake sync can't revert it). Every
-- dashboard / sales report reads "Date", so they all follow. Not moved: Item Ledger Entries, Pancake, POS.
--
-- Run AFTER supabase_online_order_date_override.sql (adds "DateOverride" + the trigger).
-- Safe to re-run: orders that already have a DateOverride are skipped, so it never shifts twice.
-- Undo one order: update public."OnlineOrders" set "DateOverride" = null where "OrderID" = '...';
-- (the next Pancake sync puts the original date back).

with ids(order_id) as (
  values ('117557'), ('117558'), ('117559'), ('117560'), ('117564'), ('117565'), ('117569'),
         ('117570'), ('117577'), ('117580'), ('117581'), ('117585'), ('117587'), ('117592')
),
src as (
  select o."OrderID", o."Date" as old_date
  from public."OnlineOrders" o
  join ids on ids.order_id = o."OrderID"
  where o."DateOverride" is null and o."Date" is not null
),
upd as (
  update public."OnlineOrders" o
  set "DateOverride" = (src.old_date - interval '1 month')::date
  from src
  where o."OrderID" = src."OrderID"
  returning o."OrderID", o."Date"
)
select ids.order_id,
       o."Date" as date_before,
       coalesce(upd."Date", o."Date") as date_now,
       o."ReceivedAtShop" as is_walkin,
       o."Status", o."CustomerName", o."MoneyToCollect",
       case
         when o."OrderID" is null then 'NOT FOUND in OnlineOrders'
         when upd."OrderID" is not null then 'moved'
         else 'skipped - already has a DateOverride'
       end as result
from ids
left join public."OnlineOrders" o on o."OrderID" = ids.order_id
left join upd on upd."OrderID" = ids.order_id
order by ids.order_id;
