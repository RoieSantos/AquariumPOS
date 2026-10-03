-- Automated Orders page (docs/automated-orders.html): show each line's SKU and variant name.
-- Run AFTER supabase_gma_conversation_order_line_variant_selection.sql (adds AutomatedOrderLines."VariationId").
--
-- Redefines admin_list_automated_order_lines with two extra columns appended at the end, so existing
-- callers (docs/js/gmaConversations.js reads rows as objects) are unaffected:
--   sku          - the picked variant's Variants."SKU", else the product's Items."SKU"
--   variant_name - the picked/resolved variant's Variants."VariantName" (null when there is none)
-- The variation_id resolution is unchanged: the line's own VariationId, else Items."VariationId".
-- Safe to re-run.

drop function if exists public.admin_list_automated_order_lines(text, text, text);

create or replace function public.admin_list_automated_order_lines(p_admin_username text, p_admin_password text, p_order_no text)
returns table(entry_no bigint, category_code text, item_code text, item_name text, quantity int, price numeric, notes text, variation_id text, sku text, variant_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      l."EntryNo",
      l."CategoryCode"::text,
      l."ItemCode"::text,
      l."ItemName"::text,
      l."Quantity",
      l."Price",
      l."Notes"::text,
      coalesce(nullif(l."VariationId", ''), i."VariationId"::text),
      coalesce(nullif(trim(v."SKU"), ''), nullif(trim(i."SKU"), ''))::text,
      nullif(trim(v."VariantName"), '')::text
    from public."AutomatedOrderLines" l
    left join lateral (
      select it."VariationId", it."SKU"
      from public."Items" it
      where it."Code" = coalesce(nullif(l."ItemCode", ''), nullif(l."CategoryCode", ''))
         or (l."ItemCode" is null and it."Name" = nullif(l."CategoryCode", ''))
      limit 1
    ) i on true
    left join public."Variants" v
      on v."VariationId" = coalesce(nullif(l."VariationId", ''), i."VariationId"::text)
    where l."OrderNo" = p_order_no
    order by l."EntryNo";
end;
$$;

grant execute on function public.admin_list_automated_order_lines(text, text, text) to anon;
