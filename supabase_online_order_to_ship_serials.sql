-- Lets the Web Portal's "To Ship" button (docs/js/onlineOrders.js) require staff to pick physical
-- serial-tracked units for a production-warehouse order before it ships, matching the desktop's
-- own EnsureOrderSerialTrackingAsync gate on MarkRowAsToShipAsync (OnlineOrdersForm.cs). Per direct
-- decision: unlike the desktop, the portal only ever offers EXISTING IN_STOCK serials (see
-- public."ItemSerialTracking" / supabase_item_serial_tracking.sql) - it never generates new ones or
-- prints labels, since a phone browser can't drive a label printer. If an order doesn't have enough
-- tagged serials available, the portal blocks "To Ship" and tells staff to finish it on the desktop
-- app instead.
--
-- The actual claim (existing IN_STOCK serial -> SOLD, tied to this order) happens inside
-- admin_update_online_order_status itself (see supabase_online_order_portal_status_update.sql's
-- p_serial_running_nos param) rather than here, so it shares that function's implicit transaction -
-- if the Pancake status PATCH fails afterward, Postgres rolls the claim back too. This file only
-- adds the READ side: figuring out which of an order's lines need a serial pick and how many.
--
-- Item code resolution mirrors OnlineOrdersForm.cs's ResolveOnlineLineItemCode/
-- ResolveOnlineLineCategoryCode: Pancake's own item_code/product_display_id on an order line
-- doesn't always match the internal Items.Code, so this resolves through public."Variants" (synced
-- from local dbo.[Variant] - see SyncProductVariationsAsync) by VariationId first, falling back to
-- a direct public."Items" match. VariationId itself is passed through unresolved (same as the
-- desktop) since that's the exact value public."ItemSerialTracking"."VariantCode" is keyed on.
-- Requirement rule (which items need a serial at all) mirrors ShouldRequireOnlineOrderSerialSelection:
-- item code prefix (AQ-, CUSTOM-AQUARIUM, CUSTOM_STAND, CUSTOM-SUMP, CUSTOM_SUMP) OR the resolved
-- category's Categories.IsProductionCategory flag.

drop function if exists public.admin_get_online_order_serial_requirements(text, text, text);

create or replace function public.admin_get_online_order_serial_requirements(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(
  line_id text,
  item_code text,
  variation_id text,
  description text,
  quantity_needed int
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with resolved as (
      select
        l."LineID" as line_id,
        nullif(trim(l."VariationId"), '') as variation_id,
        l."Description" as description,
        l."Quantity" as quantity,
        coalesce(
          nullif(trim(v."ItemCode"), ''),
          nullif(trim(i."Code"), ''),
          nullif(trim(l."ItemCode"), '')
        ) as resolved_item_code,
        coalesce(v."CategoryCode", i."CategoryCode") as resolved_category_code
      from public."OnlineOrderLines" l
      left join public."Variants" v
        on nullif(trim(l."VariationId"), '') is not null and v."VariationId" = l."VariationId"
      left join public."Items" i
        on i."Code" = l."ItemCode" or i."VariationId" = l."ItemCode"
      where l."OrderID" = p_order_id
    )
    select
      r.line_id::text,
      r.resolved_item_code::text,
      r.variation_id::text,
      coalesce(nullif(trim(r.description), ''), r.resolved_item_code)::text,
      greatest(1, ceil(coalesce(r.quantity, 1)))::int
    from resolved r
    left join public."Categories" c on c."Code" = r.resolved_category_code
    where r.resolved_item_code is not null
      and (
        upper(r.resolved_item_code) like 'AQ-%'
        or upper(r.resolved_item_code) like 'CUSTOM-AQUARIUM%'
        or upper(r.resolved_item_code) like 'CUSTOM_STAND%'
        or upper(r.resolved_item_code) like 'CUSTOM-SUMP%'
        or upper(r.resolved_item_code) like 'CUSTOM_SUMP%'
        or coalesce(c."IsProductionCategory", false)
      );
end;
$$;

grant execute on function public.admin_get_online_order_serial_requirements(text, text, text) to anon;
