-- Online Orders: which Facebook Page a conversation-created order came from.
--
-- One Messenger app now serves more than one Page (RSPetStop GMA + RS Pet Stop - see
-- supabase/functions/_shared/page-tokens.ts), so the old hardcoded "GMA Page" badge on Online
-- Orders (gmaBadgeHtml in docs/js/onlineOrders.js) was wrong for orders from the other Page.
-- AutomatedOrders.GmaPageId already records the Page for every conversation order (staff "+ New
-- Order" and Alice's own orders) - this just exposes it for the rows on screen, same small
-- attach-RPC pattern as staff_list_online_order_production_requests, rather than rewriting the big
-- admin_list_online_orders. Same join admin_list_online_orders uses for is_gma_order
-- (AutomatedOrders.PancakeReceiptNo = OnlineOrders.OrderID).
--
-- Read-only, safe to re-run. Until this is run the page quietly keeps the old "GMA Page" label.

drop function if exists public.staff_list_online_order_gma_pages(text, text, text[]);

create or replace function public.staff_list_online_order_gma_pages(
  p_admin_username text,
  p_admin_password text,
  p_order_ids text[]
)
returns table(order_id text, gma_page_id text)
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
    select distinct on (ao."PancakeReceiptNo")
           ao."PancakeReceiptNo"::text, ao."GmaPageId"::text
    from public."AutomatedOrders" ao
    where ao."PancakeReceiptNo" = any(coalesce(p_order_ids, '{}'))
      and ao."GmaPsid" is not null
      and ao."GmaPageId" is not null
    order by ao."PancakeReceiptNo", ao."CreatedAtUtc" desc;
end;
$$;

grant execute on function public.staff_list_online_order_gma_pages(text, text, text[]) to anon;

notify pgrst, 'reload schema';
