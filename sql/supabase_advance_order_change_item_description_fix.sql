-- Change Item: a swap to a DIFFERENT product gets that product's name as the line text - per the
-- screenshot of advance order 10971 ("Now: FROK-SUBMERSIBLE-LIGHT (4FT-WHITE) - F-087" with
-- "F-087 - TIGER-BARB" as Current).
--
-- Bug: _order_line_variant_swap_description only swapped the SKU / variant part inside the POS text
-- (right for "AST-003-BlackPaint -> AST-003-WhitePaint", same product), so FROK light -> Tiger Barb kept
-- the light's name with just the code changed to F-087. The line WAS changed (Current = Tiger Barb,
-- stock / serials use it) - only its text was wrong.
-- Now: the in-text swap only when old and new are variants of the SAME product; otherwise the new
-- product's label ("F-087 - TIGER-BARB").
--
-- Also:
--   - repairs advance lines already changed to another product (line text + its override text),
--   - staff_list_advance_order_line_changes: the "Changed" badge on the advance order card's lines
--     (what it was, who changed it, when).
--
-- Run AFTER supabase_advance_order_change_item_quantity.sql. Safe to re-run.
-- Needs js/onlineOrders.js ?v=advchgfix1.

-- ============================================================================
-- 1. Line text after a swap
-- ============================================================================

create or replace function public._order_line_variant_swap_description(p_desc text, p_old_variation text, p_new_variation text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_old record;
  v_new record;
  v_desc text := coalesce(p_desc, '');
begin
  select * into v_new from public._order_line_variant_candidates() c where c.variation_id = p_new_variation limit 1;
  if not found then
    return p_desc;
  end if;
  select * into v_old from public._order_line_variant_candidates() c where c.variation_id = p_old_variation limit 1;
  -- (this file) Only a variant of the SAME product keeps the POS wording with the variant part swapped.
  if found and upper(coalesce(v_old.main_item_code, '')) = upper(coalesce(v_new.main_item_code, ''))
     and coalesce(v_old.main_item_code, '') <> '' then
    if v_old.sku <> '' and v_new.sku <> '' and v_old.sku <> v_new.sku and position(v_old.sku in v_desc) > 0 then
      return replace(v_desc, v_old.sku, v_new.sku);
    elsif v_old.tag is not null and v_new.tag is not null and v_old.tag <> v_new.tag and position(v_old.tag in v_desc) > 0 then
      return replace(v_desc, v_old.tag, v_new.tag);
    elsif v_old.name <> '' and position(v_old.name in v_desc) > 0 then
      return replace(v_desc, v_old.name, v_new.label);
    end if;
  end if;
  return v_new.label;
end;
$$;

revoke execute on function public._order_line_variant_swap_description(text, text, text) from public, anon, authenticated;

-- ============================================================================
-- 2. Repair: advance lines already changed to a different product
-- ============================================================================

do $$
declare
  r record;
begin
  for r in
    select distinct on (c."OrderNo", coalesce(c."NewLineNo", c."LineNo"))
           c."OrderNo" as no, coalesce(c."NewLineNo", c."LineNo") as line_no, c."NewVariationId" as new_var,
           o.main_item_code as old_main, n.main_item_code as new_main, n.label as new_label
    from public."OrderLineVariantChanges" c
    left join lateral (select x.main_item_code from public._order_line_variant_candidates() x
                       where x.variation_id = c."OldVariationId" limit 1) o on true
    join lateral (select x.main_item_code, x.label from public._order_line_variant_candidates() x
                  where x.variation_id = c."NewVariationId" limit 1) n on true
    where c."OrderKind" = 'Advance'
    order by c."OrderNo", coalesce(c."NewLineNo", c."LineNo"), c."Id" desc
  loop
    continue when upper(coalesce(r.old_main, '')) = upper(coalesce(r.new_main, '')) and coalesce(r.old_main, '') <> '';
    update public."AdvanceOrderLineOverrides" set "Description" = left(r.new_label, 500)
     where "TransactionNo" = r.no and "LineNo" = r.line_no and "VariationId" = r.new_var;
    update public."AdvanceOrderLines" set "Description" = left(r.new_label, 500)
     where "TransactionNo" = r.no and "LineNo" = r.line_no and "VariationId" = r.new_var
       and "Description" is distinct from left(r.new_label, 500);
  end loop;
end;
$$;

-- ============================================================================
-- 3. The "Changed" badge: every Change Item on an advance order's lines
-- ============================================================================

create or replace function public.staff_list_advance_order_line_changes(
  p_admin_username text,
  p_admin_password text,
  p_no text
)
returns table(line_no text, old_description text, new_description text, quantity numeric,
              changed_by text, changed_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return query
    select coalesce(c."NewLineNo", c."LineNo")::text, c."OldDescription"::text, c."NewDescription"::text,
           c."Quantity", c."ChangedBy"::text, c."ChangedAtUtc"
    from public."OrderLineVariantChanges" c
    where c."OrderKind" = 'Advance' and c."OrderNo" = p_no
    order by c."Id";
end;
$$;

grant execute on function public.staff_list_advance_order_line_changes(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Result: every advance order line changed so far, with the text it shows now.
select c."OrderNo" as advance_no, coalesce(c."NewLineNo", c."LineNo") as line_no,
       c."OldDescription" as was, l."Description" as now_shows, c."Quantity" as qty,
       c."ChangedBy" as changed_by, c."ChangedAtUtc" as changed_at
from public."OrderLineVariantChanges" c
left join public."AdvanceOrderLines" l on l."TransactionNo" = c."OrderNo" and l."LineNo" = coalesce(c."NewLineNo", c."LineNo")
where c."OrderKind" = 'Advance'
order by c."Id" desc;
