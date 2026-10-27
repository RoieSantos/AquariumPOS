-- READ-ONLY. Wholesale side of the +2.5% price increase check, per "can we check the wholesale pricing
-- too?" - companion to supabase_check_price_increase_2_5.sql (retail), same rounding so the two line up.
-- Then per "can we do wholesale price a bit closer to the retail price": the proposed wholesale price
-- also narrows each item's discount off retail.
--
-- THE KNOBS (params below):
--   increase_pct (default 5, per "can we do above 2.5%?") - the % increase, for retail AND the wholesale
--     floor. Keep it the same as in supabase_check_price_increase_2_5.sql. (File name kept from the 2.5% version.)
--   keep_discount (default 0.75) - the share of today's wholesale discount that is kept, applied to the
--     NEW retail price. 0.75 = a 20%-off-retail item becomes 15% off; 0.50 = 10% off; 1.00 = same
--     discount as today (plain +increase_pct). Edit the numbers and re-run to compare.
--   proposed = max(wholesale x (1 + increase_pct), new retail x (1 - today's discount x keep_discount)),
--   rounded UP to a clean price point (< 100: whole peso; < 1,000: next 5; >= 1,000: next 10).
-- It never goes below the plain +increase_pct, so no wholesale price drops.
--
-- One row per item that has a WholesalePrice > 0 and is active OR sold in the last 365 days.
--   wholesale_applicable              - category is IsWholesaleApplicable. If false the wholesale price
--                                       is never used (Alice / the staff Wholesale switch skip it).
--   price / new_price                 - retail today and after +increase_pct (same as the retail check)
--   wholesale_price                   - wholesale today
--   ws_plain                          - wholesale x (1 + increase_pct) only, for comparison
--   new_wholesale_price               - the PROPOSED price (closer to retail, see the knob)
--   ws_increase_peso / ws_real_increase_pct - proposed vs today
--   wholesale_margin_pct / new_...    - margin over cost at wholesale, today vs proposed
--   wholesale_off_retail_pct / new_...- how far below retail wholesale sits, today vs proposed
--   ws_qty / ws_revenue 90d + 365d    - ESTIMATED wholesale sales: order lines have no wholesale flag,
--                                       so a line counts as wholesale when its unit price was at or
--                                       below the item's current WholesalePrice
--   forecast / extra_ws_revenue_90d   - same wholesale units at the proposed price (no volume loss assumed)
--   flags                             - NOT APPLICABLE, NO COST, LOSS (wholesale <= cost), LOW MARGIN
--                                       (< 10%), NOT BELOW RETAIL (proposed >= new retail), BIG JUMP
--                                       (proposed is > increase_pct + 7.5 points over today), CROSSES ₱xxx, NOT SOLD 90D
--
-- Nothing is changed. Run the whole file; then use the result grid's export to download it as CSV.

with params as (
  select 1 + 5.0::numeric / 100 as mult,   -- <- increase_pct
         0.75::numeric as keep_discount
),
items as (
  select i."Code"::text as item_code,
         i."Name"::text as item_name,
         i."CategoryCode"::text as category,
         coalesce(i."IsActive", false) as is_active,
         coalesce(c."IsWholesaleApplicable", false) as wholesale_applicable,
         round(coalesce(i."Price", 0), 2) as price,
         round(i."Cost", 2) as cost,
         round(i."WholesalePrice", 2) as wholesale_price
    from public."Items" i
    left join public."Categories" c on c."Code" = i."CategoryCode"
   where i."WholesalePrice" > 0
),
ws_sales as (
  select l."ItemCode" as code,
         sum(l."Quantity") filter (where o."Date" >= current_date - 90)    as ws_qty_90d,
         sum(l."GrossAmount") filter (where o."Date" >= current_date - 90) as ws_revenue_90d,
         count(distinct l."OrderID") filter (where o."Date" >= current_date - 90) as ws_orders_90d,
         sum(l."Quantity")    as ws_qty_365d,
         sum(l."GrossAmount") as ws_revenue_365d
    from public."OnlineOrderLines" l
    join public."OnlineOrders" o on o."OrderID" = l."OrderID"
    join items it on it.item_code = l."ItemCode"
   where o."Date" >= current_date - 365
     and lower(trim(coalesce(o."Status", ''))) not in ('cancelled', 'canceled', 'cancel')
     and l."Quantity" > 0
     and coalesce(l."Price", 0) > 0
     and l."Price" <= it.wholesale_price
   group by l."ItemCode"
),
base as (
  select it.*,
         coalesce(s.ws_qty_90d, 0) as ws_qty_90d,
         coalesce(s.ws_revenue_90d, 0) as ws_revenue_90d,
         coalesce(s.ws_orders_90d, 0) as ws_orders_90d,
         coalesce(s.ws_qty_365d, 0) as ws_qty_365d,
         coalesce(s.ws_revenue_365d, 0) as ws_revenue_365d
    from items it
    left join ws_sales s on s.code = it.item_code
   where it.is_active or s.code is not null
),
retail as (
  select b.*,
         case when b.price <= 0 then 0
              when b.price * pr.mult < 100  then ceil(b.price * pr.mult)
              when b.price * pr.mult < 1000 then ceil(b.price * pr.mult / 5) * 5
              else ceil(b.price * pr.mult / 10) * 10 end as new_price
    from base b
    cross join params pr
),
target as (
  -- Raw (unrounded) proposed wholesale: the larger of plain +increase_pct and the narrowed discount off
  -- new retail. Items with no retail price, or wholesale already at/above retail, just get the plain one.
  select r.*,
         pr.mult,
         r.wholesale_price * pr.mult as ws_plain_raw,
         case when r.price > 0 and r.wholesale_price < r.price
              then greatest(r.wholesale_price * pr.mult,
                            r.new_price * (1 - (1 - r.wholesale_price / r.price) * pr.keep_discount))
              else r.wholesale_price * pr.mult end as ws_target_raw
    from retail r
    cross join params pr
),
priced as (
  select t.*,
         case when t.ws_plain_raw < 100  then ceil(t.ws_plain_raw)
              when t.ws_plain_raw < 1000 then ceil(t.ws_plain_raw / 5) * 5
              else ceil(t.ws_plain_raw / 10) * 10 end as ws_plain,
         case when t.ws_target_raw < 100  then ceil(t.ws_target_raw)
              when t.ws_target_raw < 1000 then ceil(t.ws_target_raw / 5) * 5
              else ceil(t.ws_target_raw / 10) * 10 end as new_wholesale_price
    from target t
)
select p.item_code,
       p.item_name,
       p.category,
       p.is_active,
       p.wholesale_applicable,
       p.price,
       p.new_price,
       p.wholesale_price,
       p.ws_plain,
       p.new_wholesale_price,
       round(p.new_wholesale_price - p.wholesale_price, 2) as ws_increase_peso,
       round((p.new_wholesale_price / p.wholesale_price - 1) * 100, 2) as ws_real_increase_pct,
       p.cost,
       case when p.cost is not null then round((p.wholesale_price - p.cost) / p.wholesale_price * 100, 1) end as wholesale_margin_pct,
       case when p.cost is not null then round((p.new_wholesale_price - p.cost) / p.new_wholesale_price * 100, 1) end as new_wholesale_margin_pct,
       case when p.price > 0 then round((1 - p.wholesale_price / p.price) * 100, 1) end as wholesale_off_retail_pct,
       case when p.new_price > 0 then round((1 - p.new_wholesale_price / p.new_price) * 100, 1) end as new_wholesale_off_retail_pct,
       p.ws_qty_90d,
       round(p.ws_revenue_90d, 2) as ws_revenue_90d,
       p.ws_orders_90d,
       p.ws_qty_365d,
       round(p.ws_revenue_365d, 2) as ws_revenue_365d,
       round(p.ws_qty_90d * p.new_wholesale_price, 2) as forecast_ws_revenue_90d,
       round(p.ws_qty_90d * (p.new_wholesale_price - p.wholesale_price), 2) as extra_ws_revenue_90d,
       nullif(concat_ws(', ',
         case when not p.wholesale_applicable then 'NOT APPLICABLE' end,
         case when p.cost is null or p.cost <= 0 then 'NO COST' end,
         case when p.cost > 0 and p.wholesale_price <= p.cost then 'LOSS' end,
         case when p.cost > 0 and p.new_wholesale_price > p.cost and (p.new_wholesale_price - p.cost) / p.new_wholesale_price < 0.10 then 'LOW MARGIN' end,
         case when p.price > 0 and p.new_wholesale_price >= p.new_price then 'NOT BELOW RETAIL' end,
         case when p.new_wholesale_price > p.wholesale_price * (p.mult + 0.075) then 'BIG JUMP' end,
         case when floor(p.wholesale_price / case when p.wholesale_price < 1000 then 100 else 1000 end)
                <> floor(p.new_wholesale_price / case when p.wholesale_price < 1000 then 100 else 1000 end)
              then 'CROSSES ₱' || (floor(p.new_wholesale_price / case when p.wholesale_price < 1000 then 100 else 1000 end)
                                   * case when p.wholesale_price < 1000 then 100 else 1000 end)::bigint::text end,
         case when p.ws_qty_90d = 0 then 'NOT SOLD 90D' end
       ), '') as flags
  from priced p
 order by p.wholesale_applicable desc, p.ws_revenue_90d desc, p.ws_revenue_365d desc, p.item_code;
