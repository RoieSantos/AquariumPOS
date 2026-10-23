-- Products move from Pancake to the portal (2026-10-23, "products are maintained in Pancake but I want to
-- cut it out and maintain in the portal").
--
-- Until the cutover, cron_sync_items_from_pancake (job sync-items-from-pancake) still copies Pancake's
-- products into Items/Variants every 5 minutes, so the portal must not edit them yet - the next sync
-- would overwrite the edit. Everything here therefore keys off ONE switch: whether that cron job is
-- active (public._items_pancake_sync_active()).
--   * job active (now)    - New Item / item edits / New Variant / picture changes are refused with a
--                           "still synced from Pancake" message; price edits keep going to Pancake
--                           first (unchanged behaviour of supabase_item_price_pancake_push.sql).
--   * job paused (cutover, supabase_item_master_cutover.sql) - the portal is the only place products are
--                           created and edited; price edits are portal-only (no Pancake call, no
--                           whole-peso rounding).
--
-- What this adds:
--   Categories."CodePrefix"           - New Item code prefix per category, seeded from the prefix most of
--                                       that category's items already use (FOOD -> FD, FISH -> F, ...).
--   Items."PortalEditedAtUtc"/"By"    - set by the portal create/edit RPCs; the POS only overwrites its
--                                       local item name for items edited here (see pos_list_items_master).
--   _next_item_code(prefix)           - PREFIX-<highest number with that prefix across ALL items + 1>, 3
--                                       digits (prefixes are shared between categories: A is Accessories,
--                                       Medicine and Production Item, so counting per category would
--                                       hand out codes that already exist).
--   admin_item_master_status          - is the portal the product master yet (for the page's buttons)
--   admin_list_item_categories        - categories with prefix + the code New Item would get
--   admin_create_item                 - New Item: Items row + its default variant (orders, stock and the
--                                       POS all point at a variant, so every item has at least one)
--   admin_update_item                 - Name, Description, Brand, Category, Active, Promo Price, picture
--   admin_add_item_variant            - New Variant: SKU = ITEMCODE-Option (AQ-001-BlackSealant pattern)
--   admin_set_variant_image           - a variant's own picture
--   admin_create_item_image_upload    - signed upload into portal-assets/item-images/ (same helper as
--                                       the company logo, supabase_portal_logo_upload.sql)
--   admin_set_item_price / admin_set_variant_price - redefined: portal-only after the cutover
--   pos_list_items_master / pos_list_variants_master - the store POS pulls products from here instead of
--                                       Pancake (POS key, no cost). Before the cutover Items/Variants are a
--                                       5-minute copy of Pancake, so switching the POS early changes nothing.
--
-- Run AFTER supabase_item_price_pancake_push.sql, supabase_portal_logo_upload.sql and
-- supabase_pos_online_pay.sql (_pos_key_ok). Safe to re-run.

-- ---------------------------------------------------------------------------
-- Columns + seed
-- ---------------------------------------------------------------------------

alter table public."Categories" add column if not exists "CodePrefix" varchar(10);
alter table public."Items" add column if not exists "PortalEditedAtUtc" timestamptz;
alter table public."Items" add column if not exists "PortalEditedBy" varchar(100);

-- Categories used on items but missing from the Categories table (e.g. "Filter Medias"), so New Item
-- can offer them.
insert into public."Categories" ("Code", "Description")
select distinct trim(i."CategoryCode"), trim(i."CategoryCode")
from public."Items" i
where nullif(trim(i."CategoryCode"), '') is not null
  and not exists (select 1 from public."Categories" c where c."Code" = trim(i."CategoryCode"))
on conflict ("Code") do nothing;

-- Dominant prefix per category (case-insensitive, so "Aquarium" and "AQUARIUM" pool their items). Only
-- fills blanks - a prefix set by hand is kept.
update public."Categories" c
set "CodePrefix" = p.prefix
from (
  select distinct on (upper(trim(i."CategoryCode")))
         upper(trim(i."CategoryCode")) as cat_key,
         upper((regexp_match(i."Code", '^([A-Za-z]+)-[0-9]+$'))[1]) as prefix
  from public."Items" i
  where i."Code" ~ '^[A-Za-z]+-[0-9]+$' and nullif(trim(i."CategoryCode"), '') is not null
  group by 1, 2
  order by upper(trim(i."CategoryCode")), count(*) desc, 2
) p
where upper(trim(c."Code")) = p.cat_key
  and nullif(trim(c."CodePrefix"), '') is null;

-- ---------------------------------------------------------------------------
-- Helpers (not callable from the browser)
-- ---------------------------------------------------------------------------

create or replace function public._items_pancake_sync_active()
returns boolean
language sql
stable
security definer
set search_path = public, cron
as $$
  select exists (select 1 from cron.job where jobname = 'sync-items-from-pancake' and active);
$$;

revoke all on function public._items_pancake_sync_active() from public, anon, authenticated;

create or replace function public._require_items_portal_owned()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if public._items_pancake_sync_active() then
    raise exception 'Products are still copied from Pancake every 5 minutes, so a change here would be overwritten. Make this change in Pancake until the cutover (supabase_item_master_cutover.sql).';
  end if;
end;
$$;

revoke all on function public._require_items_portal_owned() from public, anon, authenticated;

create or replace function public._next_item_code(p_prefix text)
returns text
language sql
stable
security definer
set search_path = public, extensions
as $$
  select upper(trim(p_prefix)) || '-' || lpad((coalesce(max((regexp_match(i."Code", '^[A-Za-z]+-([0-9]+)$'))[1]::int), 0) + 1)::text, 3, '0')
  from public."Items" i
  where i."Code" ~ '^[A-Za-z]+-[0-9]+$'
    and upper(split_part(i."Code", '-', 1)) = upper(trim(p_prefix));
$$;

revoke all on function public._next_item_code(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Page RPCs (super users)
-- ---------------------------------------------------------------------------

create or replace function public.admin_item_master_status(p_admin_username text, p_admin_password text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return jsonb_build_object('portal_owned', not public._items_pancake_sync_active());
end;
$$;

grant execute on function public.admin_item_master_status(text, text) to anon;

drop function if exists public.admin_list_item_categories(text, text);

create or replace function public.admin_list_item_categories(p_admin_username text, p_admin_password text)
returns table(code text, description text, code_prefix text, next_code text)
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
    select c."Code"::text, coalesce(nullif(trim(c."Description"), ''), c."Code")::text,
           nullif(trim(c."CodePrefix"), '')::text,
           case when nullif(trim(c."CodePrefix"), '') is null then null else public._next_item_code(c."CodePrefix") end
    from public."Categories" c
    where nullif(trim(c."Code"), '') is not null and upper(c."Code") <> 'NULL'
    order by 2;
end;
$$;

grant execute on function public.admin_list_item_categories(text, text) to anon;

drop function if exists public.admin_create_item(text, text, text, text, text, text, numeric, text, text);

-- p_code_prefix is only needed (and only used) when the category has no prefix yet - it is then saved
-- on the category for next time. Returns the new item code.
create or replace function public.admin_create_item(
  p_admin_username text,
  p_admin_password text,
  p_category_code text,
  p_name text,
  p_description text,
  p_brand text,
  p_price numeric,
  p_image_url text default null,
  p_code_prefix text default null
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_category public."Categories"%rowtype;
  v_prefix text;
  v_code text;
  v_variation_id text := gen_random_uuid()::text;
  v_name text := trim(coalesce(p_name, ''));
  v_image text := nullif(trim(coalesce(p_image_url, '')), '');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  perform public._require_items_portal_owned();

  if v_name = '' then
    raise exception 'Enter the item name.';
  end if;
  if p_price is null or p_price < 0 then
    raise exception 'Enter a price of 0 or more.';
  end if;

  select * into v_category from public."Categories" where "Code" = trim(coalesce(p_category_code, ''));
  if not found then
    raise exception 'Pick a category.';
  end if;

  v_prefix := upper(coalesce(nullif(trim(v_category."CodePrefix"), ''), nullif(trim(coalesce(p_code_prefix, '')), '')));
  if v_prefix is null then
    raise exception 'Category % has no code prefix yet - enter one (e.g. FD).', v_category."Code";
  end if;
  if v_prefix !~ '^[A-Z]{1,6}$' then
    raise exception 'A code prefix is 1 to 6 letters (e.g. FD).';
  end if;
  if nullif(trim(v_category."CodePrefix"), '') is null then
    update public."Categories" set "CodePrefix" = v_prefix where "Code" = v_category."Code";
  end if;

  -- Two people adding an item with the same prefix at once must not get the same number.
  perform pg_advisory_xact_lock(hashtext('item-code|' || v_prefix));
  v_code := public._next_item_code(v_prefix);

  insert into public."Items" (
    "Code", "Name", "Description", "Brand", "CategoryCode", "SKU", "Price", "IsActive",
    "VariationId", "Images", "PortalEditedAtUtc", "PortalEditedBy"
  )
  values (
    v_code, left(v_name, 255), left(coalesce(nullif(trim(coalesce(p_description, '')), ''), v_name), 1000),
    nullif(trim(coalesce(p_brand, '')), ''), v_category."Code", v_code, round(p_price, 2), true,
    v_variation_id, v_image, now(), p_admin_username
  );

  insert into public."Variants" ("VariationId", "MainItemCode", "ItemCode", "SKU", "VariantName", "Price", "CategoryCode", "Images")
  values (v_variation_id, v_code, v_code, v_code, left(v_name, 255), round(p_price, 2), v_category."Code", v_image);

  return v_code;
end;
$$;

grant execute on function public.admin_create_item(text, text, text, text, text, text, numeric, text, text) to anon;

drop function if exists public.admin_update_item(text, text, text, text, text, text, text, boolean, numeric, text);

-- p_image_url: null = keep the picture, '' = remove it. p_promo_price: null = no promo.
create or replace function public.admin_update_item(
  p_admin_username text,
  p_admin_password text,
  p_item_code text,
  p_name text,
  p_description text,
  p_brand text,
  p_category_code text,
  p_is_active boolean,
  p_promo_price numeric,
  p_image_url text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_item public."Items"%rowtype;
  v_name text := trim(coalesce(p_name, ''));
  v_category text;
  v_variant_count int;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  perform public._require_items_portal_owned();

  select * into v_item from public."Items" where "Code" = p_item_code for update;
  if not found then
    raise exception 'Item % not found.', p_item_code;
  end if;
  if v_name = '' then
    raise exception 'The item name can''t be blank.';
  end if;
  if p_promo_price is not null and p_promo_price < 0 then
    raise exception 'Promo price must be 0 or more (or blank for no promo).';
  end if;

  select "Code" into v_category from public."Categories" where "Code" = trim(coalesce(p_category_code, ''));
  if v_category is null then
    raise exception 'Pick a category.';
  end if;

  update public."Items"
  set "Name" = left(v_name, 255),
      "Description" = left(coalesce(nullif(trim(coalesce(p_description, '')), ''), v_name), 1000),
      "Brand" = nullif(trim(coalesce(p_brand, '')), ''),
      "CategoryCode" = v_category,
      "IsActive" = coalesce(p_is_active, true),
      "PromoPrice" = round(p_promo_price, 2),
      "Images" = case when p_image_url is null then "Images" else nullif(trim(p_image_url), '') end,
      "PortalEditedAtUtc" = now(),
      "PortalEditedBy" = p_admin_username
  where "Code" = p_item_code;

  -- Variants carry their own copy of the category, and of the item name (alone, or "Name - Option").
  update public."Variants"
  set "CategoryCode" = v_category,
      "VariantName" = case
        when "VariantName" = v_item."Name" then left(v_name, 255)
        when v_item."Name" is not null and "VariantName" like v_item."Name" || ' - %'
          then left(v_name || substr("VariantName", length(v_item."Name") + 1), 255)
        else "VariantName" end
  where "MainItemCode" = p_item_code;

  -- A lone variant shows the item's picture.
  select count(*) into v_variant_count from public."Variants" where "MainItemCode" = p_item_code;
  if p_image_url is not null and v_variant_count = 1 then
    update public."Variants" set "Images" = nullif(trim(p_image_url), '') where "MainItemCode" = p_item_code;
  end if;
end;
$$;

grant execute on function public.admin_update_item(text, text, text, text, text, text, text, boolean, numeric, text) to anon;

drop function if exists public.admin_add_item_variant(text, text, text, text, numeric, text);

-- Returns the new VariationId.
create or replace function public.admin_add_item_variant(
  p_admin_username text,
  p_admin_password text,
  p_item_code text,
  p_option text,
  p_price numeric,
  p_image_url text default null
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_item public."Items"%rowtype;
  v_option text := regexp_replace(trim(coalesce(p_option, '')), '\s+', ' ', 'g');
  v_sku text;
  v_variation_id text := gen_random_uuid()::text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  perform public._require_items_portal_owned();

  select * into v_item from public."Items" where "Code" = p_item_code;
  if not found then
    raise exception 'Item % not found.', p_item_code;
  end if;
  if v_option !~ '^[A-Za-z0-9][A-Za-z0-9 ._/()-]{0,39}$' then
    raise exception 'Enter the option name (letters, numbers, spaces, - . / ( ); up to 40 characters), e.g. BlackSealant.';
  end if;
  if p_price is not null and p_price < 0 then
    raise exception 'Price must be 0 or more.';
  end if;

  v_sku := left(v_item."Code" || '-' || replace(v_option, ' ', ''), 150);
  if exists (select 1 from public."Variants" where upper("SKU") = upper(v_sku)) then
    raise exception 'Variant SKU % already exists.', v_sku;
  end if;

  insert into public."Variants" ("VariationId", "MainItemCode", "ItemCode", "SKU", "VariantName", "Price", "CategoryCode", "Images")
  values (
    v_variation_id, v_item."Code", v_item."Code", v_sku,
    left(coalesce(v_item."Name", v_item."Code") || ' - ' || v_option, 255),
    round(coalesce(p_price, v_item."Price"), 2), v_item."CategoryCode",
    coalesce(nullif(trim(coalesce(p_image_url, '')), ''), v_item."Images")
  );

  update public."Items" set "PortalEditedAtUtc" = now(), "PortalEditedBy" = p_admin_username where "Code" = v_item."Code";

  return v_variation_id;
end;
$$;

grant execute on function public.admin_add_item_variant(text, text, text, text, numeric, text) to anon;

drop function if exists public.admin_set_variant_image(text, text, text, text);

create or replace function public.admin_set_variant_image(
  p_admin_username text,
  p_admin_password text,
  p_variation_id text,
  p_image_url text
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
  perform public._require_items_portal_owned();

  update public."Variants" set "Images" = nullif(trim(coalesce(p_image_url, '')), '') where "VariationId" = p_variation_id;
  if not found then
    raise exception 'Variant % not found.', p_variation_id;
  end if;
end;
$$;

grant execute on function public.admin_set_variant_image(text, text, text, text) to anon;

drop function if exists public.admin_create_item_image_upload(text, text, text);

create or replace function public.admin_create_item_image_upload(
  p_admin_username text,
  p_admin_password text,
  p_file_name text
)
returns table(storage_path text, upload_token text, public_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_ext text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  perform public._require_items_portal_owned();

  v_ext := lower(regexp_replace(coalesce(p_file_name, ''), '^.*\.', ''));
  if v_ext !~ '^(jpg|jpeg|png|webp|gif)$' then
    v_ext := 'jpg';
  end if;

  return query select * from public._create_signed_portal_asset_upload('item-images/' || gen_random_uuid()::text || '.' || v_ext);
end;
$$;

grant execute on function public.admin_create_item_image_upload(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Prices: same as supabase_item_price_pancake_push.sql while the Pancake sync runs; portal-only after.
-- Return shape unchanged (+ portal_only), so Item Setup's save code reads both.
-- ---------------------------------------------------------------------------

create or replace function public.admin_set_variant_price(
  p_admin_username text,
  p_admin_password text,
  p_variation_id text,
  p_price numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
as $$
declare
  v_variant public."Variants"%rowtype;
  v_price numeric;
  v_product_id text;
  v_result jsonb;
  v_final_price numeric;
  v_items_updated int;
  v_portal_only boolean := not public._items_pancake_sync_active();
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_price is null or p_price < 0 then
    raise exception 'Price must be 0 or more.';
  end if;
  v_price := round(p_price, 2);

  select * into v_variant from public."Variants" where "VariationId" = p_variation_id;
  if not found then
    raise exception 'Variant % not found.', p_variation_id;
  end if;

  if v_portal_only then
    v_final_price := v_price;
  else
    v_product_id := nullif(trim(v_variant."ProductId"), '');
    if v_product_id is null then
      select nullif(trim(i."ProductId"), '') into v_product_id
        from public."Items" i
        where i."Code" = coalesce(nullif(v_variant."ItemCode", ''), v_variant."MainItemCode");
    end if;

    if v_product_id is null then
      raise exception 'This variant is not linked to a Pancake product yet (no ProductId) - run the Pancake sync first, then try again.';
    end if;

    v_result := public._pancake_push_variation_price(v_product_id, p_variation_id, v_price);
    v_final_price := (v_result ->> 'price')::numeric;
  end if;

  update public."Variants" set "Price" = v_final_price where "VariationId" = p_variation_id;

  -- Only the representative variant's edit reaches Items.Price.
  update public."Items" set "Price" = v_final_price where "VariationId" = p_variation_id;
  get diagnostics v_items_updated = row_count;

  return jsonb_build_object(
    'price', v_final_price,
    'requested', v_price,
    'pancake_confirmed', case when v_portal_only then true else (v_result ->> 'confirmed')::boolean end,
    'portal_only', v_portal_only,
    'item_price_updated', v_items_updated > 0
  );
end;
$$;

grant execute on function public.admin_set_variant_price(text, text, text, numeric) to anon;

create or replace function public.admin_set_item_price(
  p_admin_username text,
  p_admin_password text,
  p_item_code text,
  p_price numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
as $$
declare
  v_item public."Items"%rowtype;
  v_price numeric;
  v_variant_count int;
  v_variation_id text;
  v_product_id text;
  v_result jsonb;
  v_final_price numeric;
  v_retail_override numeric;
  v_portal_only boolean := not public._items_pancake_sync_active();
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_price is null or p_price < 0 then
    raise exception 'Price must be 0 or more.';
  end if;
  v_price := round(p_price, 2);

  select * into v_item from public."Items" where "Code" = p_item_code;
  if not found then
    raise exception 'Item % not found.', p_item_code;
  end if;

  select count(*) into v_variant_count from public."Variants" where "MainItemCode" = p_item_code;

  if v_variant_count > 1 then
    raise exception 'This item has % variants, each with its own price - set the price on the variant instead (Item Card > Variants).', v_variant_count;
  end if;

  if v_variant_count = 1 then
    select nullif(trim("VariationId"), ''), nullif(trim("ProductId"), '')
      into v_variation_id, v_product_id
      from public."Variants" where "MainItemCode" = p_item_code;
  end if;

  v_variation_id := coalesce(v_variation_id, nullif(trim(v_item."VariationId"), ''));
  v_product_id := coalesce(v_product_id, nullif(trim(v_item."ProductId"), ''));

  if v_portal_only then
    v_final_price := v_price;
  else
    if v_product_id is null and v_variation_id is not null then
      select nullif(trim("ProductId"), '') into v_product_id
        from public."Variants" where "VariationId" = v_variation_id;
    end if;

    if v_variation_id is null or v_product_id is null then
      raise exception 'This item is not linked to a Pancake product yet (no VariationId/ProductId) - run the Pancake sync first, then try again.';
    end if;

    v_result := public._pancake_push_variation_price(v_product_id, v_variation_id, v_price);
    v_final_price := (v_result ->> 'price')::numeric;
  end if;

  update public."Items" set "Price" = v_final_price where "Code" = p_item_code;
  if v_variation_id is not null then
    update public."Variants" set "Price" = v_final_price where "VariationId" = v_variation_id;
  end if;

  if v_item."RetailPrice" is not null and v_item."RetailPrice" <> v_final_price then
    v_retail_override := v_item."RetailPrice";
  end if;

  return jsonb_build_object(
    'price', v_final_price,
    'requested', v_price,
    'pancake_confirmed', case when v_portal_only then true else (v_result ->> 'confirmed')::boolean end,
    'portal_only', v_portal_only,
    'retail_price_override', v_retail_override
  );
end;
$$;

grant execute on function public.admin_set_item_price(text, text, text, numeric) to anon;

-- ---------------------------------------------------------------------------
-- Store POS pull (replaces its Pancake /products/variations pull). POS key, no cost.
-- ---------------------------------------------------------------------------

drop function if exists public.pos_list_items_master(text, int, int);

create or replace function public.pos_list_items_master(p_pos_key text, p_limit int default 1000, p_offset int default 0)
returns table(
  code text, name text, description text, sku text, price numeric, category_code text,
  variation_id text, product_id text, images text, is_active boolean, portal_edited boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select i."Code"::text, i."Name"::text, i."Description"::text, i."SKU"::text, i."Price",
         nullif(trim(i."CategoryCode"), '')::text, i."VariationId"::text, i."ProductId"::text, i."Images",
         coalesce(i."IsActive", true), i."PortalEditedAtUtc" is not null
  from public."Items" i
  where public._pos_key_ok(p_pos_key)
  order by i."Code"
  limit least(greatest(coalesce(p_limit, 1000), 1), 1000) offset greatest(coalesce(p_offset, 0), 0);
$$;

grant execute on function public.pos_list_items_master(text, int, int) to anon;

drop function if exists public.pos_list_variants_master(text, int, int);

create or replace function public.pos_list_variants_master(p_pos_key text, p_limit int default 1000, p_offset int default 0)
returns table(
  variation_id text, main_item_code text, item_code text, sku text, variant_name text, price numeric,
  category_code text, images text
)
language sql
stable
security definer
set search_path = public
as $$
  select v."VariationId"::text, v."MainItemCode"::text, v."ItemCode"::text, v."SKU"::text, v."VariantName"::text,
         v."Price", nullif(trim(v."CategoryCode"), '')::text, v."Images"
  from public."Variants" v
  where public._pos_key_ok(p_pos_key)
  order by v."VariationId"
  limit least(greatest(coalesce(p_limit, 1000), 1), 1000) offset greatest(coalesce(p_offset, 0), 0);
$$;

grant execute on function public.pos_list_variants_master(text, int, int) to anon;

notify pgrst, 'reload schema';

-- One result: each category's prefix and the code New Item would hand out next.
select c."Code"::text as category, coalesce(c."CodePrefix", '(none - enter one on New Item)')::text as prefix,
       case when c."CodePrefix" is null then null else public._next_item_code(c."CodePrefix") end as next_code,
       case when public._items_pancake_sync_active() then 'Pancake still syncs products' else 'portal owns products' end as mode
from public."Categories" c
where nullif(trim(c."Code"), '') is not null and upper(c."Code") <> 'NULL'
order by 1;
