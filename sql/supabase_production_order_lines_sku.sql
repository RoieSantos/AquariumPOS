-- Production Orders: SKU per line - per "I want the maker to see the item / description / SKU /
-- quantity" on My Assignments (online-orders.html, js/onlineOrders.js openProdOrderCard).
--
-- staff_list_production_order_lines: same as supabase_production_variant_colour.sql plus a `sku`
-- column, resolved like the Physical Journal's SKU (supabase_phys_journal_sku_column.sql): the line's
-- variant SKU, else a variant under the same Item Code with a SKU, else Items."SKU", else the Item Code.
--
-- Run AFTER supabase_production_variant_colour.sql (re-running either of those drops the sku column
-- again - just run this one after). Safe to re-run. Until it's run the page falls back to Item Code.

drop function if exists public.staff_list_production_order_lines(text, text, text);

create or replace function public.staff_list_production_order_lines(
  p_admin_username text,
  p_admin_password text,
  p_no text
)
returns table(
  line_no bigint, item_code text, item_name text, variant_id text, variant_name text, description text,
  quantity numeric, qty_output numeric, part text, needs_serial boolean, colour text, sku text
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
           public._production_colour(v."VariantName", v."SKU", vi."Name", l."Description"),
           coalesce(
             nullif(trim(v."SKU"), ''),
             case when l."VariantId" is null then (
               select nullif(trim(vf."SKU"), '')
               from public."Variants" vf
               where vf."ItemCode" = l."ItemCode" and nullif(trim(vf."SKU"), '') is not null
               limit 1
             ) end,
             nullif(trim(i."SKU"), ''),
             l."ItemCode"
           )::text
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
