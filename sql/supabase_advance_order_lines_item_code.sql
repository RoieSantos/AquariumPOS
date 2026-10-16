-- Advance Order card: Item No. shows the real item code - per "i change this to AQ-013 why the item no. is
-- still saying CUSTOMIZED ITEM".
--
-- AdvanceOrderLines."No" is the POS's Category column ("CUSTOMIZED ITEM", "CUSTOM-STICKER"...), not an item
-- code, so the card's Item No. never followed a Change Item (which only swaps the line's VariationId). Now
-- item_no is the item resolved from the line (VariationId first - so a Change Item shows at once - then the
-- old "No"-is-a-code / name matches, same as _advance_order_line_items), falling back to "No" when nothing
-- resolves (and for PAYMENT lines, e.g. CASH). The POS category moves to its own `category` column.
-- "No" itself is left alone: the POS re-sends it every sync, and the serial / production checks read it.
-- The maker part (Tank / Stand) is still worked out from the POS line, unchanged.
--
-- Run AFTER supabase_advance_order_production.sql and supabase_advance_order_sticker_no_serial.sql.
-- Function only - safe to re-run. Needs js/onlineOrders.js ?v=aoitemno1.

drop function if exists public.staff_list_advance_order_lines(text, text, text);

create or replace function public.staff_list_advance_order_lines(p_admin_username text, p_admin_password text, p_no text)
returns table(
  line_no text, type text, item_no text, description text, quantity numeric,
  price numeric, discount numeric, gross_amount numeric, net_amount numeric, part text, category text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._advance_order_can_view(p_admin_username, p_no) then
    raise exception 'Not authorized.';
  end if;
  return query
    select l."LineNo"::text, l."Type"::text,
           coalesce(li.item_code, l."No")::text,
           l."Description"::text, l."Quantity",
           l."Price", l."Discount", l."GrossAmount", l."NetAmount",
           public._online_order_line_part(l."Description", l."No", null),
           l."No"::text
    from public."AdvanceOrderLines" l
    left join public._advance_order_line_items(p_no) li on li.line_no = l."LineNo"
    where l."TransactionNo" = p_no
    order by case when l."LineNo" ~ '^\d+$' then l."LineNo"::numeric end nulls last, l."LineNo";
end;
$$;

grant execute on function public.staff_list_advance_order_lines(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Result: advance order 10538's lines as the card will show them.
select l."LineNo" as line_no, l."Type" as type, l."No" as pos_category,
       coalesce(li.item_code, l."No") as item_no_now, li.resolved_by, l."VariationId" as variation_id, l."Description" as description
from public."AdvanceOrderLines" l
left join public._advance_order_line_items(l."TransactionNo") li on li.line_no = l."LineNo"
where l."TransactionNo" = '10538'
order by l."LineNo";
