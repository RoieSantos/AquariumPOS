-- Public (anon, no login) delivery price self-estimate for the "Order Now" customer wizard
-- (docs/order-now.html / js/orderNow.js) - per direct request: add an "Estimate Delivery" mode
-- alongside Standard/Customize that lets a customer quote themselves (origin branch -> their own
-- destination address), mirroring the staff-only Delivery Quote page's in-house pricing formula
-- (base fee + rate/km + toll - see docs/js/deliveryQuote.js's runInHouseQuote) but reachable with
-- no staff login at all.
--
-- The staff tool reads these same 4 settings via admin_get_public_portal_setting, which still
-- requires a valid staff username/password (is_staff_authorized) even though it's the "public"
-- one - unusable for an anonymous customer page. This is that same narrow slice (only rows
-- already flagged IsPublicToStaff = true - nothing becomes newly exposed by adding this, it's the
-- same information already reaching every staff member's browser) opened up further to anon, with
-- no credentials at all, same trust model as public_list_order_categories/public_list_order_items
-- in supabase_automated_orders_tables.sql.
--
-- GOOGLE_MAPS_API_KEY is safe to expose this way - a Maps JavaScript API key is meant to run in
-- browser JS and is restricted by HTTP referrer (Google Cloud Console), not by keeping it secret.

drop function if exists public.public_get_delivery_quote_settings();

create or replace function public.public_get_delivery_quote_settings()
returns table(setting_key text, setting_value text)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select "SettingKey"::text, "SettingValue"::text
  from public."PortalSettings"
  where "IsPublicToStaff" is true
    and "SettingKey" in ('GOOGLE_MAPS_API_KEY', 'DELIVERY_BASE_FEE', 'DELIVERY_RATE_PER_KM', 'DELIVERY_TOLL_FEE');
$$;

grant execute on function public.public_get_delivery_quote_settings() to anon;
