-- Advance Orders <-> Transfer Orders - per "in an advance order the warehouse is GMA (which is not
-- production store) so they dont have stocks ... amaya has standard stocks for that order.. should we
-- create a transfer order link to that advance order?" -> yes (option A), build 1-4, button for both
-- the branch staff and the Production Manager.
--
-- The link is the transfer line's "Order ID" = 'ADV-<TransactionNo>' (supabase_transfer_request_cap.sql:
-- such a line skips the shelf cap and is capped at what the order still needs). This file adds:
--
--   1. staff_get_advance_order_transfers(p_no)     - the order's transfer lines (open + posted) for the
--      "Stock Transfers" section on the Advance Order card.
--   2. staff_get_advance_order_transfer_status(p_nos[]) - per order: a CALCULATED transfer stage
--      ('Transfer requested' / 'In transit' / 'Transfer received') + docs + quantities, for the list
--      badge, the card's Status and the Assign warning. Nothing stored - always matches the transfers.
--   3. Hold on receive: a serial received on a transfer line carrying an Order ID becomes RESERVED for
--      that order at the destination (BEFORE UPDATE trigger on ItemSerialTracking - the Transfer Orders
--      page sets IN_TRANSIT -> IN_STOCK when it receives, the trigger turns that into RESERVED instead).
--      Only for an order that's still open, only up to that line's Qty Received, and only when the unit
--      lands at the transfer's To Warehouse (a short "Return to sender" goes back IN_STOCK as before).
--      Ready to Ship then pre-fills those serials (reservations, supabase_serial_order_reservation.sql).
--   4. staff_get_advance_order_transfer_plan(p_no) + staff_create_advance_order_transfer(...) - the
--      "Request Stock Transfer" button: per line what's still short at the order's branch and which
--      warehouses have it; then creates a Requested transfer (From = the picked warehouse, To = the
--      order's branch) with the Order ID on every line. The request cap trigger still checks each line.
--      Who: Super User / Production Manager, or the order's own branch staff (Store Manager / Sales /
--      Conversations staff who can see the order). Makers alone can't.
--   5. staff_get_advance_order_fulfilment_flags(p_nos[]) - list flags on NEW orders: "Can be transferred"
--      (another warehouse has the missing stock) / "Needs assigning" (nobody has it - a maker builds it).
--
-- Run AFTER supabase_transfer_request_cap.sql (re-run it first - its ADV- check was fixed in the same
-- change), supabase_serial_order_reservation.sql and supabase_advance_order_to_follow.sql.
-- Needs js/onlineOrders.js + online-orders.html cache v=advtransfer3. Safe to re-run.

-- ============================================================================
-- Helpers
-- ============================================================================

-- Every transfer line (open and posted, not cancelled) linked to an advance order.
create or replace function public._advance_order_transfer_lines(p_no text)
returns table(doc_no text, posted boolean, status text, from_warehouse text, to_warehouse text,
              requested_date text, requested_by text, line_no text, item_no text, variant_id text,
              variant_name text, description text, qty_requested numeric, qty_shipped numeric,
              qty_received numeric, qty_returned numeric, qty_written_off numeric)
language sql
stable
security definer
set search_path = public
as $$
  select h."No."::text, false, h."Status"::text, h."From Warehouse"::text, h."To Warehouse"::text,
         h."Requested Date"::text, h."Requested By"::text, l."Line No."::text, l."Item No."::text,
         nullif(trim(coalesce(l."Variant ID", '')), '')::text, l."Variant Name"::text, l."Description"::text,
         coalesce(l."Qty To Transfer", 0), coalesce(l."Qty Shipped", 0), coalesce(l."Qty Received", 0),
         coalesce(l."Qty Returned", 0), coalesce(l."Qty Written Off", 0)
    from public."Transfer_Line" l
    join public."Transfer_Header" h on h."No." = l."Document No."
   where upper(trim(coalesce(l."Order ID", ''))) = 'ADV-' || upper(trim(p_no))
     and coalesce(h."Status", '') <> 'Cancelled'
  union all
  select h."No."::text, true, h."Status"::text, h."From Warehouse"::text, h."To Warehouse"::text,
         h."Requested Date"::text, h."Requested By"::text, l."Line No."::text, l."Item No."::text,
         nullif(trim(coalesce(l."Variant ID", '')), '')::text, l."Variant Name"::text, l."Description"::text,
         coalesce(l."Qty To Transfer", 0), coalesce(l."Qty Shipped", 0), coalesce(l."Qty Received", 0),
         coalesce(l."Qty Returned", 0), coalesce(l."Qty Written Off", 0)
    from public."Posted_Transfer_Line" l
    join public."Posted_Transfer_Header" h on h."No." = l."Document No."
   where upper(trim(coalesce(l."Order ID", ''))) = 'ADV-' || upper(trim(p_no));
$$;

revoke execute on function public._advance_order_transfer_lines(text) from public, anon, authenticated;

-- Can request a transfer for this advance order: Super User / Production Manager, or a viewer (Store
-- Manager / Sales / Conversations staff) who can see it - i.e. its own branch. Makers alone: no.
create or replace function public._advance_order_can_request_transfer(p_username text, p_no text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public._advance_order_can_view(p_username, p_no)
     and (public._production_is_manager(p_username) or public._advance_order_is_viewer(p_username));
$$;

revoke execute on function public._advance_order_can_request_transfer(text, text) from public, anon, authenticated;

-- Units of one item/variant at a warehouse: free serials (IN_STOCK) for a serial-tracked item, else the
-- Item Ledger balance. p_variant null = the item without a variant.
create or replace function public._advance_order_stock_at(p_item text, p_variant text, p_serial boolean, p_wh_id text)
returns numeric
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_name text;
  v_key record;
  v_n numeric;
begin
  if p_serial then
    select w."Name" into v_name from public."Warehouses" w where w."ID" = p_wh_id;
    select count(*) into v_n from public."ItemSerialTracking" s
     where s."Status" = 'IN_STOCK' and lower(trim(coalesce(s."Location", ''))) = lower(trim(coalesce(v_name, '')))
       and case when p_variant is not null then s."VariantCode" = p_variant
                else s."ItemCode" = p_item and nullif(trim(coalesce(s."VariantCode", '')), '') is null end;
    return coalesce(v_n, 0);
  end if;
  begin
    select k.item_code, k.variant_id into v_key from public._ile_resolve_stock_key(p_item, p_variant) k;
    return greatest(coalesce(public._ile_balance(v_key.item_code, v_key.variant_id, p_wh_id), 0), 0);
  exception when others then
    return 0;
  end;
end;
$$;

revoke execute on function public._advance_order_stock_at(text, text, boolean, text) from public, anon, authenticated;

-- ============================================================================
-- 1. The order's transfer lines (card section)
-- ============================================================================

drop function if exists public.staff_get_advance_order_transfers(text, text, text);

create or replace function public.staff_get_advance_order_transfers(
  p_admin_username text,
  p_admin_password text,
  p_no text
)
returns table(doc_no text, posted boolean, status text, from_warehouse text, to_warehouse text,
              requested_date text, requested_by text, line_no text, item_no text, variant_id text,
              variant_name text, description text, qty_requested numeric, qty_shipped numeric,
              qty_received numeric, qty_returned numeric, qty_written_off numeric)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._advance_order_can_view(p_admin_username, p_no) then
    raise exception 'Not authorized.';
  end if;
  return query
    select t.* from public._advance_order_transfer_lines(p_no) t
    order by t.posted, t.doc_no, t.line_no;
end;
$$;

grant execute on function public.staff_get_advance_order_transfers(text, text, text) to anon;

-- ============================================================================
-- 2. Calculated transfer stage per order (list badge, card Status, Assign warning)
-- ============================================================================

drop function if exists public.staff_get_advance_order_transfer_status(text, text, text[]);

-- stage: 'Transfer requested' = something not shipped yet; 'In transit' = all shipped, some not
-- received; 'Transfer received' = everything requested has arrived (or was settled). Orders with no
-- linked transfer aren't returned. can_request: this user may press Request Stock Transfer.
create or replace function public.staff_get_advance_order_transfer_status(
  p_admin_username text,
  p_admin_password text,
  p_nos text[]
)
returns table(transaction_no text, stage text, docs text, from_warehouses text,
              qty_requested numeric, qty_shipped numeric, qty_received numeric, open_docs int)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with nos as (
      select distinct trim(n) as no from unnest(coalesce(p_nos, array[]::text[])) n
      where nullif(trim(n), '') is not null
    ),
    lines as (
      select n.no, t.*
        from nos n
        cross join lateral public._advance_order_transfer_lines(n.no) t
       where public._advance_order_can_view(p_admin_username, n.no)
    ),
    agg as (
      select l.no,
             string_agg(distinct l.doc_no, ', ') as docs,
             string_agg(distinct l.from_warehouse, ', ') as froms,
             sum(l.qty_requested) as req,
             sum(l.qty_shipped) as shp,
             sum(l.qty_received) as rcv,
             count(distinct l.doc_no) filter (where not l.posted)::int as open_n,
             -- open lines with something not shipped yet / shipped but not received yet
             bool_or(not l.posted and l.qty_requested - l.qty_shipped > 0) as any_unshipped,
             bool_or(not l.posted and l.qty_shipped - l.qty_received - l.qty_returned - l.qty_written_off > 0) as any_in_transit
        from lines l
       group by l.no
    )
    select a.no, case when a.any_unshipped then 'Transfer requested'
                      when a.any_in_transit then 'In transit'
                      else 'Transfer received' end,
           a.docs, a.froms, a.req, a.shp, a.rcv, a.open_n
      from agg a
     order by a.no;
end;
$$;

grant execute on function public.staff_get_advance_order_transfer_status(text, text, text[]) to anon;

-- ============================================================================
-- 3. Hold the unit for the order when the transfer is received
-- ============================================================================

create or replace function public._serial_reserve_on_transfer_receipt()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_line record;
  v_held int;
begin
  if not (old."Status" = 'IN_TRANSIT' and new."Status" = 'IN_STOCK')
     or nullif(trim(coalesce(new."SourceDocumentNo", '')), '') is null then
    return new;
  end if;

  -- Order-linked lines of THIS transfer for this item/variant (same match the page uses to release the
  -- serials: ItemCode = Item No., VariantCode = Variant ID), landing at the transfer's To Warehouse.
  for v_line in
    select upper(trim(l."Order ID")) as link, sum(coalesce(l."Qty Received", 0)) as received
      from public."Transfer_Line" l
      join public."Transfer_Header" h on h."No." = l."Document No."
     where l."Document No." = new."SourceDocumentNo"
       and nullif(trim(coalesce(l."Order ID", '')), '') is not null
       and l."Item No." = new."ItemCode"
       and coalesce(nullif(trim(l."Variant ID"), ''), '') = coalesce(nullif(trim(new."VariantCode"), ''), '')
       and lower(trim(coalesce(h."To Warehouse", ''))) = lower(trim(coalesce(new."Location", '')))
     group by upper(trim(l."Order ID"))
     order by min(l."Line No.")
  loop
    continue when not public._serial_order_is_open(v_line.link);
    -- Units of this transfer already held for that order (earlier rows of the same receive included -
    -- a row-level BEFORE trigger sees the rows the statement already changed).
    select count(*) into v_held
      from public."ItemSerialTracking" s
     where s."Status" = 'RESERVED' and s."ReservedForOrderId" = v_line.link
       and s."SourceDocumentNo" = new."SourceDocumentNo"
       and s."ItemCode" = new."ItemCode"
       and coalesce(nullif(trim(s."VariantCode"), ''), '') = coalesce(nullif(trim(new."VariantCode"), ''), '')
       and s."RunningSerialNo" <> new."RunningSerialNo";
    if v_held < v_line.received then
      new."Status" := 'RESERVED';
      new."ReservedForOrderId" := v_line.link;
      new."ReservedAtUtc" := now();
      new."ReservedBy" := left(coalesce(new."UpdatedBy", 'transfer receipt') || ' (' || new."SourceDocumentNo" || ')', 100);
      return new;
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists "TR_ItemSerialTracking_ReserveOnTransferReceipt" on public."ItemSerialTracking";
create trigger "TR_ItemSerialTracking_ReserveOnTransferReceipt"
  before update of "Status" on public."ItemSerialTracking"
  for each row execute function public._serial_reserve_on_transfer_receipt();

-- ============================================================================
-- 4. Request Stock Transfer: what's short, then create the transfer
-- ============================================================================

drop function if exists public.staff_get_advance_order_transfer_plan(text, text, text);
drop function if exists public._advance_order_transfer_plan_rows(text);

-- (internal - the button's plan and the list's flags) One row per item/variant on the order (sets, stickers and CUSTOM- builds left out - makers do those):
--   needed         = qty on the order
--   tagged         = serials already SOLD to the order
--   held           = serials RESERVED for the order (e.g. received on an earlier transfer)
--   on_the_way     = open order-linked transfer qty not received / settled yet
--   in_stock_here  = free stock at the order's branch (could be used without a transfer)
--   short          = needed - tagged - held - on_the_way - in_stock_here (never below 0)
--   sources        = [{warehouse_id, warehouse, is_production, available}] other active warehouses with stock
create or replace function public._advance_order_transfer_plan_rows(p_no text)
returns table(order_warehouse text, order_warehouse_id text, item_code text,
              variant_id text, variant_name text, description text, needs_serial boolean,
              needed numeric, tagged numeric, held numeric, on_the_way numeric, in_stock_here numeric,
              short numeric, sources jsonb)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_wh_name text;
  v_wh_id text;
  v_link text := 'ADV-' || trim(coalesce(p_no, ''));
begin
  select nullif(trim(a."Warehouse"), '') into v_wh_name from public."AdvanceOrders" a where a."TransactionNo" = p_no;
  select w."ID" into v_wh_id from public."Warehouses" w where lower(trim(w."Name")) = lower(v_wh_name) limit 1;

  return query
    with li as (
      select x.item_code as code, x.variation_id as variant, bool_or(x.needs_serial) as is_serial,
             sum(x.quantity)::numeric as qty, min(x.description) as descr
        from public._advance_order_line_items(p_no) x
       where x.item_code is not null
         and x.reason not like 'no - SET%' and x.reason not like 'no - custom sticker%'
         and left(upper(x.item_code), 7) not in ('CUSTOM-', 'CUSTOM_')
       group by x.item_code, x.variation_id
    ),
    counted as (
      select li.*,
             (select count(*) from public._advance_order_serials(p_no) s
               where s."Status" = 'SOLD' and s."ItemCode" = li.code
                 and coalesce(nullif(trim(s."VariantCode"), ''), '') = coalesce(li.variant, ''))::numeric as n_tagged,
             (select count(*) from public."ItemSerialTracking" s
               where s."Status" = 'RESERVED' and s."ReservedForOrderId" = v_link
                 and case when li.variant is not null then s."VariantCode" = li.variant
                          else s."ItemCode" = li.code and nullif(trim(coalesce(s."VariantCode", '')), '') is null end)::numeric as n_held,
             (select coalesce(sum(greatest(0, t.qty_requested - t.qty_received - t.qty_returned - t.qty_written_off)), 0)
                from public._advance_order_transfer_lines(p_no) t
               where not t.posted
                 and case when li.variant is not null then t.variant_id = li.variant
                          else t.item_no = li.code and t.variant_id is null end) as n_way,
             case when v_wh_id is null then 0 else public._advance_order_stock_at(li.code, li.variant, li.is_serial, v_wh_id) end as n_here
        from li
    )
    select v_wh_name, v_wh_id::text,
           c.code::text, c.variant::text,
           (select nullif(trim(v."VariantName"), '') from public."Variants" v where v."VariationId" = c.variant)::text,
           c.descr::text, c.is_serial, c.qty, c.n_tagged, c.n_held, c.n_way, c.n_here,
           greatest(0, c.qty - c.n_tagged - c.n_held - c.n_way - c.n_here),
           coalesce((
             select jsonb_agg(jsonb_build_object('warehouse_id', s.id, 'warehouse', s.name,
                                                 'is_production', s.prod, 'available', s.avail)
                              order by s.prod desc, s.avail desc, s.name)
               from (
                 select w."ID"::text as id, w."Name"::text as name, coalesce(w."IsProductionWarehouse", false) as prod,
                        public._advance_order_stock_at(c.code, c.variant, c.is_serial, w."ID"::text) as avail
                   from public."Warehouses" w
                  where coalesce(w."IsActive", true) and w."ID"::text is distinct from v_wh_id::text
               ) s
              where s.avail > 0
           ), '[]'::jsonb)
      from counted c
     order by c.code, c.variant;
end;
$$;

revoke execute on function public._advance_order_transfer_plan_rows(text) from public, anon, authenticated;

create or replace function public.staff_get_advance_order_transfer_plan(
  p_admin_username text,
  p_admin_password text,
  p_no text
)
returns table(order_warehouse text, order_warehouse_id text, can_request boolean, item_code text,
              variant_id text, variant_name text, description text, needs_serial boolean,
              needed numeric, tagged numeric, held numeric, on_the_way numeric, in_stock_here numeric,
              short numeric, sources jsonb)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._advance_order_can_view(p_admin_username, p_no) then
    raise exception 'Not authorized.';
  end if;
  return query
    select r.order_warehouse, r.order_warehouse_id,
           public._advance_order_can_request_transfer(p_admin_username, p_no) and r.order_warehouse_id is not null,
           r.item_code, r.variant_id, r.variant_name, r.description, r.needs_serial, r.needed, r.tagged,
           r.held, r.on_the_way, r.in_stock_here, r.short, r.sources
      from public._advance_order_transfer_plan_rows(p_no) r;
end;
$$;

grant execute on function public.staff_get_advance_order_transfer_plan(text, text, text) to anon;

-- ============================================================================
-- 5. List flags: "Can be transferred" / "Needs assigning"
-- ============================================================================

drop function if exists public.staff_get_advance_order_fulfilment_flags(text, text, text[]);

-- Per NEW order (not assigned / shipped yet - the production stage takes over from there), from the
-- same plan as the button:
--   short_units        = stock units not at the branch and not on the way / held
--   transferable_units = of those, how many another warehouse can send (best single warehouse per line)
--   maker_units        = the rest - no warehouse has them, a maker has to build them
--   transfer_from      = the warehouse(s) that would send (production first, then most stock)
-- Custom lines (CUSTOM- builds, needs_tank / needs_stand) are left to the page - it already has those
-- flags on the list row. Orders with nothing short aren't returned.
create or replace function public.staff_get_advance_order_fulfilment_flags(
  p_admin_username text,
  p_admin_password text,
  p_nos text[]
)
returns table(transaction_no text, short_units numeric, transferable_units numeric, maker_units numeric,
              transfer_from text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with nos as (
      select distinct a."TransactionNo"::text as no
        from public."AdvanceOrders" a
        left join public."AdvanceOrderProduction" p on p."TransactionNo" = a."TransactionNo"
       where a."TransactionNo" = any(coalesce(p_nos, array[]::text[]))
         and coalesce(public._advance_order_prod_status(p), 'New') = 'New'
         and public._advance_order_can_view(p_admin_username, a."TransactionNo")
    ),
    lines as (
      select n.no, r.short,
             least(r.short, coalesce((select max((s->>'available')::numeric) from jsonb_array_elements(r.sources) s), 0)) as can_send,
             (select s->>'warehouse' from jsonb_array_elements(r.sources) s
               order by (s->>'is_production')::boolean desc, (s->>'available')::numeric desc limit 1) as best_from
        from nos n
        cross join lateral public._advance_order_transfer_plan_rows(n.no) r
       where r.short > 0
    )
    select l.no, sum(l.short), sum(l.can_send), sum(l.short - l.can_send),
           string_agg(distinct l.best_from, ', ') filter (where l.can_send > 0)
      from lines l
     group by l.no
     order by l.no;
end;
$$;

grant execute on function public.staff_get_advance_order_fulfilment_flags(text, text, text[]) to anon;

drop function if exists public.staff_create_advance_order_transfer(text, text, text, text, jsonb);

-- p_lines: [{"item_code": "...", "variant_id": "..." | null, "qty": 1}]. Creates a Requested transfer
-- From p_from_warehouse_id To the order's branch, every line carrying Order ID 'ADV-<no>'. The request
-- cap trigger checks each line against the order (refuses the whole request if one is over).
-- Returns the new transfer's No.
create or replace function public.staff_create_advance_order_transfer(
  p_admin_username text,
  p_admin_password text,
  p_no text,
  p_from_warehouse_id text,
  p_lines jsonb
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order record;
  v_to record;
  v_from record;
  v_doc text;
  v_legacy_prefix text;
  v_legacy_max int;
  v_by text;
  v_line record;
  v_line_no int := 0;
  v_variant_name text;
  v_descr text;
  v_link text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._advance_order_can_request_transfer(p_admin_username, p_no) then
    raise exception 'Not authorized to request a transfer for this order.';
  end if;

  select a."TransactionNo", nullif(trim(a."Warehouse"), '') as wh, a."CustomerName", a."ReceiptNo"
    into v_order from public."AdvanceOrders" a where a."TransactionNo" = p_no;
  if not found then
    raise exception 'Advance order % was not found.', p_no;
  end if;
  v_link := 'ADV-' || v_order."TransactionNo";
  if not public._serial_order_is_open(v_link) then
    raise exception 'Advance order % is already shipped.', p_no;
  end if;

  select w."ID"::text as id, w."Name"::text as name into v_to
    from public."Warehouses" w where lower(trim(w."Name")) = lower(coalesce(v_order.wh, '')) limit 1;
  if v_to.id is null then
    raise exception 'Advance order % has no branch warehouse (Warehouse "%") - it can''t receive a transfer.', p_no, coalesce(v_order.wh, '');
  end if;

  select w."ID"::text as id, w."Name"::text as name, coalesce(w."IsProductionWarehouse", false) as prod into v_from
    from public."Warehouses" w where w."ID"::text = p_from_warehouse_id;
  if v_from.id is null then
    raise exception 'Pick the warehouse to send from.';
  end if;
  if v_from.id = v_to.id then
    raise exception 'From and To are the same warehouse (%).', v_to.name;
  end if;

  if jsonb_typeof(coalesce(p_lines, '[]'::jsonb)) <> 'array'
     or not exists (select 1 from jsonb_array_elements(p_lines) e where coalesce(nullif(e->>'qty', '')::numeric, 0) > 0) then
    raise exception 'Enter a quantity on at least one line.';
  end if;

  select coalesce(nullif(trim(u."DisplayName"), ''), u."Username") into v_by
    from public."StaffUsers" u where u."Username" = p_admin_username;

  -- Same numbering as the Transfer Orders page (staff_next_transfer_no), scoped to the To Warehouse.
  v_legacy_prefix := 'TR-' || v_to.name;
  select coalesce(max(substring(h."No." from length(v_legacy_prefix) + 1)::int), 0) into v_legacy_max
    from public."Transfer_Header" h
   where h."No." like v_legacy_prefix || '%'
     and substring(h."No." from length(v_legacy_prefix) + 1) ~ '^[0-9]+$';
  v_doc := public._next_no_series_number('TRANSFER-ORDER', v_to.name, v_legacy_max);

  insert into public."Transfer_Header" (
    "No.", "Description", "Status", "Requested Date", "From Warehouse ID", "From Warehouse",
    "To Warehouse ID", "To Warehouse", "Use Production Category", "Requested By",
    "Is Locked", "Locked At", "Locked By")
  values (
    v_doc,
    left('For advance order ' || v_order."TransactionNo"
         || coalesce(' (receipt ' || nullif(trim(v_order."ReceiptNo"), '') || ')', '')
         || coalesce(' - ' || nullif(trim(v_order."CustomerName"), ''), ''), 100),
    'Requested', (now() at time zone 'Asia/Manila')::date, v_from.id, v_from.name,
    v_to.id, v_to.name, v_from.prod, v_by,
    true, now(), v_by);

  for v_line in
    select trim(e->>'item_code') as item, nullif(trim(coalesce(e->>'variant_id', '')), '') as variant,
           coalesce(nullif(e->>'qty', '')::numeric, 0) as qty
      from jsonb_array_elements(p_lines) e
     where nullif(trim(coalesce(e->>'item_code', '')), '') is not null
       and coalesce(nullif(e->>'qty', '')::numeric, 0) > 0
  loop
    v_line_no := v_line_no + 10000;
    select nullif(trim(v."VariantName"), '') into v_variant_name from public."Variants" v where v."VariationId" = v_line.variant;
    select coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), '')) into v_descr
      from public."Items" i where i."Code" = v_line.item;
    -- The request cap trigger (TR_Transfer_Line_RequestCap) refuses an over-the-order line -> the
    -- whole request rolls back with its message.
    insert into public."Transfer_Line" (
      "Document No.", "Line No.", "Item No.", "Variant ID", "Variant Name", "Description", "Qty To Transfer", "Order ID")
    values (v_doc, v_line_no, v_line.item, v_line.variant, v_variant_name, v_descr, v_line.qty, v_link);
  end loop;

  return v_doc;
end;
$$;

grant execute on function public.staff_create_advance_order_transfer(text, text, text, text, jsonb) to anon;

notify pgrst, 'reload schema';

-- Verification - one result: functions, trigger, and advance orders that already have linked transfers.
select 'function' as section, p.proname::text as item,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon ok' else 'internal' end as value
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in (
  'staff_get_advance_order_transfers', 'staff_get_advance_order_transfer_status',
  'staff_get_advance_order_transfer_plan', 'staff_create_advance_order_transfer',
  'staff_get_advance_order_fulfilment_flags', '_advance_order_transfer_plan_rows',
  '_serial_reserve_on_transfer_receipt', '_tr_order_cap')
union all
select 'trigger', tgname::text, case when tgenabled <> 'D' then 'enabled' else 'DISABLED' end
from pg_trigger where tgrelid = 'public."ItemSerialTracking"'::regclass and tgname = 'TR_ItemSerialTracking_ReserveOnTransferReceipt'
union all
select 'linked transfer', l."Order ID"::text, string_agg(distinct l."Document No.", ', ')
from public."Transfer_Line" l where upper(coalesce(l."Order ID", '')) like 'ADV-%'
group by l."Order ID";
