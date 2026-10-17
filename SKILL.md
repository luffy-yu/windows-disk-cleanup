---
name: windows-disk-cleanup
description: Audit a Windows drive (usually C:) to find what is really using the space and what can safely be deleted, moved to another drive, or uninstalled, then hand the user exact paths and copy-paste PowerShell commands to run. Use this whenever someone says C: or another Windows drive is full, nearly full, low on space or red in Explorer; asks what they can delete, clean up or free; wonders why the disk filled up; or wants to shrink Docker/WSL disks, dev caches (pip, uv, npm, Gradle, Unity, JetBrains), Temp, crash dumps or old installers, even if they never say "audit" or "cleanup".
---

# Windows disk cleanup

Find where a drive's space went, check what is truly reclaimable, and give the user a tiered list with exact paths and commands. You investigate, measure and recommend; the user runs anything destructive.

**Why the user runs the deletes.** Deleting is irreversible and it's their machine. Users have asked for exactly this split ("list the folders and paths and let me run the delete"), and auto mode blocks bulk deletion anyway. If the user explicitly asks you to run a cleanup and the call is blocked, stop and hand over the commands. Don't reach the same result another way (moving the files, `robocopy /MOVE`, the Recycle Bin): that reads as working around the block.

Everything below is read-only until step 7. Paths like `scripts/du_scan.ps1` are relative to this skill's folder (its base directory is shown when the skill loads); call the scripts by full path.

## 1. Baseline

```powershell
Get-Volume | Where-Object DriveLetter | Format-Table DriveLetter, FileSystemLabel, @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}}, @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}} -AutoSize
"Elevated: " + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Get-ChildItem C:\ -Force | Select-Object Mode, LastWriteTime, @{n='GB';e={ if (-not $_.PSIsContainer) { [math]::Round($_.Length/1GB,2) } }}, Name | Format-Table -AutoSize
```

Note which other drives have free space: that's where "move instead of delete" items go. The root listing shows `hiberfil.sys`, `pagefile.sys` and `swapfile.sys`.

## 2. Scan the drive (in the background)

`scripts/du_scan.ps1` takes about 2–3 minutes per million files. Run it in the background and do step 3 meanwhile:

```powershell
pwsh -NoProfile -File "<skill-dir>\scripts\du_scan.ps1" -Root 'C:\' -OutPrefix "<scratch>\cscan"
```

It writes three files to the session scratchpad (or `$env:TEMP`):

- `cscan-dirs.csv`: folders of at least 200 MB, to depth 8, with file count and newest write date.
- `cscan-files.csv`: files of at least 200 MB.
- `cscan-denied.txt`: folders it couldn't read.

Sizes are what the files occupy on disk. Compressed and sparse files count at their allocated size, OneDrive cloud-only placeholders count as zero, and junctions aren't followed.

Browse the result with `scripts/du_kids.ps1` rather than scanning again:

```powershell
& "<skill-dir>\scripts\du_kids.ps1" -Csv "<scratch>\cscan-dirs.csv" -Parent 'C:\', 'C:\Users\<me>\AppData\Local' -MinGB 1
```

Compare the scan total with the volume's used space:

- **Well below used:** some space is invisible to the scan, such as restore points in System Volume Information, other users' profiles, or admin-only folders.
- **Above used:** hard links were counted more than once (see step 5).

## 3. While it scans

These need their own tools:

- **Dev caches.** Ask each tool where its cache lives: `pip cache dir`, `uv cache dir`, `npm config get cache`, `yarn cache dir`, `pnpm store path`, `go env GOCACHE GOMODCACHE`, `dotnet nuget locals all --list`, `conda info`. Skip the ones that aren't installed.
- **WSL and Docker.** `scripts/wsl_docker_report.ps1` is read-only. It reports:
  - each distro's virtual disk and Docker's disk files;
  - each image's unique size;
  - each volume and whether any container uses it;
  - how full Docker's disk is inside the VM.
- **Hibernation and page file.**
  - `powercfg /a` shows whether Hibernate is available.
  - `(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power').HiberbootEnabled` shows whether Fast Startup is on.
  - `Get-CimInstance Win32_PageFileUsage` gives allocated vs peak page-file use.
- **Recycle Bin:** `$rb = (New-Object -ComObject Shell.Application).Namespace(0xA); ($rb.Items() | ForEach-Object { $_.ExtendedProperty('System.Size') } | Measure-Object -Sum).Sum / 1GB`

## 4. Drill down

Work biggest first. The usual order:

1. `AppData\Local` and its `Temp`
2. `AppData\Roaming`
3. the profile's dot-folders (`.cache`, `.gradle`, …)
4. `Program Files*`
5. `ProgramData`
6. `Windows`

Read the big-files CSV too. A few huge single files often explain most of the usage: virtual disks, dumps, backups, ISOs.

- For Temp, Downloads and similar folders, `scripts/age_breakdown.ps1 -Path <dir>` shows size by file age and the newest file in each entry. Recent writes hint that something still uses it.
- `references/hotspots.md` covers the usual space hogs: where each lives, how to confirm it, what's safe and how to stop it regrowing. Read the entries that match what you found, and its "Measurement gotchas" section before trusting any number.

## 5. Verify before recommending

Folder sizes can mislead, and folders that look like junk are sometimes live data. Before an item goes in the "safe to delete" tier, check:

- **Real size.** Caches that hard-link into environments (uv, conda `pkgs`, the pnpm store) and WinSxS show several times their real footprint. `scripts/linkunion.ps1 -Root <dir>` reports the real on-disk size and what deleting the whole tree would free. One uv cache showed 25 GB but held 3.6 GB.
- **What it is.** Look inside unknown folders and read the names.
  - Crash dump names include the crashing process's path.
  - Randomly named `xxxxxxxx.xxx` folders in Temp are often Visual Studio Installer extractions.
  - For a huge VS Code C/C++ `.BROWSE.VC.DB`, `python -I scripts/cpptools_db_paths.py <db>` shows which workspace and folders it indexed.
- **Whether it's in use.**
  - Check for the owning app's process, `go` builds, Gradle daemons (`java` with `GradleDaemon` in the command line) and Python running from a cache environment.
  - A Windows venv's `python.exe` only launches the base interpreter. A process running from a venv therefore shows as `C:\PythonXY\python.exe`, with the venv launcher as its parent, so check parents and command lines.
  - An SQLite file with a freshly written `-wal`/`-shm` beside it is open.
- **Data vs cache.**
  - Docker's "RECLAIMABLE" counts everything no container uses, including your images and volumes full of project data. Check each volume's creation date and look inside read-only (`docker run --rm -v <vol>:/v:ro alpine du -sh /v/*`).
  - An image's *unique* size is what removing it frees. Untagged `<none>` images often share almost all their layers with the tagged one.
  - Backups, chat history and Downloads are personal: suggest moving them, not deleting them.
- **Whether an app is still used.** The newest file in its config folder (`AppData\Roaming\<Vendor>\<Product><Version>`) and the uninstall registry show which versions are current and which have gone untouched for years.
- **Windows Installer.** `scripts/msi_orphans.ps1` lists files in `C:\Windows\Installer` that no product or patch references. Only these orphans are candidates, and they get moved, not deleted. Windows needs the registered files to repair, patch and uninstall.

If you couldn't check something (it needs admin, or a tool is missing), say so rather than guessing a size.

## 6. Report

Open with the drive's size and free space and a one-line summary. Then list the tiers, biggest item first, each with a size, an exact path and a one-line reason:

```
C: is 476 GB with 21 GB free. About 90 GB is cache and crash data you can delete today; moving Docker's disk to D: frees another 60 GB. Nothing has been deleted.

### Safe to delete now (~N GB)
| Size | What | Notes |          <- path under What; owner, why it's safe and which app to close under Notes
### Move to D: instead of deleting   <- large live data: VM disks, backups
### Needs an admin prompt            <- hiberfil, installer orphans, system cleanup
### Uninstall if unused              <- with the usage signal behind it
### Keep it from coming back         <- settings that stop the regrowth
Not worth touching: …                <- one line, so the user knows you looked
```

End by offering to list the paths with commands.

## 7. Hand over the commands

When the user wants to act, give exact paths and copy-paste PowerShell, one block per item, with sizes in comments:

- **Delete:** `Remove-Item -LiteralPath '<path>' -Recurse -Force`. Use `-LiteralPath`, because `-Path` treats `[` and `]` in names as wildcards. To empty a folder: `Get-ChildItem -LiteralPath '<dir>' -Force | Remove-Item -Recurse -Force`.
- **Use the tool's own cleaner** where one exists: `pip cache purge`, `uv cache clean`, `go clean -cache`, `npm cache clean --force`, `dotnet nuget locals all --clear`, `docker image rm <img>`.
- **Say which app to close first and which steps need an admin window.** Mention that `-WhatIf` previews any `Remove-Item`.
- **Move a folder to another drive** with `robocopy <src> <dst> /E /MOVE`. Windows PowerShell 5.1's `Move-Item` can't move folders across volumes; it's fine for single files.
- **Guard commands that pick their own targets** (orphaned installer files, Temp folders chosen by content). They should print the set first and refuse to act if the count looks wrong; otherwise one failed lookup turns "everything" into the target.
- **For many items, offer one script** built from `assets/cleanup_template.ps1`. Its helpers skip a step while the owning app is running and print the GB freed per item. Fill in its STEPS section and save it where the user can open it.

After the user has run the commands, check free space again and compare it with the expected total.
