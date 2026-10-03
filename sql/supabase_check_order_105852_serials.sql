-- Read-only: why Ready to Ship didn't take order 105852's serials out of stock. ONE query (the Supabase
-- editor only shows the last statement's result), three sections in the `section` column:
--
--   1 serial   - serials tied to the order. NO rows = no serial step ran at all (the To Ship didn't go
--                through the portal's serial picker). how = 'picked from stock' (existing serial claimed)
--                or 'new serial created' ("+ New serial" - stock untouched).
--   2 stock    - what the order line needs, and IN STOCK now at the order's branch.
--   3 pancake  - Pancake's own edit history / editor / status fields for the order - who moved it to
--                To Ship and from where (desktop POS / Pancake / portal).

with resp as (
  select extensions.http_get(
    'https://pos.pages.fm/api/v1/shops/1328301944/orders/105852?api_key=' || public._pancake_api_key()
  ) as r
),
el as (
  select case when jsonb_typeof((r).content::jsonb -> 'data') = 'object' then (r).content::jsonb -> 'data'
              else (r).content::jsonb end as o
  from resp
)
select '1 serial' as section,
       s."SerialNo" as field,
       format('%s | variant %s | %s | %s | %s | source doc %s | by %s | %s',
              s."ItemCode", coalesce(s."VariantCode", '-'), s."Location", s."Status",
              case when s."SourceDocumentNo" = s."SoldOnlineOrderId" then 'new serial created' else 'picked from stock' end,
              coalesce(s."SourceDocumentNo", '-'), coalesce(s."UpdatedBy", s."CreatedBy", '-'), s."UpdatedAtUtc") as value
from public."ItemSerialTracking" s
where s."SoldOnlineOrderId" = '105852'

union all
select '1 serial', '(count)', count(*)::text || ' serial(s) tied to this order'
from public."ItemSerialTracking" s
where s."SoldOnlineOrderId" = '105852'

union all
select '2 stock', l."ItemCode" || ' x ' || l."Quantity",
       format('variant %s | branch %s | in stock now: %s', l."VariationId", w."Name",
         (select count(*) from public."ItemSerialTracking" s
           where s."Status" = 'IN_STOCK' and s."ItemCode" = l."ItemCode"
             and coalesce(nullif(trim(s."VariantCode"), ''), '') = coalesce(nullif(trim(l."VariationId"), ''), '')
             and s."Location" = w."Name"))
from public."OnlineOrderLines" l
join public."OnlineOrders" o on o."OrderID" = l."OrderID"
left join public."Warehouses" w on w."ID" = o."LocationID"
where l."OrderID" = '105852'

union all
select '3 pancake', k.key, left(k.value::text, 4000)
from el, jsonb_each(el.o) k
where k.key ~* '(histor|editor|edit|updated_by|status|assigning|seller|creator|source)'

order by 1, 2;
