-- Read-only check for the price-edit flow (supabase_item_price_pancake_push.sql).
--
-- Order Now, the AI bot ("Alice") and order price validation all quote
-- coalesce(Items."RetailPrice", Items."Price", 0) - RetailPrice wins whenever it is set. A price saved
-- from Item Setup only changes Items."Price" (Pancake has no separate retail/promo columns), so any
-- item listed here would keep quoting its old RetailPrice to customers after a portal price edit.
-- RetailPrice comes from the desktop POS's own Items.RetailPrice column via SyncItemsToSupabase.

-- 1) How many items are affected, and how many are a plain 0 (which would quote as 0.00).
select
  count(*) filter (where "RetailPrice" is not null)                          as items_with_retail_price,
  count(*) filter (where "RetailPrice" is not null and "RetailPrice" = 0)    as retail_price_zero,
  count(*) filter (where "RetailPrice" is not null
                     and "RetailPrice" <> coalesce("Price", 0))              as retail_differs_from_price
from public."Items"
where "IsActive" is not false;

-- 2) The items where the customer-facing price is NOT the Price shown in Item Setup.
select "Code", "Name", "Price", "RetailPrice"
from public."Items"
where "IsActive" is not false
  and "RetailPrice" is not null
  and "RetailPrice" <> coalesce("Price", 0)
order by "Code"
limit 200;
