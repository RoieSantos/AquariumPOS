-- One-off: create vendor V020 IsdaPoko (2026-11-21), with its Metrobank account set as the
-- Xendit payout account so Purchase Order payments can be sent to it.
-- Safe to re-run: does nothing if V020 already exists.

insert into public."Vendors" (
    "VendorCode", "Name", "ContactPerson", "Phone", "Email", "Address", "Notes", "IsActive",
    "PayoutChannelCode", "PayoutChannelName", "PayoutAccountNumber", "PayoutAccountName",
    "PayoutUpdatedBy", "PayoutUpdatedAtUtc"
)
values (
    'V020', 'IsdaPoko', 'MC Roice Malabanan', '09501347522', 'malabananmcroice@gmail.com',
    'Calamba City, Laguna', 'Contact age: 29', true,
    'PH_MET', 'Metrobank', '7363807790014', 'MC Roice Malabanan',
    'Claude (Roie request)', now()
)
on conflict ("VendorCode") do nothing;

select "VendorCode", "Name", "ContactPerson", "Phone", "Email", "Address", "Notes",
       "PayoutChannelCode", "PayoutAccountNumber", "PayoutAccountName"
from public."Vendors" where "VendorCode" = 'V020';
