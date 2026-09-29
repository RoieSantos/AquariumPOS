-- Production Orders: Undo Production Done = REWORK - per "in the production orders if undo has been hit
-- .. logged it as rework to the maker".
--
-- Same idea as Online Orders' Send Back (supabase_online_order_production_rework.sql):
--   * Undoing a part's Production Done logs a rework entry: which order / part, the maker it goes back
--     to, when they had marked it done, who undid it, when, and why.
--   * The part's done mark is cleared (as before), so the order is back on the maker's My Assignments,
--     now with a Rework badge and the reason.
--   * When the maker marks that part Production Done again, the open rework entry is closed as Fixed
--     (FixedAtUtc / FixedBy).
--
--   ProductionOrderRework                        - the log.
--   staff_set_production_order_part_done(..., p_reason) - replaces the 5-argument version; p_reason is
--                                                  optional (callers that don't pass it still work).
--   staff_list_production_order_rework(no)       - an order's rework entries, newest first (manager, or
--                                                  a maker on that order).
--
-- Run AFTER supabase_production_orders.sql. Safe to re-run.

create table if not exists public."ProductionOrderRework" (
  "Id" bigint generated always as identity primary key,
  "ProdOrderNo" varchar(20) not null references public."ProductionOrders" ("No") on delete cascade,
  "Part" varchar(10) not null check ("Part" in ('tank', 'stand')),
  "Maker" varchar(100),
  "Reason" text not null,
  "SentBackBy" varchar(100) not null,
  "SentBackAtUtc" timestamptz not null default now(),
  "PrevDoneAtUtc" timestamptz,
  "FixedAtUtc" timestamptz,
  "FixedBy" varchar(100)
);

create index if not exists "IX_ProductionOrderRework_Order"
  on public."ProductionOrderRework" ("ProdOrderNo", "Part", "SentBackAtUtc" desc);

alter table public."ProductionOrderRework" enable row level security;
revoke all on public."ProductionOrderRework" from anon, authenticated;

-- ---------------------------------------------------------------------------
drop function if exists public.staff_set_production_order_part_done(text, text, text, text, boolean);
drop function if exists public.staff_set_production_order_part_done(text, text, text, text, boolean, text);

-- p_part 'tank' | 'stand'. The maker assigned to that part, or a Production Manager.
create or replace function public.staff_set_production_order_part_done(
  p_admin_username text,
  p_admin_password text,
  p_no text,
  p_part text,
  p_done boolean,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."ProductionOrders";
  v_part text := lower(trim(coalesce(p_part, '')));
  v_maker text;
  v_done_at timestamptz;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_part not in ('tank', 'stand') then
    raise exception 'p_part must be ''tank'' or ''stand''.';
  end if;

  select * into v_order from public."ProductionOrders" where "No" = p_no for update;
  if not found then
    raise exception 'Production order % not found.', p_no;
  end if;
  if v_order."Status" <> 'Released' then
    raise exception 'Production order % is %, not Released.', p_no, v_order."Status";
  end if;

  v_maker := case v_part when 'tank' then v_order."TankMaker" else v_order."StandMaker" end;
  v_done_at := case v_part when 'tank' then v_order."TankDoneAtUtc" else v_order."StandDoneAtUtc" end;

  if not public._production_is_manager(p_admin_username) and p_admin_username is distinct from v_maker then
    raise exception 'You are not the % Maker on %.', initcap(v_part), p_no;
  end if;

  if v_part = 'tank' then
    update public."ProductionOrders" set "TankDoneAtUtc" = case when p_done then now() end, "UpdatedAtUtc" = now() where "No" = p_no;
  else
    update public."ProductionOrders" set "StandDoneAtUtc" = case when p_done then now() end, "UpdatedAtUtc" = now() where "No" = p_no;
  end if;

  if not p_done and v_done_at is not null then
    -- Undo of a real Production Done -> rework for the maker.
    insert into public."ProductionOrderRework" ("ProdOrderNo", "Part", "Maker", "Reason", "SentBackBy", "PrevDoneAtUtc")
    values (p_no, v_part, v_maker,
            coalesce(nullif(trim(coalesce(p_reason, '')), ''), 'Production Done was undone'),
            p_admin_username, v_done_at);
  elsif p_done then
    -- Marked done again -> any open rework on this part is fixed.
    update public."ProductionOrderRework"
      set "FixedAtUtc" = now(), "FixedBy" = p_admin_username
      where "ProdOrderNo" = p_no and "Part" = v_part and "FixedAtUtc" is null;
  end if;
end;
$$;

grant execute on function public.staff_set_production_order_part_done(text, text, text, text, boolean, text) to anon;

-- ---------------------------------------------------------------------------
drop function if exists public.staff_list_production_order_rework(text, text, text);

create or replace function public.staff_list_production_order_rework(
  p_admin_username text,
  p_admin_password text,
  p_no text
)
returns table(id bigint, part text, maker text, maker_name text, reason text, sent_back_by text,
              sent_back_by_name text, sent_back_at timestamptz, prev_done_at timestamptz,
              fixed_at timestamptz, fixed_by text, fixed_by_name text)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if not public._production_is_manager(p_admin_username) and not exists (
    select 1 from public."ProductionOrders" o
    where o."No" = p_no and (o."TankMaker" = p_admin_username or o."StandMaker" = p_admin_username)
  ) then
    raise exception 'You are not assigned to production order %.', p_no;
  end if;

  return query
    select r."Id", r."Part"::text, r."Maker"::text,
           coalesce(nullif(trim(m."DisplayName"), ''), r."Maker")::text,
           r."Reason", r."SentBackBy"::text,
           coalesce(nullif(trim(s."DisplayName"), ''), r."SentBackBy")::text,
           r."SentBackAtUtc", r."PrevDoneAtUtc", r."FixedAtUtc", r."FixedBy"::text,
           coalesce(nullif(trim(f."DisplayName"), ''), r."FixedBy")::text
    from public."ProductionOrderRework" r
    left join public."StaffUsers" m on m."Username" = r."Maker"
    left join public."StaffUsers" s on s."Username" = r."SentBackBy"
    left join public."StaffUsers" f on f."Username" = r."FixedBy"
    where r."ProdOrderNo" = p_no
    order by r."SentBackAtUtc" desc;
end;
$$;

grant execute on function public.staff_list_production_order_rework(text, text, text) to anon;

notify pgrst, 'reload schema';
