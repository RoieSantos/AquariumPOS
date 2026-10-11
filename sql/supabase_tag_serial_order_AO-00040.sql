-- One-off: tag serial RS-AST-005-26-000041 as SOLD to online order AO-00040 - per "I have a serial
-- that's supposed to tag into an order". Same result as picking it at Ready to Ship: Status SOLD +
-- SoldOnlineOrderId. (The Serial Tracker's "Mark Sold" can't do this - it leaves the online order blank.)
--
-- Safety: stops (changes nothing) unless AO-00040 is in Online Orders AND the serial is still IN_STOCK
-- - the error says what the serial's current status / order is otherwise. UpdatedAtUtc is set so the
-- desktop POS pulls the change down. Safe to re-run (a second run stops: it's no longer In Stock).
-- The grid at the end shows the serial plus every serial now tied to AO-00040.

do $$
declare
  v_order_id text := 'AO-00040';
  v_serial text := 'RS-AST-005-26-000041';
  v_row public."ItemSerialTracking"%rowtype;
begin
  if not exists (select 1 from public."OnlineOrders" where "OrderID" = v_order_id) then
    raise exception 'Order % is not in Online Orders - nothing changed.', v_order_id;
  end if;

  select * into v_row from public."ItemSerialTracking" where "SerialNo" = v_serial;
  if not found then
    raise exception 'Serial % not found - nothing changed.', v_serial;
  end if;

  if v_row."Status" is distinct from 'IN_STOCK' then
    raise exception 'Serial % is % (item %, location %, order %) - not In Stock, nothing changed.',
      v_serial, v_row."Status", v_row."ItemCode", coalesce(v_row."Location", '-'),
      coalesce(v_row."SoldOnlineOrderId", '-');
  end if;

  update public."ItemSerialTracking"
  set "Status" = 'SOLD',
      "SoldOnlineOrderId" = v_order_id,
      "UpdatedAtUtc" = now(),
      "UpdatedBy" = 'manual tag (order ' || v_order_id || ')'
  where "SerialNo" = v_serial and "Status" = 'IN_STOCK';
end;
$$;

select "SerialNo", "ItemCode", "VariantCode", "Location", "Status", "SoldOnlineOrderId", "UpdatedBy", "UpdatedAtUtc"
from public."ItemSerialTracking"
where "SerialNo" = 'RS-AST-005-26-000041' or "SoldOnlineOrderId" = 'AO-00040'
order by "SerialNo";
