-- Reset the Production Order number counter (production_order_no_seq -> PRD-000001, PRD-000002 ...).
--
-- The next number becomes (highest PRD- number still in ProductionOrders) + 1:
--   * no orders left (e.g. test orders deleted) -> next order is PRD-000001
--   * PRD-000007 is the highest remaining       -> next order is PRD-000008
-- It never goes below an existing order's number, so a new order can't collide with an old one
-- ("No" is the primary key).
--
-- To start from a specific number instead, see the commented block at the bottom.
-- Safe to re-run.

-- 1. See where things stand.
select
  (select last_value from public.production_order_no_seq) as counter_last_value,
  (select is_called from public.production_order_no_seq) as counter_used,
  (select count(*) from public."ProductionOrders") as orders,
  (select max(substring("No" from '^PRD-(\d+)$')::bigint) from public."ProductionOrders") as highest_prd_no;

-- 2. Reset.
select setval(
  'public.production_order_no_seq',
  coalesce((select max(substring("No" from '^PRD-(\d+)$')::bigint) from public."ProductionOrders"), 1),
  (select max(substring("No" from '^PRD-(\d+)$')::bigint) from public."ProductionOrders") is not null
) as reset_to;

-- 3. Check: the number the next saved order will get.
select 'PRD-' || lpad(
  (case when is_called then last_value + 1 else last_value end)::text, 6, '0') as next_order_no
from public.production_order_no_seq;

-- Start from a specific number instead (e.g. next order = PRD-000100). Only if it's above
-- highest_prd_no from step 1, otherwise saving will hit an existing order:
-- select setval('public.production_order_no_seq', 100, false);
