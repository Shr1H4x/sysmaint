# sysmaint (Zsh) — Debian update client

An interactive **Zsh** wrapper for common Debian/Kali maintenance tasks (APT / Flatpak / Snap) with a clean terminal UI and per-run logs.

- Targeted for **Debian-based** systems (including **Kali rolling**)
- Requires: `zsh`, `sudo`

---

## Features

- **Interactive task menu**
  - Choose tasks by number (e.g. `1 2 4`) or type `all`
- **Per-run logging** to `~/.sysmaint/logs/`
  - Log filename includes CLI flags (example: `--dry-run__quiet`)
  - Automatic log cleanup (keeps last **14 days**)
- **Clean terminal UI**
  - `apt-get update` shown as compact status (no repo spam)
  - Upgrade progress bar driven by dpkg stage parsing
- **Upgradable packages table (after update)**
  - Shows **Security / Regular / Total** counts
  - Prints a **5-column** table of package names
    - Security packages highlighted **red**
    - Regular packages highlighted **cyan**
  - If none: prints **“No upgradable packages found.”**
- **Snapshot support (manual menu option)**
  - Prefers **Timeshift** if installed
  - Falls back to **Btrfs snapshot** (if `/` is btrfs and `btrfs` tool is present)
- **Smart upgrade skip**
  - If no packages are upgradable, `apt upgrade` is skipped
- **Network awareness**
  - Basic connectivity check; warns when offline

---

## Requirements

### Required
- `zsh`
- `sudo`
- `coreutils` (for `stdbuf`, `df`, etc.)
- `awk`, `sed`, `grep`, `tr`

### Optional (tasks appear only if installed)
- `flatpak`
- `snapd` (provides `snap`)
- `timeshift` (snapshot creation)
- `btrfs-progs` + btrfs root filesystem (btrfs snapshot fallback)

---

## Install

### 1) Get the script

Clone and run from the repo, or download the script and make it executable:

```sh
chmod +x sysmaint.sh
```

### 2) Run

```sh
./sysmaint.sh
```

---

## Alias (optional)

If you don’t want to move the script into a PATH directory, you can add an alias so you can run it as `sysmaint` from anywhere.

### Zsh (`~/.zshrc`)
```sh
# If sysmaint.sh is in your home directory:
alias sysmaint="$HOME/sysmaint.sh"

# Or if it’s inside your repo folder:
# alias sysmaint="$HOME/path/to/sysmaint/sysmaint.sh"
```

Reload Zsh:
```sh
source ~/.zshrc
```

Test:
```sh
sysmaint
sysmaint --dry-run
```

### Bash (`~/.bashrc`)
```sh
alias sysmaint="$HOME/sysmaint.sh"
```

Reload Bash:
```sh
source ~/.bashrc
```

### Function wrapper (recommended alternative)

A function wrapper behaves better than an alias for passing flags/arguments:

```sh
sysmaint() { "$HOME/sysmaint.sh" "$@"; }
```

## Usage

### Interactive menu (recommended)

```sh
./sysmaint.sh
```

Select tasks by number (e.g. `1 2 4`) or type `all`, then confirm.

### Common flags

- `--dry-run`  
  Print commands without making changes.
  ```sh
  ./sysmaint.sh --dry-run
  ```

- `--quiet`  
  Reduce terminal output (still writes logs).
  ```sh
  ./sysmaint.sh --quiet
  ```

- `--no-snapshot`  
  Disables snapshot creation even if you select the `snapshot` task.
  ```sh
  ./sysmaint.sh --no-snapshot
  ```

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

> Note: The **Snap** option only appears if `snap` is installed and on PATH (usually by installing `snapd`).

---

## Logs

- Location: `~/.sysmaint/logs/`

Example filenames:
- `sysmaint-20260403_211004--noflags.log`
- `sysmaint-20260403_211004--dry-run__quiet.log`

---

## Setup (rename + put on PATH)

Recommended: move to `~/.local/bin` so you can run `sysmaint` directly:

```sh
mkdir -p ~/.local/bin
cp sysmaint.sh ~/.local/bin/sysmaint
chmod +x ~/.local/bin/sysmaint
```

Ensure `~/.local/bin` is in PATH (Zsh):

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Now run:

```sh
sysmaint
```

---

## Troubleshooting

### Snap option is missing

The menu hides Snap if the `snap` command is not installed:

```sh
command -v snap || echo "snap not installed"
```

Install (Debian/Kali):

```sh
sudo apt-get update
sudo apt-get install -y snapd
```

### APT lock errors

If you see:

- `Could not get lock /var/lib/dpkg/lock-frontend`

It means another `apt`/`dpkg` process is still running. Wait for it to finish, or stop it safely, then repair:

```sh
sudo dpkg --configure -a
sudo apt-get -f install
```

### `dpkg verify` shows “missing” or “?M5??????”

`dpkg --verify` reports files that differ from packaged checksums/permissions or are missing.

Find the owning package and reinstall if needed:

```sh
dpkg -S /usr/share/wordlists/rockyou.txt.gz
sudo apt-get install --reinstall wordlists
```

---

## Safety notes / disclaimers

- This tool runs real system package operations with `sudo`.
- Snapshots are best-effort and **not guaranteed**:
  - Timeshift snapshot IDs are extracted from command output (may vary by version)
  - Btrfs snapshot behavior depends on your system layout and permissions
- Upgrade progress is based on parsing dpkg/apt output; output formats can vary.
