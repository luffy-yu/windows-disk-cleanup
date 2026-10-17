# windows-disk-cleanup

A Claude Code skill that finds out what is using space on a Windows drive (usually C:) and what can safely go. Claude scans the drive and checks each candidate: its real size on disk, whether it's in use, and whether it's a cache or real data. You then get a tiered list with exact paths and copy-paste PowerShell commands.

Claude doesn't delete anything; you run the commands.

## Using it

Just ask Claude Code, in any project. For example: "my C drive is almost full", "what can I delete?", "Docker is eating my disk". The skill loads automatically, or you can run it with `/windows-disk-cleanup`.

You get:

1. A report in tiers: **safe to delete now**, **move to another drive**, **needs an admin prompt**, **uninstall if unused**, and **keep it from coming back** (settings that stop regrowth).
2. When you're ready, paths and commands for each item, or a single cleanup script that skips anything whose app is still running and prints the GB freed.

## What's inside

| Path | What it is |
|---|---|
| `SKILL.md` | The workflow Claude follows |
| `references/hotspots.md` | Common space hogs (where they live, how to confirm, what's safe, how to stop regrowth) and measurement pitfalls |
| `scripts/du_scan.ps1` | Fast on-disk size scan to CSV (about 2–3 minutes per million files) |
| `scripts/du_kids.ps1` | Browse the scan's CSV by folder |
| `scripts/linkunion.ps1` | Real size of hard-linked trees (uv, conda, pnpm, WinSxS) and what deleting one frees |
| `scripts/age_breakdown.ps1` | Folder size by file age, with the newest file in each entry |
| `scripts/wsl_docker_report.ps1` | WSL disks; Docker images (unique size), volumes, and room to grow |
| `scripts/msi_orphans.ps1` | Files in `C:\Windows\Installer` that nothing references any more |
| `scripts/cpptools_db_paths.py` | Which folders a huge VS Code C/C++ index covers |
| `assets/cleanup_template.ps1` | Skeleton for the run-it-yourself cleanup script |
| `evals/evals.json` | Test prompts for evaluating the skill |

All the scripts are read-only and work on their own:

```powershell
pwsh -File .\scripts\du_scan.ps1 -Root C:\ -OutPrefix $env:TEMP\cscan
& .\scripts\du_kids.ps1 -Csv $env:TEMP\cscan-dirs.csv -Parent 'C:\Users' -MinGB 1
& .\scripts\linkunion.ps1 -Root "$env:LOCALAPPDATA\uv\cache"
```

## Requirements

- Windows with PowerShell 7 (`pwsh`). The scanners use .NET APIs that Windows PowerShell 5.1 lacks.
- Python 3, only for `cpptools_db_paths.py`.
- Docker and WSL are optional; their checks are skipped when not installed or not running.
- Some checks see more from an admin prompt: other users' installer packages, restore points, `hiberfil.sys`.

Built from a real audit of a nearly full developer workstation; the checks and scripts are the ones that audit needed.
