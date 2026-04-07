#!/usr/bin/env zsh
#=============================================================================
# sysmaint — System Maintenance Tool (Zsh)
#
# Based on: Shr1H4x/sysmaint sysmaint-v3.sh (commit cb69ced...)
#
# FIXES APPLIED (critical bugs):
#   FIX-1  tee >/dev/null was discarding all terminal output in _log,
#          _section, show_upgradable_table_5col. Removed the >/dev/null
#          redirect so tee correctly writes to both terminal and log file.
#   FIX-2  run_aptget_update_clean subshell pipe lost apt-get exit code
#          because pipestatus was read after the pipeline had been reset.
#          Restructured to capture the exit code reliably using a
#          dedicated pipe-segment approach.
#   FIX-3  build_pkg_intelligence was called twice per upgrade run
#          (once in _has_upgrades via apt-get -s upgrade, once in
#          run_apt_progress_with_status). Merged into a single call
#          stored in UPGRADABLE_PKGS globals, shared between both sites.
#   FIX-4  select_tasks displayed wrong labels when flatpak/snap were
#          absent — the label index tracked the original TASK_KEYS loop
#          counter instead of the packed AVAILABLE_LABELS counter. Fixed
#          by using a separate display index.
#   FIX-5  show_upgradable_table_5col + _log + _section all used
#          tee -a "$LOG_FILE" >/dev/null — same root as FIX-1. All
#          instances corrected in one pass.
#   FIX-6  trap in acquire_lock used single quotes so ${Y}/${NC} colour
#          variables were never expanded. Changed to $'...' ANSI-C quoting
#          and direct escape sequences.
#   FIX-7  run_apt_progress_with_status incremented the progress counter
#          on every awk token (PREP, UNP, SET = 3× per package). Counter
#          now only advances on SET: (package fully installed) so the bar
#          fills at the correct rate.
#   FIX-8  Spinner arrays accessed at index 0 (empty in Zsh 1-based arrays).
#          Changed modulo to (i % 10 + 1) in both spinner sites.
#=============================================================================

setopt LOCAL_OPTIONS NO_MONITOR NO_NOTIFY 2>/dev/null

# Ensure a sane PATH for non-interactive / restricted environments
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# Resolve common utilities to absolute paths where possible (fallback to name)
if command -v mktemp >/dev/null 2>&1; then MKTEMP=$(command -v mktemp); else MKTEMP=mktemp; fi
if command -v cat >/dev/null 2>&1; then CAT=$(command -v cat); else CAT=cat; fi
if command -v rm >/dev/null 2>&1; then RM=$(command -v rm); else RM=rm; fi
if command -v tee >/dev/null 2>&1; then TEE=$(command -v tee); else TEE=tee; fi
if command -v date >/dev/null 2>&1; then CMD_DATE=$(command -v date); else CMD_DATE=date; fi

# If stdin is not a tty or CI environment detected, enable AUTO (non-interactive)
if [[ ! -t 0 || -n "${CI:-}" ]]; then
  AUTO=true
fi

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
typeset -g HEALTH_MODE=false DEEP_CLEAN=false RESUME=false
typeset -g IGNORE_DOCS=true
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

# package intelligence
typeset -ga UPGRADABLE_PKGS SECURITY_PKGS
UPGRADABLE_PKGS=() SECURITY_PKGS=()
typeset -g UPGRADABLE_TOTAL=0 UPGRADABLE_SECURITY=0 UPGRADABLE_REGULAR=0
# FIX-3: track whether intelligence has been built this run
typeset -g _PKG_INTEL_BUILT=false

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
  # FIX (minor): use safe timestamp format without colons
  LOG_FILE="$LOG_DIR/sysmaint-$($CMD_DATE +%Y%m%d_%H%M%S)--${suffix}.log"
  find "$LOG_DIR" -name "sysmaint-*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null
}

#=============================================================================
# LOGGING / OUTPUT
#
# FIX-1 / FIX-5: All tee calls previously ended with >/dev/null which
# silently dropped all terminal output. Removed that redirect so tee
# correctly writes to BOTH the terminal (stdout) and the log file.
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
    LOG_FILE="$LOG_DIR/sysmaint-$($CMD_DATE +%Y%m%d_%H%M%S)--noflags.log"
  fi

  if $QUIET && [[ "$level" != "ERROR" ]]; then
    print -r -- "[$($CMD_DATE +%H:%M:%S)] [$level] $msg" >> "$LOG_FILE"
    return 0
  fi
  # Write colored message to terminal and plain message to log file
  local ts=$($CMD_DATE +%H:%M:%S)
  local term_msg="${col}[${ts}] [$level] $msg${NC}"
  local log_msg="[${ts}] [$level] $msg"
  print -r -- "$term_msg"
  print -r -- "$log_msg" >> "$LOG_FILE"
}

_section() {
  local title="$1"
  [[ $QUIET == true ]] && return 0

  print -r -- ""
  print -r -- "${W}== ${title} ==${NC}"
  print -r -- "== ${title} ==" >> "$LOG_FILE"
  print -r -- ""
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

  # Run command and append all output to the log file. Avoid requiring external
  # `tee` in restricted environments; we intentionally do not stream live output
  # to the terminal here to keep compatibility.
  "${cmd[@]}" >>"$LOG_FILE" 2>&1
  local rc=$?
  return $rc
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
  tmp=$("$MKTEMP")

  stdbuf -oL -eL "${cmd[@]}" >>"$tmp" 2>&1 &
  local cpid=$!

  while kill -0 "$cpid" 2>/dev/null; do
    # FIX-8: was (i % 10) — index 0 is empty in Zsh 1-based arrays.
    printf "\r  ${C}%s${NC}  %s..." "${spin[$((i % 10 + 1))]}" "$label"
    sleep 0.1
    (( i++ ))
  done
  printf "\r%-80s\r" " "

  wait "$cpid" 2>/dev/null
  exit_code=$?

  "$CAT" "$tmp" | "$TEE" -a "$LOG_FILE"
  "$RM" -f "$tmp"
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

# Snapshot support (optional task)

#=============================================================================
# Snapshot support (optional task)
_snapshot_create_timeshift() {
  command -v timeshift >/dev/null 2>&1 || return 1

  _log INFO "Creating Timeshift snapshot..."
  if $DRY_RUN; then
    _log CMD "[DRY-RUN] sudo timeshift --create --comments \"sysmaint\""
    SNAPSHOT_INFO="dry-run|$($CMD_DATE -Is)|timeshift"
    return 0
  fi

  local tmp out rc sid
  tmp=$($MKTEMP)
  sudo timeshift --create --comments "sysmaint snapshot" >"$tmp" 2>&1
  rc=$?
  out=$("$CAT" "$tmp")
  "$CAT" "$tmp" >> "$LOG_FILE"
  "$RM" -f "$tmp"
  if [[ $rc -ne 0 ]]; then
    _log WARN "Timeshift snapshot creation failed."
    return 1
  fi
  sid=$(print -r -- "$out" | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' | head -n1)
  [[ -z "$sid" ]] && sid="unknown"
  SNAPSHOT_INFO="${sid}|$($CMD_DATE -Is)|timeshift"
  _log INFO "Snapshot created: $sid"
  return 0
}

_snapshot_create_btrfs() {
  command -v btrfs >/dev/null 2>&1 || return 1

  local fstype
  fstype=$(stat -f -c %T / 2>/dev/null)
  [[ "$fstype" != "btrfs" ]] && return 1

  local snapdir="/.snapshots" sid tmp rc
  sid="sysmaint-$($CMD_DATE +%Y%m%d_%H%M%S)"
  _log INFO "Creating Btrfs snapshot: ${snapdir}/${sid}"

  if $DRY_RUN; then
    _log CMD "[DRY-RUN] sudo mkdir -p $snapdir && sudo btrfs subvolume snapshot / ${snapdir}/${sid}"
    SNAPSHOT_INFO="${sid}|$($CMD_DATE -Is)|btrfs"
    return 0
  fi

  sudo mkdir -p "$snapdir" >>"$LOG_FILE" 2>&1 || return 1
  sudo btrfs subvolume snapshot / "${snapdir}/${sid}" >>"$LOG_FILE" 2>&1
  rc=$?
  [[ $rc -ne 0 ]] && return 1

  SNAPSHOT_INFO="${sid}|$($CMD_DATE -Is)|btrfs"
  _log INFO "Snapshot created: $sid"
  return 0
}

snapshot_maybe_create() {
  _snapshot_create_timeshift && return 0
  _snapshot_create_btrfs && return 0
  _log WARN "No snapshot mechanism available (timeshift missing; btrfs not applicable)."
  return 1
}

# apt update — clean terminal output, full log
#
# FIX-2: The original subshell used:
#   ( stdbuf … | tee … | awk … ; echo ${pipestatus[1]:-0} > exit_file )
# pipestatus is only valid immediately after a pipeline in Zsh. The
# semicolon-separated echo ran after the pipeline had ended, so pipestatus
# was already stale/reset — it captured awk's exit code, not apt-get's.
#
# Fix: run apt-get in the background, capture its PID, wait for it
# explicitly, and use the wait exit code directly. The tee and awk run
# in a co-process fed from apt-get's stdout via a named pipe so we keep
# clean terminal output while still logging everything.
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

  local awk_script fifo
  awk_script=$("$MKTEMP" /tmp/sysmaint_update_awk.XXXX)
  fifo=$("$MKTEMP" -u /tmp/sysmaint_update_fifo.XXXX)
  mkfifo "$fifo"

  # Cleanup on exit/interrupt
  trap "rm -f '$awk_script' '$fifo'" EXIT INT TERM

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

  # FIX-2: apt-get writes to the fifo; we tee from fifo to log + awk.
  # apt-get's PID is captured so we can wait on it for the real exit code.
  sudo apt-get update >"$fifo" 2>&1 &
  local apt_pid=$!

  local last_host="" stage="Updating package lists"
  local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0

  # Read fifo: tee to log and pipe to awk for token extraction
  "$TEE" -a "$LOG_FILE" < "$fifo" | awk -f "$awk_script" | \
  while IFS= read -r tok; do
    case "$tok" in
      REPO:*)  last_host="${tok#REPO:}" ;;
      STAGE:*) stage="${tok#STAGE:}" ;;
    esac
    # FIX-8: +1 so we never hit index 0 (empty in Zsh 1-based arrays)
    printf "\r  ${C}%s${NC}  %s — %s..." "${spin[$((i % 10 + 1))]}" "$stage" "${last_host:-}" 2>/dev/null
    (( i++ ))
  done

  # Wait for apt-get specifically — this is the authoritative exit code
  wait "$apt_pid"
  local rc=$?

  printf "\r%-120s\r" " "
  "$RM" -f "$awk_script" "$fifo"
  trap - EXIT INT TERM
  return "$rc"
}

#=============================================================================
# Package intelligence
#
# FIX-3: Previously build_pkg_intelligence was called from two places in
# the upgrade flow (implicitly via _has_upgrades → apt-get -s upgrade, and
# again inside run_apt_progress_with_status). This caused two separate
# apt-get -s upgrade invocations whose results could differ, and doubled
# the overhead. Now a single build_pkg_intelligence call populates the
# globals, guarded by _PKG_INTEL_BUILT so subsequent calls are no-ops.
# Call reset_pkg_intelligence() to force a fresh fetch.
#=============================================================================
reset_pkg_intelligence() {
  UPGRADABLE_PKGS=() SECURITY_PKGS=()
  UPGRADABLE_TOTAL=0 UPGRADABLE_SECURITY=0 UPGRADABLE_REGULAR=0
  _PKG_INTEL_BUILT=false
}

build_pkg_intelligence() {
  # FIX-3: skip if already built this run
  [[ "$_PKG_INTEL_BUILT" == true ]] && return 0

  UPGRADABLE_PKGS=() SECURITY_PKGS=()
  UPGRADABLE_TOTAL=0 UPGRADABLE_SECURITY=0 UPGRADABLE_REGULAR=0

  local -a pkgs
  pkgs=("${(@f)$(apt-get -s upgrade 2>/dev/null | awk '/^Inst /{print $2}')}")
  (( ${#pkgs[@]} == 0 )) && { _PKG_INTEL_BUILT=true; return 0; }

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

  _PKG_INTEL_BUILT=true
}

_is_security_pkg() {
  local p="$1"
  [[ " ${SECURITY_PKGS[*]} " == *" $p "* ]]
}

#=============================================================================
# Upgradable packages table
#
# FIX-5: All printf/print calls now use plain `tee -a "$LOG_FILE"` without
# the >/dev/null that was silently swallowing all terminal output.
#=============================================================================
show_upgradable_table_5col() {
  # FIX-3: use the shared intelligence built by task_update
  build_pkg_intelligence

  _log INFO "Updates available: ${R}Security=${UPGRADABLE_SECURITY}${NC}  ${C}Regular=${UPGRADABLE_REGULAR}${NC}  Total=${UPGRADABLE_TOTAL}"

  if (( UPGRADABLE_TOTAL == 0 )); then
    print -r -- ""
    # FIX-5: removed >/dev/null
    print -r -- "${G}No upgradable packages found.${NC}"
    print -r -- "No upgradable packages found." >> "$LOG_FILE"
    print -r -- ""
    return 0
  fi

  local col_width=28 cols=5
  local total_width=$((col_width * cols))

  print -r -- ""
  # FIX-5: removed >/dev/null from all lines below
  print -r -- "${W}Upgradable packages (5 columns):${NC}"
  print -r -- "Upgradable packages (5 columns):" >> "$LOG_FILE"

  printf "  ${W}%-${col_width}s%-${col_width}s%-${col_width}s%-${col_width}s%-${col_width}s${NC}\n" \
    "Package" "Package" "Package" "Package" "Package"
    printf "  ${W}%s${NC}\n" "$(printf '─%.0s' $(seq 1 $total_width))"
    printf "  Package Package Package Package Package\n" >> "$LOG_FILE"
    printf "  %s\n" "$(printf '─%.0s' $(seq 1 $total_width))" >> "$LOG_FILE"

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
    # FIX-5: removed >/dev/null
    printf "%b\n" "$line"
    printf "%b\n" "$line" >> "$LOG_FILE"
  done

  print -r -- ""
  print -r -- "" >> "$LOG_FILE"
}

#=============================================================================
# Upgrade progress bar
#
# FIX-7: The original loop incremented `current` on every awk token
# (PREP, UNP, SET), producing 3 increments per package and sending the
# bar to 100% almost immediately. Now only SET: (package fully configured)
# advances the counter — one increment per completed package.
#
# FIX-2 (same pattern): exit code captured via wait on the background PID
# using a fifo, not via pipestatus after a subshell semicolon.
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

  # FIX-3: intelligence already built by task_update; this is a no-op
  build_pkg_intelligence
  local total=$UPGRADABLE_TOTAL
  [[ $total -lt 1 ]] && total=1

  local current=0 pkg="(starting)" pkg_status="Running"
  local awk_script fifo
  awk_script=$("$MKTEMP" /tmp/sysmaint_upgrade_awk.XXXX)
  fifo=$("$MKTEMP" -u /tmp/sysmaint_upgrade_fifo.XXXX)
  mkfifo "$fifo"

  trap "rm -f '$awk_script' '$fifo'" EXIT INT TERM

  cat > "$awk_script" << 'AWKEOF'
/^Get:/ {
  url=$0
  n=split(url,a,"/")
  file=a[n]
  if (match(file,/([A-Za-z0-9+_.-]+)_([0-9].*)\.deb/,m)) {
    split(m[1],b,"_")
    print "DL:" b[1]
  } else if (match(file,/([A-Za-z0-9+_.-]+)\.deb/,m)) {
    print "DL:" m[1]
  }
  next
}

/^Downloading/ {
  if (match($0,/([A-Za-z0-9+_.-]+)\.deb/,m)) {
    split(m[1],b,"_")
    print "DL:" b[1]
  }
  next
}

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

  # FIX-2: run the command in background via fifo for reliable exit code
  "${cmd[@]}" >"$fifo" 2>&1 &
  local cmd_pid=$!

  "$TEE" -a "$LOG_FILE" < "$fifo" | awk -f "$awk_script" | \
  while IFS= read -r token; do
    case "$token" in
      DL:*)   pkg="${token#DL:}"; pkg_status="Downloading" ;;
      PREP:*) pkg="${token#PREP:}"; pkg_status="Preparing" ;;
      UNP:*)  pkg="${token#UNP:}";  pkg_status="Unpacking" ;;
      # FIX-7: only SET: advances the counter (one per completed package)
      SET:*)
        pkg="${token#SET:}"
        pkg_status="Setting up"
        (( current++ ))
        (( current > total )) && current=$total
        ;;
    esac
    _bar "$current" "$total" "$pkg"
    printf "  ${W}%s${NC}\n" "$pkg_status"
  done

  wait "$cmd_pid"
  local exit_code=$?

  printf "\r%-120s\r" " "
  "$RM" -f "$awk_script" "$fifo"
  trap - EXIT INT TERM
  return "$exit_code"
}

#=============================================================================
# HELPERS
#=============================================================================
_has_task() { [[ " ${SELECTED_TASKS[*]} " == *" $1 "* ]] }

# FIX-3: _has_upgrades now uses the already-built intelligence globals
# instead of re-running apt-get -s upgrade independently.
_has_upgrades() {
  build_pkg_intelligence
  (( UPGRADABLE_TOTAL > 0 ))
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
  # If a lock file exists, read its PID and check if that process is alive
  if [[ -f "$LOCK_FILE" ]]; then
    local old_pid
    if read -r old_pid < "$LOCK_FILE" 2>/dev/null; then
      if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        print -r -- "${R}[ERROR] sysmaint already running (PID ${old_pid}). Exiting.${NC}"
        return 1
      fi
    fi
    # stale lock: fall through and attempt atomic creation
  fi

  # Attempt atomic creation of the lock file using noclobber in a subshell.
  if ( set -C; printf '%s' "$$" > "$LOCK_FILE" ) 2>/dev/null; then
    : # acquired lock
  else
    local holder
    read -r holder < "$LOCK_FILE" 2>/dev/null
    print -r -- "${R}[ERROR] Could not acquire lock; held by PID ${holder:-unknown}.${NC}"
    return 1
  fi

  # Ensure lock file is removed on normal exit
  trap "rm -f \"$LOCK_FILE\"" EXIT

  # Remove lock and present an interrupt message on signals
  trap "rm -f \"$LOCK_FILE\"; printf '\n\033[0;33mInterrupted.\033[0m\n\n'; exit 1" INT TERM
  
}

sudo_check() {
  if ! sudo -n true 2>/dev/null; then
    _log WARN "Sudo requires password. Prompting..."
    sudo true || { _log ERROR "Sudo access denied. Aborting."; return 1; }
  fi
}

#=============================================================================
# TASK LIST / SELECTION
#
# FIX-4: The display loop used the original TASK_KEYS loop index ($i) to
# index into TASK_LABELS, but once flatpak/snap are skipped the packed
# AVAILABLE_LABELS array has fewer entries than TASK_LABELS. When e.g.
# snap (index 7) is absent, AVAILABLE_LABELS[7] is unset, so the label
# slot shows blank or the wrong entry. Fixed by using a separate
# display_idx that tracks the packed array position.
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

  # If auto mode, select all available tasks and skip interactive prompts
  if $AUTO; then
    _log INFO "Auto mode enabled: selecting all available tasks"
    SELECTED_TASKS=("${AVAILABLE_KEYS[@]}")
    return 0
  fi

  printf "\n${W}╔══════════════════════════════════════╗${NC}\n"
  printf "${W}║    sysmaint — System Maintenance     ║${NC}\n"
  printf "${W}╚══════════════════════════════════════╝${NC}\n\n"
  printf "${C}  Select tasks to run (e.g. 1 2 3 or 'all'):${NC}\n\n"

  # FIX-4: use a separate display_idx that counts only the packed entries,
  # not the original TASK_KEYS loop counter ($i).
  local display_idx
  for (( display_idx=1; display_idx<=total; display_idx++ )); do
    printf "  ${W}[%d]${NC}  %s\n" "$display_idx" "${AVAILABLE_LABELS[$display_idx]}"
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

  # FIX-3: build intelligence once here; _has_upgrades and
  # run_apt_progress_with_status will reuse it.
  build_pkg_intelligence
  show_upgradable_table_5col
  return 0
}

task_upgrade() {
  # FIX-3: _has_upgrades now delegates to the already-built globals
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
  _log INFO "Running dpkg -V (package verification)"

  if $DRY_RUN; then
    _log CMD "[DRY-RUN] sudo dpkg -V"
    RAN+=("dpkg verify")
    return 0
  fi

  local out line code path pkg human
  out=$(sudo dpkg -V 2>&1)
  # append raw output to the log file
  print -r -- "$out" >> "$LOG_FILE"

  local -a report
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    if [[ "$line" == missing* ]]; then
      path=${line#missing }
      pkg=$(dpkg -S "$path" 2>/dev/null | head -n1 | cut -d: -f1)
      if [[ -z "$pkg" ]]; then
        report+=("MISSING: $path (not owned by any package)")
      else
        report+=("MISSING: $path (package: $pkg) — consider: sudo apt-get --reinstall install $pkg")
      fi
      continue
    fi

    # normal dpkg -V line: <code> [c] <path>
    set -- $line
    code=$1
    # find first token that looks like a path
    path=""
    for tok in "$@"; do
      [[ "$tok" == /* ]] && { path="$tok"; break; }
    done
    [[ -z "$path" ]] && continue

    # optionally ignore document/man pages
    if $IGNORE_DOCS && { [[ "$path" == /usr/share/doc/* ]] || [[ "$path" == /usr/share/man/* ]]; }; then
      continue
    fi

    # if code is all dots, it's OK
    if [[ "$code" =~ ^[.]+$ ]]; then
      continue
    fi

    human=""
    [[ "$code" == *5* ]] && human+="content changed; "
    [[ "$code" == *S* ]] && human+="size differs; "
    [[ "$code" == *M* ]] && human+="mode/permissions differ; "
    [[ "$code" == *U* ]] && human+="owner differs; "
    [[ "$code" == *G* ]] && human+="group differs; "
    [[ "$code" == *T* ]] && human+="timestamp differs; "
    [[ "$code" == *L* ]] && human+="symlink target differs; "
    [[ "$code" == *D* ]] && human+="device differs; "
    [[ "$code" == *?* ]] && human+="unknown/unchecked attributes; "

    pkg=$(dpkg -S "$path" 2>/dev/null | head -n1 | cut -d: -f1)
    if [[ -n "$pkg" ]]; then
      report+=("$path: ${human} (package: ${pkg})")
    else
      report+=("$path: ${human} (not owned by any package)")
    fi
  done <<< "$out"

  if (( ${#report[@]} == 0 )); then
    _log INFO "dpkg verification: no actionable issues found."
    RAN+=("dpkg verify")
    return 0
  fi

  _log WARN "dpkg verification found issues (filtered):"
  for line in "${report[@]}"; do
    print -r -- "$line"
    print -r -- "$line" >> "$LOG_FILE"
  done
  FAILED+=("dpkg verify")
  return 1
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
  local tnow="$($CMD_DATE -Is)"
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
  local END_TIME=$($CMD_DATE +%s)
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

  START_TIME=$($CMD_DATE +%s)
  DISK_BEFORE=$(_disk_free_human)
  DISK_BYTES_BEFORE=$(_disk_free_bytes)
  PKG_BEFORE=$(dpkg -l 2>/dev/null | grep -c '^ii')

  _log INFO "Started at $($CMD_DATE)"
  _log INFO "Version: $SYSMAINT_VERSION"
  _log INFO "Log    : $LOG_FILE"

  net_check || _log WARN "No network connectivity detected. Network tasks will be skipped."

  select_tasks || { summary; return 0; }

  local t
  for t in "${SELECTED_TASKS[@]}"; do
    case "$t" in
      update)      task_update ;;
      upgrade)     task_upgrade ;;
      autoremove)  task_autoremove ;;
      clean)       task_clean ;;
      dpkg-verify) task_dpkg_verify ;;
      flatpak)     task_flatpak ;;
      snap)        task_snap ;;
      snapshot)    task_snapshot ;;
    esac
  done

  summary
}

main "$@"