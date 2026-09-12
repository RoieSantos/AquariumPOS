-- Makes Items."WholesalePrice" editable from Item Setup, per direct request to "indicate the
-- wholesale price of the item" (follow-up to supabase_category_wholesale_flag.sql, which flags
-- which CATEGORIES are wholesale-eligible - this is where the actual per-item price gets entered).
--
-- The column already exists (supabase_warehouses_items_tables.sql) and is also one of Pancake's
-- OptionalItemColumns (OnlinefunctionsEvents.cs), same as "Cost" - admin_set_item_cost
-- (supabase_item_cost_and_po_line_cost.sql) already accepts that a synced column can also be
-- portal-edited, so this follows that exact precedent rather than adding a parallel override
-- column. In practice Pancake has never supplied wholesale prices for these items, so there's
-- nothing to actually collide with today.
--
-- A null/blank price is stored as NULL rather than 0 - "no wholesale price set" and "wholesale
-- price of 0" are different, same reasoning as admin_set_item_cost.
create or replace function public.admin_set_item_wholesale_price(
  p_admin_username text,
  p_admin_password text,
  p_item_code text,
  p_wholesale_price numeric
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_wholesale_price is not null and p_wholesale_price < 0 then
    raise exception 'Wholesale price cannot be negative.';
  end if;

  update public."Items" set "WholesalePrice" = p_wholesale_price where "Code" = p_item_code;
end;
$$;

grant execute on function public.admin_set_item_wholesale_price(text, text, text, numeric) to anon;

-- Bulk wholesale-price import for Item Setup's Export/Import Excel round-trip, per follow-up
-- request to make Wholesale Price re-importable the same way Cost already is. Mirrors
-- admin_bulk_set_item_costs (supabase_item_cost_and_po_line_cost.sql) exactly - same jsonb-array
-- shape, same updated/skipped/errors return, same "missing column vs blank cell" contract: the
-- caller only includes a row here when the imported file actually HAS a Wholesale Price column,
-- so a trimmed-down re-import (Item Code only) never silently wipes wholesale prices off every
-- item it mentions. Within a file that does carry the column, a blank cell is a deliberate "clear
-- this wholesale price" and stores NULL, distinct from a wholesale price of 0.
create or replace function public.admin_bulk_set_item_wholesale_prices(
  p_admin_username text,
  p_admin_password text,
  p_items jsonb
)
returns table(updated_count int, skipped_count int, errors text[])
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row jsonb;
  v_item_code text;
  v_price_text text;
  v_price numeric;
  v_invalid boolean;
  v_updated int := 0;
  v_skipped int := 0;
  v_errors text[] := array[]::text[];
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be a JSON array.';
  end if;

  for v_row in select * from jsonb_array_elements(p_items)
  loop
    v_item_code := trim(coalesce(v_row ->> 'item_code', ''));
    v_price_text := nullif(trim(coalesce(v_row ->> 'wholesale_price', '')), '');

    if v_item_code = '' then
      v_skipped := v_skipped + 1;
      v_errors := v_errors || 'Skipped a row with no Item Code.';
      continue;
    end if;

    if not exists (select 1 from public."Items" where "Code" = v_item_code) then
      v_skipped := v_skipped + 1;
      v_errors := v_errors || (v_item_code || ': item not found - skipped.');
      continue;
    end if;

    v_price := null;
    v_invalid := false;

    if v_price_text is not null then
      begin
        v_price := v_price_text::numeric;
      exception when others then
        v_invalid := true;
        v_errors := v_errors || (v_item_code || ': "' || v_price_text || '" is not a valid wholesale price - skipped.');
      end;

      if not v_invalid and v_price < 0 then
        v_invalid := true;
        v_errors := v_errors || (v_item_code || ': wholesale price cannot be negative - skipped.');
      end if;
    end if;

    if v_invalid then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    update public."Items" set "WholesalePrice" = v_price where "Code" = v_item_code;
    v_updated := v_updated + 1;
  end loop;

  return query select v_updated, v_skipped, v_errors;
end;
$$;

grant execute on function public.admin_bulk_set_item_wholesale_prices(text, text, jsonb) to anon;
