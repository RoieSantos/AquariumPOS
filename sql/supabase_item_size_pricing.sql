-- =============================================================================
-- Size-based pricing (e.g. fish): "SHBRTG is 8,500, but a 10-11" one is 10,000".
--
-- A Size Scale is a reusable formula: a list of size tiers, each adding a % and/or a fixed peso
-- amount on top of the product's normal price, then rounded to the scale's step (e.g. nearest 100).
-- A product opts in by getting a SizeScaleCode. Stock is NOT split - it is still one product /
-- variant; the size only changes the line's price and adds the size to the line's name.
--
--   price = round( base * (1 + MarkupPercent/100) + MarkupAmount , to the nearest RoundTo )
--   e.g. SHBRTG base 8,500, tier 10-11" = +18%, RoundTo 100  ->  10,030 -> 10,000
--
-- Used by: Size Pricing page (docs/size-pricing.html), the shared size picker
-- (docs/js/sizePricePicker.js - Conversations Create Order, Online Orders New tab + Add Item) and the
-- desktop POS (pos_list_item_size_tiers, pulled into dbo.ItemSizeTier). NOT on Order Now - the AI bot
-- just tells customers fish are priced by size.
--
-- Safe to re-run.
-- =============================================================================

create table if not exists public."SizePriceScales" (
    "Code" varchar(50) primary key,
    "Name" varchar(150) not null default '',
    "RoundTo" numeric(18, 2) not null default 100,
    "UpdatedAtUtc" timestamptz not null default now(),
    "UpdatedBy" varchar(100)
);

create table if not exists public."SizePriceTiers" (
    "Id" bigserial primary key,
    "ScaleCode" varchar(50) not null references public."SizePriceScales"("Code") on delete cascade,
    "SortOrder" int not null default 0,
    "SizeLabel" varchar(60) not null,
    "MarkupPercent" numeric(9, 2) not null default 0,
    "MarkupAmount" numeric(18, 2) not null default 0
);
create index if not exists "IX_SizePriceTiers_Scale" on public."SizePriceTiers" ("ScaleCode", "SortOrder");

alter table public."Items" add column if not exists "SizeScaleCode" varchar(50);
create index if not exists "IX_Items_SizeScaleCode" on public."Items" ("SizeScaleCode") where "SizeScaleCode" is not null;

alter table public."SizePriceScales" enable row level security;
alter table public."SizePriceTiers" enable row level security;

-- ---------------------------------------------------------------------------
-- The formula. Never goes below the base price (a size tier only ever adds).
-- ---------------------------------------------------------------------------
create or replace function public._size_tier_price(p_base numeric, p_pct numeric, p_amount numeric, p_round_to numeric)
returns numeric
language sql
immutable
as $$
  select greatest(
    coalesce(p_base, 0),
    case when coalesce(p_round_to, 0) > 0
      then round((coalesce(p_base, 0) * (1 + coalesce(p_pct, 0) / 100) + coalesce(p_amount, 0)) / p_round_to) * p_round_to
      else round(coalesce(p_base, 0) * (1 + coalesce(p_pct, 0) / 100) + coalesce(p_amount, 0), 2)
    end);
$$;

-- ---------------------------------------------------------------------------
-- Size picker: the tiers for one product with their computed prices.
-- p_item_code may be the main item code or a variant's own item code. p_base_price = the price the
-- line would otherwise get (variant price, wholesale price...); null = the item's own selling price.
-- Returns null when the product is not size-priced.
-- ---------------------------------------------------------------------------
create or replace function public.public_get_item_size_prices(p_item_code text, p_base_price numeric default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_scale public."SizePriceScales"%rowtype;
  v_base numeric;
  v_code text;
begin
  select coalesce(
           (select i."Code" from public."Items" i where i."Code" = p_item_code and i."SizeScaleCode" is not null),
           (select v."MainItemCode" from public."Variants" v
              join public."Items" i on i."Code" = v."MainItemCode" and i."SizeScaleCode" is not null
             where v."ItemCode" = p_item_code or v."VariationId" = p_item_code limit 1))
    into v_code;
  if v_code is null then
    return null;
  end if;

  select s.* into v_scale
    from public."Items" i join public."SizePriceScales" s on s."Code" = i."SizeScaleCode"
   where i."Code" = v_code;
  if not found then
    return null;
  end if;

  v_base := coalesce(p_base_price, (select coalesce(i."RetailPrice", i."Price") from public."Items" i where i."Code" = v_code), 0);

  return jsonb_build_object(
    'item_code', v_code,
    'scale_code', v_scale."Code",
    'scale_name', v_scale."Name",
    'base_price', v_base,
    'tiers', coalesce((
      select jsonb_agg(jsonb_build_object(
               'tier_id', t."Id",
               'label', t."SizeLabel",
               'price', public._size_tier_price(v_base, t."MarkupPercent", t."MarkupAmount", v_scale."RoundTo"))
             order by t."SortOrder", t."Id")
        from public."SizePriceTiers" t where t."ScaleCode" = v_scale."Code"), '[]'::jsonb)
  );
end;
$$;
grant execute on function public.public_get_item_size_prices(text, numeric) to anon;

-- ---------------------------------------------------------------------------
-- Size Pricing page (super users).
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_size_scales(p_admin_username text, p_admin_password text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'code', s."Code",
             'name', s."Name",
             'round_to', s."RoundTo",
             'updated_at_utc', s."UpdatedAtUtc",
             'updated_by', s."UpdatedBy",
             'tiers', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'label', t."SizeLabel",
                        'markup_percent', t."MarkupPercent",
                        'markup_amount', t."MarkupAmount") order by t."SortOrder", t."Id")
                 from public."SizePriceTiers" t where t."ScaleCode" = s."Code"), '[]'::jsonb),
             'items', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'code', i."Code",
                        'name', coalesce(nullif(trim(i."Name"), ''), i."Description", i."Code"),
                        'price', coalesce(i."RetailPrice", i."Price")) order by i."Name")
                 from public."Items" i where i."SizeScaleCode" = s."Code"), '[]'::jsonb)
           ) order by s."Name")
      from public."SizePriceScales" s), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_list_size_scales(text, text) to anon;

-- p_tiers: [{label, markup_percent, markup_amount}, ...] in display order - replaces all tiers.
create or replace function public.admin_save_size_scale(
  p_admin_username text,
  p_admin_password text,
  p_code text,
  p_name text,
  p_round_to numeric,
  p_tiers jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := upper(trim(coalesce(p_code, '')));
  v_tier jsonb;
  v_order int := 0;
  v_label text;
  v_pct numeric;
  v_amt numeric;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_code = '' then
    raise exception 'Enter a code for the size scale, e.g. LARGEFISH.';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'Enter a name for the size scale.';
  end if;
  if p_round_to is null or p_round_to < 0 then
    raise exception 'Round To must be 0 or more (0 = no rounding).';
  end if;
  if p_tiers is null or jsonb_typeof(p_tiers) <> 'array' or jsonb_array_length(p_tiers) = 0 then
    raise exception 'Add at least one size.';
  end if;

  insert into public."SizePriceScales" ("Code", "Name", "RoundTo", "UpdatedAtUtc", "UpdatedBy")
  values (v_code, trim(p_name), p_round_to, now(), p_admin_username)
  on conflict ("Code") do update
    set "Name" = excluded."Name", "RoundTo" = excluded."RoundTo",
        "UpdatedAtUtc" = now(), "UpdatedBy" = excluded."UpdatedBy";

  delete from public."SizePriceTiers" where "ScaleCode" = v_code;

  for v_tier in select * from jsonb_array_elements(p_tiers) loop
    v_label := trim(coalesce(v_tier ->> 'label', ''));
    v_pct := coalesce(nullif(v_tier ->> 'markup_percent', '')::numeric, 0);
    v_amt := coalesce(nullif(v_tier ->> 'markup_amount', '')::numeric, 0);
    if v_label = '' then
      raise exception 'Every size needs a label, e.g. 10-11".';
    end if;
    if v_pct < 0 or v_amt < 0 then
      raise exception 'Size "%": the increase can''t be negative.', v_label;
    end if;
    if v_pct = 0 and v_amt = 0 then
      raise exception 'Size "%": enter a %% or a ₱ increase.', v_label;
    end if;
    v_order := v_order + 1;
    insert into public."SizePriceTiers" ("ScaleCode", "SortOrder", "SizeLabel", "MarkupPercent", "MarkupAmount")
    values (v_code, v_order, v_label, v_pct, v_amt);
  end loop;

  return jsonb_build_object('code', v_code, 'tiers', v_order);
end;
$$;
grant execute on function public.admin_save_size_scale(text, text, text, text, numeric, jsonb) to anon;

create or replace function public.admin_delete_size_scale(p_admin_username text, p_admin_password text, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_items int;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  update public."Items" set "SizeScaleCode" = null where "SizeScaleCode" = p_code;
  get diagnostics v_items = row_count;
  delete from public."SizePriceScales" where "Code" = p_code;
  return jsonb_build_object('items_cleared', v_items);
end;
$$;
grant execute on function public.admin_delete_size_scale(text, text, text) to anon;

-- p_scale_code null = take the product off size pricing.
create or replace function public.admin_set_item_size_scale(
  p_admin_username text,
  p_admin_password text,
  p_item_code text,
  p_scale_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_scale_code is not null and not exists (select 1 from public."SizePriceScales" where "Code" = p_scale_code) then
    raise exception 'Size scale % not found.', p_scale_code;
  end if;
  update public."Items" set "SizeScaleCode" = p_scale_code where "Code" = p_item_code;
  if not found then
    raise exception 'Item % not found.', p_item_code;
  end if;
  return jsonb_build_object('item_code', p_item_code, 'scale_code', p_scale_code);
end;
$$;
grant execute on function public.admin_set_item_size_scale(text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Desktop POS pull: one row per (item, tier) with the formula inputs - the POS works the price out
-- from the line's own price with the same formula (MainForm.ComputeSizeTierPrice).
-- ---------------------------------------------------------------------------
create or replace function public.pos_list_item_size_tiers(p_pos_key text)
returns table(item_code text, sort_order int, size_label text, markup_percent numeric, markup_amount numeric, round_to numeric)
language sql
stable
security definer
set search_path = public
as $$
  select i."Code"::text, t."SortOrder", t."SizeLabel"::text, t."MarkupPercent", t."MarkupAmount", s."RoundTo"
  from public."Items" i
  join public."SizePriceScales" s on s."Code" = i."SizeScaleCode"
  join public."SizePriceTiers" t on t."ScaleCode" = s."Code"
  where public._pos_key_ok(p_pos_key)
  order by i."Code", t."SortOrder", t."Id";
$$;
grant execute on function public.pos_list_item_size_tiers(text) to anon;
