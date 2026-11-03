-- Top cover jobs can go to a Tank Maker or a Stand Maker - per "can you mix it for stand maker and tank
-- maker.. meaning either both of them can be chosen" (about CUSTOM-TOPCOVER).
--
-- A top cover line (CUSTOM-TOPCOVER, "Allum Top Cover"...) still puts the order in the Stand slot
-- (_online_order_line_part / _advance_order_needs are unchanged). What changes is who can fill it:
--
--   1. _online_order_stand_is_cover_only / _advance_order_stand_is_cover_only (new) - the order has a
--      top cover line and no real stand line ("standard" / "standalone sump" don't count as a stand).
--   2. admin_assign_online_order_maker and staff_assign_advance_order_maker accept a Tank Maker in the
--      Stand slot when that's true. An order with a real stand still needs a Stand Maker there.
--      Patched into the LIVE function text, like supabase_order_now_line_notes.sql.
--
-- Production Done, My Assignments and Maker Assignments already go by the assigned username, not the
-- role, so a Tank Maker in the Stand slot sees and finishes the job with no other change.
-- The Online Orders page's Stand Maker dropdowns list Tank Makers under "Tank Makers (top cover only)".
--
-- Run AFTER supabase_online_order_staff_no_assign.sql and supabase_advance_order_production.sql. If
-- either of those is re-run, run this one again. Safe to re-run. Ends with one result query.

-- ---------------------------------------------------------------------------
-- 1. Cover-only helpers

create or replace function public._online_order_stand_is_cover_only(p_order_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(bool_or(t ~* 'top[[:space:]_-]*cover'), false)
     and not coalesce(bool_or(t ~* 'stand(?!ard|alone)'), false)
  from (
    select coalesce(ol."Description", '') || ' ' || coalesce(ol."ItemCode", '') as t
    from public."OnlineOrderLines" ol
    where ol."OrderID" = p_order_id
  ) l;
$$;
revoke execute on function public._online_order_stand_is_cover_only(text) from public, anon, authenticated;

create or replace function public._advance_order_stand_is_cover_only(p_no text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(bool_or(t ~* 'top[[:space:]_-]*cover'), false)
     and not coalesce(bool_or(t ~* 'stand(?!ard|alone)'), false)
  from (
    select coalesce(l."Description", '') || ' ' || coalesce(l."No", '') as t
    from public."AdvanceOrderLines" l
    where l."TransactionNo" = p_no
  ) l;
$$;
revoke execute on function public._advance_order_stand_is_cover_only(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Assign RPCs. Stops with an error, without patching, if the expected text isn't there.

do $patch$
declare
  v_sig regprocedure := 'public.admin_assign_online_order_maker(text, text, text, text, text)'::regprocedure;
  v_def text := pg_get_functiondef(v_sig);
  v_new text;
begin
  if v_def like '%_online_order_stand_is_cover_only%' then
    raise notice 'admin_assign_online_order_maker already patched - skipped.';
    return;
  end if;

  v_new := replace(v_def,
    $s$where "Username" = v_username and "IsActive" and v_staff_role = any("StaffRoles")$s$,
    $s$where "Username" = v_username and "IsActive"
      and (v_staff_role = any("StaffRoles")
           -- supabase_maker_top_cover_either_maker.sql: a top cover can go to a Tank Maker too.
           or (v_role = 'stand' and 'TankMaker' = any("StaffRoles")
               and public._online_order_stand_is_cover_only(p_order_id)))$s$);
  if v_new = v_def then raise exception 'admin_assign_online_order_maker patch: role check not found - nothing changed.'; end if;
  v_def := v_new;

  v_new := replace(v_def,
    $s$format('That user is not an active %s.', v_role_label)::text;$s$,
    $s$(format('That user is not an active %s.', v_role_label)
      || case when v_role = 'stand' then ' A Tank Maker can only take it when the order''s only stand work is a top cover.' else '' end)::text;$s$);
  if v_new = v_def then raise exception 'admin_assign_online_order_maker patch: error message not found - nothing changed.'; end if;

  execute v_new;
end
$patch$;

do $patch$
declare
  v_sig regprocedure := 'public.staff_assign_advance_order_maker(text, text, text, text, text)'::regprocedure;
  v_def text := pg_get_functiondef(v_sig);
  v_new text;
begin
  if v_def like '%_advance_order_stand_is_cover_only%' then
    raise notice 'staff_assign_advance_order_maker already patched - skipped.';
    return;
  end if;

  v_new := replace(v_def,
    $s$and (case v_role when 'tank' then 'TankMaker' else 'StandMaker' end) = any(coalesce("StaffRoles", '{}'))) then
    raise exception '% is not an active % Maker.', v_user, initcap(v_role);$s$,
    $s$and ((case v_role when 'tank' then 'TankMaker' else 'StandMaker' end) = any(coalesce("StaffRoles", '{}'))
              -- supabase_maker_top_cover_either_maker.sql: a top cover can go to a Tank Maker too.
              or (v_role = 'stand' and 'TankMaker' = any(coalesce("StaffRoles", '{}'))
                  and public._advance_order_stand_is_cover_only(p_no)))) then
    raise exception '% is not an active % Maker%', v_user, initcap(v_role),
      case when v_role = 'stand' then '. A Tank Maker can only take it when the order''s only stand work is a top cover.' else '.' end;$s$);
  if v_new = v_def then raise exception 'staff_assign_advance_order_maker patch: role check not found - nothing changed.'; end if;

  execute v_new;
end
$patch$;

notify pgrst, 'reload schema';

select 'admin_assign_online_order_maker accepts Tank Maker for top cover' as section,
       (pg_get_functiondef('public.admin_assign_online_order_maker(text, text, text, text, text)'::regprocedure)
          like '%_online_order_stand_is_cover_only%')::text as detail
union all
select 'staff_assign_advance_order_maker accepts Tank Maker for top cover',
       (pg_get_functiondef('public.staff_assign_advance_order_maker(text, text, text, text, text)'::regprocedure)
          like '%_advance_order_stand_is_cover_only%')::text
union all
select 'still refuses Online Order Staff (system check)',
       (pg_get_functiondef('public.admin_assign_online_order_maker(text, text, text, text, text)'::regprocedure)
          like '%"OnlineOrderStaff"%')::text;
