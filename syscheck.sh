#!/usr/bin/env bash
# ================================================================
#  kali-diag.sh — Deep System Diagnostic for Kali Linux KDE Wayland
#  Checks: broken packages, missing deps, polkit, D-Bus, systemd,
#          KDE/Wayland, filesystem, services, security, journals
# ================================================================

LOG="kali-diag.log"
WARN_LOG="kali-warnings.log"
> "$LOG"; > "$WARN_LOG"

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; RESET='\033[0m'

PASS=0; WARN=0; FAIL=0

# ── Helpers ──────────────────────────────────────────────────
log()      { echo -e "$1" | tee -a "$LOG"; }
logwarn()  { echo -e "$1" | tee -a "$LOG" >> "$WARN_LOG"; echo -e "$1" >> "$WARN_LOG"; }

header() {
  log "\n${BOLD}${CYAN}╔══════════════════════════════════════════════════╗"
  log   "║  $1"
  log   "╚══════════════════════════════════════════════════╝${RESET}"
}

subhead() { log "\n  ${BOLD}${MAGENTA}▶ $1${RESET}"; }

ok() {
  log "    ${GREEN}[✔] $1${RESET}"
  ((PASS++))
}

warn() {
  log "    ${YELLOW}[⚠] $1${RESET}"
  echo "[⚠] $1" >> "$WARN_LOG"
  ((WARN++))
}

fail() {
  log "    ${RED}[✘] $1${RESET}"
  echo "[✘] $1" >> "$WARN_LOG"
  ((FAIL++))
}

info() { log "    ${CYAN}[i] $1${RESET}"; }

# Run command silently, return output
run() { eval "$1" 2>/dev/null; }

# Check if a package is installed
pkg_installed() { dpkg -l "$1" 2>/dev/null | grep -q "^ii"; }

# Check a package and report
check_pkg() {
  local pkg=$1 label=${2:-$1}
  if pkg_installed "$pkg"; then
    VER=$(dpkg -l "$pkg" 2>/dev/null | awk '/^ii/{print $3}' | head -1)
    ok "$label ($VER)"
  else
    fail "$label — PACKAGE MISSING (fix: sudo apt install $pkg)"
  fi
}

# Check if a systemd service is active
check_service() {
  local svc=$1 label=${2:-$1}
  STATUS=$(systemctl is-active "$svc" 2>/dev/null)
  ENABLED=$(systemctl is-enabled "$svc" 2>/dev/null)
  if [ "$STATUS" = "active" ]; then
    ok "$label — active ($ENABLED)"
  elif [ "$STATUS" = "inactive" ]; then
    warn "$label — inactive (not running, enabled=$ENABLED)"
  else
    fail "$label — $STATUS (fix: sudo systemctl enable --now $svc)"
  fi
}

# Check file exists
check_file() {
  local f=$1 label=${2:-$1}
  if [ -e "$f" ]; then
    ok "$label — exists"
  else
    fail "$label — MISSING"
  fi
}

# Check file readable
check_file_readable() {
  local f=$1 label=${2:-$1}
  if [ -r "$f" ]; then
    ok "$label — readable"
  else
    fail "$label — NOT READABLE (permission issue?)"
  fi
}

# ── BANNER ───────────────────────────────────────────────────
log "${BOLD}${RED}"
log "  ██╗  ██╗ █████╗ ██╗     ██╗      ██████╗ ██╗ █████╗  ██████╗ "
log "  ██║ ██╔╝██╔══██╗██║     ██║      ██╔══██╗██║██╔══██╗██╔════╝ "
log "  █████╔╝ ███████║██║     ██║█████╗██║  ██║██║███████║██║  ███╗"
log "  ██╔═██╗ ██╔══██║██║     ██║╚════╝██║  ██║██║██╔══██║██║   ██║"
log "  ██║  ██╗██║  ██║███████╗██║      ██████╔╝██║██║  ██║╚██████╔╝"
log "  ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝      ╚═════╝ ╚═╝╚═╝  ╚═╝ ╚═════╝ "
log "${RESET}"
log "  ${BOLD}Deep Diagnostic — Kali Linux + KDE + Wayland${RESET}"
log "  ${CYAN}Started: $(date)${RESET}"
log "  ${CYAN}User   : $(whoami) | Host: $(hostname)${RESET}"
log "  Logs   : $LOG  |  Warnings: $WARN_LOG"


# ════════════════════════════════════════════════════════════
header "1 — APT PACKAGE MANAGER HEALTH"
# ════════════════════════════════════════════════════════════

subhead "Broken / Unconfigured packages"
BROKEN=$(dpkg --audit 2>/dev/null)
if [ -z "$BROKEN" ]; then
  ok "No broken packages found (dpkg --audit)"
else
  fail "Broken packages detected:"
  echo "$BROKEN" | while read -r line; do fail "    $line"; done
  info "Fix: sudo dpkg --configure -a && sudo apt install -f"
fi

subhead "dpkg inconsistencies"
HALF=$(dpkg -l 2>/dev/null | grep -E "^(rc|iH|rH|iF|pF)" )
if [ -z "$HALF" ]; then
  ok "No half-installed or residual packages"
else
  COUNT=$(echo "$HALF" | wc -l)
  warn "$COUNT residual/half-removed packages found"
  echo "$HALF" | head -20 | tee -a "$LOG"
  info "Fix: sudo apt autoremove --purge"
fi

subhead "Held packages"
HELD=$(apt-mark showhold 2>/dev/null)
if [ -z "$HELD" ]; then
  ok "No held packages"
else
  warn "Held packages (may cause dep conflicts): $HELD"
fi

subhead "Unmet dependencies check"
UNMET=$(apt-get check 2>&1)
if echo "$UNMET" | grep -qi "error\|unmet"; then
  fail "Unmet dependencies detected:"
  echo "$UNMET" | tee -a "$LOG"
  info "Fix: sudo apt install -f"
else
  ok "No unmet dependencies (apt-get check)"
fi

subhead "APT sources"
if [ -f /etc/apt/sources.list ]; then
  ACTIVE_SOURCES=$(grep -vE "^#|^$" /etc/apt/sources.list | wc -l)
  info "Active sources in sources.list: $ACTIVE_SOURCES"
  grep -vE "^#|^$" /etc/apt/sources.list | tee -a "$LOG"
fi
EXTRA_SOURCES=$(find /etc/apt/sources.list.d/ -name "*.list" 2>/dev/null)
if [ -n "$EXTRA_SOURCES" ]; then
  info "Extra source files:"
  echo "$EXTRA_SOURCES" | tee -a "$LOG"
fi

subhead "Last apt update age"
STAMP=$(stat -c %Y /var/cache/apt/pkgcache.bin 2>/dev/null)
if [ -n "$STAMP" ]; then
  NOW=$(date +%s)
  DAYS=$(( (NOW - STAMP) / 86400 ))
  if [ "$DAYS" -gt 7 ]; then
    warn "apt cache is $DAYS days old — run: sudo apt update"
  else
    ok "apt cache updated $DAYS day(s) ago"
  fi
else
  warn "Cannot determine last apt update time"
fi


# ════════════════════════════════════════════════════════════
header "2 — POLKIT (PolicyKit) — the one that broke Timeshift"
# ════════════════════════════════════════════════════════════

subhead "Core polkit packages"
for pkg in policykit-1 polkitd pkexec; do
  check_pkg "$pkg"
done

# polkitd binary
subhead "polkitd binary & SUID"
if command -v pkexec &>/dev/null; then
  PKEXEC_PATH=$(which pkexec)
  ok "pkexec found: $PKEXEC_PATH"
  # Check SUID bit
  if [ -u "$PKEXEC_PATH" ]; then
    ok "pkexec has SUID bit set"
  else
    fail "pkexec missing SUID bit — pkexec won't work for privilege escalation"
    info "Fix: sudo chmod +s $PKEXEC_PATH"
  fi
else
  fail "pkexec not found in PATH"
fi

subhead "polkit service"
check_service polkit "polkit daemon"

subhead "polkit action files"
POLKIT_ACTIONS=$(find /usr/share/polkit-1/actions/ -name "*.policy" 2>/dev/null | wc -l)
if [ "$POLKIT_ACTIONS" -gt 0 ]; then
  ok "Found $POLKIT_ACTIONS polkit action files"
else
  fail "No polkit action files found — many apps will fail auth"
fi

subhead "Timeshift polkit rule"
TIMESHIFT_RULE=$(find /usr/share/polkit-1/ /etc/polkit-1/ -name "*timeshift*" 2>/dev/null)
if [ -n "$TIMESHIFT_RULE" ]; then
  ok "Timeshift polkit rule found: $TIMESHIFT_RULE"
else
  warn "No Timeshift polkit rule — Timeshift may fail without root"
  info "Fix: reinstall timeshift: sudo apt install --reinstall timeshift"
fi

subhead "Other important polkit rules"
for app in org.freedesktop.NetworkManager org.kde.kpackagekit org.freedesktop.udisks2 \
           org.freedesktop.login1 org.bluez org.freedesktop.fwupd; do
  if find /usr/share/polkit-1/actions/ -name "${app}.policy" &>/dev/null 2>&1 | grep -q .; then
    ok "$app.policy — present"
  else
    FOUND=$(find /usr/share/polkit-1/actions/ -name "${app}*" 2>/dev/null)
    if [ -n "$FOUND" ]; then ok "$app — present"; else warn "$app — policy missing"; fi
  fi
done


# ════════════════════════════════════════════════════════════
header "3 — D-BUS"
# ════════════════════════════════════════════════════════════

check_pkg dbus "D-Bus"
check_service dbus "D-Bus service"

subhead "D-Bus socket"
if [ -S /run/dbus/system_bus_socket ]; then
  ok "System D-Bus socket exists"
else
  fail "System D-Bus socket MISSING — many system services will break"
fi

if [ -n "$DBUS_SESSION_BUS_ADDRESS" ]; then
  ok "Session D-Bus active: $DBUS_SESSION_BUS_ADDRESS"
else
  warn "Session D-Bus not set (normal if running as root or in tty)"
fi

subhead "D-Bus config files"
check_file /etc/dbus-1/system.conf "D-Bus system config"
check_file /usr/share/dbus-1 "D-Bus service definitions dir"


# ════════════════════════════════════════════════════════════
header "4 — SYSTEMD HEALTH"
# ════════════════════════════════════════════════════════════

subhead "Failed units"
FAILED=$(systemctl --failed --no-legend 2>/dev/null)
if [ -z "$FAILED" ]; then
  ok "No failed systemd units"
else
  COUNT=$(echo "$FAILED" | wc -l)
  fail "$COUNT failed systemd unit(s):"
  echo "$FAILED" | while read -r line; do fail "    $line"; done
  info "Fix: sudo systemctl reset-failed && sudo systemctl start <unit>"
fi

subhead "Core services"
for svc in NetworkManager bluetooth cups avahi-daemon ssh; do
  check_service "$svc"
done

subhead "Critical targets"
for target in multi-user graphical network-online; do
  STATUS=$(systemctl is-active "${target}.target" 2>/dev/null)
  if [ "$STATUS" = "active" ]; then
    ok "${target}.target — active"
  else
    warn "${target}.target — $STATUS"
  fi
done

subhead "Journal errors (last boot)"
JOURNAL_ERRORS=$(journalctl -b -p err --no-pager -n 30 2>/dev/null)
ERR_COUNT=$(echo "$JOURNAL_ERRORS" | grep -c "." 2>/dev/null || echo 0)
if [ "$ERR_COUNT" -lt 3 ]; then
  ok "No significant journal errors this boot"
else
  warn "$ERR_COUNT error lines in journal this boot (showing last 10):"
  echo "$JOURNAL_ERRORS" | tail -10 | tee -a "$LOG"
fi


# ════════════════════════════════════════════════════════════
header "5 — KDE PLASMA DEPENDENCIES"
# ════════════════════════════════════════════════════════════

subhead "KDE core packages"
for pkg in plasma-desktop plasma-workspace kwin-wayland kde-cli-tools \
           kscreen libkscreen-dev kinfocenter systemsettings \
           kde-config-screenlocker khotkeys; do
  check_pkg "$pkg"
done

subhead "KDE frameworks"
for pkg in libkf5coreaddons5 libkf5config-dev libkf5notifications-dev \
           kpackagetools libkf5service-bin; do
  check_pkg "$pkg"
done

subhead "KDE application essentials"
for pkg in dolphin konsole kate ark okular spectacle gwenview \
           kcalc kdeconnect; do
  check_pkg "$pkg"
done

subhead "KDE system integration"
for pkg in kde-plasma-integration plasma-nm plasma-pa \
           powerdevil bluedevil kde-config-bluetooth; do
  check_pkg "$pkg"
done

subhead "KDE autostart / session files"
KDE_AUTOSTART="$HOME/.config/autostart"
if [ -d "$KDE_AUTOSTART" ]; then
  COUNT=$(ls "$KDE_AUTOSTART"/*.desktop 2>/dev/null | wc -l)
  info "Autostart entries: $COUNT"
  ls "$KDE_AUTOSTART"/*.desktop 2>/dev/null | tee -a "$LOG"
else
  info "No user autostart dir (normal on fresh install)"
fi

subhead "KDE config dir"
if [ -d "$HOME/.config/plasma*" ] || [ -d "$HOME/.config/kde*" ]; then
  ok "KDE config dir present"
else
  info "KDE config dir: $HOME/.config/ (may be fresh)"
fi


# ════════════════════════════════════════════════════════════
header "6 — WAYLAND"
# ════════════════════════════════════════════════════════════

subhead "Wayland session"
if [ "$XDG_SESSION_TYPE" = "wayland" ]; then
  ok "Running on Wayland session"
else
  warn "Session type: ${XDG_SESSION_TYPE:-unknown} (not Wayland)"
  info "Set WAYLAND_DISPLAY or start a Wayland session"
fi

if [ -n "$WAYLAND_DISPLAY" ]; then
  ok "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
else
  warn "WAYLAND_DISPLAY not set"
fi

subhead "Wayland packages"
for pkg in kwin-wayland plasma-workspace-wayland xwayland \
           wayland-protocols libwayland-client0 libwayland-server0; do
  check_pkg "$pkg"
done

subhead "XWayland (for X11 app compat)"
if command -v Xwayland &>/dev/null; then
  ok "Xwayland binary found"
else
  fail "Xwayland missing — X11 apps won't work under Wayland"
  info "Fix: sudo apt install xwayland"
fi

subhead "KWin Wayland compositor"
if pgrep -x kwin_wayland &>/dev/null; then
  ok "kwin_wayland compositor is running"
else
  warn "kwin_wayland not running (expected if in X11 or TTY)"
fi

subhead "Wayland socket"
WL_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/wayland-0"
if [ -S "$WL_SOCK" ]; then
  ok "Wayland socket exists: $WL_SOCK"
else
  warn "Wayland socket not found at $WL_SOCK"
fi

subhead "Screen sharing / portal"
for pkg in xdg-desktop-portal xdg-desktop-portal-kde xdg-desktop-portal-gtk; do
  check_pkg "$pkg"
done

check_service xdg-desktop-portal "XDG Desktop Portal"


# ════════════════════════════════════════════════════════════
header "7 — DISPLAY SERVER & GPU"
# ════════════════════════════════════════════════════════════

subhead "Display session info"
info "XDG_SESSION_TYPE : ${XDG_SESSION_TYPE:-not set}"
info "DISPLAY          : ${DISPLAY:-not set}"
info "WAYLAND_DISPLAY  : ${WAYLAND_DISPLAY:-not set}"
info "XDG_RUNTIME_DIR  : ${XDG_RUNTIME_DIR:-not set}"

subhead "GPU drivers"
GPU_INFO=$(lspci 2>/dev/null | grep -iE "vga|3d|display")
if [ -n "$GPU_INFO" ]; then
  info "GPU: $GPU_INFO"
else
  warn "No GPU detected via lspci"
fi

# Mesa / open source drivers
check_pkg libgl1-mesa-dri "Mesa DRI (open source GPU)"
check_pkg libgles2-mesa "Mesa GLES2"
check_pkg mesa-vulkan-drivers "Mesa Vulkan"

# NVIDIA
if lspci 2>/dev/null | grep -qi nvidia; then
  info "NVIDIA GPU detected"
  if pkg_installed nvidia-driver; then
    ok "NVIDIA proprietary driver installed"
    check_service nvidia-persistenced "NVIDIA persistenced"
  else
    warn "NVIDIA GPU found but proprietary driver not installed"
    info "Fix: sudo apt install nvidia-driver"
  fi
  # Wayland + NVIDIA
  if pkg_installed nvidia-driver; then
    if grep -qr "nvidia_drm.modeset=1" /etc/default/grub 2>/dev/null || \
       grep -qr "nvidia-drm.modeset=1" /etc/modprobe.d/ 2>/dev/null; then
      ok "NVIDIA KMS/modesetting enabled (good for Wayland)"
    else
      warn "NVIDIA KMS modesetting not enabled — Wayland may be unstable"
      info "Fix: add nvidia-drm.modeset=1 to GRUB_CMDLINE_LINUX in /etc/default/grub"
    fi
  fi
fi

# AMD
if lspci 2>/dev/null | grep -qi amd; then
  info "AMD GPU detected"
  check_pkg firmware-amd-graphics "AMD GPU firmware"
fi

subhead "Kernel modesetting"
for mod in drm drm_kms_helper; do
  if lsmod 2>/dev/null | grep -q "^$mod"; then
    ok "Kernel module loaded: $mod"
  else
    warn "Kernel module not loaded: $mod"
  fi
done


# ════════════════════════════════════════════════════════════
header "8 — FILESYSTEM & DISK HEALTH"
# ════════════════════════════════════════════════════════════

subhead "Disk usage"
df -h 2>/dev/null | grep -E "^/dev/" | while read -r line; do
  PCT=$(echo "$line" | awk '{print $5}' | tr -d '%')
  if [ "$PCT" -ge 90 ] 2>/dev/null; then
    fail "CRITICAL disk usage: $line"
  elif [ "$PCT" -ge 75 ] 2>/dev/null; then
    warn "High disk usage: $line"
  else
    ok "$line"
  fi
done

subhead "Inode usage (often overlooked)"
df -i 2>/dev/null | grep -E "^/dev/" | while read -r line; do
  PCT=$(echo "$line" | awk '{print $5}' | tr -d '%')
  if [ "$PCT" -ge 90 ] 2>/dev/null; then
    fail "CRITICAL inode usage: $line"
  elif [ "$PCT" -ge 75 ] 2>/dev/null; then
    warn "High inode usage: $line"
  else
    ok "Inodes OK: $line"
  fi
done

subhead "Filesystem errors in dmesg"
FS_ERRORS=$(dmesg 2>/dev/null | grep -iE "error|corrupt|fail|i/o error|ext4|btrfs" | tail -10)
if [ -n "$FS_ERRORS" ]; then
  warn "Filesystem-related dmesg messages:"
  echo "$FS_ERRORS" | tee -a "$LOG"
else
  ok "No filesystem errors in dmesg"
fi

subhead "fstab vs mounted"
while read -r dev mp type opts dump pass; do
  [[ "$dev" =~ ^# ]] && continue
  [ -z "$dev" ] && continue
  [ "$mp" = "none" ] && continue
  [ "$type" = "swap" ] && continue
  if ! mountpoint -q "$mp" 2>/dev/null; then
    warn "fstab entry not mounted: $mp ($dev)"
  else
    ok "Mounted OK: $mp"
  fi
done < /etc/fstab 2>/dev/null

subhead "SMART disk health"
if command -v smartctl &>/dev/null; then
  for disk in $(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
    SMART=$(smartctl -H /dev/$disk 2>/dev/null | grep -i "SMART overall")
    if echo "$SMART" | grep -qi "PASSED\|OK"; then
      ok "SMART /dev/$disk: PASSED"
    elif [ -n "$SMART" ]; then
      fail "SMART /dev/$disk: $SMART"
    else
      warn "SMART /dev/$disk: could not read (may need sudo)"
    fi
  done
else
  warn "smartmontools not installed — can't check disk health"
  info "Fix: sudo apt install smartmontools"
fi

subhead "Swap"
SWAP=$(free -h | grep Swap | awk '{print $2, $3, $4}')
if echo "$SWAP" | grep -q "^0B"; then
  warn "No swap configured"
else
  info "Swap: total=$( echo $SWAP | awk '{print $1}') used=$(echo $SWAP | awk '{print $2}') free=$(echo $SWAP | awk '{print $3}')"
  ok "Swap is configured"
fi


# ════════════════════════════════════════════════════════════
header "9 — PERMISSIONS & IMPORTANT FILES"
# ════════════════════════════════════════════════════════════

subhead "Critical system files"
for f in /etc/passwd /etc/shadow /etc/group /etc/fstab /etc/hosts \
          /etc/hostname /etc/resolv.conf /etc/sudoers /etc/locale.gen; do
  check_file_readable "$f"
done

subhead "sudoers integrity"
if visudo -c &>/dev/null 2>&1; then
  ok "/etc/sudoers — valid syntax"
else
  fail "/etc/sudoers — SYNTAX ERROR (dangerous!)"
  info "Fix: sudo EDITOR=nano visudo"
fi

subhead "sudo access for current user"
if sudo -n true 2>/dev/null; then
  ok "$(whoami) has passwordless sudo"
elif groups | grep -qw sudo; then
  ok "$(whoami) is in sudo group"
else
  warn "$(whoami) may not have sudo access"
fi

subhead "SUID binaries (critical ones)"
for bin in /usr/bin/sudo /usr/bin/pkexec /usr/bin/passwd /usr/bin/su; do
  if [ -u "$bin" ]; then
    ok "$bin — SUID set"
  else
    fail "$bin — SUID missing! This will break privilege escalation"
  fi
done

subhead "Immutable files check"
if command -v lsattr &>/dev/null; then
  IMM=$(lsattr /etc/ 2>/dev/null | grep "^....i" | head -5)
  if [ -n "$IMM" ]; then
    warn "Immutable files in /etc/ — may block system config:"
    echo "$IMM" | tee -a "$LOG"
  else
    ok "No unexpected immutable files in /etc/"
  fi
fi


# ════════════════════════════════════════════════════════════
header "10 — NETWORKING STACK"
# ════════════════════════════════════════════════════════════

subhead "Network interfaces"
ip -br link show 2>/dev/null | tee -a "$LOG"

subhead "Default route"
ROUTE=$(ip route show default 2>/dev/null)
if [ -n "$ROUTE" ]; then
  ok "Default route: $ROUTE"
else
  fail "No default route — no internet gateway"
fi

subhead "DNS resolution"
for domain in kali.org google.com github.com; do
  if host "$domain" &>/dev/null 2>&1; then
    ok "DNS resolves: $domain"
  else
    fail "DNS FAIL: $domain — check /etc/resolv.conf"
  fi
done

subhead "/etc/resolv.conf"
if [ -f /etc/resolv.conf ]; then
  NAMESERVERS=$(grep "^nameserver" /etc/resolv.conf)
  if [ -n "$NAMESERVERS" ]; then
    ok "Nameservers configured:"
    echo "$NAMESERVERS" | tee -a "$LOG"
  else
    fail "No nameservers in /etc/resolv.conf"
  fi
fi

subhead "NetworkManager"
check_service NetworkManager "NetworkManager"
check_pkg network-manager "NetworkManager package"

subhead "Listening ports"
info "Open listening ports:"
ss -tlnp 2>/dev/null | tee -a "$LOG"


# ════════════════════════════════════════════════════════════
header "11 — AUDIO (PipeWire / PulseAudio)"
# ════════════════════════════════════════════════════════════

if pgrep -x pipewire &>/dev/null; then
  ok "PipeWire is running"
  check_pkg pipewire "pipewire"
  check_pkg pipewire-pulse "pipewire-pulse (PulseAudio compat)"
  check_pkg wireplumber "WirePlumber (session manager)"
  if pgrep -x wireplumber &>/dev/null; then
    ok "WirePlumber session manager running"
  else
    warn "WirePlumber not running — audio routing may fail"
    info "Fix: systemctl --user start wireplumber"
  fi
elif pgrep -x pulseaudio &>/dev/null; then
  ok "PulseAudio is running (legacy)"
  warn "PulseAudio detected — consider migrating to PipeWire for Wayland"
else
  fail "No audio server running (no PipeWire, no PulseAudio)"
  info "Fix: systemctl --user start pipewire pipewire-pulse wireplumber"
fi

for pkg in alsa-base alsa-utils; do
  check_pkg "$pkg"
done


# ════════════════════════════════════════════════════════════
header "12 — BLUETOOTH"
# ════════════════════════════════════════════════════════════

check_pkg bluez "BlueZ"
check_pkg bluetooth "bluetooth service"
check_service bluetooth "Bluetooth daemon"

if rfkill list bluetooth 2>/dev/null | grep -qi "blocked: yes"; then
  warn "Bluetooth is RF-blocked (soft or hard)"
  info "Fix: rfkill unblock bluetooth"
else
  ok "Bluetooth not RF-blocked"
fi


# ════════════════════════════════════════════════════════════
header "13 — PRINTER & USB"
# ════════════════════════════════════════════════════════════

if pkg_installed cups; then
  check_service cups "CUPS printer service"
else
  info "CUPS not installed (skip if no printer needed)"
fi

subhead "USB devices"
if command -v lsusb &>/dev/null; then
  USB_COUNT=$(lsusb 2>/dev/null | wc -l)
  ok "$USB_COUNT USB devices detected"
  lsusb 2>/dev/null | tee -a "$LOG"
else
  warn "lsusb not found"
  info "Fix: sudo apt install usbutils"
fi

subhead "udisks2 (auto-mount)"
check_pkg udisks2 "udisks2"
check_service udisks2 "udisks2"


# ════════════════════════════════════════════════════════════
header "14 — SECURITY & INTEGRITY"
# ════════════════════════════════════════════════════════════

subhead "AppArmor"
if command -v aa-status &>/dev/null; then
  AA=$(aa-status 2>/dev/null | head -3)
  ok "AppArmor available"
  info "$AA"
else
  info "AppArmor not active (optional on Kali)"
fi

subhead "Kernel security params"
for param in \
  "kernel.dmesg_restrict" \
  "kernel.kptr_restrict" \
  "net.ipv4.conf.all.rp_filter" \
  "net.ipv4.tcp_syncookies"; do
  VAL=$(sysctl -n "$param" 2>/dev/null)
  if [ -n "$VAL" ]; then
    info "$param = $VAL"
  else
    warn "$param — could not read"
  fi
done

subhead "Kali-specific security tools"
for pkg in metasploit-framework nmap wireshark burpsuite \
           aircrack-ng sqlmap hydra john hashcat; do
  if pkg_installed "$pkg"; then
    ok "$pkg — installed"
  else
    info "$pkg — not installed (optional)"
  fi
done


# ════════════════════════════════════════════════════════════
header "15 — BACKUP TOOLS"
# ════════════════════════════════════════════════════════════

subhead "Timeshift"
if pkg_installed timeshift; then
  ok "Timeshift installed"
  # Check timeshift polkit + deps
  for dep in rsync grub-common; do
    check_pkg "$dep" "timeshift dep: $dep"
  done
  if pkg_installed polkitd || pkg_installed policykit-1; then
    ok "Timeshift polkit dependency met"
  else
    fail "Timeshift needs polkit — this is why it broke for you!"
    info "Fix: sudo apt install policykit-1"
  fi
else
  warn "Timeshift not installed"
  info "Install: sudo apt install timeshift"
fi

subhead "Other backup tools"
for pkg in rsync borgbackup deja-dup backintime-common; do
  if pkg_installed "$pkg"; then ok "$pkg installed"; fi
done


# ════════════════════════════════════════════════════════════
header "16 — KERNEL & BOOT"
# ════════════════════════════════════════════════════════════

subhead "Kernel version"
KVER=$(uname -r)
info "Running kernel: $KVER"

INSTALLED_KERNELS=$(dpkg -l linux-image-* 2>/dev/null | grep "^ii" | awk '{print $2}')
COUNT=$(echo "$INSTALLED_KERNELS" | wc -l)
info "Installed kernels ($COUNT):"
echo "$INSTALLED_KERNELS" | tee -a "$LOG"

if [ "$COUNT" -gt 3 ]; then
  warn "$COUNT kernels installed — old ones wasting disk space"
  info "Fix: sudo apt autoremove"
fi

subhead "GRUB"
check_file /boot/grub/grub.cfg "GRUB config"
check_file /etc/default/grub "GRUB defaults"
if command -v grub-install &>/dev/null; then
  ok "grub-install available"
fi

subhead "initramfs"
INITRD="/boot/initrd.img-$KVER"
if [ -f "$INITRD" ]; then
  ok "initramfs exists for running kernel"
else
  fail "initramfs MISSING for running kernel — system may not boot after update"
  info "Fix: sudo update-initramfs -u -k $KVER"
fi

subhead "Kernel modules"
for mod in ext4 btrfs overlay loop nfs bluetooth; do
  if lsmod 2>/dev/null | grep -q "^$mod" || modinfo "$mod" &>/dev/null 2>&1; then
    ok "Module available: $mod"
  else
    info "Module not loaded: $mod (may be OK if not needed)"
  fi
done


# ════════════════════════════════════════════════════════════
header "17 — LOCALE & TIME"
# ════════════════════════════════════════════════════════════

subhead "Locale"
LANG_SET=$(locale 2>/dev/null | grep "LANG=" | head -1)
info "$LANG_SET"
if locale 2>/dev/null | grep -qi "UTF-8"; then
  ok "UTF-8 locale configured"
else
  warn "UTF-8 locale not set — may cause encoding issues"
  info "Fix: sudo dpkg-reconfigure locales"
fi

subhead "Timezone & time sync"
TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)
info "Timezone: $TZ"

NTP=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)
if [ "$NTP" = "yes" ]; then
  ok "NTP time sync active"
else
  warn "NTP not synchronized — time may be wrong"
  info "Fix: sudo timedatectl set-ntp true"
fi

CLOCK=$(timedatectl show --property=LocalRTC --value 2>/dev/null)
info "Hardware clock: $CLOCK"


# ════════════════════════════════════════════════════════════
header "18 — FINAL SUMMARY"
# ════════════════════════════════════════════════════════════

log ""
log "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗"
log "║              DIAGNOSTIC RESULTS                  ║"
log "╚══════════════════════════════════════════════════╝${RESET}"
log ""
log "  ${GREEN}${BOLD}[✔] Passed  : $PASS${RESET}"
log "  ${YELLOW}${BOLD}[⚠] Warnings: $WARN${RESET}"
log "  ${RED}${BOLD}[✘] Failed  : $FAIL${RESET}"
log ""

if [ "$FAIL" -eq 0 ] && [ "$WARN" -lt 5 ]; then
  log "  ${GREEN}${BOLD}★ System looks healthy!${RESET}"
elif [ "$FAIL" -gt 0 ]; then
  log "  ${RED}${BOLD}✘ Issues found — check $WARN_LOG for all problems${RESET}"
  log "  ${YELLOW}Run with: grep '\\[✘\\]' $WARN_LOG to see only failures${RESET}"
else
  log "  ${YELLOW}${BOLD}⚠ Minor issues found — review $WARN_LOG${RESET}"
fi

log ""
log "  ${CYAN}Full log  → ${BOLD}$LOG${RESET}"
log "  ${CYAN}Issues    → ${BOLD}$WARN_LOG${RESET}"
log "  ${CYAN}Finished  : $(date)${RESET}"
log ""
log "${CYAN}${BOLD}Quick fix commands for common issues:${RESET}"
log "  ${YELLOW}Broken packages  : sudo dpkg --configure -a && sudo apt install -f${RESET}"
log "  ${YELLOW}Missing deps     : sudo apt --fix-broken install${RESET}"
log "  ${YELLOW}Polkit broken    : sudo apt install --reinstall policykit-1 polkitd${RESET}"
log "  ${YELLOW}Timeshift broken : sudo apt install --reinstall timeshift policykit-1${RESET}"
log "  ${YELLOW}Failed units     : systemctl --failed${RESET}"
log "  ${YELLOW}Update system    : sudo apt update && sudo apt full-upgrade${RESET}"
log ""
