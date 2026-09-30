-- Transfer Orders <-> Production Orders link - per "once the production order is created can you tag it
-- to the Transfer order as a new field".
--
-- Transfer Orders' "Create Production Order" (js/transferOrders.js) can create two orders for one transfer
-- (Aquarium + Stand), so the link lives on the production order, same as Online Orders'
-- ProductionOrders.SourceOnlineOrderId (supabase_online_order_stock_ship.sql):
--   ProductionOrders.SourceTransferNo                 - which Transfer Order (Transfer_Header."No.") a build is for.
--   staff_link_production_order_to_transfer(...)      - sets that link (Production Manager / Super User).
--   staff_list_transfer_production_orders(...)        - the production orders linked to a transfer, for the
--                                                       Transfer Order card's "Production Orders" field.
--
-- Run AFTER supabase_production_orders.sql. Safe to re-run.

alter table public."ProductionOrders" add column if not exists "SourceTransferNo" varchar(50);
create index if not exists "IX_ProductionOrders_SourceTransferNo" on public."ProductionOrders" ("SourceTransferNo");

-- ---------------------------------------------------------------------------
drop function if exists public.staff_link_production_order_to_transfer(text, text, text, text);

create or replace function public.staff_link_production_order_to_transfer(
  p_admin_username text,
  p_admin_password text,
  p_no text,
  p_transfer_no text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if not public._production_is_manager(p_admin_username) then
    raise exception 'Only a Production Manager can link a production order.';
  end if;
  update public."ProductionOrders"
    set "SourceTransferNo" = nullif(trim(coalesce(p_transfer_no, '')), ''), "UpdatedAtUtc" = now()
    where "No" = p_no;
  if not found then
    raise exception 'Production order % not found.', p_no;
  end if;
end;
$$;

grant execute on function public.staff_link_production_order_to_transfer(text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
drop function if exists public.staff_list_transfer_production_orders(text, text, text);

create or replace function public.staff_list_transfer_production_orders(
  p_admin_username text,
  p_admin_password text,
  p_transfer_no text
)
returns table(no text, status text, description text, qty numeric, qty_output numeric, created_at timestamptz)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select o."No"::text, o."Status"::text, o."Description"::text,
           coalesce(sum(l."Quantity"), 0), coalesce(sum(l."QtyOutput"), 0), o."CreatedAtUtc"
    from public."ProductionOrders" o
    left join public."ProductionOrderLines" l on l."ProdOrderNo" = o."No"
    where o."SourceTransferNo" = p_transfer_no
    group by o."No", o."Status", o."Description", o."CreatedAtUtc"
    order by o."CreatedAtUtc";
end;
$$;

grant execute on function public.staff_list_transfer_production_orders(text, text, text) to anon;

-- Existing orders created from a Transfer Order before this file: their description says so
-- ("For Transfer Order TR-... (Stand)") - tag them too.
update public."ProductionOrders"
set "SourceTransferNo" = substring("Description" from '^For Transfer Order ([^ ]+)')
where "SourceTransferNo" is null
  and "Description" ~ '^For Transfer Order [^ ]+';

notify pgrst, 'reload schema';
