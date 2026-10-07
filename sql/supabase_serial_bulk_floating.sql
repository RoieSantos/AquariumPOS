-- Serial Tracker: bulk Mark Floating / Release (Super User only) - per "can you allow the super user to
-- bulk delete the serial?" -> "it should be bulk mark as sold or bulk floating just to not make the user
-- sell the serials".
--
-- FLOATING = the unit exists but must not be sold. Every serial picker (POS sale, online-order To Ship,
-- portal To Ship) only offers IN_STOCK serials, so a floating serial can't be picked. Not SOLD on
-- purpose: no fake sale mixed in with real ones, and it's undone with Release (back to IN_STOCK, same
-- location). It's a status change, not a row delete, so it reaches every store POS through the normal
-- serial pull (OnlinefunctionsEvents.SyncItemSerialTrackingFromSupabaseAsync, by UpdatedAtUtc).
--
--   admin_bulk_set_serial_status(serials, 'FLOATING')  - skips SOLD (tied to a sale), IN_TRANSIT (on an
--                                                        open Transfer Order) and already-FLOATING.
--   admin_bulk_set_serial_status(serials, 'IN_STOCK')  - Release: only FLOATING serials go back.
--
-- The Item Ledger is NOT touched. Floating serials don't count as stock (Inventory Summary / Serial
-- Inventory Journal count IN_STOCK only) - Release them before counting that item.
--
-- Replaces supabase_serial_bulk_delete.sql (never run). Run AFTER supabase_staff_users_table.sql
-- (is_admin_authorized). Safe to re-run.

drop function if exists public.admin_bulk_delete_serials(text, text, text[]);
drop function if exists public.admin_bulk_set_serial_status(text, text, text[], text);

create or replace function public.admin_bulk_set_serial_status(
  p_admin_username text,
  p_admin_password text,
  p_serial_nos text[],
  p_status text
)
returns table(serial_no text, changed boolean, reason text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_status text := upper(trim(coalesce(p_status, '')));
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Only a Super User can change serials in bulk.';
  end if;
  if v_status not in ('FLOATING', 'IN_STOCK') then
    raise exception 'Bulk status can only be FLOATING or IN_STOCK.';
  end if;
  if coalesce(array_length(p_serial_nos, 1), 0) = 0 then
    raise exception 'No serials selected.';
  end if;
  if array_length(p_serial_nos, 1) > 2000 then
    raise exception 'Change at most 2000 serials at a time.';
  end if;

  return query
  with wanted as (
    select distinct trim(x) as sn from unnest(p_serial_nos) as x where nullif(trim(x), '') is not null
  ),
  current_rows as (
    select w.sn, s."RunningSerialNo", upper(coalesce(s."Status", '')) as status
    from wanted w
    left join public."ItemSerialTracking" s on s."SerialNo" = w.sn
  ),
  done as (
    update public."ItemSerialTracking" s
      set "Status" = v_status, "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
      from current_rows c
      where s."RunningSerialNo" = c."RunningSerialNo"
        and case when v_status = 'FLOATING'
                 then c.status not in ('SOLD', 'IN_TRANSIT', 'FLOATING')
                 else c.status = 'FLOATING' end
      returning s."SerialNo"
  )
  select c.sn,
         (d."SerialNo" is not null),
         case
           when d."SerialNo" is not null then null
           when c."RunningSerialNo" is null then 'Not found'
           when v_status = 'IN_STOCK' then 'Not floating (' || lower(c.status) || ')'
           when c.status = 'SOLD' then 'Sold - tied to a sale'
           when c.status = 'IN_TRANSIT' then 'In transit on a Transfer Order'
           when c.status = 'FLOATING' then 'Already floating'
           else 'Not changed'
         end
  from current_rows c
  left join done d on d."SerialNo" = c.sn
  order by c.sn;
end;
$$;

grant execute on function public.admin_bulk_set_serial_status(text, text, text[], text) to anon;
