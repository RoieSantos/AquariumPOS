-- Portal-only lock flag for Transfer Orders (see WebPortal/js/transferOrders.js). Set
-- automatically the moment an order is created/requested (saveNewTransfer's header payload) -
-- the portal's Manage modal has no line/qty-editing surface once an order exists anyway, so this
-- just makes that permanent/explicit and shows a lock icon right away. Also hides Cancel Order
-- (see updateManageActionButtons' cancelTransferBtn logic in transferOrders.js) - since every
-- order is locked from creation, this means Cancel is no longer available as a portal action at
-- all; only Ship/Receive remain.
alter table public."Transfer_Header" add column if not exists "Is Locked" boolean not null default false;
alter table public."Transfer_Header" add column if not exists "Locked At" timestamptz;
alter table public."Transfer_Header" add column if not exists "Locked By" varchar(100);
