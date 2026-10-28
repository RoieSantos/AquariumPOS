-- Public product page (docs/product.html?code=...) - per "can we make our website like this?"
-- (a Petco-style page per product: photos, price, stock per branch, pickup/delivery, add to cart).
--
-- public_get_product(p_code): one item, no login. Reuses public_list_order_items for the row itself
-- (same IsActive / HideFromSet filters, price, stock_by_location and stock_by_variant as Order Now and
-- Alice - see supabase_chatbot_stock_by_variant.sql), so stock logic stays in one place, and adds the
-- item's category code (as stored, e.g. "Aquarium" - the cart records it like Order Now does) + label
-- for the page's breadcrumb. Returns no row for an inactive/hidden or
-- unknown code (the page shows "not found").
--
-- Run AFTER supabase_chatbot_stock_by_variant.sql. Safe to re-run.

drop function if exists public.public_get_product(text);

create or replace function public.public_get_product(p_code text)
returns table(code text, name text, description text, price numeric, images text, quantity_in_stock int,
              stock_by_location jsonb, stock_by_variant jsonb, category_code text, category_label text)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select p.code, p.name, p.description, p.price, p.images, p.quantity_in_stock,
         p.stock_by_location, p.stock_by_variant,
         trim(i."CategoryCode")::text,
         coalesce(nullif(trim(c."Description"), ''), trim(i."CategoryCode"))::text
  from public."Items" i
  cross join lateral public.public_list_order_items(i."CategoryCode") p
  left join public."Categories" c on c."Code" = i."CategoryCode"
  where i."Code" = trim(p_code)
    and p.code = i."Code"
  limit 1;
$$;

grant execute on function public.public_get_product(text) to anon;

notify pgrst, 'reload schema';

-- Check: a few products as the page will load them (open product.html?code=<code> to see each).
select x.code, x.name, x.category_code, x.category_label, x.price, x.stock_by_location
from (select i."Code" from public."Items" i
      where i."IsActive" is true and i."HideFromSet" is not true
        and upper(trim(coalesce(i."CategoryCode", ''))) in ('SET', 'AQUARIUM', 'STAND')
      order by i."CategoryCode", i."Code" limit 5) s
cross join lateral public.public_get_product(s."Code") x;
