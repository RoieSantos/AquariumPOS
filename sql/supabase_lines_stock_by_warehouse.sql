-- "Stock" FactBox on the Online Order, Advance Order, Transfer Order and Purchase Order cards - per
-- "can we show in the factbox in the right if there is available stocks per item? so the user can see
-- if there are no stocks or have?".
--
-- staff_get_lines_stock_by_warehouse: on-hand per warehouse for many document lines in ONE call (the
-- Item Setup card's staff_get_item_stock_by_warehouse does one item at a time).
--   p_lines = [{"key": "<line key>", "item_code": "...", "variant_id": "..." or null}, ...]
-- Each line's item is resolved the same way as staff_get_online_order_stock_status: the variant's
-- ItemCode (Variants.VariationId), else Items.Code (matched on Code or VariationId), else nothing -
-- lines that aren't an item (custom tanks, fees, ...) return no rows.
-- Stock source, same as Alice (supabase_chatbot_stock_from_serials.sql):
--   Items.CategoryCode AQUARIUM / STAND / SUMP -> ItemSerialTracking Status = 'IN_STOCK', by Location
--                                                 (= warehouse name), source = 'serials'
--   everything else                            -> ItemLedgerEntries per WarehouseId, source = 'ledger'
-- With a variant: only that variant's stock. Without: every variant of the item combined.
-- A warehouse is listed if it's an active stock warehouse OR holds stock of the line's item.
--
-- Read-only, staff-level auth. Run in the Supabase SQL Editor (needs supabase_item_ledger_entries.sql).
-- Safe to re-run.

drop function if exists public.staff_get_lines_stock_by_warehouse(text, text, jsonb);

create or replace function public.staff_get_lines_stock_by_warehouse(
  p_admin_username text,
  p_admin_password text,
  p_lines jsonb
)
returns table(line_key text, item_code text, variant_id text, source text,
              warehouse_id text, warehouse_name text, is_stock_warehouse boolean, quantity numeric)
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
    with input as (
      select x->>'key' as k,
             nullif(trim(x->>'item_code'), '') as raw_item,
             nullif(trim(x->>'variant_id'), '') as var
      from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) x
    ),
    resolved as (
      select inp.k, inp.var,
             coalesce(nullif(trim(v."ItemCode"), ''), nullif(trim(i."Code"), '')) as item,
             nullif(trim(v."MainItemCode"), '') as main_item
      from input inp
      left join lateral (
        select v0."ItemCode", v0."MainItemCode" from public."Variants" v0
        where inp.var is not null and v0."VariationId" = inp.var
        limit 1
      ) v on true
      left join lateral (
        select i0."Code" from public."Items" i0
        where inp.raw_item is not null and (i0."Code" = inp.raw_item or i0."VariationId" = inp.raw_item)
        order by (i0."Code" = inp.raw_item) desc
        limit 1
      ) i on true
    ),
    lines as (
      select r.k, r.var, r.item,
             upper(trim(coalesce(ic."CategoryCode", mc."CategoryCode", ''))) in ('AQUARIUM', 'STAND', 'SUMP') as by_serial
      from resolved r
      left join public."Items" ic on ic."Code" = r.item
      left join public."Items" mc on mc."Code" = r.main_item
      where r.item is not null
    ),
    -- every item code a line covers: the item itself, plus (no variant picked) its variants' own codes
    line_codes as (
      select l.k, l.item as code from lines l
      union
      select l.k, v."ItemCode" from lines l
      join public."Variants" v on v."MainItemCode" = l.item
      where l.var is null and nullif(trim(v."ItemCode"), '') is not null
    ),
    ledger as (
      select l.k, e."WarehouseId"::text as wid, sum(e."Quantity") as qty
      from lines l
      join line_codes lc on lc.k = l.k
      join public."ItemLedgerEntries" e on e."ItemCode" = lc.code
      where not l.by_serial
        -- a variant is booked either under its own ItemCode (VariantId empty) or under the shared
        -- item with VariantId set (items with 2+ variants, _ile_resolve_stock_key)
        and (l.var is null or coalesce(e."VariantId", '') in ('', l.var))
      group by l.k, e."WarehouseId"
    ),
    serials as (
      select l.k, w."ID"::text as wid, count(*)::numeric as qty
      from lines l
      join line_codes lc on lc.k = l.k
      join public."ItemSerialTracking" s
        on s."ItemCode" = lc.code and s."Status" = 'IN_STOCK'
       and (l.var is null or coalesce(nullif(trim(s."VariantCode"), ''), '') in ('', l.var))
      join public."Warehouses" w on lower(trim(w."Name")) = lower(trim(s."Location"))
      where l.by_serial
      group by l.k, w."ID"
    ),
    balances as (
      select * from ledger
      union all
      select * from serials
    )
    select l.k, l.item, l.var,
           case when l.by_serial then 'serials' else 'ledger' end,
           w."ID"::text, coalesce(w."Name", w."ID")::text,
           coalesce(w."IsActive", true) and coalesce(w."IsStockWarehouse", false),
           coalesce(b.qty, 0)::numeric
    from lines l
    cross join public."Warehouses" w
    left join balances b on b.k = l.k and b.wid = w."ID"::text
    where (coalesce(w."IsActive", true) and coalesce(w."IsStockWarehouse", false)) or coalesce(b.qty, 0) <> 0
    order by l.k, w."Name";
end;
$$;

grant execute on function public.staff_get_lines_stock_by_warehouse(text, text, jsonb) to anon;
