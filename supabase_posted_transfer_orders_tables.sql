-- Posted_Transfer_Header / Posted_Transfer_Line - permanent archive of completed portal Transfer
-- Orders. Exact same column set as Transfer_Header/Transfer_Line (the live, in-progress tables
-- the portal's Ship/Receive workflow reads/writes - see transferOrders.js) - these are schema
-- copies, not a subset.
--
-- Once an order's Status reaches "Received" (every line's cumulative Qty Received has caught up
-- to its Qty To Transfer - see computeAggregateStatus in transferOrders.js), the portal moves
-- (not copies) the header + lines here: inserts into these Posted tables, then deletes the rows
-- from Transfer_Header/Transfer_Line. After that point the order no longer appears on the
-- Transfer Orders list/Manage modal - these Posted tables are its permanent record.
--
-- Distinct from the desktop's own dbo.[Transfer Header]/[Transfer Line] ("TO-" Posted Transfer
-- Orders, synced from Pancake) - that's a separate pipeline this doesn't touch. These
-- Posted_Transfer_* tables are portal-only.
create table if not exists public."Posted_Transfer_Header" (
    "No." varchar(50) primary key,
    "Description" varchar(255),
    "Status" varchar(50),
    "Requested Date" date,
    "Estimated Delivery Date" date,
    "Transfer Date" date,
    "Receive Date" date,
    "From Warehouse ID" varchar(100),
    "From Warehouse" varchar(200),
    "To Warehouse ID" varchar(100),
    "To Warehouse" varchar(200),
    "Category Code" varchar(100),
    "Use Production Category" boolean,
    "Posted Date" timestamptz,
    "Sent To Online" boolean
);

create table if not exists public."Posted_Transfer_Line" (
    "Document No." varchar(50) not null,
    "Item No." varchar(200),
    "Variant ID" varchar(100),
    "Description" varchar(1000),
    "CategoryCode" varchar(100),
    "Line No." int not null,
    "Available QTY" numeric(18, 2),
    "Qty To Transfer" numeric(18, 2),
    "Qty To Ship" numeric(18, 2),
    "Qty Shipped" numeric(18, 2),
    "Qty To Receive" numeric(18, 2),
    "Qty Received" numeric(18, 2),
    primary key ("Document No.", "Line No.")
);

alter table public."Posted_Transfer_Header" enable row level security;
drop policy if exists "Anon full access" on public."Posted_Transfer_Header";
create policy "Anon full access" on public."Posted_Transfer_Header"
    for all to anon, authenticated using (true) with check (true);

alter table public."Posted_Transfer_Line" enable row level security;
drop policy if exists "Anon full access" on public."Posted_Transfer_Line";
create policy "Anon full access" on public."Posted_Transfer_Line"
    for all to anon, authenticated using (true) with check (true);
