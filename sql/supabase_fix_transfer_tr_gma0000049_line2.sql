-- Follow-up to supabase_fix_transfer_tr_gma0000049.sql - AQ-008 ClearSealant was silently skipped
-- because its actual stored SKU has a stray space after the hyphen ("AQ-008- ClearSealant", not
-- "AQ-008-ClearSealant" like the other rows), so the exact-match join in that script never found
-- it. Matches on Item No. + a space-stripped SKU comparison instead, so this one isn't sensitive to
-- that same quirk.
--
-- TARGET: AQ-008 ClearSealant (3 total) -> fully received: Shipped 3, Received 3.

begin;

alter table public."Transfer_Line" disable trigger "TR_Transfer_Line_ItemLedger";

update public."Transfer_Line" tl
   set "Qty Shipped" = 3,
       "Qty Received" = 3,
       "Qty To Ship" = null,
       "Qty To Receive" = null
  from public."Variants" var
 where tl."Document No." = 'TR-GMA0000049'
   and tl."Item No." = 'AQ-008'
   and tl."Variant ID" = var."VariationId"
   and replace(var."SKU", ' ', '') = 'AQ-008-ClearSealant';

alter table public."Transfer_Line" enable trigger "TR_Transfer_Line_ItemLedger";

commit;

-- Verification - expect 1 row: Qty Shipped = 3, Qty Received = 3.
select tl."Item No.", var."SKU", tl."Qty Shipped", tl."Qty Received", tl."Qty To Ship", tl."Qty To Receive"
from public."Transfer_Line" tl
left join public."Variants" var on var."VariationId" = tl."Variant ID"
where tl."Document No." = 'TR-GMA0000049' and tl."Item No." = 'AQ-008';
