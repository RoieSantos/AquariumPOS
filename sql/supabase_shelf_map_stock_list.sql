-- Shelf Map > "Stock List" view, per "create me a list version on what are the items that is low on
-- stocks / show the vendor and i want a super user to be able to do Purchase order from there ...
-- i want to see how many has been sold".
--
-- One row per item linked on ANY shelf at the location (an item drawn in several spots/shelves is
-- one row - same totals the map's spots show):
--
--   min_qty           sum of the spots' Min. Shelf Count (ShelfMapCells.CurrentQty) at the location
--   on_hand           Item Ledger balance at the location, all variants together (= map's "Stock on hand")
--   pending_to        open transfer orders INTO the location: Qty To Transfer - Qty Received
--                     (= map's "Pending TO"), with the TO numbers; split for the Suggested qty into
--                     pending_in_transit (shipped, not received) and pending_unshipped_other (not
--                     shipped yet, from a location other than "Warehouse"). Unshipped qty FROM the
--                     Warehouse isn't extra stock - it's still inside warehouse_on_hand, and when the
--                     Warehouse has none the TO can't ship, so it must not hide a buy.
--   warehouse_on_hand Item Ledger balance at the "Warehouse" location (null when the list IS the Warehouse)
--   on_po             open Purchase Orders, any location: Quantity - QtyReceived, with the PO numbers
--   sold_here         net units sold at the location in the last p_days days (ledger 'Sale' entries,
--                     returns net off), sold_all = the same over every location
--   last_sold / last_purchased   latest ledger Sale at the location / latest Purchase anywhere
--   vendor_*          primary vendor (Items."VendorCode"); vendors = every vendor that can supply it
--                     (primary + Item Vendor catalog) with that vendor's cost
--   variant_*         variant count; the single variant's id/name when there is exactly one (the PO
--                     line uses it, same rule as the Replenishment TO)
--
-- Read-only for every staff user. Creating the Purchase Orders reuses staff_create_purchase_order
-- (the page only offers it to super users).
-- Run AFTER supabase_shelf_maps.sql, supabase_item_ledger_entries.sql, supabase_item_vendors_catalog.sql.
-- Safe to re-run.

-- Dropped first: the return columns change between versions (create or replace can't do that).
drop function if exists public.staff_get_shelf_stock_list(text, text, text, int);

create or replace function public.staff_get_shelf_stock_list(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text,
  p_days int default 30
)
returns table(
  item_code text, item_name text, shelves text, spots int, min_qty numeric,
  on_hand numeric, pending_to numeric, pending_in_transit numeric, pending_unshipped_other numeric, pending_docs text, warehouse_on_hand numeric,
  on_po numeric, open_pos text, sold_here numeric, sold_all numeric, last_sold date, last_purchased date,
  vendor_code text, vendor_name text, unit_cost numeric, vendors jsonb,
  variant_count int, variant_id text, variant_name text
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_days int := least(greatest(coalesce(p_days, 30), 1), 730);
  v_since date := (now() at time zone 'Asia/Manila')::date - v_days;
  v_main_wh text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if nullif(trim(coalesce(p_warehouse_id, '')), '') is null then
    return;
  end if;

  select w."ID" into v_main_wh from public."Warehouses" w where lower(trim(w."Name")) = 'warehouse' limit 1;

  return query
  with cells as (
    select c."ItemCode" as item,
           sum(coalesce(c."CurrentQty", 0)) as min_qty,
           count(*)::int as spots,
           string_agg(distinct s."Name", ', ') as shelves
      from public."ShelfMapCells" c
      join public."ShelfMaps" s on s."Id" = c."ShelfId"
     where s."WarehouseId" = p_warehouse_id and nullif(trim(coalesce(c."ItemCode", '')), '') is not null
     group by c."ItemCode"
  ),
  -- Every code a transfer / PO line can carry for the item: the item itself and its variants' own item rows.
  keys as (
    select c.item, c.item as k from cells c
    union
    select c.item, v."ItemCode" from cells c
      join public."Variants" v on v."MainItemCode" = c.item
     where nullif(trim(coalesce(v."ItemCode", '')), '') is not null
  ),
  ledger as (
    select e."ItemCode" as item,
           coalesce(sum(e."Quantity") filter (where e."WarehouseId" = p_warehouse_id), 0) as on_hand,
           sum(e."Quantity") filter (where e."WarehouseId" = v_main_wh) as wh_on_hand,
           coalesce(sum(-e."Quantity") filter (where e."EntryType" = 'Sale' and e."WarehouseId" = p_warehouse_id and e."PostingDate" > v_since), 0) as sold_here,
           coalesce(sum(-e."Quantity") filter (where e."EntryType" = 'Sale' and e."PostingDate" > v_since), 0) as sold_all,
           max(e."PostingDate") filter (where e."EntryType" = 'Sale' and e."Quantity" < 0 and e."WarehouseId" = p_warehouse_id) as last_sold,
           max(e."PostingDate") filter (where e."EntryType" = 'Purchase' and e."Quantity" > 0) as last_purchased
      from public."ItemLedgerEntries" e
     where e."ItemCode" in (select item from cells)
     group by e."ItemCode"
  ),
  tos as (
    select k.item,
           sum(greatest(0, coalesce(l."Qty To Transfer", 0) - coalesce(l."Qty Received", 0))) as qty,
           sum(greatest(0, coalesce(l."Qty Shipped", 0) - coalesce(l."Qty Received", 0))) as in_transit,
           sum(greatest(0, coalesce(l."Qty To Transfer", 0) - greatest(coalesce(l."Qty Shipped", 0), coalesce(l."Qty Received", 0))))
             filter (where h."From Warehouse ID" is distinct from v_main_wh) as unshipped_other,
           string_agg(distinct l."Document No.", ', ')
             filter (where coalesce(l."Qty To Transfer", 0) - coalesce(l."Qty Received", 0) > 0) as docs
      from public."Transfer_Line" l
      join public."Transfer_Header" h on h."No." = l."Document No."
      join keys k on k.k = l."Item No."
     where h."To Warehouse ID" = p_warehouse_id
       and coalesce(h."Status", '') not in ('Received', 'Cancelled')
     group by k.item
  ),
  pos as (
    select k.item,
           sum(greatest(0, coalesce(pl."Quantity", 0) - coalesce(pl."QtyReceived", 0))) as qty,
           string_agg(distinct pl."PONo", ', ')
             filter (where coalesce(pl."Quantity", 0) - coalesce(pl."QtyReceived", 0) > 0) as docs
      from public."PurchaseOrderLines" pl
      join keys k on k.k = pl."ItemCode"
     group by k.item
  ),
  vars as (
    select c.item, count(v."VariationId")::int as n,
           min(v."VariationId") as vid,
           min(coalesce(nullif(trim(v."SKU"), ''), nullif(trim(v."VariantName"), ''), v."VariationId")) as vname
      from cells c
      join public."Variants" v on v."MainItemCode" = c.item or v."ItemCode" = c.item
     group by c.item
  )
  select c.item::text,
         coalesce(nullif(trim(i."Name"), ''), c.item)::text,
         c.shelves::text,
         c.spots,
         c.min_qty,
         coalesce(lg.on_hand, 0),
         coalesce(t.qty, 0),
         coalesce(t.in_transit, 0),
         coalesce(t.unshipped_other, 0),
         t.docs::text,
         case when v_main_wh is null or v_main_wh = p_warehouse_id then null else coalesce(lg.wh_on_hand, 0) end,
         coalesce(p.qty, 0),
         p.docs::text,
         coalesce(lg.sold_here, 0),
         coalesce(lg.sold_all, 0),
         lg.last_sold,
         lg.last_purchased,
         nullif(trim(coalesce(i."VendorCode", '')), '')::text,
         pv."Name"::text,
         coalesce((select iv."Cost" from public."ItemVendors" iv where iv."ItemCode" = c.item and iv."VendorCode" = i."VendorCode"), i."Cost"),
         coalesce((
           select jsonb_agg(jsonb_build_object('code', x.code, 'name', x.name, 'cost', x.cost, 'primary', x.prim)
                            order by x.prim desc, x.name)
             from (
               select iv."VendorCode"::text as code, coalesce(v."Name", iv."VendorCode")::text as name,
                      coalesce(iv."Cost", i."Cost") as cost, (iv."VendorCode" = i."VendorCode") as prim
                 from public."ItemVendors" iv
                 left join public."Vendors" v on v."VendorCode" = iv."VendorCode"
                where iv."ItemCode" = c.item
               union all
               select pv."VendorCode"::text, coalesce(pv."Name", pv."VendorCode")::text, i."Cost", true
                where pv."VendorCode" is not null
                  and not exists (select 1 from public."ItemVendors" iv2 where iv2."ItemCode" = c.item and iv2."VendorCode" = pv."VendorCode")
             ) x
         ), '[]'::jsonb),
         coalesce(vr.n, 0),
         case when vr.n = 1 then vr.vid::text end,
         case when vr.n = 1 then vr.vname::text end
    from cells c
    left join public."Items" i on i."Code" = c.item
    left join public."Vendors" pv on pv."VendorCode" = i."VendorCode"
    left join ledger lg on lg.item = c.item
    left join tos t on t.item = c.item
    left join pos p on p.item = c.item
    left join vars vr on vr.item = c.item
   order by coalesce(nullif(trim(i."Name"), ''), c.item);
end;
$$;

grant execute on function public.staff_get_shelf_stock_list(text, text, text, int) to anon;

notify pgrst, 'reload schema';

-- Verification - one result: the grant, and per shelf location how many items are listed / low.
select 'function' as section, 'staff_get_shelf_stock_list' as item,
       case when has_function_privilege('anon', 'public.staff_get_shelf_stock_list(text, text, text, int)', 'EXECUTE') then 'ok' else 'anon cannot execute' end as value
union all
select 'location', coalesce(w."Name", s."WarehouseId"),
       count(distinct c."ItemCode") || ' linked item(s) on ' || count(distinct s."Id") || ' shelf/shelves'
from public."ShelfMaps" s
join public."ShelfMapCells" c on c."ShelfId" = s."Id" and c."ItemCode" is not null
left join public."Warehouses" w on w."ID" = s."WarehouseId"
where s."WarehouseId" is not null
group by coalesce(w."Name", s."WarehouseId");
