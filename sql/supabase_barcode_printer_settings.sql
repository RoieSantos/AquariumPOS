-- Barcode printer (QZ Tray) settings - per "i have a barcode printer.. can we add a setup in the general
-- setup? so everytime we print a barcode it will print on the barcode printer, then for the order
-- printout it will proceed on the normal printer".
--
-- A web page can't pick a printer on its own, so barcode labels go through QZ Tray (https://qz.io), a
-- small free print helper installed on the PC that prints. The portal (docs/js/labelPrinter.js) sends
-- each label straight to the printer named here - no print dialog. Everything else (order printouts)
-- still uses the browser's normal print dialog / normal printer.
--
-- Two PortalSettings rows, both readable by any staff (IsPublicToStaff) through
-- admin_get_public_portal_setting, edited from General Setup -> Barcode Printer:
--   BARCODE_PRINTER_NAME - the printer's name exactly as Windows / QZ Tray lists it.
--   QZ_CERTIFICATE       - the PUBLIC certificate (PEM) QZ Tray trusts, so it prints silently instead
--                          of asking "Allow this site?" every time. Public by design - it's safe here.
-- The matching PRIVATE key is NOT stored here: it's the QZ_PRIVATE_KEY secret of the qz-sign Edge
-- Function (supabase/functions/qz-sign), which signs each print request server-side.
--
-- Run AFTER supabase_portal_settings_table.sql. Safe to re-run (never overwrites a value you set).

insert into public."PortalSettings" ("SettingKey", "SettingValue", "Description", "IsPublicToStaff")
select 'BARCODE_PRINTER_NAME', '', 'Barcode / label printer name for serial labels (QZ Tray). Set from General Setup -> Barcode Printer.', true
where not exists (select 1 from public."PortalSettings" where "SettingKey" = 'BARCODE_PRINTER_NAME');

insert into public."PortalSettings" ("SettingKey", "SettingValue", "Description", "IsPublicToStaff")
select 'QZ_CERTIFICATE', '', 'Public certificate (PEM) QZ Tray trusts for silent printing. Its private key is the qz-sign Edge Function secret QZ_PRIVATE_KEY.', true
where not exists (select 1 from public."PortalSettings" where "SettingKey" = 'QZ_CERTIFICATE');

-- Label layout (per "how can we adjust the barcode printout?") - JSON of js/labelPrinter.js's
-- DEFAULT_LAYOUT keys (size, offset, rotation, text size, lines, barcode size, copies). Empty = defaults
-- (100 x 30 mm, the desktop's label). Edited from General Setup -> Barcode Printer -> Label layout.
insert into public."PortalSettings" ("SettingKey", "SettingValue", "Description", "IsPublicToStaff")
select 'BARCODE_LABEL_LAYOUT', '', 'Serial label layout (size, offset, rotation, text size...) as JSON. Edit from General Setup -> Barcode Printer -> Label layout.', true
where not exists (select 1 from public."PortalSettings" where "SettingKey" = 'BARCODE_LABEL_LAYOUT');

-- All three must be readable by staff (the maker / manager printing), not just super users.
update public."PortalSettings" set "IsPublicToStaff" = true
where "SettingKey" in ('BARCODE_PRINTER_NAME', 'QZ_CERTIFICATE', 'BARCODE_LABEL_LAYOUT');
