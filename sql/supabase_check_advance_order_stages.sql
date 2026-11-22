-- Read-only: how many advance orders sit at each portal stage (all time and last 30 days),
-- plus the last few To Ship / Shipped moves. Same stage rules as _advance_order_prod_status.
with s as (
  select a."TransactionNo", a."Date",
    case
      when p."TransactionNo" is null then 'New'
      when p."ShippedAtUtc" is not null then 'Shipped'
      when p."ToShipAtUtc" is not null then 'To Ship'
      when p."TankMaker" is null and p."StandMaker" is null then 'New'
      when (p."TankMaker" is not null and p."TankDoneAtUtc" is null)
        or (p."StandMaker" is not null and p."StandDoneAtUtc" is null) then 'Assigned'
      else 'Production Done'
    end as stage,
    p."ToShipAtUtc", p."ToShipBy", p."ShippedAtUtc", p."ShippedBy"
  from public."AdvanceOrders" a
  left join public."AdvanceOrderProduction" p on p."TransactionNo" = a."TransactionNo"
)
select 'all' as section, stage as k, count(*)::text as v from s group by 1,2
union all
select 'last_30_days', stage, count(*)::text from s where "Date" >= current_date - 30 group by 1,2
union all
select * from (
  select 'latest_moves', "TransactionNo",
         concat('ToShip ', "ToShipAtUtc", ' by ', "ToShipBy", ' | Shipped ', "ShippedAtUtc", ' by ', "ShippedBy")
  from s where "ToShipAtUtc" is not null
  order by greatest("ToShipAtUtc", coalesce("ShippedAtUtc", "ToShipAtUtc")) desc limit 8
) x
order by 1,2;
