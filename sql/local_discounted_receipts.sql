-- =====================================================================================
-- LOCAL POS (SQL Server / SSMS) - list every receipt that has a discount (READ-ONLY)
-- Run on the STORE POS database (not Supabase). Nothing is changed.
--
-- A receipt counts as discounted if the header Discount <> 0 OR any of its item lines
-- (ItemLedgerEntry) has Discount <> 0. Also shows the Pancake sync status, so you can spot
-- discounted sales that Pancake rejected ("[discount_each_product]: is invalid", fixed
-- 2026-10-14 - those need Resend Selected after the POS update).
--
-- DiscountSource: the POS saves TransactionHeader.DiscountDescription = 'Wholesale Discount'
-- when the Wholesale button applied the discount; a manual discount leaves it empty.
--   WHOLESALE = Wholesale button     MANUAL = cashier-entered discount
--   (any other text in DiscountDescription is shown as-is)
--
-- Set the date range / source filter below (NULL = no limit) and run the whole file.
-- =====================================================================================

DECLARE @FromDate DATE         = NULL;   -- e.g. '2026-10-01'
DECLARE @ToDate   DATE         = NULL;   -- e.g. '2026-10-14'
DECLARE @Source   NVARCHAR(20) = NULL;   -- NULL = all, 'MANUAL' or 'WHOLESALE'

WITH LineDiscounts AS (
    SELECT DocumentNo,
           COUNT(*)                AS DiscountedLines,
           SUM(ABS(Discount))      AS LineDiscountTotal
    FROM ItemLedgerEntry
    WHERE ISNULL(Discount, 0) <> 0
    GROUP BY DocumentNo
),
Receipts AS (
SELECT
    CASE
        WHEN LTRIM(RTRIM(ISNULL(th.DiscountDescription, ''))) = '' THEN 'MANUAL'
        WHEN th.DiscountDescription = 'Wholesale Discount'          THEN 'WHOLESALE'
        ELSE th.DiscountDescription
    END                                AS DiscountSource,
    th.ReceiptNo,
    th.TransactionNo,
    th.[Date],
    th.[Time],
    th.[Type],
    th.UserID                          AS Cashier,
    th.GrossAmount,
    th.Discount                        AS HeaderDiscount,
    ISNULL(ld.LineDiscountTotal, 0)    AS LineDiscountTotal,
    ISNULL(ld.DiscountedLines, 0)      AS DiscountedLines,
    th.NetAmount,
    th.SentToOnline,
    m.OnlineOrderId                    AS PancakeOrderId,
    m.LastAction                       AS PancakeLastAction,
    LEFT(m.LastResponse, 300)          AS PancakeLastResponse
FROM TransactionHeader th
LEFT JOIN LineDiscounts ld
       ON ld.DocumentNo = th.ReceiptNo
LEFT JOIN dbo.InstoreOnlineOrderMap m
       ON m.LocalReceiptNo = th.ReceiptNo
WHERE (ISNULL(th.Discount, 0) <> 0 OR ld.DocumentNo IS NOT NULL)
  AND (@FromDate IS NULL OR th.[Date] >= @FromDate)
  AND (@ToDate   IS NULL OR th.[Date] <= @ToDate)
)
SELECT *
FROM Receipts
WHERE @Source IS NULL OR DiscountSource = @Source
ORDER BY [Date] DESC, [Time] DESC, ReceiptNo DESC;
