-- "In production" message: a thick-glass note for 10mm / 12mm orders - per "once assigned add details
-- like. Thicker glass needs more time to process since its pre-order / longer time to cure due to
-- thicker silicon".
--
-- Same text as supabase_online_order_assigned_message_gma.sql's _online_order_assigned_message_text,
-- plus one paragraph after the item list when the order has 10mm / 12mm glass. Thickness = the order's
-- GlassThickness flag (the "10mm glass" / "12mm glass" badge), or failing that its lines (description /
-- note / item code) - same 12mm-wins-over-10mm rule as the turnaround ETA in
-- admin_sync_online_order_assigned_status. Every other order gets the exact same message as before.
-- Both send routes (Pancake and GMA Page) use this function, so both get the note.
--
-- Run AFTER supabase_online_order_assigned_message_gma.sql; if that file is ever re-run, run this one
-- again after it. Replaces one function - no table locks. Safe to re-run.

create or replace function public._online_order_assigned_message_text(p_order_id text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_customer_name text;
  v_glass text;
  v_items_text text;
  v_thickness text;
  v_glass_note text := '';
begin
  select "CustomerName", "GlassThickness" into v_customer_name, v_glass from public."OnlineOrders" where "OrderID" = p_order_id;

  select string_agg(
    '✅ ' || trim(to_char(coalesce(l."Quantity", 1), 'FM999999990.##')) || ' x ' || coalesce(nullif(trim(l."Description"), ''), l."ItemCode")
      || case when nullif(trim(coalesce(l."Note", '')), '') is null then '' else ' 🧾 Note : ' || l."Note" end,
    chr(10) order by l."LineID"
  ) into v_items_text
  from public."OnlineOrderLines" l
  where l."OrderID" = p_order_id;

  -- 10mm / 12mm: the order's flag first, then its lines.
  v_thickness := case lower(regexp_replace(coalesce(v_glass, ''), '\s+', '', 'g'))
                   when '12mm' then '12mm' when '10mm' then '10mm' end;
  if v_thickness is null then
    select t.thickness into v_thickness
    from (values ('12mm', 1), ('10mm', 2)) as t(thickness, priority)
    where exists (
      select 1 from public."OnlineOrderLines" ol
      where ol."OrderID" = p_order_id
        and regexp_replace(coalesce(ol."Description", '') || coalesce(ol."Note", '') || coalesce(ol."ItemCode", ''), '[[:space:]]+', '', 'g') ilike '%' || t.thickness || '%'
    )
    order by t.priority
    limit 1;
  end if;

  -- ---- Message text: edit here ----
  if v_thickness is not null then
    v_glass_note :=
      '⏳ A quick heads-up about your ' || v_thickness || ' glass:' || chr(10) || chr(10)
      || '• Thick glass is pre-ordered and cut to size for your tank, so it takes longer than our regular orders.' || chr(10)
      || '• Thicker glass also needs thicker silicone joints, which need extra curing time to fully set. This is what makes your tank strong and leak-free, so we don''t rush it.' || chr(10) || chr(10)
      || 'Thank you for your patience - it''s worth the wait! 🙏' || chr(10) || chr(10);
  end if;

  return
    '🎉 Hi ' || coalesce(nullif(trim(v_customer_name), ''), 'there') || '! Good news - your order ' || p_order_id
    || ' is now in production. '
    -- Thick glass is pre-ordered, so building hasn't really started yet.
    || case when v_thickness is not null
         then 'Our team has been assigned and is now preparing the materials for your build.'
         else 'Our team has been assigned and your items are now in our production queue.' end
    || chr(10) || chr(10)
    || '🧾 Here''s what we''re making:' || chr(10) || chr(10)
    || coalesce(v_items_text, '') || chr(10) || chr(10)
    || v_glass_note
    || 'We''ll message you again once your order is ready. For any urgent matters, call +63 997 189 1662 or drop us a message here.'
    || chr(10) || chr(10)
    || 'Happy fish keeping 🐟 😊';
  -- ---------------------------------
end;
$$;

revoke execute on function public._online_order_assigned_message_text(text) from public, anon, authenticated;

-- Preview (doesn't send anything):
-- select public._online_order_assigned_message_text('105355');
