-- "Send Back" for rework - per "a production manager can click a button reassign after production
-- done so it will go back to the maker has issue or if needed to rework".
--
-- The Production Manager (or a Super User) picks which finished part(s) of an order need rework and
-- gives a reason. Those parts' done marks (OnlineOrderProductionDone,
-- supabase_online_order_production_done.sql) are removed, so the order leaves the Production Done
-- tab and comes back onto that maker's My Assignments. The reason is logged here and shown to the
-- maker until they mark the part done again. Order status and Pancake are not touched.
--
-- New table only (no OnlineOrders DDL), so running this never locks OnlineOrders. Run AFTER
-- supabase_online_order_production_done.sql.

create table if not exists public."OnlineOrderProductionRework" (
  "Id" bigint generated always as identity primary key,
  "OrderID" text not null,
  "Role" text not null check ("Role" in ('tank', 'stand', 'dispatcher')),
  "Reason" text not null,
  "SentBackBy" text not null,
  "SentBackAtUtc" timestamptz not null default now(),
  "PrevDoneBy" text,
  "PrevDoneAtUtc" timestamptz
);

create index if not exists "IX_OnlineOrderProductionRework_Order" on public."OnlineOrderProductionRework" ("OrderID", "Role", "SentBackAtUtc" desc);

alter table public."OnlineOrderProductionRework" enable row level security;
revoke all on public."OnlineOrderProductionRework" from anon, authenticated;

-- ---------------------------------------------------------------------------
drop function if exists public.admin_send_back_online_order_production(text, text, text, text[], text);

create or replace function public.admin_send_back_online_order_production(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_roles text[],
  p_reason text
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_count int;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if not exists (
    select 1 from public."StaffUsers"
    where "Username" = p_admin_username and "IsActive"
      and ("SuperUser" or 'ProductionManager' = any("StaffRoles"))
  ) then
    return query select false, 'Only a Production Manager can send work back.'::text;
    return;
  end if;

  if v_reason is null then
    return query select false, 'Please give a reason so the maker knows what to fix.'::text;
    return;
  end if;

  if p_roles is null or cardinality(p_roles) = 0 then
    return query select false, 'Pick at least one part to send back.'::text;
    return;
  end if;

  select "Status" into v_status from public."OnlineOrders" where "OrderID" = p_order_id;
  if not found then
    return query select false, 'Order not found.'::text;
    return;
  end if;

  if lower(trim(coalesce(v_status, ''))) not in ('confirmed', 'submitted', 'printed', 'assigned') then
    return query select false, format('This order is already %s - it can''t be sent back from here.', v_status)::text;
    return;
  end if;

  with removed as (
    delete from public."OnlineOrderProductionDone"
    where "OrderID" = p_order_id and "Role" = any(p_roles)
    returning "Role", "DoneBy", "DoneAtUtc"
  ), logged as (
    insert into public."OnlineOrderProductionRework" ("OrderID", "Role", "Reason", "SentBackBy", "PrevDoneBy", "PrevDoneAtUtc")
    select p_order_id, r."Role", v_reason, p_admin_username, r."DoneBy", r."DoneAtUtc" from removed r
    returning 1
  )
  select count(*) into v_count from logged;

  if v_count = 0 then
    return query select false, 'None of those parts were marked done.'::text;
    return;
  end if;

  return query select true, format('Sent back %s part(s) for rework.', v_count)::text;
end;
$$;

grant execute on function public.admin_send_back_online_order_production(text, text, text, text[], text) to anon;

-- ---------------------------------------------------------------------------
-- Open rework notes for the orders on screen: the latest send-back per part, while that part
-- hasn't been marked done again since.
drop function if exists public.staff_get_online_order_rework(text, text, text[]);

create or replace function public.staff_get_online_order_rework(
  p_admin_username text,
  p_admin_password text,
  p_order_ids text[]
)
returns table(order_id text, role text, reason text, sent_back_by text, sent_back_by_name text, sent_back_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select distinct on (w."OrderID", w."Role")
      w."OrderID", w."Role", w."Reason",
      w."SentBackBy", coalesce(nullif(trim(s."DisplayName"), ''), w."SentBackBy")::text, w."SentBackAtUtc"
    from public."OnlineOrderProductionRework" w
    left join public."StaffUsers" s on s."Username" = w."SentBackBy"
    where w."OrderID" = any(p_order_ids)
      and not exists (
        select 1 from public."OnlineOrderProductionDone" d
        where d."OrderID" = w."OrderID" and d."Role" = w."Role" and d."DoneAtUtc" > w."SentBackAtUtc"
      )
    order by w."OrderID", w."Role", w."SentBackAtUtc" desc;
end;
$$;

grant execute on function public.staff_get_online_order_rework(text, text, text[]) to anon;
