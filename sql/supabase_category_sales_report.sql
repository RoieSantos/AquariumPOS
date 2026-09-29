-- Category Sales report - per "can you create me a report for accessories or per category".
--
-- Top Selling Items ranks by the line's own "ItemCode" (Pancake's product_display_id) and has no
-- category breakdown. This ranks categories, then the items / variants inside one (e.g.
-- ACCESSORIES), so a line's category is resolved the most specific way available:
--   1. its variant   (OnlineOrderLines."VariationId" -> Variants."CategoryCode")
--   2. its item      (the variant's parent item, else the line's ItemCode -> Items."CategoryCode")
--   3. '(Uncategorized)' - e.g. fee / service lines with no product behind them.
-- The item is the variant's parent (MainItemCode, like supabase_sealant_sales_report.sql), so all
-- variants of one product group under it.
--
-- Same source and rules as admin_get_top_selling_items: OnlineOrderLines x OnlineOrders (online +
-- walk-in), order "Date", cancelled left out, revenue = GrossAmount. Components of a set carry ₱0
-- on their own line, so their revenue sits on the set's line / category.
--
-- One row per warehouse x online/walk-in x category x item x variant; the page filters, rolls up
-- and drills down client-side. Any active staff (is_staff_authorized). Safe to re-run.

drop function if exists public.admin_get_category_sales_report(text, text, date, date);

create or replace function public.admin_get_category_sales_report(
  p_admin_username text,
  p_admin_password text,
  p_date_from date,
  p_date_to date
)
returns table(
  warehouse_name text, is_walkin boolean,
  category_code text, category_name text,
  item_code text, item_name text,
  variant_id text, variant_name text, variant_sku text,
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
    with lines as (
      select l."OrderID" as order_id,
             coalesce(nullif(trim(w."Name"), ''), '(No warehouse)') as wh,
             coalesce(o."ReceivedAtShop", false) as walkin,
             v."VariationId" as var_id,
             v."VariantName" as var_name,
             v."SKU" as var_sku,
             v."CategoryCode" as var_category,
             coalesce(nullif(trim(v."MainItemCode"), ''), nullif(trim(v."ItemCode"), ''), nullif(trim(l."ItemCode"), '')) as code,
             nullif(trim(l."Description"), '') as line_desc,
             coalesce(l."Quantity", 0) as qty,
             coalesce(l."GrossAmount", 0) as amount
      from public."OnlineOrderLines" l
      join public."OnlineOrders" o on o."OrderID" = l."OrderID"
      left join public."Warehouses" w on w."ID" = o."LocationID"
      left join public."Variants" v on v."VariationId" = l."VariationId"
      where o."Date" >= p_date_from and o."Date" <= p_date_to
        and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
    ),
    resolved as (
      select x.order_id, x.wh, x.walkin,
             coalesce(nullif(trim(x.var_category), ''), nullif(trim(i."CategoryCode"), ''), '(Uncategorized)') as cat,
             coalesce(x.code, x.line_desc, '(No item)') as code,
             coalesce(nullif(trim(i."Name"), ''), x.line_desc, x.code, '(No item)') as name,
             x.var_id, x.var_name, x.var_sku, x.qty, x.amount
      from lines x
      left join public."Items" i on i."Code" = x.code
    )
    select r.wh::text, r.walkin,
           r.cat::text, coalesce(nullif(trim(c."Description"), ''), r.cat)::text,
           r.code::text, max(r.name)::text,
           r.var_id::text, max(r.var_name)::text, max(r.var_sku)::text,
           sum(r.qty)::numeric, sum(r.amount)::numeric, count(distinct r.order_id)::int
    from resolved r
    left join public."Categories" c on c."Code" = r.cat
    group by r.wh, r.walkin, r.cat, c."Description", r.code, r.var_id;
end;
$$;

grant execute on function public.admin_get_category_sales_report(text, text, date, date) to anon;

notify pgrst, 'reload schema';
