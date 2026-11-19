-- Turn Xendit Payouts v3 on (2026-11-19): new payouts to the destinations in PH_PAYOUT_DESTINATIONS
-- (_shared/xendit-payouts.ts) go through /v3/payouts; any other channel (e.g. PH_GOTYME) stays on /v2/payouts.
-- Back to v2: run the same update with 'v2'. Run AFTER supabase_xendit_payouts_v3.sql. Safe to re-run.

update public."PortalSettings" set "SettingValue" = 'v3', "UpdatedBy" = 'claude-code', "UpdatedAtUtc" = now()
 where "SettingKey" = 'XENDIT_PAYOUT_API';

select 'XENDIT_PAYOUT_API' as section, "SettingValue" as value
  from public."PortalSettings" where "SettingKey" = 'XENDIT_PAYOUT_API';
