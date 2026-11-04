-- Read-only check: confirmed portal (AO-) orders whose GMA Conversations order card disagrees with Online
-- Orders - per "gap in the conversation orders too AO-00172" (after AO-00176's double-counted delivery
-- fee, supabase_ao_delivery_fee_double_count_fix.sql).
--
-- Card:          Total = AutomatedOrders.EstimatedTotal, Paid = sum(AutomatedOrderPayments)
-- Online Orders: Total = OnlineOrders.MoneyToCollect,    Paid = AmountPaid (also Discount / Balance)
-- One row per order where total or paid differ (AO-00172 always listed), with both sides' line sums and
-- fees so the cause shows: total_gap = fee -> fee counted twice; lines differ -> items edited on one side
-- only; paid differ -> a payment on one side only. fix_patched = whether the double-count fix has run.
-- Safe to re-run; one result.
select ao."OrderNo"::text as order_no,
       ao."EstimatedTotal" as card_total,
       o."MoneyToCollect" as online_total,
       ao."EstimatedTotal" - o."MoneyToCollect" as total_gap,
       pay.card_paid,
       o."AmountPaid" as online_paid,
       pay.card_paid - o."AmountPaid" as paid_gap,
       ao."EstimatedTotal" - pay.card_paid as card_balance,
       o."Balance" as online_balance,
       ao."DeliveryFee" as ao_fee,
       o."DeliveryFee" as online_fee,
       o."PortalDeliveryFee" as online_portal_fee,
       o."Discount" as online_discount,
       aol.ao_lines,
       ool.online_lines,
       o."Status"::text as online_status,
       o."ConfirmedAtUtc",
       o."Last_Updated_At",
       ao."UpdatedAtUtc" as ao_updated_at,
       exists (select 1 from pg_proc p where p.proname = 'admin_set_portal_order_delivery_fee'
                and p.prosrc like '%fee_double_count_fix%') as fix_patched
  from public."AutomatedOrders" ao
  join public."OnlineOrders" o on o."OrderID" = ao."PancakeReceiptNo"
  cross join lateral (select coalesce(sum(p."Amount"), 0) as card_paid
                        from public."AutomatedOrderPayments" p where p."OrderNo" = ao."OrderNo") pay
  cross join lateral (select coalesce(sum(l."Quantity" * l."Price"), 0) as ao_lines
                        from public."AutomatedOrderLines" l where l."OrderNo" = ao."OrderNo") aol
  cross join lateral (select coalesce(sum(l."NetAmount"), 0) as online_lines
                        from public."OnlineOrderLines" l where l."OrderID" = o."OrderID") ool
 where ao."PancakeSyncStatus" = 'Portal'
   and (ao."OrderNo" = 'AO-00172'
        or ao."EstimatedTotal" is distinct from o."MoneyToCollect"
        or pay.card_paid is distinct from o."AmountPaid")
 order by ao."OrderNo";
