-- Per direct follow-up request, GMA Conversations' order management (the "Products" section inside
-- an expanded order card, docs/gma-conversations.html) now also shows each line's Pancake
-- VariationId - the exact same value _push_automated_order_to_pancake (supabase_gma_conversation_
-- order_line_notes.sql) actually sends as that line's 'variation_id' field, using the identical
-- join/match predicate (Items.Code matched against ItemCode, falling back to CategoryCode) so what
-- staff see here is guaranteed to match what really goes to Pancake, not a separate guess.
--
-- Note (see supabase_diagnose_po_receive_variant_stock.sql's own header): Items."VariationId" is a
-- single REPRESENTATIVE variation for that whole product, not necessarily a specific
-- color/size/SKU a customer picked - AutomatedOrderLines only ever stores a product-level ItemCode
-- (from public_search_items in the Create Order tab), never a specific Variants.VariationId. This
-- is exactly the same representative id Pancake itself will receive, which is what makes it useful
-- for staff to cross-check here - it just isn't a promise of a specific variant choice.

drop function if exists public.admin_list_automated_order_lines(text, text, text);

create or replace function public.admin_list_automated_order_lines(p_admin_username text, p_admin_password text, p_order_no text)
returns table(entry_no bigint, category_code text, item_code text, item_name text, quantity int, price numeric, notes text, variation_id text)
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
      (
        select i."VariationId"::text
        from public."Items" i
        where i."Code" = coalesce(nullif(l."ItemCode", ''), nullif(l."CategoryCode", ''))
           or (l."ItemCode" is null and i."Name" = nullif(l."CategoryCode", ''))
        limit 1
      )
    from public."AutomatedOrderLines" l
    where l."OrderNo" = p_order_no
    order by l."EntryNo";
end;
$$;

grant execute on function public.admin_list_automated_order_lines(text, text, text) to anon;
