#!/usr/bin/env zsh
#=============================================================================
# sysmaint — System Maintenance Tool (Zsh)
#
# Includes:
# - Logging + log retention + flag-aware logfile name
# - Interactive task menu + snapshot task
# - Upgrade progress bar (package name)
# - Skip upgrade completely when no packages are upgradable (no header/no bar)
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

  LOG_FILE="$LOG_DIR/sysmaint-$(date +%Y%m%d_%H%M%S)--${suffix}.log"

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
# APT REAL-TIME PROGRESS
#=============================================================================
run_apt_progress_pkgname_only() {
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

  local total
  total=$(apt list --upgradable 2>/dev/null | grep -vc '^Listing')
  [[ $total -lt 1 ]] && total=1

  local current=0 pkg=""
  local awk_script exit_file
  awk_script=$(mktemp /tmp/sysmaint_apt_awk.XXXX)
  exit_file=$(mktemp /tmp/sysmaint_apt_exit.XXXX)

  cat > "$awk_script" << 'AWKEOF'
/^Preparing to unpack/ {
  n=split($NF,a,"/")
  file=a[n]
  split(file,b,"_")
  if (b[1]!="") print "PKG:" b[1]
  next
}
/^(Unpacking|Setting up) / {
  split($2, p, ":")
  if (p[1]!="") print "PKG:" p[1]
  next
}
AWKEOF

  (
    stdbuf -oL -eL "${cmd[@]}" 2>&1 | \
      stdbuf -oL -eL tee -a "$LOG_FILE" | \
      stdbuf -oL -eL awk -f "$awk_script"
    print -r -- "${pipestatus[1]:-0}" > "$exit_file"
  ) | while IFS= read -r parsed; do
    case "$parsed" in
      PKG:*)
        pkg="${parsed#PKG:}"
        (( current++ ))
        _bar "$current" "$total" "$pkg"
        ;;
    esac
  done

  printf "\r%-80s\r" " "
  rm -f "$awk_script"

  local exit_code=0
  [[ -f "$exit_file" ]] && exit_code=$(<"$exit_file")
  rm -f "$exit_file"
  return "$exit_code"
}

#=============================================================================
# HELPERS
#=============================================================================
_has_upgrades() {
  local count
  count=$(apt-get -s upgrade 2>/dev/null | awk '/^Inst /{c++} END{print c+0}')
  (( count > 0 ))
}

#=============================================================================
# ARG PARSE  (FIXED: this function was missing)
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
}

sudo_check() {
  if ! sudo -n true 2>/dev/null; then
    _log WARN "Sudo requires password. Prompting..."
    sudo true || { _log ERROR "Sudo access denied. Aborting."; return 1; }
  fi
}

#=============================================================================
# TASK MENU (with snapshot)
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

  (( ${#SELECTED_TASKS[@]} == 0 )) && return 1

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
  run_with_spinner "apt-get update" sudo apt-get update && RAN+=("apt update") || FAILED+=("apt update")
}

task_upgrade() {
  # hide everything if nothing to do
  if ! _has_upgrades; then
    _log INFO "No packages to upgrade — skipping."
    SKIPPED+=("apt upgrade (nothing to do)")
    return 0
  fi

  _section "apt upgrade"
  run_apt_progress_pkgname_only sudo apt-get upgrade -y && RAN+=("apt upgrade") || FAILED+=("apt upgrade")
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
  local DISK_AFTER=$(_disk_free_human)
  local DISK_BYTES_AFTER=$(_disk_free_bytes)
  local PKG_AFTER=$(dpkg -l 2>/dev/null | grep -c '^ii')
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
      snapshot) task_snapshot ;;
      update) task_update ;;
      upgrade) task_upgrade ;;
      autoremove) run_cmd sudo apt-get autoremove -y ;;
      clean) run_cmd sudo apt-get clean ;;
      dpkg-verify) run_cmd sudo dpkg --verify ;;
      flatpak) run_cmd flatpak update -y ;;
      snap) run_cmd sudo snap refresh ;;
    esac
  done

  summary
}

main "$@"
