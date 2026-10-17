<#
.SYNOPSIS
  Show the subfolders of one or more folders from a du_scan.ps1 dirs CSV, biggest first.
.DESCRIPTION
  Lets you drill down without rescanning. Only folders the scan kept (>= its -MinDirMB,
  within its -ReportDepth) appear. Pass several parents in one call from PowerShell:
  & .\du_kids.ps1 -Csv x-dirs.csv -Parent 'C:\', 'C:\Users\me\AppData\Local'
.EXAMPLE
  & .\du_kids.ps1 -Csv $env:TEMP\cscan-dirs.csv -Parent 'C:\Users\me\AppData\Local' -MinGB 0.5 -Top 15
#>
param(
  [Parameter(Mandatory)][string]$Csv,
  [Parameter(Mandatory)][string[]]$Parent,
  [double]$MinGB = 1,
  [int]$Top = 25
)
$rows = Import-Csv $Csv
foreach ($par in $Parent) {
  $p = $par.TrimEnd('\') + '\'
  "== $par =="
  $rows | Where-Object {
      $_.Path.Length -gt $p.Length -and $_.Path.StartsWith($p, 'OrdinalIgnoreCase') -and
      -not $_.Path.Substring($p.Length).Contains('\') -and [double]$_.GB -ge $MinGB } |
    Sort-Object { [double]$_.GB } -Descending | Select-Object -First $Top |
    ForEach-Object { "{0,8:N1} GB {1,10:N0} files  newest {2,-10}  {3}" -f [double]$_.GB, [long]$_.Files, $_.Newest, $_.Path.Substring($p.Length) }
}
