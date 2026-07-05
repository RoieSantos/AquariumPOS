$connectionString = "Server=LAPTOP-20MJVLDK;Database=RSPETSTOPQ12026updated;Trusted_Connection=True;Connection Timeout=30;"
$query1 = "SELECT ItemCode, Description, Quantity, Price, GrossAmount, NetAmount, VariationId, DocumentType, ReceiptNo, DocumentNo FROM ItemLedgerEntry WHERE DocumentNo = 'RS-0000006687'"
$query3 = "SELECT Code, Name, Description, VariationId, IsActive FROM Items WHERE Code IN (SELECT ItemCode FROM ItemLedgerEntry WHERE DocumentNo = 'RS-0000006687')"

$connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
try {
    $connection.Open()
    $cmd1 = $connection.CreateCommand()
    $cmd1.CommandText = $query1
    $adapter1 = New-Object System.Data.SqlClient.SqlDataAdapter($cmd1)
    $dt1 = New-Object System.Data.DataTable
    $null = $adapter1.Fill($dt1)
    $dt1 | Format-Table -AutoSize | Out-String | Write-Host

    $cmd3 = $connection.CreateCommand()
    $cmd3.CommandText = $query3
    $adapter3 = New-Object System.Data.SqlClient.SqlDataAdapter($cmd3)
    $dt3 = New-Object System.Data.DataTable
    $null = $adapter3.Fill($dt3)
    $dt3 | Format-Table -AutoSize | Out-String | Write-Host
}
finally {
    $connection.Close()
}
