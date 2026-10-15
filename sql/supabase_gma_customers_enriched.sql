-- Customers page, richer records - per "can we beautify the customers.. i can see its lacking a lot
-- of info".
--
-- admin_list_gma_customers only returned what the bot itself saved on ChatbotConversations
-- (CustomerPhone / CustomerAddress), so anyone who never typed their details to the bot showed
-- blank - even when staff had already taken their number on an order, or Pancake knows them. Now
-- each row also fills the gaps from:
--   * their latest AutomatedOrders row (matched by GmaPsid, or Psid for order-now.html orders) -
--     phone / address / email, plus order count, order value (not cancelled) and last order date;
--   * their Pancake customer (OnlineCustomers.FbID = the PSID, bare or page-prefixed - same match
--     as public_lookup_customer_by_psid) - phone / address / email, Pancake order count + spend.
-- phone_source / address_source say where the shown value came from ('Chat', 'Order', 'Pancake').
-- Also returns the conversation's tags, mood and paused flag, and the stat-tile counts (over the
-- search) so docs/customers.html can show totals and the All / Has phone / No phone / Ordered
-- filter without a second call.
--
-- Same function name, new columns + p_filter, so it's dropped and re-created - replaces the
-- version in supabase_chatbot_customer_crm.sql (don't re-run that file's function part afterwards).
-- Read-only, safe to re-run. Needs docs/js/customers.js ?v=3.

create index if not exists "IX_AutomatedOrders_GmaPsid" on public."AutomatedOrders" ("GmaPsid");
create index if not exists "IX_AutomatedOrders_Psid" on public."AutomatedOrders" ("Psid");

drop function if exists public.admin_list_gma_customers(text, text, text, int, int);
drop function if exists public.admin_list_gma_customers(text, text, text, int, int, text);

create or replace function public.admin_list_gma_customers(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_page int default 1,
  p_page_size int default 50,
  p_filter text default null      -- null/'all', 'has_phone', 'no_phone', 'ordered'
)
returns table(
  psid text,
  page_id text,
  customer_name text,
  customer_name_source text,
  customer_phone text,
  phone_source text,
  customer_address text,
  address_source text,
  customer_email text,
  order_count bigint,
  order_value numeric,
  last_order_at_utc timestamptz,
  pancake_order_count int,
  pancake_purchased numeric,
  customer_mood text,
  customer_mood_reason text,
  is_paused boolean,
  tags jsonb,
  last_message_at_utc timestamptz,
  last_customer_message_at_utc timestamptz,
  created_at_utc timestamptz,
  total_count bigint,
  stat_total bigint,
  stat_with_phone bigint,
  stat_ordered bigint,
  stat_order_value numeric
)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_filter text := coalesce(nullif(trim(p_filter), ''), 'all');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with base as (
      select
        c."Psid", c."PageId", c."CustomerName", c."CustomerNameSource",
        nullif(trim(c."CustomerPhone"), '') as chat_phone,
        nullif(trim(c."CustomerAddress"), '') as chat_address,
        c."CustomerMood", c."CustomerMoodReason", c."IsPaused",
        c."LastMessageAtUtc", c."LastCustomerMessageAtUtc", c."CreatedAtUtc",
        ord.cnt, ord.value, ord.last_at,
        lo.phone as order_phone, lo.address as order_address, lo.email as order_email,
        pc.phone as pc_phone, pc.address as pc_address, pc.email as pc_email,
        pc.order_count as pc_orders, pc.purchased as pc_purchased
      from public."ChatbotConversations" c
      left join lateral (
        select count(*) as cnt,
               coalesce(sum(ao."EstimatedTotal") filter (where ao."Status" is distinct from 'Cancelled'), 0) as value,
               max(ao."CreatedAtUtc") as last_at
        from public."AutomatedOrders" ao
        where (ao."GmaPsid" = c."Psid" and ao."GmaPageId" = c."PageId") or ao."Psid" = c."Psid"
      ) ord on true
      left join lateral (
        select nullif(trim(ao."CustomerPhone"), '') as phone,
               nullif(trim(ao."DeliveryAddress"), '') as address,
               nullif(trim(ao."CustomerEmail"), '') as email
        from public."AutomatedOrders" ao
        where (ao."GmaPsid" = c."Psid" and ao."GmaPageId" = c."PageId") or ao."Psid" = c."Psid"
        order by ao."CreatedAtUtc" desc
        limit 1
      ) lo on true
      left join lateral (
        select nullif(trim(oc."PrimaryPhoneNumber"), '') as phone,
               nullif(trim(oc."PrimaryAddress"), '') as address,
               nullif(trim(oc."PrimaryEmail"), '') as email,
               oc."OrderCount" as order_count, oc."PurchasedAmount" as purchased
        from public."OnlineCustomers" oc
        where oc."FbID" = c."Psid" or oc."FbID" = c."PageId" || '_' || c."Psid"
        order by oc."UpdatedAt" desc nulls last
        limit 1
      ) pc on true
    ),
    shaped as (
      select b.*,
             coalesce(b.chat_phone, b.order_phone, b.pc_phone) as phone,
             case when b.chat_phone is not null then 'Chat'
                  when b.order_phone is not null then 'Order'
                  when b.pc_phone is not null then 'Pancake' end as phone_src,
             coalesce(b.chat_address, b.order_address, b.pc_address) as address,
             case when b.chat_address is not null then 'Chat'
                  when b.order_address is not null then 'Order'
                  when b.pc_address is not null then 'Pancake' end as address_src,
             coalesce(b.order_email, b.pc_email) as email
      from base b
    ),
    searched as (
      select s.* from shaped s
      where v_search is null
         or s."CustomerName" ilike '%' || v_search || '%'
         or s."Psid" ilike '%' || v_search || '%'
         or s.chat_phone ilike '%' || v_search || '%'
         or s.order_phone ilike '%' || v_search || '%'
         or s.pc_phone ilike '%' || v_search || '%'
         or s.address ilike '%' || v_search || '%'
         or s.email ilike '%' || v_search || '%'
    ),
    stats as (
      select count(*) as total,
             count(*) filter (where phone is not null) as with_phone,
             count(*) filter (where cnt > 0) as ordered,
             coalesce(sum(value), 0) as order_value
      from searched
    )
    select
      s."Psid"::text, s."PageId"::text, s."CustomerName"::text, s."CustomerNameSource"::text,
      s.phone::text, s.phone_src, s.address::text, s.address_src, s.email::text,
      coalesce(s.cnt, 0), coalesce(s.value, 0), s.last_at,
      s.pc_orders, s.pc_purchased,
      s."CustomerMood"::text, s."CustomerMoodReason"::text, coalesce(s."IsPaused", false),
      coalesce((
        select jsonb_agg(jsonb_build_object('id', t."Id", 'name', t."Name", 'color', t."Color") order by lower(t."Name"))
        from public."ChatbotConversationTags" ct
        join public."ChatbotTags" t on t."Id" = ct."TagId"
        where ct."Psid" = s."Psid"
      ), '[]'::jsonb),
      s."LastMessageAtUtc", s."LastCustomerMessageAtUtc", s."CreatedAtUtc",
      count(*) over(),
      st.total, st.with_phone, st.ordered, st.order_value
    from searched s
    cross join stats st
    where v_filter = 'all'
       or (v_filter = 'has_phone' and s.phone is not null)
       or (v_filter = 'no_phone' and s.phone is null)
       or (v_filter = 'ordered' and s.cnt > 0)
    order by s."LastMessageAtUtc" desc nulls last, s."CreatedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_gma_customers(text, text, text, int, int, text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select p.proname::text as function_name, pg_get_function_identity_arguments(p.oid) as args
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'admin_list_gma_customers';
