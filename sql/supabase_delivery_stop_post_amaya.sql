-- Delivery "Mark Done" posts to BOTH Facebook Pages - per "it will post to GMA page.. can we post to Amaya
-- and Gma both?". Each done stop is now posted to the GMA Page AND the RS Pet Stop (Amaya) Page - the same
-- Page Amaya ship posts already go to (FACEBOOK_RSPETSTOP_POST_TOKEN / _PAGE_ID secrets).
--
-- Same "at most once per stop" rule as supabase_delivery_stop_done_post.sql, now per Page: the GMA post keeps
-- its existing columns, the Amaya post gets its own (Amaya*), and the Edge Function claims each Page
-- separately before posting - so a retry only posts the Page(s) that didn't go out, never one twice.
--
-- Stops already posted to GMA before this file are NOT posted to Amaya afterwards (marked 'skipped' once, when
-- the columns are first added) - otherwise every old stop would show "Post to Facebook" again.
--
-- Adds columns + 2 service functions (claim / finish per Page); re-creates staff_list_delivery_stop_completions
-- (supabase_delivery_stop_done_post.sql) so a stop counts as posted only once both Pages are, + amaya_post_url.
-- Run AFTER supabase_delivery_stop_done_post.sql. Safe to re-run.
-- Needs the facebook-page-post Edge Function redeployed, and js/delivery.js ?v=amayapost1.

do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'DeliveryStopCompletions' and column_name = 'AmayaPostedAtUtc'
  ) then
    alter table public."DeliveryStopCompletions"
      add column "AmayaPostId" varchar(100),
      add column "AmayaPostUrl" varchar(500),
      add column "AmayaPostCaption" text,
      add column "AmayaPostedAtUtc" timestamptz,
      add column "AmayaPostClaimedAtUtc" timestamptz,
      add column "AmayaPostError" text;
    -- First run only: stops already on the GMA Page stay GMA-only.
    update public."DeliveryStopCompletions"
       set "AmayaPostId" = 'skipped', "AmayaPostedAtUtc" = now()
     where "PostedAtUtc" is not null or "FacebookPostId" is not null;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. Claim one Page's post for a done stop (p_page = 'gma' / 'amaya'). Same rules as
--    service_claim_delivery_stop_post: only one caller wins, a claim is only released by a failed post.

create or replace function public.service_claim_delivery_stop_post_page(p_stop_id uuid, p_page text)
returns table(status text, photo_storage_path text, facebook_post_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row public."DeliveryStopCompletions";
begin
  if p_page not in ('gma', 'amaya') then
    raise exception 'Page must be gma or amaya.';
  end if;
  select * into v_row from public."DeliveryStopCompletions" where "StopID" = p_stop_id for update;
  if not found then
    return query select 'not_done'::text, null::text, null::text;
    return;
  end if;

  if p_page = 'gma' then
    if v_row."PostedAtUtc" is not null or v_row."FacebookPostId" is not null then
      return query select 'posted'::text, v_row."PhotoStoragePath"::text, v_row."FacebookPostUrl"::text;
    elsif v_row."PostClaimedAtUtc" is not null then
      return query select 'in_progress'::text, v_row."PhotoStoragePath"::text, null::text;
    else
      update public."DeliveryStopCompletions" set "PostClaimedAtUtc" = now(), "PostError" = null where "StopID" = p_stop_id;
      return query select 'claimed'::text, v_row."PhotoStoragePath"::text, null::text;
    end if;
  else
    if v_row."AmayaPostedAtUtc" is not null or v_row."AmayaPostId" is not null then
      return query select 'posted'::text, v_row."PhotoStoragePath"::text, v_row."AmayaPostUrl"::text;
    elsif v_row."AmayaPostClaimedAtUtc" is not null then
      return query select 'in_progress'::text, v_row."PhotoStoragePath"::text, null::text;
    else
      update public."DeliveryStopCompletions" set "AmayaPostClaimedAtUtc" = now(), "AmayaPostError" = null where "StopID" = p_stop_id;
      return query select 'claimed'::text, v_row."PhotoStoragePath"::text, null::text;
    end if;
  end if;
end;
$$;

revoke all on function public.service_claim_delivery_stop_post_page(uuid, text) from public, anon, authenticated;
grant execute on function public.service_claim_delivery_stop_post_page(uuid, text) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Outcome of one Page's claimed post: p_post_id set = posted (claim kept); else failed (claim released).

create or replace function public.service_finish_delivery_stop_post_page(
  p_stop_id uuid, p_page text, p_post_id text, p_post_url text, p_caption text, p_error text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_posted boolean := nullif(trim(coalesce(p_post_id, '')), '') is not null;
begin
  if p_page = 'gma' then
    perform public.service_finish_delivery_stop_post(p_stop_id, p_post_id, p_post_url, p_caption, p_error);
  elsif p_page = 'amaya' then
    if v_posted then
      update public."DeliveryStopCompletions"
         set "AmayaPostId" = p_post_id, "AmayaPostUrl" = p_post_url, "AmayaPostCaption" = p_caption,
             "AmayaPostedAtUtc" = now(), "AmayaPostError" = null
       where "StopID" = p_stop_id;
    else
      update public."DeliveryStopCompletions"
         set "AmayaPostClaimedAtUtc" = null, "AmayaPostError" = left(coalesce(p_error, 'Post failed.'), 1000),
             "AmayaPostCaption" = coalesce(p_caption, "AmayaPostCaption")
       where "StopID" = p_stop_id;
    end if;
  else
    raise exception 'Page must be gma or amaya.';
  end if;
end;
$$;

revoke all on function public.service_finish_delivery_stop_post_page(uuid, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.service_finish_delivery_stop_post_page(uuid, text, text, text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Stop cards: posted only once BOTH Pages are; the error says which Page failed; + amaya_post_url.

drop function if exists public.staff_list_delivery_stop_completions(text, text, uuid[]);

create or replace function public.staff_list_delivery_stop_completions(
  p_username text,
  p_password text,
  p_stop_ids uuid[]
)
returns table(stop_id uuid, done_by text, done_at_utc timestamptz, facebook_post_url text,
              post_status text, post_error text, post_claimed_at_utc timestamptz, amaya_post_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;

  return query
  select c."StopID", coalesce(u."DisplayName", c."DoneBy")::text, c."DoneAtUtc", c."FacebookPostUrl"::text,
         case when (c."PostedAtUtc" is not null or c."FacebookPostId" is not null)
                   and (c."AmayaPostedAtUtc" is not null or c."AmayaPostId" is not null) then 'posted'
              when c."PostClaimedAtUtc" is not null or c."AmayaPostClaimedAtUtc" is not null then 'in_progress'
              when c."PostError" is not null or c."AmayaPostError" is not null then 'failed'
              else 'not_posted' end,
         nullif(concat_ws(' / ',
           case when c."PostError" is not null then 'GMA: ' || c."PostError" end,
           case when c."AmayaPostError" is not null then 'Amaya: ' || c."AmayaPostError" end), '')::text,
         coalesce(c."PostClaimedAtUtc", c."AmayaPostClaimedAtUtc"),
         nullif(c."AmayaPostUrl", '')::text
    from public."DeliveryStopCompletions" c
    left join public."StaffUsers" u on u."Username" = c."DoneBy"
   where c."StopID" = any(p_stop_ids);
end;
$$;

grant execute on function public.staff_list_delivery_stop_completions(text, text, uuid[]) to anon;

notify pgrst, 'reload schema';
