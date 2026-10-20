-- Read-only check: the latest Facebook ship (Dispatch) posts, their caption, and the order lines the
-- caption writer (facebook-page-post orderItemsText) reads for that order - to see why a caption
-- left out the item size / details. Online orders read OnlineOrderLines; 'ADV-<no>' advance orders
-- read AdvanceOrderLines. lines_found = 0 means the caption writer had nothing to go on.
-- Safe to run any time (no changes).

select
  p."OrderID" as order_id,
  p."PostedAtUtc" as posted_at_utc,
  p."PostError" as post_error,
  coalesce(ol.cnt, al.cnt, 0) as lines_found,
  coalesce(ol.lines, al.lines) as order_lines,
  p."PostCaption" as caption
from public."OnlineOrderShipPosts" p
left join lateral (
  select count(*) as cnt,
         string_agg(coalesce(l."Description", '(no name)') || ' | SKU: ' || coalesce(l."ItemCode", '') || ' | qty ' || coalesce(l."Quantity"::text, '')
                    || coalesce(' | note: ' || left(replace(l."Note", E'\n', ' / '), 200), ''), E'\n') as lines
  from public."OnlineOrderLines" l
  where l."OrderID" = p."OrderID"
  having count(*) > 0
) ol on true
left join lateral (
  select count(*) as cnt,
         string_agg(coalesce(a."Description", '(no name)') || ' | No: ' || coalesce(a."No", '') || ' | qty ' || coalesce(a."Quantity"::text, ''), E'\n') as lines
  from public."AdvanceOrderLines" a
  where p."OrderID" ilike 'ADV-%' and a."TransactionNo" = substr(p."OrderID", 5)
  having count(*) > 0
) al on true
order by coalesce(p."PostedAtUtc", p."PostClaimedAtUtc") desc nulls last
limit 10;
