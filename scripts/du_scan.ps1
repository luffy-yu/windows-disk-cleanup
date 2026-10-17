<#
.SYNOPSIS
  Fast on-disk size scan of a folder tree, for disk-space audits. Read-only.
.DESCRIPTION
  Walks the tree with a compiled .NET helper (about 2-3 minutes per million files) and writes:
    <OutPrefix>-dirs.csv    folders down to -ReportDepth holding at least -MinDirMB:
                            Path, Depth, GB, Files, Dirs, Newest (latest file write inside)
    <OutPrefix>-files.csv   files of at least -MinFileMB: Path, GB, LogicalGB, Modified
    <OutPrefix>-denied.txt  folders it could not read (an elevated run sees more)
  Sizes are what the files occupy on disk:
    - compressed, sparse and WOF (CompactOS) files count their allocated size;
    - cloud-only placeholders (OneDrive Files On-Demand) count as zero;
    - junctions and symlinked folders are not followed.
  Hard links count once per link, so trees sharing files by hard link (WinSxS, uv / conda /
  pnpm caches) look bigger than they are; measure those with linkunion.ps1.
.EXAMPLE
  pwsh -NoProfile -File du_scan.ps1 -Root C:\ -OutPrefix $env:TEMP\cscan
#>
param(
  [string]$Root = 'C:\',
  [int]$ReportDepth = 8,
  [long]$MinDirMB = 200,
  [long]$MinFileMB = 200,
  [int]$ParallelDepth = 3,
  [Parameter(Mandatory)][string]$OutPrefix
)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Threading;
using System.Threading.Tasks;
using System.Runtime.InteropServices;

public static class DuScan
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);

    public sealed class Entry { public string Path { get; set; } public int Depth { get; set; } public long Bytes { get; set; } public long Files { get; set; } public long Dirs { get; set; } public long NewestTicks { get; set; } }
    public sealed class FileEntry { public string Path { get; set; } public long Bytes { get; set; } public long Logical { get; set; } public DateTime Modified { get; set; } }

    public static ConcurrentBag<Entry> Dirs = new ConcurrentBag<Entry>();
    public static ConcurrentBag<FileEntry> BigFiles = new ConcurrentBag<FileEntry>();
    public static ConcurrentBag<string> Denied = new ConcurrentBag<string>();
    static int ReportDepth; static long MinDir; static long MinFile; static int ParallelDepth;

    static readonly EnumerationOptions Opts = new EnumerationOptions {
        RecurseSubdirectories = false, IgnoreInaccessible = false,
        AttributesToSkip = 0, ReturnSpecialDirectories = false
    };

    public static long[] Run(string root, int reportDepth, long minDir, long minFile, int parallelDepth)
    {
        ReportDepth = reportDepth; MinDir = minDir; MinFile = minFile; ParallelDepth = parallelDepth;
        long files = 0, dirs = 0, newest = 0;
        long bytes = Scan(new DirectoryInfo(root), 0, ref files, ref dirs, ref newest);
        return new long[] { bytes, files, dirs };
    }

    // On-disk size for sparse / compressed / WOF (reparse) files, whose Length overstates usage.
    static long Allocated(string path, long len)
    {
        uint hi; uint lo = GetCompressedFileSizeW(path, out hi);
        if (lo == 0xFFFFFFFF && Marshal.GetLastWin32Error() != 0) return len;
        return ((long)hi << 32) | lo;
    }

    static void Max(ref long target, long value)
    {
        long cur = Interlocked.Read(ref target);
        while (value > cur)
        {
            long seen = Interlocked.CompareExchange(ref target, value, cur);
            if (seen == cur) break;
            cur = seen;
        }
    }

    static long Scan(DirectoryInfo di, int depth, ref long totalFiles, ref long totalDirs, ref long newestTicks)
    {
        long bytes = 0, files = 0, dirs = 0, newest = 0;
        var subdirs = new List<DirectoryInfo>();
        try
        {
            foreach (var fsi in di.EnumerateFileSystemInfos("*", Opts))
            {
                int a = (int)fsi.Attributes;
                if ((a & 0x10) != 0)
                {
                    if ((a & 0x400) != 0) continue; // junction / symlink / mount point
                    subdirs.Add((DirectoryInfo)fsi);
                }
                else
                {
                    // cloud-only placeholders (OneDrive etc.) take no local space
                    if ((a & 0x400000) != 0 || (a & 0x40000) != 0 || (a & 0x1000) != 0) continue;
                    var f = (FileInfo)fsi;
                    long logical = f.Length, len = logical;
                    if ((a & (0x200 | 0x800 | 0x400)) != 0 && len > 0) len = Allocated(f.FullName, len);
                    bytes += len; files++;
                    long t = f.LastWriteTimeUtc.Ticks; if (t > newest) newest = t;
                    if (len >= MinFile) BigFiles.Add(new FileEntry { Path = f.FullName, Bytes = len, Logical = logical, Modified = f.LastWriteTime });
                }
            }
        }
        catch (Exception) { Denied.Add(di.FullName); }

        if (depth < ParallelDepth && subdirs.Count > 1)
        {
            long pb = 0, pf = 0, pd = 0, pn = 0;
            Parallel.ForEach(subdirs, new ParallelOptions { MaxDegreeOfParallelism = 8 }, sd => {
                long f2 = 0, d2 = 0, n2 = 0;
                long b2 = Scan(sd, depth + 1, ref f2, ref d2, ref n2);
                Interlocked.Add(ref pb, b2); Interlocked.Add(ref pf, f2); Interlocked.Add(ref pd, d2 + 1); Max(ref pn, n2);
            });
            bytes += pb; files += pf; dirs += pd; if (pn > newest) newest = pn;
        }
        else
        {
            foreach (var sd in subdirs)
            {
                long f2 = 0, d2 = 0, n2 = 0;
                bytes += Scan(sd, depth + 1, ref f2, ref d2, ref n2);
                files += f2; dirs += d2 + 1; if (n2 > newest) newest = n2;
            }
        }
        if (depth <= ReportDepth && bytes >= MinDir)
            Dirs.Add(new Entry { Path = di.FullName, Depth = depth, Bytes = bytes, Files = files, Dirs = dirs, NewestTicks = newest });
        totalFiles += files; totalDirs += dirs; newestTicks = newest;
        return bytes;
    }
}
'@
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = [DuScan]::Run($Root, $ReportDepth, $MinDirMB * 1MB, $MinFileMB * 1MB, $ParallelDepth)
$sw.Stop()
"Scanned {0}: {1:N1} GB in {2:N0} files, {3:N0} dirs; {4:N0} unreadable dirs; {5:N1}s" -f $Root, ($r[0] / 1GB), $r[1], $r[2], [DuScan]::Denied.Count, $sw.Elapsed.TotalSeconds
$letter = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Root)).Substring(0, 1)
$vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
if ($vol) { "Volume {0}: {1:N1} GB used, {2:N1} GB free" -f $letter, (($vol.Size - $vol.SizeRemaining) / 1GB), ($vol.SizeRemaining / 1GB) }
[DuScan]::Dirs | Sort-Object Bytes -Descending |
  Select-Object Path, Depth, @{n = 'GB'; e = { [math]::Round($_.Bytes / 1GB, 2) } }, Files, Dirs,
    @{n = 'Newest'; e = { if ($_.NewestTicks) { [DateTime]::new($_.NewestTicks, [DateTimeKind]::Utc).ToLocalTime().ToString('yyyy-MM-dd') } } } |
  Export-Csv "$OutPrefix-dirs.csv" -NoTypeInformation
[DuScan]::BigFiles | Sort-Object Bytes -Descending |
  Select-Object Path, @{n = 'GB'; e = { [math]::Round($_.Bytes / 1GB, 2) } }, @{n = 'LogicalGB'; e = { [math]::Round($_.Logical / 1GB, 2) } }, Modified |
  Export-Csv "$OutPrefix-files.csv" -NoTypeInformation
[DuScan]::Denied | Sort-Object | Set-Content "$OutPrefix-denied.txt"
"Wrote $OutPrefix-dirs.csv, -files.csv, -denied.txt"
