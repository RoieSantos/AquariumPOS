-- Read-only item list for the POS, per "make sure that the item is not present on portal and pancake
-- before deactivating": tools/pos_duplicate_items_cleanup.bat (and the generator of
-- sql/pos_duplicate_items_cleanup.sql) call this to get every portal Items row
-- (Code + Pancake ids) so it never deactivates a POS item the portal still has.
--
-- Same POS-key check as the Online Pay RPCs (_pos_key_ok, Vault secret POS_API_KEY).
-- Run AFTER supabase_pos_online_pay.sql (already live - it creates _pos_key_ok).
-- Safe to re-run.

create or replace function public.pos_list_item_codes(
  p_pos_key text,
  p_limit int default 1000,
  p_offset int default 0
)
returns table(code text, name text, variation_id text, product_id text, is_active boolean)
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if not public._pos_key_ok(p_pos_key) then
    raise exception 'Not authorized.';
  end if;

  return query
  select i."Code"::text, i."Name"::text, i."VariationId"::text, i."ProductId"::text, coalesce(i."IsActive", true)
  from public."Items" i
  order by i."Code"
  limit least(greatest(coalesce(p_limit, 1000), 1), 1000)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

revoke all on function public.pos_list_item_codes(text, int, int) from public;
grant execute on function public.pos_list_item_codes(text, int, int) to anon;

-- Check: row count the RPC can see (should match the portal's Item list).
select count(*) as portal_items from public."Items";
