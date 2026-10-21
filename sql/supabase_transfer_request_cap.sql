-- Transfer Orders: HARD CAP on store requests from the shelf "maintaining qty", per "if the store is
-- asking or requesting items can we control it base on the minimum qty of their shelf and production
-- shelf" -> hard cap, levels = what's already set on the shelf maps, no level = free, block adding the
-- line, customer orders allowed with an Order ID checked against what the order needs.
--
-- PER LINE, for the To Warehouse (the requesting store):
--
--   Allowed = maintaining qty - on hand there - already on the way (open transfers to that store)
--
--   Maintaining qty, first match wins:
--     1. Production Shelf Map rack linked to the item at that location:
--          rack Capacity (sum of the linked racks - what Auto Order fills to), else the product's
--          minimum (ProductionShelfMinimums). A rack linked to the exact variant beats an
--          "Any variant" rack. On hand = serials IN_STOCK there (or the ledger if the rack counts
--          from the ledger - CountSource).
--     2. Shelf Map (inventory shelves) at that location: the sum of the spots' maintaining count
--          (ShelfMapCells.CurrentQty) for the item, all variants together. On hand = Item Ledger there,
--          all variants together - the same numbers the Shelf Map page shows.
--     3. Neither (or the count is 0 / blank) -> no limit.
--   On the way = every open line (header not Received/Cancelled) to that store for the same item
--     (variant for a variant rack): Qty To Transfer - Received - Returned - Written Off. Lines with an
--     Order ID don't count - they're for a customer, not the shelf.
--   Negative on hand counts as 0.
--
--   Lines WITH an Order ID (online / walk-in order ID, or ADV-<TransactionNo> for an advance order)
--   skip the shelf cap. Instead: the order must exist, not be cancelled, and contain the item; the qty
--   can't exceed what the order needs minus what's already been requested for that order (open lines
--   + received on posted ones).
--
-- ENFORCED by a BEFORE INSERT / UPDATE trigger on Transfer_Line (the database refuses the line, so the
-- form can't be bypassed). Only fires when a line is added or its Qty To Transfer / item / variant /
-- Order ID changes - Ship / Receive never touch those, and lowering a qty is always allowed.
-- staff_check_transfer_request_lines is the same calculation for the screens (New Transfer Order shows
-- "Max N" per line; Shelf Map Replenish trims its quantities to it), summing several lines of the same
-- item in one request.
--
-- Transfers are portal-only (no desktop POS writer), so the trigger only meets portal saves.
-- ADV- lines resolve the order's items like Ready to Ship does (_advance_order_line_items), and a
-- shipped advance order can't be requested for.
-- Run AFTER supabase_transfer_order_post_partial.sql (Qty Returned / Qty Written Off columns) and
-- supabase_advance_order_sticker_no_serial.sql (_advance_order_line_items).
-- Safe to re-run.

alter table public."Transfer_Line" add column if not exists "Order ID" varchar(100);
alter table public."Posted_Transfer_Line" add column if not exists "Order ID" varchar(100);

-- ============================================================================
-- Helpers
-- ============================================================================

-- Every item code a line's item/variant can appear under: the line's item, the variant's own item row
-- and its main item (same reach as the ledger / Shelf Map / Production Shelf matching).
create or replace function public._tr_item_keys(p_item text, p_variant text)
returns text[]
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce(array_agg(distinct k) filter (where k is not null and k <> ''), array[]::text[])
  from (
    select trim(coalesce(p_item, '')) as k
    union all
    select trim(v."ItemCode") from public."Variants" v where v."VariationId" = nullif(trim(coalesce(p_variant, '')), '')
    union all
    select trim(v."MainItemCode") from public."Variants" v where v."VariationId" = nullif(trim(coalesce(p_variant, '')), '')
  ) x;
$$;

revoke execute on function public._tr_item_keys(text, text) from public, anon, authenticated;

drop function if exists public._tr_request_cap(text, text, text, text, text);

-- The shelf cap for one line. rule null = no maintaining qty -> no limit.
-- p_doc / p_line: the line being checked, left out of "on the way" (null p_line = a line not saved yet).
create or replace function public._tr_request_cap(p_doc text, p_line text, p_to_wh_id text, p_item text, p_variant text)
returns table(rule text, scope text, scope_key text, maintain numeric, on_hand numeric, on_the_way numeric, allowed numeric, open_docs text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_variant text := nullif(trim(coalesce(p_variant, '')), '');
  v_items text[] := public._tr_item_keys(p_item, p_variant);
  v_wh_name text;
  v_n int;
  v_cap numeric;
  v_min numeric;
  v_ledger boolean;
  v_spot_item text;
  v_key record;
begin
  select w."Name" into v_wh_name from public."Warehouses" w where w."ID" = p_to_wh_id;

  -- 1a. Production rack linked to this exact variant
  if v_variant is not null then
    select count(*), sum(sp."Capacity"), bool_or(coalesce(sp."CountSource", 'serials') = 'ledger'), min(sp."ItemCode")
      into v_n, v_cap, v_ledger, v_spot_item
      from public."ProductionShelfSpots" sp
      join public."ProductionShelves" sh on sh."Id" = sp."ShelfId"
     where sh."WarehouseId" = p_to_wh_id and sp."VariantId" = v_variant;
    if v_n > 0 then
      scope := 'variant';
      select m."MinQty" into v_min from public."ProductionShelfMinimums" m
       where m."WarehouseId" = p_to_wh_id and m."ItemCode" = v_spot_item and m."VariantId" = v_variant;
    end if;
  end if;

  -- 1b. Production rack linked to the item, "Any variant"
  if scope is null then
    select count(*), sum(sp."Capacity"), bool_or(coalesce(sp."CountSource", 'serials') = 'ledger'), min(sp."ItemCode")
      into v_n, v_cap, v_ledger, v_spot_item
      from public."ProductionShelfSpots" sp
      join public."ProductionShelves" sh on sh."Id" = sp."ShelfId"
     where sh."WarehouseId" = p_to_wh_id and nullif(trim(coalesce(sp."VariantId", '')), '') is null
       and sp."ItemCode" = any(v_items);
    if v_n > 0 then
      scope := 'item';
      select m."MinQty" into v_min from public."ProductionShelfMinimums" m
       where m."WarehouseId" = p_to_wh_id and m."ItemCode" = v_spot_item and m."VariantId" = '';
    end if;
  end if;

  if scope is not null then
    maintain := case when coalesce(v_cap, 0) > 0 then v_cap else v_min end;
    if maintain is null then
      scope := null;  -- rack with no capacity and no minimum -> try the inventory Shelf Map
    else
      rule := case when coalesce(v_cap, 0) > 0 then 'Production Shelf rack capacity' else 'Production Shelf minimum' end;
      if coalesce(v_ledger, false) then
        if scope = 'variant' then
          begin
            select k.item_code, k.variant_id into v_key from public._ile_resolve_stock_key(p_item, v_variant) k;
            on_hand := public._ile_balance(v_key.item_code, v_key.variant_id, p_to_wh_id);
          exception when others then
            on_hand := 0;
          end;
        else
          select coalesce(sum(e."Quantity"), 0) into on_hand from public."ItemLedgerEntries" e
           where e."WarehouseId" = p_to_wh_id and e."ItemCode" = any(v_items);
        end if;
      else
        select count(*) into on_hand
          from public."ItemSerialTracking" s
         where s."Status" = 'IN_STOCK' and s."Location" = v_wh_name
           and case when scope = 'variant' then s."VariantCode" = v_variant
                    else s."ItemCode" = any(v_items)
                      or s."VariantCode" in (select v."VariationId" from public."Variants" v
                                              where v."MainItemCode" = any(v_items) or v."ItemCode" = any(v_items)) end;
      end if;
    end if;
  end if;

  -- 2. Inventory Shelf Map maintaining count
  if scope is null then
    select sum(c."CurrentQty") into maintain
      from public."ShelfMapCells" c
      join public."ShelfMaps" s on s."Id" = c."ShelfId"
     where s."WarehouseId" = p_to_wh_id and c."ItemCode" = any(v_items);
    if coalesce(maintain, 0) > 0 then
      scope := 'item';
      rule := 'Shelf Map maintaining count';
      select coalesce(sum(e."Quantity"), 0) into on_hand from public."ItemLedgerEntries" e
       where e."WarehouseId" = p_to_wh_id and e."ItemCode" = any(v_items);
    else
      maintain := null;
    end if;
  end if;

  -- 3. No level -> no limit
  if rule is null then
    return next;
    return;
  end if;

  scope_key := scope || ':' || case when scope = 'variant' then v_variant else coalesce(v_items[1], '') end;

  select coalesce(sum(r.remaining), 0),
         string_agg(distinct r.doc, ', ') filter (where r.remaining > 0)
    into on_the_way, open_docs
    from (
      select l."Document No." as doc,
             greatest(0, coalesce(l."Qty To Transfer", 0) - coalesce(l."Qty Received", 0)
                         - coalesce(l."Qty Returned", 0) - coalesce(l."Qty Written Off", 0)) as remaining
        from public."Transfer_Line" l
        join public."Transfer_Header" h on h."No." = l."Document No."
       where h."To Warehouse ID" = p_to_wh_id
         and coalesce(h."Status", '') not in ('Received', 'Cancelled')
         and nullif(trim(coalesce(l."Order ID", '')), '') is null
         and not (l."Document No." = p_doc and l."Line No."::text = coalesce(p_line, ''))
         and case when scope = 'variant' then l."Variant ID" = v_variant else l."Item No." = any(v_items) end
    ) r;

  on_hand := greatest(coalesce(on_hand, 0), 0);
  allowed := greatest(0, maintain - on_hand - on_the_way);
  return next;
end;
$$;

revoke execute on function public._tr_request_cap(text, text, text, text, text) from public, anon, authenticated;

drop function if exists public._tr_order_cap(text, text, text, text, text);

-- The Order ID check for one line: message not null = refused outright (order missing / cancelled /
-- doesn't contain the item); otherwise allowed = needed - already requested.
create or replace function public._tr_order_cap(p_doc text, p_line text, p_order_id text, p_item text, p_variant text)
returns table(order_key text, needed numeric, already numeric, allowed numeric, message text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_id text := upper(trim(coalesce(p_order_id, '')));
  v_variant text := nullif(trim(coalesce(p_variant, '')), '');
  v_items text[] := public._tr_item_keys(p_item, p_variant);
  v_status text;
  v_adv text;
begin
  order_key := v_id;
  if v_id = '' then
    message := 'Order ID is blank.';
    return next; return;
  end if;

  if v_id like 'ADV-%' then
    select a."TransactionNo" into v_adv from public."AdvanceOrders" a where upper(a."TransactionNo") = substr(v_id, 5);
    if not found then
      message := 'Advance order ' || v_id || ' was not found.';
      return next; return;
    end if;
    if exists (select 1 from public."AdvanceOrderProduction" p where p."TransactionNo" = v_adv and p."ShippedAtUtc" is not null) then
      message := 'Advance order ' || v_id || ' is already shipped.';
      return next; return;
    end if;
    -- The order's lines with their real item resolved (AdvanceOrderLines."No" is the POS category, not
    -- the item code) - same resolution as Ready to Ship (_advance_order_line_items).
    select coalesce(sum(li.quantity), 0) into needed
      from public._advance_order_line_items(v_adv) li
     where (v_variant is not null and li.variation_id = v_variant)
        or (coalesce(li.item_code, li.category) = any(v_items) and (v_variant is null or li.variation_id is null));
  else
    select o."Status" into v_status from public."OnlineOrders" o where upper(o."OrderID") = v_id;
    if not found then
      message := 'Order ' || v_id || ' was not found (use ADV-<no> for an advance order).';
      return next; return;
    end if;
    if coalesce(v_status, '') ilike '%cancel%' then
      message := 'Order ' || v_id || ' is cancelled.';
      return next; return;
    end if;
    select coalesce(sum(coalesce(ol."Quantity", 0)), 0) into needed
      from public."OnlineOrderLines" ol
     where upper(ol."OrderID") = v_id
       and ((v_variant is not null and ol."VariationId" = v_variant)
         or (coalesce(nullif(trim(ol."ItemCode"), ''), trim(ol."product_display_id")) = any(v_items)
             and (v_variant is null or nullif(trim(coalesce(ol."VariationId", '')), '') is null)));
  end if;

  if coalesce(needed, 0) <= 0 then
    message := 'Order ' || v_id || ' has no ' || coalesce(nullif(trim(p_item), ''), 'such item')
               || case when v_variant is not null then ' (this variant)' else '' end || ' on it.';
    return next; return;
  end if;

  select coalesce(sum(x.q), 0) into already
    from (
      select greatest(0, coalesce(l."Qty To Transfer", 0) - coalesce(l."Qty Returned", 0) - coalesce(l."Qty Written Off", 0)) as q
        from public."Transfer_Line" l
        join public."Transfer_Header" h on h."No." = l."Document No."
       where upper(trim(coalesce(l."Order ID", ''))) = v_id
         and coalesce(h."Status", '') <> 'Cancelled'
         and not (l."Document No." = p_doc and l."Line No."::text = coalesce(p_line, ''))
         and case when v_variant is not null then l."Variant ID" = v_variant else l."Item No." = any(v_items) end
      union all
      select coalesce(pl."Qty Received", 0)
        from public."Posted_Transfer_Line" pl
       where upper(trim(coalesce(pl."Order ID", ''))) = v_id
         and case when v_variant is not null then pl."Variant ID" = v_variant else pl."Item No." = any(v_items) end
    ) x;

  allowed := greatest(0, needed - already);
  return next;
end;
$$;

revoke execute on function public._tr_order_cap(text, text, text, text, text) from public, anon, authenticated;

-- ============================================================================
-- Enforcement: trigger on Transfer_Line
-- ============================================================================

create or replace function public._tr_line_request_cap_check()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_header record;
  v_cap record;
  v_ord record;
  v_qty numeric := coalesce(new."Qty To Transfer", 0);
  v_label text := coalesce(new."Item No.", '?') || coalesce(' ' || nullif(trim(coalesce(new."Variant Name", '')), ''), '');
begin
  if tg_op = 'UPDATE'
     and new."Item No." is not distinct from old."Item No."
     and new."Variant ID" is not distinct from old."Variant ID"
     and upper(trim(coalesce(new."Order ID", ''))) = upper(trim(coalesce(old."Order ID", '')))
     and v_qty <= coalesce(old."Qty To Transfer", 0) then
    return new;   -- unchanged or lowered - always allowed
  end if;
  if v_qty <= 0 then
    return new;
  end if;

  select h."To Warehouse ID" as to_id, h."To Warehouse" as to_name, h."Status" as status
    into v_header from public."Transfer_Header" h where h."No." = new."Document No.";
  if not found or coalesce(v_header.status, '') in ('Received', 'Cancelled') then
    return new;
  end if;

  if nullif(trim(coalesce(new."Order ID", '')), '') is not null then
    new."Order ID" := upper(trim(new."Order ID"));
    select * into v_ord from public._tr_order_cap(new."Document No.", new."Line No."::text, new."Order ID", new."Item No.", new."Variant ID");
    if v_ord.message is not null then
      raise exception '% - %', v_label, v_ord.message;
    end if;
    if v_qty > v_ord.allowed then
      raise exception '% - order % needs %, % already requested for it -> max %, requested %.',
        v_label, v_ord.order_key, v_ord.needed, v_ord.already, v_ord.allowed, v_qty;
    end if;
    return new;
  end if;

  select * into v_cap from public._tr_request_cap(new."Document No.", new."Line No."::text, v_header.to_id, new."Item No.", new."Variant ID");
  if v_cap.rule is not null and v_qty > v_cap.allowed then
    raise exception '% - over the limit for %: % %, on hand %, on the way % % -> max %, requested %.',
      v_label, coalesce(v_header.to_name, v_header.to_id), v_cap.rule, v_cap.maintain, v_cap.on_hand, v_cap.on_the_way,
      coalesce('(' || v_cap.open_docs || ')', ''), v_cap.allowed, v_qty;
  end if;
  return new;
end;
$$;

drop trigger if exists "TR_Transfer_Line_RequestCap" on public."Transfer_Line";
create trigger "TR_Transfer_Line_RequestCap"
  before insert or update of "Qty To Transfer", "Item No.", "Variant ID", "Order ID" on public."Transfer_Line"
  for each row execute function public._tr_line_request_cap_check();

-- ============================================================================
-- Screens: same calculation before saving
-- ============================================================================

drop function if exists public.staff_check_transfer_request_lines(text, text, text, text, jsonb);

-- p_lines: [{"item_no": "...", "variant_id": "..." | null, "qty": 3, "order_id": "..." | null}], in
-- form order. Lines of the same item in one request share the allowance (earlier lines use it first).
-- One row per line: rule null + ok = no limit; allowed = the max for that line.
create or replace function public.staff_check_transfer_request_lines(
  p_admin_username text,
  p_admin_password text,
  p_doc_no text,
  p_to_warehouse_id text,
  p_lines jsonb
)
returns table(idx int, rule text, maintain numeric, on_hand numeric, on_the_way numeric, open_docs text,
              order_needed numeric, order_already numeric, allowed numeric, ok boolean, message text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_line record;
  v_cap record;
  v_ord record;
  v_used jsonb := '{}'::jsonb;
  v_key text;
  v_qty numeric;
  v_order text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  for v_line in
    select (t.ord - 1)::int as i, t.value as v from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) with ordinality t(value, ord)
  loop
    idx := v_line.i;
    rule := null; maintain := null; on_hand := null; on_the_way := null; open_docs := null;
    order_needed := null; order_already := null; allowed := null; ok := true; message := null;
    v_qty := coalesce(nullif(v_line.v->>'qty', '')::numeric, 0);
    v_order := nullif(upper(trim(coalesce(v_line.v->>'order_id', ''))), '');

    if nullif(trim(coalesce(v_line.v->>'item_no', '')), '') is null then
      return next; continue;
    end if;

    if v_order is not null then
      select * into v_ord from public._tr_order_cap(p_doc_no, null, v_order, v_line.v->>'item_no', v_line.v->>'variant_id');
      rule := 'Order ' || v_order;
      if v_ord.message is not null then
        ok := false; message := v_ord.message;
      else
        v_key := 'order:' || v_order || ':' || coalesce(nullif(v_line.v->>'variant_id', ''), v_line.v->>'item_no');
        order_needed := v_ord.needed;
        order_already := v_ord.already + coalesce((v_used->>v_key)::numeric, 0);
        allowed := greatest(0, v_ord.allowed - coalesce((v_used->>v_key)::numeric, 0));
        ok := v_qty <= allowed;
        if not ok then
          message := 'Order ' || v_order || ' needs ' || order_needed || ', ' || order_already || ' already requested -> max ' || allowed || '.';
        end if;
        v_used := v_used || jsonb_build_object(v_key, coalesce((v_used->>v_key)::numeric, 0) + v_qty);
      end if;
    else
      select * into v_cap from public._tr_request_cap(p_doc_no, null, p_to_warehouse_id, v_line.v->>'item_no', v_line.v->>'variant_id');
      if v_cap.rule is not null then
        v_key := v_cap.scope_key;
        rule := v_cap.rule; maintain := v_cap.maintain; on_hand := v_cap.on_hand; open_docs := v_cap.open_docs;
        on_the_way := v_cap.on_the_way + coalesce((v_used->>v_key)::numeric, 0);
        allowed := greatest(0, v_cap.allowed - coalesce((v_used->>v_key)::numeric, 0));
        ok := v_qty <= allowed;
        if not ok then
          message := 'Over the limit: ' || rule || ' ' || maintain || ', on hand ' || on_hand || ', on the way ' || on_the_way
                     || coalesce(' (' || open_docs || ')', '') || ' -> max ' || allowed || '.';
        end if;
        v_used := v_used || jsonb_build_object(v_key, coalesce((v_used->>v_key)::numeric, 0) + v_qty);
      end if;
    end if;
    return next;
  end loop;
end;
$$;

grant execute on function public.staff_check_transfer_request_lines(text, text, text, text, jsonb) to anon;

notify pgrst, 'reload schema';

-- Verification - one result: columns, trigger, function grant, and a sample of the levels that are set
-- (rule per product per location) so you can see what the cap will use.
select 'column' as section, table_name || '."Order ID"' as item, 'ok' as value
from information_schema.columns
where table_schema = 'public' and table_name in ('Transfer_Line', 'Posted_Transfer_Line') and column_name = 'Order ID'
union all
select 'trigger', tgname::text, case when tgenabled <> 'D' then 'enabled' else 'DISABLED' end
from pg_trigger where tgrelid = 'public."Transfer_Line"'::regclass and tgname = 'TR_Transfer_Line_RequestCap'
union all
select 'function', 'staff_check_transfer_request_lines',
       case when has_function_privilege('anon', 'public.staff_check_transfer_request_lines(text, text, text, text, jsonb)', 'EXECUTE') then 'ok' else 'anon cannot execute' end
union all
select 'levels - Shelf Map', w."Name" || ' | ' || count(distinct c."ItemCode") || ' item(s) with a maintaining count', ''
from public."ShelfMapCells" c join public."ShelfMaps" s on s."Id" = c."ShelfId" join public."Warehouses" w on w."ID" = s."WarehouseId"
where c."ItemCode" is not null and coalesce(c."CurrentQty", 0) > 0
group by w."Name"
union all
select 'levels - Production Shelf', w."Name" || ' | ' || count(distinct sp."ItemCode" || '|' || coalesce(sp."VariantId", '')) || ' rack product(s), '
       || count(distinct sp."ItemCode" || '|' || coalesce(sp."VariantId", '')) filter (where sp."Capacity" > 0) || ' with capacity', ''
from public."ProductionShelfSpots" sp join public."ProductionShelves" sh on sh."Id" = sp."ShelfId" join public."Warehouses" w on w."ID" = sh."WarehouseId"
where sp."ItemCode" is not null
group by w."Name";
