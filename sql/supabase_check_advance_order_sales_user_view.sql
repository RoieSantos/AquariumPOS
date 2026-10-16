-- Read-only check - per "why my user with access "Sales User" cannot see the advance order".
--
-- Advance Orders (Online Orders > Advance Orders tab) is view-only for Store Managers, Sales Users and
-- Conversations Access staff, and only for their OWN branch: an order shows when AdvanceOrders."Warehouse"
-- equals their StaffUsers."WarehouseName" (case/space-insensitive). A blank WarehouseName ("all
-- warehouses") matches NO order (supabase_advance_orders_store_manager_view.sql
-- _advance_order_viewer_branch). Super Users and Production Managers see every branch.
--
-- One result:
--   section 'user'      - every active Sales User / Store Manager / Conversations Access account: its
--                         warehouse, whether the server treats it as a viewer, and how many advance
--                         orders it can see. "why" says what's wrong when it's 0.
--   section 'branches'  - the Warehouse values advance orders actually carry, with counts, to compare
--                         spelling against the users' WarehouseName.
-- Changes nothing. Safe to re-run.

with u as (
  select s."Username", s."DisplayName", s."WarehouseName",
         coalesce(s."SalesUser", false) as sales_user,
         coalesce(s."StoreManager", false) as store_manager,
         coalesce(s."ConversationsStaff", false) as conversations,
         public._advance_order_is_viewer(s."Username") as is_viewer,
         public._advance_order_viewer_branch(s."Username") as branch
  from public."StaffUsers" s
  where s."IsActive"
    and (coalesce(s."SalesUser", false) or coalesce(s."StoreManager", false) or coalesce(s."ConversationsStaff", false))
)
select 'user' as section,
       u."Username" as name,
       concat_ws(', ', case when u.sales_user then 'Sales User' end, case when u.store_manager then 'Store Manager' end,
                 case when u.conversations then 'Conversations' end) as detail,
       coalesce(nullif(trim(u."WarehouseName"), ''), '(blank = all warehouses)') as warehouse,
       (select count(*) from public."AdvanceOrders" a
         where u.is_viewer and (u.branch is null or lower(trim(coalesce(a."Warehouse", ''))) = u.branch)) as visible_orders,
       case
         when not u.is_viewer then 'not a viewer - supabase_advance_orders_store_manager_view.sql not run (or an older version)'
         when u.branch = '' then 'Warehouse is blank - blank matches no advance order (set a branch in User Setup)'
         when not exists (select 1 from public."AdvanceOrders" a where lower(trim(coalesce(a."Warehouse", ''))) = u.branch)
           then 'no advance order has Warehouse = "' || trim(u."WarehouseName") || '" - compare with the branches rows'
         else 'ok'
       end as why
from u
union all
select 'branches',
       coalesce(nullif(trim(a."Warehouse"), ''), '(blank)'),
       null, null, count(*), null
from public."AdvanceOrders" a
group by 2
order by 1 desc, 2;
