-- Advance Orders: Exchange - one or more lines (or part of their quantity) traded for one or MORE other items,
-- by value - per "if this one is changed.. how can we know how many tigerbarb is needed?" / "what if multiple
-- items will be exchange to a specific item?" / "can we add more products and adjust the price?" /
-- "Must equal value".
--
-- staff_exchange_advance_order_lines(p_no, p_sources [{line_no, quantity}], p_targets [{variation_id, quantity, price}]):
--   - each source line goes down by its quantity (to 0 is fine), with its share of Discount / Gross / Net,
--   - each target becomes a new line "<first source LineNo>-X<n>": quantity x the price staff set (list price
--     by default). The new lines must add up to the exchange value (the sources' Net share) - prices are how
--     the deal is settled (the page has "Fit to value"). The last line takes the rounding (at most 1 centavo
--     per unit), so the order's Net total, balance and payments never move. New lines carry no discount
--     (Gross = Net = quantity x price).
--   Same rules as Change Item: before To Ship, no serial tagged to a source's item, Super User / Sales User /
--   Production Manager, ITEM lines only.
--
-- POS sync: a POS line's lower quantity is kept in AdvanceOrderLineOverrides (PosQuantity / Quantity / amounts,
-- supabase_advance_order_change_item_quantity.sql's trigger); a portal "-X" line is edited directly (deleted
-- when it reaches 0). New "-X" lines are never sent by the POS, so they stay. The Item Ledger follows on its own.
-- Logged in OrderLineVariantChanges: one row per source line and one per new line (each shows the Changed
-- badge on its own line).
--
-- Run AFTER supabase_advance_order_change_item_quantity.sql and
-- supabase_advance_order_change_item_description_fix.sql. Safe to re-run.
-- Needs js/onlineOrders.js ?v=advexch2.

-- ============================================================================
-- 1. Exchange
-- ============================================================================

drop function if exists public.staff_exchange_advance_order_lines(text, text, text, jsonb, text, numeric);

create or replace function public.staff_exchange_advance_order_lines(
  p_admin_username text,
  p_admin_password text,
  p_no text,
  p_sources jsonb,               -- [{"line_no": "5", "quantity": 1}, ...]
  p_targets jsonb                -- [{"variation_id": "...", "quantity": 20, "price": 49}, ...]
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_src record;
  v_tgt record;
  v_line public."AdvanceOrderLines";
  v_first public."AdvanceOrderLines";
  v_new record;
  v_old_variation text;
  v_old_item text;
  v_serial text;
  v_total numeric;
  v_ratio numeric;
  v_sign numeric;
  v_s_disc numeric;
  v_s_gross numeric;
  v_s_net numeric;
  v_value numeric := 0;
  v_targets_total numeric;
  v_last_qty numeric;
  v_target_count int;
  v_amount numeric;
  v_base text;
  v_line_no text;
  v_n int := 0;
  v_count int := 0;
  v_given text := '';
  v_got text := '';
  v_new_lines jsonb := '[]'::jsonb;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._can_change_advance_order_line_item(p_admin_username) then
    raise exception 'Only a Super User, Sales User or Production Manager can exchange advance order items.';
  end if;

  if exists (select 1 from public."AdvanceOrderProduction" p where p."TransactionNo" = p_no and p."ToShipAtUtc" is not null) then
    raise exception 'Advance order % is already at To Ship or later - Undo Stage back before To Ship first, then exchange.', p_no;
  end if;

  if p_sources is null or jsonb_typeof(p_sources) <> 'array' or jsonb_array_length(p_sources) = 0 then
    raise exception 'Tick at least one line the customer is giving up.';
  end if;
  if p_targets is null or jsonb_typeof(p_targets) <> 'array' or jsonb_array_length(p_targets) = 0 then
    raise exception 'Add at least one item the customer gets.';
  end if;
  if exists (select 1 from jsonb_to_recordset(p_sources) as x(line_no text, quantity numeric)
             group by x.line_no having count(*) > 1) then
    raise exception 'A line is listed twice.';
  end if;
  if exists (select 1 from jsonb_to_recordset(p_targets) as x(variation_id text, quantity numeric, price numeric)
             where coalesce(x.quantity, 0) <= 0 or x.price is null or x.price < 0) then
    raise exception 'Every new item needs a quantity (more than 0) and a price.';
  end if;
  if exists (select 1 from jsonb_to_recordset(p_targets) as x(variation_id text, quantity numeric, price numeric)
             where not exists (select 1 from public._order_line_variant_candidates() c where c.variation_id = trim(coalesce(x.variation_id, '')))) then
    raise exception 'A new item isn''t linked to a Pancake variant - pick another one.';
  end if;

  -- ---- What's given up: validate every source and add up its value first (nothing changes yet).
  for v_src in
    select x.line_no, x.quantity
    from jsonb_array_elements(p_sources) with ordinality as e(j, ord)
    cross join lateral jsonb_to_record(e.j) as x(line_no text, quantity numeric)
    order by e.ord
  loop
    select * into v_line from public."AdvanceOrderLines" where "TransactionNo" = p_no and "LineNo" = v_src.line_no for update;
    if not found then
      raise exception 'Line % is no longer on advance order % - close and reopen the order.', v_src.line_no, p_no;
    end if;
    if upper(coalesce(v_line."Type", '')) <> 'ITEM' then
      raise exception 'Line % isn''t an item line.', v_src.line_no;
    end if;
    v_total := abs(coalesce(v_line."Quantity", 0));
    if coalesce(v_src.quantity, 0) <= 0 or v_src.quantity > v_total then
      raise exception 'Line % has % - give up 1 to % of it.', v_src.line_no, v_total, v_total;
    end if;

    select li.variation_id, li.item_code into v_old_variation, v_old_item
    from public._advance_order_line_items(p_no) li where li.line_no = v_src.line_no;
    select s."SerialNo" into v_serial from public._advance_order_serials(p_no) s
    where s."Status" = 'SOLD' and s."ItemCode" = v_old_item and coalesce(s."VariantCode", '') = coalesce(v_old_variation, '')
    limit 1;
    if v_serial is not null then
      raise exception 'Serial % is tagged to line %''s item - a Super User must Mark it In Stock in the Serial Tracker first.', v_serial, v_src.line_no;
    end if;

    v_value := v_value + case when v_src.quantity = v_total then coalesce(v_line."NetAmount", 0)
                              else round(coalesce(v_line."NetAmount", 0) * v_src.quantity / v_total, 2) end;
    if v_count = 0 then
      v_first := v_line;
      v_base := regexp_replace(v_src.line_no, '-X\d+$', '');
    end if;
    v_count := v_count + 1;
  end loop;

  -- ---- The new items must add up to that value (the last line may take up to 1 centavo per unit of rounding).
  select sum(x.quantity * x.price), count(*) into v_targets_total, v_target_count
  from jsonb_to_recordset(p_targets) as x(variation_id text, quantity numeric, price numeric);
  select x.quantity into v_last_qty
  from jsonb_array_elements(p_targets) with ordinality as e(j, ord)
  cross join lateral jsonb_to_record(e.j) as x(quantity numeric)
  order by e.ord desc limit 1;
  if abs(v_value - v_targets_total) > 0.01 * v_last_qty + 0.001 then
    raise exception 'The new items add up to % but the exchange value is % - adjust the prices or quantities (or use Fit to value).',
      to_char(v_targets_total, 'FM999,999,990.00'), to_char(v_value, 'FM999,999,990.00');
  end if;

  -- ---- Take the units off the source lines.
  for v_src in
    select x.line_no, x.quantity
    from jsonb_array_elements(p_sources) with ordinality as e(j, ord)
    cross join lateral jsonb_to_record(e.j) as x(line_no text, quantity numeric)
    order by e.ord
  loop
    select * into v_line from public."AdvanceOrderLines" where "TransactionNo" = p_no and "LineNo" = v_src.line_no;
    v_total := abs(coalesce(v_line."Quantity", 0));
    v_ratio := v_src.quantity / v_total;
    v_sign := sign(coalesce(nullif(v_line."Quantity", 0), 1));
    if v_src.quantity = v_total then
      v_s_disc := coalesce(v_line."Discount", 0);
      v_s_gross := coalesce(v_line."GrossAmount", 0);
      v_s_net := coalesce(v_line."NetAmount", 0);
    else
      v_s_disc := round(coalesce(v_line."Discount", 0) * v_ratio, 2);
      v_s_gross := round(coalesce(v_line."GrossAmount", 0) * v_ratio, 2);
      v_s_net := round(coalesce(v_line."NetAmount", 0) * v_ratio, 2);
    end if;
    select li.variation_id into v_old_variation from public._advance_order_line_items(p_no) li where li.line_no = v_src.line_no;

    if v_src.line_no like '%-X%' then
      -- Portal line: edited directly; gone when nothing is left.
      if v_src.quantity = v_total then
        delete from public."AdvanceOrderLines" where "TransactionNo" = p_no and "LineNo" = v_src.line_no;
      else
        update public."AdvanceOrderLines"
           set "Quantity" = "Quantity" - v_sign * v_src.quantity,
               "Discount" = coalesce("Discount", 0) - v_s_disc,
               "GrossAmount" = coalesce("GrossAmount", 0) - v_s_gross,
               "NetAmount" = coalesce("NetAmount", 0) - v_s_net
         where "TransactionNo" = p_no and "LineNo" = v_src.line_no;
      end if;
    else
      -- POS line: kept through the sync by a quantity override (0 left is fine - the POS can't delete it).
      insert into public."AdvanceOrderLineOverrides"
        ("TransactionNo", "LineNo", "PosVariationId", "VariationId", "Description", "ChangedBy", "ChangedAtUtc",
         "PosQuantity", "Quantity", "Discount", "GrossAmount", "NetAmount")
      values
        (p_no, v_src.line_no, nullif(trim(v_line."VariationId"), ''), coalesce(nullif(trim(v_line."VariationId"), ''), ''),
         v_line."Description", p_admin_username, now(),
         v_line."Quantity",
         v_line."Quantity" - v_sign * v_src.quantity,
         coalesce(v_line."Discount", 0) - v_s_disc,
         coalesce(v_line."GrossAmount", 0) - v_s_gross,
         coalesce(v_line."NetAmount", 0) - v_s_net)
      on conflict ("TransactionNo", "LineNo") do update
        set "PosQuantity" = coalesce(public."AdvanceOrderLineOverrides"."PosQuantity", excluded."PosQuantity"),
            "Quantity" = excluded."Quantity", "Discount" = excluded."Discount",
            "GrossAmount" = excluded."GrossAmount", "NetAmount" = excluded."NetAmount",
            "ChangedBy" = excluded."ChangedBy", "ChangedAtUtc" = now();

      update public."AdvanceOrderLines"
         set "Quantity" = "Quantity" - v_sign * v_src.quantity,
             "Discount" = coalesce("Discount", 0) - v_s_disc,
             "GrossAmount" = coalesce("GrossAmount", 0) - v_s_gross,
             "NetAmount" = coalesce("NetAmount", 0) - v_s_net
       where "TransactionNo" = p_no and "LineNo" = v_src.line_no;
    end if;

    v_given := v_given || case when v_given = '' then '' else ' + ' end
               || v_src.quantity || ' x ' || coalesce(v_line."Description", v_src.line_no);

    -- Logged on the source line (NewLineNo null = the badge shows on this line only).
    insert into public."OrderLineVariantChanges"
      ("OrderKind", "OrderNo", "LineNo", "OldVariationId", "OldDescription", "NewVariationId", "NewDescription", "ChangedBy",
       "Quantity", "NewLineNo")
    values ('Advance', p_no, v_src.line_no, v_old_variation, v_src.quantity || ' x ' || coalesce(v_line."Description", ''),
            coalesce(nullif(trim(v_line."VariationId"), ''), '-'),
            'Exchanged (' || v_src.quantity || ' given up, worth ' || to_char(v_s_net, 'FM999,999,990.00') || ')',
            p_admin_username, v_src.quantity, null);
  end loop;

  -- ---- The new lines.
  v_amount := 0;
  for v_tgt in
    select x.variation_id, x.quantity, x.price, e.ord
    from jsonb_array_elements(p_targets) with ordinality as e(j, ord)
    cross join lateral jsonb_to_record(e.j) as x(variation_id text, quantity numeric, price numeric)
    order by e.ord
  loop
    select * into v_new from public._order_line_variant_candidates() c where c.variation_id = trim(v_tgt.variation_id) limit 1;
    loop
      v_n := v_n + 1;
      v_line_no := v_base || '-X' || v_n;
      exit when not exists (select 1 from public."AdvanceOrderLines" where "TransactionNo" = p_no and "LineNo" = v_line_no);
    end loop;

    -- The last line takes the rounding so the lines add up to the exchange value exactly.
    v_s_net := case when v_tgt.ord = v_target_count then v_value - v_amount else round(v_tgt.quantity * v_tgt.price, 2) end;
    v_amount := v_amount + v_s_net;

    insert into public."AdvanceOrderLines"
      ("TransactionNo", "LineNo", "StoreNo", "POSTerminalNo", "ReceiptNo", "Type", "No", "Description",
       "Quantity", "Price", "Discount", "GrossAmount", "NetAmount", "Date", "Time", "EODID", "UserID",
       "VariationId", "SyncedAtUtc")
    values
      (p_no, v_line_no, v_first."StoreNo", v_first."POSTerminalNo", v_first."ReceiptNo", 'ITEM', v_new.item_code,
       left(v_new.label, 500),
       v_tgt.quantity, round(v_s_net / v_tgt.quantity, 2), 0, v_s_net, v_s_net,
       v_first."Date", v_first."Time", v_first."EODID", v_first."UserID",
       v_new.variation_id, now());

    insert into public."OrderLineVariantChanges"
      ("OrderKind", "OrderNo", "LineNo", "OldVariationId", "OldDescription", "NewVariationId", "NewDescription", "ChangedBy",
       "Quantity", "NewLineNo")
    values ('Advance', p_no, v_line_no, null, 'Exchange for: ' || v_given, v_new.variation_id,
            v_tgt.quantity || ' x ' || v_new.label || ' at ' || to_char(round(v_s_net / v_tgt.quantity, 2), 'FM999,999,990.00'),
            p_admin_username, v_tgt.quantity, null);

    v_got := v_got || case when v_got = '' then '' else ' + ' end || v_tgt.quantity || ' x ' || v_new.label;
    v_new_lines := v_new_lines || jsonb_build_array(v_line_no);
  end loop;

  return jsonb_build_object('given_up', v_given, 'got', v_got, 'new_lines', v_new_lines, 'exchange_value', v_value);
end;
$$;

grant execute on function public.staff_exchange_advance_order_lines(text, text, text, jsonb, jsonb) to anon;

-- ============================================================================
-- 2. "Changed" badge: a split (Change Item for part of a line) shows on the new line AND the line it came from
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
    select x.line_no, x.old_description, x.new_description, x.quantity, x.changed_by, x.changed_at
    from (
      select c."Id" as id, coalesce(c."NewLineNo", c."LineNo")::text as line_no, c."OldDescription"::text as old_description,
             c."NewDescription"::text as new_description, c."Quantity" as quantity, c."ChangedBy"::text as changed_by,
             c."ChangedAtUtc" as changed_at
      from public."OrderLineVariantChanges" c
      where c."OrderKind" = 'Advance' and c."OrderNo" = p_no
      union all
      -- the source line of a split
      select c."Id", c."LineNo"::text, c."OldDescription"::text, c."NewDescription"::text, c."Quantity",
             c."ChangedBy"::text, c."ChangedAtUtc"
      from public."OrderLineVariantChanges" c
      where c."OrderKind" = 'Advance' and c."OrderNo" = p_no and c."NewLineNo" is not null
    ) x
    order by x.id;
end;
$$;

grant execute on function public.staff_list_advance_order_line_changes(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Result: confirms the Exchange function is in place (one row).
select
  (select count(*) from pg_proc where proname = 'staff_exchange_advance_order_lines') as exchange_function,
  (select count(*) from information_schema.columns
    where table_name = 'AdvanceOrderLineOverrides' and column_name = 'PosQuantity') as needs_quantity_file_first;
