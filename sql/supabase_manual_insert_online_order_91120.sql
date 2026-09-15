-- One-off manual insert of Online Order 91120 (Advance Order RS-0000010635, TransactionNo 9935,
-- customer JHON GILBUENA) into public."OnlineOrders"/"OnlineOrderLines" so it can be scheduled
-- on the Delivery Calendar.
--
-- WHY THIS IS NEEDED: this order was created in-store as an Advance Order, then pushed to Pancake
-- (OnlinefunctionsEvents.SyncAdvanceOrderToCloud), which is where it got OnlineOrderID 91120. But
-- every order push to Pancake from an Advance Order is created with status = 0 ("New") - see
-- OnlinefunctionsEvents.cs's BuildAdvanceOrderCloudPayload - and ALL THREE paths that would
-- normally pull an order from Pancake into public."OnlineOrders" (the desktop app's
-- IntegrationEvents.SyncOrderListAsync, the portal's admin_sync_online_orders_from_pancake button,
-- and admin_list_online_orders_live's automatic browse-time upsert) explicitly skip any order
-- whose status is "New". So this order will never arrive there on its own, and the Delivery
-- Calendar's order picker (admin_list_deliverable_online_orders) only reads from
-- public."OnlineOrders" - it has no idea Advance Orders/91120 exist at all.
--
-- This inserts the missing header + item lines directly, sourced from public."AdvanceOrders"/
-- "AdvanceOrderLines" (already synced successfully via the desktop's "Resend to Portal" button).
-- Status is set to 'Confirmed' (money already collected in-store) so it passes the calendar
-- picker's status filter and ForDelivery is left NULL so it shows up as not-yet-scheduled.
--
-- ShippingAddress is intentionally left blank - Advance Orders don't capture one since the
-- customer is physically in-store - fill it in manually on the delivery stop when scheduling.
--
-- NOTE: because Pancake's own copy of this order stays "New" forever (nothing in this codebase
-- currently moves an Advance-Order-origin Pancake order out of "New"), none of the three sync
-- paths above will ever touch or duplicate this row later. If this order's payment status changes
-- (e.g. paid in full), update this row manually too - it's now decoupled from automatic sync.

insert into public."OnlineOrders" (
  "OrderID", "Date", "Time", "Status", "CustomerName", "MoneyToCollect", "AmountPaid", "Discount",
  "Balance", "ForDelivery", "SyncedAtUtc"
) values (
  '91120', '2026-09-15', '16:47:27', 'Confirmed', 'JHON GILBUENA 09190096481',
  17564.19, 10000.00, 0.00, 7564.19, null, now()
)
on conflict ("OrderID") do update set
  "Date" = excluded."Date",
  "Time" = excluded."Time",
  "Status" = excluded."Status",
  "CustomerName" = excluded."CustomerName",
  "MoneyToCollect" = excluded."MoneyToCollect",
  "AmountPaid" = excluded."AmountPaid",
  "Balance" = excluded."Balance",
  "SyncedAtUtc" = now();

insert into public."OnlineOrderLines" (
  "OrderID", "LineID", "ItemCode", "product_display_id", "VariationId", "Quantity", "Price",
  "GrossAmount", "NetAmount", "Description", "SyncedAtUtc"
) values
('91120', '1',  'AQUARIUM SET',     null, '8553a6b8-5bb1-4c7a-885b-e801a694ed31', 1, 16358.00, 16358.00, 16358.00, '100GALLONS-AQUARIUM-6MM (OVERHEAD COMPETE SETUP SET)', now()),
('91120', '2',  'AQUARIUM',         null, '389e25b5-50a7-4894-8518-a8a83a1f7a94', 1, 0.00,     0.00,     0.00,     'AQ-011-BlackSealant - STANDARD-100G ( 721818in, 6MM GLASS) | with Brace and free top cover - AQ-011-ClearSealant', now()),
('91120', '3',  'STAND',            null, 'c7b75385-dbbc-4726-aee0-1884b197c219', 1, 0.00,     0.00,     0.00,     'AST-006-BlackPaint - Dual Stand 100G - 36in height, 22 tubular | Can be white or black color - AST-006-WhitePaint', now()),
('91120', '4',  'SUMP',             null, 'ff3fcf6d-eebe-4434-a046-43fb0ed25541', 1, 0.00,     0.00,     0.00,     'S-019-BlackSealant - OVERHEAD-SUMP (100GAL) - S-019-ClearSealant', now()),
('91120', '5',  'CUSTOMIZED ITEM',  null, 'a74b9084-c51c-4ae1-ac75-3c0594d1be19', 1, 0.00,     0.00,     0.00,     'CUSTOM-STICKER', now()),
('91120', '6',  'LIGHTS',           null, '71d246db-2bf6-47cb-94cb-dbb3d1ecdd53', 1, 0.00,     0.00,     0.00,     'FROK-SUBMERSIBLE-LIGHT (6FT-WHITE)', now()),
('91120', '7',  'ACCESSORIES',      null, '0d09ff41-cb43-424c-92e4-244554578cdd', 3, 0.00,     0.00,     0.00,     'MESH-BAG (SMALL)', now()),
('91120', '8',  'PUMP',             null, '1b2421a2-009a-4dfa-baae-f123a2779309', 1, 0.00,     0.00,     0.00,     'A3000-SUBMERSIBLE-PUMP (16W)', now()),
('91120', '9',  'FILTRATION',       null, '434e5780-7ed7-4f11-99ff-8247965a0682', 1, 0.00,     0.00,     0.00,     'PIPE-STANDARD (1/2)', now()),
('91120', '10', 'MEDIAS',           null, '48f8339f-65bb-4ac2-b877-e36a9d71306c', 1, 0.00,     0.00,     0.00,     'INFINITY-PREMIUM-WOOL', now()),
('91120', '11', 'MEDIAS',           null, 'dd5c5bec-050b-4fa4-afac-350f8e5b26ea', 1, 0.00,     0.00,     0.00,     'CERAMIC-RING (1KG)', now()),
('91120', '12', '',                 null, '7b771b1e-3ccd-45c2-b61c-718d08614dd1', 1, 0.00,     0.00,     0.00,     'Peppered Ring Medias 1KG', now()),
('91120', '13', 'MEDIAS',           null, '255f7c8e-331a-437d-a086-19fd50cf074c', 1, 0.00,     0.00,     0.00,     'LAVA-ROCKS (1KG)', now()),
('91120', '14', 'CUSTOM-STICKER',   null, 'a74b9084-c51c-4ae1-ac75-3c0594d1be19', 1, 630.00,   630.00,   630.00,   'Plain Sticker 72Inches x 18Inches', now()),
('91120', '15', '',                 null, '6b8960c4-4368-48c4-86bd-0bab34fe3820', 1, 100.00,   100.00,   100.00,   'SERVICES - Product for - 1', now()),
('91120', '16', '',                 null, null,                                   1, 476.19,   476.19,   476.19,   'Card Processing Fee', now())
on conflict ("OrderID", "LineID") do update set
  "ItemCode" = excluded."ItemCode",
  "VariationId" = excluded."VariationId",
  "Quantity" = excluded."Quantity",
  "Price" = excluded."Price",
  "GrossAmount" = excluded."GrossAmount",
  "NetAmount" = excluded."NetAmount",
  "Description" = excluded."Description",
  "SyncedAtUtc" = now();

-- Verify
select "OrderID", "Date", "Status", "CustomerName", "MoneyToCollect", "Balance", "ForDelivery"
from public."OnlineOrders" where "OrderID" = '91120';

select "OrderID", "LineID", "ItemCode", "Description", "Quantity", "Price"
from public."OnlineOrderLines" where "OrderID" = '91120' order by "LineID"::int;
