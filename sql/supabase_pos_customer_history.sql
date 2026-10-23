-- POS checkout: a picked customer's addresses + existing orders - per "is it possible to show their
-- existing orders and address?" (the customer box, FunctionEvents.PromptForCustomer).
--
-- pos_get_customer_history(pos key, mobile, psid) - one list, two kinds of rows:
--   'Address' - up to 3 distinct addresses, the Messenger default first, then newest: the chat's saved
--               address + every address it used (ChatbotCustomerContacts), bot / order-now delivery
--               addresses, and online orders' shipping addresses. Walk-in / pickup placeholders skipped.
--   'Order'   - the 10 newest orders: Online Orders (online + walk-in WI-) matched by mobile (last 10
--               digits, like pos_search_customers), the linked walk-in PSID or a bot order of that chat,
--               plus bot orders not confirmed yet (a confirmed one is shown as its Online Order instead).
--               detail = first 3 items (+ "+N more") and the balance when one is left.
-- Matched on the mobile and/or the Messenger PSID - either may be empty.
--
-- POS key only (_pos_key_ok), like the other pos_* RPCs. Run AFTER supabase_pos_walkin_orders_direct.sql
-- (WalkinPsid). Safe to re-run. Needs the POS build with the customer history panel.

drop function if exists public.pos_get_customer_history(text, text, text);

create or replace function public.pos_get_customer_history(p_pos_key text, p_phone text, p_psid text)
returns table(kind text, ref text, seen date, status text, amount numeric, detail text)
language sql
stable
security definer
set search_path = public
as $$
  with q as (
    select case when length(d) >= 10 then right(d, 10) end as phone_key,
           nullif(trim(coalesce(p_psid, '')), '') as psid
      from (select regexp_replace(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '^(63|0)', '') as d) x
     where public._pos_key_ok(p_pos_key)
  ),
  aos as (
    select a.*
      from public."AutomatedOrders" a, q
     where (q.psid is not null and (a."GmaPsid" = q.psid or a."Psid" = q.psid))
        or right(regexp_replace(coalesce(a."CustomerPhone", ''), '\D', '', 'g'), 10) = q.phone_key
  ),
  onl as (
    select o.*
      from public."OnlineOrders" o, q
     where (q.psid is not null and o."WalkinPsid" = q.psid)
        or right(regexp_replace(coalesce(o."ShippingPhone", ''), '\D', '', 'g'), 10) = q.phone_key
        or right(regexp_replace(coalesce(o."WalkinCustomerPhone", ''), '\D', '', 'g'), 10) = q.phone_key
        or o."OrderID" in (select a."PancakeReceiptNo" from aos a where a."PancakeReceiptNo" is not null)
  ),
  addr_raw as (
    select k."Value" as addr, (k."LastSeenAtUtc" at time zone 'Asia/Manila')::date as seen, coalesce(k."IsDefault", false) as dflt
      from public."ChatbotCustomerContacts" k, q
     where k."Kind" = 'Address' and k."Psid" = q.psid
    union all
    select c."CustomerAddress", null, true
      from public."ChatbotConversations" c, q
     where c."Psid" = q.psid
    union all
    select a."DeliveryAddress", (a."CreatedAtUtc" at time zone 'Asia/Manila')::date, false
      from aos a
    union all
    select o."ShippingAddress", o."Date"::date, false   -- incl. a walk-in's checkout address ('Walkin' skipped below)
      from onl o
  ),
  addr as (
    select distinct on (lower(regexp_replace(trim(addr), '\s+', ' ', 'g'))) trim(addr) as addr, seen, dflt
      from addr_raw
     where length(trim(coalesce(addr, ''))) > 5
       and lower(trim(addr)) not in ('walkin', 'walk-in', 'walk in', 'pickup', 'pick up', 'pick-up', 'n/a', 'none')
     order by lower(regexp_replace(trim(addr), '\s+', ' ', 'g')), dflt desc, seen desc nulls last
  ),
  orders as (
    select o."OrderID"::text as ref, o."Date"::date as seen,
           (case when o."ReceivedAtShop" is true then 'Walk-in' else 'Online' end) || ' · ' || coalesce(nullif(trim(o."Status"), ''), '-') as status,
           coalesce(o."MoneyToCollect", 0)::numeric as amount,
           o."Balance"::numeric as balance,
           (select string_agg(t.line, ', ' order by t.n)
              from (select l."LineID",
                           row_number() over (order by case when l."LineID" ~ '^\d+$' then l."LineID"::numeric end nulls last, l."LineID") as n,
                           rtrim(to_char(coalesce(l."Quantity", 1), 'FM999990.##'), '.') || 'x ' || coalesce(nullif(trim(l."Description"), ''), l."product_display_id", l."ItemCode", 'item') as line
                      from public."OnlineOrderLines" l where l."OrderID" = o."OrderID") t
             where t.n <= 3) as items,
           (select count(*) from public."OnlineOrderLines" l where l."OrderID" = o."OrderID") as line_count
      from onl o
    union all
    select a."OrderNo"::text, (a."CreatedAtUtc" at time zone 'Asia/Manila')::date,
           'Bot order · ' || coalesce(nullif(trim(a."Status"), ''), 'New'),
           coalesce(a."EstimatedTotal", 0)::numeric,
           null::numeric,
           (select string_agg(t.line, ', ' order by t.n)
              from (select row_number() over (order by l."EntryNo") as n, l."Quantity" || 'x ' || l."ItemName" as line
                      from public."AutomatedOrderLines" l where l."OrderNo" = a."OrderNo") t
             where t.n <= 3),
           (select count(*) from public."AutomatedOrderLines" l where l."OrderNo" = a."OrderNo")
      from aos a
     where a."PancakeReceiptNo" is null or not exists (select 1 from onl o where o."OrderID" = a."PancakeReceiptNo")
  )
  select * from (
    select 'Address'::text, null::text, a.seen, null::text, null::numeric, a.addr
      from addr a
     order by a.dflt desc, a.seen desc nulls last
     limit 3
  ) x
  union all
  select * from (
    select 'Order'::text, o.ref, o.seen, o.status, o.amount,
           concat_ws('  ·  ',
             nullif(coalesce(o.items, '') || case when o.line_count > 3 then ' +' || (o.line_count - 3) || ' more' else '' end, ''),
             case when coalesce(o.balance, 0) > 0 then 'Balance ' || to_char(o.balance, 'FM999,999,990.00') end)
      from orders o
     order by o.seen desc nulls last, o.ref desc
     limit 10
  ) y;
$$;

revoke all on function public.pos_get_customer_history(text, text, text) from public;
grant execute on function public.pos_get_customer_history(text, text, text) to anon, service_role;

notify pgrst, 'reload schema';

-- Verification - one result.
select p.proname::text as function_name,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'callable by the POS (POS key checked inside)' else 'CHECK GRANTS' end as detail
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'pos_get_customer_history';
