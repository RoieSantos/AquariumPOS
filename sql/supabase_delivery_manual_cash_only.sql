-- Drivers: only CASH can be recorded by hand while the delivery Xendit QR is on - per "the collected P1 did
-- allowed in gcash even though the QR (xendit) has not been paid.. Can we control them to not allow to receive
-- payments online manually if xendit is available online".
--
-- "Record Payment Collected" with Paid via GCash / bank saved the driver's word as a payment. While
-- XenditSettings."DeliveryEnabled" is ON (Xendit Payments > "Allow drivers to collect by Xendit QR"):
--   - staff_list_delivery_payment_methods only offers Cash,
--   - staff_record_delivery_collection refuses any other method for a NEW collection (a retry of one already
--     saved still goes through), so an old page or a direct call can't get around it.
-- GCash / Maya / bank go through "Collect by QR", which is only saved once Xendit says Paid.
-- Switch OFF = every method is back, same as before.
--
-- Run AFTER supabase_delivery_driver_collections.sql and supabase_xendit_delivery_collect.sql. Safe to re-run.
-- Needs js/delivery.js ?v=xqr2 (reload the Delivery page). Ends with ONE result.

-- Copy of supabase_delivery_driver_collections.sql's version + the cash-only rule.
drop function if exists public.staff_list_delivery_payment_methods(text, text);

create or replace function public.staff_list_delivery_payment_methods(p_username text, p_password text)
returns table(code text, name text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_qr_on boolean := coalesce((select s."DeliveryEnabled" from public."XenditSettings" s where s."Id" = 1), false);
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;
  return query
    select pm."Code", coalesce(nullif(trim(pm."Name"), ''), nullif(trim(pm."PancakeName"), ''))::text
    from public."PaymentMethods" pm
    where pm."IsActive" and (pm."Code" = 'CASH' or coalesce(nullif(trim(pm."Name"), ''), nullif(trim(pm."PancakeName"), '')) is not null)
      and (not v_qr_on or pm."Code" = 'CASH')
    order by (pm."Code" = 'CASH') desc, 2;
end;
$$;

grant execute on function public.staff_list_delivery_payment_methods(text, text) to anon;

-- Copy of supabase_delivery_driver_collections.sql's version + the cash-only rule for new collections.
drop function if exists public.staff_record_delivery_collection(text, text, uuid, uuid, numeric, text, text);

create or replace function public.staff_record_delivery_collection(
  p_username text,
  p_password text,
  p_collection_id uuid,
  p_stop_id uuid,
  p_amount numeric,
  p_method_code text,
  p_reference text
)
returns table(apply_status text, apply_error text, applied_amount numeric, applied_in text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '120000'
as $$
declare
  v_existing public."DeliveryCollections"%rowtype;
  v_method_name text;
  v_collectable numeric;
  v_order_ref text;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;
  if p_collection_id is null or p_stop_id is null then
    raise exception 'Collection ID and stop are required.';
  end if;

  perform pg_advisory_xact_lock(hashtext('delivery-collection:' || p_stop_id::text));

  select * into v_existing from public."DeliveryCollections" where "CollectionID" = p_collection_id;
  if found then
    if v_existing."StopID" <> p_stop_id then
      raise exception 'This collection belongs to another stop.';
    end if;
  else
    if v_amount <= 0 then
      raise exception 'Enter the amount collected.';
    end if;
    if coalesce(p_method_code, '') <> 'CASH'
       and coalesce((select s."DeliveryEnabled" from public."XenditSettings" s where s."Id" = 1), false) then
      raise exception 'Only cash can be recorded by hand. For GCash, Maya or bank, use "Collect by QR" - it saves itself once the customer pays.';
    end if;
    select coalesce(nullif(trim(pm."Name"), ''), nullif(trim(pm."PancakeName"), ''), 'Cash') into v_method_name
    from public."PaymentMethods" pm where pm."Code" = p_method_code and pm."IsActive";
    if v_method_name is null then
      raise exception 'Pick a payment method.';
    end if;

    select coalesce(s."OrderID", 'ADV-' || s."AdvanceTransactionNo", s."AutomatedOrderNo") into v_order_ref
    from public."DeliveryStops" s where s."StopID" = p_stop_id;
    if not found then
      raise exception 'Stop not found.';
    end if;

    v_collectable := coalesce(public._delivery_stop_collectable(p_stop_id), 0);
    if v_amount > v_collectable + 0.005 then
      raise exception 'The amount (%) is more than the balance to collect (%).', v_amount, round(greatest(v_collectable, 0), 2);
    end if;

    insert into public."DeliveryCollections" ("CollectionID", "StopID", "OrderRef", "Amount", "MethodCode", "MethodName", "Reference", "CollectedBy")
    values (p_collection_id, p_stop_id, v_order_ref, v_amount, p_method_code, v_method_name,
            nullif(left(trim(coalesce(p_reference, '')), 200), ''), p_username);
  end if;

  perform public._apply_delivery_collection(p_collection_id);

  return query
    select dc."ApplyStatus", dc."ApplyError", dc."AppliedAmount", dc."AppliedIn"
    from public."DeliveryCollections" dc where dc."CollectionID" = p_collection_id;
end;
$$;

grant execute on function public.staff_record_delivery_collection(text, text, uuid, uuid, numeric, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result: the switch, and what a driver can pick by hand right now.
select 'setting' as section, 'Delivery QR switch' as item,
       case when s."DeliveryEnabled" then 'ON - drivers can record CASH only by hand' else 'OFF - every method allowed' end as value
  from public."XenditSettings" s where s."Id" = 1
union all
select 'manual method', pm."Code", coalesce(nullif(trim(pm."Name"), ''), nullif(trim(pm."PancakeName"), ''))
  from public."PaymentMethods" pm
 where pm."IsActive"
   and (pm."Code" = 'CASH' or not coalesce((select s."DeliveryEnabled" from public."XenditSettings" s where s."Id" = 1), false));
