-- Xendit Payouts v3, behind a switch (Xendit support ticket 2805116: v2 may carry an extra fee; v3 adds
-- processor_reference, receipt_notification and estimated_arrival_time).
--
--   - PortalSettings 'XENDIT_PAYOUT_API': 'v2' (default - nothing changes) or 'v3'. With 'v3', NEW payouts to an
--     e-wallet (GCash / Maya / GrabPay / ShopeePay) go through POST /v3/payouts; banks stay on v2 until Xendit
--     confirms the v3 routing values for PH banks. Salary, cash advance and owner withdrawals all follow it.
--   - XenditPayouts.ApiVersion: the API each payout was first sent with. A re-send (a 'Creating' row whose first
--     call got no answer) always goes to that same API with the same Idempotency-key, so switching the setting
--     midway can't pay anyone twice. Every existing row is 'v2'.
--   - _payout_api_version: Edge Function helper that stamps a new row / reads a row's API.
--   - v3 statuses are stored in the v2 names the pages already use (rejected / expired = FAILED); the raw v3
--     answer, with processor_reference, stays in LastResponse.
--
-- Run AFTER supabase_xendit_payroll_payouts.sql, supabase_xendit_cash_advance_payouts.sql and
-- supabase_xendit_owner_payouts.sql. Safe to re-run (keeps the setting's current value). Needs the redeployed
-- xendit-payroll-payout, xendit-owner-payout and xendit-webhook Edge Functions. Ends with ONE result.

alter table public."XenditPayouts" add column if not exists "ApiVersion" text not null default 'v2';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'CK_XenditPayouts_ApiVersion') then
    alter table public."XenditPayouts" add constraint "CK_XenditPayouts_ApiVersion" check ("ApiVersion" in ('v2', 'v3'));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- p_api set: stamp it on a row that hasn't reached Xendit yet (new 'Creating' row, no Xendit ID).
-- Always returns the row's API (null = no such payout).

create or replace function public._payout_api_version(p_payout_id uuid, p_api text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_api text;
begin
  if p_api in ('v2', 'v3') then
    update public."XenditPayouts"
       set "ApiVersion" = p_api
     where "PayoutID" = p_payout_id and "Status" = 'Creating' and "XenditPayoutID" is null and "LastResponse" is null;
  end if;
  select "ApiVersion" into v_api from public."XenditPayouts" where "PayoutID" = p_payout_id;
  return v_api;
end;
$$;

revoke all on function public._payout_api_version(uuid, text) from public, anon, authenticated;
grant execute on function public._payout_api_version(uuid, text) to service_role;

-- ---------------------------------------------------------------------------
-- The switch. Left at its current value on a re-run. To turn v3 on (e-wallets only), run just:
--   update public."PortalSettings" set "SettingValue" = 'v3', "UpdatedAtUtc" = now() where "SettingKey" = 'XENDIT_PAYOUT_API';
-- and back to v2 the same way with 'v2'.

insert into public."PortalSettings" ("SettingKey", "SettingValue", "Description", "IsPublicToStaff")
values ('XENDIT_PAYOUT_API', 'v2',
        'Xendit payouts API: v2, or v3 (e-wallet payouts go through Payouts v3; banks stay on v2). See sql/supabase_xendit_payouts_v3.sql.',
        false)
on conflict ("SettingKey") do nothing;

notify pgrst, 'reload schema';

-- Check - one result.
select 'ApiVersion column' as section,
       case when exists (select 1 from information_schema.columns where table_name = 'XenditPayouts' and column_name = 'ApiVersion')
            then 'ready' else 'MISSING' end as value
union all
select 'edge function helper',
       case when to_regprocedure('public._payout_api_version(uuid, text)') is not null then 'ready' else 'MISSING' end
union all
select 'XENDIT_PAYOUT_API', coalesce((select "SettingValue" from public."PortalSettings" where "SettingKey" = 'XENDIT_PAYOUT_API'), 'MISSING')
union all
select 'payouts by API', coalesce(string_agg("ApiVersion" || ': ' || n, ', '), 'none yet')
  from (select "ApiVersion", count(*) as n from public."XenditPayouts" group by 1 order by 1) t;
