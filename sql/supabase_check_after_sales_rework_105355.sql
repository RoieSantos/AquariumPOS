-- Read-only check: why can't the maker see order 105355 (Delivered, sent back for rework) on My Assignments?
-- See supabase_online_order_after_sales_rework.sql. Change the order no. in the first line of the CTE to
-- check another order. One result:
--   order          - status + the assigned Tank / Stand Maker (the rework shows for THAT username)
--   rework         - each send-back: part, when, by whom, and whether it's still open
--   done mark      - Production Done marks on the order (a mark newer than the send-back closes it)
--   reopened       - true = the server treats this part as after-sales rework now
--   maker account  - each login that could be the maker; ok = true means the order is on THAT login's
--                    My Assignments. Online order staff = true means they get a different list.
--   list function  - patched = true means My Assignments has the after-sales branch; if false, the
--                    detail shows the live text around where the patch should have gone - send it over.

with v as (select '105355'::text as order_id)
select 'order'::text as section, o."OrderID"::text as item,
       null::boolean as ok,
       format('status=%s | tank maker=%s | stand maker=%s | parts needed=%s | walk-in=%s',
              o."Status", coalesce(o."AssignedTankMaker", '-'), coalesce(o."AssignedStandMaker", '-'),
              array_to_string(public._online_order_production_roles(o."OrderID"), ','), coalesce(o."ReceivedAtShop", false)) as detail
from public."OnlineOrders" o, v where o."OrderID" = v.order_id

union all
select 'rework', w."Role",
       not exists (select 1 from public."OnlineOrderProductionDone" d
                   where d."OrderID" = w."OrderID" and d."Role" = w."Role" and d."DoneAtUtc" > w."SentBackAtUtc"),
       format('sent back %s by %s | reason: %s | made by: %s',
              to_char(w."SentBackAtUtc" at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI'), w."SentBackBy", w."Reason", coalesce(w."PrevDoneBy", '-'))
from public."OnlineOrderProductionRework" w, v where w."OrderID" = v.order_id

union all
select 'done mark', d."Role", null,
       format('done %s by %s', to_char(d."DoneAtUtc" at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI'), d."DoneBy")
from public."OnlineOrderProductionDone" d, v where d."OrderID" = v.order_id

union all
select 'reopened', r.role, public._online_order_rework_reopened(v.order_id, r.role), null
from v, (values ('tank'), ('stand')) as r(role)

union all
-- Every account that could be "the maker": the assigned usernames, plus anything named like them.
-- ok = the server would put this order on THAT login's My Assignments. A maker that has Online Order
-- Staff ticked gets the Online Order Staff queue instead of My Assignments.
select 'maker account', s."Username"::text,
       public._online_order_my_rework_reopened(v.order_id, s."Username"),
       format('display=%s | exact match to assigned=%s | active=%s | super=%s | online order staff=%s | roles=%s',
              coalesce(s."DisplayName", '-'),
              s."Username" in (coalesce(o."AssignedTankMaker", ''), coalesce(o."AssignedStandMaker", '')),
              s."IsActive", coalesce(s."SuperUser", false),
              coalesce(to_jsonb(s) ->> 'OnlineOrderStaff', 'false'), array_to_string(s."StaffRoles", ','))
from v
join public."OnlineOrders" o on o."OrderID" = v.order_id
join public."StaffUsers" s
  on lower(s."Username") in (lower(coalesce(o."AssignedTankMaker", '')), lower(coalesce(o."AssignedStandMaker", '')))
  or s."DisplayName" ilike '%' || nullif(o."AssignedTankMaker", '') || '%'
  or s."DisplayName" ilike '%' || nullif(o."AssignedStandMaker", '') || '%'

union all
select 'list function', p.proname::text || '(' || p.oid || ')',
       p.prosrc ilike '%after-sales rework%',
       case when p.prosrc ilike '%after-sales rework%' then 'patched'
            when position('AssignedDispatcher" = p_admin_username' in p.prosrc) = 0 then 'no AssignedDispatcher clause found'
            else substring(p.prosrc from position('AssignedDispatcher" = p_admin_username' in p.prosrc) - 200 for 700) end
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('admin_list_online_orders', 'admin_list_maker_assignments')
order by 1, 2;
