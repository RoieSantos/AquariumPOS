-- "Add COD Items" on the Advance Order card - per "a customer has an advance order ... now they want to add
-- new products but it will be COD" / "can we build that button?". Super Users, Sales Users and Production Managers.
--
-- The advance order itself is NOT changed: its lines, Downpayment and Balance belong to the POS, which pushes
-- them up every 5 minutes, and POS Pay In Full collects its own local Balance. The items go on a NEW confirmed
-- portal online order instead (same shape as admin_confirm_bot_order / staff_create_order_return), with nothing
-- paid, so the whole amount is the COD balance. AdvanceOrderAddOns links the two.
--
-- Delivery: same customer + address + date = one drop (supabase_delivery_combined_drops.sql), so the name,
-- address and contact no. default to what the advance order's delivery stop has. The new order still has to be
-- put on that date - it isn't scheduled here. No delivery fee on the add-on (the drop's fee stays one charge).
-- Pickup: the cashier collects it with POS Online Pay using the AO- number (supabase_pos_online_pay.sql).
--
-- Not linked to the customer's Messenger chat (no Psid), so no customer messages go out for it.
-- Refused once the advance order is voided or shipped.
-- Custom aquariums / stands / sumps come in priced by the calculator, as with Conversations' Create Order; they
-- go to the makers like any custom online order. Standalone stickers aren't offered here yet.
--
-- Run AFTER supabase_online_order_add_line.sql, supabase_online_order_returns.sql,
-- supabase_advance_order_customer_tag.sql and supabase_advance_order_void.sql. Safe to re-run.
-- Also needs _production_is_manager (supabase_production_orders.sql - don't re-run that file). Needs js/onlineOrders.js ?v=addoncod3.

set lock_timeout = '10s';

create table if not exists public."AdvanceOrderAddOns" (
  "OnlineOrderID" text primary key,
  "TransactionNo" varchar(100) not null,
  "ClientKey" text not null unique,    -- one per dialog, so a retry after a lost reply can't make a second order
  "CreatedBy" text,
  "CreatedAtUtc" timestamptz not null default now()
);

create index if not exists "IX_AdvanceOrderAddOns_TransactionNo" on public."AdvanceOrderAddOns" ("TransactionNo");

alter table public."AdvanceOrderAddOns" enable row level security;
revoke all on public."AdvanceOrderAddOns" from anon, authenticated;

-- Super User, Sales User or Production Manager. Change Item / Add Item keep their own narrower check.
create or replace function public._can_add_advance_cod_items(p_username text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public._can_change_order_line_item(p_username) or public._production_is_manager(p_username);
$$;

revoke execute on function public._can_add_advance_cod_items(text) from public, anon, authenticated;

-- ============================================================================
-- 1. Create
-- ============================================================================

drop function if exists public.staff_create_advance_order_cod_addon(text, text, text, text, text, text, text, jsonb, text);

create or replace function public.staff_create_advance_order_cod_addon(
  p_admin_username text,
  p_admin_password text,
  p_no text,
  p_fulfillment text,      -- 'Delivery' / 'Pickup'
  p_address text,
  p_phone text,
  p_client_key text,
  -- Catalog: { variation_id, quantity, price (null = list price), note }.
  -- Custom build (priced by the calculator): { category_code, item_name, quantity, price, note }.
  p_lines jsonb,
  p_customer_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
set lock_timeout = '10000'
as $$
declare
  v_no text := trim(coalesce(p_no, ''));
  v_key text := nullif(trim(coalesce(p_client_key, '')), '');
  v_fulfillment text := trim(coalesce(p_fulfillment, ''));
  v_address text := nullif(trim(coalesce(p_address, '')), '');
  v_phone text := nullif(trim(coalesce(p_phone, '')), '');
  v_advance public."AdvanceOrders"%rowtype;
  v_customer text;
  v_warehouse_id text;
  v_warehouse_name text;
  v_order_no text;
  v_existing text;
  v_line jsonb;
  v_new record;
  v_custom_category text;
  v_custom_code text;
  v_custom_variation text;
  v_label text;
  v_list_price numeric;
  v_glass text;
  v_qty int;
  v_price numeric(18, 2);
  v_amount numeric(18, 2);
  v_note text;
  v_entry_no bigint;
  v_total numeric(18, 2) := 0;
  v_notes text;
  v_by text;
  v_now timestamptz := now();
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._can_add_advance_cod_items(p_admin_username) then
    raise exception 'Only a Super User, Sales User or Production Manager can add COD items.';
  end if;
  if v_key is null then
    raise exception 'Close the dialog and try again.';
  end if;
  if v_fulfillment not in ('Delivery', 'Pickup') then
    raise exception 'Choose Delivery or Pickup.';
  end if;
  if v_fulfillment = 'Delivery' and v_address is null then
    raise exception 'Enter the delivery address.';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Add at least one product.';
  end if;

  -- Holds other tries for this order until this one commits, so the ClientKey check below is safe.
  begin
    select * into v_advance from public."AdvanceOrders" where "TransactionNo" = v_no for update;
  exception when lock_not_available then
    raise exception 'Advance order % is busy. Wait a moment and try again.', v_no;
  end;
  if v_advance."TransactionNo" is null then
    raise exception 'Advance order % not found.', v_no;
  end if;

  select "OnlineOrderID" into v_existing from public."AdvanceOrderAddOns" where "ClientKey" = v_key;
  if v_existing is not null then
    return jsonb_build_object('order_id', v_existing,
                              'total', (select "MoneyToCollect" from public."OnlineOrders" where "OrderID" = v_existing));
  end if;

  if v_advance."IsVoid" is true then
    raise exception 'Advance order % was voided.', v_no;
  end if;
  if exists (select 1 from public."AdvanceOrderProduction" p where p."TransactionNo" = v_no and p."ShippedAtUtc" is not null) then
    raise exception 'Advance order % has already shipped - create a separate order instead.', v_no;
  end if;

  select w."ID", w."Name" into v_warehouse_id, v_warehouse_name
    from public."Warehouses" w
   where lower(trim(w."Name")) = lower(trim(coalesce(v_advance."Warehouse", '')))
   limit 1;
  if v_warehouse_id is null then
    raise exception 'Advance order % has no branch, so the COD order has nowhere to ship from.', v_no;
  end if;

  v_customer := coalesce(nullif(trim(coalesce(p_customer_name, '')), ''), nullif(trim(v_advance."CustomerName"), ''), '-');
  select coalesce(nullif(trim("DisplayName"), ''), "Username") into v_by
    from public."StaffUsers" where "Username" = p_admin_username;
  v_order_no := public._next_no_series_number('AUTOMATED-ORDER', '');
  v_notes := left(format('COD add-on to advance order %s (receipt %s).', v_no, coalesce(v_advance."ReceiptNo", '-')), 1000);

  -- Already confirmed, so the same shape admin_confirm_bot_order leaves behind. Totals are set after the lines.
  insert into public."AutomatedOrders" (
    "OrderNo", "CustomerName", "CustomerPhone", "FulfillmentType", "DeliveryAddress", "Notes", "Status",
    "EstimatedTotal", "Location", "UpdatedBy", "UpdatedAtUtc",
    "PancakeSyncStatus", "PancakeReceiptNo", "ConfirmationMessageStatus"
  ) values (
    v_order_no, v_customer, coalesce(v_phone, ''), v_fulfillment,
    case when v_fulfillment = 'Delivery' then v_address end,
    v_notes, 'Confirmed', 0, left(v_warehouse_name, 20), p_admin_username, v_now,
    'Portal', v_order_no, 'Skipped'
  );

  insert into public."OnlineOrders" (
    "OrderID", "Date", "Time", "Status", "CustomerName", "LocationID",
    "MoneyToCollect", "AmountPaid", "Discount", "Balance",
    "ForDelivery", "ShippingAddress", "ShippingPhone", "PrintCount",
    "Last_Updated_At", "SyncedAtUtc", "ReceivedAtShop",
    "GlassThicknessCheckedAt", "NotePrintCheckedAt",
    "CreatedBy", "ConfirmedBy", "ConfirmedAtUtc", "Source"
  ) values (
    v_order_no,
    (v_now at time zone 'Asia/Manila')::date,
    to_char(v_now at time zone 'Asia/Manila', 'HH24:MI:SS'),
    'Confirmed', v_customer, v_warehouse_id,
    0, 0, 0, 0,
    v_fulfillment = 'Delivery',
    case when v_fulfillment = 'Delivery' then v_address end,
    v_phone, 0,
    v_now, v_now, false, v_now, v_now,
    p_admin_username, coalesce(v_by, p_admin_username), v_now, 'Portal'
  );

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_custom_category := upper(nullif(trim(coalesce(v_line->>'category_code', '')), ''));
    if v_custom_category is not null then
      if v_custom_category not in ('CUSTOM-AQUARIUM', 'CUSTOM-STAND', 'CUSTOM-SUMP') then
        raise exception 'Unknown custom item type %.', v_custom_category;
      end if;
      v_label := nullif(trim(coalesce(v_line->>'item_name', '')), '');
      if v_label is null or (v_line->>'price') is null then
        raise exception 'A custom item is missing its description or price - build it again.';
      end if;
      -- Same placeholder product admin_confirm_bot_order gives a custom line.
      select c."Code", c."VariationId" into v_custom_code, v_custom_variation
        from public."Items" c
       where c."Name" = v_custom_category or c."Code" = v_custom_category
       order by c."IsActive" desc, (c."Code" = v_custom_category) desc
       limit 1;
      v_custom_code := coalesce(v_custom_code, v_custom_category);
      v_list_price := null;
    else
      select * into v_new from public._order_line_variant_candidates() c
       where c.variation_id = trim(coalesce(v_line->>'variation_id', '')) limit 1;
      if not found then
        raise exception 'A product wasn''t found - search and pick it again.';
      end if;
      v_label := v_new.label;
      v_list_price := v_new.price;
    end if;

    if (v_line->>'quantity') is null or (v_line->>'quantity')::numeric < 1
       or (v_line->>'quantity')::numeric <> trunc((v_line->>'quantity')::numeric) then
      raise exception 'Quantity for % must be a whole number, 1 or more.', v_label;
    end if;
    v_qty := (v_line->>'quantity')::int;
    if (v_line->>'price')::numeric < 0 then
      raise exception 'Unit Price for % can''t be negative.', v_label;
    end if;
    v_price := round(coalesce((v_line->>'price')::numeric, v_list_price, 0), 2);
    v_amount := v_price * v_qty;
    v_note := nullif(trim(coalesce(v_line->>'note', '')), '');

    if v_custom_category is not null then
      insert into public."AutomatedOrderLines"
        ("OrderNo", "CategoryCode", "ItemCode", "ItemName", "Quantity", "Price", "Notes", "VariationId")
      values (v_order_no, v_custom_category, null, left(v_label, 255), v_qty, v_price, v_note, null)
      returning "EntryNo" into v_entry_no;

      insert into public."OnlineOrderLines" (
        "OrderID", "LineID", "ItemCode", "product_display_id", "VariationId", "Quantity", "UnitCost", "Price",
        "Discount", "GrossAmount", "NetAmount", "Note", "Description", "SyncedAtUtc"
      ) values (
        v_order_no, v_entry_no::text, v_custom_code, v_custom_code, nullif(trim(coalesce(v_custom_variation, '')), ''), v_qty, null, v_price,
        0, v_amount, v_amount, v_note, left(v_label, 500), v_now
      );
    else
      insert into public."AutomatedOrderLines"
        ("OrderNo", "CategoryCode", "ItemCode", "ItemName", "Quantity", "Price", "Notes", "VariationId")
      values (
        v_order_no,
        left(nullif(trim(coalesce(public._online_order_line_category(v_new.variation_id, v_new.item_code), '')), ''), 100),
        v_new.item_code, left(v_new.label, 255), v_qty, v_price, v_note, v_new.variation_id
      )
      returning "EntryNo" into v_entry_no;

      insert into public."OnlineOrderLines" (
        "OrderID", "LineID", "ItemCode", "product_display_id", "VariationId", "Quantity", "UnitCost", "Price",
        "Discount", "GrossAmount", "NetAmount", "Note", "Description", "SyncedAtUtc"
      ) values (
        v_order_no, v_entry_no::text, v_new.item_code, v_new.item_code, v_new.variation_id, v_qty, null, v_price,
        0, v_amount, v_amount, v_note, left(v_new.label, 500), v_now
      );
    end if;

    v_total := v_total + v_amount;
  end loop;

  -- Same 12mm / 10mm flag rule as admin_confirm_bot_order.
  select case
           when bool_or(regexp_replace(coalesce(l."ItemName", '') || coalesce(l."Notes", '') || coalesce(l."ItemCode", ''), '[[:space:]]+', '', 'g') ilike '%12mm%') then '12mm'
           when bool_or(regexp_replace(coalesce(l."ItemName", '') || coalesce(l."Notes", '') || coalesce(l."ItemCode", ''), '[[:space:]]+', '', 'g') ilike '%10mm%') then '10mm'
         end
    into v_glass
    from public."AutomatedOrderLines" l where l."OrderNo" = v_order_no;

  update public."AutomatedOrders" set "EstimatedTotal" = v_total where "OrderNo" = v_order_no;
  update public."OnlineOrders" set "MoneyToCollect" = v_total, "Balance" = v_total, "GlassThickness" = v_glass where "OrderID" = v_order_no;

  insert into public."AdvanceOrderAddOns" ("OnlineOrderID", "TransactionNo", "ClientKey", "CreatedBy")
  values (v_order_no, v_no, v_key, p_admin_username);

  return jsonb_build_object('order_id', v_order_no, 'total', v_total);
end;
$$;

grant execute on function public.staff_create_advance_order_cod_addon(text, text, text, text, text, text, text, jsonb, text) to anon;

-- ============================================================================
-- 2. Read: the card's add-on list + the details the dialog starts with
-- ============================================================================

drop function if exists public.staff_get_advance_order_cod_addons(text, text, text);

create or replace function public.staff_get_advance_order_cod_addons(
  p_admin_username text,
  p_admin_password text,
  p_no text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_no text := trim(coalesce(p_no, ''));
  v_advance public."AdvanceOrders"%rowtype;
  v_stop record;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not (public._can_open_order_return(p_admin_username) or public._production_is_manager(p_admin_username)) then
    raise exception 'Not authorized.';
  end if;

  select * into v_advance from public."AdvanceOrders" where "TransactionNo" = v_no;
  select s."DeliveryDate", nullif(trim(s."ManualCustomerName"), '') as name,
         nullif(trim(s."ManualAddress"), '') as address, nullif(trim(s."ManualContactNumber"), '') as phone
    into v_stop
    from public."DeliveryStops" s
   where s."AdvanceTransactionNo" = v_no
   order by s."DeliveryDate" desc
   limit 1;

  return jsonb_build_object(
    'customer_name', coalesce(v_stop.name, v_advance."CustomerName"),
    'address', coalesce(v_stop.address, nullif(trim(v_advance."CustomerAddress"), '')),
    'phone', coalesce(v_stop.phone, nullif(trim(v_advance."CustomerMobile"), '')),
    'delivery_date', v_stop."DeliveryDate",
    'addons', coalesce((
      select jsonb_agg(jsonb_build_object(
               'order_id', a."OnlineOrderID", 'status', o."Status", 'total', o."MoneyToCollect",
               'balance', o."Balance", 'created_by', a."CreatedBy", 'created_at', a."CreatedAtUtc")
             order by a."CreatedAtUtc")
        from public."AdvanceOrderAddOns" a
        left join public."OnlineOrders" o on o."OrderID" = a."OnlineOrderID"
       where a."TransactionNo" = v_no), '[]'::jsonb)
  );
end;
$$;

grant execute on function public.staff_get_advance_order_cod_addons(text, text, text) to anon;

-- Product search for the dialog. Its own function because staff_search_order_line_variants is limited to
-- Change Item's roles, and Production Managers shouldn't get Change Item from this.
drop function if exists public.staff_search_advance_cod_items(text, text, text);

create or replace function public.staff_search_advance_cod_items(
  p_admin_username text,
  p_admin_password text,
  p_query text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_query text := nullif(trim(coalesce(p_query, '')), '');
  v_result jsonb;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._can_add_advance_cod_items(p_admin_username) then
    raise exception 'Only a Super User, Sales User or Production Manager can add COD items.';
  end if;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.name, r.sku), '[]'::jsonb) into v_result
  from (
    select distinct on (c.variation_id)
           c.variation_id, c.item_code, c.name, c.label, c.sku, c.price
    from public._order_line_variant_candidates() c
    where v_query is not null
      and (c.item_code || ' ' || c.name || ' ' || c.description || ' ' || c.sku) ilike '%' || v_query || '%'
    order by c.variation_id
    limit 60
  ) r;

  return jsonb_build_object('options', v_result);
end;
$$;

grant execute on function public.staff_search_advance_cod_items(text, text, text) to anon;

-- The advance order an online order was added to (null = not an add-on), for the Online Order card.
drop function if exists public.staff_get_order_cod_addon_parent(text, text, text);

create or replace function public.staff_get_order_cod_addon_parent(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns text
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return (select "TransactionNo"::text from public."AdvanceOrderAddOns" where "OnlineOrderID" = trim(coalesce(p_order_id, '')));
end;
$$;

grant execute on function public.staff_get_order_cod_addon_parent(text, text, text) to anon;

notify pgrst, 'reload schema';
