-- Read-only check: products that are HIDDEN from the website's Order Now shop because they have no photo.
--
-- Per the payment gateway review ("add photos to all listed products"), order-now.html now only lists
-- items that have a photo (Items."Images"). This lists every active item in the shop's categories
-- (SET / AQUARIUM / STAND / PUMP / LIGHTS - same filter as public_list_order_items) with no photo, so
-- you can add one in Item Setup - it shows up on the website again as soon as it has a photo.
--
-- Safe to run any time; changes nothing.

select
  upper(trim(i."CategoryCode")) as category,
  i."Code" as item_code,
  coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), i."Code") as item_name,
  coalesce(i."RetailPrice", i."Price", 0) as price
from public."Items" i
where i."IsActive" is true
  and i."HideFromSet" is not true
  and upper(trim(coalesce(i."CategoryCode", ''))) in ('SET', 'AQUARIUM', 'STAND', 'PUMP', 'LIGHTS')
  and nullif(trim(split_part(coalesce(i."Images", ''), ',', 1)), '') is null
order by 1, 3;
