-- "In production" customer message: bring back the custom build's specs (size / glass / silicone / stand /
-- sticker / color) - per "it did not send over dimensions / color / etc" (AO-00103 went out as just
-- "• 1 x CUSTOM-AQUARIUM").
--
-- supabase_online_order_assigned_message_short.sql dropped line notes to cut the SET noise, but on a custom
-- line the note IS the spec - the line's name is often just "CUSTOM-AQUARIUM" (Pancake's product name).
-- Now, for any line whose note is a custom build sheet (first line "CUSTOM ..."), the customer-relevant rows
-- are listed under the item, and the item is named from that first line ("Custom Aquarium"):
--   • 1 x Custom Aquarium
--      - Size: L: 36" x W: 18" x H: 18" (91.4 x 45.7 x 45.7 cm)
--      - Glass: 10mm, Tempered
--      - Silicone: Black
--      - Sticker Background: Tiles Sticker
-- Left out: prices, volume, quantities, the drawing link, "see Custom Stand line" pointers, Special Note
-- (staff-facing). Lines without a custom build sheet (stock items, SET parts) are unchanged.
--
-- Run AFTER supabase_online_order_assigned_message_short.sql (replaces the same function - if that file is
-- ever re-run, run this one again after it). No table locks. Safe to re-run.

-- Customer-facing spec rows from a custom line's build-sheet note ('   - Label: value' lines), or null.
create or replace function public._online_order_message_line_specs(p_note text)
returns text
language sql
immutable
as $$
  select string_agg(
           '   - ' || case
             when x.m is null then trim(x.line)
             else case x.m[1]
                    when 'Dimensions' then 'Size'
                    when 'Size (L x W)' then 'Size'
                    when 'Sealant' then 'Silicone'
                    else x.m[1] end || ': ' || x.m[2]
           end,
           chr(10) order by x.ord)
  from (
    select t.line, t.ord, regexp_match(trim(t.line), '^([^:]+):\s*(.+)$') as m
    from regexp_split_to_table(coalesce(p_note, ''), '\r?\n') with ordinality as t(line, ord)
    where t.ord > 1
  ) x
  where upper(trim(split_part(coalesce(p_note, ''), chr(10), 1))) like 'CUSTOM %'
    and (
      (x.m is not null
        and x.m[1] in ('Build type', 'Dimensions', 'Size', 'Size (L x W)', 'Glass', 'Thickness', 'Sealant', 'Color',
                       'Add-ons', 'Stand', 'Stand Options', 'Sticker Background', 'Sticker Bottom',
                       'Filtration Sump', 'Sump Dimensions', 'Sump Glass', 'Sump Includes', 'Job')
        and not (x.m[1] = 'Build type' and x.m[2] ilike 'Aquarium only')
        and not (x.m[1] = 'Stand' and x.m[2] !~* '^Layers'))       -- "Stand: None (aquarium only)" / "Yes - see ..."
      or (x.m is null and trim(x.line) ~* '^(Hole for Aquarium|Divider)')
    );
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
           public._online_order_message_line_specs(l."Note") as specs,
           public._online_order_message_item_name(l."Description", coalesce(nullif(trim(l."ItemCode"), ''), l."product_display_id")) as short_name,
           -- custom build sheet's first line ("CUSTOM AQUARIUM", "CUSTOM STAND (stand only - ...)") -> "Custom Aquarium"
           initcap(trim(regexp_replace(split_part(coalesce(l."Note", ''), chr(10), 1), '\s*\(.*$', ''))) as sheet_name,
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
  ),
  bullets as (
    select "LineID", is_set, is_built, short_name,
           '• ' || trim(to_char(qty, 'FM999999990.##')) || ' x '
           || case when specs is not null and sheet_name <> '' then sheet_name else short_name end
           || coalesce(chr(10) || specs, '') as bullet
    from lines
  )
  select
    string_agg('📦 Your set: ' || short_name, chr(10) order by "LineID") filter (where is_set),
    string_agg(bullet, chr(10) order by "LineID") filter (where not is_set and is_built),
    string_agg(bullet, chr(10) order by "LineID") filter (where not is_set and not is_built)
  into v_sets_text, v_built_text, v_stock_text
  from bullets;

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

-- Preview (doesn't send anything) - one result: the message AO-00103 would get now, plus its raw line notes
-- so you can see what the specs were pulled from.
select 'preview' as section, public._online_order_assigned_message_text('AO-00103') as value
union all
select 'line ' || l."LineID" || ' note', coalesce(l."Description", '') || chr(10) || '---' || chr(10) || coalesce(l."Note", '(no note)')
from public."OnlineOrderLines" l
where l."OrderID" = 'AO-00103';
