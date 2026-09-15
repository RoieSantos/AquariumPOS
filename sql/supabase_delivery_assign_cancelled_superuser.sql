-- Lets a super user look up and assign a Cancelled order on the Delivery calendar (e.g. an order
-- that was cancelled by mistake, or needs a delivery scheduled despite the cancellation) while
-- everyone else still only sees the normal deliverable statuses. Only the search/eligibility list
-- (admin_list_deliverable_online_orders) needed this check - admin_create_delivery_stop never
-- filtered by order status itself, so once a Cancelled order is surfaced here it can already be
-- assigned exactly the same way any other order is.
create or replace function public.admin_list_deliverable_online_orders(p_admin_username text, p_admin_password text, p_search text default null, p_page int default 1, p_page_size int default 50)
returns table(
  order_id text,
  customer_name text,
  status text,
  shipping_address text,
  money_to_collect numeric,
  balance numeric,
  estimated_delivery_date date,
  scheduled_date date,
  stop_id uuid,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_is_super_user boolean;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select coalesce("SuperUser", false) into v_is_super_user
  from public."StaffUsers"
  where "Username" = p_admin_username;

  return query
    select o."OrderID"::text, o."CustomerName"::text, o."Status"::text, o."ShippingAddress"::text,
           o."MoneyToCollect", o."Balance", o."EstimatedDeliveryDate",
           s."DeliveryDate", s."StopID",
           count(*) over()
    from public."OnlineOrders" o
    left join public."DeliveryStops" s on s."OrderID" = o."OrderID"
    where o."ForDelivery" is not true
      and (
        lower(o."Status") in ('confirmed', 'printed', 'to ship', 'shipped')
        or (coalesce(v_is_super_user, false) and lower(o."Status") in ('canceled', 'cancelled'))
      )
      and (
        p_search is null or trim(p_search) = ''
        or o."OrderID" ilike '%' || p_search || '%'
        or o."CustomerName" ilike '%' || p_search || '%'
      )
    order by o."Last_Updated_At" desc nulls last
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;
