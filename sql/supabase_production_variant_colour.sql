-- Production Orders: Black / Clear tagging of the variant - per "from the production shelf.. can you do
-- better tagging of variant in the production order. Its not tagging if the order is black or clear".
--
-- Why it was missing: the Shelf Map's Auto Production Order found the item's variants with
-- staff_search_variants, which (a) hides categories flagged ExcludeInTransferOrders and (b) only gave
-- the page VariantName / SKU to spot the colour in - a variant whose colour is only in its own item's
-- name, or written "BLK" / "CLR", came through untagged (or not at all, so no colour split happened).
--
--   _production_colour(text...)              - 'Black' / 'Clear' / null from the first text that says
--                                               black|blk or clear|clr.
--   staff_list_production_item_variants(item) - every variant of an item (by ItemCode or MainItemCode),
--                                               no category filter, with the variant's own item name
--                                               and its colour. Used by docs/js/productionShelfMap.js.
--   staff_list_production_order_lines        - same as before plus a `colour` column, so the order card
--                                               and printout show a Black / Clear tag per line.
--
-- Run AFTER supabase_production_orders.sql (re-running that file drops the colour column again - just
-- run this one after it). Safe to re-run.

create or replace function public._production_colour(variadic p_texts text[])
returns text
language sql
immutable
as $$
  select case
    when t ~* '(black|\mblk\M)' then 'Black'
    when t ~* '(clear|\mclr\M)' then 'Clear'
  end
  from unnest(p_texts) with ordinality as x(t, n)
  where t ~* '(black|\mblk\M|clear|\mclr\M)'
  order by n
  limit 1;
$$;

grant execute on function public._production_colour(text[]) to anon;

drop function if exists public.staff_list_production_item_variants(text, text, text);

create or replace function public.staff_list_production_item_variants(
  p_admin_username text,
  p_admin_password text,
  p_item_code text
)
returns table(variation_id text, item_code text, main_item_code text, sku text, variant_name text,
              item_name text, colour text)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select v."VariationId"::text, v."ItemCode"::text, v."MainItemCode"::text, v."SKU"::text,
           v."VariantName"::text, i."Name"::text,
           public._production_colour(v."VariantName", v."SKU", i."Name")
    from public."Variants" v
    left join public."Items" i on i."Code" = coalesce(v."ItemCode", v."MainItemCode")
    where v."ItemCode" = p_item_code or v."MainItemCode" = p_item_code
    order by v."VariantName", v."SKU";
end;
$$;

grant execute on function public.staff_list_production_item_variants(text, text, text) to anon;

-- Same as supabase_production_orders.sql's version, plus `colour`.
drop function if exists public.staff_list_production_order_lines(text, text, text);

create or replace function public.staff_list_production_order_lines(
  p_admin_username text,
  p_admin_password text,
  p_no text
)
returns table(
  line_no bigint, item_code text, item_name text, variant_id text, variant_name text, description text,
  quantity numeric, qty_output numeric, part text, needs_serial boolean, colour text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if not public._production_is_manager(p_admin_username) and not exists (
    select 1 from public."ProductionOrders" o
    where o."No" = p_no and (o."TankMaker" = p_admin_username or o."StandMaker" = p_admin_username)
  ) then
    raise exception 'You are not assigned to production order %.', p_no;
  end if;

  return query
    select l."LineNo", l."ItemCode"::text, i."Name"::text, l."VariantId"::text,
           coalesce(nullif(trim(v."VariantName"), ''), v."SKU")::text, l."Description"::text,
           l."Quantity", l."QtyOutput", l."Part"::text,
           public._production_item_needs_serial(coalesce(v."ItemCode", l."ItemCode"), l."VariantId"),
           public._production_colour(v."VariantName", v."SKU", vi."Name", l."Description")
    from public."ProductionOrderLines" l
    left join public."Items" i on i."Code" = l."ItemCode"
    left join public."Variants" v on v."VariationId" = l."VariantId"
    left join public."Items" vi on vi."Code" = v."ItemCode"
    where l."ProdOrderNo" = p_no
    order by l."LineNo";
end;
$$;

grant execute on function public.staff_list_production_order_lines(text, text, text) to anon;

notify pgrst, 'reload schema';
