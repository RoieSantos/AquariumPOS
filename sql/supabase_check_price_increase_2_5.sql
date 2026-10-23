-- READ-ONLY. Price increase check: is +2.5% safe per item, and what would prices / revenue look like -
-- per "can you analyze all of my items if its safe to increase to 2.5% .. also can you show me a
-- forecast of what would our pricing be look like" (to cover Xendit fees, ~2.3-2.6% for GCash).
--
-- One row per item that is active OR sold in the last 365 days. Sales come from Online Orders (online +
-- walk-ins received at the shop - the same source as Top Selling Items), cancelled orders excluded.
--   price / cost / margin_pct         - Items list price and cost today
--   new_price                         - price x 1.025, rounded UP to a clean price point
--                                       (< 100: whole peso; < 1,000: next 5; >= 1,000: next 10)
--   new_margin_pct, real_increase_pct - after rounding
--   avg_sold_price_90d                - what customers actually paid (discounts / wholesale lower it)
--   qty / revenue 90d + 365d          - volume
--   forecast_revenue_90d, extra_revenue_90d - same units at the new price (no volume loss assumed)
--   flags                             - NO COST, LOSS (price <= cost), LOW MARGIN (< 15%),
--                                       CROSSES ₱xxx (new price passes a round number), CUSTOM (priced by
--                                       the calculators / Pricing Setup, not by this list price),
--                                       NOT SOLD 90D
--
-- Nothing is changed. Run the whole file; then use the result grid's export to download it as CSV.

with sales as (
  select l."ItemCode" as code,
         sum(l."Quantity") filter (where o."Date" >= current_date - 90)  as qty_90d,
         sum(l."GrossAmount") filter (where o."Date" >= current_date - 90) as revenue_90d,
         count(distinct l."OrderID") filter (where o."Date" >= current_date - 90) as orders_90d,
         sum(l."Quantity")    as qty_365d,
         sum(l."GrossAmount") as revenue_365d
    from public."OnlineOrderLines" l
    join public."OnlineOrders" o on o."OrderID" = l."OrderID"
   where l."ItemCode" is not null
     and o."Date" >= current_date - 365
     and lower(trim(coalesce(o."Status", ''))) not in ('cancelled', 'canceled', 'cancel')
   group by l."ItemCode"
),
base as (
  select i."Code"::text as item_code,
         i."Name"::text as item_name,
         i."CategoryCode"::text as category,
         coalesce(i."IsActive", false) as is_active,
         round(coalesce(i."Price", 0), 2) as price,
         round(i."Cost", 2) as cost,
         round(i."WholesalePrice", 2) as wholesale_price,
         (i."Code" ilike 'CUSTOM%' or i."Name" ilike 'CUSTOM%' or i."CategoryCode" ilike 'CUSTOM%') as is_custom,
         coalesce(s.qty_90d, 0) as qty_90d,
         coalesce(s.revenue_90d, 0) as revenue_90d,
         coalesce(s.orders_90d, 0) as orders_90d,
         coalesce(s.qty_365d, 0) as qty_365d,
         coalesce(s.revenue_365d, 0) as revenue_365d
    from public."Items" i
    left join sales s on s.code = i."Code"
   where coalesce(i."IsActive", false) or s.code is not null
),
priced as (
  select b.*,
         case when b.price <= 0 then 0
              when b.price * 1.025 < 100  then ceil(b.price * 1.025)
              when b.price * 1.025 < 1000 then ceil(b.price * 1.025 / 5) * 5
              else ceil(b.price * 1.025 / 10) * 10 end as new_price
    from base b
)
select p.item_code,
       p.item_name,
       p.category,
       p.is_active,
       p.price,
       p.new_price,
       round(p.new_price - p.price, 2) as increase_peso,
       case when p.price > 0 then round((p.new_price / p.price - 1) * 100, 2) end as real_increase_pct,
       p.cost,
       case when p.price > 0 and p.cost is not null then round((p.price - p.cost) / p.price * 100, 1) end as margin_pct,
       case when p.new_price > 0 and p.cost is not null then round((p.new_price - p.cost) / p.new_price * 100, 1) end as new_margin_pct,
       p.wholesale_price,
       case when p.qty_90d > 0 then round(p.revenue_90d / p.qty_90d, 2) end as avg_sold_price_90d,
       p.qty_90d,
       round(p.revenue_90d, 2) as revenue_90d,
       p.orders_90d,
       p.qty_365d,
       round(p.revenue_365d, 2) as revenue_365d,
       round(p.qty_90d * p.new_price, 2) as forecast_revenue_90d,
       round(p.qty_90d * (p.new_price - p.price), 2) as extra_revenue_90d,
       nullif(concat_ws(', ',
         case when p.is_custom then 'CUSTOM' end,
         case when p.cost is null or p.cost <= 0 then 'NO COST' end,
         case when p.cost > 0 and p.price > 0 and p.price <= p.cost then 'LOSS' end,
         case when p.cost > 0 and p.price > p.cost and (p.price - p.cost) / p.price < 0.15 then 'LOW MARGIN' end,
         case when p.price > 0 and floor(p.price / case when p.price < 1000 then 100 else 1000 end)
                                <> floor(p.new_price / case when p.price < 1000 then 100 else 1000 end)
              then 'CROSSES ₱' || (floor(p.new_price / case when p.price < 1000 then 100 else 1000 end)
                                   * case when p.price < 1000 then 100 else 1000 end)::bigint::text end,
         case when p.qty_90d = 0 then 'NOT SOLD 90D' end
       ), '') as flags
  from priced p
 order by p.revenue_90d desc, p.revenue_365d desc, p.item_code;
