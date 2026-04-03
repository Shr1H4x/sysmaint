# sysmaint (Zsh) — System Maintenance Wrapper

A small interactive **Zsh** wrapper to run common system maintenance tasks (APT / Flatpak / Snap) with **logging**, **progress UI**, a **snapshot menu option**, and a **smart skip** for upgrades when nothing is available.

> Tested/targeted for Debian-based systems (including Kali).  
> Requires `zsh` and `sudo`.

---

## Features

- **Interactive menu** to select tasks (numbers or `all`)
- **Log file per run** stored under `~/.sysmaint/logs/`
  - Log filename includes CLI flags (e.g. `--dry-run__quiet`)
  - Automatic log cleanup (keeps last **14 days**)
- **Progress UI**
  - Spinner for operations without a simple progress signal (e.g. `apt-get update`)
  - Upgrade progress bar driven by dpkg stage parsing (`Preparing to unpack`, `Unpacking`, `Setting up`)
- **Snapshot support (manual menu option)**
  - Prefers **Timeshift** if available
  - Falls back to **Btrfs snapshot** (if `/` is btrfs and `btrfs` tool is present)
- **Smart upgrade skip**
  - If no packages are available to upgrade, the tool **skips upgrade** (no header/progress noise)
- **Network awareness**
  - Basic connectivity check; warns when offline

---

## Requirements

### Required
- `zsh`
- `sudo`
- `coreutils` (for `stdbuf`, `df`, etc.)
- `awk`, `sed`, `grep`, `tr`

### Package managers (optional but used by tasks)
- `apt-get` (Debian/Kali)
- `flatpak` (only needed if you want the Flatpak task)
- `snap` (only needed if you want the Snap task)

### Snapshot tools (optional)
- **Timeshift** (`timeshift`) for snapshot creation (preferred)
- **Btrfs** (`btrfs`) + root filesystem on btrfs for btrfs snapshot fallback

---

## Install

1. Save the script as `sysmaint_V2.2.2.sh` (or any name you prefer):
   ```sh
   chmod +x sysmaint_V2.2.2.sh
   ```

2. Run it:
   ```sh
   ./sysmaint_V2.2.2.sh
   ```

---

## Usage

### Interactive menu (recommended)
```sh
./sysmaint_V2.2.2.sh
```

Choose tasks by number (e.g. `1 2 4`) or type `all`, then confirm.

### Common flags

- `--dry-run`  
  Print the commands that would run without making changes.
  ```sh
  ./sysmaint_V2.2.2.sh --dry-run
  ```

- `--quiet`  
  Reduce terminal output (still writes logs).
  ```sh
  ./sysmaint_V2.2.2.sh --quiet
  ```

- `--no-snapshot`  
  Disables snapshot creation even if you select the `snapshot` task.
  ```sh
  ./sysmaint_V2.2.2.sh --no-snapshot
  ```

> Note: This tool does **not** automatically create snapshots before upgrades in this revision.  
> Snapshots happen only if you select the `snapshot` task from the menu (unless disabled with `--no-snapshot`).

---

## Tasks (menu options)

Typical menu entries:

- `apt update` — refresh package index
- `apt upgrade` — upgrade all packages (**auto-skips if nothing to do**)
- `apt autoremove` — remove unused dependencies
- `apt clean` — clear downloaded package cache
- `dpkg verify` — verify installed package integrity
- `flatpak update` — update Flatpak packages (only if Flatpak is installed)
- `snap refresh` — update Snap packages (only if Snap is installed)
- `snapshot` — create system snapshot (Timeshift/Btrfs)

---

## Logs

- Logs are stored in:
  - `~/.sysmaint/logs/`

Example log filename:
- `sysmaint-20260403_211004--noflags.log`
- `sysmaint-20260403_211004--dry-run__quiet.log`

---

## Safety notes / disclaimers

- This tool runs real system package operations with `sudo`.
- Snapshots are **best-effort** and **not guaranteed**:
  - Timeshift snapshot IDs are extracted from command output (may vary by version)
  - Btrfs snapshot behavior depends on your system layout and permissions
- The upgrade progress bar is based on parsing dpkg/apt output and may behave differently across distributions.

---

## Troubleshooting

### “command not found” errors (e.g. `parse_args`, `init_logging`)
This usually happens when the script file got **appended** accidentally (two scripts glued together) or is truncated.

Fix by rewriting the file using overwrite (not append), e.g.:

```sh
cat > sysmaint_V2.2.2.sh <<'EOF'
# paste the full script here
EOF
chmod +x sysmaint_V2.2.2.sh
```

### No progress bar during upgrade
The progress UI relies on dpkg stage lines. If your system’s output format differs, it may not detect packages.
Check the log file and confirm lines like:
- `Preparing to unpack ...`
- `Unpacking ...`
- `Setting up ...`

---

## License

Choose one:
- MIT
