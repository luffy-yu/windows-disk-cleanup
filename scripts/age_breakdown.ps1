<#
.SYNOPSIS
  How much of a folder is old vs recent, and its biggest entries with the newest file in each.
.DESCRIPTION
  Recent writes inside an entry hint that something still uses it; entries untouched for
  months are the easy wins. Good for %TEMP%, Downloads and app cache folders. Read-only.
.EXAMPLE
  & .\age_breakdown.ps1 -Path $env:TEMP -Top 25
#>
param([Parameter(Mandatory)][string]$Path, [int]$Top = 20)
$opts = [System.IO.EnumerationOptions]::new()
$opts.RecurseSubdirectories = $true; $opts.IgnoreInaccessible = $true; $opts.AttributesToSkip = [IO.FileAttributes]::ReparsePoint
$now = Get-Date
$labels = '<1d', '1-7d', '7-30d', '30-180d', '>180d'
$buckets = [long[]]::new(5)
$items = foreach ($e in Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue) {
  $size = 0L; $n = 0; $newest = $e.LastWriteTime
  if ($e.PSIsContainer) {
    if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    foreach ($f in ([IO.DirectoryInfo]$e.FullName).EnumerateFiles('*', $opts)) {
      $size += $f.Length; $n++
      if ($f.LastWriteTime -gt $newest) { $newest = $f.LastWriteTime }
      $age = ($now - $f.LastWriteTime).TotalDays
      $k = if ($age -lt 1) { 0 } elseif ($age -lt 7) { 1 } elseif ($age -lt 30) { 2 } elseif ($age -lt 180) { 3 } else { 4 }
      $buckets[$k] += $f.Length
    }
  } else {
    $size = $e.Length; $n = 1
    $age = ($now - $e.LastWriteTime).TotalDays
    $k = if ($age -lt 1) { 0 } elseif ($age -lt 7) { 1 } elseif ($age -lt 30) { 2 } elseif ($age -lt 180) { 3 } else { 4 }
    $buckets[$k] += $e.Length
  }
  [pscustomobject]@{ Name = $e.Name; GB = $size / 1GB; Files = $n; Newest = $newest; IsDir = $e.PSIsContainer }
}
"{0}: {1:N2} GB in {2:N0} entries" -f $Path, (($items | Measure-Object GB -Sum).Sum), @($items).Count
"By last write:"
for ($i = 0; $i -lt 5; $i++) { "  {0,-8} {1,8:N2} GB" -f $labels[$i], ($buckets[$i] / 1GB) }
""
"Biggest entries (newest file inside):"
$items | Sort-Object GB -Descending | Select-Object -First $Top |
  ForEach-Object { "{0,8:N2} GB {1,8:N0} files  newest {2:yyyy-MM-dd HH:mm}  {3}{4}" -f $_.GB, $_.Files, $_.Newest, $_.Name, $(if ($_.IsDir) { '\' } else { '' }) }
