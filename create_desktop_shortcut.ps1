<#
Creates a Desktop shortcut to the built application exe for this solution.

Usage:
  - Build the project first (e.g. `dotnet build`).
  - Run this script from the project root in PowerShell:
      .\create_desktop_shortcut.ps1

The script searches the project folder recursively for the expected
assembly executable name (taken from the project assembly name) and
creates a .lnk on the current user's Desktop.
#>

# Expected executable filename (matches the AssemblyName from the csproj)
$exeName = "RSPETSTOP POS.exe"

try {
    $projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
} catch {
    # Fallback to current directory
    $projectRoot = Get-Location
}

Write-Host "Searching for '$exeName' under: $projectRoot"

$found = Get-ChildItem -Path $projectRoot -Filter $exeName -Recurse -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | Select-Object -First 1

if (-not $found) {
    Write-Host "Executable '$exeName' not found under project."
    Write-Host "Common build output locations to check:"
    Write-Host "  - $projectRoot\bin\Debug\net7.0-windows\"
    Write-Host "  - $projectRoot\bin\Release\net7.0-windows\"
    Write-Host "  - $projectRoot\publish\win-x64\release\" 
    Write-Host "Please build/publish the project and re-run this script."
    exit 1
}

$targetPath = $found.FullName
$workingDir = Split-Path $targetPath

$desktop = [Environment]::GetFolderPath("Desktop")
$lnkName = "RSPETSTOP POS.lnk"
$lnkPath = Join-Path $desktop $lnkName

Write-Host "Creating shortcut on Desktop: $lnkPath"

$WshShell = New-Object -ComObject WScript.Shell
$shortcut = $WshShell.CreateShortcut($lnkPath)
$shortcut.TargetPath = $targetPath
$shortcut.WorkingDirectory = $workingDir
$shortcut.IconLocation = "$targetPath,0"
$shortcut.Save()

Write-Host "Shortcut created: $lnkPath -> $targetPath"
