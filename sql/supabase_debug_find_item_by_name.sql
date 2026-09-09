-- One-off lookup: debug_item_description(p_item_code) needs the exact public."Items"."Code",
-- but the Order Now item card only shows the display Name - this finds the real Code from a
-- partial Name match so the right value can be passed to debug_item_description(). Safe to
-- re-run, read-only, no writes.
--
-- Usage: swap the search text below for whatever's in the item's name, then run it.

select "Code", "Name", "Description", "SKU", "ProductId", "SyncedAtUtc"
from public."Items"
where "Name" ilike '%100GALLONS%OVERHEAD%';
