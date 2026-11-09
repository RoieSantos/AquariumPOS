-- QR Ph payment method - per "can you add that QRPH tender". The desktop POS now adds a local QRPH tender
-- on open (MainForm.cs); this names it on the portal so a walk-in paid by manual QR Ph (POS offline) shows
-- "QR Ph" under Paid Via instead of "Unnamed (QRPH)". Also names GCASH / BANK if they have no name yet.
-- Online QR Ph / GCash / Bank Transfer payments go through Xendit and are recorded as XENDIT.
--
-- Run AFTER supabase_payment_methods_master.sql. Safe to re-run; never overwrites a name staff already set.

insert into public."PaymentMethods" ("Code", "Name", "MethodType", "Source")
values
  ('QRPH',  'QR Ph',         'Bank', 'POS'),
  ('GCASH', 'GCash',         'Bank', 'POS'),
  ('BANK',  'Bank Transfer', 'Bank', 'POS')
on conflict ("Code") do update
  set "Name" = coalesce(nullif(trim(public."PaymentMethods"."Name"), ''), excluded."Name");

select "Code", "Name", "MethodType", "Source", "IsActive"
from public."PaymentMethods"
where "Code" in ('QRPH', 'GCASH', 'BANK', 'XENDIT')
order by "Code";
