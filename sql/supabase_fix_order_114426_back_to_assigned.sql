-- One-off fix: online order 114426 (GMA, custom) was moved to To Ship while its Tank Maker had not
-- marked Production Done yet (likely the POS "To Ship" button, which only checks Printed/Assigned).
-- Per "do #2 for now": put it back to Assigned so it follows the normal
-- Production Done -> Ready to Ship flow on the portal.
--
-- Same Pancake status code + columns admin_sync_online_order_assigned_status uses
-- (supabase_online_order_assigned_status.sql). No customer message is sent, and the estimated delivery
-- date, makers, and Production Done marks are left as they are.
-- Only acts while the order is still To Ship - safe to re-run (does nothing the second time).

do $$
begin
  if exists (select 1 from public."OnlineOrders"
             where "OrderID" = '114426' and lower(trim(coalesce("Status", ''))) = 'to ship') then
    perform public._pancake_patch_online_order_status('114426',
      jsonb_build_object('status', public._online_order_assigned_pancake_code()));

    update public."OnlineOrders"
    set "Status" = 'Assigned',
        "PreAssignStatus" = coalesce(nullif(trim("PreAssignStatus"), ''), 'Printed')
    where "OrderID" = '114426';
  end if;
end $$;

-- Result: the order's status now, and each needed part's maker / done state.
select 'order' as section,
       format('status=%s | pre-assign=%s | tank maker=%s | stand maker=%s',
              o."Status", coalesce(o."PreAssignStatus", '-'),
              coalesce(o."AssignedTankMaker", '-'), coalesce(o."AssignedStandMaker", '-')) as detail
from public."OnlineOrders" o
where o."OrderID" = '114426'
union all
select 'part ' || r.part,
       case when d."DoneBy" is not null then 'DONE by ' || d."DoneBy" || ' at ' || d."DoneAtUtc"::text
            else 'not done yet' end
from unnest(public._online_order_production_roles('114426')) as r(part)
left join public."OnlineOrders" o on o."OrderID" = '114426'
left join public."OnlineOrderProductionDone" d
  on d."OrderID" = '114426' and d."Role" = r.part
 and d."DoneBy" = case r.part when 'tank' then o."AssignedTankMaker"
                              when 'stand' then o."AssignedStandMaker" else o."AssignedDispatcher" end
order by 1;
