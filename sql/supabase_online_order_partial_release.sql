-- Online Orders: partial release by the Dispatcher - per "in the dispatcher.. can they do partial release
-- only.. meaning some items will be release and the some items is pending to release" / "please build it
-- i want it to control in the portal".
--
-- Mark Shipped used to be whole-order only. Now the Dispatcher (or Production Manager / Super User) picks
-- which lines - and how many of each - leave in this batch. Every batch is logged per line in
-- OnlineOrderLineReleases. Controlled in the portal only:
--   * a partial batch changes nothing in Pancake - the order stays To Ship there and in the portal, and
--     stays on the Dispatcher's To Ship list with a "Released x/y" badge until the rest goes out;
--   * the batch that releases the LAST remaining unit does what Mark Shipped did: Pancake status 2,
--     portal Status 'Shipped', AssignedDispatcher + OnlineOrderShipments recorded.
-- Stock / Item Ledger are unaffected (the sale already posted once the order was confirmed; serials were
-- claimed at Ready to Ship).
--
--   staff_get_online_order_release_lines(order_id)        - each line: ordered / released / remaining
--   admin_release_online_order_lines(order_id, lines, note) - release a batch (last batch = Shipped)
--   staff_list_online_order_release_summary(order_ids[])  - per order: released / ordered units, batches
--   staff_get_online_order_release_history(order_id)      - every released line, newest batch first
--
-- Run AFTER supabase_online_order_mark_shipped_any_dispatcher.sql. Safe to re-run. New table + functions
-- only - no OnlineOrders lock.

create table if not exists public."OnlineOrderLineReleases" (
  "Id" bigint generated always as identity primary key,
  "OrderID" text not null,
  "BatchNo" int not null,
  "LineID" text not null,
  "Quantity" numeric(18, 2) not null check ("Quantity" > 0),
  "ReleasedBy" text not null,
  "ReleasedAtUtc" timestamptz not null default now(),
  "AsDispatcher" boolean not null,
  "Note" text
);

create index if not exists "IX_OnlineOrderLineReleases_Order" on public."OnlineOrderLineReleases" ("OrderID", "LineID");

alter table public."OnlineOrderLineReleases" enable row level security;
revoke all on public."OnlineOrderLineReleases" from anon, authenticated;

-- Lines that count for release: every line with a quantity (a missing quantity counts as 1).
create or replace function public._online_order_release_lines(p_order_id text)
returns table(line_id text, item_code text, description text, ordered_qty numeric, released_qty numeric)
language sql
stable
security definer
set search_path = public
as $$
  select
    l."LineID"::text,
    l."ItemCode"::text,
    coalesce(nullif(trim(l."Description"), ''), l."ItemCode")::text,
    coalesce(l."Quantity", 1),
    coalesce((select sum(r."Quantity") from public."OnlineOrderLineReleases" r
              where r."OrderID" = l."OrderID" and r."LineID" = l."LineID"), 0)
  from public."OnlineOrderLines" l
  where l."OrderID" = p_order_id
    and coalesce(l."Quantity", 1) > 0
  order by l."LineID";
$$;

revoke all on function public._online_order_release_lines(text) from anon, authenticated;

drop function if exists public.staff_get_online_order_release_lines(text, text, text);

create or replace function public.staff_get_online_order_release_lines(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(line_id text, item_code text, description text, ordered_qty numeric, released_qty numeric, remaining_qty numeric)
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
    select x.line_id, x.item_code, x.description, x.ordered_qty, x.released_qty,
           greatest(x.ordered_qty - x.released_qty, 0)
    from public._online_order_release_lines(p_order_id) x;
end;
$$;

grant execute on function public.staff_get_online_order_release_lines(text, text, text) to anon;

-- p_lines: [{"line_id": "...", "quantity": 2}, ...]. An order with no lines on file can only be released
-- whole (empty p_lines) - same as the old Mark Shipped.
drop function if exists public.admin_release_online_order_lines(text, text, text, jsonb, text);

create or replace function public.admin_release_online_order_lines(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_lines jsonb,
  p_note text default null
)
returns table(success boolean, message text, fully_shipped boolean, batch_no int)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '45000'
as $$
declare
  v_status text;
  v_is_manager boolean;
  v_is_dispatcher boolean;
  v_batch int;
  v_line_count int;
  v_bad text;
  v_remaining numeric;
  v_picked int;
  v_req jsonb;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text, false, null::int;
    return;
  end if;

  select coalesce(s."SuperUser", false) or 'ProductionManager' = any(s."StaffRoles"),
         'Dispatcher' = any(s."StaffRoles")
    into v_is_manager, v_is_dispatcher
  from public."StaffUsers" s where s."Username" = p_admin_username and s."IsActive";

  if not coalesce(v_is_manager, false) and not coalesce(v_is_dispatcher, false) then
    return query select false, 'Only a Dispatcher or a Production Manager can release orders.'::text, false, null::int;
    return;
  end if;

  -- Row lock: two dispatchers releasing the same order at once can't both take the last units.
  select "Status" into v_status from public."OnlineOrders" where "OrderID" = p_order_id for update;
  if not found then
    return query select false, 'Order not found.'::text, false, null::int;
    return;
  end if;

  if lower(trim(coalesce(v_status, ''))) not in ('to ship', 'packing', 'packed') then
    return query select false, format('Only a To Ship order can be released - this one is %s.', v_status)::text, false, null::int;
    return;
  end if;

  select count(*) into v_line_count from public._online_order_release_lines(p_order_id);

  -- Requested lines, one row per line id (quantities summed), zero quantities dropped.
  select coalesce(jsonb_agg(jsonb_build_object('line_id', q.line_id, 'quantity', q.quantity)), '[]'::jsonb), count(*)
    into v_req, v_picked
  from (
    select e->>'line_id' as line_id, sum(coalesce(nullif(e->>'quantity', '')::numeric, 0)) as quantity
    from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
    group by e->>'line_id'
  ) q
  where q.quantity <> 0;

  if v_line_count > 0 then
    if v_picked = 0 then
      return query select false, 'Pick at least one item to release.'::text, false, null::int;
      return;
    end if;

    select string_agg(coalesce(x.description, q.line_id), ', ') into v_bad
    from jsonb_to_recordset(v_req) as q(line_id text, quantity numeric)
    left join public._online_order_release_lines(p_order_id) x on x.line_id = q.line_id
    where x.line_id is null or q.quantity < 0 or q.quantity > x.ordered_qty - x.released_qty;
    if v_bad is not null then
      return query select false, format('More than what is left to release (someone may have released it already): %s', v_bad)::text, false, null::int;
      return;
    end if;

    select coalesce(max("BatchNo"), 0) + 1 into v_batch
    from public."OnlineOrderLineReleases" where "OrderID" = p_order_id;

    insert into public."OnlineOrderLineReleases" ("OrderID", "BatchNo", "LineID", "Quantity", "ReleasedBy", "AsDispatcher", "Note")
    select p_order_id, v_batch, q.line_id, q.quantity, p_admin_username, coalesce(v_is_dispatcher, false), nullif(trim(p_note), '')
    from jsonb_to_recordset(v_req) as q(line_id text, quantity numeric);
  end if;

  select coalesce(sum(greatest(x.ordered_qty - x.released_qty, 0)), 0) into v_remaining
  from public._online_order_release_lines(p_order_id) x;

  if v_remaining > 0 then
    -- Partial: portal only. Recorded as the order's dispatcher so it shows who is handling it.
    if coalesce(v_is_dispatcher, false) then
      update public."OnlineOrders" set "AssignedDispatcher" = p_admin_username where "OrderID" = p_order_id;
    end if;
    return query select true, format('Batch %s released. %s still to release - the order stays To Ship.',
      v_batch, rtrim(to_char(v_remaining, 'FM999999990.##'), '.'))::text, false, v_batch;
    return;
  end if;

  -- Everything is out: same as Mark Shipped. Raises (and rolls the batch back) if Pancake rejects it.
  perform public._pancake_patch_online_order_status(p_order_id, jsonb_build_object('status', '2'));

  update public."OnlineOrders"
  set "Status" = 'Shipped',
      "AssignedDispatcher" = case when coalesce(v_is_dispatcher, false) then p_admin_username else "AssignedDispatcher" end
  where "OrderID" = p_order_id;

  insert into public."OnlineOrderShipments" ("OrderID", "ShippedBy", "AsDispatcher")
  values (p_order_id, p_admin_username, coalesce(v_is_dispatcher, false))
  on conflict ("OrderID") do update
    set "ShippedBy" = excluded."ShippedBy", "ShippedAtUtc" = now(), "AsDispatcher" = excluded."AsDispatcher";

  return query select true,
    (case when coalesce(v_batch, 1) > 1 then format('Last batch (%s) released - marked as shipped.', v_batch) else 'Marked as shipped.' end)::text,
    true, v_batch;
end;
$$;

grant execute on function public.admin_release_online_order_lines(text, text, text, jsonb, text) to anon;

-- Only orders that have at least one release.
drop function if exists public.staff_list_online_order_release_summary(text, text, text[]);

create or replace function public.staff_list_online_order_release_summary(
  p_admin_username text,
  p_admin_password text,
  p_order_ids text[]
)
returns table(order_id text, ordered_qty numeric, released_qty numeric, batches int, last_released_at timestamptz)
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
    select r."OrderID"::text,
           (select coalesce(sum(coalesce(l."Quantity", 1)), 0) from public."OnlineOrderLines" l
            where l."OrderID" = r."OrderID" and coalesce(l."Quantity", 1) > 0),
           sum(r."Quantity"),
           max(r."BatchNo"),
           max(r."ReleasedAtUtc")
    from public."OnlineOrderLineReleases" r
    where r."OrderID" = any(coalesce(p_order_ids, '{}'))
    group by r."OrderID";
end;
$$;

grant execute on function public.staff_list_online_order_release_summary(text, text, text[]) to anon;

drop function if exists public.staff_get_online_order_release_history(text, text, text);

create or replace function public.staff_get_online_order_release_history(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(batch_no int, line_id text, description text, quantity numeric, released_by text, released_by_name text, released_at timestamptz, note text)
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
    select r."BatchNo", r."LineID"::text,
           coalesce(nullif(trim(l."Description"), ''), l."ItemCode", r."LineID")::text,
           r."Quantity", r."ReleasedBy"::text,
           coalesce(nullif(trim(s."DisplayName"), ''), r."ReleasedBy")::text,
           r."ReleasedAtUtc", r."Note"
    from public."OnlineOrderLineReleases" r
    left join public."OnlineOrderLines" l on l."OrderID" = r."OrderID" and l."LineID" = r."LineID"
    left join public."StaffUsers" s on s."Username" = r."ReleasedBy"
    where r."OrderID" = p_order_id
    order by r."BatchNo" desc, r."Id";
end;
$$;

grant execute on function public.staff_get_online_order_release_history(text, text, text) to anon;

notify pgrst, 'reload schema';
