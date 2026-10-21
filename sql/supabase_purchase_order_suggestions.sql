-- Purchase Order SUGGESTIONS - per "can we implement auto purchase order? so when the items is moving
-- on our stores there will be a corresponding PO" -> decisions: the WAREHOUSE buys and then transfers
-- to the stores; a person reviews before anything is ordered; all categories except production;
-- manual - "when we do PO it will suggest" (no scheduled job, no auto-created POs).
--
-- New Purchase Order > pick Vendor + Warehouse > "Suggest Lines". This works out, per item/variant
-- the vendor supplies (primary vendor OR Item Vendor catalog), what the warehouse should order:
--
--   demand from    = the PO warehouse + every store it has sent transfers to (open or posted, not
--                    cancelled) - the warehouse buys for the stores it supplies
--   sold           = Item Ledger 'Sale' qty at those warehouses over the last p_sales_days days
--   avg / day      = sold / p_sales_days
--   lead days      = ItemVendors.LeadTimeDays for this vendor, else p_default_lead_days
--   target         = ceil(avg / day x (lead days + p_cover_days))   -- enough until the NEXT order lands
--   available      = warehouse on hand (ledger, never below 0)
--                  + still on open POs into this warehouse (Quantity - QtyReceived, any vendor)
--                  + inbound transfers shipped to it, not received yet
--                  - outbound transfers from it not shipped yet (already promised to stores)
--   suggested      = target - available, never below 0
--   store on hand  = the stores' own stock - shown for the reviewer only, NOT subtracted (it sits on
--                    their shelves; the shelf caps on Transfer Orders already manage store levels)
--
-- Left out: production categories (Categories.IsProductionCategory), categories excluded from
-- transfers (same as the PO item picker), inactive items. Only rows with sales in the period are
-- returned. Quantities are in BASE units - the page converts to the line's purchase unit.
--
-- Read-only: nothing is written. The page fills the New PO lines; Create Purchase Order is unchanged.
--
-- Run AFTER supabase_item_ledger_entries.sql, supabase_item_vendors_catalog.sql,
-- supabase_purchase_order_header_warehouse.sql and supabase_transfer_order_post_partial.sql.
-- Needs js/purchaseOrders.js + purchase-orders.html cache v=posuggest1. Safe to re-run.

drop function if exists public.staff_suggest_purchase_order_lines(text, text, text, text, int, int, int);

create or replace function public.staff_suggest_purchase_order_lines(
  p_admin_username text,
  p_admin_password text,
  p_vendor_code text,
  p_warehouse_id text,
  p_sales_days int default 30,
  p_cover_days int default 30,
  p_default_lead_days int default 7
)
returns table(item_code text, item_name text, description text, variant_id text, variant_name text,
              sku text, unit_cost numeric, lead_days int, sold_qty numeric, avg_daily numeric,
              wh_on_hand numeric, store_on_hand numeric, on_po numeric, inbound numeric,
              outbound numeric, target_qty numeric, suggested_qty numeric, demand_from text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_vendor text := nullif(trim(coalesce(p_vendor_code, '')), '');
  v_wh text := nullif(trim(coalesce(p_warehouse_id, '')), '');
  v_days int := least(greatest(coalesce(p_sales_days, 30), 1), 365);
  v_cover int := least(greatest(coalesce(p_cover_days, 30), 0), 365);
  v_lead int := least(greatest(coalesce(p_default_lead_days, 7), 0), 365);
  v_from date := (now() at time zone 'Asia/Manila')::date - least(greatest(coalesce(p_sales_days, 30), 1), 365);
  v_network text[];
  v_network_names text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_vendor is null then
    raise exception 'Select a Vendor first.';
  end if;
  if v_wh is null then
    raise exception 'Select the Warehouse this order is for first.';
  end if;

  -- The warehouse + the stores it supplies (anything it has ever sent a transfer to).
  select array_agg(distinct x.id) into v_network
    from (
      select v_wh as id
      union
      select h."To Warehouse ID"::text from public."Transfer_Header" h
       where h."From Warehouse ID"::text = v_wh and coalesce(h."Status", '') <> 'Cancelled'
      union
      select h."To Warehouse ID"::text from public."Posted_Transfer_Header" h
       where h."From Warehouse ID"::text = v_wh and coalesce(h."Status", '') <> 'Cancelled'
    ) x
    join public."Warehouses" w on w."ID"::text = x.id
   where x.id is not null and (x.id = v_wh or coalesce(w."IsActive", true));

  select string_agg(w."Name", ', ' order by (w."ID"::text <> v_wh), w."Name") into v_network_names
    from public."Warehouses" w where w."ID"::text = any(v_network);

  return query
    with vendor_items as (
      select i."Code" as code, i."Name" as name, nullif(trim(i."Description"), '') as descr,
             i."CategoryCode" as cat, i."Cost" as item_cost,
             iv."Cost" as vendor_cost, iv."LeadTimeDays" as vendor_lead
        from public."Items" i
        left join public."ItemVendors" iv on iv."ItemCode" = i."Code" and iv."VendorCode" = v_vendor
       where coalesce(i."IsActive", true)
         and (i."VendorCode" = v_vendor or iv."VendorCode" is not null)
    ),
    -- Stock keys, the same way the ledger keys them (_ile_resolve_stock_key): an item with 2+
    -- variants is kept per variant, anything else as the item alone.
    keys as (
      select vi.*, v."VariationId" as variant, v."VariantName" as vname, v."SKU" as vsku,
             coalesce(v."CategoryCode", vi.cat) as key_cat
        from vendor_items vi
        join public."Variants" v on v."ItemCode" = vi.code
       where (select count(*) from public."Variants" v2 where v2."ItemCode" = vi.code) >= 2
      union all
      select vi.*, null, null, null, vi.cat
        from vendor_items vi
       where (select count(*) from public."Variants" v2 where v2."ItemCode" = vi.code) < 2
    ),
    k as (
      select keys.* from keys
        left join public."Categories" c on c."Code" = keys.key_cat
       where not coalesce(c."IsProductionCategory", false)
         and not coalesce(c."ExcludeInTransferOrders", false)
    ),
    led as (
      select e."ItemCode" as code, nullif(trim(coalesce(e."VariantId", '')), '') as variant,
             e."WarehouseId" as wh,
             sum(e."Quantity") as bal,
             -sum(e."Quantity") filter (where e."EntryType" = 'Sale' and e."PostingDate" > v_from) as sold
        from public."ItemLedgerEntries" e
       where e."WarehouseId" = any(v_network)
         -- a variant's ledger rows carry its own item code (Variants.ItemCode), so this covers both
         and e."ItemCode" in (select vi.code from vendor_items vi)
       group by 1, 2, 3
    ),
    po as (
      select l."ItemCode" as code, nullif(trim(coalesce(l."VariantCode", '')), '') as variant,
             sum(greatest(0, l."Quantity" - coalesce(l."QtyReceived", 0))) as qty
        from public."PurchaseOrderLines" l
        join public."PurchaseOrders" h on h."PONo" = l."PONo"
       where coalesce(nullif(l."WarehouseId", ''), h."WarehouseId") = v_wh
       group by 1, 2
    ),
    tr as (
      select l."Item No." as code, nullif(trim(coalesce(l."Variant ID", '')), '') as variant,
             sum(case when h."From Warehouse ID"::text = v_wh
                      then greatest(0, coalesce(l."Qty To Transfer", 0) - coalesce(l."Qty Shipped", 0)) else 0 end) as out_qty,
             sum(case when h."To Warehouse ID"::text = v_wh
                      then greatest(0, coalesce(l."Qty Shipped", 0) - coalesce(l."Qty Received", 0)
                                       - coalesce(l."Qty Returned", 0) - coalesce(l."Qty Written Off", 0)) else 0 end) as in_qty
        from public."Transfer_Line" l
        join public."Transfer_Header" h on h."No." = l."Document No."
       where coalesce(h."Status", '') not in ('Received', 'Cancelled')
         and (h."From Warehouse ID"::text = v_wh or h."To Warehouse ID"::text = v_wh)
       group by 1, 2
    ),
    calc as (
      select k.code, k.name, k.descr, k.variant, k.vname, k.vsku,
             coalesce(k.vendor_cost, k.item_cost) as cost,
             coalesce(k.vendor_lead, v_lead) as lead,
             coalesce((select sum(greatest(0, coalesce(l.sold, 0))) from led l
                        where case when k.variant is not null then l.variant = k.variant
                                   else l.code = k.code and l.variant is null end), 0) as sold,
             greatest(0, coalesce((select sum(l.bal) from led l
                        where l.wh = v_wh
                          and case when k.variant is not null then l.variant = k.variant
                                   else l.code = k.code and l.variant is null end), 0)) as here,
             coalesce((select sum(greatest(0, l.bal)) from led l
                        where l.wh <> v_wh
                          and case when k.variant is not null then l.variant = k.variant
                                   else l.code = k.code and l.variant is null end), 0) as stores,
             coalesce((select sum(p.qty) from po p
                        where case when k.variant is not null then p.variant = k.variant
                                   else p.code = k.code end), 0) as on_po,
             coalesce((select sum(t.in_qty) from tr t
                        where case when k.variant is not null then t.variant = k.variant
                                   else t.code = k.code end), 0) as in_qty,
             coalesce((select sum(t.out_qty) from tr t
                        where case when k.variant is not null then t.variant = k.variant
                                   else t.code = k.code end), 0) as out_qty
        from k
    ),
    sized as (
      select c.*, round(c.sold / v_days, 2) as per_day,
             ceil(c.sold / v_days * (c.lead + v_cover)) as target
        from calc c
       where c.sold > 0
    )
    select s.code::text, s.name::text, s.descr::text, s.variant::text, s.vname::text, s.vsku::text,
           s.cost, s.lead, s.sold, s.per_day, s.here, s.stores, s.on_po, s.in_qty, s.out_qty, s.target,
           greatest(0, ceil(s.target - (s.here + s.on_po + s.in_qty - s.out_qty))),
           v_network_names
      from sized s
     order by greatest(0, s.target - (s.here + s.on_po + s.in_qty - s.out_qty)) desc, s.name, s.vname;
end;
$$;

grant execute on function public.staff_suggest_purchase_order_lines(text, text, text, text, int, int, int) to anon;

notify pgrst, 'reload schema';

-- Verification - one result: the function is in place, and per warehouse which stores it supplies
-- (that is whose sales its suggestions will count).
select 'function' as section, p.proname::text as item,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon ok' else 'NOT GRANTED' end as value
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'staff_suggest_purchase_order_lines'
union all
select 'supplies stores', fw."Name"::text, string_agg(distinct tw."Name", ', ')
from (
  select "From Warehouse ID"::text as f, "To Warehouse ID"::text as t, "Status" from public."Transfer_Header"
  union all
  select "From Warehouse ID"::text, "To Warehouse ID"::text, "Status" from public."Posted_Transfer_Header"
) x
join public."Warehouses" fw on fw."ID"::text = x.f
join public."Warehouses" tw on tw."ID"::text = x.t
where coalesce(x."Status", '') <> 'Cancelled'
group by fw."Name";
