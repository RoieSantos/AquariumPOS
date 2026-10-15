-- Customer Card - per "i want to have a customer card same like business central".
--
-- Opening a row on the Customers page (docs/customers.html) now shows a BC-style Customer Card:
-- General / Communication FastTabs (editable), a Statistics FactBox and an Orders part. This file
-- adds the two RPCs it needs; the header fields themselves come from admin_list_gma_customers
-- (supabase_gma_customers_enriched.sql), so run that first.
--
-- 1. admin_list_gma_customer_orders - every AutomatedOrders row for the customer (GmaPsid + page,
--    or Psid for order-now.html orders - same match as the Customers list), newest first, with
--    paid / balance from AutomatedOrderPayments and the Online Orders status once confirmed.
-- 2. admin_update_gma_customer - staff edit the CRM record on ChatbotConversations (Name / Contact
--    No. / Address). This is the same record the bot reads for returning customers and saves to
--    with save_customer_info, so a fix here is what the bot sees next. A blank field clears it.
--    A changed name is marked CustomerNameSource = 'Staff'. Contact No. uses the same mobile rule
--    as Create Order (09xxxxxxxxx / 639xxxxxxxxx).
--    NOTE: the bot's order-privacy check (chatbot-engine.ts "Order privacy") lets a chat see orders
--    whose mobile number matches this CustomerPhone - so only save a number that is really theirs.
--
-- Super users only (is_admin_authorized), like the Customers page. Run AFTER
-- supabase_gma_customers_enriched.sql. Safe to re-run. Needs docs/js/customers.js ?v=4.

drop function if exists public.admin_list_gma_customer_orders(text, text, text, text);

create or replace function public.admin_list_gma_customer_orders(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_page_id text
)
returns table(
  order_no text,
  created_at_utc timestamptz,
  status text,
  online_order_status text,
  fulfillment_type text,
  location text,
  total numeric,
  amount_paid numeric,
  balance numeric,
  item_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_psid is null or trim(p_psid) = '' then
    raise exception 'Psid is required.';
  end if;

  return query
    select
      o."OrderNo"::text,
      o."CreatedAtUtc",
      o."Status"::text,
      oo."Status"::text,
      o."FulfillmentType"::text,
      o."Location"::text,
      o."EstimatedTotal"::numeric,
      coalesce(pay.paid, 0)::numeric,
      (o."EstimatedTotal" - coalesce(pay.paid, 0))::numeric,
      coalesce((select sum(l."Quantity") from public."AutomatedOrderLines" l where l."OrderNo" = o."OrderNo"), 0)::bigint
    from public."AutomatedOrders" o
    left join lateral (
      select sum(p."Amount") as paid from public."AutomatedOrderPayments" p where p."OrderNo" = o."OrderNo"
    ) pay on true
    left join public."OnlineOrders" oo on oo."OrderID" = o."PancakeReceiptNo"
    where (o."GmaPsid" = trim(p_psid) and o."GmaPageId" = trim(coalesce(p_page_id, '')))
       or o."Psid" = trim(p_psid)
    order by o."CreatedAtUtc" desc;
end;
$$;

grant execute on function public.admin_list_gma_customer_orders(text, text, text, text) to anon;


drop function if exists public.admin_update_gma_customer(text, text, text, text, text, text, text);

create or replace function public.admin_update_gma_customer(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_page_id text,
  p_name text,
  p_phone text,
  p_address text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_name text := nullif(trim(coalesce(p_name, '')), '');
  v_phone text := nullif(trim(coalesce(p_phone, '')), '');
  v_address text := nullif(trim(coalesce(p_address, '')), '');
  v_old_name text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select "CustomerName" into v_old_name
  from public."ChatbotConversations"
  where "Psid" = trim(coalesce(p_psid, ''));   -- Psid is the primary key
  if not found then
    raise exception 'Customer not found.';
  end if;

  if v_phone is not null and regexp_replace(v_phone, '[^0-9]', '', 'g') !~ '^(09[0-9]{9}|639[0-9]{9})$' then
    raise exception 'Contact No. must be a mobile number like 09171234567.';
  end if;
  if length(coalesce(v_name, '')) > 255 then raise exception 'Name is too long.'; end if;
  if length(coalesce(v_phone, '')) > 50 then raise exception 'Contact No. is too long.'; end if;
  if length(coalesce(v_address, '')) > 500 then raise exception 'Address is too long (500 characters max).'; end if;

  -- Tells the contact-list trigger (supabase_gma_customer_contacts.sql) this change came from staff.
  perform set_config('app.contact_source', 'Staff', true);
  update public."ChatbotConversations"
  set "CustomerName" = v_name,
      "CustomerNameSource" = case when v_name is distinct from v_old_name then 'Staff' else "CustomerNameSource" end,
      "CustomerPhone" = v_phone,
      "CustomerAddress" = v_address
  where "Psid" = trim(p_psid);
end;
$$;

grant execute on function public.admin_update_gma_customer(text, text, text, text, text, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select p.proname::text as function_name, pg_get_function_identity_arguments(p.oid) as args
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('admin_list_gma_customer_orders', 'admin_update_gma_customer');
