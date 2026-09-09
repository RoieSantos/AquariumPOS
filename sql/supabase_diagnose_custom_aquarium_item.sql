-- One-off diagnostic for AO-00002's Pancake push failure ("None of this order's lines matched a
-- known Pancake product") - the order line's CategoryCode/ItemCode is expected to be
-- 'CUSTOM-AQUARIUM' (see docs/js/orderNow.js's buildCustomAquariumCartLine), which
-- _push_automated_order_to_pancake (supabase_automated_orders_tables.sql) then matches against
-- public."Items"."Code" exactly. If nothing comes back from query 1 below, that exact string
-- doesn't exist in Items at all - query 2 looks for anything close, to find the real Code.

-- 1. Does the exact code the order line uses actually exist in Items?
select "Code", "Name", "VariationId", "ProductId", "CategoryCode", "IsActive"
from public."Items"
where "Code" = 'CUSTOM-AQUARIUM';

-- 2. If query 1 came back empty, what's actually in there that looks like it?
select "Code", "Name", "VariationId", "ProductId", "CategoryCode", "IsActive"
from public."Items"
where "Code" ilike '%custom%aquarium%' or "Name" ilike '%custom%aquarium%';

-- 3. What did AO-00002's line actually store as CategoryCode/ItemCode?
select "OrderNo", "CategoryCode", "ItemCode", "ItemName"
from public."AutomatedOrderLines"
where "OrderNo" = 'AO-00002';
