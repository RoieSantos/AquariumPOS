-- Confirmed portal (AO-) orders: delivery fee counted twice on the Conversations order card - per "it has
-- due but on the online orders it is fully paid" (AO-00176: card Total 6436 / P599 due, Online Orders
-- 5837 fully paid; items 5238 + fee 599 = 5837).
--
-- CAUSE (supabase_ao00176_balance_check.sql): the three fee writers for a confirmed order work out ONE
-- delta from the ONLINE order's old fee and add it to BOTH OnlineOrders.MoneyToCollect and
-- AutomatedOrders.EstimatedTotal. AO-00176's online order had no fee yet (0) while the AO already had
-- its 599, so setting 599 on 11-01 moved the online order 5238 -> 5837 (right) and the AO 5837 -> 6436
-- (fee twice). Whenever the two fees differ, the AO drifts.
--
-- FIX:
--   1. Patched into the LIVE function text (same pg_get_functiondef idiom as supabase_order_now_portal_only.sql)
--      - the AO side now swaps ITS OWN old fee for the new one:
--        "EstimatedTotal" = EstimatedTotal - DeliveryFee(old, AO's) + new fee
--      in admin_set_portal_order_delivery_fee (Online Orders card / Edit Details), _delivery_set_order_fee
--      (combined drops) and _book_delivery_stop_core (book from pin, confirmed-order branch). The online
--      order side is unchanged. Each patch stops with an error if the expected text isn't there.
--   2. Data: every confirmed portal AO whose EstimatedTotal = Online Orders MoneyToCollect + its own fee
--      (exactly the double count) is set back to MoneyToCollect. Payments are not touched.
--
-- Run AFTER supabase_order_card_delivery_fee_walkin_advance.sql, supabase_delivery_combined_drops.sql and
-- supabase_gma_pin_delivery_booking.sql. If any of those is re-run later, run this one again afterwards.
-- Safe to re-run. Ends with one result (patch status + each order fixed).

-- ---------------------------------------------------------------------------
-- 1a. admin_set_portal_order_delivery_fee
do $patch$
declare
  v_sig regprocedure := 'public.admin_set_portal_order_delivery_fee(text, text, text, numeric)'::regprocedure;
  v_def text := pg_get_functiondef(v_sig);
  v_new text;
begin
  if v_def like '%fee_double_count_fix%' then
    raise notice 'admin_set_portal_order_delivery_fee already patched - skipped.';
    return;
  end if;
  v_new := replace(v_def,
    $s$"EstimatedTotal" = coalesce("EstimatedTotal", 0) + v_delta,$s$,
    $s$"EstimatedTotal" = coalesce("EstimatedTotal", 0) - coalesce("DeliveryFee", 0) + v_new_fee /* fee_double_count_fix: AO's own old fee */,$s$);
  if v_new = v_def then raise exception 'admin_set_portal_order_delivery_fee patch: EstimatedTotal update not found - nothing changed.'; end if;
  execute v_new;
end
$patch$;

-- 1b. _delivery_set_order_fee (combined drops)
do $patch$
declare
  v_sig regprocedure := 'public._delivery_set_order_fee(text, numeric)'::regprocedure;
  v_def text := pg_get_functiondef(v_sig);
  v_new text;
begin
  if v_def like '%fee_double_count_fix%' then
    raise notice '_delivery_set_order_fee already patched - skipped.';
    return;
  end if;
  v_new := replace(v_def,
    $s$"EstimatedTotal" = coalesce("EstimatedTotal", 0) + v_delta,$s$,
    $s$"EstimatedTotal" = coalesce("EstimatedTotal", 0) - coalesce("DeliveryFee", 0) + v_fee /* fee_double_count_fix: AO's own old fee */,$s$);
  if v_new = v_def then raise exception '_delivery_set_order_fee patch: EstimatedTotal update not found - nothing changed.'; end if;
  execute v_new;
end
$patch$;

-- 1c. _book_delivery_stop_core (confirmed-order branch; the draft branch already does this)
do $patch$
declare
  v_sig regprocedure := 'public._book_delivery_stop_core(text, date, numeric, numeric, text, text, numeric, text)'::regprocedure;
  v_def text := pg_get_functiondef(v_sig);
  v_new text;
begin
  if v_def like '%fee_double_count_fix%' then
    raise notice '_book_delivery_stop_core already patched - skipped.';
    return;
  end if;
  v_new := replace(v_def,
    $s$"DeliveryFee" = v_fee, "EstimatedTotal" = coalesce("EstimatedTotal", 0) + v_delta,$s$,
    $s$"DeliveryFee" = v_fee, "EstimatedTotal" = coalesce("EstimatedTotal", 0) - coalesce("DeliveryFee", 0) + v_fee /* fee_double_count_fix: AO's own old fee */,$s$);
  if v_new = v_def then raise exception '_book_delivery_stop_core patch: EstimatedTotal update not found - nothing changed.'; end if;
  execute v_new;
end
$patch$;

-- ---------------------------------------------------------------------------
-- 2. Data fix + one result.
with fixed as (
  update public."AutomatedOrders" ao
     set "EstimatedTotal" = o."MoneyToCollect",
         "UpdatedAtUtc" = now()
    from public."OnlineOrders" o
   where o."OrderID" = ao."PancakeReceiptNo"
     and ao."PancakeSyncStatus" = 'Portal'
     and coalesce(ao."DeliveryFee", 0) > 0
     and ao."EstimatedTotal" = o."MoneyToCollect" + ao."DeliveryFee"
  returning ao."OrderNo", ao."EstimatedTotal" + 0 as new_total, o."MoneyToCollect" + ao."DeliveryFee" as old_total
)
select 'patch' as section, p.proname::text as name,
       case when p.prosrc like '%fee_double_count_fix%' then 'patched' else 'NOT patched' end as detail
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('admin_set_portal_order_delivery_fee', '_delivery_set_order_fee', '_book_delivery_stop_core')
union all
select 'fixed order', "OrderNo"::text, 'EstimatedTotal ' || old_total || ' -> ' || new_total from fixed
order by 1 desc, 2;
