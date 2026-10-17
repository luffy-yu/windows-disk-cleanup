<#
.SYNOPSIS
  Read-only: list files in C:\Windows\Installer that no installed product or patch still
  references ("orphans"), and what each was for.
.DESCRIPTION
  Registered files must stay: Windows uses them to repair, patch and uninstall software.
  Orphans can be moved to another drive from an admin prompt (keep them a while in case).
  Elevated, it checks every user's installs (SID s-1-1-0). Unelevated, it sees machine-wide
  installs and the current user's only, so another user's per-user packages would look
  orphaned; say so when reporting.
.EXAMPLE
  & .\msi_orphans.ps1 -Top 20 -CsvOut $env:TEMP\msi-orphans.csv
#>
param([int]$Top = 20, [string]$CsvOut)
$ErrorActionPreference = 'Stop'

$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$sid = if ($elevated) { 's-1-1-0' } else { '' }
$inst = New-Object -ComObject WindowsInstaller.Installer
$t = $inst.GetType()
function Get-Prop($obj, [string]$name, $argList) { try { $obj.GetType().InvokeMember($name, 'GetProperty', $null, $obj, $argList) } catch { $null } }

$owner = @{}   # LocalPackage path -> what it belongs to
$names = @{}   # ProductCode -> ProductName
foreach ($p in $t.InvokeMember('ProductsEx', 'GetProperty', $null, $inst, @('', $sid, 7))) {
  $code = Get-Prop $p 'ProductCode' $null
  $name = Get-Prop $p 'InstallProperty' @('ProductName'); if (-not $name) { $name = $code }
  $names[$code] = $name
  $lp = Get-Prop $p 'InstallProperty' @('LocalPackage'); if ($lp) { $owner[$lp] = $name }
  # patch states: 1 applied, 2 superseded, 4 obsolete, 8 registered
  $patches = try { $t.InvokeMember('PatchesEx', 'GetProperty', $null, $inst, @($code, $sid, 7, 15)) } catch { @() }
  foreach ($x in $patches) { $plp = Get-Prop $x 'PatchProperty' @('LocalPackage'); if ($plp) { $owner[$plp] = "$name (patch)" } }
}
if ($owner.Count -eq 0) { throw 'No registered packages found: the Windows Installer query failed, so there is no orphan list.' }

$files = @(Get-ChildItem 'C:\Windows\Installer' -File -Force | Where-Object { $_.Extension -in '.msi', '.msp' })
$reg = @($files | Where-Object { $owner.ContainsKey($_.FullName) })
$orph = @($files | Where-Object { -not $owner.ContainsKey($_.FullName) })
"Scope: " + $(if ($elevated) { 'all users (elevated)' } else { 'machine-wide + current user (not elevated)' })
"Registered: {0,4} files {1,7:N2} GB  (keep)" -f $reg.Count, (($reg | Measure-Object Length -Sum).Sum / 1GB)
"Orphaned:   {0,4} files {1,7:N2} GB" -f $orph.Count, (($orph | Measure-Object Length -Sum).Sum / 1GB)

# What each orphan was for: a patch lists its target product codes (summary property 7),
# an .msi carries a subject (3) / title (2).
$rows = foreach ($o in $orph) {
  $for = ''
  try {
    $si = $t.InvokeMember('SummaryInformation', 'GetProperty', $null, $inst, @($o.FullName, 0))
    if ($o.Extension -eq '.msp') {
      $targets = "$(Get-Prop $si 'Property' @(7))" -split ';' | Where-Object { $_ }
      $for = (@($targets | ForEach-Object { if ($names[$_]) { $names[$_] } else { $_ } }) | Select-Object -Unique) -join ', '
    } else {
      $for = "$(Get-Prop $si 'Property' @(3))"; if (-not $for) { $for = "$(Get-Prop $si 'Property' @(2))" }
    }
  } catch { $for = '(unreadable)' }
  [pscustomobject]@{ Name = $o.Name; GB = [math]::Round($o.Length / 1GB, 3); Modified = $o.LastWriteTime.ToString('yyyy-MM-dd'); For = $for; Path = $o.FullName }
}

""
"Orphans by product:"
$rows | Group-Object For | ForEach-Object { [pscustomobject]@{ For = $_.Name; GB = ($_.Group | Measure-Object GB -Sum).Sum; N = $_.Count } } |
  Sort-Object GB -Descending | ForEach-Object { "  {0,7:N2} GB {1,4} files  {2}" -f $_.GB, $_.N, $(if ($_.For) { $_.For } else { '(unknown)' }) }
""
"Largest orphans:"
$rows | Sort-Object GB -Descending | Select-Object -First $Top |
  ForEach-Object { "  {0,6:N2} GB  {1}  {2,-14} {3}" -f $_.GB, $_.Modified, $_.Name, $_.For }
if ($CsvOut) { $rows | Export-Csv $CsvOut -NoTypeInformation; "Saved $($rows.Count) rows to $CsvOut" }
