
#=============================================================================
# === sysmaint — System Maintenance Function ===
#=============================================================================
sysmaint() {
    # ============================================================
    # CONSTANTS & DEFAULTS
    # ============================================================
    local LOG_DIR="$HOME/.sysmaint/logs"
    local LOG_FILE="$LOG_DIR/sysmaint-$(date +%Y%m%d_%H%M%S).log"
    local LOCK_FILE="/tmp/sysmaint.lock"
    local LOG_RETENTION_DAYS=14
    local DRY_RUN=false AUTO=false FULL=false QUIET=false
    local START_TIME DISK_BEFORE PKG_BEFORE
    local -a RAN SKIPPED FAILED SELECTED_TASKS

    # Suppress zsh job control noise
    setopt LOCAL_OPTIONS NO_MONITOR NO_NOTIFY 2>/dev/null

    # ============================================================
    # COLOURS
    # ============================================================
    local R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m'
    local B='\033[0;34m' C='\033[0;36m' W='\033[1;37m' NC='\033[0m'

    # ============================================================
    # PARSE ARGUMENTS
    # ============================================================
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=true ;;
            --auto)    AUTO=true ;;
            --full)    FULL=true ;;
            --quiet)   QUIET=true ;;
            --help)
                echo "Usage: sysmaint [--dry-run] [--auto] [--full] [--quiet]"
                echo ""
                echo "  (no flags)   Interactive menu — pick tasks by number"
                echo "  --auto       Ask y/n per task, then run selected automatically"
                echo "  --dry-run    Show what would run without executing"
                echo "  --full       Include apt full-upgrade in task list"
                echo "  --quiet      Suppress output except errors"
                return 0
                ;;
            *) echo "Unknown option: $1"; return 1 ;;
        esac
        shift
    done

    # ============================================================
    # HELPERS
    # ============================================================

    _log() {
        local level="$1" msg="$2" col="$NC"
        case "$level" in
            INFO)  col="$G" ;;
            WARN)  col="$Y" ;;
            ERROR) col="$R" ;;
            SKIP)  col="$B" ;;
            CMD)   col="$C" ;;
        esac
        printf "${col}[%s] [%s] %s${NC}\n" "$(date +%H:%M:%S)" "$level" "$msg" | tee -a "$LOG_FILE"
    }

    # ── Generic run — streams live ────────────────────────────────
    run_cmd() {
        local -a cmd=("$@")
        $DRY_RUN && { _log CMD "[DRY-RUN] ${cmd[*]}"; return 0; }
        _log CMD "${cmd[*]}"
        if $QUIET; then
            "${cmd[@]}" >> "$LOG_FILE" 2>&1
            return $?
        fi
        "${cmd[@]}" 2>&1 | tee -a "$LOG_FILE"
        return "${pipestatus[1]:-${PIPESTATUS[0]}}"
    }

    # ── Draw progress bar ─────────────────────────────────────────
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

    # ── Realtime apt upgrade with live progress bar ───────────────
    run_apt_progress() {
        local -a cmd=("$@")
        $DRY_RUN && { _log CMD "[DRY-RUN] ${cmd[*]}"; return 0; }
        _log CMD "${cmd[*]}"

        if $QUIET; then
            "${cmd[@]}" >> "$LOG_FILE" 2>&1
            return $?
        fi

        local total
        total=$(apt list --upgradable 2>/dev/null | grep -vc "^Listing")
        [[ $total -lt 1 ]] && total=1

        local current=0 pkg=""

        local awk_script exit_file
        awk_script=$(mktemp /tmp/sysmaint_awk.XXXX)
        exit_file=$(mktemp /tmp/sysmaint_exit.XXXX)

        cat > "$awk_script" << 'AWKEOF'
/^Get:[0-9]/ {
    n = split($0, parts, " ")
    print "DL:" parts[n-1]
    next
}
/^(Unpacking|Setting up) / {
    split($2, p, ":")
    print "PKG:" p[1]
    next
}
AWKEOF

        (
            stdbuf -oL "${cmd[@]}" 2>&1 | \
            stdbuf -oL tee -a "$LOG_FILE" | \
            stdbuf -oL awk -f "$awk_script"
            echo "${pipestatus[1]:-0}" > "$exit_file"
        ) | while IFS= read -r parsed; do
            case "$parsed" in
                DL:*)
                    pkg="${parsed#DL:}"
                    printf "\r%-80s\r" " "
                    printf "  ${C}↓${NC}  %s\n" "$pkg"
                    ;;
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
        [[ -f "$exit_file" ]] && exit_code=$(cat "$exit_file")
        rm -f "$exit_file"
        return "$exit_code"
    }

    # ── Realtime flatpak update with live progress bar ────────────
    run_flatpak_progress() {
        $DRY_RUN && { _log CMD "[DRY-RUN] flatpak update -y"; return 0; }
        _log CMD "flatpak update -y"

        if $QUIET; then
            flatpak update -y >> "$LOG_FILE" 2>&1
            return $?
        fi

        local total=0 current=0 action="Installing"
        local awk_script exit_file
        awk_script=$(mktemp /tmp/sysmaint_awk.XXXX)
        exit_file=$(mktemp /tmp/sysmaint_exit.XXXX)

        cat > "$awk_script" << 'AWKEOF'
/^[[:space:]]+[0-9]+\./ { print "COUNT"; next }
/^(Installing|Updating)[[:space:]]+[0-9]+\/[0-9]+/ {
    split($0, a, " ")
    split(a[2], b, "/")
    print "PROG:" a[1] ":" b[1] ":" b[2]
    next
}
/Changes complete/ { print "DONE"; next }
AWKEOF

        (
            stdbuf -oL flatpak update -y 2>&1 | \
            stdbuf -oL tee -a "$LOG_FILE" | \
            stdbuf -oL awk -f "$awk_script"
            echo "${pipestatus[1]:-0}" > "$exit_file"
        ) | while IFS= read -r parsed; do
            case "$parsed" in
                COUNT) (( total++ )) ;;
                PROG:*)
                    local rest="${parsed#PROG:}"
                    action="${rest%%:*}"; rest="${rest#*:}"
                    current="${rest%%:*}"; total="${rest#*:}"
                    _bar "$current" "$total" "$action"
                    ;;
                DONE)
                    printf "\r%-80s\r" " "
                    printf "  ${G}✔${NC}  Changes complete.\n"
                    ;;
            esac
        done

        printf "\r%-80s\r" " "
        rm -f "$awk_script"

        local exit_code=0
        [[ -f "$exit_file" ]] && exit_code=$(cat "$exit_file")
        rm -f "$exit_file"
        return "$exit_code"
    }

    # ── Spinner for commands without parseable progress ───────────
    run_with_spinner() {
        local label="$1"; shift
        local -a cmd=("$@")
        $DRY_RUN && { _log CMD "[DRY-RUN] ${cmd[*]}"; return 0; }
        _log CMD "${cmd[*]}"

        if $QUIET; then
            "${cmd[@]}" >> "$LOG_FILE" 2>&1
            return $?
        fi

        local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local tmp exit_code i=0
        tmp=$(mktemp)

        "${cmd[@]}" >> "$tmp" 2>&1 &
        local cpid=$!
        while kill -0 "$cpid" 2>/dev/null; do
            printf "\r  ${C}%s${NC}  %s..." "${spin[$((i % 10))]}" "$label"
            sleep 0.1
            (( i++ ))
        done
        printf "\r%-60s\r" " "
        wait "$cpid" 2>/dev/null
        exit_code=$?
        cat "$tmp" | tee -a "$LOG_FILE"
        rm -f "$tmp"
        return "$exit_code"
    }

    _has_task() { [[ " ${SELECTED_TASKS[*]} " == *" $1 "* ]] }

    # ============================================================
    # TASK DEFINITIONS
    # ============================================================
    local -a TASK_KEYS TASK_LABELS AVAILABLE_KEYS AVAILABLE_LABELS
    TASK_KEYS=("update" "upgrade" "autoremove" "clean" "dpkg-verify" "flatpak" "snap")
    TASK_LABELS=(
        "apt update       — refresh package index"
        "apt upgrade      — upgrade all packages"
        "apt autoremove   — remove unused dependencies"
        "apt clean        — clear downloaded package cache"
        "dpkg verify      — check installed package integrity"
        "flatpak update   — update Flatpak packages"
        "snap refresh     — update Snap packages"
    )

    if $FULL; then
        TASK_KEYS+=("full-upgrade")
        TASK_LABELS+=("apt full-upgrade — full system upgrade (may remove packages)")
    fi

    local n=${#TASK_KEYS[@]} i
    for (( i=1; i<=n; i++ )); do
        local key="${TASK_KEYS[$i]}"
        [[ "$key" == "flatpak" ]] && ! command -v flatpak &>/dev/null && continue
        [[ "$key" == "snap"    ]] && ! command -v snap    &>/dev/null && continue
        AVAILABLE_KEYS+=("$key")
        AVAILABLE_LABELS+=("${TASK_LABELS[$i]}")
    done

    # ============================================================
    # TASK SELECTION
    # ============================================================
    local total=${#AVAILABLE_KEYS[@]}

    if $AUTO; then
        if [[ ! -t 0 ]]; then
            _log WARN "Non-interactive — running all tasks automatically"
            SELECTED_TASKS=("${AVAILABLE_KEYS[@]}")
        else
            echo -e "\n${W}  Select tasks to run:${NC}\n"
            for (( i=1; i<=total; i++ )); do
                local ans=""
                printf "${Y}  ▶  %s (y/n): ${NC}" "${AVAILABLE_LABELS[$i]}"
                read -r ans
                [[ "$ans" == "y" ]] && SELECTED_TASKS+=("${AVAILABLE_KEYS[$i]}")
            done
        fi
    else
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
    fi

    if [[ ${#SELECTED_TASKS[@]} -eq 0 ]]; then
        printf "\n${Y}  No tasks selected. Exiting.${NC}\n\n"
        return 0
    fi

    # ============================================================
    # CONFIRMATION SUMMARY
    # ============================================================
    printf "\n${W}  Tasks queued to run:${NC}\n\n"
    for task in "${SELECTED_TASKS[@]}"; do
        printf "  ${G}✔${NC}  %s\n" "$task"
    done
    printf "\n"
    printf "${Y}  ▶  Confirm and run? (y/n): ${NC}"
    local confirm_ans=""
    read -r confirm_ans
    [[ "$confirm_ans" != "y" ]] && { printf "\n${Y}  Aborted.${NC}\n\n"; return 0; }

    # ============================================================
    # PRE-FLIGHT CHECKS
    # ============================================================
    if [[ -f "$LOCK_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            printf "${R}[ERROR] sysmaint already running (PID %s). Exiting.${NC}\n" "$old_pid"
            return 1
        fi
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "/tmp/sysmaint.lock"' EXIT
    trap 'rm -f "/tmp/sysmaint.lock"; printf "\n${Y}Interrupted.${NC}\n"; return 1' INT TERM

    if ! sudo -n true 2>/dev/null; then
        _log WARN "Sudo requires password. Prompting..."
        sudo true || { _log ERROR "Sudo access denied. Aborting."; return 1; }
    fi

    mkdir -p "$LOG_DIR"
    find "$LOG_DIR" -name "sysmaint-*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null
    _log INFO "Old logs (>${LOG_RETENTION_DAYS}d) cleaned"

    # ============================================================
    # SYSTEM SNAPSHOT — BEFORE
    # ============================================================
    START_TIME=$(date +%s)
    DISK_BEFORE=$(df -h / | awk 'NR==2 {print $4}')
    PKG_BEFORE=$(dpkg -l 2>/dev/null | grep -c '^ii')

    printf "\n${W}╔══════════════════════════════════════╗${NC}\n"
    printf "${W}║             Running Tasks            ║${NC}\n"
    printf "${W}╚══════════════════════════════════════╝${NC}\n\n"
    _log INFO "Started at $(date)"
    _log INFO "Log    : $LOG_FILE"
    _log INFO "Disk   : $DISK_BEFORE free  |  Packages: $PKG_BEFORE"
    printf "\n"

    # ============================================================
    # TASK RUNNER
    # ============================================================

    # APT UPDATE
    if _has_task "update"; then
        _log INFO "Fetching package index..."
        run_with_spinner "apt update" sudo apt update
        if [[ $? -ne 0 ]]; then
            _log ERROR "apt update failed"
            FAILED+=("apt update")
            return 1
        fi
        RAN+=("apt update")

        # Count upgradable
        local upgradable_count
        upgradable_count=$(apt list --upgradable 2>/dev/null | grep -vc "^Listing")
        upgradable_count=$(( upgradable_count + 0 ))

        if [[ $upgradable_count -eq 0 ]]; then
            _log INFO "System is up to date — nothing to upgrade"
        else
            _log INFO "$upgradable_count package(s) available to upgrade:"
            printf "\n"

            # Multi-column side-by-side package list (5 columns)
            local col_width=30 cols=5
            local -a pkgs
            pkgs=("${(@f)$(apt list --upgradable 2>/dev/null | grep '/' | awk -F'/' '{print $1}')}")
            local total_pkgs=${#pkgs[@]}

                printf "  ${W}%-${col_width}s%-${col_width}s%-${col_width}s%-${col_width}s%-${col_width}s${NC}\n" \
                "Package" "Package" "Package" "Package" "Package" | tee -a "$LOG_FILE"
            
             #Print underline matching 5 columns
    local total_width=$((col_width * cols))
    printf "  ${W}%*s${NC}\n" "$total_width" "$(printf '─%.0s' $(seq 1 $total_width))" | tee -a "$LOG_FILE"

                
            local line idx
            for (( i=1; i<=total_pkgs; i+=cols )); do
                line="  "
                for (( idx=i; idx<i+cols && idx<=total_pkgs; idx++ )); do
                    line+=$(printf "${C}%-${col_width}s${NC}" "${pkgs[$idx]}")
                done
                printf "%b\n" "$line" | tee -a "$LOG_FILE"
            done
            printf "\n"
        fi
    else
        SKIPPED+=("apt update")
    fi

    # APT UPGRADE — realtime progress bar
    if _has_task "upgrade"; then
        _log INFO "Upgrading packages..."
        printf "\n"
        run_apt_progress sudo apt upgrade -y
        local upgrade_exit=$?
        printf "\n"
        if [[ $upgrade_exit -ne 0 ]]; then
            _log ERROR "apt upgrade failed"
            _log WARN  "Rollback hint: sudo apt install -f"
            FAILED+=("apt upgrade")
            return 1
        fi
        RAN+=("apt upgrade")
    else
        SKIPPED+=("apt upgrade")
    fi

    # APT AUTOREMOVE
    if _has_task "autoremove"; then
        _log INFO "Removing unused dependencies..."
        run_with_spinner "apt autoremove" sudo apt autoremove -y
        [[ $? -eq 0 ]] && RAN+=("apt autoremove") || FAILED+=("apt autoremove")
    else
        SKIPPED+=("apt autoremove")
    fi

    # APT CLEAN
    if _has_task "clean"; then
        _log INFO "Cleaning package cache..."
        run_with_spinner "apt clean" sudo apt clean
        [[ $? -eq 0 ]] && RAN+=("apt clean") || FAILED+=("apt clean")
    else
        SKIPPED+=("apt clean")
    fi

    # DPKG VERIFY — safe integer handling
    if _has_task "dpkg-verify"; then
        _log INFO "Verifying package integrity — this may take a moment..."
        local verify_tmp
        verify_tmp=$(mktemp)
        sudo dpkg --verify > "$verify_tmp" 2>&1
        local missing_count altered_count
        missing_count=$(( $(grep -c '^missing' "$verify_tmp" 2>/dev/null || echo 0) + 0 ))
        altered_count=$(( $(grep -c '^\?\?' "$verify_tmp" 2>/dev/null || echo 0) + 0 ))
        cat "$verify_tmp" >> "$LOG_FILE"
        rm -f "$verify_tmp"
        if [[ $missing_count -eq 0 && $altered_count -eq 0 ]]; then
            _log INFO "Package integrity OK — no issues found"
            RAN+=("dpkg verify")
        else
            _log WARN "Issues: ${missing_count} missing, ${altered_count} altered"
            _log WARN "Details in: $LOG_FILE"
            FAILED+=("dpkg verify")
        fi
    else
        SKIPPED+=("dpkg verify")
    fi

    # FLATPAK — realtime progress bar
    if _has_task "flatpak"; then
        _log INFO "Updating Flatpak packages..."
        printf "\n"
        run_flatpak_progress
        local flatpak_exit=$?
        printf "\n"
        [[ $flatpak_exit -eq 0 ]] && RAN+=("flatpak update") || FAILED+=("flatpak update")
    else
        SKIPPED+=("flatpak update")
    fi

    # SNAP
    if _has_task "snap"; then
        _log INFO "Refreshing Snap packages..."
        run_with_spinner "snap refresh" sudo snap refresh
        [[ $? -eq 0 ]] && RAN+=("snap refresh") || FAILED+=("snap refresh")
    else
        SKIPPED+=("snap refresh")
    fi

    # FULL UPGRADE — realtime progress bar
    if _has_task "full-upgrade"; then
        _log INFO "Running full-upgrade..."
        printf "\n"
        run_apt_progress sudo apt full-upgrade -y
        local full_exit=$?
        printf "\n"
        if [[ $full_exit -ne 0 ]]; then
            _log ERROR "full-upgrade failed"
            _log WARN  "Rollback hint: sudo apt install -f"
            FAILED+=("full-upgrade")
            return 1
        fi
        RAN+=("full-upgrade")
    fi

    # ============================================================
    # SYSTEM SNAPSHOT — AFTER
    # ============================================================
    local DISK_AFTER PKG_AFTER END_TIME ELAPSED
    DISK_AFTER=$(df -h / | awk 'NR==2 {print $4}')
    PKG_AFTER=$(dpkg -l 2>/dev/null | grep -c '^ii')
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))

    # ============================================================
    # RUN SUMMARY
    # ============================================================
    printf "\n${W}╔══════════════════════════════════════╗${NC}\n"
    printf "${W}║             Run Summary              ║${NC}\n"
    printf "${W}╚══════════════════════════════════════╝${NC}\n\n"
    printf "${G}  ✔  Ran      :${NC} %s\n" "${RAN[*]:-none}"
    printf "${Y}  ⊘  Skipped  :${NC} %s\n" "${SKIPPED[*]:-none}"
    printf "${R}  ✘  Failed   :${NC} %s\n" "${FAILED[*]:-none}"
    printf "\n${C}  Disk free   :${NC} %s → %s\n" "$DISK_BEFORE" "$DISK_AFTER"
    printf "${C}  Packages    :${NC} %s → %s\n" "$PKG_BEFORE" "$PKG_AFTER"
    printf "${C}  Time taken  :${NC} %ss\n" "$ELAPSED"
    printf "${C}  Log saved   :${NC} %s\n\n" "$LOG_FILE"

    _log INFO "==== Completed in ${ELAPSED}s ===="

    if command -v notify-send &>/dev/null && ! $QUIET; then
        if [[ ${#FAILED[@]} -gt 0 ]]; then
            notify-send -u critical "sysmaint" "Errors: ${FAILED[*]}"
        else
            notify-send -u normal "sysmaint" "Done in ${ELAPSED}s"
        fi
    fi
}
#=============================================================================
