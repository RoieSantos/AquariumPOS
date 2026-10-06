-- =====================================================================================
-- LOCAL POS (SQL Server / SSMS) - fix a mis-punched item on a posted receipt
-- Run on the STORE POS database (not Supabase).
--
-- Case: RS-0000011082 - cashier punched 932 (BIO-SPONGEFILTER-INFINITY) instead of FT-043.
-- The wrong item also made Pancake reject the receipt (500), so it never synced.
--
-- What it does (one transaction, all-or-nothing):
--   1. Swaps the ItemLedgerEntry line(s) for @WrongCode on the receipt to @RightCode
--      (ItemCode, VariationId, Description, UnitCost/TotalCost from the Items card).
--      Price / Discount / Gross / Net are kept AS SOLD - the customer paid that amount,
--      so the receipt total and cash still match.
--   2. Gives the stock back to @WrongCode and takes it from @RightCode (Items.QuantityInStock),
--      the same thing posting did to the wrong item.
--   3. Resets SentToOnline = 0 so Resend Selected / Retry Failed will push it.
--
-- HOW TO RUN: first run with @Apply = 0 (preview only, nothing changes). Check the
-- "BEFORE" / "AFTER" result grids. Then set @Apply = 1 and run again to commit.
-- After it commits: POS > Transaction List > select the receipt > Resend Selected.
-- =====================================================================================

DECLARE @ReceiptNo  NVARCHAR(50) = N'RS-0000011082';
DECLARE @WrongCode  NVARCHAR(50) = N'932';
DECLARE @RightCode  NVARCHAR(50) = N'FT-043';
DECLARE @Apply      BIT          = 0;   -- 0 = preview only, 1 = commit

SET XACT_ABORT ON;

-- ---- Sanity checks -----------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM TransactionHeader WHERE ReceiptNo = @ReceiptNo)
    THROW 50001, 'Receipt not found in TransactionHeader.', 1;

IF NOT EXISTS (SELECT 1 FROM ItemLedgerEntry WHERE DocumentNo = @ReceiptNo AND ItemCode = @WrongCode)
    THROW 50002, 'The wrong item code is not on this receipt (already fixed?).', 1;

IF NOT EXISTS (SELECT 1 FROM Items WHERE Code = @RightCode)
    THROW 50003, 'The correct item code does not exist in Items.', 1;

IF EXISTS (SELECT 1 FROM Items WHERE Code = @RightCode AND ISNULL(VariationId, '') = '')
    THROW 50004, 'The correct item has no VariationId - run Sync Product Variations in the POS first, or Pancake will not know the item.', 1;

-- ---- BEFORE --------------------------------------------------------------------------
SELECT 'BEFORE' AS Stage, ile.ID, ile.ItemCode, ile.VariationId, ile.Description,
       ile.Quantity, ile.Price, ile.Discount, ile.GrossAmount, ile.NetAmount, ile.UnitCost, ile.TotalCost,
       (SELECT QuantityInStock FROM Items WHERE Code = @WrongCode) AS WrongItemStock,
       (SELECT QuantityInStock FROM Items WHERE Code = @RightCode) AS RightItemStock,
       (SELECT Price FROM Items WHERE Code = @RightCode) AS RightItemCurrentPrice
FROM ItemLedgerEntry ile
WHERE ile.DocumentNo = @ReceiptNo AND ile.ItemCode IN (@WrongCode, @RightCode);

BEGIN TRANSACTION;

DECLARE @Qty INT = (SELECT SUM(ABS(Quantity)) FROM ItemLedgerEntry WHERE DocumentNo = @ReceiptNo AND ItemCode = @WrongCode);

UPDATE ile
SET ItemCode    = r.Code,
    VariationId = r.VariationId,
    Description = LEFT(ISNULL(NULLIF(r.Description, ''), r.Name) + ' - ' + r.Code, 500),
    UnitCost    = ISNULL(r.Cost, 0),
    TotalCost   = ISNULL(r.Cost, 0) * ABS(ile.Quantity)
FROM ItemLedgerEntry ile
CROSS JOIN (SELECT Code, Name, Description, Cost, VariationId FROM Items WHERE Code = @RightCode) r
WHERE ile.DocumentNo = @ReceiptNo AND ile.ItemCode = @WrongCode;

UPDATE Items SET QuantityInStock = ISNULL(QuantityInStock, 0) + @Qty, UpdatedDate = GETDATE() WHERE Code = @WrongCode;
UPDATE Items SET QuantityInStock = ISNULL(QuantityInStock, 0) - @Qty, UpdatedDate = GETDATE() WHERE Code = @RightCode;

UPDATE TransactionHeader SET SentToOnline = 0 WHERE ReceiptNo = @ReceiptNo;

-- ---- AFTER (inside the transaction) ---------------------------------------------------
SELECT 'AFTER' AS Stage, ile.ID, ile.ItemCode, ile.VariationId, ile.Description,
       ile.Quantity, ile.Price, ile.Discount, ile.GrossAmount, ile.NetAmount, ile.UnitCost, ile.TotalCost,
       (SELECT QuantityInStock FROM Items WHERE Code = @WrongCode) AS WrongItemStock,
       (SELECT QuantityInStock FROM Items WHERE Code = @RightCode) AS RightItemStock,
       CASE WHEN @Apply = 1 THEN 'COMMITTED' ELSE 'PREVIEW ONLY - rolled back, set @Apply = 1 to save' END AS Result
FROM ItemLedgerEntry ile
WHERE ile.DocumentNo = @ReceiptNo AND ile.ItemCode IN (@WrongCode, @RightCode);

IF @Apply = 1 COMMIT TRANSACTION; ELSE ROLLBACK TRANSACTION;
