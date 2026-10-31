-- Price Increase page (price-increase.html), per "can we build a new feature that can cover this?" - the
-- +x% price increase plan (supabase_check_price_increase_2_5.sql / supabase_check_wholesale_price_increase_2_5.sql)
-- as a portal feature instead of read-only SQL: pick the %, review every item, override / exclude, save as a
-- draft, apply now or SCHEDULE it ("i was thinking we can schedule the price increase"), and undo if needed.
--
--   PriceChangeBatches / PriceChangeBatchLines - one batch per planned price change
--                                       (Draft -> Scheduled -> Applied -> Undone). Lines hold the old and new
--                                       price per item / variant, so Apply and Undo are exact and the batch is
--                                       the history of who changed what.
--   admin_price_change_source_rows     - the data the page prices from: retail, cost, wholesale, sales.
--                                       The % / rounding / wholesale rule is computed on the page (js/priceIncrease.js)
--                                       so the knobs update instantly; Apply only takes the saved numbers.
--   admin_price_change_list / _get / _save / _delete / _schedule / _apply / _undo
--   cron_apply_scheduled_price_changes - pg_cron job apply-scheduled-price-changes, every 5 minutes: applies
--                                       each Scheduled batch whose time has come.
--
-- What Apply writes (the same tables Item Setup's price edit writes - admin_set_item_price / admin_set_variant_price):
--   item line    - Items."Price" + its single variant's Variants."Price"
--   variant line - Variants."Price" (+ Items."Price" when it is the item's representative variant)
--   both         - Items."RetailPrice" cleared to NULL. It is a leftover from the desktop POS push (which no
--                  longer runs), and Order Now / Alice / the price list quote coalesce(RetailPrice, Price), so a
--                  stale RetailPrice would keep quoting the OLD price after the increase. The old value is kept
--                  on the line and Undo puts it back.
--   wholesale    - Items."WholesalePrice"
-- The store POS pulls Price from here (pos_list_items_master / pos_list_variants_master) and WholesalePrice
-- (SyncItemWholesalePricesFromSupabaseAsync) on its next sync tick - nothing is pushed to Pancake.
--
-- Safety: a line whose item's current price is no longer the "old" price saved on the draft (someone edited it
-- in Item Setup since) is never overwritten.
--   Apply Now  - refuses the whole batch and names the items; re-opening the draft reloads today's prices.
--   Scheduled  - nobody is there to fix it, so it applies every other line and marks those lines Skipped
--                (shown on the batch). If the scheduled apply fails outright, the batch goes back to Draft with
--                the error on it, so it never retries a broken batch every 5 minutes.
-- Undo only restores lines still at the batch's new price, so it never overwrites a later edit (reported as
-- skipped). Refused while Pancake still syncs products (_items_pancake_sync_active) - the next sync would undo it.
--
-- Aquarium SETS (category SET) are never included as ITEM lines: their price is the Package Price on the
-- Customer Aquarium page (the Items row is a trigger-maintained copy, and the POS sells at PackagePrice). Old
-- set item lines on a draft are refused by Apply Now / skipped by a schedule; re-opening the draft drops them.
-- Instead (per "in the price increase will the set package price be updated too?" - "can you also increase
-- it?") each package rides on the batch as its own 'set' line:
--   set line      - CompleteAquariumSetHeader."PackagePrice" (ItemCode = the package's "SetCode"). Its
--                   TR_CompleteAquariumSetHeader_SyncItem trigger copies the new price to the set's Items row,
--                   so Order Now, Alice, the website and the POS all sell at the new Package Price. The parts
--                   lines (CompleteAquariumSetLine."Price") are left as they are - they're only a breakdown.
--
-- CALCULATOR rates ride on it too (per "price mismatch" between a ready-made aquarium and the calculator, so
-- both go up together):
--   glass line    - GlassPricingSetup."PricePerSqFt" (ItemCode = "Id")
--   tubular line  - TubularPricingSetup."PricePerFt" (ItemCode = "Id")
--   extra line    - AquariumExtraPricingSetup."Price" (ItemCode = "FeatureKey"). Only peso amounts: waste %,
--                   markups (multipliers) and 'Piping Separate Drain' (it reads item A-070's price) are never
--                   listed. The calculators' flat prices that used to be hardcoded (small 6mm glass rate, 12mm
--                   surcharges, filter media, overflow box, piping sets, high strip, aquascape) are seeded
--                   below at today's values, so seeding them changes no quote.
--
-- Sticker & delivery RATES ride on the same batch (per "is the price increase also include custom stickers?
-- deliver quote?" - "yes please add that too"), so one increase / schedule / undo covers them:
--   sticker line  - StickerPricingSetup."PricePerSqFt" (ItemCode = the row's "Id"). The 'Acrylic Sump Cover'
--                   row is a markup multiplier on Acrylic, not pesos, so it is never listed (it already follows
--                   Acrylic's new rate).
--   delivery line - PortalSettings DELIVERY_BASE_FEE / DELIVERY_RATE_PER_KM / DELIVERY_TOLL_FEE (ItemCode = the
--                   setting key). DELIVERY_MULTI_STOP_MARKUP_PERCENT is a % and is never listed.
-- Order Now, Alice (chatbot-engine.ts) and the Delivery Quote page read both live, so they quote the new
-- rates right away. Same safety rules as items: a rate edited since the draft is refused / skipped, and Undo
-- only restores a rate still at the batch's new value.
--
-- Super users only (is_admin_authorized), like Item Setup's price edit.
-- Run AFTER supabase_item_master_portal_owned.sql. Safe to re-run (re-creates the cron job).

-- ---------------------------------------------------------------------------
-- Flat calculator prices (today's values; existing rows are never overwritten)
-- ---------------------------------------------------------------------------

insert into public."AquariumExtraPricingSetup" ("FeatureKey", "Price")
values
  ('Small 6mm Glass per sq ft', 117.00),
  ('12mm Surcharge 170+ gal per sq ft', 110.00),
  ('12mm Surcharge 300+ gal per sq ft', 145.00),
  ('High Strip per ft', 90.00),
  ('Filter Media per kg', 300.00),
  ('Overflow Box', 1900.00),
  ('Overhead Piping Set', 540.00),
  ('Undersump Piping Set', 2500.00),
  ('Aquascape per gallon', 210.00)
on conflict ("FeatureKey") do nothing;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table if not exists public."PriceChangeBatches" (
  "BatchId" bigint generated always as identity primary key,
  "Description" text,
  "IncreasePct" numeric(9, 4),
  "KeepDiscount" numeric(9, 4),
  "Status" text not null default 'Draft',
  "CreatedBy" text,
  "CreatedAtUtc" timestamptz not null default now(),
  "UpdatedBy" text,
  "UpdatedAtUtc" timestamptz,
  "AppliedBy" text,
  "AppliedAtUtc" timestamptz,
  "UndoneBy" text,
  "UndoneAtUtc" timestamptz,
  "UndoSkipped" int
);

alter table public."PriceChangeBatches" add column if not exists "ScheduledForUtc" timestamptz;
alter table public."PriceChangeBatches" add column if not exists "ScheduledBy" text;
alter table public."PriceChangeBatches" add column if not exists "ApplyError" text;
alter table public."PriceChangeBatches" add column if not exists "ApplyErrorAtUtc" timestamptz;

alter table public."PriceChangeBatches" drop constraint if exists "PriceChangeBatches_Status_check";
alter table public."PriceChangeBatches" drop constraint if exists "CK_PriceChangeBatches_Status";
alter table public."PriceChangeBatches" add constraint "CK_PriceChangeBatches_Status"
  check ("Status" in ('Draft', 'Scheduled', 'Applied', 'Undone'));

create index if not exists "IX_PriceChangeBatches_Scheduled" on public."PriceChangeBatches" ("ScheduledForUtc")
  where "Status" = 'Scheduled';

create table if not exists public."PriceChangeBatchLines" (
  "BatchId" bigint not null references public."PriceChangeBatches"("BatchId") on delete cascade,
  "LineNo" int not null,
  "Kind" text not null check ("Kind" in ('item', 'variant')),
  "ItemCode" text not null,
  "VariationId" text,
  "Name" text,
  "OldPrice" numeric(18, 4),
  "NewPrice" numeric(18, 4),          -- null = retail not changed on this line
  "OldWholesalePrice" numeric(18, 4),
  "NewWholesalePrice" numeric(18, 4), -- null = wholesale not changed on this line
  "OldRetailPrice" numeric(18, 4),    -- Items."RetailPrice" captured at Apply (cleared), restored by Undo
  "RetailPriceCleared" boolean not null default false,
  constraint "PK_PriceChangeBatchLines" primary key ("BatchId", "LineNo")
);

-- Set by a scheduled apply for a line it left alone (price edited since the draft was saved / item gone).
alter table public."PriceChangeBatchLines" add column if not exists "Skipped" boolean not null default false;
alter table public."PriceChangeBatchLines" add column if not exists "SkipReason" text;

alter table public."PriceChangeBatchLines" drop constraint if exists "PriceChangeBatchLines_Kind_check";
alter table public."PriceChangeBatchLines" drop constraint if exists "CK_PriceChangeBatchLines_Kind";
alter table public."PriceChangeBatchLines" add constraint "CK_PriceChangeBatchLines_Kind"
  check ("Kind" in ('item', 'variant', 'sticker', 'delivery', 'set', 'glass', 'tubular', 'extra'));

create index if not exists "IX_PriceChangeBatchLines_Item" on public."PriceChangeBatchLines" ("ItemCode");

alter table public."PriceChangeBatches" enable row level security;
alter table public."PriceChangeBatchLines" enable row level security;

-- ---------------------------------------------------------------------------
-- Source rows for the page
-- ---------------------------------------------------------------------------
-- One 'item' row per active (or sold in the last 365 days) item with at most one variant, and one 'variant'
-- row per variant of items with several variants (each has its own price). A multi-variant item that has a
-- wholesale price also gets an 'item' row with price null, so its wholesale price can be raised too.
-- Sales come from Online Orders (online + walk-ins), cancelled excluded - same source as the SQL checks.
-- ws_* = ESTIMATED wholesale sales: a line counts as wholesale when its unit price was at or below the item's
-- current WholesalePrice (order lines have no wholesale flag).

drop function if exists public.admin_price_change_source_rows(text, text);

create or replace function public.admin_price_change_source_rows(p_admin_username text, p_admin_password text)
returns table(
  kind text, item_code text, variation_id text, name text, category text, is_active boolean,
  is_custom boolean, wholesale_applicable boolean, variant_count int,
  price numeric, retail_price numeric, cost numeric, wholesale_price numeric,
  qty_90d numeric, revenue_90d numeric, qty_365d numeric, revenue_365d numeric,
  ws_qty_90d numeric, ws_revenue_90d numeric
)
language plpgsql
stable
security definer
set search_path = public, extensions
set statement_timeout = '30000'
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
  with lines as (
    select l."ItemCode" as code, nullif(trim(l."VariationId"), '') as vid, l."Quantity" as qty,
           l."GrossAmount" as gross, l."Price" as unit_price, o."Date" as d
      from public."OnlineOrderLines" l
      join public."OnlineOrders" o on o."OrderID" = l."OrderID"
     where l."ItemCode" is not null
       and o."Date" >= current_date - 365
       and lower(trim(coalesce(o."Status", ''))) not in ('cancelled', 'canceled', 'cancel')
  ),
  item_sales as (
    select code,
           sum(qty) filter (where d >= current_date - 90) as q90, sum(gross) filter (where d >= current_date - 90) as r90,
           sum(qty) as q365, sum(gross) as r365
      from lines group by code
  ),
  variant_sales as (
    select vid,
           sum(qty) filter (where d >= current_date - 90) as q90, sum(gross) filter (where d >= current_date - 90) as r90,
           sum(qty) as q365, sum(gross) as r365
      from lines where vid is not null group by vid
  ),
  ws_sales as (
    select ln.code,
           sum(ln.qty) filter (where ln.d >= current_date - 90) as q90,
           sum(ln.gross) filter (where ln.d >= current_date - 90) as r90
      from lines ln
      join public."Items" i on i."Code" = ln.code
     where i."WholesalePrice" > 0 and ln.qty > 0 and coalesce(ln.unit_price, 0) > 0
       and ln.unit_price <= i."WholesalePrice"
     group by ln.code
  ),
  vcount as (
    select "MainItemCode" as code, count(*)::int as n from public."Variants" group by "MainItemCode"
  ),
  items as (
    select i.*, coalesce(vc.n, 0) as n_variants,
           coalesce(c."IsWholesaleApplicable", false) as ws_ok,
           (i."Code" ilike 'CUSTOM%' or i."Name" ilike 'CUSTOM%' or i."CategoryCode" ilike 'CUSTOM%') as custom
      from public."Items" i
      left join vcount vc on vc.code = i."Code"
      left join public."Categories" c on c."Code" = i."CategoryCode"
     where (coalesce(i."IsActive", false)
            or exists (select 1 from item_sales s where s.code = i."Code"))
       -- Aquarium SETS are priced on the Customer Aquarium page (PackagePrice); their Items row is a copy the
       -- package trigger overwrites and the POS sells at PackagePrice - never raise them here.
       and upper(trim(coalesce(i."CategoryCode", ''))) <> 'SET'
  )
  select 'item'::text, it."Code"::text, null::text, it."Name"::text, it."CategoryCode"::text,
         coalesce(it."IsActive", false), it.custom, it.ws_ok, it.n_variants,
         case when it.n_variants <= 1 then round(coalesce(it."Price", 0), 2) end,
         round(it."RetailPrice", 2), round(it."Cost", 2), round(it."WholesalePrice", 2),
         coalesce(s.q90, 0), coalesce(s.r90, 0), coalesce(s.q365, 0), coalesce(s.r365, 0),
         coalesce(w.q90, 0), coalesce(w.r90, 0)
    from items it
    left join item_sales s on s.code = it."Code"
    left join ws_sales w on w.code = it."Code"
   where it.n_variants <= 1 or it."WholesalePrice" > 0
  union all
  select 'variant'::text, it."Code"::text, v."VariationId"::text,
         (it."Name" || ' - ' || coalesce(nullif(trim(v."VariantName"), ''), v."VariationId"))::text,
         it."CategoryCode"::text, coalesce(it."IsActive", false), it.custom, it.ws_ok, it.n_variants,
         round(coalesce(v."Price", 0), 2),
         case when v."VariationId" = it."VariationId" then round(it."RetailPrice", 2) end,
         round(it."Cost", 2), null::numeric,
         coalesce(vs.q90, 0), coalesce(vs.r90, 0), coalesce(vs.q365, 0), coalesce(vs.r365, 0),
         0::numeric, 0::numeric
    from items it
    join public."Variants" v on v."MainItemCode" = it."Code"
    left join variant_sales vs on vs.vid = v."VariationId"
   where it.n_variants > 1;
end;
$$;

grant execute on function public.admin_price_change_source_rows(text, text) to anon;

-- Sticker & delivery rates and aquarium set Package Prices the page can raise with the same %. A delivery
-- setting that isn't a plain number comes back with price null (shown, never changed). note = the set's
-- SetCode (+ "not sold online"), shown under its name.
drop function if exists public.admin_price_change_rate_rows(text, text);

create or replace function public.admin_price_change_rate_rows(p_admin_username text, p_admin_password text)
returns table(kind text, item_code text, name text, price numeric, note text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
  select 'sticker'::text, s."Id"::text,
         (s."StickerType" || coalesce(' ' || nullif(trim(s."Thickness"), '') || 'mm', ''))::text,
         round(s."PricePerSqFt", 2), null::text
    from public."StickerPricingSetup" s
   where s."StickerType" <> 'Acrylic Sump Cover'
  union all
  select 'delivery'::text, k.key,
         k.label,
         case when trim(coalesce(p."SettingValue", '')) ~ '^[0-9]+(\.[0-9]+)?$' then round(trim(p."SettingValue")::numeric, 2) end,
         null::text
    from (values ('DELIVERY_BASE_FEE', 'Delivery base fee', 1),
                 ('DELIVERY_RATE_PER_KM', 'Delivery rate per km', 2),
                 ('DELIVERY_TOLL_FEE', 'Delivery toll fee (when Google has no toll price)', 3)) as k(key, label, ord)
    join public."PortalSettings" p on p."SettingKey" = k.key
  union all
  select 'set'::text, trim(h."SetCode")::text, h."PackageName"::text, round(h."PackagePrice", 2),
         (trim(h."SetCode") || case when h."SellOnline" then '' else ' · not sold online' end)::text
    from public."CompleteAquariumSetHeader" h
   where nullif(trim(h."SetCode"), '') is not null
  union all
  select 'glass'::text, g."Id"::text, (g."Thickness" || lower(g."Uom") || ' glass')::text, round(g."PricePerSqFt", 2),
         'Per sq ft - glass (Pricing Setup). Repairs and the sticker Glass type use it too.'::text
    from public."GlassPricingSetup" g
  union all
  select 'tubular'::text, t."Id"::text, (t."TubularSize" || ' tubular')::text, round(t."PricePerFt", 2),
         'Per ft - stand frame (Pricing Setup)'::text
    from public."TubularPricingSetup" t
  union all
  select 'extra'::text, x."FeatureKey"::text, x."FeatureKey"::text, round(x."Price", 2),
         'Aquarium extra (Pricing Setup)'::text
    from public."AquariumExtraPricingSetup" x
   where x."FeatureKey" <> 'Piping Separate Drain'
     and x."FeatureKey" not ilike '%markup%'
     and x."FeatureKey" not like '%\%%';
end;
$$;

grant execute on function public.admin_price_change_rate_rows(text, text) to anon;

-- ---------------------------------------------------------------------------
-- Batches: list / get / save / delete / schedule
-- ---------------------------------------------------------------------------

drop function if exists public.admin_price_change_list(text, text);

create or replace function public.admin_price_change_list(p_admin_username text, p_admin_password text)
returns table(
  batch_id bigint, description text, increase_pct numeric, keep_discount numeric, status text,
  line_count int, retail_lines int, wholesale_lines int, rate_lines int, set_lines int, calc_lines int, skipped_lines int,
  created_by text, created_at_utc timestamptz, updated_by text, updated_at_utc timestamptz,
  scheduled_for_utc timestamptz, scheduled_by text, apply_error text, apply_error_at_utc timestamptz,
  applied_by text, applied_at_utc timestamptz, undone_by text, undone_at_utc timestamptz, undo_skipped int
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
  select b."BatchId", b."Description", b."IncreasePct", b."KeepDiscount", b."Status",
         count(l."LineNo")::int,
         count(l."LineNo") filter (where l."NewPrice" is not null and l."Kind" in ('item', 'variant'))::int,
         count(l."LineNo") filter (where l."NewWholesalePrice" is not null)::int,
         count(l."LineNo") filter (where l."Kind" in ('sticker', 'delivery'))::int,
         count(l."LineNo") filter (where l."Kind" = 'set')::int,
         count(l."LineNo") filter (where l."Kind" in ('glass', 'tubular', 'extra'))::int,
         count(l."LineNo") filter (where l."Skipped")::int,
         b."CreatedBy", b."CreatedAtUtc", b."UpdatedBy", b."UpdatedAtUtc",
         b."ScheduledForUtc", b."ScheduledBy", b."ApplyError", b."ApplyErrorAtUtc",
         b."AppliedBy", b."AppliedAtUtc", b."UndoneBy", b."UndoneAtUtc", b."UndoSkipped"
    from public."PriceChangeBatches" b
    left join public."PriceChangeBatchLines" l on l."BatchId" = b."BatchId"
   group by b."BatchId"
   order by b."BatchId" desc;
end;
$$;

grant execute on function public.admin_price_change_list(text, text) to anon;

drop function if exists public.admin_price_change_get(text, text, bigint);

create or replace function public.admin_price_change_get(p_admin_username text, p_admin_password text, p_batch_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_batch public."PriceChangeBatches"%rowtype;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select * into v_batch from public."PriceChangeBatches" where "BatchId" = p_batch_id;
  if not found then
    raise exception 'Price change #% not found.', p_batch_id;
  end if;

  return jsonb_build_object(
    'batch_id', v_batch."BatchId",
    'description', v_batch."Description",
    'increase_pct', v_batch."IncreasePct",
    'keep_discount', v_batch."KeepDiscount",
    'status', v_batch."Status",
    'scheduled_for_utc', v_batch."ScheduledForUtc",
    'apply_error', v_batch."ApplyError",
    'applied_by', v_batch."AppliedBy",
    'applied_at_utc', v_batch."AppliedAtUtc",
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
               'kind', l."Kind", 'item_code', l."ItemCode", 'variation_id', l."VariationId", 'name', l."Name",
               'old_price', l."OldPrice", 'new_price', l."NewPrice",
               'old_wholesale_price', l."OldWholesalePrice", 'new_wholesale_price', l."NewWholesalePrice",
               'old_retail_price', l."OldRetailPrice", 'retail_price_cleared', l."RetailPriceCleared",
               'skipped', l."Skipped", 'skip_reason', l."SkipReason"
             ) order by l."LineNo")
        from public."PriceChangeBatchLines" l where l."BatchId" = p_batch_id
    ), '[]'::jsonb)
  );
end;
$$;

grant execute on function public.admin_price_change_get(text, text, bigint) to anon;

-- Creates (p_batch_id null) or replaces a Draft / Scheduled batch (a Scheduled one keeps its date).
-- p_lines: [{kind, item_code, variation_id, name, old_price, new_price, old_wholesale_price,
-- new_wholesale_price}] - only lines that actually change something.
drop function if exists public.admin_price_change_save(text, text, bigint, text, numeric, numeric, jsonb);

create or replace function public.admin_price_change_save(
  p_admin_username text,
  p_admin_password text,
  p_batch_id bigint,
  p_description text,
  p_increase_pct numeric,
  p_keep_discount numeric,
  p_lines jsonb
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_batch_id bigint := p_batch_id;
  v_status text;
  v_bad text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Nothing to save - no item would change price.';
  end if;

  select string_agg(coalesce(e ->> 'item_code', '?'), ', ') into v_bad
    from jsonb_array_elements(p_lines) e
   where coalesce(e ->> 'kind', '') not in ('item', 'variant', 'sticker', 'delivery', 'set', 'glass', 'tubular', 'extra')
      or nullif(trim(coalesce(e ->> 'item_code', '')), '') is null
      or (e ->> 'kind' = 'variant' and nullif(trim(coalesce(e ->> 'variation_id', '')), '') is null)
      or ((e ->> 'new_price') is null and (e ->> 'new_wholesale_price') is null)
      or coalesce((e ->> 'new_price')::numeric, 0) < 0
      or coalesce((e ->> 'new_wholesale_price')::numeric, 0) < 0
      or (e ->> 'kind' in ('variant', 'sticker', 'delivery', 'set', 'glass', 'tubular', 'extra') and (e ->> 'new_wholesale_price') is not null)
      or (e ->> 'kind' in ('sticker', 'delivery', 'set', 'glass', 'tubular', 'extra') and ((e ->> 'new_price') is null or (e ->> 'old_price') is null))
      or (e ->> 'kind' in ('glass', 'tubular') and coalesce(e ->> 'item_code', '') !~ '^[0-9]+$')
      or (e ->> 'kind' = 'extra' and (e ->> 'item_code' = 'Piping Separate Drain'
          or e ->> 'item_code' ilike '%markup%' or e ->> 'item_code' like '%\%%'))
      or (e ->> 'kind' = 'delivery'
          and e ->> 'item_code' not in ('DELIVERY_BASE_FEE', 'DELIVERY_RATE_PER_KM', 'DELIVERY_TOLL_FEE'))
      or (e ->> 'kind' = 'sticker' and coalesce(e ->> 'item_code', '') !~ '^[0-9]+$');
  if v_bad is not null then
    raise exception 'Invalid lines: %', left(v_bad, 300);
  end if;

  if v_batch_id is null then
    insert into public."PriceChangeBatches" ("Description", "IncreasePct", "KeepDiscount", "CreatedBy")
    values (nullif(trim(coalesce(p_description, '')), ''), p_increase_pct, p_keep_discount, p_admin_username)
    returning "BatchId" into v_batch_id;
  else
    select "Status" into v_status from public."PriceChangeBatches" where "BatchId" = v_batch_id for update;
    if not found then
      raise exception 'Price change #% not found.', v_batch_id;
    end if;
    if v_status not in ('Draft', 'Scheduled') then
      raise exception 'Price change #% is % - only a Draft or Scheduled one can be edited.', v_batch_id, v_status;
    end if;
    update public."PriceChangeBatches"
       set "Description" = nullif(trim(coalesce(p_description, '')), ''),
           "IncreasePct" = p_increase_pct,
           "KeepDiscount" = p_keep_discount,
           "UpdatedBy" = p_admin_username,
           "UpdatedAtUtc" = now(),
           "ApplyError" = null,
           "ApplyErrorAtUtc" = null
     where "BatchId" = v_batch_id;
    delete from public."PriceChangeBatchLines" where "BatchId" = v_batch_id;
  end if;

  insert into public."PriceChangeBatchLines"
    ("BatchId", "LineNo", "Kind", "ItemCode", "VariationId", "Name",
     "OldPrice", "NewPrice", "OldWholesalePrice", "NewWholesalePrice")
  select v_batch_id, e.ord::int, e.it ->> 'kind', trim(e.it ->> 'item_code'),
         nullif(trim(coalesce(e.it ->> 'variation_id', '')), ''), e.it ->> 'name',
         round((e.it ->> 'old_price')::numeric, 2), round((e.it ->> 'new_price')::numeric, 2),
         round((e.it ->> 'old_wholesale_price')::numeric, 2), round((e.it ->> 'new_wholesale_price')::numeric, 2)
    from jsonb_array_elements(p_lines) with ordinality as e(it, ord);

  return v_batch_id;
end;
$$;

grant execute on function public.admin_price_change_save(text, text, bigint, text, numeric, numeric, jsonb) to anon;

drop function if exists public.admin_price_change_delete(text, text, bigint);

create or replace function public.admin_price_change_delete(p_admin_username text, p_admin_password text, p_batch_id bigint)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  delete from public."PriceChangeBatches" where "BatchId" = p_batch_id and "Status" in ('Draft', 'Scheduled');
  if not found then
    raise exception 'Only a Draft or Scheduled price change can be deleted - an applied one stays as history (use Undo instead).';
  end if;
end;
$$;

grant execute on function public.admin_price_change_delete(text, text, bigint) to anon;

-- Schedules a Draft (or moves a Scheduled one) to p_scheduled_for; null unschedules it back to Draft.
drop function if exists public.admin_price_change_schedule(text, text, bigint, timestamptz);

create or replace function public.admin_price_change_schedule(
  p_admin_username text,
  p_admin_password text,
  p_batch_id bigint,
  p_scheduled_for timestamptz
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_status text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select "Status" into v_status from public."PriceChangeBatches" where "BatchId" = p_batch_id for update;
  if not found then
    raise exception 'Price change #% not found.', p_batch_id;
  end if;
  if v_status not in ('Draft', 'Scheduled') then
    raise exception 'Price change #% is already % - it can no longer be scheduled.', p_batch_id, v_status;
  end if;

  if p_scheduled_for is null then
    update public."PriceChangeBatches"
       set "Status" = 'Draft', "ScheduledForUtc" = null, "ScheduledBy" = null
     where "BatchId" = p_batch_id;
    return;
  end if;

  if p_scheduled_for <= now() + interval '1 minute' then
    raise exception 'Pick a time in the future - or use Apply Now.';
  end if;

  update public."PriceChangeBatches"
     set "Status" = 'Scheduled', "ScheduledForUtc" = p_scheduled_for, "ScheduledBy" = p_admin_username,
         "ApplyError" = null, "ApplyErrorAtUtc" = null
   where "BatchId" = p_batch_id;
end;
$$;

grant execute on function public.admin_price_change_schedule(text, text, bigint, timestamptz) to anon;

-- ---------------------------------------------------------------------------
-- Apply (shared by Apply Now and the scheduled job) / Undo
-- ---------------------------------------------------------------------------
-- p_skip_changed false (Apply Now): any line whose price moved since the draft refuses the whole batch.
-- p_skip_changed true (scheduled): those lines are marked Skipped and everything else is applied.

drop function if exists public._price_change_apply(bigint, text, boolean);

create or replace function public._price_change_apply(p_batch_id bigint, p_actor text, p_skip_changed boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_status text;
  v_changed text;
  v_changed_count int;
  v_n int;
  v_retail int := 0;
  v_wholesale int := 0;
  v_cleared int := 0;
  v_skipped int := 0;
  v_rates int := 0;
  v_sets int := 0;
  v_calc int := 0;
begin
  if public._items_pancake_sync_active() then
    raise exception 'Products are still synced from Pancake - the next sync would undo the new prices. Finish the portal cutover first.';
  end if;

  select "Status" into v_status from public."PriceChangeBatches" where "BatchId" = p_batch_id for update;
  if not found then
    raise exception 'Price change #% not found.', p_batch_id;
  end if;
  if v_status not in ('Draft', 'Scheduled') then
    raise exception 'Price change #% is already %.', p_batch_id, v_status;
  end if;

  update public."PriceChangeBatchLines" set "Skipped" = false, "SkipReason" = null where "BatchId" = p_batch_id;

  -- Lines that can't be applied as planned: the item / variant is gone, or its price is no longer the old one.
  create temp table if not exists _pc_bad (line_no int, label text, reason text) on commit drop;
  truncate _pc_bad;

  insert into _pc_bad
  select l."LineNo", l."ItemCode" || coalesce(' / ' || l."VariationId", ''),
         case when i."Code" is null or (l."Kind" = 'variant' and v."VariationId" is null) then 'item no longer exists'
              when upper(trim(coalesce(i."CategoryCode", ''))) = 'SET' then 'aquarium set - change its Package Price on the Customer Aquarium page'
              else 'price edited since the draft was saved' end
    from public."PriceChangeBatchLines" l
    left join public."Items" i on i."Code" = l."ItemCode"
    left join public."Variants" v on v."VariationId" = l."VariationId"
   where l."BatchId" = p_batch_id and l."Kind" in ('item', 'variant')
     and (i."Code" is null
       or upper(trim(coalesce(i."CategoryCode", ''))) = 'SET'
       or (l."Kind" = 'variant' and v."VariationId" is null)
       or (l."NewPrice" is not null and l."Kind" = 'item'
           and round(coalesce(i."Price", 0), 2) is distinct from round(coalesce(l."OldPrice", 0), 2))
       or (l."NewPrice" is not null and l."Kind" = 'variant'
           and round(coalesce(v."Price", 0), 2) is distinct from round(coalesce(l."OldPrice", 0), 2))
       or (l."NewWholesalePrice" is not null
           and round(i."WholesalePrice", 2) is distinct from round(l."OldWholesalePrice", 2)));

  -- Sticker / delivery rates: gone, or no longer the old value.
  insert into _pc_bad
  select l."LineNo", coalesce(l."Name", l."ItemCode"),
         case when s."Id" is null and p."SettingKey" is null then 'rate no longer exists'
              else 'rate edited since the draft was saved' end
    from public."PriceChangeBatchLines" l
    left join public."StickerPricingSetup" s on l."Kind" = 'sticker' and s."Id"::text = l."ItemCode"
    left join public."PortalSettings" p on l."Kind" = 'delivery' and p."SettingKey" = l."ItemCode"
   where l."BatchId" = p_batch_id and l."Kind" in ('sticker', 'delivery')
     and ((s."Id" is null and p."SettingKey" is null)
       or (l."Kind" = 'sticker' and round(s."PricePerSqFt", 2) is distinct from round(l."OldPrice", 2))
       or (l."Kind" = 'delivery'
           and case when trim(coalesce(p."SettingValue", '')) ~ '^[0-9]+(\.[0-9]+)?$'
                    then round(trim(p."SettingValue")::numeric, 2) end is distinct from round(l."OldPrice", 2)));

  -- Set packages: gone, or Package Price no longer the old one.
  insert into _pc_bad
  select l."LineNo", coalesce(l."Name", l."ItemCode"),
         case when h."SetCode" is null then 'set package no longer exists'
              else 'Package Price edited since the draft was saved' end
    from public."PriceChangeBatchLines" l
    left join public."CompleteAquariumSetHeader" h on trim(h."SetCode") = l."ItemCode"
   where l."BatchId" = p_batch_id and l."Kind" = 'set'
     and (h."SetCode" is null or round(h."PackagePrice", 2) is distinct from round(l."OldPrice", 2));

  -- Calculator rates: gone, or no longer the old value.
  insert into _pc_bad
  select l."LineNo", coalesce(l."Name", l."ItemCode"),
         case when coalesce(g."Id"::text, t."Id"::text, x."FeatureKey") is null then 'rate no longer exists'
              else 'rate edited since the draft was saved' end
    from public."PriceChangeBatchLines" l
    left join public."GlassPricingSetup" g on l."Kind" = 'glass' and g."Id"::text = l."ItemCode"
    left join public."TubularPricingSetup" t on l."Kind" = 'tubular' and t."Id"::text = l."ItemCode"
    left join public."AquariumExtraPricingSetup" x on l."Kind" = 'extra' and x."FeatureKey" = l."ItemCode"
   where l."BatchId" = p_batch_id and l."Kind" in ('glass', 'tubular', 'extra')
     and round(coalesce(g."PricePerSqFt", t."PricePerFt", x."Price"), 2) is distinct from round(l."OldPrice", 2);

  select count(*), string_agg(label, ', ') into v_changed_count, v_changed
    from (select label from _pc_bad order by line_no limit 20) x;
  select count(*) into v_changed_count from _pc_bad;

  if v_changed_count > 0 and not p_skip_changed then
    raise exception 'Some lines can''t be applied as saved (price edited since, item gone, or an aquarium set): % - Open the draft (it reloads today''s prices and drops sets), review, and save again.', left(v_changed, 400);
  end if;

  update public."PriceChangeBatchLines" l
     set "Skipped" = true, "SkipReason" = b.reason
    from _pc_bad b
   where l."BatchId" = p_batch_id and l."LineNo" = b.line_no;
  get diagnostics v_skipped = row_count;

  -- Remember the RetailPrice each line clears (item lines, and variant lines for the representative variant).
  update public."PriceChangeBatchLines" l
     set "OldRetailPrice" = i."RetailPrice",
         "RetailPriceCleared" = true
    from public."Items" i
   where l."BatchId" = p_batch_id and not l."Skipped"
     and l."NewPrice" is not null
     and i."RetailPrice" is not null
     and ((l."Kind" = 'item' and i."Code" = l."ItemCode")
       or (l."Kind" = 'variant' and i."Code" = l."ItemCode" and i."VariationId" = l."VariationId"));
  get diagnostics v_cleared = row_count;

  -- Retail, item lines: the item + its single variant (MainItemCode, or the item's own VariationId).
  update public."Items" i
     set "Price" = l."NewPrice",
         "RetailPrice" = null
    from public."PriceChangeBatchLines" l
   where l."BatchId" = p_batch_id and not l."Skipped" and l."Kind" = 'item' and l."NewPrice" is not null
     and i."Code" = l."ItemCode";
  get diagnostics v_retail = row_count;

  update public."Variants" v
     set "Price" = l."NewPrice"
    from public."PriceChangeBatchLines" l
    join public."Items" i on i."Code" = l."ItemCode"
   where l."BatchId" = p_batch_id and not l."Skipped" and l."Kind" = 'item' and l."NewPrice" is not null
     and (v."MainItemCode" = l."ItemCode" or v."VariationId" = i."VariationId");

  -- Retail, variant lines: the variant, and the item when it is the representative one.
  update public."Variants" v
     set "Price" = l."NewPrice"
    from public."PriceChangeBatchLines" l
   where l."BatchId" = p_batch_id and not l."Skipped" and l."Kind" = 'variant' and l."NewPrice" is not null
     and v."VariationId" = l."VariationId";
  get diagnostics v_n = row_count;
  v_retail := v_retail + v_n;

  update public."Items" i
     set "Price" = l."NewPrice",
         "RetailPrice" = null
    from public."PriceChangeBatchLines" l
   where l."BatchId" = p_batch_id and not l."Skipped" and l."Kind" = 'variant' and l."NewPrice" is not null
     and i."Code" = l."ItemCode" and i."VariationId" = l."VariationId";

  -- Wholesale.
  update public."Items" i
     set "WholesalePrice" = l."NewWholesalePrice"
    from public."PriceChangeBatchLines" l
   where l."BatchId" = p_batch_id and not l."Skipped" and l."NewWholesalePrice" is not null
     and i."Code" = l."ItemCode";
  get diagnostics v_wholesale = row_count;

  -- Sticker / delivery rates.
  update public."StickerPricingSetup" s
     set "PricePerSqFt" = round(l."NewPrice", 2), "UpdatedAtUtc" = now(), "UpdatedBy" = p_actor
    from public."PriceChangeBatchLines" l
   where l."BatchId" = p_batch_id and not l."Skipped" and l."Kind" = 'sticker' and s."Id"::text = l."ItemCode";
  get diagnostics v_rates = row_count;

  update public."PortalSettings" p
     set "SettingValue" = trim_scale(round(l."NewPrice", 2))::text, "UpdatedAtUtc" = now(), "UpdatedBy" = left(p_actor, 100)
    from public."PriceChangeBatchLines" l
   where l."BatchId" = p_batch_id and not l."Skipped" and l."Kind" = 'delivery' and p."SettingKey" = l."ItemCode";
  get diagnostics v_n = row_count;
  v_rates := v_rates + v_n;

  -- Set packages (the header trigger copies the new price to the set's Items row).
  update public."CompleteAquariumSetHeader" h
     set "PackagePrice" = round(l."NewPrice", 2), "UpdatedDate" = now()
    from public."PriceChangeBatchLines" l
   where l."BatchId" = p_batch_id and not l."Skipped" and l."Kind" = 'set' and trim(h."SetCode") = l."ItemCode";
  get diagnostics v_sets = row_count;

  -- Calculator rates.
  update public."GlassPricingSetup" g
     set "PricePerSqFt" = round(l."NewPrice", 2), "UpdatedAtUtc" = now(), "UpdatedBy" = p_actor
    from public."PriceChangeBatchLines" l
   where l."BatchId" = p_batch_id and not l."Skipped" and l."Kind" = 'glass' and g."Id"::text = l."ItemCode";
  get diagnostics v_calc = row_count;

  update public."TubularPricingSetup" t
     set "PricePerFt" = round(l."NewPrice", 2), "UpdatedAtUtc" = now(), "UpdatedBy" = p_actor
    from public."PriceChangeBatchLines" l
   where l."BatchId" = p_batch_id and not l."Skipped" and l."Kind" = 'tubular' and t."Id"::text = l."ItemCode";
  get diagnostics v_n = row_count;
  v_calc := v_calc + v_n;

  update public."AquariumExtraPricingSetup" x
     set "Price" = round(l."NewPrice", 2), "UpdatedAtUtc" = now(), "UpdatedBy" = p_actor
    from public."PriceChangeBatchLines" l
   where l."BatchId" = p_batch_id and not l."Skipped" and l."Kind" = 'extra' and x."FeatureKey" = l."ItemCode";
  get diagnostics v_n = row_count;
  v_calc := v_calc + v_n;

  update public."PriceChangeBatches"
     set "Status" = 'Applied', "AppliedBy" = p_actor, "AppliedAtUtc" = now(),
         "ApplyError" = null, "ApplyErrorAtUtc" = null
   where "BatchId" = p_batch_id;

  return jsonb_build_object('retail_updated', v_retail, 'wholesale_updated', v_wholesale, 'rates_updated', v_rates,
                            'sets_updated', v_sets, 'calc_updated', v_calc, 'retail_price_cleared', v_cleared, 'skipped', v_skipped);
end;
$$;

revoke execute on function public._price_change_apply(bigint, text, boolean) from public, anon, authenticated;

drop function if exists public.admin_price_change_apply(text, text, bigint);

create or replace function public.admin_price_change_apply(p_admin_username text, p_admin_password text, p_batch_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '60000'
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return public._price_change_apply(p_batch_id, p_admin_username, false);
end;
$$;

grant execute on function public.admin_price_change_apply(text, text, bigint) to anon;

-- pg_cron: applies every Scheduled batch that is due. Each batch runs in its own sub-transaction, so one
-- failing batch is rolled back on its own, put back to Draft with the error (shown on the page), and the
-- others still apply.
drop function if exists public.cron_apply_scheduled_price_changes();

create or replace function public.cron_apply_scheduled_price_changes()
returns void
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '120000'
as $$
declare
  v_batch record;
begin
  for v_batch in
    select "BatchId", "ScheduledBy" from public."PriceChangeBatches"
     where "Status" = 'Scheduled' and "ScheduledForUtc" <= now()
     order by "ScheduledForUtc", "BatchId"
  loop
    begin
      perform public._price_change_apply(v_batch."BatchId", coalesce(v_batch."ScheduledBy", 'system') || ' (scheduled)', true);
    exception when others then
      update public."PriceChangeBatches"
         set "Status" = 'Draft', "ApplyError" = left(sqlerrm, 1000), "ApplyErrorAtUtc" = now()
       where "BatchId" = v_batch."BatchId";
    end;
  end loop;
end;
$$;

revoke execute on function public.cron_apply_scheduled_price_changes() from public, anon, authenticated;

select cron.unschedule('apply-scheduled-price-changes')
where exists (select 1 from cron.job where jobname = 'apply-scheduled-price-changes');

select cron.schedule(
  'apply-scheduled-price-changes',
  '*/5 * * * *',
  $$select public.cron_apply_scheduled_price_changes();$$
);

-- Puts every applied line back to its old price - but only lines still at the batch's new price, so a price
-- edited after the increase is left alone (counted in undo_skipped). Lines a scheduled apply skipped were
-- never changed, so they are ignored.
drop function if exists public.admin_price_change_undo(text, text, bigint);

create or replace function public.admin_price_change_undo(p_admin_username text, p_admin_password text, p_batch_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '60000'
as $$
declare
  v_status text;
  v_total int;
  v_retail int := 0;
  v_wholesale int := 0;
  v_n int;
  v_skipped int;
  v_rates int := 0;
  v_sets int := 0;
  v_calc int := 0;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if public._items_pancake_sync_active() then
    raise exception 'Products are still synced from Pancake - the next sync would overwrite the restored prices.';
  end if;

  select "Status" into v_status from public."PriceChangeBatches" where "BatchId" = p_batch_id for update;
  if not found then
    raise exception 'Price change #% not found.', p_batch_id;
  end if;
  if v_status <> 'Applied' then
    raise exception 'Price change #% is % - only an Applied one can be undone.', p_batch_id, v_status;
  end if;

  select count(*) filter (where "NewPrice" is not null) + count(*) filter (where "NewWholesalePrice" is not null)
    into v_total from public."PriceChangeBatchLines" where "BatchId" = p_batch_id and not "Skipped";

  -- Retail lines still at the new price (+ the single variant, + the cleared RetailPrice).
  create temp table if not exists _pc_undo (item_code text, variation_id text, kind text, old_price numeric,
                                            old_retail numeric, cleared boolean) on commit drop;
  truncate _pc_undo;

  insert into _pc_undo
  select l."ItemCode", l."VariationId", l."Kind", l."OldPrice", l."OldRetailPrice", l."RetailPriceCleared"
    from public."PriceChangeBatchLines" l
    left join public."Items" i on i."Code" = l."ItemCode"
    left join public."Variants" v on v."VariationId" = l."VariationId"
   where l."BatchId" = p_batch_id and not l."Skipped" and l."NewPrice" is not null
     and ((l."Kind" = 'item' and round(coalesce(i."Price", 0), 2) = round(l."NewPrice", 2))
       or (l."Kind" = 'variant' and round(coalesce(v."Price", 0), 2) = round(l."NewPrice", 2)));

  update public."Variants" v
     set "Price" = u.old_price
    from _pc_undo u
    join public."Items" i on i."Code" = u.item_code
   where u.kind = 'item' and (v."MainItemCode" = u.item_code or v."VariationId" = i."VariationId");

  update public."Items" i
     set "Price" = u.old_price,
         "RetailPrice" = case when u.cleared then u.old_retail else i."RetailPrice" end
    from _pc_undo u
   where u.kind = 'item' and i."Code" = u.item_code;
  get diagnostics v_n = row_count;
  v_retail := v_n;

  update public."Variants" v
     set "Price" = u.old_price
    from _pc_undo u
   where u.kind = 'variant' and v."VariationId" = u.variation_id;
  get diagnostics v_n = row_count;
  v_retail := v_retail + v_n;

  update public."Items" i
     set "Price" = u.old_price,
         "RetailPrice" = case when u.cleared then u.old_retail else i."RetailPrice" end
    from _pc_undo u
   where u.kind = 'variant' and i."Code" = u.item_code and i."VariationId" = u.variation_id;

  -- Wholesale, only where still at the batch's new wholesale price.
  update public."Items" i
     set "WholesalePrice" = l."OldWholesalePrice"
    from public."PriceChangeBatchLines" l
   where l."BatchId" = p_batch_id and not l."Skipped" and l."NewWholesalePrice" is not null
     and i."Code" = l."ItemCode"
     and round(i."WholesalePrice", 2) = round(l."NewWholesalePrice", 2);
  get diagnostics v_wholesale = row_count;

  -- Sticker / delivery rates, only where still at the batch's new value.
  update public."StickerPricingSetup" s
     set "PricePerSqFt" = round(l."OldPrice", 2), "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
    from public."PriceChangeBatchLines" l
   where l."BatchId" = p_batch_id and not l."Skipped" and l."Kind" = 'sticker' and s."Id"::text = l."ItemCode"
     and round(s."PricePerSqFt", 2) = round(l."NewPrice", 2);
  get diagnostics v_rates = row_count;

  update public."PortalSettings" p
     set "SettingValue" = trim_scale(round(l."OldPrice", 2))::text, "UpdatedAtUtc" = now(), "UpdatedBy" = left(p_admin_username, 100)
    from public."PriceChangeBatchLines" l
   where l."BatchId" = p_batch_id and not l."Skipped" and l."Kind" = 'delivery' and p."SettingKey" = l."ItemCode"
     and case when trim(coalesce(p."SettingValue", '')) ~ '^[0-9]+(\.[0-9]+)?$'
              then round(trim(p."SettingValue")::numeric, 2) end = round(l."NewPrice", 2);
  get diagnostics v_n = row_count;
  v_rates := v_rates + v_n;

  -- Set packages, only where the Package Price is still the batch's new price.
  update public."CompleteAquariumSetHeader" h
     set "PackagePrice" = round(l."OldPrice", 2), "UpdatedDate" = now()
    from public."PriceChangeBatchLines" l
   where l."BatchId" = p_batch_id and not l."Skipped" and l."Kind" = 'set' and trim(h."SetCode") = l."ItemCode"
     and round(h."PackagePrice", 2) = round(l."NewPrice", 2);
  get diagnostics v_sets = row_count;

  -- Calculator rates, only where still at the batch's new value.
  update public."GlassPricingSetup" g
     set "PricePerSqFt" = round(l."OldPrice", 2), "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
    from public."PriceChangeBatchLines" l
   where l."BatchId" = p_batch_id and not l."Skipped" and l."Kind" = 'glass' and g."Id"::text = l."ItemCode"
     and round(g."PricePerSqFt", 2) = round(l."NewPrice", 2);
  get diagnostics v_calc = row_count;

  update public."TubularPricingSetup" t
     set "PricePerFt" = round(l."OldPrice", 2), "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
    from public."PriceChangeBatchLines" l
   where l."BatchId" = p_batch_id and not l."Skipped" and l."Kind" = 'tubular' and t."Id"::text = l."ItemCode"
     and round(t."PricePerFt", 2) = round(l."NewPrice", 2);
  get diagnostics v_n = row_count;
  v_calc := v_calc + v_n;

  update public."AquariumExtraPricingSetup" x
     set "Price" = round(l."OldPrice", 2), "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
    from public."PriceChangeBatchLines" l
   where l."BatchId" = p_batch_id and not l."Skipped" and l."Kind" = 'extra' and x."FeatureKey" = l."ItemCode"
     and round(x."Price", 2) = round(l."NewPrice", 2);
  get diagnostics v_n = row_count;
  v_calc := v_calc + v_n;

  v_skipped := greatest(v_total - v_retail - v_wholesale - v_rates - v_sets - v_calc, 0);

  update public."PriceChangeBatches"
     set "Status" = 'Undone', "UndoneBy" = p_admin_username, "UndoneAtUtc" = now(), "UndoSkipped" = v_skipped
   where "BatchId" = p_batch_id;

  return jsonb_build_object('retail_restored', v_retail, 'wholesale_restored', v_wholesale, 'rates_restored', v_rates,
                            'sets_restored', v_sets, 'calc_restored', v_calc, 'skipped', v_skipped);
end;
$$;

grant execute on function public.admin_price_change_undo(text, text, bigint) to anon;

notify pgrst, 'reload schema';

-- Verification - ONE result. Expect 9 'function' rows (all has_anon_execute = true) and 1 'cron' row (active).
select 'function' as section, p.proname::text as name,
       has_function_privilege('anon', p.oid, 'EXECUTE')::text as detail
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname like 'admin_price_change_%'
union all
select 'cron', jobname::text, schedule || case when active then ' (active)' else ' (PAUSED)' end
  from cron.job
 where jobname = 'apply-scheduled-price-changes'
order by 1 desc, 2;
