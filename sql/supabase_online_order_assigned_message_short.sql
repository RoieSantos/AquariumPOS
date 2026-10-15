-- "In production" customer message: plain, short and split into what's BUILT vs what's FROM STOCK - per
-- "can we do a better messaging done this. i want to make it plain short and informative / so if we
-- assign a set then others has stock in the message should say there is stocks only assigned products
-- will be built".
--
-- Before: every order line with its full Note ("SET Materials: ...", "SET Material for <set name>") - a
-- SET order repeated the set name 5+ times and listed every part as if it were being made.
-- Now:
--   📦 Your set: <set name>                     (SET lines, once, no note)
--   🛠️ Being made for you:                       (custom tank / stand lines, and items on a Production
--   • 1 x DUALSTAND-50G (36in HEIGHT, ...)        Order built for this order - ProductionOrderLines)
--   ✅ Ready from our stock:                      (every other item / SET part)
--   • 1 x STANDARD-50G ( 36×18×18in, 6MM GLASS)
-- Only one list when everything is built ("Here's what we're making"). Notes are left out; names are
-- shortened (a leading "AQ-026 - " code and a trailing "(AS-012 - ... - AS-012)" repeat are dropped).
-- The 10mm / 12mm thick-glass paragraph from supabase_online_order_assigned_message_thick_glass.sql is kept.
-- Both send routes (Pancake and GMA Page) use this function.
--
-- Run AFTER supabase_online_order_assigned_message_thick_glass.sql (replaces the same function - if that
-- file is ever re-run, run this one again after it). No table locks. Safe to re-run.

-- Shortened line name for customer messages.
create or replace function public._online_order_message_item_name(p_description text, p_item_code text)
returns text
language sql
immutable
as $$
  select trim(regexp_replace(
           regexp_replace(coalesce(nullif(trim(p_description), ''), p_item_code, ''),
                          '^[A-Z]{1,6}-[0-9]+[A-Za-z0-9-]*\s+-\s+', ''),     -- "AQ-026 - STANDARD-50G" -> "STANDARD-50G"
           '\s*\([A-Z]{1,6}-[0-9]+[A-Za-z0-9-]*\s+-\s+.*$', ''));            -- "... (AS-012 - ... - AS-012)" -> "..."
$$;

create or replace function public._online_order_assigned_message_text(p_order_id text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_customer_name text;
  v_glass text;
  v_sets_text text;
  v_built_text text;
  v_stock_text text;
  v_thickness text;
  v_glass_note text := '';
  v_list text;
begin
  select "CustomerName", "GlassThickness" into v_customer_name, v_glass from public."OnlineOrders" where "OrderID" = p_order_id;

  with lines as (
    select l."LineID",
           coalesce(l."Quantity", 1) as qty,
           public._online_order_message_item_name(l."Description", coalesce(nullif(trim(l."ItemCode"), ''), l."product_display_id")) as name,
           upper(coalesce(public._online_order_line_category(l."VariationId",
             coalesce(nullif(trim(l."ItemCode"), ''), nullif(trim(l."product_display_id"), ''))), '')) = 'SET'
             and l."LineID" not like '%~SETMAT~%' as is_set,
           -- built: custom tank / stand work, or an item on a Production Order built for this order
           public._online_order_line_part(l."Description", l."ItemCode", l."product_display_id") is not null
           or exists (
             select 1
             from public."ProductionOrders" po
             join public."ProductionOrderLines" pl on pl."ProdOrderNo" = po."No"
             where po."SourceOnlineOrderId" = p_order_id
               and pl."ItemCode" = coalesce(
                     (select nullif(trim(v."ItemCode"), '') from public."Variants" v
                       where nullif(trim(l."VariationId"), '') is not null and v."VariationId" = l."VariationId" limit 1),
                     nullif(trim(l."ItemCode"), ''))
               and (pl."VariantId" is null or nullif(trim(l."VariationId"), '') is null or pl."VariantId" = l."VariationId")
           ) as is_built
    from public."OnlineOrderLines" l
    where l."OrderID" = p_order_id
  )
  select
    string_agg('📦 Your set: ' || name, chr(10) order by "LineID") filter (where is_set),
    string_agg('• ' || trim(to_char(qty, 'FM999999990.##')) || ' x ' || name, chr(10) order by "LineID") filter (where not is_set and is_built),
    string_agg('• ' || trim(to_char(qty, 'FM999999990.##')) || ' x ' || name, chr(10) order by "LineID") filter (where not is_set and not is_built)
  into v_sets_text, v_built_text, v_stock_text
  from lines;

  -- 10mm / 12mm: the order's flag first, then its lines (unchanged).
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
      '⏳ About your ' || v_thickness || ' glass: thick glass is pre-ordered and cut to size, and its thicker silicone needs extra time to cure. '
      || 'That''s what makes your tank strong and leak-free, so we don''t rush it. Thank you for your patience! 🙏' || chr(10) || chr(10);
  end if;

  v_list :=
    coalesce(v_sets_text || chr(10) || chr(10), '')
    || case
         -- built + stock: say clearly that only the built items are being made
         when v_built_text is not null and v_stock_text is not null then
           '🛠️ Being made for you:' || chr(10) || v_built_text || chr(10) || chr(10)
           || '✅ Ready from our stock:' || chr(10) || v_stock_text || chr(10) || chr(10)
         when v_built_text is not null then
           '🛠️ Here''s what we''re making:' || chr(10) || v_built_text || chr(10) || chr(10)
         when v_stock_text is not null then
           '🧾 Your items:' || chr(10) || v_stock_text || chr(10) || chr(10)
         else ''
       end;

  return
    '🎉 Hi ' || coalesce(nullif(trim(v_customer_name), ''), 'there') || '! Your order ' || p_order_id || ' is now in production. '
    || case when v_thickness is not null
         then 'Our team is preparing the materials for your build.'
         when v_built_text is not null and v_stock_text is not null
         then 'Some of your items are ready from our stock - we''re only building the ones under "Being made".'
         else 'Our team has been assigned and your order is in our production queue.' end
    || chr(10) || chr(10)
    || v_list
    || v_glass_note
    || 'We''ll message you once your order is ready. Questions? Call +63 997 189 1662 or message us here.'
    || chr(10) || chr(10)
    || 'Happy fish keeping 🐟';
  -- ---------------------------------
end;
$$;

revoke execute on function public._online_order_assigned_message_text(text) from public, anon, authenticated;

-- Preview (doesn't send anything) - one result:
select public._online_order_assigned_message_text('AO-00048') as preview;
