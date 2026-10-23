-- Vic / Alice orders keep the bot as "Created By" even when staff edit them before confirming - per
-- "can you double check why this is not increasing i see there are number of created order by the bot (vic)".
--
-- Cause: admin_confirm_bot_order fills OnlineOrders."CreatedBy" from AutomatedOrders."UpdatedBy", and
-- every staff edit of the draft (items, delivery fee, wholesale, status) overwrites "UpdatedBy" with
-- the staff username - so an edited Vic order was saved as created by that staff member and the
-- dashboard's Vic (created) card never counted it.
--
-- Fix (no Edge Function / admin_confirm_bot_order change needed):
--   1. AutomatedOrders."CreatedBy" - stamped once on insert from "UpdatedBy" (the bot name for a bot
--      order, the staff username for a GMA "+ New Order"), never touched by edits.
--   2. Backfill it for existing orders: bot-made = "UpdatedBy" still Vic / Alice / AI Bot, or Vic's own
--      chat reply carried the order number within 15 minutes of the order being made.
--   3. OnlineOrders insert trigger: an order confirmed from an AutomatedOrders row takes that row's
--      "CreatedBy" - so it's right no matter who edited / confirmed it.
--   4. Backfill OnlineOrders already confirmed under a staff name.
--
-- Unconfirmed drafts still don't count on the card (they aren't sales until staff confirm them).
-- Diagnostic: supabase_check_vic_created_orders.sql. Safe to re-run.

-- 1. Column + insert stamp
alter table public."AutomatedOrders" add column if not exists "CreatedBy" varchar(100);

create or replace function public._automated_orders_stamp_created_by()
returns trigger
language plpgsql
as $$
begin
  new."CreatedBy" := coalesce(nullif(trim(new."CreatedBy"), ''), new."UpdatedBy");
  return new;
end;
$$;

drop trigger if exists trg_automated_orders_stamp_created_by on public."AutomatedOrders";
create trigger trg_automated_orders_stamp_created_by
  before insert on public."AutomatedOrders"
  for each row execute function public._automated_orders_stamp_created_by();

-- 2. Backfill AutomatedOrders."CreatedBy" (bot-made first, then everything else from "UpdatedBy")
update public."AutomatedOrders" ao
   set "CreatedBy" = case when ao."GmaPsid" like 'web:%' then 'Alice' else 'Vic' end
 where coalesce(ao."CreatedBy", '') not in ('Vic', 'Alice')
   and (ao."UpdatedBy" in ('Vic', 'Alice', 'AI Bot')
        or exists (select 1 from public."ChatbotMessages" m
                    where m."Psid" = ao."GmaPsid"
                      and m."Role" = 'assistant'
                      and m."CreatedAtUtc" between ao."CreatedAtUtc" and ao."CreatedAtUtc" + interval '15 minutes'
                      and m."Content" ilike '%' || ao."OrderNo" || '%'));

update public."AutomatedOrders"
   set "CreatedBy" = "UpdatedBy"
 where "CreatedBy" is null;

-- 3. Confirmed order inherits the draft's creator
create or replace function public._online_orders_created_by_from_draft()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_created_by text;
begin
  select nullif(trim(ao."CreatedBy"), '') into v_created_by
    from public."AutomatedOrders" ao
   where ao."OrderNo" = new."OrderID";
  if v_created_by is not null then
    new."CreatedBy" := v_created_by;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_online_orders_created_by_from_draft on public."OnlineOrders";
create trigger trg_online_orders_created_by_from_draft
  before insert on public."OnlineOrders"
  for each row execute function public._online_orders_created_by_from_draft();

-- 4. Backfill confirmed bot orders that were credited to staff
update public."OnlineOrders" oo
   set "CreatedBy" = ao."CreatedBy"
  from public."AutomatedOrders" ao
 where ao."OrderNo" = oo."OrderID"
   and ao."CreatedBy" in ('Vic', 'Alice')
   and coalesce(oo."CreatedBy", '') <> ao."CreatedBy";

-- Check: Vic / Alice orders per month now (what the card will show for Monthly / Prev. Month).
select coalesce(o."CreatedBy", '') as created_by,
       to_char(o."Date", 'YYYY-MM') as month,
       count(*) as orders,
       sum(o."MoneyToCollect") as sales
  from public."OnlineOrders" o
 where o."CreatedBy" in ('Vic', 'Alice')
   and o."ReceivedAtShop" is not true
   and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
   and o."Date" >= date_trunc('month', now() at time zone 'Asia/Manila')::date - interval '1 month'
 group by 1, 2
 order by 2 desc, 1;
