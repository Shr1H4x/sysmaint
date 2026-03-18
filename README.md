# sysmaint

> A smart, interactive system maintenance function for Debian/Ubuntu-based systems — built for Kali Linux with zsh support.

---

## Features

- **Interactive task menu** — pick exactly what you want to run, no more, no less
- **Upgrade preview** — shows a formatted table of packages before upgrading
- **Package integrity check** — runs `dpkg --verify` and parses results cleanly
- **Flatpak & Snap support** — auto-detected, only shown if installed
- **Lock file** — prevents overlapping runs with stale PID detection
- **Sudo check** — fails early and cleanly if access is denied
- **Log rotation** — per-run timestamped logs, auto-deletes after 14 days
- **Log levels** — every line tagged `INFO` / `WARN` / `ERROR` / `SKIP` / `CMD`
- **System snapshot** — disk space and package count before and after
- **Run summary** — shows what ran, what was skipped, what failed, time taken
- **Spinner** — progress indicator on long-running commands
- **Desktop notification** — `notify-send` on completion or failure
- **Colour output** — green pass, red fail, yellow warn, blue skip
- **`--quiet` mode** — suppresses everything except errors
- **`--dry-run` mode** — shows what would run without executing anything

---

## Requirements

- zsh or bash
- Debian/Ubuntu-based system (`apt`, `dpkg`)
- `sudo` access
- Optional: `flatpak`, `snap`, `notify-send`

---

## Installation

**1. Clone or download**

```bash
git clone https://github.com/ShriHax-21/sysmaint.git
```

**2. Add to your shell config**

```bash
echo 'source ~/sysmaint/sysmaint.zsh' >> ~/.zshrc
source ~/.zshrc
```

Or paste the function directly into your `~/.zshrc` / `~/.bashrc`.

---

## Usage

```bash
sysmaint                  # Interactive menu — pick tasks by number
sysmaint --auto           # Ask y/n per task, then run selected automatically
sysmaint --dry-run        # Show what would run without executing
sysmaint --full           # Include apt full-upgrade in task list
sysmaint --quiet          # Suppress all output except errors
sysmaint --auto --full    # Full upgrade, auto-confirm all
sysmaint --dry-run --full # Preview full upgrade run
sysmaint --help           # Show usage
```

---

## Task Menu

When run interactively, you get a numbered menu:

```
╔══════════════════════════════════════╗
║    sysmaint — System Maintenance     ║
╚══════════════════════════════════════╝

  Select tasks to run (e.g. 1 2 3 or 'all'):

  [1]  apt update       — refresh package index
  [2]  apt upgrade      — upgrade all packages
  [3]  apt autoremove   — remove unused dependencies
  [4]  apt clean        — clear downloaded package cache
  [5]  dpkg verify      — check installed package integrity
  [6]  flatpak update   — update Flatpak packages  (if installed)
  [7]  snap refresh     — update Snap packages      (if installed)

  ▶  Enter numbers (space separated) or 'all':
```

---

## Upgrade Preview

After `apt update`, sysmaint shows a formatted table of upgradable packages before running upgrade:

```
[01:23:45] [INFO] 12 package(s) available to upgrade:

  Package                             Version
  ─────────────────────────────────────────────
  curl                                8.5.0-2
  libssl3                             3.1.4-2
  ...
```

---

## Run Summary

Every run ends with a full summary:

```
╔══════════════════════════════════════╗
║             Run Summary              ║
╚══════════════════════════════════════╝

  ✔  Ran      : apt update apt upgrade apt autoremove apt clean
  ⊘  Skipped  : dpkg verify
  ✘  Failed   : none

  Disk free   : 8.9G → 9.2G
  Packages    : 1927 → 1931
  Time taken  : 47s
  Log saved   : /home/user/.sysmaint/logs/sysmaint-20260318_012320.log
```

---

## Logs

Logs are stored at:

```
~/.sysmaint/logs/sysmaint-YYYYMMDD_HHMMSS.log
```

Logs older than **14 days** are automatically deleted on each run. To change retention:

```bash
# Inside the function, edit this line
local LOG_RETENTION_DAYS=14
```

---

## Flags Reference

| Flag | Description |
|------|-------------|
| `--dry-run` | Preview all commands without executing |
| `--auto` | Prompt y/n per task instead of menu |
| `--full` | Add `apt full-upgrade` to task list |
| `--quiet` | Suppress all output except errors |
| `--help` | Show usage |

---

## Known Behaviour

- Flatpak and Snap tasks only appear in the menu if the tools are installed
- `dpkg --verify` output is saved to log only — terminal shows a clean pass/fail summary
- Lock file at `/tmp/sysmaint.lock` is auto-removed on exit; stale PIDs are detected and cleared
- Non-interactive shells (e.g. cron) skip prompts and log a `[SKIP]` entry

---

## Author

**ShriHax** — [shrijesh.com.np](https://shrijesh.com.np) · [GitHub: ShriHax-21](https://github.com/ShriHax-21)

---

## License

MIT License — do whatever you want, just don't remove the attribution.
