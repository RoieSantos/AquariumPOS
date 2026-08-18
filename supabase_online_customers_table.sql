-- Supabase/Postgres mirror of Pancake customer records (GET /shops/{ShopId}/customers),
-- including "FbID" (Facebook PSID).
--
-- Populated from TWO independent sources (either one alone keeps it fresh - see
-- OnlineOrders' own header comment in supabase_orders_sync_tables.sql for why this
-- redundant-by-design pattern is used elsewhere in this codebase too):
--   1. Direct Pancake -> Supabase, via pg_cron every 5 minutes, regardless of whether the
--      desktop POS app is even open - see cron_sync_online_customers_from_pancake() below.
--      This is the primary path.
--   2. The desktop app's own push, also every 5 minutes but only while it's running -
--      OnlinefunctionsEvents.SyncCustomersAsync() pulls from Pancake into local
--      dbo.OnlineCustomers, then SyncCustomersToSupabaseAsync() pushes that up to this
--      table (exists-check-then-POST/PATCH by "Id"). Kept as a backstop, same reasoning
--      as cron_sync_items_from_pancake alongside the desktop's masterDataSyncTimer.
--
-- Purpose: "FbID" is the customer's Facebook PSID. The order-now.html wizard can arrive with a
-- ?psid= query param when the customer opens it via a Messenger button Pancake personalized with
-- their PSID (see docs/js/orderNow.js's captureMessengerPsid()) - this table is what lets that
-- captured PSID be matched back to a real Pancake customer (name/phone/email/order history)
-- later, e.g. `select * from public."OnlineCustomers" where "FbID" = '<captured psid>'`.
--
-- Only a lean, directly-useful subset of dbo.OnlineCustomers' columns is synced here (not the
-- *Json blobs or RawJson that table also carries) - this is meant for PSID lookups, not as a full
-- customer master mirror.
--
-- SECURITY NOTE: carries customer PII (name, phone, email, PSID) - NOT opened up to the "anon"
-- role via RLS policies (this portal has no real Supabase Auth session for auth.uid()-based
-- policies to key off - staff "login" is a re-verified username/password pair, not a JWT). The
-- desktop app authenticates its Supabase REST calls with the SECRET/service-role key, which
-- bypasses Row Level Security entirely, so no anon/authenticated table policies are required for
-- the sync to work. Staff reads happen only through admin_list_online_customers() below, which
-- re-verifies the caller via public.is_staff_authorized() on every call (same trust model as
-- admin_list_online_orders in supabase_orders_sync_tables.sql) - that's this table's equivalent
-- of a "policy".

create table if not exists public."OnlineCustomers" (
    "Id" varchar(100) primary key,
    "CustomerID" varchar(100),
    "ShopID" varchar(100),
    "Name" varchar(255),
    "FbID" varchar(255),
    "PrimaryEmail" varchar(255),
    "PrimaryPhoneNumber" varchar(100),
    "PrimaryAddress" varchar(1000),
    "ConversationLink" varchar(1000),
    "OrderCount" int,
    "PurchasedAmount" numeric(18, 2),
    "LastOrderAt" timestamptz,
    "UpdatedAt" timestamptz,
    "InsertedAt" timestamptz,
    "SyncedAtUtc" timestamptz
);

create index if not exists idx_online_customers_fbid on public."OnlineCustomers" ("FbID");

alter table public."OnlineCustomers" enable row level security;

-- Staff-facing read access - lets the portal look up which Pancake customer a captured PSID
-- (from order-now.html's ?psid= link, or a general name/phone/email search) belongs to. Any
-- active staff login can call this (read-only, same access level as admin_list_online_orders) -
-- pass p_psid for an exact PSID match, p_search for a name/phone/email substring match, or both.
create or replace function public.admin_list_online_customers(
  p_admin_username text, p_admin_password text,
  p_search text default null,
  p_psid text default null,
  p_page int default 1, p_page_size int default 50
)
returns table(
  id text,
  customer_id text,
  shop_id text,
  name text,
  fb_id text,
  primary_email text,
  primary_phone_number text,
  primary_address text,
  conversation_link text,
  order_count int,
  purchased_amount numeric,
  last_order_at timestamptz,
  updated_at timestamptz,
  inserted_at timestamptz,
  synced_at_utc timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
  select
    c."Id", c."CustomerID", c."ShopID", c."Name", c."FbID",
    c."PrimaryEmail", c."PrimaryPhoneNumber", c."PrimaryAddress", c."ConversationLink",
    c."OrderCount", c."PurchasedAmount", c."LastOrderAt", c."UpdatedAt", c."InsertedAt", c."SyncedAtUtc",
    count(*) over() as total_count
  from public."OnlineCustomers" c
  where (p_psid is null or p_psid = '' or c."FbID" = p_psid)
    and (
      p_search is null or p_search = ''
      or c."Name" ilike '%' || p_search || '%'
      or c."PrimaryPhoneNumber" ilike '%' || p_search || '%'
      or c."PrimaryEmail" ilike '%' || p_search || '%'
    )
  order by c."UpdatedAt" desc nulls last
  limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

-- Direct table access stays fully blocked by RLS (no policies) - only the desktop app's
-- service-role key (writes) and the re-verifying function above (reads) can reach this table.
revoke all on public."OnlineCustomers" from anon, authenticated;

grant execute on function public.admin_list_online_customers(text, text, text, text, int, int) to anon;

-- Public (anon, no login) PSID-only lookup - lets order-now.html auto-fill Step 4's
-- name/phone/email fields for a customer who arrived via a Messenger-personalized link, instead
-- of making them retype details Pancake already has on file (see js/orderNow.js's
-- prefillCustomerDetailsFromPsid()). Deliberately narrower than admin_list_online_customers: no
-- staff auth (this page has none to check), so it returns ONLY name/phone/email - never
-- CustomerID/order history/purchased amount/address - and only for an EXACT PSID match (no
-- search-by-name/phone, which would let anon browse the customer list).
--
-- SECURITY NOTE: this trusts whatever psid value the caller passes, same as every other place in
-- this feature already treats a customer's own PSID as their identifier (it's handed to them
-- by Pancake, embedded in a link only they receive) - a real Facebook PSID is a long
-- platform-assigned number, not something practical to guess/enumerate. Kept to name/phone/email
-- only so even a guessed PSID exposes the least useful set of PII possible.
drop function if exists public.public_lookup_customer_by_psid(text);

create or replace function public.public_lookup_customer_by_psid(p_psid text)
returns table(name text, phone text, email text)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select c."Name"::text, c."PrimaryPhoneNumber"::text, c."PrimaryEmail"::text
  from public."OnlineCustomers" c
  where p_psid is not null and trim(p_psid) <> ''
    and (c."FbID" = p_psid or c."FbID" = '195716644410829_' || p_psid)
  order by c."SyncedAtUtc" desc nulls last
  limit 1;
$$;

grant execute on function public.public_lookup_customer_by_psid(text) to anon;

-- ============================================================================
-- Cron sync, direct Pancake -> Supabase, independent of the desktop POS app -
-- per "should customer/PSID syncing happen entirely on the Supabase side,
-- independent of whether the desktop POS app is even open" -> yes. Talks to
-- Pancake directly from Postgres via the `http` extension, same "channel 3"
-- pattern already used for Warehouses/Items/Online Orders in
-- supabase_pancake_manual_sync.sql (see cron_sync_items_from_pancake there for
-- the near-identical sibling this was modeled on) - this file just adds the
-- Customers equivalent so it doesn't depend on that file's load order.
--
-- Relies on public.pancake_try_parse_timestamptz() and public.pancake_parse_decimal()
-- (defined in supabase_pancake_manual_sync.sql) already existing - run that file
-- first if this is a brand new project.
--
-- Stops paging on the first empty page (not "page shorter than requested page_size")
-- since Pancake's /products endpoint is known to silently cap page size regardless of
-- what's requested (see cron_sync_items_from_pancake's comment) - assume the same
-- could be true here and use the one signal that's reliable either way.
create extension if not exists http with schema extensions;

drop function if exists public.cron_sync_online_customers_from_pancake(int, int);

create or replace function public.cron_sync_online_customers_from_pancake(p_max_pages int default 200, p_page_size int default 200)
returns table(customers_synced int, customers_inserted int, customers_updated int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_page_size int := least(greatest(coalesce(p_page_size, 200), 1), 1000);
  v_max_pages int := least(greatest(coalesce(p_max_pages, 200), 1), 500);
  v_page int;
  v_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_page_items jsonb;
  v_item jsonb;
  v_id text;
  v_was_existing boolean;
  v_synced int := 0;
  v_inserted int := 0;
  v_updated int := 0;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');

  v_page := 1;
  while v_page <= v_max_pages loop
    v_url := v_base_url || '/shops/' || v_shop_id || '/customers?api_key=' || v_api_key
      || '&page_size=' || v_page_size || '&page=' || v_page;

    v_response := extensions.http_get(v_url);
    if v_response.status < 200 or v_response.status >= 300 then
      if v_page = 1 then
        raise exception 'Pancake customers request failed (HTTP %).', v_response.status;
      end if;
      exit;
    end if;

    v_body := v_response.content::jsonb;
    v_page_items := case
      when jsonb_typeof(v_body) = 'array' then v_body
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'data') = 'array' then v_body -> 'data'
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'customers') = 'array' then v_body -> 'customers'
      else '[]'::jsonb
    end;

    exit when jsonb_typeof(v_page_items) <> 'array' or jsonb_array_length(v_page_items) = 0;

    for v_item in select * from jsonb_array_elements(v_page_items)
    loop
      v_id := coalesce(nullif(v_item ->> 'id', ''), nullif(v_item ->> 'customer_id', ''));
      if v_id is null then
        continue;
      end if;

      select exists(select 1 from public."OnlineCustomers" where "Id" = v_id) into v_was_existing;

      insert into public."OnlineCustomers" (
        "Id", "CustomerID", "ShopID", "Name", "FbID",
        "PrimaryEmail", "PrimaryPhoneNumber", "PrimaryAddress", "ConversationLink",
        "OrderCount", "PurchasedAmount", "LastOrderAt", "UpdatedAt", "InsertedAt", "SyncedAtUtc"
      )
      values (
        v_id,
        nullif(v_item ->> 'customer_id', ''),
        nullif(v_item ->> 'shop_id', ''),
        nullif(v_item ->> 'name', ''),
        nullif(v_item ->> 'fb_id', ''),
        nullif(v_item -> 'emails' ->> 0, ''),
        nullif(v_item -> 'phone_numbers' ->> 0, ''),
        nullif(v_item -> 'shop_customer_address' -> 0 ->> 'full_address', ''),
        nullif(v_item ->> 'conversation_link', ''),
        public.pancake_parse_decimal(v_item ->> 'order_count')::int,
        public.pancake_parse_decimal(v_item ->> 'purchased_amount'),
        public.pancake_try_parse_timestamptz(v_item ->> 'last_order_at'),
        public.pancake_try_parse_timestamptz(v_item ->> 'updated_at'),
        public.pancake_try_parse_timestamptz(v_item ->> 'inserted_at'),
        now()
      )
      on conflict ("Id") do update
        set "CustomerID" = excluded."CustomerID",
            "ShopID" = excluded."ShopID",
            "Name" = excluded."Name",
            "FbID" = excluded."FbID",
            "PrimaryEmail" = excluded."PrimaryEmail",
            "PrimaryPhoneNumber" = excluded."PrimaryPhoneNumber",
            "PrimaryAddress" = excluded."PrimaryAddress",
            "ConversationLink" = excluded."ConversationLink",
            "OrderCount" = excluded."OrderCount",
            "PurchasedAmount" = excluded."PurchasedAmount",
            "LastOrderAt" = excluded."LastOrderAt",
            "UpdatedAt" = excluded."UpdatedAt",
            "InsertedAt" = excluded."InsertedAt",
            "SyncedAtUtc" = now();

      v_synced := v_synced + 1;
      if v_was_existing then
        v_updated := v_updated + 1;
      else
        v_inserted := v_inserted + 1;
      end if;
    end loop;

    exit when jsonb_array_length(v_page_items) = 0;
    v_page := v_page + 1;
  end loop;

  return query select v_synced, v_inserted, v_updated;
end;
$$;

-- No grant to anon - called directly by pg_cron inside Postgres, never through PostgREST
-- (same as cron_sync_items_from_pancake/cron_sync_online_orders_from_pancake).

do $$
begin
  perform cron.unschedule('sync-online-customers-from-pancake');
exception when others then
  null; -- job didn't exist yet - nothing to unschedule
end;
$$;

select cron.schedule(
  'sync-online-customers-from-pancake',
  '*/5 * * * *',
  $$select public.cron_sync_online_customers_from_pancake();$$
);
