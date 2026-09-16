-- Per direct follow-up request: "can we log the actual facebook name on a customer table that
-- should act as our CRM" - prompted by the bot having to ask a customer to type their name/
-- contact/address because it had nothing on file (ChatbotConversations.CustomerName was only ever
-- auto-filled from Facebook's profile API, which is frequently empty/permission-restricted - see
-- fetchFacebookProfileName's header comment in supabase/functions/facebook-messenger-webhook/
-- index.ts). Once a customer DOES type their name/phone/address in chat, nothing before this
-- persisted it anywhere durable except inside a specific AutomatedOrders row if/when an order was
-- actually placed - so a returning customer who chatted without ordering got asked again.
--
-- ChatbotConversations is already exactly "one row per Messenger customer for this page" (Psid
-- primary key - see supabase_chatbot_conversations_tables.sql's own header), so this extends that
-- table into the CRM itself rather than standing up a parallel customer table that would just
-- duplicate Psid/PageId/CustomerName and risk drifting out of sync with it.
--
-- CustomerNameSource distinguishes a name Meta's profile API supplied (fetchFacebookProfileName -
-- can be wrong/stale, e.g. a nickname) from one the customer explicitly typed for their own order
-- (more authoritative) - shown in the new staff Customers page (docs/customers.html) so staff can
-- judge which name to trust when they differ.

alter table public."ChatbotConversations" add column if not exists "CustomerPhone" varchar(50);
alter table public."ChatbotConversations" add column if not exists "CustomerAddress" varchar(500);
alter table public."ChatbotConversations" add column if not exists "CustomerNameSource" varchar(20);

comment on column public."ChatbotConversations"."CustomerPhone" is 'Contact number the customer gave in chat (save_customer_info tool / create_order) - the CRM record, independent of any one order.';
comment on column public."ChatbotConversations"."CustomerAddress" is 'Delivery/home address the customer gave in chat (save_customer_info tool / create_order) - the CRM record, independent of any one order.';
comment on column public."ChatbotConversations"."CustomerNameSource" is '''FacebookProfile'' (auto-fetched via fetchFacebookProfileName, may be a nickname or unavailable) or ''CustomerProvided'' (the customer explicitly typed it for their own order/record - more authoritative). Null for older rows predating this column.';

-- ---------------------------------------------------------------------------
-- Staff Customers page (docs/customers.html / js/customers.js) - same access tier as GMA
-- Conversations/AI Bot Sandbox (is_admin_authorized, i.e. super users only - this table carries
-- Messenger PII), same p_search/p_page/p_page_size shape as admin_list_automated_orders.
-- order_count is a live join against AutomatedOrders by GmaPsid+GmaPageId (matches
-- admin_list_automated_orders_by_gma_conversation's own matching convention), not a stored
-- counter, so it's always accurate without a separate maintenance job.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_list_gma_customers(text, text, text, int, int);

create or replace function public.admin_list_gma_customers(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  psid text,
  page_id text,
  customer_name text,
  customer_name_source text,
  customer_phone text,
  customer_address text,
  order_count bigint,
  last_message_at_utc timestamptz,
  created_at_utc timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      c."Psid"::text,
      c."PageId"::text,
      c."CustomerName"::text,
      c."CustomerNameSource"::text,
      c."CustomerPhone"::text,
      c."CustomerAddress"::text,
      coalesce((
        select count(*) from public."AutomatedOrders" ao
        where ao."GmaPsid" = c."Psid" and ao."GmaPageId" = c."PageId"
      ), 0),
      c."LastMessageAtUtc",
      c."CreatedAtUtc",
      count(*) over()
    from public."ChatbotConversations" c
    where (
      v_search is null
      or c."CustomerName" ilike '%' || v_search || '%'
      or c."CustomerPhone" ilike '%' || v_search || '%'
      or c."CustomerAddress" ilike '%' || v_search || '%'
      or c."Psid" ilike '%' || v_search || '%'
    )
    order by c."LastMessageAtUtc" desc nulls last, c."CreatedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_gma_customers(text, text, text, int, int) to anon;
