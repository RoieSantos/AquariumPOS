-- Return / Exchange on a shipped online order: MANY lines -> ONE new item, and serial-tracked items - per
-- "we need many to one. in the original receipt the user will choose Item 1 item 2 or more then choose what item
-- they will exchange" / "If the item is serial tracked i want it to behave the same on how we are managing serials".
--
-- Builds on supabase_online_order_returns.sql (same table, same Receive / Refund / Cancel steps):
--
--   staff_list_order_return_lines(order)   The order's lines with how many can still be returned, whether the
--                                          item takes a serial, and the serials SOLD to this order for it that
--                                          aren't on a return yet.
--   staff_create_order_return_multi(order, lines [{line_id, quantity, serials: [RunningSerialNo]}], reason,
--                                   resolution, new item, new qty, dry_run)
--                                          One OnlineOrderReturns row per returned line (each still received on
--                                          its own), all sharing a ReturnGroup (= the first row's ReturnNo) and
--                                          ONE replacement order for the new item, priced at new total - the
--                                          lines' total credit (never below 0). The group's Customer Pays /
--                                          Refund Due sit on the first row; the others carry 0.
--   Serial-tracked lines (aquarium / stand / sump, _order_line_item_needs_serial): one serial ticked per unit,
--   SOLD to this order, not on another return. Saved in OnlineOrderReturnSerials. The serial stays SOLD while
--   the customer still has it, then on Receive - same rules as Repair Returns:
--     Resellable -> IN_STOCK at the order's branch (sold order / receipt cleared). To repair it, send it from
--                   the Repair Returns page afterwards.
--     Defective  -> SCRAPPED (the Defect Items report writes the unit off).
--   The Item Ledger posting is the same as any return (Positive Adjmt., + Negative Adjmt. if defective).
--   The new item, if it takes a serial, gets one the normal way on the replacement order (Ready to Ship /
--   To Ship from stock, or a build).
--   Refund: recorded on the group's first row, once EVERY row of the group is received.
--   Cancel: cancels the whole group (the price of the replacement order depended on all of it), only while
--   none of it is received and after the replacement order is cancelled.
--
-- Still NOT handled: SET lines and items that aren't stocked (e.g. a one-off custom build), order discount.
--
-- Who: Super User, Sales User, Store Manager and (per "can you let production manager access this feature in
-- the portal") Production Manager open / cancel returns. Receive: Super User, Production Manager (any branch)
-- or the branch's Store Manager. Record refund stays Super User only.
--
-- Run AFTER supabase_online_order_returns.sql and supabase_production_orders.sql (_production_is_manager) -
-- re-run this one if supabase_online_order_returns.sql is ever re-run (it would put back the old list / receive /
-- refund / cancel and the narrower _can_open_order_return). Safe to re-run. Needs js/onlineOrders.js
-- ?v=returnspm1. Ends with ONE result.

set lock_timeout = '10s';

-- Super User, Sales User, Store Manager or Production Manager (supabase_online_order_returns.sql's + PM).
create or replace function public._can_open_order_return(p_username text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public."StaffUsers" s
                 where s."Username" = p_username and s."IsActive"
                   and (coalesce(s."SuperUser", false) or coalesce(s."SalesUser", false) or coalesce(s."StoreManager", false)))
      or public._production_is_manager(p_username);
$$;

revoke execute on function public._can_open_order_return(text) from public, anon, authenticated;

-- Product search for the Exchange item. Its own function because staff_search_order_line_variants is Change
-- Item's (Super User / Sales User only), which refused Store Managers and Production Managers here.
drop function if exists public.staff_search_return_items(text, text, text);

create or replace function public.staff_search_return_items(p_admin_username text, p_admin_password text, p_query text)
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
     or not public._can_open_order_return(p_admin_username) then
    raise exception 'Only a Super User, Sales User, Store Manager or Production Manager can open a return.';
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

grant execute on function public.staff_search_return_items(text, text, text) to anon;

-- ============================================================================
-- 1. Group + serials
-- ============================================================================

alter table public."OnlineOrderReturns" add column if not exists "ReturnGroup" varchar(30);
create index if not exists "IX_OnlineOrderReturns_Group" on public."OnlineOrderReturns" ("ReturnGroup");

create table if not exists public."OnlineOrderReturnSerials" (
    "ReturnId" int not null references public."OnlineOrderReturns" ("Id") on delete cascade,
    "RunningSerialNo" bigint not null references public."ItemSerialTracking" ("RunningSerialNo"),
    "SerialNo" varchar(120),
    primary key ("ReturnId", "RunningSerialNo")
);
alter table public."OnlineOrderReturnSerials" enable row level security;
revoke all on public."OnlineOrderReturnSerials" from anon, authenticated;

-- The rows a return belongs with: its group, or just itself (returns made before groups).
create or replace function public._order_return_group_ids(p_id int)
returns setof int
language sql
stable
security definer
set search_path = public
as $$
  select r2."Id"
  from public."OnlineOrderReturns" r
  join public."OnlineOrderReturns" r2
    on (r."ReturnGroup" is not null and r2."ReturnGroup" = r."ReturnGroup") or r2."Id" = r."Id"
  where r."Id" = p_id;
$$;
revoke execute on function public._order_return_group_ids(int) from public, anon, authenticated;

-- Serials SOLD to this order for this line's item that aren't on an open / received return.
create or replace function public._order_return_line_serials(p_order_id text, p_item_code text, p_stock_item text)
returns table(running_serial_no bigint, serial_no text, variant_code text)
language sql
stable
security definer
set search_path = public
as $$
  select s."RunningSerialNo", s."SerialNo"::text, s."VariantCode"::text
  from public."ItemSerialTracking" s
  where s."Status" = 'SOLD'
    and s."SoldOnlineOrderId" = p_order_id
    and (s."ItemCode" = p_item_code or s."ItemCode" = p_stock_item)
    and not exists (select 1 from public."OnlineOrderReturnSerials" rs
                    join public."OnlineOrderReturns" r on r."Id" = rs."ReturnId"
                    where rs."RunningSerialNo" = s."RunningSerialNo" and r."Status" <> 'Cancelled')
  order by s."SerialNo";
$$;
revoke execute on function public._order_return_line_serials(text, text, text) from public, anon, authenticated;

-- ============================================================================
-- 2. Lines that can be returned (for the dialog)
-- ============================================================================

drop function if exists public.staff_list_order_return_lines(text, text, text);

create or replace function public.staff_list_order_return_lines(p_admin_username text, p_admin_password text, p_order_id text)
returns table(line_id text, description text, quantity numeric, returnable numeric, unit_credit numeric,
              needs_serial boolean, returnable_here boolean, why_not text, serials jsonb)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_order_id text := trim(coalesce(p_order_id, ''));
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._can_open_order_return(p_admin_username) then
    raise exception 'Only a Super User, Sales User, Store Manager or Production Manager can open a return.';
  end if;

  return query
    with l as (
      select ol.*,
             coalesce((select v."ItemCode" from public."Variants" v where v."VariationId" = ol."VariationId"), ol."ItemCode") as item,
             upper(coalesce(public._online_order_line_category(ol."VariationId", ol."ItemCode"), '')) = 'SET' as is_set,
             public._order_line_item_needs_serial(ol."VariationId", ol."ItemCode") as needs_serial
      from public."OnlineOrderLines" ol
      where ol."OrderID" = v_order_id
    ),
    k as (
      select l.*, sk.item_code as stock_item
      from l
      left join lateral public._ile_try_resolve_stock_key(l.item, nullif(trim(coalesce(l."VariationId", '')), '')) sk on true
    )
    select k."LineID"::text,
           coalesce(k."Description", k.item)::text,
           coalesce(k."Quantity", 0),
           greatest(coalesce(k."Quantity", 0) - coalesce((select sum(r."Quantity") from public."OnlineOrderReturns" r
                                                           where r."OrderID" = v_order_id and r."LineID" = k."LineID"
                                                             and r."Status" <> 'Cancelled'), 0), 0),
           round(coalesce(k."NetAmount", k."GrossAmount", coalesce(k."Price", 0) * k."Quantity", 0) / nullif(k."Quantity", 0), 2),
           k.needs_serial,
           not k.is_set and k.stock_item is not null,
           case when k.is_set then 'SET lines can''t be returned here yet.'
                when k.stock_item is null then 'Not a stocked item.' end,
           case when k.needs_serial then coalesce((
             select jsonb_agg(jsonb_build_object('running_serial_no', s.running_serial_no, 'serial_no', s.serial_no,
                                                 'variant_code', s.variant_code) order by s.serial_no)
             from public._order_return_line_serials(v_order_id, k.item, k.stock_item) s), '[]'::jsonb) end
    from k
    order by k."LineID";
end;
$$;

grant execute on function public.staff_list_order_return_lines(text, text, text) to anon;

-- ============================================================================
-- 3. Create (or preview): many lines -> one new item
-- ============================================================================

drop function if exists public.staff_create_order_return_multi(text, text, text, jsonb, text, text, text, int, boolean);

create or replace function public.staff_create_order_return_multi(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_lines jsonb,                 -- [{"line_id": "123", "quantity": 1, "serials": [4567]}, ...]
  p_reason text,
  p_resolution text,
  p_new_variation_id text default null,
  p_new_quantity int default null,
  p_dry_run boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
set lock_timeout = '10000'
as $$
declare
  v_order_id text := trim(coalesce(p_order_id, ''));
  v_resolution text := trim(coalesce(p_resolution, ''));
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_order public."OnlineOrders"%rowtype;
  v_source public."AutomatedOrders"%rowtype;
  v_line public."OnlineOrderLines"%rowtype;
  v_req jsonb;
  v_line_id text;
  v_qty numeric;
  v_serials bigint[];
  v_ok_serials bigint[];
  v_key record;
  v_new record;
  v_new_label text;
  v_warnings text[] := '{}';
  v_item text;
  v_already numeric;
  v_credit numeric(18, 2);
  v_total_credit numeric(18, 2) := 0;
  v_new_qty int;
  v_new_total numeric(18, 2) := 0;
  v_net_unit numeric(18, 2) := 0;
  v_pays numeric(18, 2) := 0;
  v_refund numeric(18, 2) := 0;
  v_group text;
  v_return_no text;
  v_return_id int;
  v_new_order text;
  v_location text;
  v_note text;
  v_entry_no bigint;
  v_by text;
  v_now timestamptz := now();
  v_first boolean := true;
  v_items jsonb := '[]'::jsonb;   -- validated lines: {line_id, qty, credit, item, variant, description, serials}
  v_it jsonb;
  v_returned_text text := '';
  v_return_nos text[] := '{}';
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._can_open_order_return(p_admin_username) then
    raise exception 'Only a Super User, Sales User, Store Manager or Production Manager can open a return.';
  end if;
  if v_resolution not in ('Exchange', 'Refund') then
    raise exception 'Choose Exchange or Refund.';
  end if;
  if jsonb_typeof(coalesce(p_lines, 'null'::jsonb)) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Tick at least one item being returned.';
  end if;
  if (select count(distinct e->>'line_id') from jsonb_array_elements(p_lines) e) <> jsonb_array_length(p_lines) then
    raise exception 'Each line can only be listed once.';
  end if;

  begin
    select * into v_order from public."OnlineOrders" where "OrderID" = v_order_id for update;
  exception when lock_not_available then
    raise exception 'Order % is busy (another update is still running on it). Wait a moment and try again.', v_order_id;
  end;
  if not found then
    raise exception 'Order % not found.', v_order_id;
  end if;
  if v_order."ReceivedAtShop" is true then
    raise exception 'Order % is a walk-in - it''s already a POS sale. Refund or exchange it at the POS instead.', v_order_id;
  end if;
  if lower(trim(coalesce(v_order."Status", ''))) not in ('shipped', 'delivered', 'completed', 'received') then
    raise exception 'Order % is % - a return needs a shipped order. Before that, use Change Item or Cancel Order.', v_order_id, coalesce(v_order."Status", 'blank');
  end if;
  if nullif(trim(coalesce(v_order."LocationID", '')), '') is null then
    raise exception 'Order % has no branch, so the return has nowhere to go.', v_order_id;
  end if;

  -- Validate every line first.
  for v_req in select * from jsonb_array_elements(p_lines) loop
    v_line_id := trim(coalesce(v_req->>'line_id', ''));
    v_qty := nullif(v_req->>'quantity', '')::numeric;
    if v_qty is null or v_qty < 1 or v_qty <> trunc(v_qty) then
      raise exception 'Quantity must be a whole number, 1 or more.';
    end if;

    select * into v_line from public."OnlineOrderLines" where "OrderID" = v_order_id and "LineID" = v_line_id;
    if not found then
      raise exception 'That line wasn''t found on order %.', v_order_id;
    end if;

    v_item := coalesce((select v."ItemCode" from public."Variants" v where v."VariationId" = v_line."VariationId"), v_line."ItemCode");
    if upper(coalesce(public._online_order_line_category(v_line."VariationId", v_line."ItemCode"), '')) = 'SET' then
      raise exception 'A SET line (%) can''t be returned here yet.', coalesce(v_line."Description", v_item);
    end if;
    select k.item_code, k.variant_id into v_key
      from public._ile_try_resolve_stock_key(v_item, nullif(trim(coalesce(v_line."VariationId", '')), '')) k;
    if v_key.item_code is null then
      raise exception '% isn''t a stocked item, so it can''t be returned here.', coalesce(v_line."Description", v_item, 'This line');
    end if;

    select coalesce(sum("Quantity"), 0) into v_already
      from public."OnlineOrderReturns"
     where "OrderID" = v_order_id and "LineID" = v_line_id and "Status" <> 'Cancelled';
    if v_qty + v_already > coalesce(v_line."Quantity", 0) then
      raise exception 'Only % of % can still be returned (% sold, % already on a return).',
        greatest(coalesce(v_line."Quantity", 0) - v_already, 0), coalesce(v_line."Description", v_item),
        coalesce(v_line."Quantity", 0), v_already;
    end if;

    -- Serial-tracked: exactly one serial per unit, sold to this order for this item, not already on a return.
    v_serials := '{}';
    if public._order_line_item_needs_serial(v_line."VariationId", v_line."ItemCode") then
      select coalesce(array_agg(distinct x.v::bigint), '{}') into v_serials
        from jsonb_array_elements_text(coalesce(v_req->'serials', '[]'::jsonb)) x(v);
      if cardinality(v_serials) <> v_qty then
        raise exception '% takes a serial - tick % serial(s) being returned (% ticked).',
          coalesce(v_line."Description", v_item), v_qty::int, cardinality(v_serials);
      end if;
      select coalesce(array_agg(s.running_serial_no), '{}') into v_ok_serials
        from public._order_return_line_serials(v_order_id, v_item, v_key.item_code) s
       where s.running_serial_no = any(v_serials);
      if cardinality(v_ok_serials) <> cardinality(v_serials) then
        raise exception 'A ticked serial for % isn''t sold to order % (or is already on a return). Reload and tick again.',
          coalesce(v_line."Description", v_item), v_order_id;
      end if;
    end if;

    v_credit := round(coalesce(v_line."NetAmount", v_line."GrossAmount", coalesce(v_line."Price", 0) * v_line."Quantity", 0)
                      / nullif(v_line."Quantity", 0) * v_qty, 2);
    v_total_credit := v_total_credit + v_credit;
    v_returned_text := v_returned_text || case when v_returned_text = '' then '' else ', ' end
                       || format('%s x %s', v_qty::int, coalesce(v_line."Description", v_item));
    v_items := v_items || jsonb_build_object(
      'line_id', v_line_id, 'qty', v_qty, 'credit', v_credit, 'item', v_key.item_code, 'variant', v_key.variant_id,
      'description', left(coalesce(v_line."Description", v_item), 500), 'serials', to_jsonb(v_serials));
  end loop;

  if v_resolution = 'Exchange' then
    v_new_qty := coalesce(p_new_quantity, 1);
    if v_new_qty < 1 then
      raise exception 'New quantity must be 1 or more.';
    end if;
    select * into v_new from public._order_line_variant_candidates() c
     where c.variation_id = trim(coalesce(p_new_variation_id, '')) limit 1;
    if not found then
      raise exception 'Pick the item they''re exchanging it for.';
    end if;
    v_new_label := v_new.label;
    v_new_total := round(coalesce(v_new.price, 0) * v_new_qty, 2);
    v_net_unit := round(greatest(v_new_total - v_total_credit, 0) / v_new_qty, 2);
    v_pays := v_net_unit * v_new_qty;
    v_refund := greatest(v_total_credit - v_new_total, 0);
  else
    v_refund := v_total_credit;
  end if;

  if coalesce(v_order."Balance", 0) > 0 then
    v_warnings := v_warnings || format('This order still has a balance of %s - the credit assumes the returned items were paid for.', to_char(v_order."Balance", 'FM999,999,990.00'));
  end if;
  if coalesce(v_order."Discount", 0) > 0 then
    v_warnings := v_warnings || format('This order has a %s order discount that isn''t taken off the credit.', to_char(v_order."Discount", 'FM999,999,990.00'));
  end if;

  if coalesce(p_dry_run, true) then
    return jsonb_build_object('credit', v_total_credit, 'new_total', v_new_total, 'customer_pays', v_pays,
                              'refund_due', v_refund, 'warnings', to_jsonb(v_warnings));
  end if;

  if v_reason is null then
    raise exception 'A reason is required.';
  end if;

  v_group := 'SR-' || lpad(nextval('public.order_return_no_seq')::text, 6, '0');

  if v_resolution = 'Exchange' then
    select * into v_source from public."AutomatedOrders" where "OrderNo" = v_order_id;
    select coalesce(nullif(trim(v_source."Location"), ''), left(w."Name", 20)) into v_location
      from public."Warehouses" w where w."ID" = v_order."LocationID";
    select coalesce(nullif(trim("DisplayName"), ''), "Username") into v_by
      from public."StaffUsers" where "Username" = p_admin_username;
    v_new_order := public._next_no_series_number('AUTOMATED-ORDER', '');
    v_note := left(format('Exchange %s for order %s: returned %s. List %s less credit %s.',
                          v_group, v_order_id, v_returned_text,
                          to_char(v_new_total, 'FM999,999,990.00'), to_char(least(v_total_credit, v_new_total), 'FM999,999,990.00')), 1000);

    -- Already confirmed, so the same shape admin_confirm_bot_order leaves behind (as supabase_online_order_returns.sql).
    insert into public."AutomatedOrders" (
      "OrderNo", "CustomerName", "CustomerPhone", "CustomerEmail", "FulfillmentType", "DeliveryAddress", "Notes", "Status",
      "EstimatedTotal", "Location", "Psid", "GmaPsid", "GmaPageId", "UpdatedBy", "UpdatedAtUtc",
      "PancakeSyncStatus", "PancakeReceiptNo", "ConfirmationMessageStatus"
    ) values (
      v_new_order, coalesce(nullif(trim(v_order."CustomerName"), ''), v_source."CustomerName", '-'),
      coalesce(nullif(trim(v_source."CustomerPhone"), ''), v_order."ShippingPhone", ''),
      v_source."CustomerEmail",
      case when v_order."ForDelivery" is true then 'Delivery' else 'Pickup' end,
      case when v_order."ForDelivery" is true then v_order."ShippingAddress" end,
      v_note, 'Confirmed', v_pays, v_location, v_source."Psid", v_source."GmaPsid", v_source."GmaPageId",
      p_admin_username, v_now, 'Portal', v_new_order, 'Skipped'
    );

    insert into public."AutomatedOrderLines"
      ("OrderNo", "CategoryCode", "ItemCode", "ItemName", "Quantity", "Price", "Notes", "VariationId")
    values (
      v_new_order,
      left(nullif(trim(coalesce(public._online_order_line_category(v_new.variation_id, v_new.item_code), '')), ''), 100),
      v_new.item_code, left(v_new.label, 255), v_new_qty, v_net_unit, v_note, v_new.variation_id
    )
    returning "EntryNo" into v_entry_no;

    insert into public."OnlineOrders" (
      "OrderID", "Date", "Time", "Status", "CustomerName", "LocationID",
      "MoneyToCollect", "AmountPaid", "Discount", "Balance",
      "ForDelivery", "ShippingAddress", "ShippingPhone", "PrintCount",
      "Last_Updated_At", "SyncedAtUtc", "ReceivedAtShop",
      "GlassThicknessCheckedAt", "NotePrintCheckedAt",
      "CreatedBy", "ConfirmedBy", "ConfirmedAtUtc", "Source"
    ) values (
      v_new_order,
      (v_now at time zone 'Asia/Manila')::date,
      to_char(v_now at time zone 'Asia/Manila', 'HH24:MI:SS'),
      'Confirmed', v_order."CustomerName", v_order."LocationID",
      v_pays, 0, 0, v_pays,
      v_order."ForDelivery", v_order."ShippingAddress", v_order."ShippingPhone", 0,
      v_now, v_now, false, v_now, v_now,
      p_admin_username, coalesce(v_by, p_admin_username), v_now, 'Portal'
    );

    insert into public."OnlineOrderLines" (
      "OrderID", "LineID", "ItemCode", "product_display_id", "VariationId", "Quantity", "UnitCost", "Price",
      "Discount", "GrossAmount", "NetAmount", "Note", "Description", "SyncedAtUtc"
    ) values (
      v_new_order, v_entry_no::text, v_new.item_code, v_new.item_code, v_new.variation_id, v_new_qty, null, v_net_unit,
      0, v_pays, v_pays, v_note, left(v_new.label, 500), v_now
    );
  end if;

  -- One row per returned line; the group's money on the first.
  for v_it in select * from jsonb_array_elements(v_items) loop
    v_return_no := case when v_first then v_group
                        else 'SR-' || lpad(nextval('public.order_return_no_seq')::text, 6, '0') end;
    insert into public."OnlineOrderReturns" (
      "ReturnNo", "ReturnGroup", "OrderID", "LineID", "ItemCode", "VariantId", "WarehouseId", "Description", "Quantity", "Reason",
      "Resolution", "CreditAmount", "NewDescription", "NewQuantity", "NewListTotal", "ReplacementOrderID",
      "CustomerPays", "RefundDue", "CreatedBy"
    ) values (
      v_return_no, v_group, v_order_id, v_it->>'line_id', v_it->>'item', nullif(v_it->>'variant', ''), v_order."LocationID",
      v_it->>'description', (v_it->>'qty')::numeric, left(v_reason, 1000),
      v_resolution, (v_it->>'credit')::numeric,
      left(v_new_label, 500),
      v_new_qty, case when v_resolution = 'Exchange' then v_new_total end, v_new_order,
      case when v_first then v_pays else 0 end, case when v_first then v_refund else 0 end, p_admin_username
    )
    returning "Id" into v_return_id;

    insert into public."OnlineOrderReturnSerials" ("ReturnId", "RunningSerialNo", "SerialNo")
    select v_return_id, s."RunningSerialNo", s."SerialNo"
    from public."ItemSerialTracking" s
    where s."RunningSerialNo" in (select x.v::bigint from jsonb_array_elements_text(v_it->'serials') x(v));

    v_return_nos := v_return_nos || v_return_no;
    v_first := false;
  end loop;

  return jsonb_build_object('return_no', v_group, 'return_nos', to_jsonb(v_return_nos), 'replacement_order_id', v_new_order,
                            'credit', v_total_credit, 'new_total', v_new_total, 'customer_pays', v_pays,
                            'refund_due', v_refund, 'warnings', to_jsonb(v_warnings));
end;
$$;

grant execute on function public.staff_create_order_return_multi(text, text, text, jsonb, text, text, text, int, boolean) to anon;

-- ============================================================================
-- 4. List: + group and serials (return type changes -> drop first)
-- ============================================================================

drop function if exists public.staff_list_order_returns(text, text, text);

create or replace function public.staff_list_order_returns(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(
  id int, return_no text, order_id text, description text, quantity numeric, reason text, resolution text,
  credit_amount numeric, new_description text, new_quantity int, replacement_order_id text, replacement_status text,
  customer_pays numeric, refund_due numeric, status text, condition text, created_by text, created_at_utc timestamptz,
  received_by text, received_at_utc timestamptz, photo_url text, defect_report_no text,
  refund_method text, refund_reference text, refunded_by text, refunded_at_utc timestamptz,
  return_group text, serial_nos text, group_all_received boolean
)
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
    select r."Id", r."ReturnNo"::text, r."OrderID"::text, r."Description"::text, r."Quantity", r."Reason"::text,
           r."Resolution"::text, r."CreditAmount", r."NewDescription"::text, r."NewQuantity",
           r."ReplacementOrderID"::text, o."Status"::text, r."CustomerPays", r."RefundDue", r."Status"::text,
           r."Condition"::text, r."CreatedBy"::text, r."CreatedAtUtc", r."ReceivedBy"::text, r."ReceivedAtUtc",
           r."PhotoUrl"::text, r."DefectReportNo"::text, r."RefundMethod"::text, r."RefundReference"::text,
           r."RefundedBy"::text, r."RefundedAtUtc",
           r."ReturnGroup"::text,
           (select string_agg(rs."SerialNo", ', ' order by rs."SerialNo") from public."OnlineOrderReturnSerials" rs
             where rs."ReturnId" = r."Id")::text,
           not exists (select 1 from public."OnlineOrderReturns" g
                       where g."Id" in (select public._order_return_group_ids(r."Id")) and g."Status" <> 'Received')
    from public."OnlineOrderReturns" r
    left join public."OnlineOrders" o on o."OrderID" = r."ReplacementOrderID"
    where r."OrderID" = trim(coalesce(p_order_id, '')) or r."ReplacementOrderID" = trim(coalesce(p_order_id, ''))
    order by r."Id" desc;
end;
$$;

grant execute on function public.staff_list_order_returns(text, text, text) to anon;

-- ============================================================================
-- 5. Receive: as supabase_online_order_returns.sql + the serials
-- ============================================================================

drop function if exists public.staff_receive_order_return(text, text, int, text, text, text, text);

create or replace function public.staff_receive_order_return(
  p_admin_username text,
  p_admin_password text,
  p_id int,
  p_condition text,
  p_note text default null,
  p_photo_path text default null,
  p_photo_url text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_caller record;
  v_return public."OnlineOrderReturns"%rowtype;
  v_warehouse_name text;
  v_condition text := trim(coalesce(p_condition, ''));
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_transaction_no bigint;
  v_defect_no text;
  v_serial_count int;
  v_moved int;
begin
  -- Super User or Store Manager (own branch), same as Defect Items - or a Production Manager, any branch.
  if public.is_staff_authorized(p_admin_username, p_admin_password) and public._production_is_manager(p_admin_username) then
    select true as is_super, null::text as warehouse_name into v_caller;
  else
    select * into v_caller from public._defect_caller(p_admin_username, p_admin_password);
  end if;

  select * into v_return from public."OnlineOrderReturns" where "Id" = p_id for update;
  if not found then
    raise exception 'Return not found.';
  end if;
  if v_return."Status" <> 'Open' then
    raise exception 'Return % is already %.', v_return."ReturnNo", lower(v_return."Status");
  end if;
  if v_condition not in ('Resellable', 'Defective') then
    raise exception 'Choose Resellable or Defective.';
  end if;

  select w."Name" into v_warehouse_name from public."Warehouses" w where w."ID" = v_return."WarehouseId";
  if not v_caller.is_super and lower(trim(coalesce(v_caller.warehouse_name, ''))) <> lower(trim(coalesce(v_warehouse_name, ''))) then
    raise exception 'Only % can receive this return (your location: %).', coalesce(v_warehouse_name, 'its branch'), coalesce(v_caller.warehouse_name, 'none assigned');
  end if;
  if v_condition = 'Defective'
     and (nullif(trim(coalesce(p_photo_path, '')), '') is null or nullif(trim(coalesce(p_photo_url, '')), '') is null) then
    raise exception 'A photo of the defective item is required.';
  end if;

  v_transaction_no := nextval('public.ile_transaction_no_seq');

  perform public._ile_post(
    'Positive Adjmt.', v_return."ItemCode", v_return."VariantId", v_return."WarehouseId", v_return."Quantity",
    public._ile_today(), 'Sales Return', v_return."ReturnNo",
    left('Returned from order ' || v_return."OrderID" || ' (' || v_condition || ')', 500),
    v_transaction_no, p_admin_username
  );

  if v_condition = 'Defective' then
    v_defect_no := 'DEF-' || lpad(nextval('public.defect_report_no_seq')::text, 6, '0');

    perform public._ile_post(
      'Negative Adjmt.', v_return."ItemCode", v_return."VariantId", v_return."WarehouseId", -v_return."Quantity",
      public._ile_today(), 'Defect', v_defect_no,
      left('Defective return ' || v_return."ReturnNo" || ' from order ' || v_return."OrderID", 500),
      v_transaction_no, p_admin_username
    );

    -- Approved on creation: the unit never joined sellable stock, so nothing is being written off.
    insert into public."DefectReports" (
      "ReportNo", "ItemCode", "VariantId", "WarehouseId", "Quantity", "Reason", "Note", "PhotoPath", "PhotoUrl",
      "Status", "ReportedBy", "DecidedBy", "DecidedAtUtc", "DecisionNote", "TransactionNo"
    ) values (
      v_defect_no, v_return."ItemCode", v_return."VariantId", v_return."WarehouseId", v_return."Quantity",
      left('Customer return', 100), left(coalesce(v_note, v_return."Reason"), 1000), trim(p_photo_path), trim(p_photo_url),
      'Approved', p_admin_username, p_admin_username, now(),
      left('Customer return ' || v_return."ReturnNo" || ' on order ' || v_return."OrderID", 1000), v_transaction_no
    );
  end if;

  -- Serials (same rules as Repair Returns): resellable back In Stock at the branch, defective scrapped.
  select count(*) into v_serial_count from public."OnlineOrderReturnSerials" where "ReturnId" = p_id;
  if v_serial_count > 0 then
    update public."ItemSerialTracking" s
       set "Status" = case when v_condition = 'Resellable' then 'IN_STOCK' else 'SCRAPPED' end,
           "Location" = coalesce(v_warehouse_name, s."Location"),
           "SoldOnlineOrderId" = null, "SoldReceiptNo" = null,
           "SourceDocumentNo" = v_return."ReturnNo",
           "UpdatedAtUtc" = now(), "UpdatedBy" = left(p_admin_username, 100)
     where s."RunningSerialNo" in (select rs."RunningSerialNo" from public."OnlineOrderReturnSerials" rs where rs."ReturnId" = p_id)
       and s."Status" = 'SOLD' and s."SoldOnlineOrderId" = v_return."OrderID";
    get diagnostics v_moved = row_count;
    if v_moved <> v_serial_count then
      raise exception 'A serial on % is no longer sold to order % (it was changed since the return was made). Check it on Serial Tracker.',
        v_return."ReturnNo", v_return."OrderID";
    end if;
  end if;

  update public."OnlineOrderReturns"
     set "Status" = 'Received', "Condition" = v_condition, "ReceivedBy" = p_admin_username, "ReceivedAtUtc" = now(),
         "ReceiveNote" = v_note, "PhotoUrl" = nullif(trim(coalesce(p_photo_url, '')), ''),
         "TransactionNo" = v_transaction_no, "DefectReportNo" = v_defect_no
   where "Id" = p_id;

  return jsonb_build_object('return_no', v_return."ReturnNo", 'condition', v_condition, 'defect_report_no', v_defect_no,
                            'serials', v_serial_count);
end;
$$;

grant execute on function public.staff_receive_order_return(text, text, int, text, text, text, text) to anon;

-- ============================================================================
-- 6. Record the refund (Super User): once the whole group is received
-- ============================================================================

drop function if exists public.admin_record_order_return_refund(text, text, int, text, text);

create or replace function public.admin_record_order_return_refund(
  p_admin_username text,
  p_admin_password text,
  p_id int,
  p_method text,
  p_reference text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_return public."OnlineOrderReturns"%rowtype;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not exists (select 1 from public."StaffUsers" s
                    where s."Username" = p_admin_username and s."IsActive" and coalesce(s."SuperUser", false)) then
    raise exception 'Only a Super User can record a refund.';
  end if;

  select * into v_return from public."OnlineOrderReturns" where "Id" = p_id for update;
  if not found then
    raise exception 'Return not found.';
  end if;
  if exists (select 1 from public."OnlineOrderReturns" g
             where g."Id" in (select public._order_return_group_ids(p_id)) and g."Status" <> 'Received') then
    raise exception 'Receive every returned item on % before recording the refund.', coalesce(v_return."ReturnGroup", v_return."ReturnNo");
  end if;
  if coalesce(v_return."RefundDue", 0) <= 0 then
    raise exception 'Return % has no refund due.', v_return."ReturnNo";
  end if;
  if v_return."RefundedAtUtc" is not null then
    raise exception 'The refund on % is already recorded.', v_return."ReturnNo";
  end if;
  if nullif(trim(coalesce(p_method, '')), '') is null then
    raise exception 'Enter how it was refunded.';
  end if;

  update public."OnlineOrderReturns"
     set "RefundMethod" = left(trim(p_method), 100), "RefundReference" = left(nullif(trim(coalesce(p_reference, '')), ''), 200),
         "RefundedBy" = p_admin_username, "RefundedAtUtc" = now()
   where "Id" = p_id;
end;
$$;

grant execute on function public.admin_record_order_return_refund(text, text, int, text, text) to anon;

-- ============================================================================
-- 7. Cancel: the whole group, before any of it is received
-- ============================================================================

drop function if exists public.staff_cancel_order_return(text, text, int, text);

create or replace function public.staff_cancel_order_return(
  p_admin_username text,
  p_admin_password text,
  p_id int,
  p_note text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_return public."OnlineOrderReturns"%rowtype;
  v_replacement_status text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._can_open_order_return(p_admin_username) then
    raise exception 'Only a Super User, Sales User, Store Manager or Production Manager can cancel a return.';
  end if;
  if nullif(trim(coalesce(p_note, '')), '') is null then
    raise exception 'A reason is required.';
  end if;

  select * into v_return from public."OnlineOrderReturns" where "Id" = p_id for update;
  if not found then
    raise exception 'Return not found.';
  end if;
  if v_return."Status" <> 'Open' then
    raise exception 'Return % is % and can''t be cancelled.', v_return."ReturnNo", lower(v_return."Status");
  end if;
  if exists (select 1 from public."OnlineOrderReturns" g
             where g."Id" in (select public._order_return_group_ids(p_id)) and g."Status" = 'Received') then
    raise exception 'Part of % is already received, so it can''t be cancelled.', coalesce(v_return."ReturnGroup", v_return."ReturnNo");
  end if;

  if v_return."ReplacementOrderID" is not null then
    select "Status" into v_replacement_status from public."OnlineOrders" where "OrderID" = v_return."ReplacementOrderID";
    if lower(trim(coalesce(v_replacement_status, 'cancelled'))) not in ('cancelled', 'canceled') then
      raise exception 'Cancel replacement order % first (it is %).', v_return."ReplacementOrderID", v_replacement_status;
    end if;
  end if;

  -- Its serials free up for a new return as soon as the rows are Cancelled (_order_return_line_serials).
  update public."OnlineOrderReturns"
     set "Status" = 'Cancelled', "CancelledBy" = p_admin_username, "CancelledAtUtc" = now(), "CancelNote" = left(trim(p_note), 1000)
   where "Id" in (select public._order_return_group_ids(p_id)) and "Status" = 'Open';
end;
$$;

grant execute on function public.staff_cancel_order_return(text, text, int, text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'function' as section, p.proname::text as item, pg_get_function_identity_arguments(p.oid) as detail
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('staff_create_order_return_multi', 'staff_list_order_return_lines', 'staff_list_order_returns',
                    'staff_receive_order_return', 'admin_record_order_return_refund', 'staff_cancel_order_return',
                    '_order_return_group_ids', '_order_return_line_serials', '_can_open_order_return', 'staff_search_return_items')
union all
select 'table', 'OnlineOrderReturnSerials', 'rows: ' || (select count(*) from public."OnlineOrderReturnSerials")
union all
select 'column', 'OnlineOrderReturns.ReturnGroup',
       case when exists (select 1 from information_schema.columns where table_schema = 'public'
                         and table_name = 'OnlineOrderReturns' and column_name = 'ReturnGroup') then 'ok' else 'MISSING' end;
