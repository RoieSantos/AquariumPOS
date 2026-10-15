-- Create Order pre-fill - per "when the user creates new order this will fill in Phone or contact
-- number / email and location" (GMA Conversations > Create Order, docs/js/gmaConversations.js).
--
-- staff_get_gma_customer_prefill returns what the customer record knows, one row per value:
--   * Phone / Address - every entry in their Contacts & Addresses (ChatbotCustomerContacts,
--     supabase_gma_customer_contacts.sql), default first, then most recently used. The form fills the
--     default and offers the others as one-click chips.
--   * Email   - from their latest order that had one, else their Pancake customer.
--   * Location - the branch (Amaya / GMA) of their latest order.
-- The form only fills fields that are still empty, and only for a NEW order (editing keeps the
-- order's own values).
--
-- Same access as the rest of GMA Conversations (is_conversations_authorized - Super User or
-- Conversations Access). Read-only. Run AFTER supabase_gma_customer_contacts.sql. Safe to re-run.
-- Needs docs/js/gmaConversations.js ?v=prefill1.

drop function if exists public.staff_get_gma_customer_prefill(text, text, text, text);

create or replace function public.staff_get_gma_customer_prefill(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_page_id text
)
returns table(kind text, value text, label text, is_default boolean, source text)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare
  v_psid text := trim(coalesce(p_psid, ''));
  v_page text := trim(coalesce(p_page_id, ''));
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_psid = '' then
    return;
  end if;

  return query
    select x."Kind"::text, x."Value"::text, x."Label"::text, x."IsDefault", x."Source"::text
    from public."ChatbotCustomerContacts" x
    where x."Psid" = v_psid
    order by x."Kind", x."IsDefault" desc, x."LastSeenAtUtc" desc;

  return query
    select 'Email'::text, e.email::text, null::text, true, e.src::text
    from (
      select nullif(trim(o."CustomerEmail"), '') as email, 'Order' as src, 1 as pri, o."CreatedAtUtc" as at
      from public."AutomatedOrders" o
      where ((o."GmaPsid" = v_psid and o."GmaPageId" = v_page) or o."Psid" = v_psid)
        and nullif(trim(o."CustomerEmail"), '') is not null
      union all
      select nullif(trim(oc."PrimaryEmail"), ''), 'Pancake', 2, oc."UpdatedAt"
      from public."OnlineCustomers" oc
      where (oc."FbID" = v_psid or oc."FbID" = v_page || '_' || v_psid)
        and nullif(trim(oc."PrimaryEmail"), '') is not null
      order by pri, at desc nulls last
      limit 1
    ) e;

  return query
    select 'Location'::text, o."Location"::text, null::text, true, 'Order'::text
    from public."AutomatedOrders" o
    where ((o."GmaPsid" = v_psid and o."GmaPageId" = v_page) or o."Psid" = v_psid)
      and o."Location" in ('Amaya', 'GMA')
    order by o."CreatedAtUtc" desc
    limit 1;
end;
$$;

grant execute on function public.staff_get_gma_customer_prefill(text, text, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select p.proname::text as function_name, pg_get_function_identity_arguments(p.oid) as args
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'staff_get_gma_customer_prefill';
