-- Purchase Order lines show the item's selling price next to Unit Cost - per "in the purchase order
-- lines. can you show the price too on how much we are selling the item".
--
-- Read-only lookup, kept separate from staff_list_purchase_order_lines on purpose: that function has
-- several superseding versions (see supabase_item_cost_and_po_line_cost.sql's header), and widening
-- its RETURN TABLE again would be one more file that reverts the others if re-run. This one is used
-- by both the existing-order grid and the New Purchase Order grid (whose lines are not saved yet).
--
-- Price = the variant's own Price when the line is on a variant, else Items."Price" (the store
-- price the POS sells at), per base unit. js/purchaseOrders.js restates it per the line's UoM.
-- Safe to re-run.

create or replace function public.staff_get_selling_prices(
  p_admin_username text,
  p_admin_password text,
  p_lines jsonb  -- [{ "item_code": "...", "variant_id": "..." }, ...]
)
returns table(item_code text, variant_id text, price numeric)
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
    select distinct on (l.item_code, l.variant_id)
           l.item_code, l.variant_id,
           coalesce(v."Price", i."Price")::numeric
      from (
        select nullif(trim(coalesce(x ->> 'item_code', '')), '') as item_code,
               coalesce(nullif(trim(coalesce(x ->> 'variant_id', '')), ''), '') as variant_id
          from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) x
      ) l
      left join public."Variants" v on l.variant_id <> '' and v."VariationId" = l.variant_id
      left join public."Items" i on i."Code" = l.item_code
     where l.item_code is not null
     order by l.item_code, l.variant_id;
end;
$$;

grant execute on function public.staff_get_selling_prices(text, text, jsonb) to anon;
