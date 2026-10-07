-- Read-only check: PUMP / LIGHTS items whose RetailPrice differs from Price.
-- Alice's complete-setup quote (public_list_order_items) and the customer's preview link price a
-- pump/light at coalesce(RetailPrice, Price); the staff Aquarium Calculator picker
-- (staff_list_items_by_category) uses Price. Any row here = Alice and staff quote that item differently.
--
-- Safe to run any time. ONE result (no rows = they all match).

select trim(i."CategoryCode") as category,
       i."Code"            as code,
       i."Name"            as name,
       i."Price"           as staff_calc_price,
       i."RetailPrice"     as alice_price,
       i."IsActive"        as active,
       i."HideFromSet"     as hidden_from_alice
from public."Items" i
where trim(coalesce(i."CategoryCode", '')) in ('PUMP', 'LIGHTS')
  and i."RetailPrice" is not null
  and i."RetailPrice" is distinct from i."Price"
order by 1, 3;
