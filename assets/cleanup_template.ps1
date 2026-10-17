# Frees space on <DRIVE> by deleting the items reviewed on <DATE>.
# Run it yourself in PowerShell 7:  pwsh -File "<PATH TO THIS FILE>"
# Each step skips itself if the app that owns the folder is running, and prints what it freed.
# Deletion is permanent. Read the STEPS section before running.

$opts = [System.IO.EnumerationOptions]::new()
$opts.RecurseSubdirectories = $true; $opts.IgnoreInaccessible = $true; $opts.AttributesToSkip = [IO.FileAttributes]::ReparsePoint
$L = $env:LOCALAPPDATA; $R = $env:APPDATA; $U = $env:USERPROFILE; $T = $env:TEMP

function Measure-Item([string]$full) {
  if (-not (Test-Path -LiteralPath $full)) { return 0L }
  $i = Get-Item -LiteralPath $full -Force
  if (-not $i.PSIsContainer) { return $i.Length }
  $sum = 0L; foreach ($f in ([IO.DirectoryInfo]$full).EnumerateFiles('*', $opts)) { $sum += $f.Length }; $sum
}
# Delete files/folders (wildcards allowed in the paths given; matches are removed literally).
function Remove-Paths([string]$label, [string[]]$paths) {
  $items = @(foreach ($p in $paths) { Get-Item -Path $p -Force -ErrorAction SilentlyContinue })
  if (-not $items) { "       -     $label (nothing there)"; return }
  $before = 0L; foreach ($i in $items) { $before += Measure-Item $i.FullName }
  $errs = @()
  foreach ($i in $items) { Remove-Item -LiteralPath $i.FullName -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +errs }
  $after = 0L; foreach ($i in $items) { $after += Measure-Item $i.FullName }
  $note = if ($errs.Count) { "  [$($errs.Count) errors, first: $($errs[0].Exception.Message -replace '\s+', ' ')]" } else { '' }
  "{0,8:N2} GB  {1}{2}" -f (($before - $after) / 1GB), $label, $note
}
# Run a tool's own cleaner and measure its cache folder.
function Invoke-Cleaner([string]$label, [string]$dir, [scriptblock]$cmd) {
  $b = Measure-Item $dir; & $cmd *> $null
  "{0,8:N2} GB  {1}" -f (($b - (Measure-Item $dir)) / 1GB), $label
}
# Same, but measured on the volume: for hard-linked caches (uv, conda, pnpm) whose folder size lies.
function Invoke-VolumeCleaner([string]$label, [scriptblock]$cmd, [string]$drive = 'C') {
  $f = (Get-Volume $drive).SizeRemaining; & $cmd *> $null
  "{0,8:N2} GB  {1}" -f (((Get-Volume $drive).SizeRemaining - $f) / 1GB), $label
}
function Running([string]$pattern) { @(Get-Process | Where-Object { $_.ProcessName -match $pattern }).Count -gt 0 }

$free0 = (Get-Volume C).SizeRemaining
"C: free before: {0:N2} GB" -f ($free0 / 1GB)

# ===== STEPS: fill in for this machine (examples below; delete what doesn't apply) =====
# Remove-Paths 'WSL crash dumps' @("$T\wsl-crashes\*.dmp")
# if (Running '^Unity$') { "skipped     Unity package cache (Unity is running)" }
# else { Remove-Paths 'Unity package cache' @("$L\Unity\cache") }
# Invoke-Cleaner 'pip cache' "$L\pip\cache" { pip cache purge }
# if (@(Get-Process | Where-Object ProcessName -in 'uv', 'uvx').Count) { "skipped     uv cache (uv is running)" }
# else { Invoke-VolumeCleaner 'uv cache' { uv cache clean } }
# if (Running '^go$') { "skipped     Go build cache (a go build/test is running)" }
# else { Invoke-Cleaner 'Go build cache' "$L\go-build" { go clean -cache } }
# ===== END STEPS =====

$free1 = (Get-Volume C).SizeRemaining
"C: free after:  {0:N2} GB  (+{1:N2} GB)" -f ($free1 / 1GB), (($free1 - $free0) / 1GB)
