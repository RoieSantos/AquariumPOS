-- Lets a hand-typed "Qty To Ship" on a transfer order line stick, per direct request ("i want it to be
-- manually changed then able to save it").
--
-- The Transfer Orders page fills Qty To Ship from the From Warehouse's available stock every time the
-- order is opened. Without a marker, a number someone typed in was overwritten by that fill on the
-- next open. This column records "a person chose this quantity": while it is true the page keeps the
-- saved Qty To Ship; shipping the line clears it so the next shipment fills from stock again.
--
-- The page still works if this hasn't been run (the quantity saves, but is refilled from stock on the
-- next open), so run it to make manual quantities stick. Safe to re-run. Does not touch the Item
-- Ledger trigger (that only fires on Qty Shipped / Qty Received changes).

alter table public."Transfer_Line" add column if not exists "Qty To Ship Manual" boolean not null default false;

notify pgrst, 'reload schema';

select count(*) as lines, count(*) filter (where "Qty To Ship Manual") as manual_lines from public."Transfer_Line";
