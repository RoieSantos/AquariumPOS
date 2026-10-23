-- POS walk-ins go straight into the portal - no Pancake order - per "walkin orders should go directly to
-- supabase" (and Pancake retired, 2026-10-21).
--
-- Before: POS checkout (CreateInstoreOnlineOrder, OnlinefunctionsEvents.cs) created every walk-in in Pancake
-- as "POS WALKIN ORDERS" / 11111, and the Pancake sync copied it into OnlineOrders under Pancake's number
-- (e.g. 118359). The real customer was never sent, so Vic could never match a walk-in to a chat.
--
-- Now the POS calls pos_create_walkin_order, which writes OnlineOrders + OnlineOrderLines +
-- OnlineOrderPayments itself:
--   - Order ID: own sequence WI-00001, WI-00002, ... (per decision - not the receipt no.).
--   - The store's receipt no. is kept in "PosReceiptNo" + "PosWarehouseId". Each store's POS has its own
--     database and its own RS-... sequence, so the same receipt no. can exist at two stores - the pair is
--     unique, so a retry / offline catch-up of the same receipt never makes a second order.
--   - "Source" = 'Portal': every existing portal-only branch (Pancake refresh / detail / payment crons,
--     cancel, change branch, line edit, ...) already skips Pancake for it - same as the AO bot orders.
--   - Same shape as a Pancake-synced walk-in: Status 'Shipped', ReceivedAtShop, ShippingAddress 'Walkin' (or the address typed at checkout),
--     Note "RS-... - Customer: X | Mobile: Y | Order: ... | Cashier: Z" (POS Description column, Vic's
--     receipt lookup), MoneyToCollect = sale total after discount (dashboard revenue), lines with the item
--     code / variation the Item Ledger resolves (custom lines keep their CUSTOM-... codes, so the maker flow
--     sees them), payments as CASH + each tender's POSBankID.
--   - The customer typed at checkout (optional) fills WalkinCustomerName / WalkinCustomerPhone and the
--     ShippingPhone, so the Walk-in list, delivery and Vic's phone check see the real customer.
--   - Picking a Messenger customer in the lookup also sends their PSID (a hard link, not just name + phone):
--     kept in "WalkinPsid" only if it's a real ChatbotConversations row (else left empty - never blocks the
--     sale), so the walk-in shows on that customer's Customer Card (supabase_gma_customer_card.sql).
--
-- pos_search_customers backs the checkout's customer lookup: one list from Messenger customers (and every
-- number they've used), bot / GMA orders, online + walk-in orders and old Pancake customers - with the
-- customer's Messenger PSID when one is known, so the POS can show their Facebook picture
-- (chatbot-profile-pics with the POS key - _pos_key_ok is granted to service_role for that) and link the walk-in.
--
-- Both check the POS key (_pos_key_ok, Vault secret POS_API_KEY = GlobalSettings.PosApiKey - same as Online
-- Pay), so only the desktop POS can create walk-ins or search customers.
-- Run AFTER supabase_pos_online_pay.sql, supabase_bot_orders_portal_confirm.sql, supabase_walkin_order_portal_status.sql,
-- supabase_walkin_order_pos_note.sql and supabase_payment_methods_master.sql. Safe to re-run.
-- Needs the POS build with the direct walk-in send (OnlinefunctionsEvents.CreateInstoreOnlineOrder).

-- OnlineOrders is busy all day (crons, portal, POS), so a column / index change waits for a gap: each one
-- is skipped when it's already there, else tried with a short lock wait (never stalls the live writers
-- behind it), up to 30 times.
do $$
declare
  v_steps text[][] := array[
    array['col', 'PosReceiptNo',   'alter table public."OnlineOrders" add column if not exists "PosReceiptNo" varchar(50)'],
    array['col', 'PosWarehouseId', 'alter table public."OnlineOrders" add column if not exists "PosWarehouseId" varchar(100)'],
    array['col', 'WalkinPsid',     'alter table public."OnlineOrders" add column if not exists "WalkinPsid" varchar(255)'],
    array['idx', 'UX_OnlineOrders_PosReceipt', 'create unique index if not exists "UX_OnlineOrders_PosReceipt" on public."OnlineOrders" ("PosWarehouseId", "PosReceiptNo") where "PosReceiptNo" is not null'],
    array['idx', 'IX_OnlineOrders_WalkinPsid', 'create index if not exists "IX_OnlineOrders_WalkinPsid" on public."OnlineOrders" ("WalkinPsid") where "WalkinPsid" is not null']
  ];
  i int;
  v_try int;
begin
  for i in 1 .. array_length(v_steps, 1) loop
    if (v_steps[i][1] = 'col' and exists (select 1 from information_schema.columns
          where table_schema = 'public' and table_name = 'OnlineOrders' and column_name = v_steps[i][2]))
       or (v_steps[i][1] = 'idx' and exists (select 1 from pg_indexes
          where schemaname = 'public' and indexname = v_steps[i][2])) then
      continue;
    end if;
    for v_try in 1 .. 30 loop
      begin
        perform set_config('lock_timeout', '2s', true);
        execute v_steps[i][3];
        exit;
      exception when lock_not_available then
        if v_try = 30 then
          raise exception 'OnlineOrders stayed busy - % not added. Run this file again in a minute.', v_steps[i][2];
        end if;
        perform pg_sleep(1);
      end;
    end loop;
  end loop;
  perform set_config('lock_timeout', '0', true);
end;
$$;

grant execute on function public._pos_key_ok(text) to service_role;

create sequence if not exists public.walkin_order_no_seq;

-- ---------------------------------------------------------------------------
-- 1. Create a walk-in
--   p_order:    { receipt_no, warehouse_id, date "yyyy-mm-dd", time "HH:mm:ss", cashier, note,
--                 customer_name, customer_phone, customer_psid, customer_address, total, discount }
--               customer_address (optional, typed at checkout for delivery) becomes the ShippingAddress
--               instead of the 'Walkin' placeholder - Delivery then has a real address to plot.
--   p_lines:    [{ item_code, product_display_id, variation_id, description, note, quantity, price,
--                  discount, gross, net }]   - price = unit retail before discount; discount = line total
--   p_payments: [{ method, amount }]          - method 'CASH' or the tender's POSBankID
-- Returns the order id, and created = false when that store's receipt was already sent (nothing changed).
drop function if exists public.pos_create_walkin_order(jsonb, jsonb, jsonb);
drop function if exists public.pos_create_walkin_order(text, jsonb, jsonb, jsonb);

create or replace function public.pos_create_walkin_order(p_pos_key text, p_order jsonb, p_lines jsonb, p_payments jsonb default '[]'::jsonb)
returns table(order_id text, created boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_receipt text := nullif(trim(coalesce(p_order ->> 'receipt_no', '')), '');
  v_warehouse text := nullif(trim(coalesce(p_order ->> 'warehouse_id', '')), '');
  v_existing text;
  v_order_id text;
  v_now timestamptz := now();
  v_date date;
  v_time text;
  v_total numeric := coalesce(nullif(trim(coalesce(p_order ->> 'total', '')), '')::numeric, 0);
  v_name text := nullif(trim(coalesce(p_order ->> 'customer_name', '')), '');
  v_phone text := nullif(trim(coalesce(p_order ->> 'customer_phone', '')), '');
  v_psid text;
  v_address text := left(nullif(trim(coalesce(p_order ->> 'customer_address', '')), ''), 500);
  v_cashier text := nullif(trim(coalesce(p_order ->> 'cashier', '')), '');
  v_glass text;
  v_non_cash numeric;
  v_cash numeric;
  v_paid numeric;
begin
  if not public._pos_key_ok(p_pos_key) then
    raise exception 'Not authorized.';
  end if;
  if v_receipt is null then
    raise exception 'receipt_no is required.';
  end if;
  if v_warehouse is null or not exists (select 1 from public."Warehouses" where "ID" = v_warehouse) then
    raise exception 'Unknown warehouse_id "%".', coalesce(v_warehouse, '');
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Receipt % has no lines.', v_receipt;
  end if;

  -- One order per store receipt - serialise two sends of the same receipt, then return the first one.
  perform pg_advisory_xact_lock(hashtext('pos_walkin|' || v_warehouse || '|' || v_receipt));
  select o."OrderID" into v_existing
    from public."OnlineOrders" o
   where o."PosWarehouseId" = v_warehouse and o."PosReceiptNo" = v_receipt;
  if v_existing is not null then
    return query select v_existing::text, false;
    return;
  end if;

  -- The POS's own date/time (Manila) - an offline sale caught up later keeps its real sale date.
  v_date := coalesce(nullif(trim(coalesce(p_order ->> 'date', '')), '')::date, (v_now at time zone 'Asia/Manila')::date);
  v_time := coalesce(nullif(trim(coalesce(p_order ->> 'time', '')), ''), to_char(v_now at time zone 'Asia/Manila', 'HH24:MI:SS'));

  -- "WALK-IN" is the POS's default name, i.e. no customer given.
  if upper(coalesce(v_name, '')) in ('', 'WALK-IN', 'WALKIN', 'WALK IN') then
    v_name := null;
  end if;

  -- The Messenger customer picked in the lookup - only kept if that chat exists.
  select c."Psid" into v_psid
    from public."ChatbotConversations" c
   where c."Psid" = nullif(trim(coalesce(p_order ->> 'customer_psid', '')), '');

  v_order_id := 'WI-' || lpad(nextval('public.walkin_order_no_seq')::text, 5, '0');

  -- Same 12mm / 10mm flag rule as _sync_online_order_detail.
  select case
           when bool_or(regexp_replace(coalesce(l ->> 'description', '') || coalesce(l ->> 'note', '') || coalesce(l ->> 'product_display_id', ''), '[[:space:]]+', '', 'g') ilike '%12mm%') then '12mm'
           when bool_or(regexp_replace(coalesce(l ->> 'description', '') || coalesce(l ->> 'note', '') || coalesce(l ->> 'product_display_id', ''), '[[:space:]]+', '', 'g') ilike '%10mm%') then '10mm'
         end
    into v_glass
    from jsonb_array_elements(p_lines) l;

  -- Paid in full at the counter. The POS's CASH tender is the cash handed over (before change), so it's
  -- capped at what the other tenders leave of the total - payments never add up to more than the sale.
  select coalesce(sum((p ->> 'amount')::numeric) filter (where upper(trim(p ->> 'method')) <> 'CASH'), 0),
         coalesce(sum((p ->> 'amount')::numeric) filter (where upper(trim(p ->> 'method')) = 'CASH'), 0)
    into v_non_cash, v_cash
    from jsonb_array_elements(coalesce(p_payments, '[]'::jsonb)) p
   where coalesce((p ->> 'amount')::numeric, 0) > 0 and nullif(trim(coalesce(p ->> 'method', '')), '') is not null;
  v_cash := greatest(least(v_cash, v_total - v_non_cash), 0);
  v_paid := v_non_cash + v_cash;

  insert into public."OnlineOrders" (
    "OrderID", "Date", "Time", "Status", "CustomerName", "LocationID",
    "MoneyToCollect", "AmountPaid", "Discount", "Balance",
    "ForDelivery", "ShippingAddress", "ShippingPhone", "PrintCount",
    "Last_Updated_At", "SyncedAtUtc", "ReceivedAtShop",
    "GlassThickness", "GlassThicknessCheckedAt", "NotePrintCheckedAt",
    "CreatedBy", "Note", "WalkinCustomerName", "WalkinCustomerPhone",
    "Source", "PosReceiptNo", "PosWarehouseId", "WalkinPsid"
  ) values (
    v_order_id, v_date, v_time, 'Shipped', coalesce(v_name, 'POS WALKIN ORDERS'), v_warehouse,
    v_total, v_paid, coalesce(nullif(trim(coalesce(p_order ->> 'discount', '')), '')::numeric, 0), greatest(v_total - v_paid, 0),
    false, coalesce(v_address, 'Walkin'), v_phone, 0,
    v_now, v_now, true,
    v_glass, v_now, v_now,
    v_cashier, nullif(trim(coalesce(p_order ->> 'note', '')), ''), v_name, v_phone,
    'Portal', v_receipt, v_warehouse, v_psid
  );

  insert into public."OnlineOrderLines" (
    "OrderID", "LineID", "ItemCode", "product_display_id", "VariationId", "Quantity", "UnitCost", "Price",
    "Discount", "GrossAmount", "NetAmount", "Note", "Description", "SyncedAtUtc"
  )
  select
    v_order_id,
    l.ord::text,
    nullif(trim(coalesce(l.v ->> 'item_code', '')), ''),
    nullif(trim(coalesce(l.v ->> 'product_display_id', l.v ->> 'item_code', '')), ''),
    nullif(trim(coalesce(l.v ->> 'variation_id', '')), ''),
    coalesce((l.v ->> 'quantity')::numeric, 1),
    null,
    coalesce((l.v ->> 'price')::numeric, 0),
    coalesce((l.v ->> 'discount')::numeric, 0),
    coalesce((l.v ->> 'gross')::numeric, coalesce((l.v ->> 'price')::numeric, 0) * coalesce((l.v ->> 'quantity')::numeric, 1)),
    coalesce((l.v ->> 'net')::numeric, coalesce((l.v ->> 'price')::numeric, 0) * coalesce((l.v ->> 'quantity')::numeric, 1) - coalesce((l.v ->> 'discount')::numeric, 0)),
    nullif(trim(coalesce(l.v ->> 'note', '')), ''),
    left(nullif(trim(coalesce(l.v ->> 'description', '')), ''), 500),
    v_now
  from jsonb_array_elements(p_lines) with ordinality as l(v, ord);

  -- Payments (Payment Method report, dashboard tender split). CASH goes in at its capped amount.
  insert into public."OnlineOrderPayments" ("OrderID", "MethodCode", "Amount")
  select v_order_id, m.method, m.amount
    from (
      select upper(trim(p ->> 'method')) as method_key, max(trim(p ->> 'method')) as method, sum((p ->> 'amount')::numeric) as amount
        from jsonb_array_elements(coalesce(p_payments, '[]'::jsonb)) p
       where coalesce((p ->> 'amount')::numeric, 0) > 0 and nullif(trim(coalesce(p ->> 'method', '')), '') is not null
         and upper(trim(p ->> 'method')) <> 'CASH'
       group by upper(trim(p ->> 'method'))
      union all
      select 'CASH', 'CASH', v_cash where v_cash > 0
    ) m;
  perform public._payment_method_touch(m.method)
     from (select distinct trim(p ->> 'method') as method
             from jsonb_array_elements(coalesce(p_payments, '[]'::jsonb)) p
            where upper(trim(coalesce(p ->> 'method', ''))) not in ('', 'CASH')) m;

  -- A linked Messenger customer: the mobile / address given at the counter go on their contact list
  -- (not as the default - the bot keeps what the customer told it). Never blocks the sale.
  if v_psid is not null then
    begin
      if v_phone is not null then perform public.gma_upsert_customer_contact(v_psid, 'Phone', v_phone, 'POS', false); end if;
      if v_address is not null then perform public.gma_upsert_customer_contact(v_psid, 'Address', v_address, 'POS', false); end if;
    exception when others then
      raise warning 'Walk-in % - contact list not updated: %', v_order_id, sqlerrm;
    end;
  end if;

  return query select v_order_id::text, true;
end;
$$;

revoke all on function public.pos_create_walkin_order(text, jsonb, jsonb, jsonb) from public;
grant execute on function public.pos_create_walkin_order(text, jsonb, jsonb, jsonb) to anon, service_role;

-- ---------------------------------------------------------------------------
-- 2. Customer lookup at checkout - type a mobile number (4+ digits: matched on the number) or a name.
--    One row per mobile number (last 10 digits), newest first; rows with no number only for a name search.
drop function if exists public.pos_search_customers(text);
drop function if exists public.pos_search_customers(text, text);

create or replace function public.pos_search_customers(p_pos_key text, p_query text)
returns table(customer_name text, phone text, source text, last_seen date, psid text)
language sql
stable
security definer
set search_path = public
as $$
  with q as (
    select trim(coalesce(p_query, '')) as text,
           regexp_replace(coalesce(p_query, ''), '\D', '', 'g') as digits
     where public._pos_key_ok(p_pos_key)
  ),
  -- Numbers are compared on their last 10 digits (0917... / +63917... / 917... are the same number), so the
  -- typed part drops its leading 0 / 63 too: "0917123" finds 9171234567.
  q2 as (
    select text, case when length(digits) >= 4 then right(regexp_replace(digits, '^(63|0)', ''), 10) end as digits from q
  ),
  raw as (
    select nullif(trim(coalesce(c."CustomerName", c."FacebookName")), '') as name, c."CustomerPhone" as phone,
           'Messenger' as source, null::date as seen, c."Psid"::text as psid
      from public."ChatbotConversations" c
    union all
    select nullif(trim(coalesce(c."CustomerName", c."FacebookName")), ''), k."Value", 'Messenger', (k."LastSeenAtUtc" at time zone 'Asia/Manila')::date, c."Psid"
      from public."ChatbotCustomerContacts" k
      join public."ChatbotConversations" c on c."Psid" = k."Psid"
     where k."Kind" = 'Phone'
    union all
    select nullif(trim(a."CustomerName"), ''), a."CustomerPhone", 'Order', (a."CreatedAtUtc" at time zone 'Asia/Manila')::date,
           coalesce(a."GmaPsid", a."Psid")
      from public."AutomatedOrders" a
    union all
    select nullif(trim(o."WalkinCustomerName"), ''), o."WalkinCustomerPhone", 'Walk-in', o."Date", o."WalkinPsid"
      from public."OnlineOrders" o
     where o."ReceivedAtShop" is true and (o."WalkinCustomerName" is not null or o."WalkinCustomerPhone" is not null)
    union all
    select nullif(trim(o."CustomerName"), ''), o."ShippingPhone", 'Order', o."Date", null
      from public."OnlineOrders" o
     where o."ReceivedAtShop" is not true
    union all
    select nullif(trim(oc."Name"), ''), oc."PrimaryPhoneNumber", 'Pancake', (oc."LastOrderAt" at time zone 'Asia/Manila')::date, null
      from public."OnlineCustomers" oc
  ),
  keyed as (
    select r.name, nullif(trim(r.phone), '') as phone, r.source, r.seen, r.psid,
           case when length(regexp_replace(coalesce(r.phone, ''), '\D', '', 'g')) >= 10
                then right(regexp_replace(r.phone, '\D', '', 'g'), 10) end as phone_key
      from raw r, q2
     where r.name is distinct from 'POS WALKIN ORDERS'
       and (case
              when q2.digits is not null then right(regexp_replace(coalesce(r.phone, ''), '\D', '', 'g'), 10) like '%' || q2.digits || '%'
              when length(q2.text) >= 2 then r.name ilike '%' || q2.text || '%'
              else false
            end)
  ),
  best as (
    select distinct on (coalesce(phone_key, lower(name)))
           name, phone, source, seen, phone_key
      from keyed
     where name is not null or phone_key is not null
     order by coalesce(phone_key, lower(name)), (name is null), seen desc nulls last
  ),
  -- The newest Messenger chat behind that number / name (two Facebook accounts on one number: the newest).
  -- An order-now.html / old order's psid only counts if it's a real chat.
  linked as (
    select coalesce(r.phone_key, lower(r.name)) as k,
           (array_agg(r.psid order by r.seen desc nulls last) filter (where c."Psid" is not null))[1] as psid
      from keyed r
      left join public."ChatbotConversations" c on c."Psid" = r.psid
     group by 1
  )
  select coalesce(b.name, '(no name)')::text, b.phone::text, b.source::text, b.seen, l.psid::text
    from best b
    left join linked l on l.k = coalesce(b.phone_key, lower(b.name))
   order by (b.phone_key is null), b.seen desc nulls last, b.name
   limit 15;
$$;

revoke all on function public.pos_search_customers(text, text) from public;
grant execute on function public.pos_search_customers(text, text) to anon, service_role;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'function' as section, p.proname::text as name,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'callable by the POS (POS key checked inside)' else 'CHECK GRANTS' end as detail
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('pos_create_walkin_order', 'pos_search_customers')
union all
select 'column', c.column_name::text, c.data_type::text
  from information_schema.columns c
 where c.table_schema = 'public' and c.table_name = 'OnlineOrders' and c.column_name in ('PosReceiptNo', 'PosWarehouseId', 'WalkinPsid')
union all
select 'next order no.', 'walkin_order_no_seq', 'WI-' || lpad((coalesce((select last_value from public.walkin_order_no_seq where is_called), 0) + 1)::text, 5, '0');
