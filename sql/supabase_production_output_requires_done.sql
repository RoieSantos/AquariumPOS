-- Production Orders: output can't be posted until the maker has marked Production Done - per "in the
-- production order dont allow to post output if the maker is not finished production done".
--
-- A Tank line needs ProductionOrders.TankDoneAtUtc, a Stand line StandDoneAtUtc (set by the maker's
-- Production Done button, cleared again by Undo / rework). Enforced as a trigger on
-- ProductionOrderOutputs - the row staff_post_production_output writes for every posted line - so it
-- holds whatever calls it. The raise rolls back the whole posting: no ledger entry, no serials.
-- Reversing output is unaffected (it doesn't insert here).
--
-- Run AFTER supabase_production_orders.sql. Safe to re-run.

create or replace function public._production_output_requires_done()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_part text;
  v_order public."ProductionOrders";
  v_maker text;
begin
  select l."Part" into v_part from public."ProductionOrderLines" l where l."LineNo" = new."LineNo";
  select * into v_order from public."ProductionOrders" where "No" = new."ProdOrderNo";

  if coalesce(v_part, 'tank') = 'stand' then
    if v_order."StandDoneAtUtc" is null then
      v_maker := v_order."StandMaker";
      raise exception 'The Stand Maker% hasn''t marked Production Done on % yet - output can be posted once they have.',
        coalesce(' (' || v_maker || ')', ''), new."ProdOrderNo";
    end if;
  elsif v_order."TankDoneAtUtc" is null then
    v_maker := v_order."TankMaker";
    raise exception 'The Tank Maker% hasn''t marked Production Done on % yet - output can be posted once they have.',
      coalesce(' (' || v_maker || ')', ''), new."ProdOrderNo";
  end if;

  return new;
end;
$$;

drop trigger if exists "TR_ProductionOrderOutputs_RequireDone" on public."ProductionOrderOutputs";
create trigger "TR_ProductionOrderOutputs_RequireDone"
  before insert on public."ProductionOrderOutputs"
  for each row execute function public._production_output_requires_done();
