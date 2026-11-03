-- Order Now keeps each line's build sheet. Per "add a button there create order base on what in the
-- estimator": the Aquarium Calculator's Create Order button (WebAquariumCalculator/index.html) sends a
-- full build sheet per line, but submit_automated_order never saved a line note, so staff would only
-- get the short item name.
--
--   1. AutomatedOrderLines."Notes" grows from 500 to 2000 characters (a build sheet can pass 500).
--      admin_confirm_bot_order already copies it to OnlineOrderLines."Note" on Confirm Order.
--   2. submit_automated_order saves p_lines[].note (patched into the LIVE function text, same as
--      supabase_order_now_portal_only.sql). This RPC is public, so the note is capped at 2000.
--
-- Run AFTER supabase_order_now_portal_only.sql. Safe to re-run. Ends with one result query.

alter table public."AutomatedOrderLines" alter column "Notes" type varchar(2000);

-- Stops with an error, without patching the function, if the expected text isn't there.
do $patch$
declare
  v_sig regprocedure := 'public.submit_automated_order(text, text, text, text, text, text, text, text, text, jsonb)'::regprocedure;
  v_def text := pg_get_functiondef(v_sig);
  v_new text;
begin
  if v_def like '%nullif(trim(coalesce(v_line->>''note''%' then
    raise notice 'submit_automated_order already patched - skipped.';
    return;
  end if;

  v_new := replace(v_def,
    $s$("OrderNo", "CategoryCode", "ItemCode", "ItemName", "Quantity", "Price")$s$,
    $s$("OrderNo", "CategoryCode", "ItemCode", "ItemName", "Quantity", "Price", "Notes")$s$);
  if v_new = v_def then raise exception 'submit_automated_order patch: line insert columns not found - nothing changed.'; end if;
  v_def := v_new;

  v_new := replace(v_def,
    $s$v_item_code, trim(v_line->>'item_name'), v_qty, v_price);$s$,
    $s$v_item_code, trim(v_line->>'item_name'), v_qty, v_price,
       left(nullif(trim(coalesce(v_line->>'note', '')), ''), 2000));$s$);
  if v_new = v_def then raise exception 'submit_automated_order patch: line insert values not found - nothing changed.'; end if;

  execute v_new;
end
$patch$;

notify pgrst, 'reload schema';

select 'submit_automated_order saves line notes' as section,
       (pg_get_functiondef('public.submit_automated_order(text, text, text, text, text, text, text, text, text, jsonb)'::regprocedure) like '%nullif(trim(coalesce(v_line->>''note''%')::text as detail
union all
select 'AutomatedOrderLines.Notes max length', character_maximum_length::text
from information_schema.columns
where table_schema = 'public' and table_name = 'AutomatedOrderLines' and column_name = 'Notes';
