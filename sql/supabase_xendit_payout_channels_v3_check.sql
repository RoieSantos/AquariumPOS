-- READ-ONLY check before turning Payouts v3 on (PortalSettings XENDIT_PAYOUT_API = 'v3').
-- Every payout destination in use must have a v3 routing pair, or its payouts stay on legacy /v2/payouts (and the
-- USD 250 / month legacy-API fee may still apply - Xendit ticket 2805116).
-- v3 pairs confirmed by Xendit support 2026-11-19 - keep in step with PH_PAYOUT_DESTINATIONS in
-- supabase/functions/_shared/xendit-payouts.ts.
-- Owner withdrawal accounts live in the XENDIT_OWNER_ACCOUNTS secret, not in the database - check those by hand.
-- Safe to re-run. Ends with ONE result.

with v3 (code, routing) as (
  values ('PH_GCASH', 'WALLET PH_GCASH'),
         ('PH_PAYMAYA', 'WALLET PH_PAYMAYA'),
         ('PH_BPI', 'SWIFT BPGOPHM1'),
         ('PH_BDO', 'SWIFT BNORPHMM'),
         ('PH_BDO_NETWORK_BANK', 'SWIFT ONNRPHM1'),
         ('PH_MAYA_BANK', 'SWIFT PAPHPHM1')
),
in_use as (
  select 'employee account' as source, su."PayoutChannelCode" as code,
         su."DisplayName" || coalesce(' (' || su."Username" || ')', '') as who
    from public."StaffUsers" su
   where su."PayViaXendit" and su."PayoutChannelCode" is not null
  union all
  select 'payout last 90 days (' || x."Kind" || ')', x."ChannelCode", coalesce(x."DisplayName", x."Username", '-')
    from public."XenditPayouts" x
   where x."CreatedAtUtc" > now() - interval '90 days' and not x."IsTest"
)
select case when v3.code is null then '1 NOT ON v3 - stays legacy' else '2 ready for v3' end as section,
       u.code || coalesce(' -> ' || v3.routing, '') as channel,
       u.source || ': ' || string_agg(distinct u.who, ', ') as detail
  from in_use u
  left join v3 on v3.code = upper(u.code)
 group by 1, u.code, v3.routing, u.source
union all
select '0 setting', 'XENDIT_PAYOUT_API',
       coalesce((select "SettingValue" from public."PortalSettings" where "SettingKey" = 'XENDIT_PAYOUT_API'), 'MISSING')
order by 1, 2;
