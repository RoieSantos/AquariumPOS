-- Serial Tracker: MAKER column - per "in the Serial tracker can you show who is the maker?".
--
--   staff_get_serial_makers(user, pass, serial_nos[]) -> serial_no, maker, maker_name, part, source
--
-- Who built the unit, from where the serial came from:
--   1. Production Order output (ProductionOrderOutputSerials -> the output's line -> its order): the
--      order's Tank Maker for a tank line, Stand Maker for a stand line. source = the PRD number.
--   2. A serial created at Ready to Ship for an online order ("+ New serial" - SourceDocumentNo is the
--      order): that order's Assigned Tank / Stand Maker, by the same stand / top-cover rule as
--      _production_line_part on the serial's item code + description. source = the order id.
-- Serials from anywhere else (desktop-created, purchased...) have no maker and are left out.
--
-- docs/js/serialTracker.js calls it for the rows on screen. Run AFTER supabase_production_orders.sql.
-- Safe to re-run.

drop function if exists public.staff_get_serial_makers(text, text, text[]);

create or replace function public.staff_get_serial_makers(
  p_admin_username text,
  p_admin_password text,
  p_serial_nos text[]
)
returns table(serial_no text, maker text, maker_name text, part text, source text)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with wanted as (
      select s."RunningSerialNo", s."SerialNo", s."ItemCode", s."ItemDescription", s."SourceDocumentNo"
      from public."ItemSerialTracking" s
      where s."SerialNo" = any(coalesce(p_serial_nos, '{}'))
    ),
    from_production as (
      select w."SerialNo" as serial_no,
             case l."Part" when 'stand' then po."StandMaker" else po."TankMaker" end as maker,
             l."Part"::text as part,
             po."No"::text as source
      from wanted w
      join public."ProductionOrderOutputSerials" os on os."RunningSerialNo" = w."RunningSerialNo"
      join public."ProductionOrderOutputs" o on o."EntryNo" = os."EntryNo"
      join public."ProductionOrderLines" l on l."LineNo" = o."LineNo"
      join public."ProductionOrders" po on po."No" = o."ProdOrderNo"
    ),
    from_online as (
      select w."SerialNo" as serial_no,
             case public._production_line_part(w."ItemDescription", w."ItemCode")
               when 'stand' then oo."AssignedStandMaker" else oo."AssignedTankMaker" end as maker,
             public._production_line_part(w."ItemDescription", w."ItemCode") as part,
             oo."OrderID"::text as source
      from wanted w
      join public."OnlineOrders" oo on oo."OrderID"::text = w."SourceDocumentNo"
      where not exists (select 1 from from_production p where p.serial_no = w."SerialNo")
    ),
    found as (
      select * from from_production
      union all
      select * from from_online
    )
    select f.serial_no::text, nullif(trim(f.maker), '')::text,
           coalesce(nullif(trim(su."DisplayName"), ''), nullif(trim(f.maker), ''))::text,
           f.part, f.source
    from found f
    left join public."StaffUsers" su on su."Username" = f.maker;
end;
$$;

grant execute on function public.staff_get_serial_makers(text, text, text[]) to anon;

notify pgrst, 'reload schema';
