-- One-off (2026-11-21): the 4 IsdaPoko (V020) PO fish that had NO primary vendor get V020 as primary.
-- Only touches rows where VendorCode is still null, so it never overwrites an existing primary vendor.
update public."Items"
set "VendorCode" = 'V020', "PortalEditedAtUtc" = now(), "PortalEditedBy" = 'Claude (Roie request)'
where "Code" in ('F-020','F-033','F-087','F-97') and "VendorCode" is null;

select "Code", "Name", "VendorCode" from public."Items" where "Code" in ('F-020','F-033','F-087','F-97') order by "Code";
