# cdrive-pulse

> Let anyone understand and safely slim down their C: drive in 5 minutes.

A Windows C: drive space monitoring and cleanup tool written in pure PowerShell 5.1+:
**works out of the box on any Windows machine, zero dependencies**.
It was distilled from a real cleanup session (July 2026: freed 34 GB from a 116 GB-used C: drive),
turning that hands-on workflow into a reusable, extensible, rule-driven tool.

## Features

- **Six-zone scan**: drive overview + per-rule measurement of well-known hotspot directories
  (caches, app data, system leftovers, dev toolchains...), using `robocopy /L /XJ` for fast,
  junction-loop-safe sizing
- **Four-quadrant classification**: `safeCache` (safe to delete) / `caution` (needs human review) /
  `system` (never delete manually) / `migrate` (move to another drive)
- **Safety rules (non-negotiable)**:
  1. Dry-run is the default; deletion only happens with an explicit `-Execute`
  2. Every path is verified to exist and not be a symlink/junction before deletion (links are skipped with a warning)
  3. Locked / access-denied files are skipped and counted — **processes are never killed**
  4. Sizes are measured before and after deletion, freed space is reported, and everything is logged
- **Before/after diff**: the `report` command compares two scans and shows per-directory freed space
- **Extensible rules**: declarative `rules.json`; paths support `%USERPROFILE%`-style environment
  variables and `*` wildcards, plus fine-grained semantics like "only files older than N days",
  "keep the latest version", and "keep specific files"
- **Dual output**: machine-readable JSON (`out\scan-latest.json`) + human-readable Markdown report (`out\report-latest.md`)

## Quick Start

```powershell
# In the tool directory (no installation; PowerShell 5.1+ required)
powershell -ExecutionPolicy Bypass -File cpulse.ps1 scan
```

Then check:

- `out\report-latest.md` — human-readable report (grouped by category, sorted by size)
- `out\scan-latest.json` — machine-readable result

## Commands

```powershell
# 1. Scan: C: drive capacity + per-rule directory sizes
.\cpulse.ps1 scan

# 2. Dry-run cleanup (default; lists what would be deleted and the estimated space to free)
.\cpulse.ps1 clean -WhatIf

# 3. Actually delete (follows the safety rules; log written to out\clean-log-<timestamp>.txt)
.\cpulse.ps1 clean -Execute

# 4. Compare two scans (freed-space statistics)
.\cpulse.ps1 report old-scan.json new-scan.json

# 5. List the current rule set
.\cpulse.ps1 rules
```

> Tip: before cleaning, back up `out\scan-latest.json`; run `scan` again after cleaning,
> then use `report` to see exactly what was freed.

## Scan Output Format

`out\scan-latest.json`:

```json
{
  "generatedAt": "2026-07-15T10:30:00+08:00",
  "drive": { "totalGB": 237.5, "usedGB": 116.2, "freeGB": 121.3, "percent": 48.9 },
  "groups": [
    {
      "id": "cache-yarn",
      "name": "Yarn global cache",
      "path": "%LOCALAPPDATA%\\Yarn\\Cache",
      "sizeGB": 2.31,
      "category": "safeCache",
      "note": "Package manager download cache; re-downloaded on demand",
      "exists": true
    }
  ]
}
```

Note: `path` in the JSON keeps the environment-variable template — **no real usernames are ever
written**, so scan results are safe to share.

## Rule Format (rules.json)

Each rule:

| Field | Required | Description |
| --- | --- | --- |
| `id` | yes | Unique identifier |
| `name` | yes | Display name |
| `path` | yes | Directory path; supports `%USERPROFILE%`, `%LOCALAPPDATA%`, `%APPDATA%`, `%WINDIR%`, `%SYSTEMDRIVE%`, etc., and `*` wildcards (matches directories) |
| `category` | yes | `safeCache` / `caution` / `system` / `migrate` |
| `action` | yes | `delete` (enters the cleanup list) / `reportOnly` (measure and report only) |
| `note` | no | Explanation text |
| `maxAgeDays` | no | Only delete files older than N days (e.g. Temp) |
| `keepLatestSubdir` | no | When `true`, keep the highest-version subdirectory and delete the rest (e.g. old WPS versions) |
| `keepFiles` | no | Keep these file names when clearing directory contents (e.g. Squirrel's `Update.exe`) |

Only rules with `action = delete` enter the `clean` cleanup list; the rest are measured and
reported by `scan` only.

## Battle Record

Real-world test, July 2026 (Windows 11 dev machine): C: drive usage **116 GB → 83 GB**, freeing **34 GB**.

Main sources: dev toolchain caches (Yarn / npm / pnpm / uv / go-build / Playwright / cargo-xwin),
old WPS versions and add-on caches, video client caches, crash dumps, temp files — plus migrating
cargo / rustup / go / WPSDrive to the D: drive.

## Disclaimer

This tool is provided "as is", without warranty of any kind, express or implied.
`clean -Execute` really deletes files: always run `scan` first to read the report, then
`clean -WhatIf` to review the cleanup list, and judge for yourself whether each rule applies to
your machine. `caution` / `system` rules are report-only by default — never manually delete system
directories (WinSxS, Windows\Installer, etc.); use Disk Cleanup or DISM instead. The authors are
not liable for any data loss caused by using this tool.

## Contributing

Contributions welcome!

- **New rules**: add C: drive hotspots you have personally verified to `rules.json`, with proper
  category and safety semantics, and open a PR
- **Code improvements**: keep `cpulse.ps1` PowerShell 5.1 compatible, dependency-free, with clear
  comments
- **Bug reports**: open an issue with your `out\scan-latest.json` (it contains no personal info)
  and reproduction steps

Conventions: never read or output any sensitive user information; generalize all rule paths with
environment variables — never hard-code a username.

## License

[MIT](LICENSE)
