<# : batch launcher - double-click this file. The PowerShell part starts after the closing tag below.
@echo off
title POS duplicate-item cleanup
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Get-Content -LiteralPath '%~f0' -Raw)))"
echo.
pause
exit /b
#>
<#
  POS duplicate-item cleanup - run on the shop POS PC (double-click). Per "i want 1 and 2.. but make
  sure that the item is not present on portal and pancake before deactivating" (RS-0000002739 failed
  because items 446 / 608 are such duplicates).

  Finds, among ACTIVE items in the POS database:
    Group 1 - items whose VariationId is really a Pancake PRODUCT id (the numeric-code copies made in one
              batch on 2026-08-17, e.g. 262 = copy of P-023). Pancake rejects orders with these ids (500).
    Group 2 - several POS items pointing at the SAME Pancake variation (e.g. 100G-OS-SET and AS-007).
              The one whose code Pancake/portal knows is kept; the others are candidates.

  A candidate is deactivated (Items.IsActive = 0, nothing is deleted) ONLY when:
    - its Code is not a Pancake product/variation code, AND
    - its Code is not in the portal's Items (via RPC pos_list_item_codes), AND
    - another active POS item holds the real Pancake variation (so the item can still be sold).
  For group 1 it also repoints saved lines (ItemLedgerEntry / AdvanceOrderLines / OnlineOrderLines) from
  the product id to the real variation id, so failed receipts like RS-0000002739 can be resent.

  Flow: finds the POS database -> preview + report CSV on the Desktop -> asks you to type YES -> applies
  everything in one transaction and writes an undo .sql to the Desktop.
  Needs sql/supabase_pos_list_item_codes.sql run in Supabase first.
#>

# ---------- 0. Find the POS database on this PC ----------
function Find-PosDatabases {
    $found = New-Object System.Collections.Generic.List[object]
    $servers = @($env:COMPUTERNAME, "$env:COMPUTERNAME\SQLEXPRESS", 'localhost', '.\SQLEXPRESS', '(localdb)\MSSQLLocalDB') | Select-Object -Unique
    foreach ($srv in $servers) {
        try {
            $c = New-Object System.Data.SqlClient.SqlConnection("Server=$srv;Database=master;Trusted_Connection=True;Connection Timeout=5;")
            $c.Open()
            $cmd = $c.CreateCommand()
            $cmd.CommandText = "SELECT name FROM sys.databases WHERE state = 0 AND name NOT IN ('master','tempdb','model','msdb') ORDER BY name"
            $names = @(); $rd = $cmd.ExecuteReader(); while ($rd.Read()) { $names += [string]$rd[0] }; $rd.Close()
            foreach ($db in $names) {
                $cmd.CommandText = "SELECT CASE WHEN OBJECT_ID(N'[$db].dbo.Items') IS NOT NULL AND OBJECT_ID(N'[$db].dbo.ItemLedgerEntry') IS NOT NULL THEN 1 ELSE 0 END"
                try { if ([int]$cmd.ExecuteScalar() -eq 1) { $found.Add([pscustomobject]@{ Server = $srv; Database = $db }) } } catch { }
            }
            $c.Close()
            if ($found.Count -gt 0) { break }   # first server that has POS databases wins
        } catch { }
    }
    , $found
}

Write-Host 'Looking for the POS database on this PC...'
$dbs = Find-PosDatabases
if ($dbs.Count -eq 0) {
    $ConnectionString = Read-Host 'No POS database found automatically. Paste the connection string (e.g. Server=DESKTOP-XXXX;Database=RSPETSTOP;Trusted_Connection=True;)'
} else {
    for ($i = 0; $i -lt $dbs.Count; $i++) { Write-Host ("  [{0}] {1} / {2}" -f ($i + 1), $dbs[$i].Server, $dbs[$i].Database) }
    $pick = 1
    if ($dbs.Count -gt 1) { $pick = [int](Read-Host 'Which one is the LIVE POS database? Type the number') }
    else { if ((Read-Host "Use this database? (Y/N)") -notmatch '^[Yy]') { Write-Host 'Stopped - nothing changed.'; return } }
    $sel = $dbs[$pick - 1]
    $ConnectionString = "Server=$($sel.Server);Database=$($sel.Database);Trusted_Connection=True;Connection Timeout=30;"
}
if ([string]::IsNullOrWhiteSpace($ConnectionString)) { Write-Host 'Stopped - nothing changed.'; return }
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Same values as GlobalSettings.cs.
$PancakeBase = 'https://pos.pages.fm/api/v1/shops/1328301944'
$PancakeKey  = 'e611861d2fc84607bfbbe1428a432447'
$SupabaseRpc = 'https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/rpc/pos_list_item_codes'
$SupabaseKey = 'sb_publishable_QWDFggQ9ce9zm65xFEzmHA_rGaOUFQz'
$PosApiKey   = 'pos_6385f793ed5792e50fa8dc35b19a23e51f28ae1c2d4cb149'

function Norm([object]$s) { if ($null -eq $s -or $s -is [DBNull]) { '' } else { ([string]$s).Trim().ToUpperInvariant() } }

# ---------- 1. Pancake: every variation ----------
Write-Host 'Reading Pancake variations...'
$pancake = New-Object System.Collections.Generic.List[object]
for ($page = 1; $page -le 200; $page++) {
    $j = Invoke-RestMethod -UseBasicParsing "$PancakeBase/products/variations?api_key=$PancakeKey&page=$page&page_size=100"
    if (-not $j.data -or @($j.data).Count -eq 0) { break }
    foreach ($v in $j.data) { $pancake.Add($v) }
}
if ($pancake.Count -eq 0) { throw 'Pancake returned no variations - stopping (nothing changed).' }

$pkVarById   = @{}   # variation id -> variation
$pkVarsByProd = @{}  # product id -> list of variations
$pkCodes     = @{}   # every Pancake code (variation display_id + product display_id)
foreach ($v in $pancake) {
    $pkVarById[[string]$v.id] = $v
    $prodId = [string]$v.product_id
    if ($prodId) { if (-not $pkVarsByProd.ContainsKey($prodId)) { $pkVarsByProd[$prodId] = New-Object System.Collections.Generic.List[object] }; $pkVarsByProd[$prodId].Add($v) }
    foreach ($c in @($v.display_id, $v.product.display_id, $v.product.custom_id)) { $n = Norm $c; if ($n) { $pkCodes[$n] = 1 } }
}
Write-Host "  $($pancake.Count) variations"

# ---------- 2. Portal: every Items row ----------
Write-Host 'Reading portal Items...'
$portalCodes = @{}
$headers = @{ apikey = $SupabaseKey; Authorization = "Bearer $SupabaseKey" }
for ($offset = 0; ; $offset += 1000) {
    $body = @{ p_pos_key = $PosApiKey; p_limit = 1000; p_offset = $offset } | ConvertTo-Json
    try { $rows = Invoke-RestMethod -UseBasicParsing -Method Post -Uri $SupabaseRpc -Headers $headers -ContentType 'application/json' -Body $body }
    catch { throw "Portal RPC pos_list_item_codes failed - run sql/supabase_pos_list_item_codes.sql in Supabase first. ($($_.Exception.Message))" }
    $rows = @($rows)
    foreach ($r in $rows) { $n = Norm $r.code; if ($n) { $portalCodes[$n] = 1 } }
    if ($rows.Count -lt 1000) { break }
}
if ($portalCodes.Count -eq 0) { throw 'Portal returned no items - stopping (nothing changed).' }
Write-Host "  $($portalCodes.Count) portal items"

# ---------- 3. POS items ----------
Write-Host "Reading POS items ($ConnectionString)..."
$conn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
$conn.Open()
function Query([string]$sql) {
    $cmd = $conn.CreateCommand(); $cmd.CommandText = $sql
    $dt = New-Object System.Data.DataTable
    (New-Object System.Data.SqlClient.SqlDataAdapter($cmd)).Fill($dt) | Out-Null
    , $dt
}
function HasColumn([string]$table, [string]$col) {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME=@t AND COLUMN_NAME=@c"
    [void]$cmd.Parameters.AddWithValue('@t', $table); [void]$cmd.Parameters.AddWithValue('@c', $col)
    [int]$cmd.ExecuteScalar() -gt 0
}

$items = Query "SELECT Code, Name, VariationId, QuantityInStock FROM Items WHERE IsActive = 1"
Write-Host "  $($items.Rows.Count) active POS items"

# Active POS items that hold a REAL Pancake variation id.
$goodByVar = @{}; $goodByProd = @{}
foreach ($r in $items.Rows) {
    $vid = [string]$r.VariationId
    if ($vid -and $pkVarById.ContainsKey($vid)) {
        if (-not $goodByVar.ContainsKey($vid)) { $goodByVar[$vid] = New-Object System.Collections.Generic.List[object] }
        $goodByVar[$vid].Add($r)
        $prod = [string]$pkVarById[$vid].product_id
        if (-not $goodByProd.ContainsKey($prod)) { $goodByProd[$prod] = New-Object System.Collections.Generic.List[object] }
        $goodByProd[$prod].Add($r)
    }
}

$report = New-Object System.Collections.Generic.List[object]
function AddRow($group, $r, $action, $reason, $keptCode, $newVid) {
    $report.Add([pscustomobject]@{
        Group = $group; Action = $action; Code = [string]$r.Code; Name = [string]$r.Name
        InPancake = [bool]$pkCodes[(Norm $r.Code)]; InPortal = [bool]$portalCodes[(Norm $r.Code)]
        RealItem = $keptCode; Stock = $r.QuantityInStock; OldVariationId = [string]$r.VariationId
        NewVariationId = $newVid; Reason = $reason })
}

# ---------- Group 1: VariationId is a Pancake PRODUCT id ----------
foreach ($r in $items.Rows) {
    $vid = [string]$r.VariationId
    if (-not $vid -or $pkVarById.ContainsKey($vid) -or -not $pkVarsByProd.ContainsKey($vid)) { continue }

    $twins = @(); if ($goodByProd.ContainsKey($vid)) { $twins = $goodByProd[$vid].ToArray() }
    $twinCodes = ($twins | ForEach-Object { [string]$_.Code } | Select-Object -Unique) -join ', '

    # The real variation to repoint saved lines to: the only one, or the one whose POS item has the same name.
    $newVid = ''
    $twinVids = @($twins | ForEach-Object { [string]$_.VariationId } | Select-Object -Unique)
    if ($twinVids.Count -eq 1) { $newVid = $twinVids[0] }
    else {
        $same = @($twins | Where-Object { (Norm $_.Name) -eq (Norm $r.Name) } | ForEach-Object { [string]$_.VariationId } | Select-Object -Unique)
        if ($same.Count -eq 1) { $newVid = $same[0] }
    }

    if ($pkCodes[(Norm $r.Code)])          { AddRow 1 $r 'KEEP' 'code exists in Pancake' $twinCodes $newVid }
    elseif ($portalCodes[(Norm $r.Code)])  { AddRow 1 $r 'KEEP' 'code exists in portal' $twinCodes $newVid }
    elseif ($twins.Count -eq 0)            { AddRow 1 $r 'KEEP' 'no other POS item holds this Pancake product - would become unsellable' '' $newVid }
    else {
        $why = 'Pancake product id stored as variation id; real item exists'
        if (-not $newVid) { $why += '; product has several variations - saved lines NOT repointed (fix by hand)' }
        AddRow 1 $r 'DEACTIVATE' $why $twinCodes $newVid
    }
}

# ---------- Group 2: several POS items on one Pancake variation ----------
foreach ($vid in $goodByVar.Keys) {
    $grp = $goodByVar[$vid].ToArray()
    if ($grp.Count -lt 2) { continue }
    $keepers = @($grp | Where-Object { $pkCodes[(Norm $_.Code)] -or $portalCodes[(Norm $_.Code)] })
    $keepCodes = ($keepers | ForEach-Object { [string]$_.Code }) -join ', '
    foreach ($r in $grp) {
        if ($pkCodes[(Norm $r.Code)])         { AddRow 2 $r 'KEEP' 'code exists in Pancake' $keepCodes '' }
        elseif ($portalCodes[(Norm $r.Code)]) { AddRow 2 $r 'KEEP' 'code exists in portal' $keepCodes '' }
        elseif ($keepers.Count -eq 0)         { AddRow 2 $r 'KEEP' 'none of the items sharing this variation is in Pancake/portal - decide by hand' '' '' }
        else                                  { AddRow 2 $r 'DEACTIVATE' 'same Pancake variation as a kept item' $keepCodes '' }
    }
}

# ---------- Report ----------
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$desk = [Environment]::GetFolderPath('Desktop')
$csv = Join-Path $desk "pos_duplicate_items_$stamp.csv"
$report | Sort-Object Group, Action, Code | Export-Csv -NoTypeInformation -Encoding UTF8 $csv

$deact = @($report | Where-Object Action -eq 'DEACTIVATE')
$repoint = @($deact | Where-Object { $_.Group -eq 1 -and $_.NewVariationId })
Write-Host ''
Write-Host ('Group 1 (product id as variation id): {0} to deactivate, {1} kept' -f @($deact | ? Group -eq 1).Count, @($report | ? { $_.Group -eq 1 -and $_.Action -eq 'KEEP' }).Count)
Write-Host ('Group 2 (several items on one variation): {0} to deactivate, {1} kept' -f @($deact | ? Group -eq 2).Count, @($report | ? { $_.Group -eq 2 -and $_.Action -eq 'KEEP' }).Count)
Write-Host "Report: $csv"

# Undo script: re-activate exactly these items.
$undo = New-Object System.Text.StringBuilder
[void]$undo.AppendLine("-- Undo for pos_duplicate_items_cleanup.ps1 run $stamp (re-activates the items it deactivated).")
foreach ($d in $deact) { [void]$undo.AppendLine("UPDATE Items SET IsActive = 1 WHERE Code = N'$($d.Code.Replace("'", "''"))';") }

$lineTables = @(@{ T = 'ItemLedgerEntry'; C = 'VariationId' }, @{ T = 'AdvanceOrderLines'; C = 'VariationId' }, @{ T = 'OnlineOrderLines'; C = 'VariationId' }) |
    Where-Object { HasColumn $_.T $_.C }

Write-Host ''
Write-Host 'PREVIEW done - nothing changed yet. Opening the report...' -ForegroundColor Yellow
try { Invoke-Item $csv } catch { }
Write-Host ''
if ((Read-Host 'Type YES to deactivate the DEACTIVATE rows and fix their saved lines (anything else = stop)') -cne 'YES') {
    Write-Host 'Stopped - nothing changed.'
    $conn.Close(); return
}

# ---------- Apply (one transaction) ----------
$tx = $conn.BeginTransaction()
try {
    $deactivated = 0; $linesFixed = 0
    foreach ($d in $deact) {
        $cmd = $conn.CreateCommand(); $cmd.Transaction = $tx
        $cmd.CommandText = 'UPDATE Items SET IsActive = 0 WHERE Code = @code AND IsActive = 1'
        [void]$cmd.Parameters.AddWithValue('@code', $d.Code)
        $deactivated += $cmd.ExecuteNonQuery()
    }
    foreach ($d in ($repoint | Sort-Object OldVariationId -Unique)) {
        foreach ($lt in $lineTables) {
            $cmd = $conn.CreateCommand(); $cmd.Transaction = $tx
            $cmd.CommandText = "UPDATE $($lt.T) SET $($lt.C) = @new WHERE $($lt.C) = @old"
            [void]$cmd.Parameters.AddWithValue('@new', $d.NewVariationId)
            [void]$cmd.Parameters.AddWithValue('@old', $d.OldVariationId)
            # Not in the undo script: the old id never existed as a Pancake variation, so putting it back
            # would only re-break those lines.
            $linesFixed += $cmd.ExecuteNonQuery()
        }
    }
    $tx.Commit()
    Write-Host ''
    Write-Host "DONE: $deactivated item(s) deactivated, $linesFixed saved line(s) repointed to the real Pancake variation." -ForegroundColor Green
    Write-Host 'Now resend the failed receipts (e.g. RS-0000002739) from the Transactions list.'
}
catch {
    $tx.Rollback()
    throw "Failed - everything rolled back, nothing changed. $($_.Exception.Message)"
}
finally {
    $undoFile = Join-Path $desk "pos_duplicate_items_undo_$stamp.sql"
    [IO.File]::WriteAllText($undoFile, $undo.ToString())
    Write-Host "Undo script: $undoFile"
    $conn.Close()
}