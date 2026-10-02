-- Read-only diagnostic: one order keeps sending the same push notification.
-- Replace 'ORDER_ID_HERE' (both places) with the order no. from the notification, run, and run it
-- again ~10 minutes later (after the next POS sync / Pancake sync) to compare.
--
-- Every push trigger fires on a CHANGE (supabase_web_push_targeted.sql):
--   "New confirmed order"              - Status moves INTO Confirmed/Submitted from anything else
--   "New tank/stand job assigned"      - AssignedTankMaker / AssignedStandMaker changes to a new value
--   "Production order released to you" - production Status moves into Released, or a maker changes
-- So a repeat means that field is flipping back and forth between two writers.

-- 1. The online order as it is now. SyncedAtUtc moving forward while Last_Updated_At (Pancake's
--    own timestamp) stays the same = something other than the Pancake sync (e.g. the POS push of
--    dbo.OnlineOrderHeader) is rewriting the row.
select o."OrderID", o."CustomerName", o."Status", o."PreAssignStatus", o."ReceivedAtShop",
       o."ConfirmedBy", o."ConfirmedAtUtc",
       o."AssignedTankMaker", o."AssignedStandMaker",
       o."LocationID", o."Last_Updated_At", o."SyncedAtUtc", now() as checked_at
from public."OnlineOrders" o
where o."OrderID" = 'ORDER_ID_HERE';

-- 2. Production orders made for it ("Production order released to you" pushes).
select po."No", po."Status", po."TankMaker", po."StandMaker",
       po."ReleasedAtUtc", po."FinishedAtUtc", po."CreatedAtUtc"
from public."ProductionOrders" po
where po."SourceOnlineOrderId" = 'ORDER_ID_HERE';

-- 3. Devices per user - a user with several rows gets one copy of each push per device.
select "CreatedBy", count(*) as devices, max("LastSeenAtUtc") as last_seen
from public."PushSubscriptions"
group by "CreatedBy"
order by devices desc;
