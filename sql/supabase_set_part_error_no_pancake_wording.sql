-- Rewords the Set Assembly save error "Component ... is not linked to a Pancake product" (Pancake is retired;
-- the real cause is a package line whose item code doesn't exist, or an item with no VariationId).
-- Patches ONLY that message inside whatever versions of the functions are live now, so the big
-- supabase_bot_orders_portal_confirm.sql / supabase_online_order_set_explode.sql don't need re-running
-- (both source files already carry the new wording for future runs).
-- Safe to re-run: a function that already has the new wording is skipped.
do $$
declare
  r record;
  v_def text;
  v_old text := 'Component "%" is not linked to a Pancake product (no VariationId in Items) - fix the item or remove it from the set.';
  v_new text := 'Part "%" is not linked to an item in the portal (unknown item code or no VariationId) - fix its item code on the Customer Aquarium package, or untick it.';
begin
  for r in
    select p.oid, p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('staff_save_online_order_set_materials', '_save_portal_order_set_materials')
  loop
    v_def := pg_get_functiondef(r.oid);
    if position(v_old in v_def) > 0 then
      execute replace(v_def, v_old, v_new);
      raise notice 'reworded %', r.proname;
    end if;
  end loop;
end;
$$;

-- Result: 'new wording' for each function (old_left = 0 means done).
select p.proname,
       (position('not linked to an item in the portal' in pg_get_functiondef(p.oid)) > 0) as new_wording,
       (length(pg_get_functiondef(p.oid)) - length(replace(pg_get_functiondef(p.oid), 'Pancake product', ''))) / length('Pancake product') as old_left
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('staff_save_online_order_set_materials', '_save_portal_order_set_materials');
