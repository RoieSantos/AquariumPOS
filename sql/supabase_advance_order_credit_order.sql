-- New Order from Credit: a voided advance order's money spent on a NEW order from the portal - per "can we do
-- exchange on a voided status in portal" / "yes build 2".
--
-- The credit is the money a voided advance order kept (POS Void Order -> "Keep as credit", VoidOrderCredit.cs) or,
-- for an order voided as a refund in the last 30 days that the customer never took back, the refund (Super User
-- only - same rule as the POS).
--
--   staff_create_order_from_void_credit   Same dialog and order shape as "+ Add COD Items"
--                                         (supabase_advance_order_cod_addon.sql): a NEW confirmed portal order (AO-)
--                                         at the advance order's branch. The credit is taken off the new lines'
--                                         prices (spread by value, like the Return / Exchange replacement order),
--                                         so the order is only worth what the customer still pays and the sales
--                                         reports don't count the voided order's money twice (it was already
--                                         counted as Advance Collected when it came in). Whatever is left is the
--                                         order's normal balance (pay link / COD / Online Pay). Credit bigger than
--                                         the order: the rest stays for later.
--   AdvanceOrderCreditUses                One row per portal use. Cancelling or deleting the new order gives the
--                                         credit back (trigger below).
--   _advance_order_credit_left(no)        Credit - refunded later - used at the POS (AdvanceOrders.VoidCreditUsed,
--                                         synced from the POS) - used here.
--   pos_get_advance_order_credit(nos[])   For the POS: what the portal used, and what's left. The POS's "Voided
--                                         Order Credit" tender and "refund the credit" both cap by it, so the same
--                                         money can't be spent on both sides.
--   staff_get_advance_order_credit(no)    For the dialog: what's left and whether a Super User is needed.
--   staff_get_advance_order_voids         + void_credit_left, and the used amount / receipts now include portal uses.
--
-- Run AFTER supabase_advance_order_void_credit.sql and supabase_advance_order_cod_addon.sql (re-run this one if
-- either is re-run). Run it BEFORE the POS build that reads pos_get_advance_order_credit. Safe to re-run.
-- Needs js/onlineOrders.js ?v=voidcreditorder1. Ends with ONE result.

set lock_timeout = '10s';

-- ============================================================================
-- 1. Uses
-- ============================================================================

create table if not exists public."AdvanceOrderCreditUses" (
  "Id" bigint generated always as identity primary key,
  "TransactionNo" varchar(100) not null,
  "OnlineOrderID" text not null,
  "Amount" numeric(18, 2) not null check ("Amount" > 0),
  "ClientKey" text not null unique,     -- one per dialog, so a retry after a lost reply can't make a second order
  "ApprovedBy" text,                    -- Super User, for a refunded void
  "CreatedBy" text,
  "CreatedAtUtc" timestamptz not null default now(),
  "ReleasedAtUtc" timestamptz,          -- the new order was cancelled / deleted -> credit back
  "ReleasedNote" text
);

create index if not exists "IX_AdvanceOrderCreditUses_TransactionNo" on public."AdvanceOrderCreditUses" ("TransactionNo");
create index if not exists "IX_AdvanceOrderCreditUses_Order" on public."AdvanceOrderCreditUses" ("OnlineOrderID");

alter table public."AdvanceOrderCreditUses" enable row level security;
revoke all on public."AdvanceOrderCreditUses" from anon, authenticated;

-- Cancelled or deleted new order -> its credit is free again.
create or replace function public._advance_order_credit_release()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    update public."AdvanceOrderCreditUses"
       set "ReleasedAtUtc" = now(), "ReleasedNote" = 'Order deleted'
     where "OnlineOrderID" = old."OrderID" and "ReleasedAtUtc" is null;
    return old;
  end if;
  if lower(trim(coalesce(new."Status", ''))) in ('cancelled', 'canceled')
     and lower(trim(coalesce(old."Status", ''))) not in ('cancelled', 'canceled') then
    update public."AdvanceOrderCreditUses"
       set "ReleasedAtUtc" = now(), "ReleasedNote" = 'Order cancelled'
     where "OnlineOrderID" = new."OrderID" and "ReleasedAtUtc" is null;
  end if;
  return new;
end;
$$;

drop trigger if exists "trg_advance_order_credit_release" on public."OnlineOrders";
create trigger "trg_advance_order_credit_release"
after update of "Status" or delete on public."OnlineOrders"
for each row execute function public._advance_order_credit_release();

-- ============================================================================
-- 2. What's left
-- ============================================================================

-- held: kept as credit at the void. refunded: voided as a refund in the last 30 days (Super User only).
create or replace function public._advance_order_credit_info(p_no text)
returns table(found boolean, held boolean, base numeric, pos_used numeric, portal_used numeric, credit_left numeric,
              used_on text, voided_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select a."TransactionNo" is not null,
         a."VoidCredit" is not null,
         b.base,
         coalesce(a."VoidCreditUsed", 0),
         coalesce(u.used, 0),
         greatest(b.base - coalesce(a."VoidCreditUsed", 0) - coalesce(u.used, 0), 0),
         nullif(concat_ws(', ', nullif(trim(coalesce(a."VoidCreditUsedOn", '')), ''), u.used_on), ''),
         a."VoidedAtUtc"
  from (select 1) x
  left join public."AdvanceOrders" a on a."TransactionNo" = trim(coalesce(p_no, '')) and a."IsVoid"
  left join lateral (
    select case
             when a."VoidCredit" is not null then greatest(a."VoidCredit" - coalesce(a."VoidRefund", 0), 0)
             when coalesce(a."VoidRefund", 0) > 0 and a."VoidedAtUtc" >= now() - interval '30 days' then a."VoidRefund"
             else 0
           end as base
  ) b on true
  left join lateral (
    select sum(c."Amount") as used, string_agg(c."OnlineOrderID", ', ' order by c."Id") as used_on
    from public."AdvanceOrderCreditUses" c
    where c."TransactionNo" = a."TransactionNo" and c."ReleasedAtUtc" is null
  ) u on true;
$$;

revoke execute on function public._advance_order_credit_info(text) from public, anon, authenticated;

-- POS (anon key, like the other pos_ reads): portal uses + what's left, per voided order.
create or replace function public.pos_get_advance_order_credit(p_nos text[])
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'transaction_no', n.no, 'found', i.found, 'portal_used', i.portal_used, 'credit_left', i.credit_left)), '[]'::jsonb)
  from unnest(coalesce(p_nos, '{}')) as n(no)
  cross join lateral public._advance_order_credit_info(n.no) i;
$$;

revoke all on function public.pos_get_advance_order_credit(text[]) from public;
grant execute on function public.pos_get_advance_order_credit(text[]) to anon;

-- Dialog: what's left on one voided order.
drop function if exists public.staff_get_advance_order_credit(text, text, text);

create or replace function public.staff_get_advance_order_credit(p_admin_username text, p_admin_password text, p_no text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v record;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._can_add_advance_cod_items(p_admin_username) then
    raise exception 'Only a Super User, Sales User or Production Manager can make an order from credit.';
  end if;
  select * into v from public._advance_order_credit_info(p_no);
  return jsonb_build_object('found', v.found, 'held', v.held, 'credit_left', v.credit_left,
                            'needs_super_user', v.found and not v.held, 'used_on', v.used_on);
end;
$$;

grant execute on function public.staff_get_advance_order_credit(text, text, text) to anon;

-- ============================================================================
-- 3. Create the new order
-- ============================================================================

drop function if exists public.staff_create_order_from_void_credit(text, text, text, text, text, text, text, jsonb, text);

create or replace function public.staff_create_order_from_void_credit(
  p_admin_username text,
  p_admin_password text,
  p_no text,
  p_fulfillment text,      -- 'Delivery' / 'Pickup'
  p_address text,
  p_phone text,
  p_client_key text,
  -- Same lines as staff_create_advance_order_cod_addon: catalog { variation_id, quantity, price, note } or
  -- custom build { category_code, item_name, quantity, price, note }.
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
  v_info record;
  v_is_super boolean;
  v_customer text;
  v_warehouse_id text;
  v_warehouse_name text;
  v_order_no text;
  v_existing record;
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
  v_apply numeric(18, 2);
  v_left_to_spread numeric(18, 2);
  v_share numeric(18, 2);
  v_net_unit numeric(18, 2);
  v_net_total numeric(18, 2) := 0;
  v_applied numeric(18, 2);
  v_rows int;
  v_i int := 0;
  v_l record;
  v_notes text;
  v_by text;
  v_now timestamptz := now();
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._can_add_advance_cod_items(p_admin_username) then
    raise exception 'Only a Super User, Sales User or Production Manager can make an order from credit.';
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

  -- Holds other tries for this voided order until this one commits (credit check + ClientKey below).
  begin
    select * into v_advance from public."AdvanceOrders" where "TransactionNo" = v_no for update;
  exception when lock_not_available then
    raise exception 'Advance order % is busy. Wait a moment and try again.', v_no;
  end;
  if v_advance."TransactionNo" is null then
    raise exception 'Advance order % not found.', v_no;
  end if;

  select "OnlineOrderID", "Amount" into v_existing from public."AdvanceOrderCreditUses" where "ClientKey" = v_key;
  if v_existing."OnlineOrderID" is not null then
    return jsonb_build_object('order_id', v_existing."OnlineOrderID", 'credit_applied', v_existing."Amount",
                              'customer_pays', (select "MoneyToCollect" from public."OnlineOrders" where "OrderID" = v_existing."OnlineOrderID"));
  end if;

  if v_advance."IsVoid" is not true then
    raise exception 'Advance order % isn''t voided - only a voided order''s credit can be used here.', v_no;
  end if;
  select * into v_info from public._advance_order_credit_info(v_no);
  if coalesce(v_info.credit_left, 0) <= 0 then
    raise exception 'Advance order % has no credit left%.', v_no,
      case when not v_info.held and coalesce(v_advance."VoidRefund", 0) > 0 and v_advance."VoidedAtUtc" < now() - interval '30 days'
           then ' (it was voided as a refund more than 30 days ago)' else '' end;
  end if;
  v_is_super := exists (select 1 from public."StaffUsers" s
                        where s."Username" = p_admin_username and s."IsActive" and coalesce(s."SuperUser", false));
  if not v_info.held and not v_is_super then
    raise exception 'Advance order % was voided as a REFUND - only a Super User can use it as credit (confirm the customer never took the money back).', v_no;
  end if;

  select w."ID", w."Name" into v_warehouse_id, v_warehouse_name
    from public."Warehouses" w
   where lower(trim(w."Name")) = lower(trim(coalesce(v_advance."Warehouse", '')))
   limit 1;
  if v_warehouse_id is null then
    raise exception 'Advance order % has no branch, so the new order has nowhere to ship from.', v_no;
  end if;

  v_customer := coalesce(nullif(trim(coalesce(p_customer_name, '')), ''), nullif(trim(v_advance."CustomerName"), ''), '-');
  select coalesce(nullif(trim("DisplayName"), ''), "Username") into v_by
    from public."StaffUsers" where "Username" = p_admin_username;
  v_order_no := public._next_no_series_number('AUTOMATED-ORDER', '');

  -- Same shape as staff_create_advance_order_cod_addon. Totals and the credit are set after the lines.
  insert into public."AutomatedOrders" (
    "OrderNo", "CustomerName", "CustomerPhone", "FulfillmentType", "DeliveryAddress", "Notes", "Status",
    "EstimatedTotal", "Location", "UpdatedBy", "UpdatedAtUtc",
    "PancakeSyncStatus", "PancakeReceiptNo", "ConfirmationMessageStatus"
  ) values (
    v_order_no, v_customer, coalesce(v_phone, ''), v_fulfillment,
    case when v_fulfillment = 'Delivery' then v_address end,
    null, 'Confirmed', 0, left(v_warehouse_name, 20), p_admin_username, v_now,
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

  -- Lines at list price first (copy of the COD add-on loop).
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

  -- Take the credit off the line prices, spread by value (last line takes the rest). Unit prices round UP to the
  -- centavo, so the credit applied never goes over what's left.
  v_apply := least(v_info.credit_left, v_total);
  v_left_to_spread := v_apply;
  select count(*) into v_rows from public."OnlineOrderLines" where "OrderID" = v_order_no;
  for v_l in select l."LineID", l."Quantity", l."GrossAmount" from public."OnlineOrderLines" l
             where l."OrderID" = v_order_no order by l."LineID"::bigint loop
    v_i := v_i + 1;
    v_share := case when v_i = v_rows then v_left_to_spread
                    when v_total > 0 then least(round(v_apply * v_l."GrossAmount" / v_total, 2), v_left_to_spread)
                    else 0 end;
    v_left_to_spread := v_left_to_spread - v_share;
    v_net_unit := ceil(greatest(v_l."GrossAmount" - v_share, 0) / nullif(v_l."Quantity", 0) * 100) / 100;
    update public."OnlineOrderLines"
       set "Price" = v_net_unit, "GrossAmount" = v_net_unit * "Quantity", "NetAmount" = v_net_unit * "Quantity",
           "Note" = left(concat_ws(' | ', nullif("Note", ''), format('Voided order %s credit: list %s', v_no, to_char(v_l."GrossAmount", 'FM999,999,990.00'))), 1000)
     where "OrderID" = v_order_no and "LineID" = v_l."LineID";
    update public."AutomatedOrderLines"
       set "Price" = v_net_unit
     where "OrderNo" = v_order_no and "EntryNo"::text = v_l."LineID";
    v_net_total := v_net_total + v_net_unit * v_l."Quantity";
  end loop;
  v_applied := v_total - v_net_total;

  -- Same 12mm / 10mm flag rule as admin_confirm_bot_order.
  select case
           when bool_or(regexp_replace(coalesce(l."ItemName", '') || coalesce(l."Notes", '') || coalesce(l."ItemCode", ''), '[[:space:]]+', '', 'g') ilike '%12mm%') then '12mm'
           when bool_or(regexp_replace(coalesce(l."ItemName", '') || coalesce(l."Notes", '') || coalesce(l."ItemCode", ''), '[[:space:]]+', '', 'g') ilike '%10mm%') then '10mm'
         end
    into v_glass
    from public."AutomatedOrderLines" l where l."OrderNo" = v_order_no;

  v_notes := left(format('From voided advance order %s (receipt %s): list %s less credit %s.', v_no, coalesce(v_advance."ReceiptNo", '-'),
                         to_char(v_total, 'FM999,999,990.00'), to_char(v_applied, 'FM999,999,990.00')), 1000);
  update public."AutomatedOrders" set "EstimatedTotal" = v_net_total, "Notes" = v_notes where "OrderNo" = v_order_no;
  update public."OnlineOrders" set "MoneyToCollect" = v_net_total, "Balance" = v_net_total, "GlassThickness" = v_glass where "OrderID" = v_order_no;

  if v_applied > 0 then
    insert into public."AdvanceOrderCreditUses" ("TransactionNo", "OnlineOrderID", "Amount", "ClientKey", "ApprovedBy", "CreatedBy")
    values (v_no, v_order_no, v_applied, v_key, case when not v_info.held then p_admin_username end, p_admin_username);
  end if;

  return jsonb_build_object('order_id', v_order_no, 'list_total', v_total, 'credit_applied', v_applied,
                            'customer_pays', v_net_total, 'credit_left', greatest(v_info.credit_left - v_applied, 0));
end;
$$;

grant execute on function public.staff_create_order_from_void_credit(text, text, text, text, text, text, text, jsonb, text) to anon;

-- ============================================================================
-- 4. Void read for the badge / card: + what's left, portal uses included
-- ============================================================================

drop function if exists public.staff_get_advance_order_voids(text, text, text[]);

create or replace function public.staff_get_advance_order_voids(p_admin_username text, p_admin_password text, p_nos text[])
returns table(transaction_no text, voided_at timestamptz, voided_by text, void_reason text, void_refund numeric, errors text,
              void_credit numeric, void_credit_used numeric, void_credit_used_on text, void_credit_left numeric)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_branch text;
begin
  if public.is_admin_authorized(p_admin_username, p_admin_password) then
    v_branch := null;
  elsif public.is_staff_authorized(p_admin_username, p_admin_password) and public._advance_order_is_viewer(p_admin_username) then
    v_branch := public._advance_order_viewer_branch(p_admin_username);
  else
    raise exception 'Not authorized.';
  end if;

  return query
    select a."TransactionNo"::text, a."VoidedAtUtc", a."VoidedBy"::text, a."VoidReason"::text, a."VoidRefund", v."Errors",
           a."VoidCredit", i.pos_used + i.portal_used, i.used_on, i.credit_left
    from public."AdvanceOrders" a
    left join public."AdvanceOrderVoids" v on v."TransactionNo" = a."TransactionNo"
    cross join lateral public._advance_order_credit_info(a."TransactionNo") i
    where a."IsVoid"
      and a."TransactionNo" = any(coalesce(p_nos, '{}'))
      and (v_branch is null or lower(trim(coalesce(a."Warehouse", ''))) = v_branch);
end;
$$;

grant execute on function public.staff_get_advance_order_voids(text, text, text[]) to anon;

notify pgrst, 'reload schema';

select case
  when to_regclass('public."AdvanceOrderCreditUses"') is not null
   and exists (select 1 from pg_trigger where tgname = 'trg_advance_order_credit_release')
   and (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname in ('_advance_order_credit_info', 'pos_get_advance_order_credit',
              'staff_get_advance_order_credit', 'staff_create_order_from_void_credit')) = 4
   and exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'staff_get_advance_order_voids'
                 and pg_get_function_result(p.oid) like '%void_credit_left%')
  then 'OK - New Order from Credit ready'
  else 'FIX - something is missing, re-run this file'
end as result;
