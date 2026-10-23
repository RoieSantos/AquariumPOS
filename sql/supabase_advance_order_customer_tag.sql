-- Customer tagging on POS advance orders too - per "is the customer tagging works on advance order as
-- well?" -> "yes". The advance-order POST now uses the same customer box as a regular sale (search by
-- mobile / name, tap the Messenger customer), so an advance order can be linked to the customer's chat
-- like a walk-in (OnlineOrders."WalkinPsid", supabase_gma_conversation_walkins.sql).
--
-- 1. public."AdvanceOrders" gets "CustomerMobile", "CustomerPsid", "CustomerAddress" (all optional - the
--    POS's advance-order sync upserts them from dbo.AdvanceOrderHeader's new columns of the same name).
-- 2. admin_list_gma_conversation_walkins also returns the customer's advance orders (ADV-<TransactionNo>,
--    production stage as status, Balance still to pay) plus a new "kind" column ('walkin' / 'advance'),
--    so Conversations' "Walk-in purchases" shows both. Older gmaConversations.js just ignores "kind".
--
-- Run BEFORE the new POS build goes on the store PCs (the POS only sends these columns once a cashier
-- tags a customer, but with this run first nothing can fail). Run AFTER supabase_gma_conversation_walkins.sql
-- and supabase_advance_order_production.sql. Safe to re-run.
-- Needs docs/js/gmaConversations.js ?v=advtag1.

-- Nullable, no default = metadata-only (no table rewrite). lock_timeout: if a long query holds the table,
-- give up after 10s (just run it again) instead of queueing every Advance Orders read behind this.
set lock_timeout = '10s';
alter table public."AdvanceOrders" add column if not exists "CustomerMobile" varchar(30);
alter table public."AdvanceOrders" add column if not exists "CustomerPsid" varchar(100);
alter table public."AdvanceOrders" add column if not exists "CustomerAddress" varchar(500);
reset lock_timeout;

create index if not exists "IX_AdvanceOrders_CustomerPsid"
  on public."AdvanceOrders" ("CustomerPsid") where "CustomerPsid" is not null;

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
  cashier text,
  kind text
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
    select x.order_id, x.order_date, x.order_time, x.branch, x.status, x.total, x.amount_paid, x.balance,
           x.items, x.line_count, x.cashier, x.kind
      from (
        select o."OrderID"::text as order_id,
               o."Date"::date as order_date,
               o."Time"::text as order_time,
               coalesce(w."Name", o."LocationID")::text as branch,
               o."Status"::text as status,
               coalesce(o."MoneyToCollect", 0)::numeric as total,
               coalesce(o."AmountPaid", 0)::numeric as amount_paid,
               coalesce(o."Balance", 0)::numeric as balance,
               (select string_agg(t.line, ', ' order by t.n)
                  from (select row_number() over (order by case when l."LineID" ~ '^\d+$' then l."LineID"::numeric end nulls last, l."LineID") as n,
                               rtrim(to_char(coalesce(l."Quantity", 1), 'FM999990.##'), '.') || 'x '
                                 || coalesce(nullif(trim(l."Description"), ''), l."product_display_id", l."ItemCode", 'item') as line
                          from public."OnlineOrderLines" l where l."OrderID" = o."OrderID") t
                 where t.n <= 5) as items,
               (select count(*) from public."OnlineOrderLines" l where l."OrderID" = o."OrderID") as line_count,
               o."CreatedBy"::text as cashier,
               'walkin'::text as kind,
               o."Time"::text as sort_time
          from public."OnlineOrders" o
          left join public."Warehouses" w on w."ID" = o."LocationID"
         where o."WalkinPsid" = trim(p_psid)

        union all

        -- Advance orders: lines are items + payment lines (Type 'PAYMENT' etc.), only items are listed.
        select ('ADV-' || a."TransactionNo")::text,
               a."Date"::date,
               to_char(public._advance_order_time(a."Time"), 'HH24:MI'),
               a."Warehouse"::text,
               ('Advance - ' || coalesce(public._advance_order_prod_status(p), 'New'))::text,
               coalesce(a."NetAmount", 0)::numeric,
               (coalesce(a."NetAmount", 0) - coalesce(a."Balance", 0))::numeric,
               coalesce(a."Balance", 0)::numeric,
               (select string_agg(t.line, ', ' order by t.n)
                  from (select row_number() over (order by case when l."LineNo" ~ '^\d+$' then l."LineNo"::numeric end nulls last, l."LineNo") as n,
                               rtrim(to_char(coalesce(l."Quantity", 1), 'FM999990.##'), '.') || 'x '
                                 || coalesce(nullif(trim(l."Description"), ''), l."No", 'item') as line
                          from public."AdvanceOrderLines" l
                         where l."TransactionNo" = a."TransactionNo" and coalesce(l."Type", '') not ilike '%payment%') t
                 where t.n <= 5),
               (select count(*) from public."AdvanceOrderLines" l
                 where l."TransactionNo" = a."TransactionNo" and coalesce(l."Type", '') not ilike '%payment%'),
               a."UserID"::text,
               'advance'::text,
               to_char(public._advance_order_time(a."Time"), 'HH24:MI:SS')
          from public."AdvanceOrders" a
          left join public."AdvanceOrderProduction" p on p."TransactionNo" = a."TransactionNo"
         where a."CustomerPsid" = trim(p_psid)
      ) x
     order by x.order_date desc nulls last, x.sort_time desc nulls last, x.order_id desc
     limit 50;
end;
$$;

grant execute on function public.admin_list_gma_conversation_walkins(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'column' as section, column_name::text as item, data_type::text as detail
  from information_schema.columns
 where table_schema = 'public' and table_name = 'AdvanceOrders'
   and column_name in ('CustomerMobile', 'CustomerPsid', 'CustomerAddress')
union all
select 'function', p.proname::text, pg_get_function_result(p.oid)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'admin_list_gma_conversation_walkins';
