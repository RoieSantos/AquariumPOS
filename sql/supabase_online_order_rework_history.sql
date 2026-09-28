-- Send-back (rework) count and history per order - per "can we log how many send back actions
-- happen for the order".
--
-- Every Send Back is already logged in public."OnlineOrderProductionRework"
-- (supabase_online_order_production_rework.sql), one row per part sent back. These read it:
--   - staff_get_online_order_rework_counts: how many send-back ACTIONS per order (parts sent back
--     together in one click count once), for the badge on the Online Orders list.
--   - staff_get_online_order_rework_history: every send-back of one order, for the order card's
--     Rework History section - part, reason, who sent it back, who had finished it, and when it was
--     fixed (the next Production Done on that part), if it has been.
--
-- Read-only; run AFTER supabase_online_order_production_rework.sql.

drop function if exists public.staff_get_online_order_rework_counts(text, text, text[]);

create or replace function public.staff_get_online_order_rework_counts(
  p_admin_username text,
  p_admin_password text,
  p_order_ids text[]
)
returns table(order_id text, send_back_count int, parts_sent_back int)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- One Send Back click inserts one row per ticked part, all with the same SentBackAtUtc (now() is
  -- fixed for the transaction), so distinct timestamps = distinct actions.
  return query
    select w."OrderID", count(distinct w."SentBackAtUtc")::int, count(*)::int
    from public."OnlineOrderProductionRework" w
    where w."OrderID" = any(p_order_ids)
    group by w."OrderID";
end;
$$;

grant execute on function public.staff_get_online_order_rework_counts(text, text, text[]) to anon;

-- ---------------------------------------------------------------------------
drop function if exists public.staff_get_online_order_rework_history(text, text, text);

create or replace function public.staff_get_online_order_rework_history(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(
  role text,
  reason text,
  sent_back_by_name text,
  sent_back_at timestamptz,
  prev_done_by_name text,
  prev_done_at timestamptz,
  fixed_by_name text,
  fixed_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- "Fixed" = the part was marked done again after this send-back and before the next one. Only the
  -- current done mark is kept, so this is known for the latest send-back of each part; an older one
  -- that was later sent back again counts as fixed at the time of that next send-back's PrevDoneAtUtc.
  return query
    select
      w."Role",
      w."Reason",
      coalesce(nullif(trim(sb."DisplayName"), ''), w."SentBackBy")::text,
      w."SentBackAtUtc",
      coalesce(nullif(trim(pd."DisplayName"), ''), w."PrevDoneBy")::text,
      w."PrevDoneAtUtc",
      coalesce(nullif(trim(fx."DisplayName"), ''), f.done_by)::text,
      f.done_at
    from public."OnlineOrderProductionRework" w
    left join public."StaffUsers" sb on sb."Username" = w."SentBackBy"
    left join public."StaffUsers" pd on pd."Username" = w."PrevDoneBy"
    left join lateral (
      select x.done_by, x.done_at from (
        -- the next send-back of the same part: its PrevDone is the fix of this one
        select n."PrevDoneBy" as done_by, n."PrevDoneAtUtc" as done_at
        from public."OnlineOrderProductionRework" n
        where n."OrderID" = w."OrderID" and n."Role" = w."Role" and n."SentBackAtUtc" > w."SentBackAtUtc"
          and n."PrevDoneAtUtc" > w."SentBackAtUtc"
        union all
        -- or the current done mark
        select d."DoneBy", d."DoneAtUtc"
        from public."OnlineOrderProductionDone" d
        where d."OrderID" = w."OrderID" and d."Role" = w."Role" and d."DoneAtUtc" > w."SentBackAtUtc"
      ) x
      order by x.done_at
      limit 1
    ) f on true
    left join public."StaffUsers" fx on fx."Username" = f.done_by
    where w."OrderID" = p_order_id
    order by w."SentBackAtUtc" desc, w."Role";
end;
$$;

grant execute on function public.staff_get_online_order_rework_history(text, text, text) to anon;
