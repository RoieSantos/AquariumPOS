-- Customers page for "Conversations Access" staff - per "can you make them available to
-- conversations access?".
--
-- The Customers page (docs/customers.html, js/customers.js) and its Customer Card were Super User
-- only. Its 6 RPCs each re-check is_admin_authorized() (SuperUser only). This swaps that one check
-- for is_conversations_authorized() (SuperUser OR ConversationsStaff - see
-- supabase_gma_conversations_staff_rpc_access.sql), same as every GMA Conversations RPC.
--
-- Instead of copying each function body again, this reads each function's LIVE definition
-- (pg_get_functiondef) and re-creates it with only that call swapped - so nothing else about the
-- functions changes, and grants stay as they are (CREATE OR REPLACE). Raises if a function is
-- missing or has no is_admin_authorized call to swap (unless it was already swapped).
--
-- NOTE: re-running supabase_gma_customers_enriched.sql / supabase_gma_customer_card.sql /
-- supabase_gma_customer_contacts.sql afterwards puts the Super User-only check back - re-run this
-- file after any of them.
--
-- Run AFTER supabase_gma_conversations_staff_rpc_access.sql and supabase_gma_customer_contacts.sql.
-- Safe to re-run. Needs docs/js/customers.js ?v=6.

do $$
declare
  v_name text;
  v_def text;
begin
  foreach v_name in array array[
    'admin_list_gma_customers',
    'admin_list_gma_customer_orders',
    'admin_update_gma_customer',
    'admin_list_gma_customer_contacts',
    'admin_save_gma_customer_contact',
    'admin_delete_gma_customer_contact'
  ] loop
    select pg_get_functiondef(p.oid)
      into v_def
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = v_name;

    if v_def is null then
      raise exception 'Function public.% not found - run its SQL file first.', v_name;
    end if;

    if position('is_admin_authorized(' in v_def) > 0 then
      execute replace(v_def, 'public.is_admin_authorized(', 'public.is_conversations_authorized(');
    elsif position('is_conversations_authorized(' in v_def) = 0 then
      raise exception 'public.% has no authorization check to swap - check it by hand.', v_name;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Verification - one result: every row should say is_conversations_authorized.
select p.proname as function_name,
       case
         when pg_get_functiondef(p.oid) like '%is_conversations_authorized(%' then 'is_conversations_authorized'
         when pg_get_functiondef(p.oid) like '%is_admin_authorized(%' then 'is_admin_authorized (STILL SUPER USER ONLY)'
         else 'no check found'
       end as auth_check
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in (
      'admin_list_gma_customers', 'admin_list_gma_customer_orders', 'admin_update_gma_customer',
      'admin_list_gma_customer_contacts', 'admin_save_gma_customer_contact', 'admin_delete_gma_customer_contact'
    )
  order by p.proname;
