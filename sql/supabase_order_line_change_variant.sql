-- Change a line's item / variant on an order - Super Users and Sales Users. Per "in the online orders / walkin orders and
-- advance orders can a super user change the item.. i notice that the punched is black paint but the actual is
-- white paint" / "yes please allow a super user to edit it manually in the order".
--
-- The line keeps its quantity, price, discount and note - only WHICH product it is changes (e.g.
-- AST-003-BlackPaint -> AST-003-WhitePaint). Every change is logged in OrderLineVariantChanges.
--
-- ONLINE ORDERS (admin_change_online_order_line_variant): Pancake owns the lines, so the change is pushed
-- there - same GET -> rebuild items -> PATCH (PUT fallback) -> restore bank_payments -> re-sync as SET Assemble
-- (staff_save_online_order_set_materials). Portal-only orders (Source 'Portal', no Pancake order) are edited
-- in OnlineOrderLines directly.
--
-- ADVANCE ORDERS (staff_change_advance_order_line_variant): the POS pushes AdvanceOrderLines up every 5
-- minutes and would put the old variant back. So the change is also kept in AdvanceOrderLineOverrides, and a
-- BEFORE trigger re-applies it whenever the POS sends the line with its ORIGINAL variant. If the POS sends a
-- different variant (someone really edited it on the POS), the POS wins and the override is dropped.
-- The Item Ledger follows on its own (TR_AdvanceOrderLines_ItemLedger re-posts on a VariationId change).
-- The local POS screens still show the old variant - only the portal / ledger / serials use the new one.
--
-- WALK-IN ORDERS are not covered: they're posted POS receipts (stock already moved) - do a POS exchange.
--
-- Blocked while a serial for the line's item is tagged to the order. Online orders: allowed up to and
-- including To Ship (Packing and later locked); at To Ship also not on SET lines / SET parts, nor swapping
-- TO a serial-tracked item (the serial pick is already done). Advance orders: blocked from To Ship on (Undo
-- Stage first).
--
-- Run AFTER supabase_online_order_set_explode.sql, supabase_bot_orders_portal_confirm.sql,
-- supabase_advance_order_serials.sql and supabase_item_ledger_advance_orders.sql. Safe to re-run.
-- Needs js/onlineOrders.js ?v=chgsales1.

-- ============================================================================
-- 1. Tables
-- ============================================================================

create table if not exists public."OrderLineVariantChanges" (
  "Id" bigserial primary key,
  "OrderKind" text not null,              -- 'Online' / 'Advance'
  "OrderNo" text not null,
  "LineNo" text not null,
  "OldVariationId" text,
  "OldDescription" text,
  "NewVariationId" text not null,
  "NewDescription" text,
  "ChangedBy" text not null,
  "ChangedAtUtc" timestamptz not null default now()
);

alter table public."OrderLineVariantChanges" enable row level security;
revoke all on public."OrderLineVariantChanges" from anon, authenticated;

create table if not exists public."AdvanceOrderLineOverrides" (
  "TransactionNo" varchar(100) not null,
  "LineNo" varchar(50) not null,
  "PosVariationId" text,                  -- what the POS still sends (the original)
  "VariationId" text not null,            -- what the portal uses instead
  "Description" text,
  "ChangedBy" text not null,
  "ChangedAtUtc" timestamptz not null default now(),
  primary key ("TransactionNo", "LineNo")
);

alter table public."AdvanceOrderLineOverrides" enable row level security;
revoke all on public."AdvanceOrderLineOverrides" from anon, authenticated;

-- ============================================================================
-- 2. Keep advance order overrides through the POS sync
-- ============================================================================

create or replace function public._advance_order_line_apply_override()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ov public."AdvanceOrderLineOverrides";
begin
  select * into v_ov from public."AdvanceOrderLineOverrides"
  where "TransactionNo" = new."TransactionNo" and "LineNo" = new."LineNo";
  if not found then
    return new;
  end if;

  if coalesce(nullif(trim(new."VariationId"), ''), '') = coalesce(v_ov."PosVariationId", '') then
    -- The POS re-sending its original line: keep the portal's variant.
    new."VariationId" := v_ov."VariationId";
    new."Description" := coalesce(v_ov."Description", new."Description");
  elsif coalesce(nullif(trim(new."VariationId"), ''), '') <> v_ov."VariationId" then
    -- Changed on the POS itself since - the POS wins.
    delete from public."AdvanceOrderLineOverrides"
    where "TransactionNo" = new."TransactionNo" and "LineNo" = new."LineNo";
  end if;
  return new;
end;
$$;

drop trigger if exists "TR_AdvanceOrderLines_VariantOverride" on public."AdvanceOrderLines";
create trigger "TR_AdvanceOrderLines_VariantOverride"
  before insert or update on public."AdvanceOrderLines"
  for each row execute function public._advance_order_line_apply_override();

-- ============================================================================
-- 3. Helpers
-- ============================================================================

create or replace function public._is_active_super_user(p_username text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public."StaffUsers" s
                 where s."Username" = p_username and s."IsActive" and coalesce(s."SuperUser", false));
$$;

revoke execute on function public._is_active_super_user(text) from public, anon, authenticated;

-- Who may Change Item: Super Users and Sales Users (per "can you let the sales user change it too?") -
-- same people as the line edit (supabase_online_order_line_edit.sql).
create or replace function public._can_change_order_line_item(p_username text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public."StaffUsers" s
                 where s."Username" = p_username and s."IsActive"
                   and (coalesce(s."SuperUser", false) or coalesce(s."SalesUser", false)));
$$;

revoke execute on function public._can_change_order_line_item(text) from public, anon, authenticated;

-- Every sellable Pancake variant (plus items without variants that have their own VariationId).
-- tag   = what tells the variants apart (SKU / variant item code, e.g. AST-003-WhitePaint) - the POS puts it
--         at the end of its line text ("DUALSTAND-50G (...) - AST-003-BlackPaint").
-- label = name + tag, so the colour/variant always shows (the variant name alone is often just the product).
drop function if exists public._order_line_variant_candidates();

create or replace function public._order_line_variant_candidates()
returns table(variation_id text, item_code text, main_item_code text, name text, description text, sku text, price numeric,
              tag text, label text)
language sql
stable
security definer
set search_path = public
as $$
  select c.*,
         t.tag,
         case when t.tag is null or position(upper(t.tag) in upper(c.name)) > 0 then c.name
              else c.name || ' - ' || t.tag end
  from (
  select v."VariationId"::text as variation_id,
         coalesce(nullif(trim(v."ItemCode"), ''), v."MainItemCode")::text as item_code,
         coalesce(nullif(trim(v."MainItemCode"), ''), v."ItemCode")::text as main_item_code,
         coalesce(nullif(trim(v."VariantName"), ''), nullif(trim(p."Name"), ''), p."Code", v."VariationId")::text as name,
         coalesce(nullif(trim(p."Description"), ''), nullif(trim(p."Name"), ''), '')::text as description,
         -- the variant's own SKU only - the product's SKU would be the same for every variant
         coalesce(nullif(trim(v."SKU"), ''), '')::text as sku,
         coalesce(v."Price", p."Price", 0)::numeric as price
  from public."Variants" v
  left join public."Items" p on p."Code" = coalesce(nullif(trim(v."MainItemCode"), ''), v."ItemCode")
  where nullif(trim(v."VariationId"), '') is not null
    and coalesce(p."IsActive", true)
  union all
  select p."VariationId"::text, p."Code"::text, p."Code"::text,
         coalesce(nullif(trim(p."Name"), ''), p."Code")::text,
         coalesce(nullif(trim(p."Description"), ''), nullif(trim(p."Name"), ''), '')::text,
         coalesce(nullif(trim(p."SKU"), ''), '')::text,
         coalesce(p."Price", 0)::numeric
  from public."Items" p
  where nullif(trim(p."VariationId"), '') is not null
    and coalesce(p."IsActive", true)
    and not exists (select 1 from public."Variants" v where v."VariationId" = p."VariationId")
  ) c
  cross join lateral (
    select coalesce(
      case when c.sku <> '' and upper(c.sku) <> upper(coalesce(c.main_item_code, '')) then c.sku end,
      case when c.item_code <> '' and upper(c.item_code) <> upper(coalesce(c.main_item_code, '')) then c.item_code end
    ) as tag
  ) t;
$$;

revoke execute on function public._order_line_variant_candidates() from public, anon, authenticated;

-- Does this item take a serial? Same rule as admin_get_online_order_serial_requirements
-- (supabase_online_order_serial_lines_dedupe.sql): AQ- / custom aquarium / stand / sump codes or a production category.
create or replace function public._order_line_item_needs_serial(p_variation_id text, p_item_code text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select r.code is not null
     and (upper(r.code) like 'AQ-%'
          or upper(r.code) like 'CUSTOM-AQUARIUM%'
          or upper(r.code) like 'CUSTOM_STAND%'
          or upper(r.code) like 'CUSTOM-SUMP%'
          or upper(r.code) like 'CUSTOM_SUMP%'
          or coalesce((select c."IsProductionCategory" from public."Categories" c where c."Code" = r.cat), false))
  from (
    select coalesce(nullif(trim(v."ItemCode"), ''), nullif(trim(i."Code"), ''), nullif(trim(p_item_code), '')) as code,
           coalesce(v."CategoryCode", i."CategoryCode") as cat
    from (select 1) x
    left join lateral (
      select v0."ItemCode", v0."CategoryCode" from public."Variants" v0
      where nullif(trim(p_variation_id), '') is not null and v0."VariationId" = p_variation_id
      limit 1
    ) v on true
    left join lateral (
      select i0."Code", i0."CategoryCode" from public."Items" i0
      where i0."Code" = p_item_code or i0."VariationId" = p_item_code
      order by (i0."Code" = p_item_code) desc
      limit 1
    ) i on true
  ) r;
$$;

revoke execute on function public._order_line_item_needs_serial(text, text) from public, anon, authenticated;

-- The line text after a variant swap: keep the POS / Pancake wording and swap just the variant part
-- (SKU, then variant item code, then variant name); otherwise the new variant's label.
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
  if found then
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
-- 4. Search: the line's other variants (no search text), or any product (search text)
-- ============================================================================

drop function if exists public.staff_search_order_line_variants(text, text, text, text, text, text, text);

create or replace function public.staff_search_order_line_variants(
  p_admin_username text,
  p_admin_password text,
  p_variation_id text default null,     -- the line's current variant (online orders)
  p_item_code text default null,
  p_query text default null,
  p_advance_no text default null,       -- advance orders: resolve the line's variant from here instead
  p_advance_line_no text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_variation text := nullif(trim(coalesce(p_variation_id, '')), '');
  v_item text := nullif(trim(coalesce(p_item_code, '')), '');
  v_query text := nullif(trim(coalesce(p_query, '')), '');
  v_main text;
  v_result jsonb;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._can_change_order_line_item(p_admin_username) then
    raise exception 'Only a Super User or Sales User can change an order line''s item.';
  end if;

  if p_advance_no is not null then
    select li.variation_id, li.item_code into v_variation, v_item
    from public._advance_order_line_items(p_advance_no) li
    where li.line_no = p_advance_line_no;
  end if;

  select c.main_item_code into v_main
  from public._order_line_variant_candidates() c
  where (v_variation is not null and c.variation_id = v_variation)
     or (v_variation is null and v_item is not null and (c.item_code = v_item or c.main_item_code = v_item))
  limit 1;
  v_main := coalesce(v_main, v_item);

  select coalesce(jsonb_agg(to_jsonb(r) order by r.is_current desc, r.name, r.sku), '[]'::jsonb) into v_result
  from (
    select distinct on (c.variation_id)
           c.variation_id, c.item_code, c.name, c.label, c.tag, c.description, c.sku, c.price,
           (c.variation_id = v_variation) as is_current
    from public._order_line_variant_candidates() c
    where (v_query is null and v_main is not null and (c.main_item_code = v_main or c.item_code = v_main))
       or (v_query is not null
           and (c.item_code || ' ' || c.name || ' ' || c.description || ' ' || c.sku) ilike '%' || v_query || '%')
    order by c.variation_id
    limit 60
  ) r;

  return jsonb_build_object('current_variation_id', v_variation, 'options', v_result);
end;
$$;

grant execute on function public.staff_search_order_line_variants(text, text, text, text, text, text, text) to anon;

-- ============================================================================
-- 5. Online orders
-- ============================================================================

drop function if exists public.admin_change_online_order_line_variant(text, text, text, text, text);

create or replace function public.admin_change_online_order_line_variant(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_line_id text,
  p_variation_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '45000'
as $$
declare
  v_order_id text := trim(coalesce(p_order_id, ''));
  v_status text;
  v_new record;
  v_old_variation text;
  v_old_desc text;
  v_old_item text;
  v_old_note text;
  v_to_ship boolean;
  v_serial text;
  v_url text;
  v_get_response extensions.http_response;
  v_get_body jsonb;
  v_order_obj jsonb;
  v_bank_payments jsonb;
  v_items jsonb;
  v_body jsonb;
  v_patch_response extensions.http_response;
  v_put_response extensions.http_response;
  v_resynced boolean := true;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._can_change_order_line_item(p_admin_username) then
    raise exception 'Only a Super User or Sales User can change an order line''s item.';
  end if;

  select "Status" into v_status from public."OnlineOrders" where "OrderID" = v_order_id;
  if not found then
    raise exception 'Order % not found.', v_order_id;
  end if;
  -- To Ship is allowed (per "can we also change the to-ship but ... cannot change the items that has tagged
  -- serials already") - guarded below: no tagged serial, no SET line, no swap to a serial-tracked item.
  if lower(trim(coalesce(v_status, ''))) in ('packing', 'packed', 'shipped', 'delivered', 'completed',
                                             'received', 'canceled', 'cancelled', 'returned', 'returning', 'deleted') then
    raise exception 'Order % is % - the item can only be changed up to To Ship.', v_order_id, v_status;
  end if;
  v_to_ship := lower(trim(coalesce(v_status, ''))) = 'to ship';

  select * into v_new from public._order_line_variant_candidates() c where c.variation_id = trim(coalesce(p_variation_id, '')) limit 1;
  if not found then
    raise exception 'That product isn''t linked to a Pancake variant - pick another one.';
  end if;

  -- ---- Portal-only order: no Pancake order, edit the line here.
  if public._is_portal_only_online_order(v_order_id) then
    select nullif(trim(l."VariationId"), ''), l."Description",
           coalesce(nullif(trim(l."ItemCode"), ''), nullif(trim(l."product_display_id"), '')), l."Note"
      into v_old_variation, v_old_desc, v_old_item, v_old_note
    from public."OnlineOrderLines" l where l."OrderID" = v_order_id and l."LineID" = p_line_id;
    if not found then
      raise exception 'Line % is no longer on order % - close and reopen the order.', p_line_id, v_order_id;
    end if;
  else
    -- ---- Pancake order: rebuild ALL items from Pancake's own copy with this one line swapped.
    v_url := 'https://pos.pages.fm/api/v1/shops/1328301944/orders/' || v_order_id
      || '?api_key=' || public._pancake_api_key() || '&page_size=1000';
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
    perform extensions.http_set_curlopt('CURLOPT_USERAGENT', 'RSPetStopPortal/1.0');

    v_get_response := extensions.http_get(v_url);
    if v_get_response.status < 200 or v_get_response.status >= 300 then
      raise exception 'Could not read order % from Pancake (HTTP %). Please try again.', v_order_id, v_get_response.status;
    end if;
    v_get_body := v_get_response.content::jsonb;
    v_order_obj := case
      when jsonb_typeof(v_get_body -> 'data') = 'object' then v_get_body -> 'data'
      when jsonb_typeof(v_get_body -> 'order') = 'object' then v_get_body -> 'order'
      else v_get_body
    end;
    if jsonb_typeof(v_order_obj -> 'items') <> 'array' or jsonb_array_length(v_order_obj -> 'items') = 0 then
      raise exception 'Pancake returned no items for order % - nothing was changed.', v_order_id;
    end if;
    if jsonb_typeof(v_order_obj -> 'bank_payments') = 'object' then
      v_bank_payments := v_order_obj -> 'bank_payments';
    end if;

    create temp table if not exists _variant_swap_items (
      ord int, line_id text, variation_id text, item_code text, name text, detail text,
      quantity numeric, price numeric, note text,
      discount jsonb, is_bonus jsonb, is_discount_percent jsonb, is_wholesale jsonb
    ) on commit drop;
    truncate _variant_swap_items;

    insert into _variant_swap_items
    select
      e.ord::int,
      nullif(coalesce(it ->> 'line_id', it ->> 'id', it ->> 'order_line_id', it ->> 'order_item_id', it ->> 'item_id'), ''),
      nullif(trim(coalesce(it -> 'variation_info' ->> 'variation_id', it ->> 'variation_id', it ->> 'variationId', '')), ''),
      nullif(trim(coalesce(it -> 'variation_info' ->> 'product_display_id', it ->> 'product_display_id',
                           it -> 'variation_info' ->> 'display_id', '')), ''),
      nullif(trim(coalesce(it -> 'variation_info' ->> 'name', it ->> 'name', '')), ''),
      coalesce(it -> 'variation_info' ->> 'detail', it -> 'variation_info' ->> 'name', it ->> 'name'),
      public.pancake_parse_decimal(it ->> 'quantity'),
      public.pancake_parse_decimal(coalesce(it -> 'variation_info' ->> 'retail_price', it ->> 'retail_price')),
      it ->> 'note',
      case when jsonb_typeof(it -> 'discount_each_product') = 'number' then it -> 'discount_each_product' else '0'::jsonb end,
      case when jsonb_typeof(it -> 'is_bonus_product') = 'boolean' then it -> 'is_bonus_product' else 'false'::jsonb end,
      case when jsonb_typeof(it -> 'is_discount_percent') = 'boolean' then it -> 'is_discount_percent' else 'false'::jsonb end,
      case when jsonb_typeof(it -> 'is_wholesale') = 'boolean' then it -> 'is_wholesale' else 'false'::jsonb end
    from jsonb_array_elements(v_order_obj -> 'items') with ordinality as e(it, ord);

    select variation_id, coalesce(name, detail), item_code, note into v_old_variation, v_old_desc, v_old_item, v_old_note
    from _variant_swap_items where line_id = p_line_id;
    if not found then
      raise exception 'Line % is no longer on order % in Pancake - close and reopen the order, then try again.', p_line_id, v_order_id;
    end if;
  end if;

  if v_old_variation = v_new.variation_id then
    raise exception 'The line is already %.', v_new.label;
  end if;

  -- A serial tagged to the order for this line's item (by variant, or by item code for items without
  -- variants) locks the line - untag it first.
  select s."SerialNo" into v_serial from public."ItemSerialTracking" s
  where s."SoldOnlineOrderId" = v_order_id and s."Status" = 'SOLD'
    and ((v_old_variation is not null and coalesce(s."VariantCode", '') = v_old_variation)
         or (v_old_item is not null and s."ItemCode" = v_old_item
             and (v_old_variation is null or coalesce(s."VariantCode", '') = '')))
  limit 1;
  if v_serial is not null then
    raise exception 'Serial % is already tagged to this line''s item - the item can''t be changed now.', v_serial;
  end if;

  if v_to_ship then
    -- SET lines / SET parts: assembled and their serials reserved at Ready to Ship.
    if p_line_id like '%~SETMAT~%' or trim(coalesce(v_old_note, '')) like 'SET Material for %'
       or upper(coalesce(public._online_order_line_category(v_old_variation, v_old_item), '')) = 'SET' then
      raise exception 'Order % is at To Ship and this line is part of an assembled SET - it can only be changed before To Ship.', v_order_id;
    end if;
    -- The serial pick happened at Ready to Ship, so the new item would ship with no serial.
    if public._order_line_item_needs_serial(v_new.variation_id, v_new.item_code) then
      raise exception '% takes a serial and order % is already at To Ship (serials were picked at Ready to Ship) - it can only be changed to it before To Ship.', v_new.label, v_order_id;
    end if;
  end if;

  if public._is_portal_only_online_order(v_order_id) then
    update public."OnlineOrderLines"
       set "VariationId" = v_new.variation_id,
           "ItemCode" = v_new.item_code,
           "product_display_id" = v_new.item_code,
           "Description" = left(v_new.label, 500),
           "SyncedAtUtc" = now()
     where "OrderID" = v_order_id and "LineID" = p_line_id;
  else
    update _variant_swap_items
       set variation_id = v_new.variation_id, item_code = v_new.item_code, name = v_new.name, detail = v_new.label
     where line_id = p_line_id;

    select jsonb_agg(jsonb_build_object(
      'line_id', line_id,
      'discount_each_product', discount,
      'is_bonus_product', is_bonus,
      'is_discount_percent', is_discount_percent,
      'is_wholesale', is_wholesale,
      'one_time_product', variation_id is null,
      'quantity', case when coalesce(abs(quantity), 0) = 0 then 1 else abs(quantity) end,
      'variation_id', variation_id,
      'note', nullif(note, ''),
      'variation_info', jsonb_build_object(
        'detail', coalesce(detail, name),
        'fields', null,
        'display_id', item_code,
        'name', coalesce(name, item_code, 'Online Item'),
        'product_display_id', item_code,
        'retail_price', coalesce(price, 0),   -- the price agreed on the order stays
        'weight', 100
      )
    ) order by ord)
    into v_items
    from _variant_swap_items;

    v_body := jsonb_build_object('items', v_items);

    v_patch_response := extensions.http((
      'PATCH', v_url,
      array[extensions.http_header('Accept', 'application/json'), extensions.http_header('Expect', '')],
      'application/json', v_body::text
    )::extensions.http_request);

    if v_patch_response.status = 404 or v_patch_response.status = 405 then
      v_put_response := extensions.http((
        'PUT', v_url,
        array[extensions.http_header('Accept', 'application/json'), extensions.http_header('Expect', '')],
        'application/json', v_body::text
      )::extensions.http_request);
      if v_put_response.status < 200 or v_put_response.status >= 300 then
        raise exception 'Pancake rejected the items update (PATCH %: % / PUT %: %)',
          v_patch_response.status, left(v_patch_response.content, 300),
          v_put_response.status, left(v_put_response.content, 300);
      end if;
    elsif v_patch_response.status < 200 or v_patch_response.status >= 300 then
      raise exception 'Pancake rejected the items update (HTTP %): %', v_patch_response.status, left(v_patch_response.content, 300);
    end if;

    -- Pancake wipes bank_payments on any PATCH unless re-sent.
    if v_bank_payments is not null then
      begin
        perform extensions.http((
          'PATCH', v_url,
          array[extensions.http_header('Accept', 'application/json'), extensions.http_header('Expect', '')],
          'application/json', jsonb_build_object('bank_payments', v_bank_payments)::text
        )::extensions.http_request);
      exception when others then
        null;
      end;
    end if;

    begin
      perform public._sync_online_order_detail(v_order_id);
    exception when others then
      v_resynced := false;
    end;
  end if;

  insert into public."OrderLineVariantChanges"
    ("OrderKind", "OrderNo", "LineNo", "OldVariationId", "OldDescription", "NewVariationId", "NewDescription", "ChangedBy")
  values ('Online', v_order_id, p_line_id, v_old_variation, v_old_desc, v_new.variation_id, v_new.label, p_admin_username);

  return jsonb_build_object('old_description', v_old_desc, 'new_description', v_new.label, 'resynced', v_resynced);
end;
$$;

grant execute on function public.admin_change_online_order_line_variant(text, text, text, text, text) to anon;

-- ============================================================================
-- 6. Advance orders
-- ============================================================================

drop function if exists public.staff_change_advance_order_line_variant(text, text, text, text, text);

create or replace function public.staff_change_advance_order_line_variant(
  p_admin_username text,
  p_admin_password text,
  p_no text,
  p_line_no text,
  p_variation_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_line public."AdvanceOrderLines";
  v_ov public."AdvanceOrderLineOverrides";
  v_has_ov boolean;
  v_new record;
  v_old_variation text;
  v_old_item text;
  v_pos_variation text;
  v_new_desc text;
  v_serial text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._can_change_order_line_item(p_admin_username) then
    raise exception 'Only a Super User or Sales User can change an order line''s item.';
  end if;

  if exists (select 1 from public."AdvanceOrderProduction" p where p."TransactionNo" = p_no and p."ToShipAtUtc" is not null) then
    raise exception 'Advance order % is already at To Ship or later - Undo Stage back before To Ship first, then change the item.', p_no;
  end if;

  select * into v_line from public."AdvanceOrderLines" where "TransactionNo" = p_no and "LineNo" = p_line_no for update;
  if not found then
    raise exception 'Line % is no longer on advance order % - close and reopen the order.', p_line_no, p_no;
  end if;
  if upper(coalesce(v_line."Type", '')) <> 'ITEM' then
    raise exception 'Only item lines can be changed.';
  end if;

  select * into v_new from public._order_line_variant_candidates() c where c.variation_id = trim(coalesce(p_variation_id, '')) limit 1;
  if not found then
    raise exception 'That product isn''t linked to a Pancake variant - pick another one.';
  end if;

  select li.variation_id, li.item_code into v_old_variation, v_old_item
  from public._advance_order_line_items(p_no) li where li.line_no = p_line_no;
  if v_old_variation = v_new.variation_id then
    raise exception 'The line is already %.', v_new.label;
  end if;

  select s."SerialNo" into v_serial from public._advance_order_serials(p_no) s
  where s."Status" = 'SOLD' and s."ItemCode" = v_old_item and coalesce(s."VariantCode", '') = coalesce(v_old_variation, '')
  limit 1;
  if v_serial is not null then
    raise exception 'Serial % is already tagged to this line''s current variant - the item can''t be changed now.', v_serial;
  end if;

  -- Same wording as the POS line, with just the variant part swapped when it's in there
  -- ("DUALSTAND-50G (...) - AST-003-BlackPaint" -> "... - AST-003-WhitePaint").
  v_new_desc := public._order_line_variant_swap_description(v_line."Description", v_old_variation, v_new.variation_id);

  -- The POS keeps sending its ORIGINAL variant - remember that one, not an earlier portal change.
  select * into v_ov from public."AdvanceOrderLineOverrides" where "TransactionNo" = p_no and "LineNo" = p_line_no;
  v_has_ov := found;
  v_pos_variation := case when v_has_ov then v_ov."PosVariationId" else nullif(trim(v_line."VariationId"), '') end;

  if v_pos_variation is not distinct from v_new.variation_id then
    -- Changed back to what the POS has: no override needed.
    delete from public."AdvanceOrderLineOverrides" where "TransactionNo" = p_no and "LineNo" = p_line_no;
  else
    insert into public."AdvanceOrderLineOverrides"
      ("TransactionNo", "LineNo", "PosVariationId", "VariationId", "Description", "ChangedBy", "ChangedAtUtc")
    values (p_no, p_line_no, v_pos_variation, v_new.variation_id, left(v_new_desc, 500), p_admin_username, now())
    on conflict ("TransactionNo", "LineNo") do update
      set "VariationId" = excluded."VariationId", "Description" = excluded."Description",
          "ChangedBy" = excluded."ChangedBy", "ChangedAtUtc" = now();
  end if;

  update public."AdvanceOrderLines"
     set "VariationId" = v_new.variation_id, "Description" = left(v_new_desc, 500)
   where "TransactionNo" = p_no and "LineNo" = p_line_no;

  insert into public."OrderLineVariantChanges"
    ("OrderKind", "OrderNo", "LineNo", "OldVariationId", "OldDescription", "NewVariationId", "NewDescription", "ChangedBy")
  values ('Advance', p_no, p_line_no, v_old_variation, v_line."Description", v_new.variation_id, v_new_desc, p_admin_username);

  return jsonb_build_object('old_description', v_line."Description", 'new_description', v_new_desc);
end;
$$;

grant execute on function public.staff_change_advance_order_line_variant(text, text, text, text, text) to anon;

-- ============================================================================
-- 7. Repair: advance lines changed by the first version of this file lost the variant from their text
--    (e.g. "AST-003 - DUALSTAND-50G (...)" with no colour). Rebuild it from the POS's original line text.
-- ============================================================================

do $$
declare
  v_ov record;
  v_orig text;
  v_desc text;
begin
  for v_ov in select * from public."AdvanceOrderLineOverrides" loop
    select c."OldDescription" into v_orig
    from public."OrderLineVariantChanges" c
    where c."OrderKind" = 'Advance' and c."OrderNo" = v_ov."TransactionNo" and c."LineNo" = v_ov."LineNo"
    order by c."Id" limit 1;
    v_desc := left(public._order_line_variant_swap_description(v_orig, v_ov."PosVariationId", v_ov."VariationId"), 500);
    if v_desc is not null and v_desc is distinct from v_ov."Description" then
      update public."AdvanceOrderLineOverrides" set "Description" = v_desc
       where "TransactionNo" = v_ov."TransactionNo" and "LineNo" = v_ov."LineNo";
      update public."AdvanceOrderLines" set "Description" = v_desc
       where "TransactionNo" = v_ov."TransactionNo" and "LineNo" = v_ov."LineNo";
    end if;
  end loop;
end;
$$;

notify pgrst, 'reload schema';

-- Result: every line changed so far, with its text now.
select c."OrderKind" as kind, c."OrderNo" as order_no, c."LineNo" as line_no,
       c."OldDescription" as was, coalesce(l."Description", c."NewDescription") as now_shows,
       c."NewVariationId" as new_variation_id, c."ChangedBy" as changed_by, c."ChangedAtUtc" as changed_at
from public."OrderLineVariantChanges" c
left join public."AdvanceOrderLines" l
       on c."OrderKind" = 'Advance' and l."TransactionNo" = c."OrderNo" and l."LineNo" = c."LineNo"
order by c."Id" desc;
