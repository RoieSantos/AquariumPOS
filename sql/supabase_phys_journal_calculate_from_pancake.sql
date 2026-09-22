-- Physical Inventory Journal - adds a "Qty. (Calculated) from Pancake (live)" option to Calculate
-- Inventory, per direct request: "can you add an option there to be able to pick the qty. calculated
-- from the pancake first? this way we can get the actual inventory from pancake if the option is
-- true".
--
-- Run AFTER supabase_phys_journal_calculate_stock_sync_filter.sql (the version this redefines).
--
-- OPT-IN, off by default (unchanged behaviour: Qty. (Calculated) comes from the portal's own item
-- ledger, via _ile_balance). Checked, it instead reads each line's CURRENT stock straight from
-- Pancake Cloud (pos.pages.fm) - the same "products/{id} -> variations -> variations_warehouses ->
-- remain_quantity" shape already used and confirmed working by
-- supabase_transfer_line_pancake_stock.sql, batched one HTTP call per distinct Pancake product
-- (not per line/variant) to keep a big run reasonably fast.
--
-- This only changes where the CALCULATED reference number comes from - it is still just a frozen
-- reference figure shown on the worksheet. Posting (admin_post_phys_inventory_journal) always diffs
-- the typed count against the portal's own LIVE ledger balance at post time regardless of this
-- option, exactly as before - that correctness guarantee is untouched.
--
-- Best-effort per item: if Pancake can't be reached, or a specific item/variant isn't found in the
-- response, that one line silently falls back to the portal's own ledger balance (same as the
-- option being off) rather than failing the whole calculate run or leaving the line blank.

drop function if exists public.admin_calculate_phys_inventory(text, text, text, text, text, text, boolean);

create or replace function public.admin_calculate_phys_inventory(
  p_admin_username text,
  p_admin_password text,
  p_batch_name text,
  p_warehouse_id text,
  p_category_code text default null,
  p_search text default null,
  p_only_stock_sync_categories boolean default false,
  p_from_pancake boolean default false
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_batch text := trim(coalesce(p_batch_name, 'DEFAULT'));
  v_warehouse text := trim(coalesce(p_warehouse_id, ''));
  v_count int;
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_product_id text;
  v_response extensions.http_response;
  v_body jsonb;
  v_product jsonb;
  v_variations jsonb;
  v_variation jsonb;
  v_warehouses jsonb;
  v_wh_entry jsonb;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if v_batch = '' then
    raise exception 'A batch name is required.';
  end if;

  if v_warehouse = '' or not exists (select 1 from public."Warehouses" where "ID" = v_warehouse) then
    raise exception 'Pick a location to calculate inventory for.';
  end if;

  create temporary table if not exists tmp_phys_calc_filtered (
    item_code text, variant_id text, product_id text, pancake_variation_id text
  ) on commit drop;
  truncate tmp_phys_calc_filtered;

  create temporary table if not exists tmp_phys_calc_pancake_stock (
    product_id text, variation_id text, warehouse_id text, remain_quantity numeric
  ) on commit drop;
  truncate tmp_phys_calc_pancake_stock;

  -- Same item/variant selection as before (unfiltered-by-warehouse - one key per item/variant),
  -- now also carrying each key's Pancake product id + variation id so the Pancake lookup below can
  -- join back to it.
  insert into tmp_phys_calc_filtered (item_code, variant_id, product_id, pancake_variation_id)
  with variant_counts as (
    select v."ItemCode" as item_code, count(*) as cnt from public."Variants" v group by v."ItemCode"
  ),
  keys as (
    -- An item with 2+ variants: one key per variant.
    select i."Code" as item_code, v."VariationId" as variant_id
    from public."Items" i
    join public."Variants" v on v."ItemCode" = i."Code"
    join variant_counts vc on vc.item_code = i."Code" and vc.cnt >= 2
    where coalesce(i."IsActive", true)
    union all
    -- Everything else (no variants, or exactly one - which is really just the item itself): one
    -- key, no variant. Mirrors _ile_resolve_stock_key's own threshold exactly.
    select i."Code", null
    from public."Items" i
    left join variant_counts vc on vc.item_code = i."Code"
    where coalesce(i."IsActive", true) and coalesce(vc.cnt, 0) < 2
  )
  select k.item_code, k.variant_id,
         coalesce(v."ProductId", i."ProductId"),
         coalesce(k.variant_id, i."VariationId")
  from keys k
  join public."Items" i on i."Code" = k.item_code
  left join public."Variants" v on v."VariationId" = k.variant_id
  left join public."Categories" cat on cat."Code" = i."CategoryCode"
  where (p_category_code is null or trim(p_category_code) = '' or i."CategoryCode" = p_category_code)
    and (not coalesce(p_only_stock_sync_categories, false) or coalesce(cat."IncludeInStockSync", false) is true)
    and (
      p_search is null or trim(p_search) = ''
      or k.item_code ilike '%' || trim(p_search) || '%'
      or i."Name" ilike '%' || trim(p_search) || '%'
      or v."VariantName" ilike '%' || trim(p_search) || '%'
    );

  if coalesce(p_from_pancake, false) then
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

    for v_product_id in
      select distinct f.product_id
      from tmp_phys_calc_filtered f
      where f.product_id is not null and trim(f.product_id) <> ''
    loop
      begin
        select * into v_response from extensions.http_get(
          v_base_url || '/shops/' || v_shop_id || '/products/' || v_product_id || '?api_key=' || v_api_key
        );

        if v_response.status < 200 or v_response.status >= 300 then
          continue; -- that product's lines fall back to the portal's own ledger balance below
        end if;

        v_body := v_response.content::jsonb;
        v_product := case
          when jsonb_typeof(v_body -> 'product') = 'object' then v_body -> 'product'
          when jsonb_typeof(v_body -> 'data') = 'object' then v_body -> 'data'
          else v_body
        end;

        v_variations := case
          when jsonb_typeof(v_product -> 'variations') = 'array' then v_product -> 'variations'
          else '[]'::jsonb
        end;

        for v_variation in select * from jsonb_array_elements(v_variations)
        loop
          v_warehouses := case
            when jsonb_typeof(v_variation -> 'variations_warehouses') = 'array' then v_variation -> 'variations_warehouses'
            else '[]'::jsonb
          end;

          for v_wh_entry in select * from jsonb_array_elements(v_warehouses)
          loop
            insert into tmp_phys_calc_pancake_stock values (
              v_product_id,
              coalesce(nullif(v_variation ->> 'id', ''), nullif(v_variation ->> 'variation_id', '')),
              coalesce(nullif(v_wh_entry ->> 'warehouse_id', ''), nullif(v_wh_entry ->> 'warehouseId', '')),
              nullif(coalesce(v_wh_entry ->> 'remain_quantity', v_wh_entry ->> 'remainQuantity', v_wh_entry ->> 'quantity'), '')::numeric
            );
          end loop;
        end loop;
      exception when others then
        continue; -- best-effort; that product's lines fall back to the portal's own ledger balance below
      end;
    end loop;
  end if;

  insert into public."PhysInventoryJournalLines"
    ("BatchName", "ItemCode", "VariantId", "WarehouseId", "QtyCalculated", "UpdatedAtUtc", "UpdatedBy")
  select v_batch, f.item_code, f.variant_id, v_warehouse,
         case
           when coalesce(p_from_pancake, false) then
             coalesce(
               (select s.remain_quantity from tmp_phys_calc_pancake_stock s
                where s.product_id = f.product_id and s.warehouse_id = v_warehouse
                  and s.variation_id = f.pancake_variation_id
                limit 1),
               public._ile_balance(f.item_code, f.variant_id, v_warehouse)
             )
           else public._ile_balance(f.item_code, f.variant_id, v_warehouse)
         end,
         now(), p_admin_username
  from tmp_phys_calc_filtered f
  on conflict ("BatchName", "ItemCode", (coalesce("VariantId", '')), "WarehouseId")
  do update set
    "QtyCalculated" = case when public."PhysInventoryJournalLines"."QtyCounted" is null
                            then excluded."QtyCalculated"
                            else public."PhysInventoryJournalLines"."QtyCalculated" end,
    "UpdatedAtUtc" = now(),
    "UpdatedBy" = excluded."UpdatedBy";

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function public.admin_calculate_phys_inventory(text, text, text, text, text, text, boolean, boolean) to anon;

notify pgrst, 'reload schema';

-- Verification. Expect exactly one row, 8 arguments, has_anon_execute = true.
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'admin_calculate_phys_inventory';
