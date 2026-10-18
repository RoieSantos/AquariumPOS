-- Dispatchers ship advance orders - per "if the order is advance order will it show on the dispatcher my
-- assignments" / "yes please i want that".
--
-- Same rule as online orders (supabase_online_orders_list_sort.sql / supabase_online_order_mark_shipped_any_dispatcher.sql):
-- any Dispatcher sees every To Ship advance order - only their own branch's (AdvanceOrders."Warehouse" =
-- StaffUsers."WarehouseName") when their account has one - and can Mark Shipped it. Ready to Ship,
-- Undo Stage, Assign etc. stay Super User / Production Manager only.
--   1. staff_list_dispatcher_advance_orders - the Dispatcher's To Ship advance orders, with their lines
--      (as jsonb, so the Dispatcher doesn't need advance-order view access for staff_list_advance_order_lines).
--   2. staff_set_advance_order_stage - re-created from supabase_delivery_stop_done_post.sql's version, plus:
--      a Dispatcher may set 'Shipped' on a To Ship order of their branch. Nothing else changes.
-- No balance guard (unlike online orders): an advance order's balance lives in the POS and is usually
-- collected on delivery, then paid in full at the POS. The card shows the balance so the Dispatcher knows.
-- The Facebook auto-post on Shipped is supabase_advance_order_ship_post.sql (run that too).
--
-- Run AFTER supabase_delivery_stop_done_post.sql. Safe to re-run. Do NOT re-run
-- supabase_delivery_stop_done_post.sql or supabase_advance_order_production.sql after this one (they
-- would put back the Super User / Production Manager-only stage function).
-- Needs js/onlineOrders.js ?v=advdispatch1.

-- ---------------------------------------------------------------------------
-- 1. My Assignments list for Dispatchers.
create or replace function public.staff_list_dispatcher_advance_orders(p_admin_username text, p_admin_password text)
returns table(
  transaction_no text, receipt_no text, customer_name text, order_description text,
  order_date date, warehouse text, balance numeric, to_ship_at timestamptz, lines jsonb
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_is_dispatcher boolean;
  v_branch text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  select coalesce('Dispatcher' = any(s."StaffRoles"), false), lower(nullif(trim(coalesce(s."WarehouseName", '')), ''))
    into v_is_dispatcher, v_branch
  from public."StaffUsers" s where s."Username" = p_admin_username and s."IsActive";
  if not coalesce(v_is_dispatcher, false) then
    return;
  end if;

  return query
    select a."TransactionNo"::text, a."ReceiptNo"::text, a."CustomerName"::text, a."Order_Description"::text,
           a."Date", a."Warehouse"::text, a."Balance", p."ToShipAtUtc",
           coalesce((
             select jsonb_agg(jsonb_build_object('description', l."Description", 'quantity', l."Quantity")
                              order by case when l."LineNo" ~ '^\d+$' then l."LineNo"::numeric end nulls last, l."LineNo")
             from public."AdvanceOrderLines" l
             where l."TransactionNo" = a."TransactionNo"
               and upper(coalesce(l."Type", '')) <> 'PAYMENT'
           ), '[]'::jsonb)
    from public."AdvanceOrderProduction" p
    join public."AdvanceOrders" a on a."TransactionNo" = p."TransactionNo"
    where public._advance_order_prod_status(p) = 'To Ship'
      and (v_branch is null or lower(trim(coalesce(a."Warehouse", ''))) = v_branch)
    order by p."ToShipAtUtc" nulls last, a."TransactionNo";
end;
$$;

grant execute on function public.staff_list_dispatcher_advance_orders(text, text) to anon;

-- ---------------------------------------------------------------------------
-- 2. Stage changes - a Dispatcher may now Mark Shipped (their branch, To Ship orders only).
create or replace function public.staff_set_advance_order_stage(
  p_admin_username text, p_admin_password text, p_no text, p_stage text
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_stage text := nullif(trim(coalesce(p_stage, '')), '');
  v_prod public."AdvanceOrderProduction";
  v_status text;
  v_is_dispatcher boolean;
  v_branch text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Only a Super User or Production Manager can change this.';
  end if;
  if not exists (select 1 from public."AdvanceOrders" where "TransactionNo" = p_no) then
    raise exception 'Advance order % not found.', p_no;
  end if;

  if not public._production_is_manager(p_admin_username) then
    select coalesce('Dispatcher' = any(s."StaffRoles"), false), lower(nullif(trim(coalesce(s."WarehouseName", '')), ''))
      into v_is_dispatcher, v_branch
    from public."StaffUsers" s where s."Username" = p_admin_username and s."IsActive";
    if not coalesce(v_is_dispatcher, false) then
      raise exception 'Only a Super User or Production Manager can change this.';
    end if;
    if v_stage is distinct from 'Shipped' then
      raise exception 'A Dispatcher can only mark an advance order Shipped.';
    end if;
    if v_branch is not null and not exists (
      select 1 from public."AdvanceOrders" a
      where a."TransactionNo" = p_no and lower(trim(coalesce(a."Warehouse", ''))) = v_branch
    ) then
      raise exception 'Advance order % belongs to another branch.', p_no;
    end if;
  end if;

  insert into public."AdvanceOrderProduction" ("TransactionNo") values (p_no) on conflict do nothing;
  select * into v_prod from public."AdvanceOrderProduction" where "TransactionNo" = p_no for update;
  v_status := public._advance_order_prod_status(v_prod);

  if v_stage = 'To Ship' then
    if v_status = 'Assigned' then
      raise exception 'Advance order % is still in production - every assigned part must be Production Done first.', p_no;
    end if;
    update public."AdvanceOrderProduction"
       set "ToShipAtUtc" = now(), "ToShipBy" = p_admin_username, "ShippedAtUtc" = null, "ShippedBy" = null,
           "DeliveredAtUtc" = null, "DeliveredBy" = null
     where "TransactionNo" = p_no;
  elsif v_stage = 'Shipped' then
    if v_status is distinct from 'To Ship' then
      raise exception 'Advance order % must be To Ship before it can be marked Shipped.', p_no;
    end if;
    update public."AdvanceOrderProduction" set "ShippedAtUtc" = now(), "ShippedBy" = p_admin_username where "TransactionNo" = p_no;
  elsif v_stage is null then
    if v_status = 'Delivered' then
      update public."AdvanceOrderProduction" set "DeliveredAtUtc" = null, "DeliveredBy" = null where "TransactionNo" = p_no;
    elsif v_status = 'Shipped' then
      update public."AdvanceOrderProduction" set "ShippedAtUtc" = null, "ShippedBy" = null where "TransactionNo" = p_no;
    else
      update public."AdvanceOrderProduction" set "ToShipAtUtc" = null, "ToShipBy" = null where "TransactionNo" = p_no;
    end if;
  else
    raise exception 'p_stage must be ''To Ship'', ''Shipped'' or null.';
  end if;

  update public."AdvanceOrderProduction" set "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
   where "TransactionNo" = p_no
  returning * into v_prod;
  return public._advance_order_prod_status(v_prod);
end;
$$;
grant execute on function public.staff_set_advance_order_stage(text, text, text, text) to anon;

notify pgrst, 'reload schema';

-- Result: To Ship advance orders per branch, and how many active Dispatchers will see them.
select coalesce(a."Warehouse", '(no branch)') as branch,
       count(*) as to_ship_advance_orders,
       (select count(*) from public."StaffUsers" s
         where s."IsActive" and 'Dispatcher' = any(s."StaffRoles")
           and (nullif(trim(coalesce(s."WarehouseName", '')), '') is null
                or lower(trim(s."WarehouseName")) = lower(trim(coalesce(a."Warehouse", ''))))) as dispatchers_who_see_them
from public."AdvanceOrderProduction" p
join public."AdvanceOrders" a on a."TransactionNo" = p."TransactionNo"
where public._advance_order_prod_status(p) = 'To Ship'
group by a."Warehouse"
order by 1;
