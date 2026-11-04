-- Read-only check: where did AO-00176's Production Done proof photo go?
-- Proof photos are saved against the ref they were taken on (OnlineOrderStatusPhotos."OrderID"):
-- the AO no. when done from the Online Orders card, the PRD no. when done from Production Orders /
-- My Assignments' production-order card. The AO card's Photos FactBox only lists its own ref.
select "OrderID" as ref_id, "Status" as label, "UploadedBy" as uploaded_by,
       "UploadedAtUtc" at time zone 'Asia/Manila' as uploaded_at_ph, "PublicUrl" as url
from public."OnlineOrderStatusPhotos"
where "OrderID" in ('AO-00176', 'PRD-000118')
order by "UploadedAtUtc" desc;
