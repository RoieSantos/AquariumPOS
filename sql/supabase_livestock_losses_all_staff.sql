-- Livestock Losses: open to every staff account except makers, Delivery Team and accounts with no branch.
-- Per "can we make this available to staff.. except makers" and "dont include delivery team / and makers" (2026-11-22).
-- Run AFTER supabase_livestock_losses.sql and supabase_online_order_my_assignments.sql (_is_order_maker_only).
-- Replaces only _livestock_caller (same signature); every livestock RPC calls it. Safe to re-run.

create or replace function public._livestock_caller(p_username text, p_password text)
returns table(is_super boolean, is_store_manager boolean, warehouse_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;
  -- "available to staff.. except makers" - Tank / Stand Makers / Dispatchers with no other access.
  if public._is_order_maker_only(p_username) then
    raise exception 'Livestock Losses is not available to maker accounts.';
  end if;
  -- "dont include delivery team / and makers".
  if exists (select 1 from public."StaffUsers" u where u."Username" = p_username
              and coalesce(u."DeliveryTeam", false) and not coalesce(u."SuperUser", false)) then
    raise exception 'Livestock Losses is not available to Delivery Team accounts.';
  end if;
  -- "dont allow users without branch".
  if exists (select 1 from public."StaffUsers" u where u."Username" = p_username
              and nullif(trim(coalesce(u."WarehouseName", '')), '') is null and not coalesce(u."SuperUser", false)) then
    raise exception 'Your account has no branch set - ask a Super User to set one in User Setup.';
  end if;

  return query
    select coalesce(u."SuperUser", false), coalesce(u."StoreManager", false),
           nullif(trim(coalesce(u."WarehouseName", '')), '')::text
    from public."StaffUsers" u
    where u."Username" = p_username;
end;
$$;

revoke execute on function public._livestock_caller(text, text) from public, anon, authenticated;

-- Check: which active accounts can / cannot use it, and who has no location (cannot post).
select case when public._is_order_maker_only(u."Username") then 'blocked (maker)'
            when coalesce(u."DeliveryTeam", false) and not coalesce(u."SuperUser", false) then 'blocked (delivery team)'
            when nullif(trim(coalesce(u."WarehouseName", '')), '') is null and not coalesce(u."SuperUser", false) then 'blocked (no branch)'
            else 'allowed' end as access,
       count(*) as accounts,
       string_agg(u."Username", ', ' order by u."Username") as usernames
from public."StaffUsers" u
where u."IsActive"
group by 1
order by 1;
