-- Delivery calendar: Assigned orders can be scheduled too - per "can we include Assigned status too?".
--
-- admin_list_deliverable_online_orders (the calendar's Add order search) only listed online orders in
-- Confirmed / Printed / To Ship / Shipped, so a custom order whose makers were assigned (status
-- Assigned, which it keeps through Production Done until To Ship) couldn't be put on the calendar
-- while it was being built. Assigned is now in that list. Everything else is unchanged:
-- Cancelled still Super User only, an order already on the calendar is still hidden, advance and
-- draft AO orders as before. admin_create_delivery_stop never checked the status, so nothing else
-- needed changing.
--
-- NOT changed: the AI bot's customer self-scheduling (public_get_delivery_scheduling_options /
-- public_schedule_online_order_delivery, supabase_chatbot_delivery_scheduling_rpc.sql) still only
-- offers Confirmed / Printed / To Ship / Shipped - nobody reviews those bookings, and an Assigned
-- order is still being built.
--
-- Same function as supabase_delivery_assign_automated_order_search.sql's section 3 otherwise.
-- Run AFTER supabase_delivery_assign_automated_order_search.sql. Function only - safe to re-run. If
-- that file is ever re-run, run this one again afterwards. No JS change - reload the Delivery page.

drop function if exists public.admin_list_deliverable_online_orders(text, text, text, int, int, text, text);

create or replace function public.admin_list_deliverable_online_orders(p_admin_username text, p_admin_password text, p_search text default null, p_page int default 1, p_page_size int default 50,
  p_sort_column text default null, p_sort_dir text default 'asc')
returns table(
  order_id text,                 -- OnlineOrders.OrderID / AdvanceOrders.TransactionNo / AutomatedOrders.OrderNo, by source
  source text,                   -- 'online' | 'advance' | 'automated'
  customer_name text,
  status text,
  shipping_address text,
  contact_number text,
  money_to_collect numeric,
  balance numeric,
  estimated_delivery_date date,
  is_walk_in boolean,
  total_count bigint,
  automated_order_no text        -- AutomatedOrders.OrderNo ("AO-00039") behind the order, if any
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_sort text := lower(coalesce(p_sort_column, ''));
  v_desc boolean := lower(coalesce(p_sort_dir, 'asc')) = 'desc';
  v_is_super_user boolean;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select coalesce("SuperUser", false) into v_is_super_user
  from public."StaffUsers"
  where "Username" = p_admin_username;

  return query
    with candidates as (
      select o."OrderID"::text as id, 'online'::text as src,
             coalesce(nullif(trim(o."WalkinCustomerName"), ''), o."CustomerName")::text as cust,
             o."Status"::text as st, o."ShippingAddress"::text as addr,
             coalesce(nullif(trim(o."WalkinCustomerPhone"), ''), o."ShippingPhone")::text as phone,
             o."MoneyToCollect" as mtc, o."Balance" as bal, o."EstimatedDeliveryDate" as edd,
             (coalesce(o."ReceivedAtShop", false)
              or lower(trim(coalesce(o."CustomerName", ''))) = 'pos walkin orders'
              or lower(trim(coalesce(o."ShippingAddress", ''))) = 'walkin') as walk_in,
             o."Last_Updated_At" as sort_at,
             (select ao."OrderNo"::text from public."AutomatedOrders" ao
              where ao."PancakeReceiptNo" = o."OrderID" order by ao."OrderNo" limit 1) as ao_no
      from public."OnlineOrders" o
      where (
          lower(o."Status") in ('confirmed', 'printed', 'assigned', 'to ship', 'shipped') -- + assigned (this file)
          or (coalesce(v_is_super_user, false) and lower(o."Status") in ('canceled', 'cancelled'))
        )
        and not exists (select 1 from public."DeliveryStops" s where s."OrderID" = o."OrderID")
        -- its advance order (if any) is already scheduled under the advance number
        and not exists (
          select 1 from public."AdvanceOrders" a
          join public."DeliveryStops" s on s."AdvanceTransactionNo" = a."TransactionNo"
          where nullif(trim(a."OnlineOrderID"), '') = o."OrderID")
        -- its automated order is already scheduled under the AO number
        and not exists (
          select 1 from public."AutomatedOrders" ao
          join public."DeliveryStops" s on s."AutomatedOrderNo" = ao."OrderNo"
          where ao."PancakeReceiptNo" = o."OrderID")
        and (v_search is null
             or o."OrderID" ilike '%' || v_search || '%'
             or o."CustomerName" ilike '%' || v_search || '%'
             or o."WalkinCustomerName" ilike '%' || v_search || '%'
             or exists (select 1 from public."AutomatedOrders" ao
                        where ao."PancakeReceiptNo" = o."OrderID"
                          and ao."OrderNo" ilike '%' || v_search || '%'))

      union all

      select a."TransactionNo"::text, 'advance',
             a."CustomerName"::text,
             ('Advance' || coalesce(' - ' || public._advance_order_prod_status(p), ''))::text,
             null::text, null::text,
             a."Balance", a."Balance", null::date,
             false,
             greatest(a."DatePaid",
                      (a."Date" + coalesce(public._advance_order_time(a."Time"), time '00:00')) at time zone 'Asia/Manila'),
             null::text
      from public."AdvanceOrders" a
      left join public."AdvanceOrderProduction" p on p."TransactionNo" = a."TransactionNo"
      where not exists (select 1 from public."DeliveryStops" s where s."AdvanceTransactionNo" = a."TransactionNo")
        -- its linked online order is already scheduled
        and not exists (select 1 from public."DeliveryStops" s
                        where s."OrderID" = nullif(trim(a."OnlineOrderID"), ''))
        and (v_search is null
             or a."TransactionNo" ilike '%' || v_search || '%'
             or a."ReceiptNo" ilike '%' || v_search || '%'
             or a."CustomerName" ilike '%' || v_search || '%'
             or a."OnlineOrderID" ilike '%' || v_search || '%')

      union all

      -- Automated orders with no online order yet (draft awaiting Confirm Order).
      select ao."OrderNo"::text, 'automated',
             ao."CustomerName"::text,
             (ao."Status" || public._automated_order_pending_label(ao."PancakeSyncStatus"))::text,
             ao."DeliveryAddress"::text, ao."CustomerPhone"::text,
             public._automated_order_total(ao."OrderNo"), public._automated_order_total(ao."OrderNo"),
             null::date,
             false,
             ao."UpdatedAtUtc",
             ao."OrderNo"::text
      from public."AutomatedOrders" ao
      where not exists (select 1 from public."OnlineOrders" o
                        where o."OrderID" = nullif(trim(ao."PancakeReceiptNo"), ''))
        and (lower(ao."Status") not in ('cancelled', 'canceled') or coalesce(v_is_super_user, false))
        and not exists (select 1 from public."DeliveryStops" s where s."AutomatedOrderNo" = ao."OrderNo")
        and (v_search is null
             or ao."OrderNo" ilike '%' || v_search || '%'
             or ao."CustomerName" ilike '%' || v_search || '%'
             or ao."CustomerPhone" ilike '%' || v_search || '%')
    ),
    keyed as (
      select c.*,
             -- order numbers sort as numbers (9 before 10), anything non-numeric after them
             case when v_sort = 'order_id' and c.id ~ '^\d+$' then c.id::numeric end as num_key,
             case v_sort
               when 'order_id' then lower(c.id)
               when 'customer_name' then lower(nullif(trim(c.cust), ''))
               when 'status' then lower(nullif(trim(c.st), ''))
               when 'shipping_address' then lower(nullif(trim(c.addr), ''))
               when 'type' then case when c.src = 'advance' then 'advance' when c.src = 'automated' then 'order form'
                                     when c.walk_in then 'walk-in' else 'online' end
             end as text_key
      from candidates c
    )
    select k.id, k.src, k.cust, k.st, k.addr, k.phone, k.mtc, k.bal, k.edd, k.walk_in,
           count(*) over(), k.ao_no
    from keyed k
    order by case when not v_desc then k.num_key end asc nulls last,
             case when v_desc then k.num_key end desc nulls last,
             case when not v_desc then k.text_key end asc nulls last,
             case when v_desc then k.text_key end desc nulls last,
             k.sort_at desc nulls last, k.id desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_deliverable_online_orders(text, text, text, int, int, text, text) to anon;

notify pgrst, 'reload schema';
