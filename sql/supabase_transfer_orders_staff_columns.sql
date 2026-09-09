-- Portal-only Transfer_Header columns: "Requested By" / "Shipped By".
-- Not present on the desktop's dbo.[Transfer Header]/[Transfer Request Header] tables and never
-- synced from/to the desktop - same pattern as supabase_transfer_orders_qty_columns.sql.
--
-- "Requested By" is set once at creation (New Transfer Order form) to the logged-in staff's
-- display name. "Shipped By" is set once by the first Ship action for an order (mirrors how
-- "Transfer Date" only records the first shipment, not every partial shipment). Both are printed
-- on the Transfer Order print view (transfer-order-print.html) header.
alter table public."Transfer_Header" add column if not exists "Requested By" varchar(200);
alter table public."Transfer_Header" add column if not exists "Shipped By" varchar(200);

-- Posted_Transfer_Header is a schema copy of Transfer_Header (see
-- supabase_posted_transfer_orders_tables.sql) - archiveReceivedTransferOrder() carries these two
-- fields over when a fully-received order is moved there.
alter table public."Posted_Transfer_Header" add column if not exists "Requested By" varchar(200);
alter table public."Posted_Transfer_Header" add column if not exists "Shipped By" varchar(200);
