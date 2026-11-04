-- Read-only check: was a Tender Declaration's "Declared Cash" made of more than one count?
-- If a declaration attempt is cut off (POS closed / crashed at the Short/Over reason prompt), its
-- TenderDeclLines are already saved with the new EODID but no header is written, so the next attempt
-- reuses the same EODID and the sync adds both counts together - a fake "Over" with no reason.
-- More than one ReceiptNo under one EODID = that happened. Ends with one result query.

select l."Warehouse",
       l."EODID",
       l."ReceiptNo",
       min(h."ReceiptNo") as header_receipt,
       sum(l."TotalAmount") as counted,
       min(h."DeclaredCash") as portal_declared,
       min(h."ExpectedCash") as portal_expected,
       min(h."Variance") as portal_variance,
       min(h."VarianceReason") as reason
from public."TenderDeclarationLines" l
join public."TenderDeclarationHeader" h on h."Warehouse" = l."Warehouse" and h."EODID" = l."EODID"
where l."EODID" in (
        select "EODID" from public."TenderDeclarationLines"
        group by "Warehouse", "EODID"
        having count(distinct "ReceiptNo") > 1)
group by l."Warehouse", l."EODID", l."ReceiptNo"
order by l."EODID" desc, l."ReceiptNo";
