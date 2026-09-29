-- Sealant Sales report - per "can you create me a report to see what is the best selling aquarium
-- sealant? the sealant is per variant".
--
-- Sealant isn't sold as its own line: Black / Clear are VARIANTS of each aquarium (and sump), e.g.
-- AQ-011-BlackSealant / AQ-011-ClearSealant (same finding as supabase_production_shelf_materials.sql).
-- So a line counts as a sealant sale when its VariationId resolves to a Variants row whose
-- name/SKU says "sealant" + black/clear. Don't read the colour from the line's Description - a
-- Pancake line's description can list BOTH variants ("AQ-011-BlackSealant - STANDARD-100G ... -
-- AQ-011-ClearSealant").
--
-- Custom builds (Web calculator / chatbot orders) have no variant, only text like
-- "Aquarium Build | ... | Black sealant | ..." - those are picked up from Description/Note when the
-- text names exactly one colour, and grouped as "Custom aquarium build" / "Custom sump build".
--
-- Same source and rules as admin_get_top_selling_items (supabase_top_selling_items_rpc.sql):
-- OnlineOrderLines x OnlineOrders (online + walk-in), order "Date", cancelled left out, revenue =
-- GrossAmount. Components of a set (e.g. the AQUARIUM line under an AQUARIUM SET) carry ₱0, so
-- units - not revenue - are the fair ranking.
--
-- One row per warehouse x online/walk-in x product x sealant variant; the page filters and totals
-- client-side. Any active staff (is_staff_authorized), like Top Selling Items. Safe to re-run.

drop function if exists public.admin_get_sealant_sales_report(text, text, date, date);

create or replace function public.admin_get_sealant_sales_report(
  p_admin_username text,
  p_admin_password text,
  p_date_from date,
  p_date_to date
)
returns table(
  warehouse_name text, is_walkin boolean,
  item_code text, item_name text, category_code text,
  sealant text, variant_sku text,
  qty_sold numeric, revenue numeric, order_count int
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_date_from is null or p_date_to is null or p_date_to < p_date_from then
    raise exception 'Pick a valid date range.';
  end if;

  return query
    with sealant_variants as (
      select v."VariationId" as variation_id,
             coalesce(nullif(trim(v."MainItemCode"), ''), v."ItemCode") as parent_code,
             v."SKU" as sku,
             case when (coalesce(v."VariantName", '') || ' ' || coalesce(v."SKU", '')) ~* 'black'
                  then 'Black' else 'Clear' end as colour
      from public."Variants" v
      where (coalesce(v."VariantName", '') || ' ' || coalesce(v."SKU", '')) ~* 'sealant'
        and (coalesce(v."VariantName", '') || ' ' || coalesce(v."SKU", '')) ~* '(black|clear)'
    ),
    lines as (
      select l."OrderID" as order_id,
             coalesce(nullif(trim(w."Name"), ''), '(No warehouse)') as wh,
             coalesce(o."ReceivedAtShop", false) as walkin,
             sv.parent_code, sv.sku, sv.colour,
             coalesce(l."Description", '') || ' ' || coalesce(l."Note", '') as line_text,
             coalesce(l."Quantity", 0) as qty,
             coalesce(l."GrossAmount", 0) as amount
      from public."OnlineOrderLines" l
      join public."OnlineOrders" o on o."OrderID" = l."OrderID"
      left join public."Warehouses" w on w."ID" = o."LocationID"
      left join sealant_variants sv on sv.variation_id = l."VariationId"
      where o."Date" >= p_date_from and o."Date" <= p_date_to
        and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
    ),
    classified as (
      -- sealant variants
      select x.order_id, x.wh, x.walkin, x.parent_code as code,
             coalesce(nullif(trim(i."Name"), ''), x.parent_code) as name,
             i."CategoryCode" as category, x.colour, x.sku, x.qty, x.amount
      from lines x
      left join public."Items" i on i."Code" = x.parent_code
      where x.colour is not null
      union all
      -- custom builds: no variant, exactly one sealant colour named in the text
      select x.order_id, x.wh, x.walkin,
             case when x.line_text ~* 'sump' then 'CUSTOM-SUMP' else 'CUSTOM-AQUARIUM' end,
             case when x.line_text ~* 'sump' then 'Custom sump build' else 'Custom aquarium build' end,
             'Custom',
             case when x.line_text ~* 'black\s*sealant' then 'Black' else 'Clear' end,
             null, x.qty, x.amount
      from lines x
      where x.colour is null
        and (x.line_text ~* 'black\s*sealant') <> (x.line_text ~* 'clear\s*sealant')
    )
    select c.wh::text, c.walkin, c.code::text, c.name::text, c.category::text,
           c.colour::text, max(c.sku)::text,
           sum(c.qty)::numeric, sum(c.amount)::numeric, count(distinct c.order_id)::int
    from classified c
    group by c.wh, c.walkin, c.code, c.name, c.category, c.colour;
end;
$$;

grant execute on function public.admin_get_sealant_sales_report(text, text, date, date) to anon;

notify pgrst, 'reload schema';
