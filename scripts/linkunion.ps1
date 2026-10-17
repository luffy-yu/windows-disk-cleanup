<#
.SYNOPSIS
  Real on-disk size of a tree whose files may be hard-linked, and what deleting the whole tree frees.
.DESCRIPTION
  Groups files by NTFS file ID. "Real on disk" counts each distinct file once; "freed if
  deleted" counts only files whose every hard link lives inside the tree. Use it before
  recommending deletion of caches that hard-link into environments (uv, conda pkgs, pnpm
  store) or anything under WinSxS. Read-only; opens each file for attributes only.
.EXAMPLE
  & .\linkunion.ps1 -Root "$env:LOCALAPPDATA\uv\cache"
#>
param([Parameter(Mandatory)][string]$Root)
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class LinkUnion
{
    // FILETIME is 4-byte aligned natively; Pack = 4 keeps the longs from being padded to offset 8.
    // Without it, Links reads the file-index field and every file looks hard-linked.
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct BY_HANDLE_FILE_INFORMATION {
        public uint Attr; public long Ctime, Atime, Wtime;
        public uint Vol, SizeHigh, SizeLow, Links, IdxHigh, IdxLow;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle h, out BY_HANDLE_FILE_INFORMATION info);

    // returns { apparentBytes, uniqueBytes, freedBytes, uniqueFiles, freedFiles, errors }
    public static long[] Measure(string root)
    {
        var o = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint };
        var seen = new Dictionary<ulong, long[]>(); // id -> { timesSeen, links, size }
        long apparent = 0, errors = 0, loose = 0;
        foreach (var f in new DirectoryInfo(root).EnumerateFiles("*", o))
        {
            apparent += f.Length;
            using (var h = CreateFileW(f.FullName, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero))
            {
                BY_HANDLE_FILE_INFORMATION i;
                if (h.IsInvalid || !GetFileInformationByHandle(h, out i)) { errors++; loose += f.Length; continue; }
                ulong id = ((ulong)i.IdxHigh << 32) | i.IdxLow;
                long[] e;
                if (seen.TryGetValue(id, out e)) e[0]++;
                else seen[id] = new long[] { 1, i.Links, f.Length };
            }
        }
        long unique = loose, freed = loose, uf = 0, ff = 0;
        foreach (var e in seen.Values) { unique += e[2]; uf++; if (e[0] >= e[1]) { freed += e[2]; ff++; } }
        return new long[] { apparent, unique, freed, uf, ff, errors };
    }
}
'@
$m = [LinkUnion]::Measure($Root)
"{0}`n  apparent {1:N2} GB | real on disk {2:N2} GB ({3:N0} distinct files) | freed if whole tree deleted {4:N2} GB ({5:N0} files) | unreadable {6}" -f $Root, ($m[0] / 1GB), ($m[1] / 1GB), $m[3], ($m[2] / 1GB), $m[4], $m[5]
