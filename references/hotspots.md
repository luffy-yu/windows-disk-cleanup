# Windows disk-space hotspots

Where space usually goes on a Windows developer machine, how to confirm each item, what is safe, and how to stop it coming back. Read the sections that match what the scan found.

1. [Measurement gotchas](#1-measurement-gotchas)
2. [User profile: caches and temp](#2-user-profile-caches-and-temp)
3. [Virtual machines and containers](#3-virtual-machines-and-containers)
4. [System areas (mostly admin)](#4-system-areas-mostly-admin)
5. [Apps and personal data](#5-apps-and-personal-data)

---

## 1. Measurement gotchas

- **Hard links.** A simple scan counts a hard-linked file once per link. WinSxS (linked with System32) and caches that link into environments look far bigger than they are, and deleting one link frees nothing while another exists. These include uv's `archive-v0` and `environments-v2`, conda `pkgs`, and the pnpm store. `scripts/linkunion.ps1` groups files by ID: one uv cache showed 25 GB apparent but 3.6 GB real.
- **P/Invoke layout.** `BY_HANDLE_FILE_INFORMATION` needs `[StructLayout(LayoutKind.Sequential, Pack = 4)]`, because FILETIME is 4-byte aligned. With default packing, the link-count field reads the file index and every file looks hard-linked.
- **Cloud placeholders.** OneDrive Files On-Demand files (attribute `0x400000` RECALL_ON_DATA_ACCESS) report their full size but take no local space.
- **Compressed, sparse and WOF/CompactOS files.** `Length` overstates their size. `GetCompressedFileSizeW` gives the allocated size; sparse WSL disks need it too.
- **Junctions and symlinked folders.** Don't follow them: `Documents and Settings`, `Application Data` and the like would be counted twice or loop.
- **Unelevated scans** can't read System Volume Information, other users' profiles or parts of Windows. Compare the scan total with the volume's used space; a big shortfall is usually restore points or other users' data.
- **Windows venv launchers.** `.venv\Scripts\python.exe` starts the base interpreter, so a process running from a venv shows up as `C:\PythonXY\python.exe` with the launcher as its parent.
- **Shell pitfalls.**
  - `pwsh -File script.ps1 -Arr a,b` passes one string, not an array. From PowerShell, call `& 'script.ps1' -Arr a, b`.
  - `Remove-Item -Path` treats `[` and `]` as wildcards; use `-LiteralPath`.
  - Windows PowerShell 5.1's `Move-Item` can't move folders across volumes; use `robocopy <src> <dst> /E /MOVE`.
  - Git Bash rewrites arguments that start with `/`. Run Windows tools from PowerShell, or set `MSYS_NO_PATHCONV=1`.

## 2. User profile: caches and temp

### VS Code C/C++ extension index

- **Where:**
  - Per-workspace symbol databases: `%LOCALAPPDATA%\Microsoft\vscode-cpptools\<hash>\.BROWSE.VC.DB`, with `-wal` and `-shm` beside them.
  - IntelliSense cache: `...\vscode-cpptools\ipch`.
  - Older versions: `%APPDATA%\Code\User\workspaceStorage\<id>\ms-vscode.cpptools\`.
- **Confirm:** there is one folder per workspace. The one in use has a `-wal`/`-shm` written today and a running `cpptools` process. `scripts/cpptools_db_paths.py <db>` shows what a big one indexed. Tens of GB usually means build output, a Unity `Library`/`Build` folder or a venv got indexed; one 55 GB database plus a 10 GB `-wal` came from a Unity project's `Build` folder.
- **Safe:** delete the folders that aren't in use. They rebuild when the workspace is next opened.
- **Prevent:** add `"C_Cpp.files.exclude": {"**/Build": true, "**/Library": true, "**/.venv*": true}` to that workspace's `.vscode/settings.json`, or disable the extension for that workspace. Otherwise the database grows back.

### WSL crash dumps

- **Where:** `%TEMP%\wsl-crashes\*.dmp`. The name includes the crashing Linux process's path (for example `…_opt_conda_envs_<env>_bin_python3.12-6.dmp`), including processes inside Docker containers. A crashing ML job can leave 9–13 GB per dump.
- **Safe:** delete them, unless someone is debugging the crash.
- **Prevent:** in `%USERPROFILE%\.wslconfig`, under `[wsl2]`, set `maxCrashDumpCount=2`. The default is 10, and the oldest dump is deleted first. Newer WSL also has `crashDumpFolder` to send dumps to another drive. Changes take effect after `wsl --shutdown`. Docs: https://learn.microsoft.com/en-us/windows/wsl/wsl-config
- Repeated dumps from one service (for example a database container's `mongod`) mean it keeps crashing. Mention it.

### Windows crash dumps and error reports

- **Where:** `%LOCALAPPDATA%\CrashDumps`. Admin-only: `C:\ProgramData\Microsoft\Windows\WER\ReportArchive` and `ReportQueue`, `C:\Windows\MEMORY.DMP`, `C:\Windows\Minidump`.
- **Safe:** delete them. Disk Cleanup's "System error memory dump files" covers the system ones.

### Temp folder (`%TEMP%`)

Break it down with `scripts/age_breakdown.ps1`. Recognizable leftovers:

- **Visual Studio Installer** (several GB):
  - randomly named `xxxxxxxx.xxx` folders holding `setup.exe`, `vswhere.exe`, `vs_layout.exe` and `feedback.exe`;
  - folders holding `BackgroundDownload.exe` with `Microsoft.VisualStudio.*.dll`;
  - randomly named folders full of `Microsoft.*` / `Win10SDK*` package payloads.

  They're safe to delete when no `vs_installer`, `vs_installershell`, `vs_setup_bootstrapper` or `BackgroundDownload` process is running, and the installer runs from `…\Microsoft Visual Studio\Installer\`. They come back: the updater runs several times a day. Many empty random folders free nothing, so leave them alone.
- **Remote Desktop client traces:** `DiagOutputDir\RdClientAutoTrace`. Safe to delete.
- **In use, leave alone:**
  - `go-build<n>` folders of running `go test` processes;
  - `<GUID>\swap.vhdx`, the WSL swap file while WSL runs;
  - folders of running apps;
  - `claude\<project>\<session>` for active Claude Code sessions (old sessions are fine to delete).
- Identify anything modified in the last day before recommending it.

### Package-manager caches

| Tool | Find it | Clean with | Notes |
|---|---|---|---|
| pip | `pip cache dir` | `pip cache purge` | |
| uv | `uv cache dir` | `uv cache clean` (`uv cache prune` for unused only) | Hard links; measure with linkunion. Not while a process runs from a cached environment. |
| npm | `npm config get cache` | `npm cache clean --force` | |
| yarn | `yarn cache dir` | `yarn cache clean` | |
| pnpm | `pnpm store path` | `pnpm store prune` | Hard-linked into `node_modules` |
| Go | `go env GOCACHE GOMODCACHE` | `go clean -cache`, `go clean -modcache` | Not while a `go` build or test runs |
| NuGet | `dotnet nuget locals all --list` | `dotnet nuget locals all --clear` | |
| Gradle | `~\.gradle\caches`, `wrapper\dists`, `daemon` | delete those three | Keep `gradle.properties` and `init.d`; no Gradle daemon running |
| Maven | `~\.m2\repository` | delete | |
| Cargo | `~\.cargo\registry` | delete `cache` and `src` | |
| conda | `conda info` (package cache dirs) | `conda clean --all` | `pkgs` hard-linked into envs |

### ML and data caches

- **Locations:** Hugging Face `~\.cache\huggingface` (or `$env:HF_HOME`), torch `~\.cache\torch`, ClearML `~\.clearml\cache\storage_manager`, and similar (`~\.paddleseg`, `~\.keras`, `~\.cache\*`).
- **Safe** when they're re-downloadable and nothing running uses them. Note the cost of downloading large models or datasets again.

### Unity

- **Package Manager global cache:** `%LOCALAPPDATA%\Unity\cache` (`npm`, `packages`, `upm`). Safe with Unity closed; it's re-downloaded on demand. Often 10–20 GB.
- **Downloaded Asset Store packages:** `%APPDATA%\Unity\Asset Store-5.x`. The user's call.
- **Editors:** 5–10 GB each. Uninstall unused versions from Unity Hub.

### JetBrains IDEs

- **Where:**
  - Caches and indexes: `%LOCALAPPDATA%\JetBrains\<Product><Version>`. These include `tmp\patch-update\*.jar`, often over 1 GB.
  - Config and plugins: `%APPDATA%\JetBrains\<Product><Version>`.
- **Stale:** folders for versions older than the newest one in use. The newest file date in the Roaming folder shows when a version was last used. The IDEs also offer "Delete old IDE data" at startup.
- **Installs:** `C:\Program Files\JetBrains\…` (uninstall in Settings → Apps) or JetBrains Toolbox.

### Browsers and chat apps

- **Chrome/Edge caches** live in `User Data\<Profile>\`. Clear them from the browser's settings, not by deleting files while it runs.
- **WeChat:**
  - 3.x data: `Documents\WeChat Files`.
  - 4.x data: `%USERPROFILE%\xwechat_files`, including an `old_backup` folder.
  - Old 3.x update packages: `C:\ProgramData\Tencent\WeChat\patch`, safe once the user is on 4.x.

  Delete old data folders only after the user confirms their history shows up in the new version.
- **Slack, Teams, Lark/Feishu, DingTalk:** clear caches from inside the app.

### Shader and GPU caches

- `%LOCALAPPDATA%\NVIDIA\DXCache`, `%LOCALAPPDATA%\NVIDIA\GLCache`, `%LOCALAPPDATA%\D3DSCache` and games' `shadercache` folders. Safe to delete; they regrow.

## 3. Virtual machines and containers

### Docker Desktop (WSL 2 backend)

- **Where:** all images, containers and volumes live in one virtual disk under `%LOCALAPPDATA%\Docker\wsl\`.
  - Older versions register a `docker-desktop-data` distro and use `wsl\data\ext4.vhdx`.
  - Newer versions use a `docker_data.vhdx` there instead.

  `scripts/wsl_docker_report.ps1` lists whatever is present.
- **Inside the disk:** run `docker system df -v`. "RECLAIMABLE" is not the same as junk:
  - Untagged `<none>` images usually share almost all their layers with the tagged build, so removing them frees little; check unique size.
  - Volumes with no container (links 0) can be live project data; check the creation date and look inside read-only.
  - Old base images nobody uses (years old, nothing built on them) are the real wins.
- **Room to grow:** `df -h` inside the VM (`wsl -d docker-desktop -e df -h`) shows the inner filesystem's size. Size minus used is how much more the disk file can grow. Flag it if that exceeds the drive's free space.
- **The disk file doesn't shrink after pruning.** Two options:
  - **Move it to another drive.** This frees the whole file. Newer Docker Desktop versions can do it from Settings → Resources → Advanced (disk image location). Older ones use this procedure:
    ```powershell
    # Quit Docker Desktop first (this stops every container)
    wsl --shutdown
    wsl --export docker-desktop-data D:\docker-desktop-data.tar
    "{0:N1} GB" -f ((Get-Item D:\docker-desktop-data.tar).Length / 1GB)   # check before going on
    wsl --unregister docker-desktop-data      # deletes the old disk: only after a complete export
    New-Item -ItemType Directory -Force D:\Docker\wsl\data | Out-Null   # wsl --import won't create missing parents (ERROR_PATH_NOT_FOUND)
    wsl --import docker-desktop-data D:\Docker\wsl\data D:\docker-desktop-data.tar --version 2
    # start Docker Desktop only after the import finishes; confirm volumes/images, then delete the tar
    ```
    Exporting and importing 150 GB takes tens of minutes, and the target drive temporarily needs about twice the disk's size free.
  - **Compact it in place** (admin). Prune first, run `wsl --shutdown`, then in `diskpart` run `select vdisk file="<vhdx>"`, `attach vdisk readonly`, `compact vdisk`, `detach vdisk`. Where Hyper-V tools are installed, `Optimize-VHD -Path <vhdx> -Mode Full` does the same.

### WSL distributions

- **Where:** `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss\{guid}` → `BasePath` holds `ext4.vhdx`. Store distros live under `%LOCALAPPDATA%\Packages\<Distro>\LocalState`. The report script lists each with its size and last write.
- **Moving one:**
  - `wsl --export <name> D:\x.tar`, `wsl --unregister <name>`, `New-Item -ItemType Directory -Force D:\WSL\<name>`, then `wsl --import <name> D:\WSL\<name> D:\x.tar`. `wsl --import` creates only the last folder of the path; a missing parent fails with `Wsl/ERROR_PATH_NOT_FOUND`.
  - After the import the default user is root; fix it with `[user] default=<user>` in the distro's `/etc/wsl.conf`.
  - Recent WSL versions also offer `wsl --manage <name> --move <dir>` (check `wsl --help`).
- **Shrinking one:** `wsl --manage <name> --set-sparse true` on recent WSL, or the `diskpart` compact above.
- Unregistering deletes the distro and everything in it.

### Android SDK and emulators

- **Where:** `%LOCALAPPDATA%\Android\Sdk`:
  - `system-images`: emulator images, 2+ GB each;
  - `ndk\<version>`: several GB each, and Unity or Gradle builds may pin a version;
  - `emulator`.

  Emulators (AVDs) and their data live in `%USERPROFILE%\.android\avd`.
- **Remove** through Android Studio's SDK Manager and Device Manager.

### Other virtual machine disks

- `.vhdx`, `.vmdk` and `.vdi` files under `Documents\Virtual Machines`, `%USERPROFILE%\VirtualBox VMs` or `C:\ProgramData\Microsoft\Windows\Virtual Hard Disks`. The big-files list catches them. They're data: move them, don't delete them.

## 4. System areas (mostly admin)

### Hibernation file: `C:\hiberfil.sys`

- **Size:** about 40% of RAM.
- **Check:** `powercfg /a`, and `HiberbootEnabled` under `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power` (that's Fast Startup).
- **Remove:** if Fast Startup is off and the user never hibernates, `powercfg /h off` (admin) removes the file; `powercfg /h on` restores it. If they want Fast Startup but not Hibernate, use `powercfg /h /type reduced`.

### Page file: `C:\pagefile.sys`

- Windows manages its size. Compare `AllocatedBaseSize` with `PeakUsage` (from `Win32_PageFileUsage`).
- Shrinking it is rarely worth it: crash dumps and heavy workloads need it. It can move to another drive in System Properties → Advanced → Performance, which takes a reboot.

### `C:\Windows\Installer`

- These are the MSI/MSP copies Windows needs to repair, patch and uninstall software. Never delete registered ones.
- **Orphans:** `scripts/msi_orphans.ps1` lists them. Adobe Acrobat is a frequent source, leaving a duplicate ~0.9 GB patch per update.
- **Moving orphans:** from an admin prompt, move them to another drive and keep them for a while. Recompute the set in that same session, and refuse if the counts look wrong, for example:
  ```powershell
  # inside an admin PowerShell, after building $keep (registered LocalPackage paths, for SID s-1-1-0) as msi_orphans.ps1 does
  $orphans = Get-ChildItem C:\Windows\Installer -File -Force | Where-Object { $_.Extension -in '.msi', '.msp' -and -not $keep.Contains($_.FullName) }
  if ($keep.Count -ge <expected registered - margin> -and $orphans.Count -le <expected orphans + margin>) { $orphans | Move-Item -Destination D:\Installer-orphans }
  ```
- Leave `$PatchCache$` alone.

### Component store: `C:\Windows\WinSxS`

- It's hard-linked with System32, so Explorer overstates its size.
- Admin: `Dism /Online /Cleanup-Image /AnalyzeComponentStore`, then `/StartComponentCleanup`. Adding `/ResetBase` also removes superseded versions, which makes installed updates permanent.

### Windows Update, Delivery Optimization, Windows.old

- Use Settings → System → Storage → Temporary files, or Disk Cleanup → "Clean up system files". The relevant items are Windows Update Cleanup, Delivery Optimization Files and Previous Windows installation(s).

### System Restore / shadow copies

- Invisible to unelevated scans (System Volume Information).
- Admin: `vssadmin list shadowstorage`. Adjust under System Properties → System Protection → Configure.

### Installer and driver extraction folders

- **Vendor installers that unpack at the drive root and leave files behind:** `C:\Autodesk` (Autodesk says it's deletable after install; a repair downloads again), `C:\SWSetup` (HP), `C:\Intel`, `C:\AMD`, `C:\NVIDIA`. Safe when the installer isn't running; check the dates.
- **Leave:** `C:\ProgramData\Package Cache` (Visual Studio and other bundles), which repair and uninstall need.
- **Don't delete by hand:** `C:\ProgramData\Microsoft\VisualStudio\Packages` is the VS Installer's own cache. Turn off "keep download cache" in the installer instead.

### Recycle Bin

- Size it via `Shell.Application` namespace `0xA` (SKILL.md step 3). Empty it from Explorer.

## 5. Apps and personal data

### Installed apps

- **List them:** `Get-ItemProperty` over
  - `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*`
  - `HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*`
  - `HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*`

  The useful fields are `DisplayName`, `DisplayVersion`, `InstallDate` and `InstallLocation`.
- **Signs a version is unused:** a newer version of the same product is installed, or its config folders haven't been touched for years.
- **Report** these as "uninstall if unused", with the signal. Uninstall through Settings → Apps.

### Apple device backups

- **Where:** `%USERPROFILE%\Apple\MobileSync\Backup` (Apple Devices or Store iTunes), or `%APPDATA%\Apple Computer\MobileSync\Backup` (classic iTunes). Each backup folder's `Info.plist` holds `Device Name`, `Product Type` and `Last Backup Date`.
- **Personal data:** suggest moving old-device backups to another drive. Look for manual `.zip`/`.7z` copies of the same backup sitting beside it; they can double or triple the space one backup takes.

### Downloads, Videos, Documents

- List the largest items with their dates. Never put them in the "safe to delete" tier.

### Claude Code

- `%USERPROFILE%\.claude\projects\**\*.jsonl` holds conversation history; leave it.
- `%TEMP%\claude` holds session scratchpads. Leave active sessions; old ones are fine to delete.
