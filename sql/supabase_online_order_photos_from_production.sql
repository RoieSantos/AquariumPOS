-- Online Orders: show the linked Production Order's photos on the order - per "if the picture is coming
-- from the production order.. can you link the picture from there".
--
-- A Production Done proof photo taken on a Production Order (Production Orders page / My Assignments'
-- production-order card) is saved under the PRD no. (OnlineOrderStatusPhotos."OrderID" = 'PRD-...'), so
-- the online order it was built for showed "No photos yet". admin_list_online_order_status_photos now
-- also returns the photos of every Production Order linked to the order
-- (ProductionOrders."SourceOnlineOrderId"), with the PRD no. in front of the label
-- ("PRD-000118 · Production Done (tank)"). Same signature, so the order card's Photos FactBox, the
-- Send Photo picker (can re-send the production photo to the customer) and the order lines page all
-- pick it up with no JS change. Called with a PRD no. (Production Orders page) it behaves as before.
--
-- Replaces the version in supabase_online_order_status_photo.sql - re-running that file puts the old
-- one back, so run this one again after it. Run AFTER supabase_online_order_status_photo.sql and
-- supabase_online_order_stock_ship.sql. Safe to re-run.

create or replace function public.admin_list_online_order_status_photos(p_admin_username text, p_admin_password text, p_order_id text)
returns table(
  photo_id uuid,
  status text,
  public_url text,
  sent_to_customer boolean,
  send_error text,
  uploaded_by text,
  uploaded_at_utc timestamptz
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
    select ph."PhotoID",
           case when ph."OrderID" = p_order_id then ph."Status"::text
                else ph."OrderID" || ' · ' || coalesce(ph."Status", 'Photo') end,
           ph."PublicUrl"::text, ph."SentToCustomer", ph."SendError",
           ph."UploadedBy"::text, ph."UploadedAtUtc"
    from public."OnlineOrderStatusPhotos" ph
    where ph."OrderID" = p_order_id
       or ph."OrderID" in (select po."No" from public."ProductionOrders" po
                           where po."SourceOnlineOrderId" = p_order_id)
    order by ph."UploadedAtUtc" desc;
end;
$$;

grant execute on function public.admin_list_online_order_status_photos(text, text, text) to anon;

notify pgrst, 'reload schema';
