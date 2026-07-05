$connStr = "Server=LAPTOP-20MJVLDK;Database=RSPETSTOPQ12026updated;Trusted_Connection=True;Connection Timeout=30;"
$query = @"
-- 1) TOP 5 latest TransactionHeader rows
SELECT TOP 5 ReceiptNo, Type, NetAmount, Discount, SentToOnline, Description, [Date], [Time]
FROM TransactionHeader
ORDER BY [Date] DESC, [Time] DESC;

-- 2) For the latest SALES receipt, count ItemLedgerEntry rows
DECLARE @LatestSalesReceipt NVARCHAR(50);
SELECT TOP 1 @LatestSalesReceipt = ReceiptNo 
FROM TransactionHeader 
WHERE Type LIKE '%SALE%' 
ORDER BY [Date] DESC, [Time] DESC;

SELECT COUNT(*) as ItemCount, @LatestSalesReceipt as ReceiptNo FROM ItemLedgerEntry WHERE DocumentNo = @LatestSalesReceipt;

SELECT TOP 10 ItemCode, Description, Quantity, Price, SentToOnline
FROM ItemLedgerEntry
WHERE DocumentNo = @LatestSalesReceipt;

-- 3) dbo.InstoreOnlineOrderMap
IF OBJECT_ID('dbo.InstoreOnlineOrderMap', 'U') IS NOT NULL
BEGIN
    SELECT TOP 5 LocalReceiptNo, OnlineOrderId, LocalType, LastAction, UpdatedAtUtc, CAST(LEFT(LastResponse, 300) AS NVARCHAR(300)) as LastResponse
    FROM dbo.InstoreOnlineOrderMap
    ORDER BY UpdatedAtUtc DESC;
END
"@

$connection = New-Object System.Data.SqlClient.SqlConnection($connStr)
$connection.Open()
$command = $connection.CreateCommand()
$command.CommandText = $query
$adapter = New-Object System.Data.SqlClient.SqlDataAdapter($command)
$dataset = New-Object System.Data.DataSet
$adapter.Fill($dataset) | Out-Null
$connection.Close()

$dataset.Tables[0] | Format-Table -AutoSize
$dataset.Tables[1] | Format-Table -AutoSize
$dataset.Tables[2] | Format-Table -AutoSize
$dataset.Tables[3] | Format-Table -AutoSize
