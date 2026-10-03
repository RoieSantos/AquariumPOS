-- READ-ONLY check: who created online order 106916 (Benjamin Inta)?
-- Pancake shows the order was pushed in by the API_CONNECTION user with note "Web order AO-00029",
-- so the real creator is on the portal-side AutomatedOrders row (UpdatedBy = staff username that
-- created it from the conversation page). Safe to re-run; changes nothing.

select 'automated_order' as section, o."OrderNo"::text as ref,
       ('created/updated by: ' || coalesce(o."UpdatedBy", '-')
        || ' | created ' || to_char(o."CreatedAtUtc" at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI')
        || ' | updated ' || to_char(o."UpdatedAtUtc" at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI')
        || ' | customer: ' || coalesce(o."CustomerName", '-')
        || ' | pancake id: ' || coalesce(o."PancakeOrderId", '-')
        || ' | status: ' || coalesce(o."Status", '-'))::text as value
from public."AutomatedOrders" o
where o."OrderNo" = 'AO-00029' or o."PancakeOrderId" = '106916'
union all
select 'payment', p."OrderNo"::text,
       ('recorded by: ' || coalesce(p."RecordedBy", '-') || ' | ' || p."Amount"::text || ' ' || coalesce(p."Method", '')
        || ' | ' || to_char(p."RecordedAtUtc" at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI'))::text
from public."AutomatedOrderPayments" p
where p."OrderNo" = 'AO-00029'
union all
select 'online_order', o."OrderID"::text,
       ('CreatedBy: ' || coalesce(o."CreatedBy", '-') || ' | ConfirmedBy: ' || coalesce(o."ConfirmedBy", '-')
        || ' | TankMaker: ' || coalesce(o."AssignedTankMaker", '-'))::text
from public."OnlineOrders" o
where o."OrderID" = '106916';
