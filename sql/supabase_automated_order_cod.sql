-- Cash on delivery (COD) option on Conversations orders - per "can we do COD option on the order?".
--
-- Before: Confirm Order refused any order with no real payment unless a super user clicked it
-- (supabase_manual_payments_super_user_only.sql), so every COD order had to wait for a super user.
--
-- Now an unconfirmed order (PancakeSyncStatus 'Not Pushed') has a "Cash on delivery" switch on its
-- Conversations card:
--   - Anyone with Conversations access can turn it on or off; who and when are saved on the order.
--   - When someone who isn't a super user turns it on, a Telegram alert goes out, so it can't quietly be
--     used to get round the payment rule.
--   - admin_confirm_bot_order lets an order through when it has a real payment, OR is marked COD, OR a
--     super user clicks it.
--   - It can't be changed once the order is confirmed (it's on Online Orders by then).
--   - Turning it on stops the unpaid-order reminder and the 48-hour auto-cancel for that order.
--   - Online Orders shows a COD badge (New tab + confirmed orders: staff_list_online_order_cod) and the New tab's
--     order dialog has the same switch.
--   - Alice's create_order can save an order as COD when the customer asks for it (chatbot-engine.ts writes
--     IsCOD / CodSetBy directly) - so run this file BEFORE deploying the chatbot Edge Functions, or every bot
--     order would fail on the missing column.
--
-- Run AFTER supabase_manual_payments_super_user_only.sql (this redefines admin_confirm_bot_order with the
-- COD exception added). Safe to re-run. If supabase_manual_payments_super_user_only.sql or
-- supabase_xendit_auto_confirm.sql is ever re-run, run this one again afterwards.
-- Needs js/gmaConversations.js ?v=cod1.

alter table public."AutomatedOrders" add column if not exists "IsCOD" boolean not null default false;
alter table public."AutomatedOrders" add column if not exists "CodSetBy" varchar(100);
alter table public."AutomatedOrders" add column if not exists "CodSetAtUtc" timestamptz;

-- ---------------------------------------------------------------------------
-- COD flag for a list of orders (the Conversations card list doesn't return it, so it's fetched separately).

drop function if exists public.admin_list_automated_order_cod(text, text, text[]);

create or replace function public.admin_list_automated_order_cod(
  p_admin_username text,
  p_admin_password text,
  p_order_nos text[]
)
returns table(order_no text, is_cod boolean, cod_set_by text, cod_set_at_utc timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select o."OrderNo"::text, o."IsCOD", o."CodSetBy"::text, o."CodSetAtUtc"
      from public."AutomatedOrders" o
     where o."OrderNo" = any(coalesce(p_order_nos, array[]::text[]));
end;
$$;

grant execute on function public.admin_list_automated_order_cod(text, text, text[]) to anon;

-- ---------------------------------------------------------------------------
-- Turn COD on / off on an unconfirmed order.

drop function if exists public.admin_set_automated_order_cod(text, text, text, boolean);

create or replace function public.admin_set_automated_order_cod(
  p_admin_username text,
  p_admin_password text,
  p_order_no text,
  p_is_cod boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public."AutomatedOrders"%rowtype;
  v_on boolean := coalesce(p_is_cod, false);
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select * into v_order from public."AutomatedOrders" where "OrderNo" = trim(p_order_no) for update;
  if not found then
    raise exception 'Order % not found.', trim(p_order_no);
  end if;
  if coalesce(v_order."PancakeSyncStatus", '') <> 'Not Pushed' or v_order."Status" in ('Completed', 'Cancelled') then
    raise exception 'Order % is already confirmed or closed, so cash on delivery can''t be changed here.', v_order."OrderNo";
  end if;
  if v_order."IsCOD" = v_on then
    return;
  end if;

  update public."AutomatedOrders"
     set "IsCOD" = v_on,
         "CodSetBy" = p_admin_username,
         "CodSetAtUtc" = timezone('utc', now()),
         -- COD: no unpaid-order reminder / 48h auto-cancel (_xendit_unpaid_orders_tick, supabase_xendit_bot_pay_online.sql).
         "AwaitingOnlinePaymentSinceUtc" = case when v_on then null else "AwaitingOnlinePaymentSinceUtc" end,
         "UpdatedBy" = p_admin_username,
         "UpdatedAtUtc" = now()
   where "OrderNo" = v_order."OrderNo";

  if v_on and not public._is_active_super_user(p_admin_username) then
    perform public._telegram_send_message(format(
      E'💵 COD order\n%s marked order %s (%s) as cash on delivery - it can now be confirmed with no payment.\nTotal: PHP %s',
      p_admin_username, v_order."OrderNo", coalesce(v_order."CustomerName", '-'),
      to_char(coalesce(v_order."EstimatedTotal", 0), 'FM999,999,990.00')));
  end if;
end;
$$;

grant execute on function public.admin_set_automated_order_cod(text, text, text, boolean) to anon;

-- ---------------------------------------------------------------------------
-- Confirm Order: needs a real payment, a COD mark, or a super user.

create or replace function public.admin_confirm_bot_order(
  p_admin_username text,
  p_admin_password text,
  p_order_no text
)
returns table(online_order_id text, order_status text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if public._order_real_paid(p_order_no) <= 0
     and not coalesce((select o."IsCOD" from public."AutomatedOrders" o where o."OrderNo" = trim(p_order_no)), false)
     and not public._is_active_super_user(p_admin_username) then
    raise exception 'Order % has no payment yet, so it can''t be confirmed. Send the customer a Pay link - the order confirms itself once the down payment is paid. Cash on delivery: turn on "Cash on delivery" on the order first.', trim(p_order_no);
  end if;
  return query select c.online_order_id, c.order_status from public._confirm_bot_order(p_order_no, p_admin_username) c;
end;
$$;

grant execute on function public.admin_confirm_bot_order(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Online Orders list / card: which confirmed orders are COD (so the rider / dispatcher collects the
-- balance). Confirmed AO- orders link back by AutomatedOrders.PancakeReceiptNo = OnlineOrders.OrderID
-- (same join as staff_list_online_order_gma_pages). Only COD orders are returned.

drop function if exists public.staff_list_online_order_cod(text, text, text[]);

create or replace function public.staff_list_online_order_cod(
  p_admin_username text,
  p_admin_password text,
  p_order_ids text[]
)
returns table(order_id text, cod_set_by text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select distinct on (ao."PancakeReceiptNo")
           ao."PancakeReceiptNo"::text, ao."CodSetBy"::text
      from public."AutomatedOrders" ao
     where ao."PancakeReceiptNo" = any(coalesce(p_order_ids, '{}'))
       and ao."IsCOD"
     order by ao."PancakeReceiptNo", ao."CreatedAtUtc" desc;
end;
$$;

grant execute on function public.staff_list_online_order_cod(text, text, text[]) to anon;

notify pgrst, 'reload schema';

-- Check: confirm function should say 'COD-aware'.
select 'admin_confirm_bot_order' as function_name,
       case when position('IsCOD' in pg_get_functiondef('public.admin_confirm_bot_order(text, text, text)'::regprocedure)) > 0
            then 'COD-aware' else 'OLD VERSION - run this file again' end as state;
