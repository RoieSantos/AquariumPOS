-- Read-only check: why does AO-00047 still ask for a Tank Maker (To Ship greyed out)?
-- One result - one row per order line, plus the order's own flags:
--   line         - each OnlineOrderLines row: maker_part (null = no maker), is_sticker, mentions 10/12mm
--   order        - Status, GlassThickness (10mm / 12mm = the glass rule), roles the portal sees now,
--                  and the To Ship block message (null = may ship)
--   functions    - whether supabase_online_order_sticker_no_maker.sql has been run (sticker helper exists)
-- Safe to run any time.

select 'line' as section, l."LineID"::text as ref, l."ItemCode"::text as item_code,
       left(l."Description", 120)::text as description, left(l."Note", 120)::text as note,
       public._online_order_line_part(l."Description", l."ItemCode", l."product_display_id") as maker_part,
       -- Same test as _online_order_is_sticker_line (inlined so this runs before the fix too).
       ((coalesce(l."ItemCode", '') || ' ' || coalesce(l."product_display_id", '')) ~* 'sticker'
        or coalesce(l."Description", '') ~* '^[[:space:]]*custom[[:space:]]+accessory[[:space:]]*/[[:space:]]*sticker'
        or (coalesce(l."Description", '') ~* 'custom[[:space:]_-]*sticker'
            and coalesce(l."Description", '') !~* 'custom[[:space:]_-]*(aquarium|tank|stand|sump|cabinet)'))::text as is_sticker,
       (regexp_replace(coalesce(l."Description", '') || coalesce(l."Note", '') || coalesce(l."ItemCode", ''), '[[:space:]]+', '', 'g') ~* '1[02]mm')::text as detail
from public."OnlineOrderLines" l
where l."OrderID" = 'AO-00047'

union all
select 'order', o."OrderID"::text, o."Status"::text, ('GlassThickness: ' || coalesce(o."GlassThickness", '-'))::text,
       ('Tank/Stand maker: ' || coalesce(o."AssignedTankMaker", '-') || ' / ' || coalesce(o."AssignedStandMaker", '-'))::text,
       array_to_string(public._online_order_production_roles(o."OrderID"), ', '),
       null,
       public._online_order_to_ship_production_block(o."OrderID")
from public."OnlineOrders" o
where o."OrderID" = 'AO-00047'

union all
select 'functions', 'sticker fix run?', null, null, null, null,
       (to_regprocedure('public._online_order_is_sticker_line(text,text,text)') is not null)::text,
       case when to_regprocedure('public._online_order_is_sticker_line(text,text,text)') is null
            then 'supabase_online_order_sticker_no_maker.sql has NOT been run yet' else 'run' end;
