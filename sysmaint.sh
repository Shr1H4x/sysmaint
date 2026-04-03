#!/usr/bin/env zsh
#=============================================================================
# sysmaint — System Maintenance Tool (Zsh)
#
# Based on: Shr1H4x/sysmaint sysmaint-v3.sh (commit cb69ced...)
#
# Added/changed for testing (per your requirements):
# - apt update uses apt-get and shows clean terminal output (no Hit/Get spam),
#   while full output is still logged.
# - After update: show upgradable packages in 5 columns (single table):
#     - security packages RED
#     - regular packages CYAN
#   plus counts (Security/Regular/Total).
#   If none: "No upgradable packages found."
# - apt upgrade: progress bar + package name + single status (Preparing/Unpacking/Setting up)
#   while full output is still logged.
# - Snap menu item exists but is hidden if `snap` command not found.
#=============================================================================

setopt LOCAL_OPTIONS NO_MONITOR NO_NOTIFY 2>/dev/null

# ----------------------------
# GLOBALS
# ----------------------------
typeset -g SYSMAINT_VERSION="3.0"
typeset -g SYSMAINT_HOME="$HOME/.sysmaint"
typeset -g LOG_DIR="$SYSMAINT_HOME/logs"
typeset -g STATE_FILE="$SYSMAINT_HOME/state.json"

typeset -g LOG_FILE=""
typeset -g LOCK_FILE="/tmp/sysmaint.lock"
typeset -g LOG_RETENTION_DAYS=14

typeset -g DRY_RUN=false AUTO=false FULL=false QUIET=false
typeset -g NO_SNAPSHOT=false HEALTH_MODE=false DEEP_CLEAN=false RESUME=false
typeset -g REPORT_MODE=""
typeset -g CHANGELOG=false

typeset -g START_TIME=0
typeset -g DISK_BEFORE="" DISK_AFTER=""
typeset -g PKG_BEFORE=0 PKG_AFTER=0
typeset -g DISK_BYTES_BEFORE=0 DISK_BYTES_AFTER=0

typeset -g SNAPSHOT_INFO=""  # id|timestamp|tool
typeset -g NETWORK_OK=true NETWORK_SLOW=false

typeset -ga RAN SKIPPED FAILED SELECTED_TASKS
typeset -gA TASK_TIME_START TASK_TIME_END TASK_STATUS

typeset -ga ORIG_ARGV
ORIG_ARGV=()

# package intelligence (new)
typeset -ga UPGRADABLE_PKGS SECURITY_PKGS
UPGRADABLE_PKGS=() SECURITY_PKGS=()
typeset -g UPGRADABLE_TOTAL=0 UPGRADABLE_SECURITY=0 UPGRADABLE_REGULAR=0

# ----------------------------
# COLOURS
# ----------------------------
typeset -g R=$'\033[0;31m' G=$'\033[0;32m' Y=$'\033[0;33m'
typeset -g B=$'\033[0;34m' C=$'\033[0;36m' W=$'\033[1;37m' NC=$'\033[0m'

#=============================================================================
# LOG FILE NAME HELPERS (FLAGS IN LOG NAME)
#=============================================================================
_log_flag_suffix_from_argv() {
  local -a args=("$@")
  local s="" a

  for a in "${args[@]}"; do
    a="${a##--}"; a="${a##-}"
    a="${a// /_}"; a="${a//\//_}"
    a="$(print -r -- "$a" | tr -c 'A-Za-z0-9._=-' '_' | sed -E 's/_+/_/g; s/^_+//; s/_+$//')"
    [[ -z "$a" ]] && continue
    [[ -z "$s" ]] && s="$a" || s="${s}__${a}"
  done

  [[ -z "$s" ]] && s="noflags"
  print -r -- "$s"
}

#=============================================================================
# INIT DIRS + LOGGING INIT
#=============================================================================
_state_init_dir() {
  mkdir -p "$SYSMAINT_HOME" "$LOG_DIR" 2>/dev/null
}

init_logging() {
  _state_init_dir
  local suffix
  suffix=$(_log_flag_suffix_from_argv "${ORIG_ARGV[@]}")
  LOG_FILE="$LOG_DIR/sysmaint-$(date +%Y:%m:%d_%H:%M:%S)--${suffix}.log"
  find "$LOG_DIR" -name "sysmaint-*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null
}

#=============================================================================
# LOGGING / OUTPUT
#=============================================================================
_log() {
  local level="$1" msg="$2" col="$NC"
  case "$level" in
    INFO)  col="$G" ;;
    WARN)  col="$Y" ;;
    ERROR) col="$R" ;;
    SKIP)  col="$B" ;;
    CMD)   col="$C" ;;
    TASK)  col="$W" ;;
  esac

  if [[ -z "${LOG_FILE:-}" ]]; then
    _state_init_dir
    LOG_FILE="$LOG_DIR/sysmaint-$(date +%Y%m%d_%H%M%S)--noflags.log"
  fi

  if $QUIET && [[ "$level" != "ERROR" ]]; then
    print -r -- "[$(date +%H:%M:%S)] [$level] $msg" >> "$LOG_FILE"
    return 0
  fi
  print -r -- "${col}[$(date +%H:%M:%S)] [$level] $msg${NC}" | tee -a "$LOG_FILE" >/dev/null
}

_section() {
  local title="$1"
  [[ $QUIET == true ]] && return 0
  print -r -- ""
  print -r -- "${W}== ${title} ==${NC}"
  print -r -- "" | tee -a "$LOG_FILE" >/dev/null
}

#=============================================================================
# SAFE RUNNERS
#=============================================================================
run_cmd() {
  local -a cmd=("$@")
  if $DRY_RUN; then
    _log CMD "[DRY-RUN] ${cmd[*]}"
    return 0
  fi

  _log CMD "${cmd[*]}"

  if $QUIET; then
    "${cmd[@]}" >>"$LOG_FILE" 2>&1
    return $?
  fi

  stdbuf -oL -eL "${cmd[@]}" 2>&1 | stdbuf -oL -eL tee -a "$LOG_FILE"
  return ${pipestatus[1]:-${PIPESTATUS[0]}}
}

run_with_spinner() {
  local label="$1"; shift
  local -a cmd=("$@")

  if $DRY_RUN; then
    _log CMD "[DRY-RUN] ${cmd[*]}"
    return 0
  fi
  _log CMD "${cmd[*]}"

  if $QUIET; then
    "${cmd[@]}" >>"$LOG_FILE" 2>&1
    return $?
  fi

  local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local tmp exit_code i=0
  tmp=$(mktemp)

  stdbuf -oL -eL "${cmd[@]}" >>"$tmp" 2>&1 &
  local cpid=$!

  while kill -0 "$cpid" 2>/dev/null; do
    printf "\r  ${C}%s${NC}  %s..." "${spin[$((i % 10))]}" "$label"
    sleep 0.1
    (( i++ ))
  done
  printf "\r%-80s\r" " "

  wait "$cpid" 2>/dev/null
  exit_code=$?

  cat "$tmp" | tee -a "$LOG_FILE" >/dev/null
  rm -f "$tmp"
  return "$exit_code"
}

_bar() {
  local cur="$1" tot="$2" label="$3"
  local width=36 pct=0 filled=0
  [[ $tot -gt 0 ]] && pct=$(( cur * 100 / tot ))
  [[ $tot -gt 0 ]] && filled=$(( cur * width / tot ))
  local empty=$(( width - filled ))
  local bar="" i
  for (( i=0; i<filled; i++ )); do bar+="█"; done
  for (( i=0; i<empty;  i++ )); do bar+="░"; done
  printf "\r  ${G}[%s]${NC} ${W}%3d%%${NC} ${C}(%d/%d)${NC} %-30s" \
    "$bar" "$pct" "$cur" "$tot" "$label"
}

#=============================================================================
# NETWORK AWARENESS
#=============================================================================
net_check() {
  NETWORK_OK=true
  NETWORK_SLOW=false

  if command -v curl >/dev/null 2>&1; then
    local t
    t=$( (TIMEFORMAT="%R"; time curl -fsS --max-time 3 https://deb.debian.org/ >/dev/null) 2>&1 )
    if [[ $? -ne 0 ]]; then
      NETWORK_OK=false
      return 1
    fi
    if [[ -n "$t" ]] && awk "BEGIN{exit !($t >= 1.2)}" >/dev/null 2>&1; then
      NETWORK_SLOW=true
    fi
  else
    ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 || { NETWORK_OK=false; return 1; }
  fi

  return 0
}

#=============================================================================
# SNAPSHOT SUPPORT
#=============================================================================
_snapshot_create_timeshift() {
  command -v timeshift >/dev/null 2>&1 || return 1

  _log INFO "Creating Timeshift snapshot..."
  if $DRY_RUN; then
    _log CMD "[DRY-RUN] sudo timeshift --create --comments \"sysmaint\""
    SNAPSHOT_INFO="dry-run|$(date -Is)|timeshift"
    return 0
  fi

  local out tmp
  tmp=$(mktemp)
  sudo timeshift --create --comments "sysmaint snapshot" 2>&1 | tee -a "$LOG_FILE" > "$tmp"
  local rc=${pipestatus[1]:-0}
  out=$(tail -n 120 "$tmp")
  rm -f "$tmp"

  if [[ $rc -ne 0 ]]; then
    _log WARN "Timeshift snapshot creation failed."
    return 1
  fi

  local sid
  sid=$(print -r -- "$out" | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' | head -n1)
  [[ -z "$sid" ]] && sid="unknown"
  SNAPSHOT_INFO="${sid}|$(date -Is)|timeshift"
  _log INFO "Snapshot created: $sid"
  return 0
}

_snapshot_create_btrfs() {
  command -v btrfs >/dev/null 2>&1 || return 1

  local fstype
  fstype=$(stat -f -c %T / 2>/dev/null)
  [[ "$fstype" != "btrfs" ]] && return 1

  local snapdir="/.snapshots"
  local sid="sysmaint-$(date +%Y%m%d_%H%M%S)"
  _log INFO "Creating Btrfs snapshot: ${snapdir}/${sid}"

  if $DRY_RUN; then
    _log CMD "[DRY-RUN] sudo mkdir -p $snapdir && sudo btrfs subvolume snapshot / ${snapdir}/${sid}"
    SNAPSHOT_INFO="${sid}|$(date -Is)|btrfs"
    return 0
  fi

  sudo mkdir -p "$snapdir" >>"$LOG_FILE" 2>&1 || return 1
  sudo btrfs subvolume snapshot / "${snapdir}/${sid}" 2>&1 | tee -a "$LOG_FILE" >/dev/null
  local rc=${pipestatus[1]:-0}
  [[ $rc -ne 0 ]] && return 1

  SNAPSHOT_INFO="${sid}|$(date -Is)|btrfs"
  _log INFO "Snapshot created: $sid"
  return 0
}

snapshot_maybe_create() {
  $NO_SNAPSHOT && { _log INFO "Snapshot disabled by --no-snapshot"; return 0; }
  _snapshot_create_timeshift && return 0
  _snapshot_create_btrfs && return 0
  _log WARN "No snapshot mechanism available (timeshift missing; btrfs not applicable)."
  return 1
}

#=============================================================================
# NEW: apt update clean terminal (no Hit/Get spam), but full output in log
#=============================================================================
run_aptget_update_clean() {
  if $DRY_RUN; then
    _log CMD "[DRY-RUN] sudo apt-get update"
    return 0
  fi

  _log CMD "sudo apt-get update"

  if $QUIET; then
    sudo apt-get update >>"$LOG_FILE" 2>&1
    return $?
  fi

  local exit_file awk_script
  exit_file=$(mktemp /tmp/sysmaint_update_exit.XXXX)
  awk_script=$(mktemp /tmp/sysmaint_update_awk.XXXX)

  cat >"$awk_script" <<'AWKEOF'
/^(Get|Hit|Ign|Err):[0-9]+[[:space:]]+/ {
  url=$2
  gsub(/^[a-z]+:\/\//,"",url)
  split(url,a,"/")
  host=a[1]
  print "REPO:" host
  next
}
/^Reading package lists/ { print "STAGE:Reading package lists"; next }
/^Building dependency tree/ { print "STAGE:Building dependency tree"; next }
/^Reading state information/ { print "STAGE:Reading state information"; next }
{ next }
AWKEOF

  local last_host="" stage="Updating package lists"
  local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0

  (
    stdbuf -oL -eL sudo apt-get update 2>&1 | stdbuf -oL -eL tee -a "$LOG_FILE" | stdbuf -oL -eL awk -f "$awk_script"
    print -r -- "${pipestatus[1]:-0}" > "$exit_file"
  ) | while IFS= read -r tok; do
        case "$tok" in
          REPO:*)  last_host="${tok#REPO:}" ;;
          STAGE:*) stage="${tok#STAGE:}" ;;
        esac
        printf "\r  ${C}%s${NC}  %s — %s..." "${spin[$((i % 10))]}" "$stage" "${last_host:-}" 2>/dev/null
        (( i++ ))
      done

  printf "\r%-120s\r" " "
  rm -f "$awk_script"

  local rc=0
  [[ -f "$exit_file" ]] && rc=$(<"$exit_file")
  rm -f "$exit_file"
  return "$rc"
}

#=============================================================================
# NEW: Package intelligence + one 5-column table of ALL upgradable pkgs
#=============================================================================
build_pkg_intelligence() {
  UPGRADABLE_PKGS=() SECURITY_PKGS=()
  UPGRADABLE_TOTAL=0 UPGRADABLE_SECURITY=0 UPGRADABLE_REGULAR=0

  local -a pkgs
  pkgs=("${(@f)$(apt-get -s upgrade 2>/dev/null | awk '/^Inst /{print $2}')}")
  (( ${#pkgs[@]} == 0 )) && return 0

  UPGRADABLE_PKGS=("${pkgs[@]}")

  local p pol
  for p in "${pkgs[@]}"; do
    pol=$(apt-cache policy "$p" 2>/dev/null)
    if print -r -- "$pol" | grep -qiE 'security|kali-security|debian-security'; then
      SECURITY_PKGS+=("$p")
    fi
  done

  UPGRADABLE_TOTAL=${#UPGRADABLE_PKGS[@]}
  UPGRADABLE_SECURITY=${#SECURITY_PKGS[@]}
  UPGRADABLE_REGULAR=$(( UPGRADABLE_TOTAL - UPGRADABLE_SECURITY ))
  (( UPGRADABLE_REGULAR < 0 )) && UPGRADABLE_REGULAR=0
}

_is_security_pkg() {
  local p="$1"
  [[ " ${SECURITY_PKGS[*]} " == *" $p "* ]]
}

show_upgradable_table_5col() {
  build_pkg_intelligence

  # Counts at top
  _log INFO "Updates available: ${R}Security=${UPGRADABLE_SECURITY}${NC}  ${C}Regular=${UPGRADABLE_REGULAR}${NC}  Total=${UPGRADABLE_TOTAL}"

  if (( UPGRADABLE_TOTAL == 0 )); then
    print -r -- "" | tee -a "$LOG_FILE" >/dev/null
    print -r -- "${G}No upgradable packages found.${NC}" | tee -a "$LOG_FILE" >/dev/null
    print -r -- "" | tee -a "$LOG_FILE" >/dev/null
    return 0
  fi

  local col_width=28 cols=5
  local total_width=$((col_width * cols))

  print -r -- "" | tee -a "$LOG_FILE" >/dev/null
  print -r -- "${W}Upgradable packages (5 columns):${NC}" | tee -a "$LOG_FILE" >/dev/null

  printf "  ${W}%-${col_width}s%-${col_width}s%-${col_width}s%-${col_width}s%-${col_width}s${NC}\n" \
    "Package" "Package" "Package" "Package" "Package" | tee -a "$LOG_FILE" >/dev/null
  printf "  ${W}%s${NC}\n" "$(printf '─%.0s' $(seq 1 $total_width))" | tee -a "$LOG_FILE" >/dev/null

  local i idx line p
  local total_pkgs=${#UPGRADABLE_PKGS[@]}

  for (( i=1; i<=total_pkgs; i+=cols )); do
    line="  "
    for (( idx=i; idx<i+cols && idx<=total_pkgs; idx++ )); do
      p="${UPGRADABLE_PKGS[$idx]}"
      if _is_security_pkg "$p"; then
        line+=$(printf "${R}%-${col_width}s${NC}" "$p")
      else
        line+=$(printf "${C}%-${col_width}s${NC}" "$p")
      fi
    done
    printf "%b\n" "$line" | tee -a "$LOG_FILE" >/dev/null
  done

  print -r -- "" | tee -a "$LOG_FILE" >/dev/null
}

#=============================================================================
# NEW: Upgrade progress bar + package name + single status word
#=============================================================================
run_apt_progress_with_status() {
  local -a cmd=("$@")

  if $DRY_RUN; then
    _log CMD "[DRY-RUN] ${cmd[*]}"
    return 0
  fi
  _log CMD "${cmd[*]}"

  if $QUIET; then
    "${cmd[@]}" >>"$LOG_FILE" 2>&1
    return $?
  fi

  build_pkg_intelligence
  local total=$UPGRADABLE_TOTAL
  [[ $total -lt 1 ]] && total=1

  local current=0 pkg="(starting)" status="Running"
  local awk_script exit_file
  awk_script=$(mktemp /tmp/sysmaint_upgrade_awk.XXXX)
  exit_file=$(mktemp /tmp/sysmaint_upgrade_exit.XXXX)

  cat > "$awk_script" << 'AWKEOF'
/^Preparing to unpack/ {
  n=split($NF,a,"/")
  file=a[n]
  split(file,b,"_")
  if (b[1]!="") print "PREP:" b[1]
  next
}
/^Unpacking / {
  split($2, p, ":")
  if (p[1]!="") print "UNP:" p[1]
  next
}
/^Setting up / {
  split($3, p, ":")
  if (p[1]!="") print "SET:" p[1]
  next
}
AWKEOF

  (
    stdbuf -oL -eL "${cmd[@]}" 2>&1 | \
      stdbuf -oL -eL tee -a "$LOG_FILE" | \
      stdbuf -oL -eL awk -f "$awk_script"
    print -r -- "${pipestatus[1]:-0}" > "$exit_file"
  ) | while IFS= read -r token; do
    case "$token" in
      PREP:*) pkg="${token#PREP:}"; status="Preparing" ;;
      UNP:*)  pkg="${token#UNP:}";  status="Unpacking" ;;
      SET:*)  pkg="${token#SET:}";  status="Setting up" ;;
    esac
    (( current++ ))
    (( current > total )) && current=$total
    _bar "$current" "$total" "$pkg"
    printf "  ${W}%s${NC}\n" "$status" 2>/dev/null
  done

  printf "\r%-120s\r" " "
  rm -f "$awk_script"

  local exit_code=0
  [[ -f "$exit_file" ]] && exit_code=$(<"$exit_file")
  rm -f "$exit_file"
  return "$exit_code"
}

#=============================================================================
# HELPERS
#=============================================================================
_has_task() { [[ " ${SELECTED_TASKS[*]} " == *" $1 "* ]] }

_has_upgrades() {
  local count
  count=$(apt-get -s upgrade 2>/dev/null | awk '/^Inst /{c++} END{print c+0}')
  (( count > 0 ))
}

#=============================================================================
# ARG PARSE
#=============================================================================
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)     DRY_RUN=true ;;
      --auto)        AUTO=true ;;
      --full)        FULL=true ;;
      --quiet)       QUIET=true ;;
      --no-snapshot) NO_SNAPSHOT=true ;;
      --help) return 2 ;;
      *) print -r -- "Unknown option: $1"; return 1 ;;
    esac
    shift
  done
  return 0
}

#=============================================================================
# LOCK / SUDO
#=============================================================================
acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local old_pid
    old_pid=$(<"$LOCK_FILE" 2>/dev/null)
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      print -r -- "${R}[ERROR] sysmaint already running (PID ${old_pid}). Exiting.${NC}"
      return 1
    fi
    rm -f "$LOCK_FILE"
  fi
  print -r -- $$ > "$LOCK_FILE"
  trap 'rm -f "/tmp/sysmaint.lock"' EXIT
  trap 'rm -f "/tmp/sysmaint.lock"; print -r -- "\n'"${Y}"'Interrupted.'"${NC}"'\n"; return 1' INT TERM
}

sudo_check() {
  if ! sudo -n true 2>/dev/null; then
    _log WARN "Sudo requires password. Prompting..."
    sudo true || { _log ERROR "Sudo access denied. Aborting."; return 1; }
  fi
}

#=============================================================================
# TASK LIST / SELECTION (includes snap; hidden if snap isn't installed)
#=============================================================================
select_tasks() {
  local -a TASK_KEYS TASK_LABELS AVAILABLE_KEYS AVAILABLE_LABELS
  TASK_KEYS=("update" "upgrade" "autoremove" "clean" "dpkg-verify" "flatpak" "snap" "snapshot")
  TASK_LABELS=(
    "apt update       — refresh package index"
    "apt upgrade      — upgrade all packages"
    "apt autoremove   — remove unused dependencies"
    "apt clean        — clear downloaded package cache"
    "dpkg verify      — check installed package integrity"
    "flatpak update   — update Flatpak packages"
    "snap refresh     — update Snap packages"
    "snapshot         — create system snapshot (Timeshift/Btrfs)"
  )

  local n=${#TASK_KEYS[@]} i
  for (( i=1; i<=n; i++ )); do
    local key="${TASK_KEYS[$i]}"
    [[ "$key" == "flatpak" ]] && ! command -v flatpak &>/dev/null && continue
    [[ "$key" == "snap"    ]] && ! command -v snap    &>/dev/null && continue
    AVAILABLE_KEYS+=("$key")
    AVAILABLE_LABELS+=("${TASK_LABELS[$i]}")
  done

  local total=${#AVAILABLE_KEYS[@]}

  printf "\n${W}╔══════════════════════════════════════╗${NC}\n"
  printf "${W}║    sysmaint — System Maintenance     ║${NC}\n"
  printf "${W}╚══════════════════════════════════════╝${NC}\n\n"
  printf "${C}  Select tasks to run (e.g. 1 2 3 or 'all'):${NC}\n\n"

  for (( i=1; i<=total; i++ )); do
    printf "  ${W}[%d]${NC}  %s\n" "$i" "${AVAILABLE_LABELS[$i]}"
  done

  printf "\n"
  printf "${Y}  ▶  Enter numbers (space separated) or 'all': ${NC}"
  local selection=""
  read -r selection

  SELECTED_TASKS=()
  if [[ "$selection" == "all" ]]; then
    SELECTED_TASKS=("${AVAILABLE_KEYS[@]}")
  else
    for num in ${=selection}; do
      if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= total )); then
        SELECTED_TASKS+=("${AVAILABLE_KEYS[$num]}")
      else
        printf "${R}  Invalid: %s — skipped${NC}\n" "$num"
      fi
    done
  fi

  if (( ${#SELECTED_TASKS[@]} == 0 )); then
    print -r -- "\n${Y}  No tasks selected. Exiting.${NC}\n"
    return 1
  fi

  printf "\n${Y}  ▶  Confirm and run? (y/n): ${NC}"
  local confirm_ans=""
  read -r confirm_ans
  [[ "$confirm_ans" != "y" ]] && return 1
  return 0
}

#=============================================================================
# TASKS
#=============================================================================
task_snapshot() {
  _section "snapshot"
  snapshot_maybe_create && RAN+=("snapshot") || FAILED+=("snapshot")
}

task_update() {
  _section "apt update"
  _log INFO "Updating package index (clean terminal; full log)..."
  run_aptget_update_clean
  local rc=$?
  if (( rc == 0 )); then
    RAN+=("apt update")
  else
    FAILED+=("apt update")
    return 1
  fi

  # After update: show the table or the "no upgradable packages found" message
  show_upgradable_table_5col
  return 0
}

task_upgrade() {
  if ! _has_upgrades; then
    _log INFO "No packages to upgrade — skipping."
    SKIPPED+=("apt upgrade (nothing to do)")
    return 0
  fi

  _section "apt upgrade"
  _log INFO "Upgrading (progress + package + status; full output in log)..."
  run_apt_progress_with_status sudo apt-get upgrade -y
  local rc=$?
  (( rc == 0 )) && RAN+=("apt upgrade") || FAILED+=("apt upgrade")
  return "$rc"
}

task_autoremove() {
  _section "apt autoremove"
  run_cmd sudo apt-get autoremove -y && RAN+=("apt autoremove") || FAILED+=("apt autoremove")
}

task_clean() {
  _section "apt clean"
  run_cmd sudo apt-get clean && RAN+=("apt clean") || FAILED+=("apt clean")
}

task_dpkg_verify() {
  _section "dpkg verify"
  run_cmd sudo dpkg --verify && RAN+=("dpkg verify") || FAILED+=("dpkg verify")
}

task_flatpak() {
  _section "flatpak update"
  if ! command -v flatpak &>/dev/null; then
    _log SKIP "flatpak not installed — skipping"
    SKIPPED+=("flatpak update")
    return 0
  fi
  run_cmd flatpak update -y && RAN+=("flatpak update") || FAILED+=("flatpak update")
}

task_snap() {
  _section "snap refresh"
  if ! command -v snap &>/dev/null; then
    _log SKIP "snap not installed — skipping"
    SKIPPED+=("snap refresh")
    return 0
  fi
  run_cmd sudo snap refresh && RAN+=("snap refresh") || FAILED+=("snap refresh")
}

#=============================================================================
# SUMMARY
#=============================================================================
_disk_free_human() { df -h / | awk 'NR==2 {print $4}'; }
_disk_free_bytes() { df -B1 / | awk 'NR==2 {print $4}'; }
_bytes_to_human() {
  local b="$1"
  awk -v b="$b" 'BEGIN{split("B KB MB GB TB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++}printf "%.2f %s",b,u[i]}'
}

_state_write() {
  local tnow="$(date -Is)"
  local completed_json failed_json
  completed_json=$(printf '%s\n' "${RAN[@]}" | awk 'BEGIN{print "["} {gsub(/"/,"\\\""); printf "%s\"%s\"", (NR==1?"":","), $0} END{print "]"}')
  failed_json=$(printf '%s\n' "${FAILED[@]}" | awk 'BEGIN{print "["} {gsub(/"/,"\\\""); printf "%s\"%s\"", (NR==1?"":","), $0} END{print "]"}')
  cat > "$STATE_FILE" <<EOF
{
  "version": "$(print -r -- "$SYSMAINT_VERSION")",
  "time": "$(print -r -- "$tnow")",
  "completed": $completed_json,
  "failed": $failed_json
}
EOF
}

summary() {
  DISK_AFTER=$(_disk_free_human)
  DISK_BYTES_AFTER=$(_disk_free_bytes)
  PKG_AFTER=$(dpkg -l 2>/dev/null | grep -c '^ii')
  local END_TIME=$(date +%s)
  local ELAPSED=$((END_TIME - START_TIME))
  local freed=$(( DISK_BYTES_AFTER - DISK_BYTES_BEFORE ))
  local freed_h=$(_bytes_to_human "$freed" 2>/dev/null)

  _section "Run Summary"
  printf "${G}  ✔  Ran      :${NC} %s\n" "${RAN[*]:-none}"
  printf "${Y}  ⊘  Skipped  :${NC} %s\n" "${SKIPPED[*]:-none}"
  printf "${R}  ✘  Failed   :${NC} %s\n" "${FAILED[*]:-none}"
  printf "\n${C}  Disk free   :${NC} %s → %s\n" "$DISK_BEFORE" "$DISK_AFTER"
  printf "${C}  Disk delta  :${NC} %s\n" "$freed_h"
  printf "${C}  Packages    :${NC} %s → %s\n" "$PKG_BEFORE" "$PKG_AFTER"
  printf "${C}  Time taken  :${NC} %ss\n" "$ELAPSED"
  printf "${C}  Log saved   :${NC} %s\n\n" "$LOG_FILE"

  _state_write
}

#=============================================================================
# MAIN
#=============================================================================
main() {
  ORIG_ARGV=("$@")

  parse_args "$@"
  local prc=$?
  (( prc == 2 )) && return 0
  (( prc != 0 )) && return 1

  init_logging
  acquire_lock || return 1
  sudo_check || return 1

  START_TIME=$(date +%s)
  DISK_BEFORE=$(_disk_free_human)
  DISK_BYTES_BEFORE=$(_disk_free_bytes)
  PKG_BEFORE=$(dpkg -l 2>/dev/null | grep -c '^ii')

  _log INFO "Started at $(date)"
  _log INFO "Version: $SYSMAINT_VERSION"
  _log INFO "Log    : $LOG_FILE"

  net_check || _log WARN "No network connectivity detected. Network tasks will be skipped."

  select_tasks || { summary; return 0; }

  local t
  for t in "${SELECTED_TASKS[@]}"; do
    case "$t" in
      snapshot)   task_snapshot ;;
      update)     task_update ;;
      upgrade)    task_upgrade ;;
      autoremove) task_autoremove ;;
      clean)      task_clean ;;
      dpkg-verify) task_dpkg_verify ;;
      flatpak)    task_flatpak ;;
      snap)       task_snap ;;
    esac
  done

  summary
}

main "$@"
