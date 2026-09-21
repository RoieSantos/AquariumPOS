-- OPTIONAL clean-up: turn 0 wholesale prices into blank ("not set") on public."Items".
--
-- Run the PREVIEW (section 1) first. It shows whether any items actually have a 0 wholesale price - if
-- wholesale_zero is 0 there is nothing to do and section 2 is a no-op.
--
-- Why it can matter: the portal treats blank ("not set") and 0 ("free") as different things (see
-- admin_set_item_wholesale_price), and Alice gets Items."WholesalePrice" as-is for wholesale-eligible
-- categories (public_search_items, supabase_search_items_wholesale_price.sql) - so an unpriced
-- Aquarium/Stand/Sump item sitting at 0 could be quoted to a customer as a ₱0 wholesale price. A 0 would
-- come from the desktop POS's local Items.WholesalePrice column (DECIMAL(10,2) DEFAULT 0) if the POS's
-- Items push ever reached Supabase; it is NOT known whether it did (see the header of
-- supabase_pos_item_wholesale_price_pull.sql - the POS's key has no SELECT on Items, so that push
-- probably fails at its first row).
--
-- If you do run section 2, run it AFTER the new POS build is on every terminal, so an old build cannot
-- write the 0s back.

-- 1) Preview: how many items are affected, and which categories they sit in.
select
  count(*) filter (where "WholesalePrice" = 0)     as wholesale_zero,
  count(*) filter (where "WholesalePrice" > 0)     as wholesale_priced,
  count(*) filter (where "WholesalePrice" is null) as wholesale_blank
from public."Items";

select coalesce("CategoryCode", '(none)') as category, count(*) as items_with_zero
from public."Items"
where "WholesalePrice" = 0
group by 1
order by 2 desc
limit 50;

-- 2) The clean-up. A real wholesale price of exactly 0 is not a thing anyone sells at; anything that
--    genuinely should be 0 can be set again from Item Setup afterwards.
update public."Items"
set "WholesalePrice" = null
where "WholesalePrice" = 0;
