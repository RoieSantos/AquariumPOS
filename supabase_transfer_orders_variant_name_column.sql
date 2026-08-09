-- Portal-only Transfer_Line column: "Variant Name".
-- Not present on the desktop's Transfer Line tables and never synced from/to the desktop - same
-- pattern as supabase_transfer_orders_qty_columns.sql.
--
-- Transfer_Line."Variant ID" only ever held the raw variation ID (a Pancake-internal identifier),
-- which isn't meaningful to read in the Manage modal/print view/Posted Transfers list. This
-- column instead stores the human-readable label staff actually saw and picked in the Variant
-- lookup while creating the line (SKU or variant name - see renderVariantSuggestions'/
-- applyItemSelection's "label" in transferOrders.js), captured once at creation time in
-- saveNewTransfer() and never changed afterward.
alter table public."Transfer_Line" add column if not exists "Variant Name" varchar(255);

-- Posted_Transfer_Line is a schema copy of Transfer_Line (see
-- supabase_posted_transfer_orders_tables.sql) - archiveReceivedTransferOrder() carries this field
-- over when a fully-received order is moved there.
alter table public."Posted_Transfer_Line" add column if not exists "Variant Name" varchar(255);
