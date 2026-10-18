-- Edit an online order line's Description, Quantity, Unit Price and Note in the Lines grid (Business Central
-- style) - Super Users and Sales Users. Per "can you allow a sales user change the note and details of the order
-- lines.. but add a history who last change it" / "can we edit same way the business central do? i need to
-- edit unit price too" / "is it possible we edit the quantity too?".
--
-- The item itself stays (Change Item swaps it). Every change is logged in OrderLineEditHistory (one row per field, old -> new,
-- who, when); the Online Orders card shows "Edited by X" under each line plus a History list.
--
-- QUANTITY only before To Ship (stock / serials are taken from To Ship on), and not while a serial is
-- already tagged to the order for that line's item. The Item Ledger follows on its own
-- (TR_OnlineOrderLines_ItemLedgerQueue re-posts the order on a Quantity change). Portal orders keep the
-- AutomatedOrderLines quantity in step.
--
-- UNIT PRICE / QUANTITY move the money with them: Money to Collect and Balance shift by
-- (new price x new qty) - (old price x old qty) (less Pancake's per-unit discount on the qty difference),
-- the same way the portal Delivery Fee edit does (supabase_online_order_portal_delivery_fee.sql). Portal
-- orders also keep the source AutomatedOrderLines price / AutomatedOrders EstimatedTotal in step (receipt,
-- invoice, GMA order card). For Pancake orders Pancake recomputes its own total and the 1-minute sync
-- re-reads it anyway.
--
-- PANCAKE ORDERS: Pancake owns the lines, so the change is pushed there the same way as Change Item
-- (supabase_order_line_change_variant.sql): GET -> rebuild ALL items with this one line changed -> PATCH
-- (PUT fallback) -> restore bank_payments -> re-sync. If Pancake's answer shows it put a stocked product's
-- own name / price back, that field is reported as not kept (description_kept / price_kept = false) and is
-- not logged or moved locally. PORTAL-ONLY orders (Source 'Portal') are edited in OnlineOrderLines directly.
--
-- Not on Shipped / Delivered / Completed / Received / Cancelled / Returned orders, nor walk-ins (posted POS
-- receipts - the card doesn't offer it). Advance orders aren't covered (their lines come from the POS).
--
-- Replaces supabase_online_order_line_edit_note.sql (never run - deleted). Run AFTER
-- supabase_order_line_change_variant.sql and supabase_bot_orders_portal_confirm.sql. Safe to re-run.
-- Needs js/onlineOrders.js ?v=lineedit3.

-- ============================================================================
-- 1. History table
-- ============================================================================

create table if not exists public."OrderLineEditHistory" (
  "Id" bigserial primary key,
  "OrderKind" text not null default 'Online',
  "OrderNo" text not null,
  "LineNo" text not null,
  "Field" text not null,                  -- 'Description' / 'Quantity' / 'Unit Price' / 'Note'
  "OldValue" text,
  "NewValue" text,
  "ChangedBy" text not null,
  "ChangedAtUtc" timestamptz not null default now()
);

create index if not exists "IX_OrderLineEditHistory_Order" on public."OrderLineEditHistory" ("OrderKind", "OrderNo", "Id" desc);

alter table public."OrderLineEditHistory" enable row level security;
revoke all on public."OrderLineEditHistory" from anon, authenticated;

-- ============================================================================
-- 2. Edit (p_description / p_note: the line's full new value; p_price / p_quantity null = leave as is)
-- ============================================================================

drop function if exists public.staff_edit_online_order_line_text(text, text, text, text, text, text);
drop function if exists public.staff_edit_online_order_line(text, text, text, text, text, text, numeric);
drop function if exists public.staff_edit_online_order_line(text, text, text, text, text, text, numeric, numeric);

create or replace function public.staff_edit_online_order_line(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_line_id text,
  p_description text,
  p_note text,
  p_price numeric default null,
  p_quantity numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '45000'
set lock_timeout = '10000'
as $$
declare
  v_order_id text := trim(coalesce(p_order_id, ''));
  v_line_id text := trim(coalesce(p_line_id, ''));
  v_new_desc text := nullif(trim(coalesce(p_description, '')), '');
  v_new_note text := nullif(trim(coalesce(p_note, '')), '');
  v_new_price numeric(18, 2) := round(p_price, 2);
  v_new_qty numeric := p_quantity;
  v_qty_changed boolean;
  v_disc_each numeric := 0;
  v_variation text;
  v_item_code text;
  v_serial text;
  v_portal boolean;
  v_found boolean;
  v_status text;
  v_old_desc text;
  v_old_note text;
  v_old_price numeric(18, 2);
  v_qty numeric;
  v_desc_changed boolean;
  v_note_changed boolean;
  v_price_changed boolean;
  v_desc_kept boolean := true;
  v_price_kept boolean := true;
  v_delta numeric(18, 2) := 0;
  v_url text;
  v_get_response extensions.http_response;
  v_get_body jsonb;
  v_order_obj jsonb;
  v_bank_payments jsonb;
  v_items jsonb;
  v_body jsonb;
  v_patch_response extensions.http_response;
  v_put_response extensions.http_response;
  v_resp jsonb;
  v_resp_item jsonb;
  v_resynced boolean := true;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not exists (select 1 from public."StaffUsers" s
                    where s."Username" = p_admin_username and s."IsActive"
                      and (coalesce(s."SuperUser", false) or coalesce(s."SalesUser", false))) then
    raise exception 'Only a Super User or Sales User can edit an order line.';
  end if;
  if v_new_price is not null and v_new_price < 0 then
    raise exception 'Unit Price can''t be negative.';
  end if;
  if v_new_qty is not null and v_new_qty <= 0 then
    raise exception 'Quantity must be more than 0.';
  end if;

  begin
    select "Status", true into v_status, v_found from public."OnlineOrders" where "OrderID" = v_order_id for update;
  exception when lock_not_available then
    raise exception 'Order % is busy (another update is still running on it). Wait a moment and try again.', v_order_id;
  end;
  if not coalesce(v_found, false) then
    raise exception 'Order % not found.', v_order_id;
  end if;
  if lower(trim(coalesce(v_status, ''))) in ('shipped', 'delivered', 'completed', 'received', 'canceled', 'cancelled',
                                             'returned', 'returning', 'deleted') then
    raise exception 'Order % is % - its lines can no longer be edited.', v_order_id, v_status;
  end if;

  v_portal := public._is_portal_only_online_order(v_order_id);

  if v_portal then
    -- ---- Portal-only order: edit the line here.
    select l."Description", l."Note", l."Price", l."Quantity", nullif(trim(l."VariationId"), ''), l."ItemCode"
      into v_old_desc, v_old_note, v_old_price, v_qty, v_variation, v_item_code
    from public."OnlineOrderLines" l where l."OrderID" = v_order_id and l."LineID" = v_line_id;
    if not found then
      raise exception 'Line % is no longer on order % - close and reopen the order.', v_line_id, v_order_id;
    end if;
  else
    -- ---- Pancake order: rebuild ALL items from Pancake's own copy with this one line changed.
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

    create temp table if not exists _line_edit_items (
      ord int, line_id text, variation_id text, item_code text, name text, detail text,
      quantity numeric, price numeric, note text,
      discount jsonb, is_bonus jsonb, is_discount_percent jsonb, is_wholesale jsonb
    ) on commit drop;
    truncate _line_edit_items;

    insert into _line_edit_items
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

    select name, note, price, quantity, variation_id, item_code,
           case when jsonb_typeof(discount) = 'number' and is_discount_percent = 'false'::jsonb
                then (discount #>> '{}')::numeric else 0 end
      into v_old_desc, v_old_note, v_old_price, v_qty, v_variation, v_item_code, v_disc_each
    from _line_edit_items where line_id = v_line_id;
    if not found then
      raise exception 'Line % is no longer on order % in Pancake - close and reopen the order, then try again.', v_line_id, v_order_id;
    end if;
  end if;

  v_new_desc := coalesce(v_new_desc, v_old_desc); -- the Description can't be blanked
  v_new_price := coalesce(v_new_price, v_old_price);
  v_new_qty := coalesce(v_new_qty, v_qty);
  v_qty_changed := v_new_qty is distinct from v_qty;
  v_desc_changed := v_new_desc is distinct from v_old_desc;
  v_note_changed := v_new_note is distinct from nullif(trim(coalesce(v_old_note, '')), '');
  v_price_changed := v_new_price is distinct from v_old_price;
  if not v_desc_changed and not v_note_changed and not v_price_changed and not v_qty_changed then
    raise exception 'Nothing changed.';
  end if;

  if v_qty_changed then
    if lower(trim(coalesce(v_status, ''))) in ('to ship', 'packing', 'packed', 'in-transit', 'pending transfer') then
      raise exception 'Order % is % - the quantity can only be changed before To Ship.', v_order_id, v_status;
    end if;
    select s."SerialNo" into v_serial from public."ItemSerialTracking" s
    where s."SoldOnlineOrderId" = v_order_id and s."Status" = 'SOLD'
      and ((v_variation is not null and coalesce(s."VariantCode", '') = v_variation)
           or (v_item_code is not null and s."ItemCode" = v_item_code))
    limit 1;
    if v_serial is not null then
      raise exception 'Serial % is already tagged to this line''s item - untag it before changing the quantity.', v_serial;
    end if;
  end if;

  if v_portal then
    update public."OnlineOrderLines"
       set "Description" = left(v_new_desc, 500),
           "Note" = v_new_note,
           "Price" = v_new_price,
           "Quantity" = v_new_qty,
           "GrossAmount" = v_new_price * v_new_qty,
           "NetAmount" = v_new_price * v_new_qty - coalesce("Discount", 0),
           "SyncedAtUtc" = now()
     where "OrderID" = v_order_id and "LineID" = v_line_id;
  else
    update _line_edit_items
       set name = case when v_desc_changed then left(v_new_desc, 500) else name end,
           detail = case when v_desc_changed then left(v_new_desc, 500) else detail end,
           note = v_new_note,
           price = v_new_price,
           quantity = v_new_qty
     where line_id = v_line_id;

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
        'retail_price', coalesce(price, 0),
        'weight', 100
      )
    ) order by ord)
    into v_items
    from _line_edit_items;

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
      v_patch_response := v_put_response;
    elsif v_patch_response.status < 200 or v_patch_response.status >= 300 then
      raise exception 'Pancake rejected the items update (HTTP %): %', v_patch_response.status, left(v_patch_response.content, 300);
    end if;

    -- Did Pancake keep the new name / price? (It may put a stocked product's own values back.)
    if v_desc_changed or v_price_changed then
      begin
        v_resp := v_patch_response.content::jsonb;
        v_resp := case when jsonb_typeof(v_resp -> 'data') = 'object' then v_resp -> 'data' else v_resp end;
        select it into v_resp_item
        from jsonb_array_elements(case when jsonb_typeof(v_resp -> 'items') = 'array' then v_resp -> 'items' else '[]'::jsonb end) it
        where coalesce(it ->> 'line_id', it ->> 'id', it ->> 'order_line_id', it ->> 'order_item_id', it ->> 'item_id') = v_line_id
        limit 1;
        if v_resp_item is not null then
          if v_desc_changed and trim(coalesce(v_resp_item -> 'variation_info' ->> 'name', v_resp_item ->> 'name', '')) <> left(v_new_desc, 500) then
            v_desc_kept := false;
          end if;
          if v_price_changed and round(public.pancake_parse_decimal(coalesce(v_resp_item -> 'variation_info' ->> 'retail_price',
                                                                              v_resp_item ->> 'retail_price')), 2) is distinct from v_new_price then
            v_price_kept := false;
          end if;
        end if;
      exception when others then
        null; -- can't tell - assume it was kept
      end;
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

  -- Money follows price / quantity: (new price x new qty) - (old price x old qty) onto Money to Collect / Balance.
  if not v_price_kept then
    v_new_price := v_old_price;
  end if;
  if (v_price_changed and v_price_kept) or v_qty_changed then
    v_delta := round(v_new_price * v_new_qty - coalesce(v_old_price, 0) * coalesce(v_qty, 0)
                     - coalesce(v_disc_each, 0) * (v_new_qty - coalesce(v_qty, 0)), 2);
    if v_portal then
      update public."AutomatedOrderLines" set "Price" = v_new_price, "Quantity" = v_new_qty
       where "OrderNo" = v_order_id and "EntryNo"::text = v_line_id;
    end if;
    if v_delta <> 0 then
      update public."OnlineOrders"
         set "MoneyToCollect" = coalesce("MoneyToCollect", 0) + v_delta,
             "Balance" = coalesce("Balance", 0) + v_delta
       where "OrderID" = v_order_id;
      if v_portal then
        update public."AutomatedOrders" set "EstimatedTotal" = coalesce("EstimatedTotal", 0) + v_delta
         where "OrderNo" = v_order_id;
      end if;
    end if;
  end if;

  if v_desc_changed and v_desc_kept then
    insert into public."OrderLineEditHistory" ("OrderKind", "OrderNo", "LineNo", "Field", "OldValue", "NewValue", "ChangedBy")
    values ('Online', v_order_id, v_line_id, 'Description', v_old_desc, v_new_desc, p_admin_username);
  end if;
  if v_price_changed and v_price_kept then
    insert into public."OrderLineEditHistory" ("OrderKind", "OrderNo", "LineNo", "Field", "OldValue", "NewValue", "ChangedBy")
    values ('Online', v_order_id, v_line_id, 'Unit Price', to_char(v_old_price, 'FM999,999,990.00'),
            to_char(v_new_price, 'FM999,999,990.00'), p_admin_username);
  end if;
  if v_qty_changed then
    insert into public."OrderLineEditHistory" ("OrderKind", "OrderNo", "LineNo", "Field", "OldValue", "NewValue", "ChangedBy")
    values ('Online', v_order_id, v_line_id, 'Quantity', rtrim(to_char(v_qty, 'FM999,999,990.####'), '.'),
            rtrim(to_char(v_new_qty, 'FM999,999,990.####'), '.'), p_admin_username);
  end if;
  if v_note_changed then
    insert into public."OrderLineEditHistory" ("OrderKind", "OrderNo", "LineNo", "Field", "OldValue", "NewValue", "ChangedBy")
    values ('Online', v_order_id, v_line_id, 'Note', nullif(trim(coalesce(v_old_note, '')), ''), v_new_note, p_admin_username);
  end if;

  return jsonb_build_object(
    'description_changed', v_desc_changed,
    'description_kept', v_desc_kept,
    'price_changed', v_price_changed,
    'price_kept', v_price_kept,
    'quantity_changed', v_qty_changed,
    'note_changed', v_note_changed,
    'money_delta', v_delta,
    'resynced', v_resynced);
end;
$$;

grant execute on function public.staff_edit_online_order_line(text, text, text, text, text, text, numeric, numeric) to anon;

-- ============================================================================
-- 3. History: every Description / Quantity / Unit Price / Note edit on the order, plus Change Item swaps - newest first.
--    Any signed-in staff can read it (the card shows "Edited by X" to everyone who opens the order).
-- ============================================================================

drop function if exists public.staff_list_online_order_line_edits(text, text, text);

create or replace function public.staff_list_online_order_line_edits(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(line_no text, field text, old_value text, new_value text, changed_by text, changed_by_name text,
              changed_at_utc timestamptz)
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
    select h.line_no, h.field, h.old_value, h.new_value, h.changed_by,
           coalesce(nullif(trim(s."DisplayName"), ''), h.changed_by)::text,
           h.changed_at_utc
    from (
      select e."LineNo"::text as line_no, e."Field"::text as field, e."OldValue"::text as old_value,
             e."NewValue"::text as new_value, e."ChangedBy"::text as changed_by, e."ChangedAtUtc" as changed_at_utc
      from public."OrderLineEditHistory" e
      where e."OrderKind" = 'Online' and e."OrderNo" = trim(coalesce(p_order_id, ''))
      union all
      select c."LineNo"::text, 'Item'::text, c."OldDescription"::text, c."NewDescription"::text,
             c."ChangedBy"::text, c."ChangedAtUtc"
      from public."OrderLineVariantChanges" c
      where c."OrderKind" = 'Online' and c."OrderNo" = trim(coalesce(p_order_id, ''))
    ) h
    left join public."StaffUsers" s on s."Username" = h.changed_by
    order by h.changed_at_utc desc;
end;
$$;

grant execute on function public.staff_list_online_order_line_edits(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Check: both functions exist (and the history table).
select 'function' as section, p.proname::text as name, pg_get_function_identity_arguments(p.oid) as detail
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('staff_edit_online_order_line', 'staff_list_online_order_line_edits')
union all
select 'table', c.relname::text, (select count(*)::text || ' edit(s) logged' from public."OrderLineEditHistory")
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'OrderLineEditHistory'
order by 1, 2;
