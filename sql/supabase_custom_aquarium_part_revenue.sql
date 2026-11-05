-- Custom Aquarium parts with their own revenue - per "can the options split too? like filter medias / light /
-- pump?" -> SET style ("custom aquarium for now") + "the sales should be revenued too per item".
--
-- Conversations > Create Order > Custom Aquarium > Add to Order now adds the calculator's submersible LIGHT and
-- PUMP as their own lines (real item codes, so stock comes off like any item) at P0, under the Custom Aquarium
-- line (or the Custom Sump line when the sump is its own line), which keeps the full quoted price - the same
-- look as an assembled SET. The customer's receipt / total don't change.
--
-- Revenue: the build's lines share one "BundleKey" and each carries a "RevenueWeight" (its base cost from the
-- calculator, x quantity). OnlineOrderLineBundleRevenue splits the build's actual GrossAmount by those weights
-- (so a discount / price edit on the aquarium line is spread too), and Top Selling Items, Category Sales and
-- the Daily Sales Report's categories now use it instead of the line's own GrossAmount. e.g. a P20,000 build
-- whose pump cost P1,200 of a P17,400 base -> the pump line shows P1,379.31 revenue, the aquarium the rest.
-- Lines without a BundleKey (everything else) report exactly as before.
--
-- The split is stored on AutomatedOrderLines only: Confirm Order copies each line to OnlineOrderLines with
-- LineID = EntryNo, so the view joins back on that - no change to Confirm Order / Xendit auto-confirm.
--
-- Re-creates (each = the live def + only the bundle fields):
--   admin_create_gma_conversation_order  (supabase_gma_order_delivery_fee.sql 1)       + inserts bundle_key / revenue_weight
--   admin_update_automated_order         (supabase_gma_order_delivery_fee.sql 2)       + inserts bundle_key / revenue_weight
--   admin_list_automated_order_lines     (supabase_automated_order_lines_sku_variant.sql) + bundle_key, revenue_weight columns
--   admin_get_top_selling_items          (supabase_top_selling_items_rpc.sql)           revenue via the view
--   admin_get_category_sales_report      (supabase_category_sales_report.sql)           revenue via the view
--   admin_get_daily_sales_report         (supabase_daily_sales_report.sql)              categories via the view
-- Run AFTER those files. If any of them is ever re-run, run this one again afterwards. Safe to re-run.
-- Needs js/calcEmbedLines.js + js/gmaConversations.js ?v=caparts1 and WebAquariumCalculator/calc-embed-bridge.js ?v=caparts1.

alter table public."AutomatedOrderLines" add column if not exists "BundleKey" varchar(40);
alter table public."AutomatedOrderLines" add column if not exists "RevenueWeight" numeric(18, 2);

comment on column public."AutomatedOrderLines"."BundleKey" is 'Lines of one custom aquarium build added from Conversations (the priced aquarium/sump line + its P0 light/pump lines). Reports split the build''s revenue across them by RevenueWeight (OnlineOrderLineBundleRevenue).';
comment on column public."AutomatedOrderLines"."RevenueWeight" is 'Base cost of this line''s part of the build (calculator component price x qty). Only meaningful with BundleKey.';

create index if not exists "IX_AutomatedOrderLines_BundleKey"
  on public."AutomatedOrderLines" ("OrderNo", "BundleKey") where "BundleKey" is not null;

-- ---------------------------------------------------------------------------
-- 0. Revenue per bundled OnlineOrderLines row. Only bundled lines appear; reports use
--    coalesce(b."Revenue", l."GrossAmount"). Shares are rounded to centavos and the biggest-weight line takes
--    the rounding difference, so a build's lines always add up to its GrossAmount exactly.

create or replace view public."OnlineOrderLineBundleRevenue" as
with b as (
  select ol."OrderID", ol."LineID", al."BundleKey",
         coalesce(ol."GrossAmount", 0) as gross,
         greatest(coalesce(al."RevenueWeight", 0), 0) as w
  from public."AutomatedOrderLines" al
  join public."OnlineOrderLines" ol on ol."OrderID" = al."OrderNo" and ol."LineID" = al."EntryNo"::text
  where al."BundleKey" is not null
),
t as (
  select b.*,
         sum(b.gross) over (partition by b."OrderID", b."BundleKey") as bundle_gross,
         sum(b.w) over (partition by b."OrderID", b."BundleKey") as bundle_w,
         row_number() over (partition by b."OrderID", b."BundleKey" order by b.w desc, b."LineID") as rn
  from b
),
s as (
  select t.*, case when t.bundle_w > 0 then round(t.bundle_gross * t.w / t.bundle_w, 2) else t.gross end as share
  from t
)
select s."OrderID", s."LineID", s."BundleKey",
       (case when s.rn = 1 and s.bundle_w > 0
             then s.bundle_gross - (sum(s.share) over (partition by s."OrderID", s."BundleKey") - s.share)
             else s.share end)::numeric(18, 2) as "Revenue"
from s;

-- Report data - only the security-definer report functions read it.
revoke all on public."OnlineOrderLineBundleRevenue" from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. admin_create_gma_conversation_order: + bundle_key / revenue_weight per line

drop function if exists public.admin_create_gma_conversation_order(text, text, text, text, text, text, text, text, text, text, text, jsonb);
drop function if exists public.admin_create_gma_conversation_order(text, text, text, text, text, text, text, text, text, text, text, jsonb, numeric);

create or replace function public.admin_create_gma_conversation_order(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_page_id text,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_fulfillment_type text,
  p_delivery_address text,
  p_notes text,
  p_location text,
  p_lines jsonb,
  p_delivery_fee numeric default null
)
returns table(order_no text, pancake_order_id text, pancake_sync_status text, pancake_sync_error text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '90000'
as $$
declare
  v_order_no text;
  v_fulfillment text := coalesce(nullif(trim(p_fulfillment_type), ''), 'Pickup');
  v_location text := coalesce(nullif(trim(p_location), ''), 'Amaya');
  v_line jsonb;
  v_total numeric(18, 4) := 0;
  v_qty int;
  v_price numeric(18, 4);
  v_delivery_fee numeric(18, 2);
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_psid is null or trim(p_psid) = '' then
    raise exception 'Psid is required.';
  end if;
  if p_customer_name is null or trim(p_customer_name) = '' then
    raise exception 'Customer name is required.';
  end if;
  if p_customer_phone is null or trim(p_customer_phone) = '' then
    raise exception 'Customer phone number is required.';
  end if;
  if regexp_replace(p_customer_phone, '[^0-9]', '', 'g') !~ '^(09[0-9]{9}|639[0-9]{9})$' then
    raise exception 'Please provide a valid PH mobile number, e.g. 09171234567.';
  end if;
  if v_fulfillment not in ('Pickup', 'Delivery') then
    raise exception 'Fulfillment type must be Pickup or Delivery.';
  end if;
  if v_fulfillment = 'Delivery' and (p_delivery_address is null or trim(p_delivery_address) = '') then
    raise exception 'Delivery address is required for delivery orders.';
  end if;
  if v_location not in ('Amaya', 'GMA') then
    raise exception 'Location must be Amaya or GMA.';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'At least one item is required.';
  end if;
  -- This file: Pickup never carries a fee.
  if coalesce(p_delivery_fee, 0) < 0 then
    raise exception 'Delivery fee can''t be negative.';
  end if;
  v_delivery_fee := case when v_fulfillment = 'Delivery' then round(coalesce(p_delivery_fee, 0), 2) else 0 end;

  v_order_no := public._next_no_series_number('AUTOMATED-ORDER', '');

  insert into public."AutomatedOrders"
    ("OrderNo", "CustomerName", "CustomerPhone", "CustomerEmail", "FulfillmentType", "DeliveryAddress", "Notes", "Status", "EstimatedTotal", "Location", "GmaPsid", "GmaPageId", "UpdatedBy", "PancakeSyncStatus", "DeliveryFee")
  values
    (v_order_no, trim(p_customer_name), trim(p_customer_phone), nullif(trim(coalesce(p_customer_email, '')), ''),
     v_fulfillment, case when v_fulfillment = 'Delivery' then trim(p_delivery_address) else null end,
     nullif(trim(coalesce(p_notes, '')), ''), 'New', 0, v_location, trim(p_psid), nullif(trim(coalesce(p_page_id, '')), ''), p_admin_username, 'Not Pushed',
     v_delivery_fee);

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_qty := greatest(coalesce((v_line->>'quantity')::int, 1), 1);
    v_price := greatest(coalesce((v_line->>'price')::numeric, 0), 0);

    if v_line->>'item_name' is null or trim(v_line->>'item_name') = '' then
      raise exception 'Each order line requires an item name.';
    end if;

    insert into public."AutomatedOrderLines"
      ("OrderNo", "CategoryCode", "ItemCode", "ItemName", "Quantity", "Price", "Notes", "VariationId", "BundleKey", "RevenueWeight")
    values
      (v_order_no, nullif(trim(coalesce(v_line->>'category_code', '')), ''),
       nullif(trim(coalesce(v_line->>'item_code', '')), ''), trim(v_line->>'item_name'), v_qty, v_price,
       nullif(trim(coalesce(v_line->>'note', '')), ''), nullif(trim(coalesce(v_line->>'variation_id', '')), ''),
       -- This file: a custom aquarium build's lines (js/calcEmbedLines.js) - see the header.
       left(nullif(trim(coalesce(v_line->>'bundle_key', '')), ''), 40),
       case when nullif(trim(coalesce(v_line->>'bundle_key', '')), '') is not null
            then round(greatest(coalesce((v_line->>'revenue_weight')::numeric, 0), 0), 2) end);

    v_total := v_total + (v_qty * v_price);
  end loop;

  update public."AutomatedOrders" set "EstimatedTotal" = v_total + v_delivery_fee where "OrderNo" = v_order_no;

  -- No Pancake push - staff confirm it into Online Orders with "Confirm Order" (admin_confirm_bot_order).

  return query
    select o."OrderNo"::text, o."PancakeOrderId"::text, o."PancakeSyncStatus"::text, o."PancakeSyncError"::text
    from public."AutomatedOrders" o
    where o."OrderNo" = v_order_no;
end;
$$;

grant execute on function public.admin_create_gma_conversation_order(text, text, text, text, text, text, text, text, text, text, text, jsonb, numeric) to anon;

-- ---------------------------------------------------------------------------
-- 2. admin_update_automated_order: + bundle_key / revenue_weight per line

drop function if exists public.admin_update_automated_order(text, text, text, text, text, text, text, text, text, text, jsonb);
drop function if exists public.admin_update_automated_order(text, text, text, text, text, text, text, text, text, text, jsonb, numeric);

create or replace function public.admin_update_automated_order(
  p_admin_username text,
  p_admin_password text,
  p_order_no text,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_fulfillment_type text,
  p_delivery_address text,
  p_notes text,
  p_location text,
  p_lines jsonb,
  p_delivery_fee numeric default null
)
returns table(order_no text, estimated_total numeric, pancake_sync_status text, pancake_sync_error text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '90000'
as $$
declare
  v_current_status text;
  v_current_sync_status text;
  v_current_fee numeric(18, 2);
  v_fulfillment text := coalesce(nullif(trim(p_fulfillment_type), ''), 'Pickup');
  v_location text := coalesce(nullif(trim(p_location), ''), 'Amaya');
  v_line jsonb;
  v_total numeric(18, 4) := 0;
  v_qty int;
  v_price numeric(18, 4);
  v_delivery_fee numeric(18, 2);
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select "Status", "PancakeSyncStatus", coalesce("DeliveryFee", 0) into v_current_status, v_current_sync_status, v_current_fee
  from public."AutomatedOrders"
  where "OrderNo" = p_order_no;

  if not found then
    raise exception 'Order % not found.', p_order_no;
  end if;
  if v_current_status in ('Completed', 'Cancelled') then
    raise exception 'This order is % and can no longer be edited.', v_current_status;
  end if;
  -- Already confirmed into Online Orders (portal-only): the Online Orders entry is the live order now.
  if v_current_sync_status = 'Portal' then
    raise exception 'Order % is already confirmed into Online Orders and can no longer be edited here.', p_order_no;
  end if;

  if p_customer_name is null or trim(p_customer_name) = '' then
    raise exception 'Customer name is required.';
  end if;
  if p_customer_phone is null or trim(p_customer_phone) = '' then
    raise exception 'Customer phone number is required.';
  end if;
  if regexp_replace(p_customer_phone, '[^0-9]', '', 'g') !~ '^(09[0-9]{9}|639[0-9]{9})$' then
    raise exception 'Please provide a valid PH mobile number, e.g. 09171234567.';
  end if;
  if v_fulfillment not in ('Pickup', 'Delivery') then
    raise exception 'Fulfillment type must be Pickup or Delivery.';
  end if;
  if v_fulfillment = 'Delivery' and (p_delivery_address is null or trim(p_delivery_address) = '') then
    raise exception 'Delivery address is required for delivery orders.';
  end if;
  if v_location not in ('Amaya', 'GMA') then
    raise exception 'Location must be Amaya or GMA.';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'At least one item is required.';
  end if;
  -- This file: the fee (null = keep it; Pickup = 0). Portal drafts only - an old Pancake-backed order's
  -- fee would never reach Pancake.
  if coalesce(p_delivery_fee, 0) < 0 then
    raise exception 'Delivery fee can''t be negative.';
  end if;
  v_delivery_fee := case when v_fulfillment = 'Delivery' then round(coalesce(p_delivery_fee, v_current_fee), 2) else 0 end;
  if v_delivery_fee <> v_current_fee and coalesce(v_current_sync_status, '') <> 'Not Pushed' then
    raise exception 'Order % is a Pancake order - set its delivery fee in Pancake instead.', p_order_no;
  end if;

  update public."AutomatedOrders"
  set "CustomerName" = trim(p_customer_name),
      "CustomerPhone" = trim(p_customer_phone),
      "CustomerEmail" = nullif(trim(coalesce(p_customer_email, '')), ''),
      "FulfillmentType" = v_fulfillment,
      "DeliveryAddress" = case when v_fulfillment = 'Delivery' then trim(p_delivery_address) else null end,
      "Notes" = nullif(trim(coalesce(p_notes, '')), ''),
      "Location" = v_location,
      "DeliveryFee" = v_delivery_fee,
      "UpdatedBy" = p_admin_username,
      "UpdatedAtUtc" = now()
  where "OrderNo" = p_order_no;

  delete from public."AutomatedOrderLines" where "OrderNo" = p_order_no;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_qty := greatest(coalesce((v_line->>'quantity')::int, 1), 1);
    v_price := greatest(coalesce((v_line->>'price')::numeric, 0), 0);

    if v_line->>'item_name' is null or trim(v_line->>'item_name') = '' then
      raise exception 'Each order line requires an item name.';
    end if;

    insert into public."AutomatedOrderLines"
      ("OrderNo", "CategoryCode", "ItemCode", "ItemName", "Quantity", "Price", "Notes", "VariationId", "BundleKey", "RevenueWeight")
    values
      (p_order_no, nullif(trim(coalesce(v_line->>'category_code', '')), ''),
       nullif(trim(coalesce(v_line->>'item_code', '')), ''), trim(v_line->>'item_name'), v_qty, v_price,
       nullif(trim(coalesce(v_line->>'note', '')), ''), nullif(trim(coalesce(v_line->>'variation_id', '')), ''),
       -- This file: a custom aquarium build's lines (js/calcEmbedLines.js) - see the header.
       left(nullif(trim(coalesce(v_line->>'bundle_key', '')), ''), 40),
       case when nullif(trim(coalesce(v_line->>'bundle_key', '')), '') is not null
            then round(greatest(coalesce((v_line->>'revenue_weight')::numeric, 0), 0), 2) end);

    v_total := v_total + (v_qty * v_price);
  end loop;

  update public."AutomatedOrders" set "EstimatedTotal" = v_total + v_delivery_fee where "OrderNo" = p_order_no;

  if v_current_sync_status = 'Synced' then
    begin
      perform public._update_automated_order_items_in_pancake(p_order_no);
    exception when others then
      update public."AutomatedOrders"
      set "PancakeSyncStatus" = 'Stale',
          "PancakeSyncError" = 'Order was edited in the portal, but updating the live Pancake order failed: ' || sqlerrm
      where "OrderNo" = p_order_no;
    end;
  elsif coalesce(v_current_sync_status, '') not in ('Not Pushed', 'Portal') then
    -- A bot draft (Not Pushed) stays a draft when staff edit it - only Confirm Order moves it on.
    perform public._push_automated_order_to_pancake(p_order_no);
  end if;

  return query
    select o."OrderNo"::text, o."EstimatedTotal", o."PancakeSyncStatus"::text, o."PancakeSyncError"::text
    from public."AutomatedOrders" o
    where o."OrderNo" = p_order_no;
end;
$$;

grant execute on function public.admin_update_automated_order(text, text, text, text, text, text, text, text, text, text, jsonb, numeric) to anon;

-- ---------------------------------------------------------------------------
-- 3. admin_list_automated_order_lines: + bundle_key, revenue_weight at the end (Edit Order keeps the build
--    together when it re-saves the lines).

drop function if exists public.admin_list_automated_order_lines(text, text, text);

create or replace function public.admin_list_automated_order_lines(p_admin_username text, p_admin_password text, p_order_no text)
returns table(entry_no bigint, category_code text, item_code text, item_name text, quantity int, price numeric, notes text, variation_id text, sku text, variant_name text, bundle_key text, revenue_weight numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      l."EntryNo",
      l."CategoryCode"::text,
      l."ItemCode"::text,
      l."ItemName"::text,
      l."Quantity",
      l."Price",
      l."Notes"::text,
      coalesce(nullif(l."VariationId", ''), i."VariationId"::text),
      coalesce(nullif(trim(v."SKU"), ''), nullif(trim(i."SKU"), ''))::text,
      nullif(trim(v."VariantName"), '')::text,
      l."BundleKey"::text,
      l."RevenueWeight"
    from public."AutomatedOrderLines" l
    left join lateral (
      select it."VariationId", it."SKU"
      from public."Items" it
      where it."Code" = coalesce(nullif(l."ItemCode", ''), nullif(l."CategoryCode", ''))
         or (l."ItemCode" is null and it."Name" = nullif(l."CategoryCode", ''))
      limit 1
    ) i on true
    left join public."Variants" v
      on v."VariationId" = coalesce(nullif(l."VariationId", ''), i."VariationId"::text)
    where l."OrderNo" = p_order_no
    order by l."EntryNo";
end;
$$;

grant execute on function public.admin_list_automated_order_lines(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 4. admin_get_top_selling_items: revenue = the bundle share for a custom aquarium build's lines.

drop function if exists public.admin_get_top_selling_items(text, text, date, date, int);

create or replace function public.admin_get_top_selling_items(
  p_admin_username text,
  p_admin_password text,
  p_date_from date,
  p_date_to date,
  p_limit int default 10
)
returns table(
  item_code text,
  item_name text,
  category_code text,
  qty_sold numeric,
  revenue numeric,
  order_count bigint,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 10), 1), 100);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      l."ItemCode"::text,
      coalesce(i."Name", l."Description")::text,
      i."CategoryCode"::text,
      sum(l."Quantity") as qty_sold,
      sum(coalesce(br."Revenue", l."GrossAmount")) as revenue,
      count(distinct l."OrderID")::bigint as order_count,
      -- Post-GROUP BY row count (before LIMIT applies) - the true number of distinct items sold
      -- in this range, so the client can show "Top 10 of 47 items sold".
      count(*) over()::bigint as total_count
    from public."OnlineOrderLines" l
    join public."OnlineOrders" o on o."OrderID" = l."OrderID"
    left join public."OnlineOrderLineBundleRevenue" br on br."OrderID" = l."OrderID" and br."LineID" = l."LineID"
    left join public."Items" i on i."Code" = l."ItemCode"
    where l."ItemCode" is not null
      and o."Date" >= p_date_from and o."Date" <= p_date_to
      and lower(trim(coalesce(o."Status", ''))) not in ('cancelled', 'canceled')
    group by l."ItemCode", coalesce(i."Name", l."Description"), i."CategoryCode"
    order by qty_sold desc
    limit v_limit;
end;
$$;

grant execute on function public.admin_get_top_selling_items(text, text, date, date, int) to anon;

-- ---------------------------------------------------------------------------
-- 5. admin_get_category_sales_report: amount = the bundle share for a custom aquarium build's lines.

drop function if exists public.admin_get_category_sales_report(text, text, date, date);

create or replace function public.admin_get_category_sales_report(
  p_admin_username text,
  p_admin_password text,
  p_date_from date,
  p_date_to date
)
returns table(
  warehouse_name text, is_walkin boolean,
  category_code text, category_name text,
  item_code text, item_name text,
  variant_id text, variant_name text, variant_sku text,
  qty_sold numeric, revenue numeric, order_count int
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_date_from is null or p_date_to is null or p_date_to < p_date_from then
    raise exception 'Pick a valid date range.';
  end if;

  return query
    with lines as (
      select l."OrderID" as order_id,
             coalesce(nullif(trim(w."Name"), ''), '(No warehouse)') as wh,
             coalesce(o."ReceivedAtShop", false) as walkin,
             v."VariationId" as var_id,
             v."VariantName" as var_name,
             v."SKU" as var_sku,
             v."CategoryCode" as var_category,
             coalesce(nullif(trim(v."MainItemCode"), ''), nullif(trim(v."ItemCode"), ''), nullif(trim(l."ItemCode"), '')) as code,
             nullif(trim(l."Description"), '') as line_desc,
             coalesce(l."Quantity", 0) as qty,
             coalesce(br."Revenue", l."GrossAmount", 0) as amount
      from public."OnlineOrderLines" l
      join public."OnlineOrders" o on o."OrderID" = l."OrderID"
      left join public."OnlineOrderLineBundleRevenue" br on br."OrderID" = l."OrderID" and br."LineID" = l."LineID"
      left join public."Warehouses" w on w."ID" = o."LocationID"
      left join public."Variants" v on v."VariationId" = l."VariationId"
      where o."Date" >= p_date_from and o."Date" <= p_date_to
        and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
    ),
    resolved as (
      select x.order_id, x.wh, x.walkin,
             coalesce(nullif(trim(x.var_category), ''), nullif(trim(i."CategoryCode"), ''), '(Uncategorized)') as cat,
             coalesce(x.code, x.line_desc, '(No item)') as code,
             coalesce(nullif(trim(i."Name"), ''), x.line_desc, x.code, '(No item)') as name,
             x.var_id, x.var_name, x.var_sku, x.qty, x.amount
      from lines x
      left join public."Items" i on i."Code" = x.code
    )
    select r.wh::text, r.walkin,
           r.cat::text, coalesce(nullif(trim(c."Description"), ''), r.cat)::text,
           r.code::text, max(r.name)::text,
           r.var_id::text, max(r.var_name)::text, max(r.var_sku)::text,
           sum(r.qty)::numeric, sum(r.amount)::numeric, count(distinct r.order_id)::int
    from resolved r
    left join public."Categories" c on c."Code" = r.cat
    group by r.wh, r.walkin, r.cat, c."Description", r.code, r.var_id;
end;
$$;

grant execute on function public.admin_get_category_sales_report(text, text, date, date) to anon;

-- ---------------------------------------------------------------------------
-- 6. admin_get_daily_sales_report: categories use the bundle share for a custom aquarium build's lines.

drop function if exists public.admin_get_daily_sales_report(text, text, date);

create or replace function public.admin_get_daily_sales_report(
  p_admin_username text,
  p_admin_password text,
  p_date date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_result jsonb;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_date is null then
    raise exception 'Pick a date.';
  end if;

  with orders as (
    select o."OrderID" as order_id,
           coalesce(nullif(trim(w."Name"), ''), '(No warehouse)') as wh,
           coalesce(o."ReceivedAtShop", false) as walkin,
           coalesce(o."MoneyToCollect", 0) as total,
           coalesce(o."Discount", 0) as discount,
           coalesce(o."AmountPaid", 0) as paid,
           coalesce(o."Balance", 0) as balance,
           o."PosReceiptNo" as receipt_no,
           o."Time" as order_time,
           o."ConfirmedAtUtc" as confirmed_at,
           o."Status" as status,
           coalesce(nullif(trim(o."WalkinCustomerName"), ''), nullif(trim(o."CustomerName"), '')) as customer,
           coalesce(o."ForDelivery", false) as for_delivery,
           (coalesce(o."Note", '') ilike '%Advance Order Ref:%'
            or (o."ReceivedAtShop" is true and o."PosReceiptNo" is not null and exists (
                  select 1 from public."AdvanceOrders" a
                  where a."ReceiptNo" = o."PosReceiptNo" and a."Warehouse" is not distinct from w."Name"))) as advance_copy,
           case when coalesce(o."ReceivedAtShop", false)
                then coalesce(nullif(trim(o."CreatedBy"), ''), '(Unknown)')
                else coalesce(nullif(trim(o."ConfirmedBy"), ''), nullif(trim(o."CreatedBy"), ''), '(Unknown)')
           end as staff
    from public."OnlineOrders" o
    left join public."Warehouses" w on w."ID" = o."LocationID"
    where lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      and (o."Date" = p_date
           or (o."ConfirmedAtUtc" >= (p_date::timestamp at time zone 'Asia/Manila')
               and o."ConfirmedAtUtc" < ((p_date + 1)::timestamp at time zone 'Asia/Manila')))
      and (
        (o."ReceivedAtShop" is true and o."Date" = p_date)
        or (o."ReceivedAtShop" is not true
            and coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = p_date)
      )
  ),
  pays as (
    select x.order_id, x.wh, x.walkin, p."MethodCode" as code, p."Amount" as amount
    from orders x
    join public."OnlineOrderPayments" p on p."OrderID" = x.order_id
  ),
  tenders as (
    select pd.wh, pd.walkin, public._payment_method_label(pd.code)::text as method,
           sum(pd.amount) as amount, count(distinct pd.order_id) as cnt
    from pays pd
    group by pd.wh, pd.walkin, pd.code
    union all
    select x.wh, x.walkin, 'Unpaid / not synced yet',
           sum(x.total) - coalesce((select sum(pd.amount) from pays pd where pd.wh = x.wh and pd.walkin = x.walkin), 0),
           count(*) filter (where not exists (select 1 from pays pd where pd.order_id = x.order_id))
    from orders x
    group by x.wh, x.walkin
  ),
  cats as (
    select x.wh, x.walkin,
           coalesce(nullif(trim(v."CategoryCode"), ''), nullif(trim(i."CategoryCode"), ''), '(Uncategorized)') as cat,
           coalesce(l."Quantity", 0) as qty,
           coalesce(br."Revenue", l."GrossAmount", 0) as amount
    from orders x
    join public."OnlineOrderLines" l on l."OrderID" = x.order_id
    left join public."OnlineOrderLineBundleRevenue" br on br."OrderID" = l."OrderID" and br."LineID" = l."LineID"
    left join public."Variants" v on v."VariationId" = l."VariationId"
    left join public."Items" i on i."Code" = coalesce(nullif(trim(v."MainItemCode"), ''), nullif(trim(v."ItemCode"), ''), nullif(trim(l."ItemCode"), ''))
  ),
  exp as (
    select coalesce(nullif(trim(e.wh), ''), '(No warehouse)') as wh, sum(e.amount) as amount, count(*) as cnt
    from (
      select h."Warehouse" as wh, h."NetAmount" as amount
      from public."ExpenseEntryHeader" h where h."Date" = p_date
      union all
      select j."Warehouse", j."Amount"
      from public."ExpenseJournalEntries" j where j."EntryDate" = p_date
        and not exists (select 1 from public."BusinessBillPayments" bp where bp."ExpenseJournalEntryID" = j."EntryID")
    ) e
    group by 1
  )
  select jsonb_build_object(
    'date', p_date,
    'compare', (
      select jsonb_build_object(
        'yesterday', (select to_jsonb(t) from public._daily_sales_totals(p_date - 1) t),
        'last_week', (select to_jsonb(t) from public._daily_sales_totals(p_date - 7) t)
      )
    ),
    'orders', coalesce((
      select jsonb_agg(jsonb_build_object(
               'order_id', x.order_id, 'receipt_no', x.receipt_no, 'time', x.order_time,
               'confirmed_at', x.confirmed_at, 'warehouse', x.wh, 'is_walkin', x.walkin,
               'customer', x.customer, 'staff', x.staff, 'status', x.status, 'for_delivery', x.for_delivery,
               'advance_copy', x.advance_copy,
               'total', x.total, 'discount', x.discount, 'paid', x.paid, 'balance', x.balance,
               'payments', (select string_agg(public._payment_method_label(pd.code) || ' ' || to_char(pd.amount, 'FM999,999,990.00'), ', ')
                            from pays pd where pd.order_id = x.order_id)
             ) order by x.walkin, coalesce(x.confirmed_at::text, x.order_time), x.order_id)
      from orders x), '[]'::jsonb),
    'tenders', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', t.wh, 'is_walkin', t.walkin, 'method', t.method,
                                          'amount', t.amount, 'order_count', t.cnt) order by t.amount desc)
      from tenders t where t.amount <> 0), '[]'::jsonb),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', c.wh, 'is_walkin', c.walkin, 'category', c.name,
                                          'qty', c.qty, 'revenue', c.revenue) order by c.revenue desc)
      from (
        select k.wh, k.walkin, coalesce(nullif(trim(cg."Description"), ''), k.cat) as name,
               sum(k.qty) as qty, sum(k.amount) as revenue
        from cats k
        left join public."Categories" cg on cg."Code" = k.cat
        group by k.wh, k.walkin, 3
      ) c), '[]'::jsonb),
    'cash', coalesce((
      select jsonb_agg(jsonb_build_object(
               'warehouse', h."Warehouse", 'eod_id', h."EODID", 'user_id', h."UserID", 'time', h."DeclTime",
               'float', h."FloatAmount", 'cash_sales', h."CashSales", 'expected', h."ExpectedCash",
               'declared', h."DeclaredCash", 'variance', h."Variance", 'reason', h."VarianceReason"
             ) order by h."Warehouse", h."DeclTime")
      from public."TenderDeclarationHeader" h
      where h."DeclDate" = p_date), '[]'::jsonb),
    'expenses', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', e.wh, 'amount', e.amount, 'count', e.cnt) order by e.wh)
      from exp e), '[]'::jsonb),
    -- The entries behind 'expenses' (same two sources, same day), for the page's clickable Expenses drill-down.
    'expense_lines', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.warehouse, x.entry_time nulls last, x.ref)
      from (
        select 'POS'::text as source, h."ReceiptNo"::text as ref, h."Time"::text as entry_time,
               coalesce(nullif(trim(h."Warehouse"), ''), '(No warehouse)') as warehouse,
               h."ExpenseCategory"::text as category, h."Description"::text as description,
               h."UserID"::text as staff, coalesce(h."NetAmount", 0) as amount
        from public."ExpenseEntryHeader" h where h."Date" = p_date
        union all
        select 'Journal', null, to_char(j."CreatedAtUtc" at time zone 'Asia/Manila', 'HH24:MI'),
               coalesce(nullif(trim(j."Warehouse"), ''), '(No warehouse)'),
               j."ExpenseCategory", j."Description", j."CreatedBy", j."Amount"
        from public."ExpenseJournalEntries" j where j."EntryDate" = p_date
        and not exists (select 1 from public."BusinessBillPayments" bp where bp."ExpenseJournalEntryID" = j."EntryID")
      ) x), '[]'::jsonb),
    -- Advance orders PLACED this day (voided left out) - same as the Dashboard's "Today's Advance Orders" card.
    'advance_placed', coalesce((
      select jsonb_agg(jsonb_build_object(
               'transaction_no', a."TransactionNo", 'receipt_no', a."ReceiptNo", 'time', a."Time",
               'warehouse', coalesce(nullif(trim(a."Warehouse"), ''), '(No warehouse)'),
               'customer', a."CustomerName", 'description', a."Order_Description", 'staff', a."UserID",
               'net', coalesce(a."NetAmount", 0), 'downpayment', coalesce(a."Downpayment", 0),
               'balance', greatest(coalesce(a."Balance", 0), 0)
             ) order by a."Time", a."TransactionNo")
      from public."AdvanceOrders" a
      where a."Date" = p_date and not coalesce(a."IsVoid", false)), '[]'::jsonb),
    -- Advance-order money COLLECTED this day on any advance order (downpayments, balances, portal Mark Fully
    -- Paid / delivery remits, and a void's refund as a negative) - same as the Dashboard's "Collected today -
    -- by tender" and the POS EOD "ADV ORDER COLLECTIONS". Voided orders are NOT filtered, on purpose.
    'advance_collected', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', c.wh, 'tender', c.tender, 'amount', c.amount,
                                          'payment_count', c.cnt) order by c.amount desc)
      from (
        select coalesce(nullif(trim(coalesce(a."Warehouse", p."Warehouse")), ''), '(No warehouse)') as wh,
               coalesce(nullif(upper(trim(p."TenderTypeCode")), ''), '(No tender)') as tender,
               sum(coalesce(p."Amount", 0)) as amount, count(*) as cnt
        from public."AdvanceOrderPayments" p
        left join public."AdvanceOrders" a on a."TransactionNo" = p."AdvanceTransactionNo"
        where p."Date" = p_date
        group by 1, 2
      ) c), '[]'::jsonb)
  )
  into v_result;

  return v_result;
end;
$$;

grant execute on function public.admin_get_daily_sales_report(text, text, date) to anon;

notify pgrst, 'reload schema';
