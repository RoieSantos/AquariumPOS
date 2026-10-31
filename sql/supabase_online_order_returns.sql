-- Return / Exchange on a shipped online order - per "on online orders i choose the order they want to return
-- then swap it to the item that is exchanging" / "yes can we build this".
--
-- The original order is never changed: it stays the record of what shipped, and its Item Ledger sale stands
-- (setting it to Returned would put the whole order back in stock at once). Instead:
--
--   Create   staff_create_order_return     Super User, Sales User or Store Manager. Order must be Shipped /
--                                          Delivered / Completed / Received, and not a walk-in (POS exchange).
--                                          p_dry_run = true (default) only returns the money preview.
--                                          Exchange: makes a Confirmed portal order for the new item, priced
--                                          at (new total - credit, never below 0), so the sales reports count
--                                          only the difference and the normal payment / packing / delivery /
--                                          stock flow applies. A cheaper item leaves a refund due.
--                                          Refund: no new order, the credit is the refund due.
--   Receive  staff_receive_order_return    Super User or Store Manager (own branch), when the item arrives.
--                                          Stock moves only here.
--                                            Resellable: Positive Adjmt. (document type "Sales Return").
--                                            Defective (photo required): the same + a Negative Adjmt. (document
--                                            type "Defect") and an Approved Defect Items report. Net stock 0.
--   Refund   admin_record_order_return_refund  Super User only, after Receive. Records the method and reference;
--                                          it doesn't move money or change the sales reports.
--   Cancel   staff_cancel_order_return     Same people as Create, before Receive and once the replacement order
--                                          is Cancelled.
--
-- One line per return. NOT handled: serial-tracked items (aquarium / stand / sump), SET lines and anything not
-- stocked are refused at Create; a line's order-level discount isn't taken off the credit (a warning says so).
-- To repair a returned item, receive it as Resellable, then send it on the Repair Returns page.
-- Reversing a "Sales Return" entry on Item Ledger Entries isn't blocked and wouldn't update this document.
--
-- Run AFTER supabase_defect_reports.sql, supabase_order_line_change_variant.sql (_order_line_variant_candidates,
-- _order_line_item_needs_serial), supabase_online_order_set_explode.sql (_online_order_line_category),
-- supabase_item_ledger_sales.sql (_ile_try_resolve_stock_key) and supabase_gma_order_delivery_fee.sql.
-- Safe to re-run. Needs js/onlineOrders.js ?v=returns1.

-- ============================================================================
-- 1. Table
-- ============================================================================

create sequence if not exists public.order_return_no_seq;

create table if not exists public."OnlineOrderReturns" (
    "Id" serial primary key,
    "ReturnNo" varchar(30) not null unique,
    "OrderID" varchar(100) not null,
    "LineID" varchar(100) not null,
    "ItemCode" varchar(200) not null,
    "VariantId" varchar(100),
    "WarehouseId" varchar(100) not null,
    "Description" varchar(500),
    "Quantity" numeric(18, 4) not null check ("Quantity" > 0),
    "Reason" varchar(1000) not null,
    "Resolution" varchar(20) not null check ("Resolution" in ('Exchange', 'Refund')),
    "CreditAmount" numeric(18, 2) not null,
    "NewDescription" varchar(500),
    "NewQuantity" int,
    "NewListTotal" numeric(18, 2),
    "ReplacementOrderID" varchar(100),
    "CustomerPays" numeric(18, 2) not null default 0,
    "RefundDue" numeric(18, 2) not null default 0,
    "Status" varchar(20) not null default 'Open' check ("Status" in ('Open', 'Received', 'Cancelled')),
    "CreatedBy" varchar(100) not null,
    "CreatedAtUtc" timestamptz not null default now(),
    "Condition" varchar(20) check ("Condition" in ('Resellable', 'Defective')),
    "ReceivedBy" varchar(100),
    "ReceivedAtUtc" timestamptz,
    "ReceiveNote" varchar(1000),
    "PhotoUrl" varchar(1000),
    "TransactionNo" bigint,
    "DefectReportNo" varchar(30),
    "RefundMethod" varchar(100),
    "RefundReference" varchar(200),
    "RefundedBy" varchar(100),
    "RefundedAtUtc" timestamptz,
    "CancelledBy" varchar(100),
    "CancelledAtUtc" timestamptz,
    "CancelNote" varchar(1000)
);

create index if not exists "IX_OnlineOrderReturns_Order" on public."OnlineOrderReturns" ("OrderID");
create index if not exists "IX_OnlineOrderReturns_Replacement" on public."OnlineOrderReturns" ("ReplacementOrderID");

alter table public."OnlineOrderReturns" enable row level security;
revoke all on public."OnlineOrderReturns" from anon, authenticated;

-- Super User, Sales User or Store Manager.
create or replace function public._can_open_order_return(p_username text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public."StaffUsers" s
                 where s."Username" = p_username and s."IsActive"
                   and (coalesce(s."SuperUser", false) or coalesce(s."SalesUser", false) or coalesce(s."StoreManager", false)));
$$;

revoke execute on function public._can_open_order_return(text) from public, anon, authenticated;

-- ============================================================================
-- 2. Create (or preview)
-- ============================================================================

drop function if exists public.staff_create_order_return(text, text, text, text, numeric, text, text, text, int, boolean);

create or replace function public.staff_create_order_return(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_line_id text,
  p_quantity numeric,
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
  v_line_id text := trim(coalesce(p_line_id, ''));
  v_resolution text := trim(coalesce(p_resolution, ''));
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_order public."OnlineOrders"%rowtype;
  v_source public."AutomatedOrders"%rowtype;
  v_line public."OnlineOrderLines"%rowtype;
  v_key record;
  v_new record;
  v_new_label text;
  v_warnings text[] := '{}';
  v_item text;
  v_already numeric;
  v_credit numeric(18, 2);
  v_new_qty int;
  v_new_total numeric(18, 2) := 0;
  v_net_unit numeric(18, 2) := 0;
  v_pays numeric(18, 2) := 0;
  v_refund numeric(18, 2) := 0;
  v_return_no text;
  v_new_order text;
  v_location text;
  v_note text;
  v_entry_no bigint;
  v_by text;
  v_now timestamptz := now();
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._can_open_order_return(p_admin_username) then
    raise exception 'Only a Super User, Sales User or Store Manager can open a return.';
  end if;
  if v_resolution not in ('Exchange', 'Refund') then
    raise exception 'Choose Exchange or Refund.';
  end if;
  if p_quantity is null or p_quantity < 1 or p_quantity <> trunc(p_quantity) then
    raise exception 'Quantity must be a whole number, 1 or more.';
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

  select * into v_line from public."OnlineOrderLines" where "OrderID" = v_order_id and "LineID" = v_line_id;
  if not found then
    raise exception 'That line wasn''t found on order %.', v_order_id;
  end if;

  v_item := coalesce((select v."ItemCode" from public."Variants" v where v."VariationId" = v_line."VariationId"), v_line."ItemCode");
  if upper(coalesce(public._online_order_line_category(v_line."VariationId", v_line."ItemCode"), '')) = 'SET' then
    raise exception 'A SET line can''t be returned here yet.';
  end if;
  if public._order_line_item_needs_serial(v_line."VariationId", v_line."ItemCode") then
    raise exception '% takes a serial - serial-tracked items can''t be returned here yet.', coalesce(v_line."Description", v_item);
  end if;
  select k.item_code, k.variant_id into v_key
    from public._ile_try_resolve_stock_key(v_item, nullif(trim(coalesce(v_line."VariationId", '')), '')) k;
  if v_key.item_code is null then
    raise exception '% isn''t a stocked item, so it can''t be returned here.', coalesce(v_line."Description", v_item, 'This line');
  end if;

  select coalesce(sum("Quantity"), 0) into v_already
    from public."OnlineOrderReturns"
   where "OrderID" = v_order_id and "LineID" = v_line_id and "Status" <> 'Cancelled';
  if p_quantity + v_already > coalesce(v_line."Quantity", 0) then
    raise exception 'Only % of this line can still be returned (% sold, % already on a return).',
      greatest(coalesce(v_line."Quantity", 0) - v_already, 0), coalesce(v_line."Quantity", 0), v_already;
  end if;

  v_credit := round(coalesce(v_line."NetAmount", v_line."GrossAmount", coalesce(v_line."Price", 0) * v_line."Quantity", 0)
                    / nullif(v_line."Quantity", 0) * p_quantity, 2);

  if v_resolution = 'Exchange' then
    v_new_qty := coalesce(p_new_quantity, p_quantity::int);
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
    v_net_unit := round(greatest(v_new_total - v_credit, 0) / v_new_qty, 2);
    v_pays := v_net_unit * v_new_qty;
    v_refund := greatest(v_credit - v_new_total, 0);
  else
    v_refund := v_credit;
  end if;

  if coalesce(v_order."Balance", 0) > 0 then
    v_warnings := v_warnings || format('This order still has a balance of %s - the credit assumes the returned item was paid for.', to_char(v_order."Balance", 'FM999,999,990.00'));
  end if;
  if coalesce(v_order."Discount", 0) > 0 then
    v_warnings := v_warnings || format('This order has a %s order discount that isn''t taken off the credit.', to_char(v_order."Discount", 'FM999,999,990.00'));
  end if;

  if coalesce(p_dry_run, true) then
    return jsonb_build_object('credit', v_credit, 'new_total', v_new_total, 'customer_pays', v_pays,
                              'refund_due', v_refund, 'warnings', to_jsonb(v_warnings));
  end if;

  if v_reason is null then
    raise exception 'A reason is required.';
  end if;

  v_return_no := 'SR-' || lpad(nextval('public.order_return_no_seq')::text, 6, '0');

  if v_resolution = 'Exchange' then
    select * into v_source from public."AutomatedOrders" where "OrderNo" = v_order_id;
    select coalesce(nullif(trim(v_source."Location"), ''), left(w."Name", 20)) into v_location
      from public."Warehouses" w where w."ID" = v_order."LocationID";
    select coalesce(nullif(trim("DisplayName"), ''), "Username") into v_by
      from public."StaffUsers" where "Username" = p_admin_username;
    v_new_order := public._next_no_series_number('AUTOMATED-ORDER', '');
    v_note := left(format('Exchange %s for order %s: returned %s x %s. List %s less credit %s.',
                          v_return_no, v_order_id, p_quantity::int, coalesce(v_line."Description", v_item),
                          to_char(v_new_total, 'FM999,999,990.00'), to_char(least(v_credit, v_new_total), 'FM999,999,990.00')), 1000);

    -- Already confirmed, so the same shape admin_confirm_bot_order leaves behind.
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

  insert into public."OnlineOrderReturns" (
    "ReturnNo", "OrderID", "LineID", "ItemCode", "VariantId", "WarehouseId", "Description", "Quantity", "Reason",
    "Resolution", "CreditAmount", "NewDescription", "NewQuantity", "NewListTotal", "ReplacementOrderID",
    "CustomerPays", "RefundDue", "CreatedBy"
  ) values (
    v_return_no, v_order_id, v_line_id, v_key.item_code, v_key.variant_id, v_order."LocationID",
    left(coalesce(v_line."Description", v_item), 500), p_quantity, left(v_reason, 1000),
    v_resolution, v_credit,
    left(v_new_label, 500),
    v_new_qty, case when v_resolution = 'Exchange' then v_new_total end, v_new_order,
    v_pays, v_refund, p_admin_username
  );

  return jsonb_build_object('return_no', v_return_no, 'replacement_order_id', v_new_order, 'credit', v_credit,
                            'new_total', v_new_total, 'customer_pays', v_pays, 'refund_due', v_refund,
                            'warnings', to_jsonb(v_warnings));
end;
$$;

grant execute on function public.staff_create_order_return(text, text, text, text, numeric, text, text, text, int, boolean) to anon;

-- ============================================================================
-- 3. List: the returns on an order, or the one a replacement order came from
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
  refund_method text, refund_reference text, refunded_by text, refunded_at_utc timestamptz
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
           r."RefundedBy"::text, r."RefundedAtUtc"
    from public."OnlineOrderReturns" r
    left join public."OnlineOrders" o on o."OrderID" = r."ReplacementOrderID"
    where r."OrderID" = trim(coalesce(p_order_id, '')) or r."ReplacementOrderID" = trim(coalesce(p_order_id, ''))
    order by r."Id" desc;
end;
$$;

grant execute on function public.staff_list_order_returns(text, text, text) to anon;

-- ============================================================================
-- 4. Receive: the only step that moves stock
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
begin
  -- Super User or Store Manager, same as Defect Items.
  select * into v_caller from public._defect_caller(p_admin_username, p_admin_password);

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

  update public."OnlineOrderReturns"
     set "Status" = 'Received', "Condition" = v_condition, "ReceivedBy" = p_admin_username, "ReceivedAtUtc" = now(),
         "ReceiveNote" = v_note, "PhotoUrl" = nullif(trim(coalesce(p_photo_url, '')), ''),
         "TransactionNo" = v_transaction_no, "DefectReportNo" = v_defect_no
   where "Id" = p_id;

  return jsonb_build_object('return_no', v_return."ReturnNo", 'condition', v_condition, 'defect_report_no', v_defect_no);
end;
$$;

grant execute on function public.staff_receive_order_return(text, text, int, text, text, text, text) to anon;

-- ============================================================================
-- 5. Record the refund (Super User)
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
  if v_return."Status" <> 'Received' then
    raise exception 'Receive the returned item before recording the refund.';
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
-- 6. Cancel, before the item is received
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
    raise exception 'Only a Super User, Sales User or Store Manager can cancel a return.';
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

  if v_return."ReplacementOrderID" is not null then
    select "Status" into v_replacement_status from public."OnlineOrders" where "OrderID" = v_return."ReplacementOrderID";
    if lower(trim(coalesce(v_replacement_status, 'cancelled'))) not in ('cancelled', 'canceled') then
      raise exception 'Cancel replacement order % first (it is %).', v_return."ReplacementOrderID", v_replacement_status;
    end if;
  end if;

  update public."OnlineOrderReturns"
     set "Status" = 'Cancelled', "CancelledBy" = p_admin_username, "CancelledAtUtc" = now(), "CancelNote" = left(trim(p_note), 1000)
   where "Id" = p_id;
end;
$$;

grant execute on function public.staff_cancel_order_return(text, text, int, text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'function' as section, p.proname::text as item, pg_get_function_identity_arguments(p.oid) as detail
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('staff_create_order_return', 'staff_list_order_returns', 'staff_receive_order_return',
                    'admin_record_order_return_refund', 'staff_cancel_order_return')
union all
select 'table', 'OnlineOrderReturns', 'rows: ' || (select count(*) from public."OnlineOrderReturns");
