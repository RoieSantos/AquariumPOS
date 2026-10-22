-- Read-only check: Delivered orders that did NOT post to Facebook - per "there is a delivered order but did
-- not post to facebook.. how can we check". Last 14 days, newest first. One result, by section:
--
--   'done stop'            - a stop marked done on the Delivery route (Mark Done). gma_post / amaya_post say
--                            what happened on each Page:
--                              posted        - on the Page (see the url)
--                              FAILED        - Facebook refused it; reason in *_error. The stop card shows
--                                              "Post to Facebook" to retry with the stored photo.
--                              STUCK (claim) - a post was started but never finished (phone closed / timed
--                                              out mid-post). Check the Page first; it may actually be there.
--                              not attempted - Mark Done saved, but step 2 (post_stop) never ran (app closed
--                                              right after Mark Done, or no signal). Retry from the stop card.
--                              skipped       - Amaya only: stop was posted to GMA before the 2-Page change.
--   'delivered, no stop'   - order is Delivered but has NO done stop, so nothing ever tried to post (e.g. set
--                            Delivered another way, or the stop was done on a different order no.).
--
-- Safe to run any time (no changes).

with done as (
  select
    coalesce(s."OrderID"::text, 'ADV-' || s."AdvanceTransactionNo", s."AutomatedOrderNo") as order_ref,
    s."DeliveryDate" as delivery_date,
    c.*
  from public."DeliveryStopCompletions" c
  join public."DeliveryStops" s on s."StopID" = c."StopID"
  where c."DoneAtUtc" > now() - interval '14 days'
)
select * from (
  select
    'done stop' as section,
    d.order_ref,
    d.delivery_date,
    d."DoneBy"::text as done_by,
    (d."DoneAtUtc" at time zone 'Asia/Manila')::timestamp(0) as done_at_ph,
    case when d."PostedAtUtc" is not null or d."FacebookPostId" is not null then 'posted'
         when d."PostClaimedAtUtc" is not null then 'STUCK (claim)'
         when d."PostError" is not null then 'FAILED'
         else 'not attempted' end as gma_post,
    case when d."AmayaPostId" = 'skipped' then 'skipped'
         when d."AmayaPostedAtUtc" is not null then 'posted'
         when d."AmayaPostClaimedAtUtc" is not null then 'STUCK (claim)'
         when d."AmayaPostError" is not null then 'FAILED'
         else 'not attempted' end as amaya_post,
    d."PostError"::text as gma_error,
    d."AmayaPostError"::text as amaya_error,
    d."FacebookPostUrl"::text as gma_url,
    d."AmayaPostUrl"::text as amaya_url,
    d."PhotoUrl"::text as photo_url,
    d."StopID"::text as stop_id
  from done d

  union all

  select
    'delivered, no stop', o."OrderID"::text, null, o."DeliveredBy"::text,
    (o."DeliveredAtUtc" at time zone 'Asia/Manila')::timestamp(0),
    'never tried', 'never tried', null, null, null, null, null, null
  from public."OnlineOrders" o
  where o."DeliveredAtUtc" > now() - interval '14 days'
    and not exists (
      select 1 from public."DeliveryStops" s
      join public."DeliveryStopCompletions" c on c."StopID" = s."StopID"
      where s."OrderID"::text = o."OrderID"::text
    )

  union all

  select
    'delivered, no stop', 'ADV-' || p."TransactionNo", null, p."DeliveredBy"::text,
    (p."DeliveredAtUtc" at time zone 'Asia/Manila')::timestamp(0),
    'never tried', 'never tried', null, null, null, null, null, null
  from public."AdvanceOrderProduction" p
  where p."DeliveredAtUtc" > now() - interval '14 days'
    and not exists (
      select 1 from public."DeliveryStops" s
      join public."DeliveryStopCompletions" c on c."StopID" = s."StopID"
      where s."AdvanceTransactionNo" = p."TransactionNo"
    )
) r
order by (gma_post = 'posted' and amaya_post in ('posted', 'skipped')), done_at_ph desc nulls last;
