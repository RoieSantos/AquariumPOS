-- READ-ONLY. Is a saved price change reasonable? Per "can you check if this priceincrease is reasonable?"
-- (Price Increase page, draft #1: +5%, 615 retail / 71 wholesale lines). Change batch_id in params to check
-- another one. Nothing is changed.
--
-- ONE result, sorted by section:
--   1 summary       - line counts, average / min / max real increase, extra income per 90 days, uplift %
--   2 spread        - how many retail lines fall in each real-increase band (rounding makes cheap items jump more)
--   3 check         - one row per item that needs a look: below cost, low margin (< 15% retail / < 10% wholesale),
--                     wholesale >= retail, big jump (> 12.5%), no cost entered, price edited since the draft
--                     was saved (Apply Now would refuse; a schedule would skip it)
--   4 top impact    - the 15 lines adding the most income (same units sold in 90 days at the new price)
--   5 biggest jumps - the 15 biggest % retail increases with sales
--   6 category      - per category: lines, average increase, extra income
-- Sales = Online Orders (online + walk-ins) last 90 days, cancelled excluded - same source as the page.

with params as (
  select 1::bigint as batch_id
),
sales as (
  select l."ItemCode" as code, nullif(trim(l."VariationId"), '') as vid, sum(l."Quantity") as qty
    from public."OnlineOrderLines" l
    join public."OnlineOrders" o on o."OrderID" = l."OrderID"
   where o."Date" >= current_date - 90
     and lower(trim(coalesce(o."Status", ''))) not in ('cancelled', 'canceled', 'cancel')
   group by 1, 2
),
item_sales as (select code, sum(qty) as qty from sales group by code),
variant_sales as (select vid, sum(qty) as qty from sales where vid is not null group by vid),
lines as (
  select l."Kind" as kind, l."ItemCode" as item_code, l."VariationId" as variation_id,
         coalesce(l."Name", i."Name")::text as name, coalesce(i."CategoryCode", '')::text as category,
         l."OldPrice" as old_price, l."NewPrice" as new_price,
         l."OldWholesalePrice" as old_ws, l."NewWholesalePrice" as new_ws,
         round(i."Cost", 2) as cost,
         case when l."Kind" = 'variant' then round(v."Price", 2) else round(i."Price", 2) end as current_price,
         round(i."WholesalePrice", 2) as current_ws,
         coalesce(case when l."Kind" = 'variant' then vs.qty else s.qty end, 0) as sold_90d
    from public."PriceChangeBatchLines" l
    join params p on p.batch_id = l."BatchId"
    left join public."Items" i on i."Code" = l."ItemCode"
    left join public."Variants" v on v."VariationId" = l."VariationId"
    left join item_sales s on s.code = l."ItemCode"
    left join variant_sales vs on vs.vid = l."VariationId"
),
calc as (
  select l.*,
         case when l.new_price is not null and l.old_price > 0 then round((l.new_price / l.old_price - 1) * 100, 2) end as retail_pct,
         case when l.new_ws is not null and l.old_ws > 0 then round((l.new_ws / l.old_ws - 1) * 100, 2) end as ws_pct,
         case when l.new_price > 0 and l.cost > 0 then round((l.new_price - l.cost) / l.new_price * 100, 1) end as new_margin,
         case when l.new_ws > 0 and l.cost > 0 then round((l.new_ws - l.cost) / l.new_ws * 100, 1) end as new_ws_margin,
         case when l.new_price is not null then l.sold_90d * (l.new_price - l.old_price) else 0 end as extra_90d,
         case when l.new_price is not null then l.sold_90d * l.old_price else 0 end as revenue_90d
    from lines l
),
result_rows as (
  -- 1 summary
  select '1 summary' as section, 1 as sort, 'Retail lines' as item, null::text as category,
         null::numeric as old_price, null::numeric as new_price,
         round(avg(retail_pct), 2) as change_pct, null::numeric as cost, null::numeric as new_margin_pct,
         null::numeric as sold_90d, null::numeric as extra_90d,
         count(*) filter (where new_price is not null) || ' lines; real increase min ' || coalesce(min(retail_pct)::text, '-')
           || '% / avg ' || coalesce(round(avg(retail_pct), 2)::text, '-') || '% / max ' || coalesce(max(retail_pct)::text, '-') || '%' as note
    from calc where new_price is not null
  union all
  select '1 summary', 2, 'Wholesale lines', null, null, null, round(avg(ws_pct), 2), null, null, null, null,
         count(*) || ' lines; increase min ' || coalesce(min(ws_pct)::text, '-') || '% / avg '
           || coalesce(round(avg(ws_pct), 2)::text, '-') || '% / max ' || coalesce(max(ws_pct)::text, '-') || '%'
    from calc where new_ws is not null
  union all
  select '1 summary', 3, 'Extra retail income / 90 days', null, null, null,
         case when sum(revenue_90d) > 0 then round(sum(extra_90d) / sum(revenue_90d) * 100, 2) end, null, null,
         sum(sold_90d) filter (where new_price is not null), round(sum(extra_90d), 2),
         'on ' || round(sum(revenue_90d), 2) || ' of 90-day sales of these items (change_pct = real uplift; same units sold)'
    from calc
  union all
  select '1 summary', 4, 'Not sold in 90 days', null, null, null, null, null, null, null, null,
         count(*) || ' of the retail lines had no sales in 90 days (no income effect, just tidier prices)'
    from calc where new_price is not null and sold_90d = 0
  union all
  -- 2 spread
  select '2 spread', b.ord, b.band, null, null, null, null, null, null,
         sum(c.sold_90d), round(sum(c.extra_90d), 2), count(c.item_code) || ' retail lines'
    from (values (1, 'up to 5%', -1000::numeric, 5.0001::numeric), (2, '5 - 7.5%', 5.0001, 7.5001),
                 (3, '7.5 - 10%', 7.5001, 10.0001), (4, '10 - 15%', 10.0001, 15.0001), (5, 'over 15%', 15.0001, 100000)) b(ord, band, lo, hi)
    left join calc c on c.retail_pct >= b.lo and c.retail_pct < b.hi
   group by b.ord, b.band
  union all
  -- 3 check
  select '3 check', 1, item_code || ' ' || name, category, old_price, new_price, retail_pct, cost, new_margin, sold_90d, round(extra_90d, 2),
         'BELOW COST - new retail at or below cost'
    from calc where new_price > 0 and cost > 0 and new_price <= cost
  union all
  select '3 check', 2, item_code || ' ' || name, category, old_price, new_price, retail_pct, cost, new_margin, sold_90d, round(extra_90d, 2),
         'LOW MARGIN - under 15% after the increase'
    from calc where new_price > cost and cost > 0 and new_margin < 15
  union all
  select '3 check', 3, item_code || ' ' || name, category, old_ws, new_ws, ws_pct, cost, new_ws_margin, sold_90d, null,
         case when new_ws <= cost then 'WHOLESALE BELOW COST' else 'LOW WHOLESALE MARGIN - under 10%' end
    from calc where new_ws > 0 and cost > 0 and (new_ws <= cost or new_ws_margin < 10)
  union all
  select '3 check', 4, item_code || ' ' || name, category, old_ws, new_ws, ws_pct, cost, null, sold_90d, null,
         'WHOLESALE >= RETAIL (' || coalesce(new_price, current_price) || ')'
    from calc where new_ws > 0 and coalesce(new_price, current_price) > 0 and new_ws >= coalesce(new_price, current_price)
  union all
  select '3 check', 5, item_code || ' ' || name, category, old_price, new_price, retail_pct, cost, new_margin, sold_90d, round(extra_90d, 2),
         'BIG JUMP - over 12.5% (usually rounding on a cheap item)'
    from calc where retail_pct > 12.5
  union all
  select '3 check', 6, item_code || ' ' || name, category, old_ws, new_ws, ws_pct, cost, new_ws_margin, sold_90d, null,
         'BIG WHOLESALE JUMP - over 12.5%'
    from calc where ws_pct > 12.5
  union all
  select '3 check', 7, item_code || ' ' || name, category, old_price, new_price, retail_pct, null, null, sold_90d, round(extra_90d, 2),
         'PRICE EDITED SINCE SAVED - now ' || coalesce(current_price::text, 'missing') || coalesce(' / wholesale ' || current_ws, '')
    from calc
   where (new_price is not null and current_price is distinct from round(old_price, 2))
      or (new_ws is not null and current_ws is distinct from round(old_ws, 2))
  union all
  select '3 check', 8, 'Items with no cost entered', null, null, null, null, null, null, sum(sold_90d), round(sum(extra_90d), 2),
         count(*) || ' changing lines have no cost, so their margin cannot be checked'
    from calc where new_price is not null and not (cost > 0)
  union all
  -- 4 top impact
  select '4 top impact', (row_number() over (order by extra_90d desc))::int, item_code || ' ' || name, category,
         old_price, new_price, retail_pct, cost, new_margin, sold_90d, round(extra_90d, 2), null
    from (select * from calc where extra_90d > 0 order by extra_90d desc limit 15) t
  union all
  -- 5 biggest jumps
  select '5 biggest jumps', (row_number() over (order by retail_pct desc))::int, item_code || ' ' || name, category,
         old_price, new_price, retail_pct, cost, new_margin, sold_90d, round(extra_90d, 2), null
    from (select * from calc where retail_pct is not null and sold_90d > 0 order by retail_pct desc limit 15) t
  union all
  -- 6 category
  select '6 category', 0, coalesce(nullif(category, ''), '(none)'), null, null, null, round(avg(retail_pct), 2), null,
         round(avg(new_margin), 1), sum(sold_90d), round(sum(extra_90d), 2),
         count(*) filter (where new_price is not null) || ' retail / ' || count(*) filter (where new_ws is not null) || ' wholesale lines'
    from calc group by category
)
select section, item, category, old_price, new_price, change_pct, cost, new_margin_pct, sold_90d, extra_90d, note
  from result_rows
 order by section, sort, extra_90d desc nulls last, item;
