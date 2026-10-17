<#
.SYNOPSIS
  Read-only report of WSL and Docker Desktop disk use.
.DESCRIPTION
  - every WSL distro and its virtual disk (size on disk, last write);
  - Docker Desktop's virtual disk files under %LOCALAPPDATA%\Docker\wsl;
  - if the Docker engine answers: docker system df, each image with the space it alone holds
    (unique size), volumes with how many containers use them and when they were created,
    containers, and how full Docker's disk is inside the VM (its room to keep growing).
  Only queries: never prunes, and runs the in-VM check only when Docker is already running.
.EXAMPLE
  & .\wsl_docker_report.ps1
#>
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OnDisk {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetCompressedFileSizeW(string name, out uint high);
    // Allocated size (smaller than Length for sparse virtual disks); -1 if unreadable.
    public static long Size(string path) {
        uint hi; uint lo = GetCompressedFileSizeW(path, out hi);
        if (lo == 0xFFFFFFFF && Marshal.GetLastWin32Error() != 0) return -1;
        return ((long)hi << 32) | lo;
    }
}
'@
function Show-Vhd([string]$label, [IO.FileInfo]$f) {
  $disk = [OnDisk]::Size($f.FullName)
  if ($disk -lt 0) { $disk = $f.Length }
  $note = if ($disk -lt $f.Length * 0.95) { " (logical {0:N1} GB, sparse)" -f ($f.Length / 1GB) } else { '' }
  "  {0,-22} {1,8:N1} GB{2}  written {3:yyyy-MM-dd}  {4}" -f $label, ($disk / 1GB), $note, $f.LastWriteTime, $f.FullName
}
function Bytes([string]$s) {
  if ($s -match '^([\d.]+)\s*([kMGT]?B)$') { [double]$Matches[1] * @{ 'B' = 1; 'kB' = 1e3; 'MB' = 1e6; 'GB' = 1e9; 'TB' = 1e12 }[$Matches[2]] } else { 0 }
}

"== WSL distros =="
wsl.exe -l -v 2>$null | ForEach-Object { $_ -replace "`0", '' } | Where-Object { $_.Trim() } | ForEach-Object { "  $_" }
foreach ($k in Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue) {
  $p = Get-ItemProperty $k.PSPath
  if (-not $p.DistributionName) { continue }
  $base = $p.BasePath -replace '^\\\\\?\\', ''
  $vhd = Get-ChildItem -LiteralPath $base -Filter *.vhdx -Force -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($vhd) { Show-Vhd $p.DistributionName $vhd } else { "  {0,-22} no .vhdx in {1}" -f $p.DistributionName, $base }
}

""
"== Docker Desktop =="
$exe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
if (Test-Path $exe) { "  app version " + (Get-Item $exe).VersionInfo.ProductVersion }
Get-ChildItem "$env:LOCALAPPDATA\Docker\wsl" -Recurse -Filter *.vhdx -Force -ErrorAction SilentlyContinue | ForEach-Object { Show-Vhd 'disk file' $_ }
$server = docker version --format '{{.Server.Version}}' 2>$null
if ($LASTEXITCODE -or -not $server) { "  engine not answering; start Docker Desktop for the inside view"; exit 0 }
"  engine $server"
""
docker system df
$df = docker system df -v --format '{{json .}}' 2>$null | ConvertFrom-Json

""
"== Images (unique = what removing that image frees) =="
$df.Images | Sort-Object { Bytes $_.UniqueSize } -Descending | ForEach-Object {
  "  {0,9} unique {1,9} total  containers {2}  {3,-15} {4}:{5}" -f $_.UniqueSize, $_.Size, $_.Containers, $_.CreatedSince, $_.Repository, $_.Tag }

""
"== Volumes (links = containers using it; 0 does not mean junk) =="
$df.Volumes | Sort-Object { Bytes $_.Size } -Descending | ForEach-Object {
  $created = (docker volume inspect $_.Name --format '{{.CreatedAt}}' 2>$null) -replace 'T.*', ''
  "  {0,9}  links {1}  created {2,-10}  {3}" -f $_.Size, $_.Links, $created, $_.Name }

""
"== Containers =="
docker ps -a --size --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Size}}'

""
"== Inside Docker's disk (size - used = how much more the disk file can grow) =="
wsl.exe -d docker-desktop -e sh -c "df -h 2>/dev/null" 2>$null | ForEach-Object { $_ -replace "`0", '' } |
  Where-Object { $_ -match 'Filesystem|docker|/var/lib' } | Select-Object -Unique | ForEach-Object { "  $_" }
