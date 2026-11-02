-- POS Online Pay: card fee. Per "they can choose credit cards.. but we charge 5% for it is that covered".
--
-- The POS adds the fee on top for card tenders. Each tender it sends now has card_fee next to amount.
-- pos_record_online_order_payment only reads amount, so the fee never touches the order's Amount Paid /
-- Balance, and it is unchanged here. This trigger totals the fee into its own column on the payment log.
--
-- Run AFTER supabase_pos_online_pay.sql. Needs the new POS build (OnlinePayForm.cs). Safe to re-run.

alter table public."OnlineOrderStorePayments" add column if not exists "CardFee" numeric(18, 2) not null default 0;

create or replace function public._pos_pay_set_card_fee()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new."CardFee" := coalesce((
    select sum(coalesce(nullif(trim(coalesce(t ->> 'card_fee', '')), '')::numeric, 0))
    from jsonb_array_elements(new."Tenders") t), 0);
  return new;
end;
$$;

revoke all on function public._pos_pay_set_card_fee() from public, anon, authenticated;

drop trigger if exists trg_pos_pay_set_card_fee on public."OnlineOrderStorePayments";
create trigger trg_pos_pay_set_card_fee
before insert or update of "Tenders" on public."OnlineOrderStorePayments"
for each row execute function public._pos_pay_set_card_fee();

-- Verification - one result: the column and trigger are in place.
select 'column' as section, c.column_name::text as item, c.data_type::text as value
from information_schema.columns c
where c.table_schema = 'public' and c.table_name = 'OnlineOrderStorePayments' and c.column_name = 'CardFee'
union all
select 'trigger', t.tgname::text, case when t.tgenabled <> 'D' then 'enabled' else 'DISABLED' end
from pg_trigger t
where t.tgrelid = 'public."OnlineOrderStorePayments"'::regclass and t.tgname = 'trg_pos_pay_set_card_fee';
