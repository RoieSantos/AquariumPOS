-- One-off: tag the 2 serials that physically went out on online order 105852 as SOLD to it - per "this
-- is the serial that has been tagged already for online order 105852 how can I manually tag it?".
-- 105852 went To Ship without its serial claim being saved (0 serials tied to it), so these two stayed
-- In Stock at Amaya. Same result as picking them at Ready to Ship: Status SOLD + SoldOnlineOrderId.
-- (The Serial Tracker's "Mark Sold" can't do this - it leaves the online order blank on purpose.)
--
-- Safety: only serials that are still IN_STOCK, item AQ-030, at Amaya are changed; it stops (changes
-- nothing) unless BOTH match. UpdatedAtUtc is set so the desktop POS pulls the change down.
-- Safe to re-run (the second run stops: they're no longer In Stock). The grid shows both serials after.

do $$
declare
  v_order_id text := '105852';
  v_serials text[] := array['RS-AQ-030-26-000228', 'RS-AQ-030-26-000229'];
  v_count int;
begin
  select count(*) into v_count
  from public."ItemSerialTracking"
  where "SerialNo" = any(v_serials) and "Status" = 'IN_STOCK' and "ItemCode" = 'AQ-030' and "Location" = 'Amaya';

  if v_count <> cardinality(v_serials) then
    raise exception 'Only % of % serials are In Stock (AQ-030, Amaya) - nothing changed. Check the grid of a re-run / the Serial Tracker.', v_count, cardinality(v_serials);
  end if;

  update public."ItemSerialTracking"
  set "Status" = 'SOLD',
      "SoldOnlineOrderId" = v_order_id,
      "UpdatedAtUtc" = now(),
      "UpdatedBy" = 'manual tag (order ' || v_order_id || ')'
  where "SerialNo" = any(v_serials) and "Status" = 'IN_STOCK';
end;
$$;

select "SerialNo", "ItemCode", "VariantCode", "Location", "Status", "SoldOnlineOrderId", "UpdatedBy", "UpdatedAtUtc"
from public."ItemSerialTracking"
where "SerialNo" in ('RS-AQ-030-26-000228', 'RS-AQ-030-26-000229')
order by "SerialNo";
