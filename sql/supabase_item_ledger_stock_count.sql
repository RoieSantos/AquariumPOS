-- Item Ledger - STOCK COUNT import + the "start posting sales" switch, per "i want the portal to be
-- the source of truth ... i want everything to be monitored as of the moment".
--
-- This is how the ledger gets its starting stock WITHOUT reading Pancake: upload a count (a CSV -
-- from a physical stock take, or an export you already have) on the Item Ledger Entries page. Run
-- AFTER supabase_item_ledger_entries.sql, supabase_item_ledger_hooks.sql and
-- supabase_item_ledger_sales.sql.
--
-- "SET TO WHAT WAS COUNTED", NOT "ADD"
-- Each row says "warehouse W has N of item I". The ledger is brought to exactly N by posting only
-- the DIFFERENCE from what it already holds (a Positive or Negative Adjmt.). That makes it safe both
-- ways:
--   * First load (ledger empty): the difference is the whole quantity = an opening balance.
--   * Any later stock take: the difference is the variance the count found.
--   * Uploading the same file twice: the second time every difference is 0, so nothing is posted -
--     a double-click or a re-upload can never double the stock.
-- Rows are matched by what a spreadsheet naturally has: an item's Code or SKU (a variant's SKU also
-- works on its own), an optional variant (id, SKU or name), and a warehouse's Name or ID.
--
-- PREVIEW FIRST, ALL-OR-NOTHING
-- p_dry_run = true validates every row and returns what WOULD change, writing nothing. A real run
-- refuses if any row has an error, so a file is either fully applied or not at all.

drop function if exists public.admin_apply_item_stock_count(text, text, jsonb, date, text, boolean);

create or replace function public.admin_apply_item_stock_count(
  p_admin_username text,
  p_admin_password text,
  p_rows jsonb,
  p_posting_date date,
  p_reason text,
  p_dry_run boolean default true
)
returns table(
  row_no int, item_input text, variant_input text, warehouse_input text, counted_qty numeric,
  item_code text, item_name text, variant_id text, variant_name text,
  warehouse_id text, warehouse_name text,
  current_qty numeric, difference numeric, error text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_el jsonb;
  v_results jsonb := '[]'::jsonb;
  v_seen text[] := array[]::text[];
  v_error_count int := 0;
  v_row_no int;
  v_item_in text;
  v_variant_in text;
  v_warehouse_in text;
  v_qty numeric;
  v_qty_text text;
  v_n int;
  v_code text;
  v_pick_variant text;
  v_wh_id text;
  v_wh_name text;
  v_key record;
  v_current numeric;
  v_diff numeric;
  v_err text;
  v_item_name text;
  v_variant_name text;
  v_key_text text;
  v_doc_no text;
  v_transaction_no bigint;
  v_r record;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'The count has no rows.';
  end if;

  if jsonb_array_length(p_rows) > 5000 then
    raise exception 'A count is limited to 5000 rows at a time - split the file.';
  end if;

  if not coalesce(p_dry_run, true) and (p_reason is null or trim(p_reason) = '') then
    raise exception 'A reason is required (e.g. "Opening balance" or "Cycle count").';
  end if;

  -- ---------------------------------------------------------------- pass 1: validate every row
  for v_el in select * from jsonb_array_elements(p_rows)
  loop
    v_err := null;
    v_code := null; v_pick_variant := null; v_wh_id := null; v_wh_name := null;
    v_item_name := null; v_variant_name := null; v_current := null; v_diff := null; v_qty := null;

    v_row_no := coalesce(nullif(v_el ->> 'row', '')::int, 0);
    v_item_in := nullif(trim(coalesce(v_el ->> 'item', '')), '');
    v_variant_in := nullif(trim(coalesce(v_el ->> 'variant', '')), '');
    v_warehouse_in := nullif(trim(coalesce(v_el ->> 'warehouse', '')), '');
    v_qty_text := nullif(trim(coalesce(v_el ->> 'quantity', '')), '');

    -- quantity
    begin
      v_qty := v_qty_text::numeric;
    exception when others then
      v_qty := null;
    end;

    if v_item_in is null then
      v_err := 'Item is missing.';
    elsif v_warehouse_in is null then
      v_err := 'Warehouse is missing.';
    elsif v_qty is null then
      v_err := 'Quantity is missing or not a number.';
    elsif v_qty < 0 then
      v_err := 'Quantity cannot be negative.';
    end if;

    -- item: Code, then SKU, then a variant's own SKU
    if v_err is null then
      select count(*), min(i."Code") into v_n, v_code from public."Items" i where lower(i."Code") = lower(v_item_in);

      if v_n = 0 then
        select count(*), min(i."Code") into v_n, v_code from public."Items" i
          where nullif(trim(i."SKU"), '') is not null and lower(trim(i."SKU")) = lower(v_item_in);
        if v_n > 1 then
          v_err := 'More than one item has SKU "' || v_item_in || '" - use the Item Code.';
        end if;
      end if;

      if v_err is null and v_n = 0 then
        select count(*), min(v."VariationId") into v_n, v_pick_variant from public."Variants" v
          where nullif(trim(v."SKU"), '') is not null and lower(trim(v."SKU")) = lower(v_item_in);
        if v_n = 1 then
          select coalesce(v."ItemCode", v."MainItemCode") into v_code from public."Variants" v where v."VariationId" = v_pick_variant;
        elsif v_n > 1 then
          v_err := 'More than one variant has SKU "' || v_item_in || '" - use the Item Code and Variant columns.';
        end if;
      end if;

      if v_err is null and v_code is null then
        v_err := 'No item with Code or SKU "' || v_item_in || '".';
      end if;
    end if;

    -- variant (only if given and not already fixed by a variant-SKU match)
    if v_err is null and v_variant_in is not null and v_pick_variant is null then
      select count(*), min(v."VariationId") into v_n, v_pick_variant from public."Variants" v
        where (v."ItemCode" = v_code or v."MainItemCode" = v_code)
          and (v."VariationId" = v_variant_in
               or lower(trim(coalesce(v."SKU", ''))) = lower(v_variant_in)
               or lower(trim(coalesce(v."VariantName", ''))) = lower(v_variant_in));
      if v_n = 0 then
        v_err := 'Variant "' || v_variant_in || '" was not found on item ' || v_code || '.';
        v_pick_variant := null;
      elsif v_n > 1 then
        v_err := 'More than one variant of ' || v_code || ' matches "' || v_variant_in || '" - use its Variation ID or SKU.';
        v_pick_variant := null;
      end if;
    end if;

    -- warehouse: ID or Name
    if v_err is null then
      select count(*), min(w."ID"), min(w."Name") into v_n, v_wh_id, v_wh_name from public."Warehouses" w
        where lower(w."ID") = lower(v_warehouse_in) or lower(trim(coalesce(w."Name", ''))) = lower(v_warehouse_in);
      if v_n = 0 then
        v_err := 'No warehouse "' || v_warehouse_in || '".';
      elsif v_n > 1 then
        v_err := 'More than one warehouse matches "' || v_warehouse_in || '" - use the Warehouse ID.';
      end if;
    end if;

    -- normalise to the ledger's stock key (a multi-variant item must say which variant)
    if v_err is null then
      begin
        select k.item_code, k.variant_id into v_key from public._ile_resolve_stock_key(v_code, v_pick_variant) k;
      exception when others then
        v_err := sqlerrm;
      end;
    end if;

    if v_err is null then
      v_key_text := v_key.item_code || '|' || coalesce(v_key.variant_id, '') || '|' || v_wh_id;
      if v_key_text = any(v_seen) then
        v_err := 'This item/variant/warehouse appears more than once in the file.';
      else
        v_seen := v_seen || v_key_text;
        v_current := public._ile_balance(v_key.item_code, v_key.variant_id, v_wh_id);
        v_diff := v_qty - v_current;
        select coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), i."Code") into v_item_name
          from public."Items" i where i."Code" = v_key.item_code;
        select v."VariantName" into v_variant_name from public."Variants" v where v."VariationId" = v_key.variant_id;
      end if;
    end if;

    if v_err is not null then
      v_error_count := v_error_count + 1;
    end if;

    -- Keys match the r_* column names read back by jsonb_to_recordset below.
    v_results := v_results || jsonb_build_object(
      'r_row', v_row_no, 'r_item_in', v_item_in, 'r_variant_in', v_variant_in, 'r_wh_in', v_warehouse_in,
      'r_counted', v_qty,
      'r_item_code', case when v_err is null then v_key.item_code end,
      'r_item_name', v_item_name,
      'r_variant_id', case when v_err is null then v_key.variant_id end,
      'r_variant_name', v_variant_name,
      'r_wh_id', v_wh_id, 'r_wh_name', v_wh_name,
      'r_current', v_current, 'r_diff', v_diff, 'r_error', v_err
    );
  end loop;

  -- ---------------------------------------------------------------- pass 2: post (real run only)
  if not coalesce(p_dry_run, true) then
    if v_error_count > 0 then
      raise exception '% row(s) have errors - fix the file and preview again. Nothing was posted.', v_error_count;
    end if;

    v_transaction_no := nextval('public.ile_transaction_no_seq');
    v_doc_no := 'COUNT-' || lpad(v_transaction_no::text, 6, '0');

    for v_r in
      select * from jsonb_to_recordset(v_results)
        as x(r_item_code text, r_variant_id text, r_wh_id text, r_diff numeric)
    loop
      if coalesce(v_r.r_diff, 0) <> 0 then
        perform public._ile_post(
          case when v_r.r_diff > 0 then 'Positive Adjmt.' else 'Negative Adjmt.' end,
          v_r.r_item_code, v_r.r_variant_id, v_r.r_wh_id, v_r.r_diff,
          coalesce(p_posting_date, public._ile_today()), 'Stock Count', v_doc_no, trim(p_reason),
          v_transaction_no, p_admin_username
        );
      end if;
    end loop;
  end if;

  return query
    select x.r_row, x.r_item_in, x.r_variant_in, x.r_wh_in, x.r_counted,
           x.r_item_code, x.r_item_name, x.r_variant_id, x.r_variant_name,
           x.r_wh_id, x.r_wh_name, x.r_current, x.r_diff, x.r_error
    from jsonb_to_recordset(v_results) as x(
      r_row int, r_item_in text, r_variant_in text, r_wh_in text, r_counted numeric,
      r_item_code text, r_item_name text, r_variant_id text, r_variant_name text,
      r_wh_id text, r_wh_name text, r_current numeric, r_diff numeric, r_error text
    );
end;
$$;

grant execute on function public.admin_apply_item_stock_count(text, text, jsonb, date, text, boolean) to anon;

-- ============================================================================
-- Sales posting switch
-- ============================================================================

drop function if exists public.admin_get_item_ledger_setup(text, text);

create or replace function public.admin_get_item_ledger_setup(
  p_admin_username text,
  p_admin_password text
)
returns table(sales_posting_start_utc timestamptz, ledger_entry_count bigint)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select (select s."SalesPostingStartUtc" from public."ItemLedgerSetup" s limit 1),
           (select count(*) from public."ItemLedgerEntries");
end;
$$;

grant execute on function public.admin_get_item_ledger_setup(text, text) to anon;

drop function if exists public.admin_start_item_ledger_sales_posting(text, text);

-- Turns sales posting ON from this moment: orders confirmed from now on take their stock out of the
-- ledger (earlier orders are assumed to already be reflected in the stock you counted). Also
-- recomputes every item's catalogue stock figure (Items."QuantityInStock", what Order Now's "In
-- stock" and the AI bot read) from the ledger, so a stale figure from the old Pancake feed can't
-- keep saying "In stock" for something the portal has none of.
--
-- Deliberately a one-way, once-only action, and refused on an empty ledger: starting it before the
-- stock is loaded would drive every item negative as orders come in.
create or replace function public.admin_start_item_ledger_sales_posting(
  p_admin_username text,
  p_admin_password text
)
returns timestamptz
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_existing timestamptz;
  v_start timestamptz := now();
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select s."SalesPostingStartUtc" into v_existing from public."ItemLedgerSetup" s limit 1;
  if v_existing is not null then
    raise exception 'Sales posting was already started at %.', v_existing;
  end if;

  if not exists (select 1 from public."ItemLedgerEntries") then
    raise exception 'Load your stock first (upload a stock count) - starting sales posting on an empty ledger would drive every item negative.';
  end if;

  update public."ItemLedgerSetup" set "SalesPostingStartUtc" = v_start, "UpdatedAtUtc" = now();
  perform public._ile_sync_all_item_quantities();

  return v_start;
end;
$$;

grant execute on function public.admin_start_item_ledger_sales_posting(text, text) to anon;

notify pgrst, 'reload schema';
