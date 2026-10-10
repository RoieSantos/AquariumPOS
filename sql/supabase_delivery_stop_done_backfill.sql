-- One-off backfill for Mark Done (delivery.html) runs whose Facebook post went out but the stop
-- was NOT recorded as done - "Posted, but the stop could not be marked done: null value in column
-- "OrderID" of relation "OnlineOrderStatusPhotos"". That came from an older
-- service_mark_delivery_stop_done that didn't know draft-AO stops (DeliveryStops.AutomatedOrderNo).
--
-- The Edge Function had already uploaded the watermarked photo to the online-order-status-photos
-- bucket as <order / advance / AO no>/<timestamp>_delivered.jpg, so each such photo that isn't in
-- OnlineOrderStatusPhotos yet is matched back to its not-done stop and marked done with it. Nothing
-- is posted to Facebook again. DoneBy is recorded as 'Delivery Team (backfill)' since the upload
-- doesn't say who took it, and there is no Facebook link (the post id wasn't saved).
--
-- Only for photos made by the OLD post-first Edge Function (before Mark Done saved first). Once the
-- new function is deployed, a saved photo means the stop was recorded, so this finds nothing new.
--
-- Run AFTER re-running the latest supabase_delivery_stop_done_post.sql. Safe to re-run: a photo
-- or stop that's already recorded is skipped. Last 14 days only.

do $$
declare
  r record;
begin
  for r in
    select distinct on (o.name) s."StopID" as stop_id, o.name as path
    from storage.objects o
    join public."DeliveryStops" s
      on split_part(o.name, '/', 1) in (s."OrderID", s."AdvanceTransactionNo", to_jsonb(s) ->> 'AutomatedOrderNo')
    where o.bucket_id = 'online-order-status-photos'
      and o.name like '%\_delivered.jpg' escape '\'
      and o.created_at > now() - interval '14 days'
      and not exists (select 1 from public."OnlineOrderStatusPhotos" p where p."StoragePath" = o.name)
      and not exists (select 1 from public."DeliveryStopCompletions" c where c."StopID" = s."StopID")
    order by o.name, s."DeliveryDate" desc
  loop
    perform public.service_mark_delivery_stop_done(
      r.stop_id, 'Delivery Team (backfill)', r.path,
      'https://hymcmesqgpliyyeghpgq.supabase.co/storage/v1/object/public/online-order-status-photos/' || r.path);
    -- These photos came from the old post-first flow, so Facebook already has the post: record it
    -- as posted, or the card would offer "Post to Facebook" and post it a second time.
    update public."DeliveryStopCompletions"
       set "PostedAtUtc" = now(), "PostClaimedAtUtc" = now()
     where "StopID" = r.stop_id and "PostedAtUtc" is null;
  end loop;
end;
$$;

-- Result: every stop marked done in the last 14 days, newest first (the backfilled one included).
select c."DoneAtUtc" at time zone 'Asia/Manila' as done_at_manila,
       coalesce(s."OrderID", 'ADV-' || s."AdvanceTransactionNo", to_jsonb(s) ->> 'AutomatedOrderNo') as order_no,
       s."DeliveryDate" as delivery_date,
       c."DoneBy" as done_by,
       c."PhotoUrl" as photo_url,
       c."FacebookPostUrl" as facebook_post_url
from public."DeliveryStopCompletions" c
join public."DeliveryStops" s on s."StopID" = c."StopID"
where c."DoneAtUtc" > now() - interval '14 days'
order by c."DoneAtUtc" desc;
