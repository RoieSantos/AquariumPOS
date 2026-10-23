-- READ-ONLY. Why the dashboard's Vic (created) card stays low - per "can you double check why this is
-- not increasing i see there are number of created order by the bot (vic)".
--
-- The card (admin_get_sales_by_created_by) counts OnlineOrders where "CreatedBy" = 'Vic'. Two ways a
-- Vic order misses it:
--   1. NOT CONFIRMED YET  - Vic's order is only an AutomatedOrders draft; OnlineOrders gets the row when
--                           staff click Confirm Order (admin_confirm_bot_order).
--   2. CREDITED TO STAFF  - admin_confirm_bot_order copies AutomatedOrders."UpdatedBy" into
--                           OnlineOrders."CreatedBy", but any staff edit before confirming (items,
--                           delivery fee, wholesale, status) overwrites "UpdatedBy" with the staff
--                           username - so the order lands as created by that staff member.
-- "Vic made it" = Vic's own chat reply carried the order number within 15 minutes of it being created.
--
-- One row per bot-made order this month and last month. Nothing is changed.

with bot_orders as (
  select ao."OrderNo",
         ao."CreatedAtUtc",
         ao."Status" as draft_status,
         ao."PancakeSyncStatus",
         ao."UpdatedBy",
         case when ao."GmaPsid" like 'web:%' then 'Alice' else 'Vic' end as bot_name
    from public."AutomatedOrders" ao
   where ao."CreatedAtUtc" >= date_trunc('month', now() at time zone 'Asia/Manila') - interval '1 month'
     and (ao."UpdatedBy" in ('Vic', 'Alice', 'AI Bot')
          or exists (select 1 from public."ChatbotMessages" m
                      where m."Psid" = ao."GmaPsid"
                        and m."Role" = 'assistant'
                        and m."CreatedAtUtc" between ao."CreatedAtUtc" and ao."CreatedAtUtc" + interval '15 minutes'
                        and m."Content" ilike '%' || ao."OrderNo" || '%'))
)
select b.bot_name,
       b."OrderNo" as order_no,
       (b."CreatedAtUtc" at time zone 'Asia/Manila')::date as made_on,
       b.draft_status,
       b."PancakeSyncStatus" as sync_status,
       b."UpdatedBy" as draft_updated_by,
       oo."Date" as online_order_date,
       oo."Status" as online_status,
       oo."CreatedBy" as online_created_by,
       oo."MoneyToCollect" as amount,
       case
         when oo."OrderID" is null and b.draft_status in ('Cancelled') then 'draft cancelled'
         when oo."OrderID" is null then 'NOT CONFIRMED YET (not in Online Orders)'
         when lower(trim(coalesce(oo."Status", ''))) in ('canceled', 'cancelled') then 'cancelled'
         when coalesce(oo."ReceivedAtShop", false) then 'walk-in (excluded)'
         when lower(trim(oo."CreatedBy")) <> lower(b.bot_name) then 'CREDITED TO STAFF: ' || oo."CreatedBy"
         else 'counted'
       end as card_result
  from bot_orders b
  left join public."OnlineOrders" oo on oo."OrderID" = b."OrderNo"
 order by b."CreatedAtUtc" desc;
