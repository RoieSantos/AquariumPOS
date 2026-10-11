-- Read-only check: which Facebook Page did each recent Dispatcher ship post go to, and why - per "i
-- tried dispatching an order under amaya warehouse but its still send to RSpetstop GMA page".
--
--   page_recorded    - what service_claim_order_ship_post decided ('amaya' / 'gma'; null = the
--                      Amaya claim SQL wasn't run when it was posted)
--   page_by_branch   - what it SHOULD be from the order's warehouse name today
--   facebook_post_url- the link actually posted; its page id shows which Page really got it
--
-- If page_recorded = 'amaya' but the post is on the GMA Page -> the facebook-page-post Edge Function
-- is an old deploy (ignores the page) or FACEBOOK_RSPETSTOP_PAGE_ID / _POST_TOKEN hold the GMA Page's.
-- If page_recorded = 'gma' for an Amaya order -> its warehouse name matches 'gma'.
--
-- Safe to re-run.

select
  p."OrderID" as order_id,
  w."Name" as warehouse_name,
  p."Page" as page_recorded,
  case when coalesce(w."Name", '') ~* 'gma' then 'gma'
       when coalesce(w."Name", '') ~* 'amaya' then 'amaya' end as page_by_branch,
  p."PostedBy" as posted_by,
  p."PostClaimedAtUtc" at time zone 'Asia/Manila' as claimed_at_ph,
  p."PostedAtUtc" at time zone 'Asia/Manila' as posted_at_ph,
  p."FacebookPostUrl" as facebook_post_url,
  p."PostError" as post_error
from public."OnlineOrderShipPosts" p
left join public."OnlineOrders" o on o."OrderID" = p."OrderID"
left join public."Warehouses" w on w."ID" = o."LocationID"
order by p."PostClaimedAtUtc" desc nulls last
limit 15;
