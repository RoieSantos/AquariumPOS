-- Per "once the Job order is printed can you saved it on the notes somewhere so it has reference" -
-- appends a dated "Job Order printed dd/mm/yyyy: <description>" line onto the stop's existing
-- Notes field (DeliveryStops."Notes") every time job-order.html's Print button is used (see
-- js/jobOrder.js), so the Job Description that was actually printed stays visible afterwards in
-- the same "Notes" column the Delivery day-detail Stops table already shows (docs/delivery.html).
-- Appends rather than overwrites (unlike admin_update_delivery_stop_geocode's Notes field, which
-- is a deliberate staff edit) so it never clobbers a scheduling note already sitting there, and a
-- Job Order printed more than once for the same stop keeps every prior entry as its own dated line
-- (left() caps it at the column's varchar(1000) limit, dropping the oldest text first). No-ops
-- silently on a blank Job Description - nothing worth keeping a reference to.
create or replace function public.admin_append_delivery_stop_job_order_note(
  p_admin_username text,
  p_admin_password text,
  p_stop_id uuid,
  p_job_description text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_entry text;
  v_current text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_job_description is null or trim(p_job_description) = '' then
    return;
  end if;

  v_entry := 'Job Order printed ' || to_char(now(), 'DD/MM/YYYY') || ': ' || trim(p_job_description);

  select "Notes" into v_current from public."DeliveryStops" where "StopID" = p_stop_id;

  if v_current is null or trim(v_current) = '' then
    v_current := v_entry;
  else
    v_current := left(v_current || E'\n' || v_entry, 1000);
  end if;

  update public."DeliveryStops" set "Notes" = v_current where "StopID" = p_stop_id;
end;
$$;

grant execute on function public.admin_append_delivery_stop_job_order_note(text, text, uuid, text) to anon;
