-- =====================================================================================
-- LOCAL POS (SQL Server / SSMS) - show everything stored for one receipt (READ-ONLY)
-- Run on the STORE POS database (not Supabase). Nothing is changed.
--
-- Change @ReceiptNo and run the whole file. SSMS shows one result grid per section:
--   1. TransactionHeader      - the sale header (totals, status, cashier, SentToOnline)
--   2. ItemLedgerEntry        - the item lines (incl. any "-REV" reversal / void lines)
--   3. TransPaymentEntry      - the payments / tenders
--   4. InstoreOnlineOrderMap  - Pancake sync status (Pancake order id, last action/response)
--   5. AdvanceOrderHeader     - only if the receipt is an advance order
--   6. ItemSerialTracking     - serials sold on this receipt (if any)
-- Sections 4-6 are skipped automatically if that table/column doesn't exist on this POS.
-- =====================================================================================

DECLARE @ReceiptNo NVARCHAR(50) = N'RS-0000011010';

-- Some rows store the TransactionNo instead of the ReceiptNo, so look both up.
DECLARE @TransactionNo NVARCHAR(200) =
    (SELECT TOP 1 CAST(TransactionNo AS NVARCHAR(200)) FROM TransactionHeader WHERE ReceiptNo = @ReceiptNo);

-- 1. Header
SELECT '1. TransactionHeader' AS section, *
FROM TransactionHeader
WHERE ReceiptNo = @ReceiptNo;

-- 2. Item lines (sale + reversal lines)
SELECT '2. ItemLedgerEntry' AS section, *
FROM ItemLedgerEntry
WHERE DocumentNo IN (@ReceiptNo, @ReceiptNo + N'-REV', @TransactionNo)
ORDER BY ID;

-- 3. Payments
SELECT '3. TransPaymentEntry' AS section, *
FROM TransPaymentEntry
WHERE ReceiptNo = @ReceiptNo;

-- 4. Pancake sync map
IF OBJECT_ID(N'dbo.InstoreOnlineOrderMap') IS NOT NULL
    EXEC sp_executesql
        N'SELECT ''4. InstoreOnlineOrderMap'' AS section, * FROM dbo.InstoreOnlineOrderMap WHERE LocalReceiptNo = @r',
        N'@r NVARCHAR(50)', @r = @ReceiptNo;

-- 5. Advance order (if this receipt is one)
IF OBJECT_ID(N'dbo.AdvanceOrderHeader') IS NOT NULL
    EXEC sp_executesql
        N'SELECT ''5. AdvanceOrderHeader'' AS section, * FROM dbo.AdvanceOrderHeader WHERE ReceiptNo = @r OR TransactionNo = @r',
        N'@r NVARCHAR(50)', @r = @ReceiptNo;

-- 6. Serial numbers sold on this receipt
IF COL_LENGTH(N'dbo.ItemSerialTracking', N'SoldReceiptNo') IS NOT NULL
    EXEC sp_executesql
        N'SELECT ''6. ItemSerialTracking'' AS section, * FROM dbo.ItemSerialTracking WHERE SoldReceiptNo = @r',
        N'@r NVARCHAR(50)', @r = @ReceiptNo;
