-- Read-only: which transfers would LOCK a store's portal right now (js/nav.js mountTransferReceiveLock).
-- Rule: Status In-Transit / Partial Shipped AND Transfer Date (first ship date) before today (Manila).
-- Staff whose warehouse = To Warehouse are locked (super users and sales-only users are exempt).
-- Run before pushing the lock: receive these (or cancel stale ones) first, so no store is locked on day one.
-- One result set, oldest first. Safe to run any time; changes nothing.

select h."To Warehouse"                                                   as locks_store,
       h."No."                                                            as transfer_no,
       h."From Warehouse"                                                 as from_warehouse,
       h."Status"                                                         as status,
       h."Transfer Date"::date                                            as shipped_on,
       (now() at time zone 'Asia/Manila')::date - h."Transfer Date"::date as days_overdue,
       h."Shipped By"                                                     as shipped_by
from public."Transfer_Header" h
where h."Status" in ('In-Transit', 'Partial Shipped')
  and h."Transfer Date" is not null
  and h."Transfer Date"::date < (now() at time zone 'Asia/Manila')::date
order by h."To Warehouse", h."Transfer Date";
