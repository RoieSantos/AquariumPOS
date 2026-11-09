-- Conversations: staff pin the delivery spot on Create / Edit Order - per "can you let the staff open a map
-- to confirm or pin the address and auto compute the fee".
--
-- The 📍 Map button beside Delivery Address (js/gmaConversations.js ?v=staffpin1) opens a map; staff drop or
-- drag the pin, the Delivery Fee is computed to that exact spot, and after the order is saved this function
-- puts the pin on it - the same AutomatedOrders.DeliveryLatitude / DeliveryLongitude a customer's
-- "📍 My delivery location" fills (supabase_gma_pin_delivery_booking.sql), so a later 📅 booking or the
-- bot's scheduling measures to it too. It only stores the pin: the fee is saved by the order form itself,
-- and an already-booked delivery stop is not moved (book it again with 📅 for that).
--
-- Same edit rules as admin_update_automated_order: not for Completed / Cancelled orders or ones already
-- confirmed into Online Orders.
--
-- Run AFTER supabase_gma_pin_delivery_booking.sql. Safe to re-run.

create or replace function public.admin_set_automated_order_pin(
  p_admin_username text,
  p_admin_password text,
  p_order_no text,
  p_latitude numeric,
  p_longitude numeric
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_status text;
  v_sync text;
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_latitude is null or p_longitude is null
     or p_latitude not between 4 and 22 or p_longitude not between 116 and 127 then
    raise exception 'The pin must be a spot in the Philippines.';
  end if;

  select "Status", "PancakeSyncStatus" into v_status, v_sync
    from public."AutomatedOrders" where "OrderNo" = p_order_no for update;
  if not found then
    raise exception 'Order % not found.', p_order_no;
  end if;
  if v_status in ('Completed', 'Cancelled') then
    raise exception 'This order is % and can no longer be edited.', v_status;
  end if;
  if v_sync = 'Portal' then
    raise exception 'Order % is already confirmed into Online Orders and can no longer be edited here.', p_order_no;
  end if;

  update public."AutomatedOrders"
     set "DeliveryLatitude" = p_latitude, "DeliveryLongitude" = p_longitude, "UpdatedAtUtc" = now()
   where "OrderNo" = p_order_no;
end;
$$;

grant execute on function public.admin_set_automated_order_pin(text, text, text, numeric, numeric) to anon;

notify pgrst, 'reload schema';

-- Check: the function exists.
select p.proname as function_name, pg_get_function_identity_arguments(p.oid) as arguments
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'admin_set_automated_order_pin';
