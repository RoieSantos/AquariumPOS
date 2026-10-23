-- Conversations: the customer's POS walk-ins next to the chat - per "is the walkin ordered customer will
-- tag the order into their conversations?" -> "yes".
--
-- A walk-in is tagged to a Messenger customer when the cashier picks them in the POS checkout's customer
-- box (OnlineOrders."WalkinPsid", supabase_pos_walkin_orders_direct.sql). The Conversations order panel
-- (admin_list_automated_orders_by_gma_conversation) only lists bot / Create Order orders and each card
-- has bot-order actions, so the walk-ins come from their own RPC and show read-only under "Walk-in
-- purchases" (docs/js/gmaConversations.js): order no., date, branch, status, total / paid / balance and
-- the first items. Cashier is shown too.
--
-- admin_list_gma_conversation_walkins - same staff check as every Conversations RPC
-- (is_conversations_authorized). Newest first, up to 50.
--
-- Run AFTER supabase_pos_walkin_orders_direct.sql (WalkinPsid). Safe to re-run.
-- Needs docs/js/gmaConversations.js ?v=walkins1.

drop function if exists public.admin_list_gma_conversation_walkins(text, text, text);

create or replace function public.admin_list_gma_conversation_walkins(
  p_admin_username text,
  p_admin_password text,
  p_psid text
)
returns table(
  order_id text,
  order_date date,
  order_time text,
  branch text,
  status text,
  total numeric,
  amount_paid numeric,
  balance numeric,
  items text,
  line_count bigint,
  cashier text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if coalesce(trim(p_psid), '') = '' then
    return;
  end if;

  return query
    select o."OrderID"::text,
           o."Date"::date,
           o."Time"::text,
           coalesce(w."Name", o."LocationID")::text,
           o."Status"::text,
           coalesce(o."MoneyToCollect", 0)::numeric,
           coalesce(o."AmountPaid", 0)::numeric,
           coalesce(o."Balance", 0)::numeric,
           (select string_agg(t.line, ', ' order by t.n)
              from (select row_number() over (order by case when l."LineID" ~ '^\d+$' then l."LineID"::numeric end nulls last, l."LineID") as n,
                           rtrim(to_char(coalesce(l."Quantity", 1), 'FM999990.##'), '.') || 'x '
                             || coalesce(nullif(trim(l."Description"), ''), l."product_display_id", l."ItemCode", 'item') as line
                      from public."OnlineOrderLines" l where l."OrderID" = o."OrderID") t
             where t.n <= 5),
           (select count(*) from public."OnlineOrderLines" l where l."OrderID" = o."OrderID"),
           o."CreatedBy"::text
      from public."OnlineOrders" o
      left join public."Warehouses" w on w."ID" = o."LocationID"
     where o."WalkinPsid" = trim(p_psid)
     order by o."Date" desc nulls last, o."Time" desc nulls last, o."OrderID" desc
     limit 50;
end;
$$;

grant execute on function public.admin_list_gma_conversation_walkins(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select p.proname::text as function_name, pg_get_function_identity_arguments(p.oid) as args
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'admin_list_gma_conversation_walkins';
