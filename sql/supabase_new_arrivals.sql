-- NEW ARRIVALS - automatic Facebook announcement when fish / plants are received at a store.
--
-- Per request (2026-11-19): "purchase orders come in to the Warehouse, we transfer to the stores -
-- can we auto-post NEW ARRIVALS of the fishes that have been transferred to the store? also a photo
-- announcement with our logo". Decisions: FULLY automatic (no staff tap), posted to the receiving
-- store's own Page (GMA -> GMA Page, Amaya -> RS Pet Stop Page, same routing as delivery/ship
-- posts), photo = one branded "📣 NEW ARRIVALS" banner with the name + logo (made on the New
-- Arrivals page), fish names in the caption, NO prices. Also shown on rspetstop.com and to Alice.
--
-- Flow:
--   1. Receive on a Transfer Order archives its lines into Posted_Transfer_Line in ONE insert
--      (transferOrders.js archiveReceivedTransferOrder). The statement trigger below turns the
--      received lines in an announced category (NewArrivalSettings."CategoryCodes", default FISH +
--      PLANTS) into ONE "NewArrivalPosts" row per transfer (Pending). It can never block a Receive -
--      any error in it is swallowed with a warning.
--   2. The Edge Function new-arrivals-post claims Pending rows (service_claim_new_arrival_posts) and
--      posts the banner + caption to the store's Page, then records the result. It is called right
--      after Receive by the portal (fire-and-forget) AND every 5 minutes by pg_cron as the backup -
--      the cron only makes an HTTP call when something is actually waiting.
--   3. Each transfer posts at most once: the claim flips Pending -> Posting atomically. A post that
--      Facebook definitely rejected is retried automatically up to 3 attempts, 15 minutes apart; a
--      post whose outcome is unknown (network error / crash mid-call) is NOT retried by itself, to
--      never double-post - it shows as Failed on the New Arrivals page with a Retry button.
--      Anything still waiting after 2 days is skipped (no stale "new arrivals" posts).
--
-- Run once (safe to re-run). Then deploy the Edge Function:
--   supabase functions deploy new-arrivals-post --project-ref hymcmesqgpliyyeghpgq --no-verify-jwt
-- and open New Arrivals (Marketing menu) once so it builds and saves the banner.

-- ============================================================================
-- 1. Tables
-- ============================================================================

create table if not exists public."NewArrivalSettings" (
  "Id" integer primary key default 1 check ("Id" = 1),
  "Enabled" boolean not null default true,
  "CategoryCodes" text[] not null default array['FISH', 'PLANTS'],
  "WebsiteDays" integer not null default 7,
  "BannerUrl" text,
  "UpdatedBy" text,
  "UpdatedAtUtc" timestamptz not null default now()
);
insert into public."NewArrivalSettings" ("Id") values (1) on conflict ("Id") do nothing;
alter table public."NewArrivalSettings" enable row level security;

create table if not exists public."NewArrivalPosts" (
  "Id" bigserial primary key,
  "DocumentNo" varchar not null unique,
  "Warehouse" text,
  "Page" text,                        -- 'gma' | 'amaya' (null = not a store with a Page)
  "Items" jsonb not null default '[]'::jsonb,   -- [{item_no, name, qty}]
  "Status" text not null default 'Pending',     -- Pending | Posting | Posted | Failed | Skipped
  "Attempts" integer not null default 0,
  "Retryable" boolean not null default false,
  "Caption" text,
  "PostId" text,
  "PostUrl" text,
  "Error" text,
  "CreatedAtUtc" timestamptz not null default now(),
  "ClaimedAtUtc" timestamptz,
  "PostedAtUtc" timestamptz,
  "UpdatedBy" text
);
create index if not exists "IX_NewArrivalPosts_Status" on public."NewArrivalPosts" ("Status");
alter table public."NewArrivalPosts" enable row level security;

-- ============================================================================
-- 2. Queue on Receive - statement trigger on Posted_Transfer_Line
-- ============================================================================

create or replace function public._new_arrivals_page_for(p_warehouse text)
returns text
language sql
immutable
as $$
  select case
    when p_warehouse ilike '%amaya%' then 'amaya'
    when p_warehouse ilike '%gma%' then 'gma'
  end;
$$;

create or replace function public._new_arrivals_queue_from_posted_lines()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_enabled boolean;
  v_codes text[];
  r record;
  v_page text;
begin
  begin
    select s."Enabled", s."CategoryCodes" into v_enabled, v_codes
    from public."NewArrivalSettings" s where s."Id" = 1;
    if not coalesce(v_enabled, false) then
      return null;
    end if;

    for r in
      select n."Document No." as doc,
             coalesce(max(h."To Warehouse"), max(th."To Warehouse")) as wh,
             jsonb_agg(jsonb_build_object(
               'item_no', n."Item No.",
               'name', coalesce(nullif(trim(i."Name"), ''), nullif(trim(n."Description"), ''), n."Item No.")
                       || case when nullif(trim(n."Variant Name"), '') is not null then ' (' || trim(n."Variant Name") || ')' else '' end,
               'qty', n."Qty Received",
               'category', upper(trim(coalesce(i."CategoryCode", n."CategoryCode", '')))
             ) order by n."Line No.") as items
      from new_rows n
      left join public."Items" i on i."Code" = n."Item No."
      left join public."Posted_Transfer_Header" h on h."No." = n."Document No."
      left join public."Transfer_Header" th on th."No." = n."Document No."
      where coalesce(n."Qty Received", 0) > 0
        and upper(trim(coalesce(i."CategoryCode", n."CategoryCode", ''))) in (select upper(trim(x)) from unnest(v_codes) x)
      group by n."Document No."
    loop
      v_page := public._new_arrivals_page_for(r.wh);
      insert into public."NewArrivalPosts" ("DocumentNo", "Warehouse", "Page", "Items", "Status", "Error")
      values (
        r.doc, r.wh, v_page, r.items,
        case when v_page is null then 'Skipped' else 'Pending' end,
        case when v_page is null then 'Received at ' || coalesce(r.wh, '?') || ' - not a store with a Facebook Page.' end
      )
      on conflict ("DocumentNo") do nothing;
    end loop;
  exception when others then
    -- Never let the announcement block a Receive.
    raise warning 'New Arrivals queue failed: %', sqlerrm;
  end;
  return null;
end;
$$;

drop trigger if exists "TR_Posted_Transfer_Line_NewArrivals" on public."Posted_Transfer_Line";
create trigger "TR_Posted_Transfer_Line_NewArrivals"
  after insert on public."Posted_Transfer_Line"
  referencing new table as new_rows
  for each statement
  execute function public._new_arrivals_queue_from_posted_lines();

-- ============================================================================
-- 3. Service RPCs - used only by the new-arrivals-post Edge Function (service role)
-- ============================================================================

drop function if exists public.service_claim_new_arrival_posts(integer);

create or replace function public.service_claim_new_arrival_posts(p_limit integer default 5)
returns setof public."NewArrivalPosts"
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  -- Crashed mid-post (outcome unknown) -> Failed, NOT retried automatically (could double-post).
  update public."NewArrivalPosts"
     set "Status" = 'Failed', "Retryable" = false,
         "Error" = coalesce("Error", 'Posting was interrupted - check the Page, then Retry if it is not there.')
   where "Status" = 'Posting' and "ClaimedAtUtc" < now() - interval '10 minutes';

  -- Too old to be "new" any more.
  update public."NewArrivalPosts"
     set "Status" = 'Skipped', "Error" = 'Not posted within 2 days - skipped so an old arrival is not announced as new.'
   where "Status" in ('Pending', 'Failed') and "CreatedAtUtc" < now() - interval '2 days';

  return query
  update public."NewArrivalPosts" p
     set "Status" = 'Posting', "Attempts" = p."Attempts" + 1, "ClaimedAtUtc" = now(), "Error" = null
   where p."Id" in (
     select q."Id" from public."NewArrivalPosts" q
      where q."Page" is not null
        and (q."Status" = 'Pending'
             or (q."Status" = 'Failed' and q."Retryable" and q."Attempts" < 3
                 and q."ClaimedAtUtc" < now() - interval '15 minutes'))
      order by q."Id"
      limit greatest(coalesce(p_limit, 5), 1)
      for update skip locked
   )
  returning p.*;
end;
$$;

drop function if exists public.service_finish_new_arrival_post(bigint, boolean, text, text, text, text, boolean);

create or replace function public.service_finish_new_arrival_post(
  p_id bigint, p_ok boolean, p_caption text, p_post_id text, p_post_url text, p_error text, p_retryable boolean
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  update public."NewArrivalPosts"
     set "Status" = case when p_ok then 'Posted' else 'Failed' end,
         "Caption" = coalesce(p_caption, "Caption"),
         "PostId" = p_post_id,
         "PostUrl" = p_post_url,
         "Error" = case when p_ok then null else p_error end,
         "Retryable" = case when p_ok then false else coalesce(p_retryable, false) end,
         "PostedAtUtc" = case when p_ok then now() else "PostedAtUtc" end
   where "Id" = p_id;
end;
$$;

revoke all on function public.service_claim_new_arrival_posts(integer) from public, anon, authenticated;
revoke all on function public.service_finish_new_arrival_post(bigint, boolean, text, text, text, text, boolean) from public, anon, authenticated;
grant execute on function public.service_claim_new_arrival_posts(integer) to service_role;
grant execute on function public.service_finish_new_arrival_post(bigint, boolean, text, text, text, text, boolean) to service_role;

-- ============================================================================
-- 4. Backup cron - every 5 minutes, HTTP call only when something is waiting
-- ============================================================================

create or replace function public.cron_dispatch_new_arrivals()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  -- Public/"publishable" anon key - same value as docs/js/config.js and the other cron wrappers.
  v_anon_key text := 'sb_publishable_QWDFggQ9ce9zm65xFEzmHA_rGaOUFQz';
  v_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co/functions/v1/new-arrivals-post';
begin
  if not exists (
    select 1 from public."NewArrivalPosts"
     where "Status" = 'Pending'
        or ("Status" = 'Failed' and "Retryable" and "Attempts" < 3 and "ClaimedAtUtc" < now() - interval '15 minutes')
        or ("Status" = 'Posting' and "ClaimedAtUtc" < now() - interval '10 minutes')
  ) then
    return;
  end if;

  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '25000');
    perform extensions.http((
      'POST',
      v_url,
      array[
        extensions.http_header('Authorization', 'Bearer ' || v_anon_key),
        extensions.http_header('apikey', v_anon_key)
      ],
      'application/json',
      '{"action":"dispatch"}'
    )::extensions.http_request);
  exception when others then
    null; -- best effort; the next tick retries
  end;
end;
$$;

do $$
begin
  perform cron.unschedule('dispatch-new-arrivals') where exists (select 1 from cron.job where jobname = 'dispatch-new-arrivals');
end;
$$;

select cron.schedule('dispatch-new-arrivals', '*/5 * * * *', $$select public.cron_dispatch_new_arrivals();$$);

-- ============================================================================
-- 5. New Arrivals page RPCs (super users)
-- ============================================================================

drop function if exists public.admin_get_new_arrival_settings(text, text);

create or replace function public.admin_get_new_arrival_settings(p_admin_username text, p_admin_password text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return (
    select jsonb_build_object(
      'enabled', s."Enabled", 'category_codes', to_jsonb(s."CategoryCodes"), 'website_days', s."WebsiteDays",
      'banner_url', s."BannerUrl", 'updated_by', s."UpdatedBy", 'updated_at', s."UpdatedAtUtc",
      'categories', (
        select coalesce(jsonb_agg(jsonb_build_object('code', c."Code", 'description', c."Description") order by c."Code"), '[]'::jsonb)
        from public."Categories" c
        where exists (select 1 from public."Items" i where i."CategoryCode" = c."Code")
      )
    )
    from public."NewArrivalSettings" s where s."Id" = 1
  );
end;
$$;

drop function if exists public.admin_save_new_arrival_settings(text, text, boolean, text[], integer);

create or replace function public.admin_save_new_arrival_settings(
  p_admin_username text, p_admin_password text, p_enabled boolean, p_category_codes text[], p_website_days integer
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  update public."NewArrivalSettings"
     set "Enabled" = coalesce(p_enabled, true),
         "CategoryCodes" = coalesce(p_category_codes, array[]::text[]),
         "WebsiteDays" = least(greatest(coalesce(p_website_days, 7), 1), 60),
         "UpdatedBy" = p_admin_username, "UpdatedAtUtc" = now()
   where "Id" = 1;
end;
$$;

drop function if exists public.admin_set_new_arrival_banner(text, text, text);

create or replace function public.admin_set_new_arrival_banner(p_admin_username text, p_admin_password text, p_url text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  update public."NewArrivalSettings"
     set "BannerUrl" = nullif(trim(p_url), ''), "UpdatedBy" = p_admin_username, "UpdatedAtUtc" = now()
   where "Id" = 1;
end;
$$;

-- Signed upload for the banner PNG - always the same path (upsert), like the company logo
-- (supabase_portal_logo_upload.sql, whose _create_signed_portal_asset_upload this reuses).
drop function if exists public.admin_create_new_arrivals_banner_upload(text, text);

create or replace function public.admin_create_new_arrivals_banner_upload(p_admin_username text, p_admin_password text)
returns table(storage_path text, upload_token text, public_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return query select * from public._create_signed_portal_asset_upload('new-arrivals/banner.png');
end;
$$;

drop function if exists public.admin_list_new_arrival_posts(text, text, integer);

create or replace function public.admin_list_new_arrival_posts(p_admin_username text, p_admin_password text, p_limit integer default 50)
returns setof public."NewArrivalPosts"
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return query select * from public."NewArrivalPosts" order by "Id" desc limit least(greatest(coalesce(p_limit, 50), 1), 500);
end;
$$;

-- Retry (Failed / Skipped -> Pending, posted on the next dispatch) or Skip (Pending / Failed -> Skipped).
drop function if exists public.admin_set_new_arrival_post_status(text, text, bigint, text);

create or replace function public.admin_set_new_arrival_post_status(
  p_admin_username text, p_admin_password text, p_id bigint, p_action text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_status text;
  v_page text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  select "Status", "Page" into v_status, v_page from public."NewArrivalPosts" where "Id" = p_id for update;
  if v_status is null then
    raise exception 'Announcement not found.';
  end if;

  if p_action = 'retry' then
    if v_status not in ('Failed', 'Skipped') then
      raise exception 'Only a Failed or Skipped announcement can be retried (this one is %).', v_status;
    end if;
    if v_page is null then
      raise exception 'This transfer was not received at a store with a Facebook Page.';
    end if;
    update public."NewArrivalPosts"
       set "Status" = 'Pending', "Error" = null, "CreatedAtUtc" = now(), "UpdatedBy" = p_admin_username
     where "Id" = p_id;
  elsif p_action = 'skip' then
    if v_status not in ('Pending', 'Failed') then
      raise exception 'Only a Pending or Failed announcement can be skipped (this one is %).', v_status;
    end if;
    update public."NewArrivalPosts"
       set "Status" = 'Skipped', "Error" = 'Skipped by ' || p_admin_username || '.', "UpdatedBy" = p_admin_username
     where "Id" = p_id;
  else
    raise exception 'Unknown action %.', p_action;
  end if;
end;
$$;

grant execute on function public.admin_get_new_arrival_settings(text, text) to anon, authenticated;
grant execute on function public.admin_save_new_arrival_settings(text, text, boolean, text[], integer) to anon, authenticated;
grant execute on function public.admin_set_new_arrival_banner(text, text, text) to anon, authenticated;
grant execute on function public.admin_create_new_arrivals_banner_upload(text, text) to anon, authenticated;
grant execute on function public.admin_list_new_arrival_posts(text, text, integer) to anon, authenticated;
grant execute on function public.admin_set_new_arrival_post_status(text, text, bigint, text) to anon, authenticated;

-- ============================================================================
-- 6. Public - website "New Arrivals" section + Alice's list_new_arrivals tool
-- ============================================================================
-- Items in an announced category received at a store (Amaya / GMA) in the last N days
-- (NewArrivalSettings."WebsiteDays" when p_days is null), newest first, one row per item per
-- branch. NO prices (per request). Not filtered by ledger stock: fish were sold before receipts were
-- posted, so store fish balances are negative and would hide real arrivals.

drop function if exists public.public_get_new_arrivals(integer);

create or replace function public.public_get_new_arrivals(p_days integer default null)
returns table(code text, name text, images text, category_code text, branch text, arrived_on date)
language sql
stable
security definer
set search_path = public, extensions
as $$
  with s as (
    select "Enabled", "CategoryCodes", coalesce(p_days, "WebsiteDays", 7) as days
    from public."NewArrivalSettings" where "Id" = 1
  ),
  arr as (
    select i."Code"::text as code,
           coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), i."Code")::text as name,
           i."Images"::text as images,
           i."CategoryCode"::text as category_code,
           case when h."To Warehouse" ilike '%amaya%' then 'Amaya' when h."To Warehouse" ilike '%gma%' then 'GMA' end as branch,
           coalesce(h."Receive Date", h."Posted Date"::date) as arrived_on
    from public."Posted_Transfer_Line" l
    join public."Posted_Transfer_Header" h on h."No." = l."Document No."
    join public."Items" i on i."Code" = l."Item No."
    cross join s
    where s."Enabled"
      and coalesce(l."Qty Received", 0) > 0
      and coalesce(i."IsActive", true)
      and upper(trim(coalesce(i."CategoryCode", ''))) in (select upper(trim(x)) from unnest(s."CategoryCodes") x)
      and coalesce(h."Receive Date", h."Posted Date"::date) >= current_date - least(greatest(s.days, 1), 60)
  )
  select code, name, max(images), max(category_code), branch, max(arrived_on)
  from arr
  where branch is not null
  group by code, name, branch
  order by max(arrived_on) desc, name
  limit 60;
$$;

grant execute on function public.public_get_new_arrivals(integer) to anon, authenticated;
