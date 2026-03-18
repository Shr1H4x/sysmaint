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
        local level="$1" msg="$2" colour="$NC"
        case "$level" in
            INFO)  colour="$G" ;;
            WARN)  colour="$Y" ;;
            ERROR) colour="$R" ;;
            SKIP)  colour="$B" ;;
            CMD)   colour="$C" ;;
        esac
        local line="[$(date +%H:%M:%S)] [$level] $msg"
        echo -e "${colour}${line}${NC}" | tee -a "$LOG_FILE"
    }

    run_cmd() {
        local -a cmd=("$@")
        if $DRY_RUN; then
            _log CMD "[DRY-RUN] ${cmd[*]}"
            return 0
        fi
        _log CMD "${cmd[*]}"

        local tmp exit_code
        tmp=$(mktemp)

        # Redirect stderr to /dev/null to suppress job control noise
        { "${cmd[@]}" > "$tmp" 2>&1 } 2>/dev/null &
        local cpid=$!

        if ! $QUIET; then
            local -a spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
            local i=0 frame
            while kill -0 "$cpid" 2>/dev/null; do
                frame=${spin[$((i % ${#spin[@]} + 1))]}
                printf "\r  ${C}%s${NC}  Running %s %s..." "$frame" "${cmd[1]}" "${cmd[2]}"
                sleep 0.1
                (( i++ ))
            done
            printf "\r%-60s\r" " "
        fi

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

    # Filter unavailable tasks
    local n=${#TASK_KEYS[@]}
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
        echo -e "\n${W}  Select tasks to run:${NC}\n"
        for (( i=1; i<=total; i++ )); do
            local ans=""
            echo -ne "${Y}  ▶  ${AVAILABLE_LABELS[$i]} (y/n): ${NC}"
            read -r ans
            [[ "$ans" == "y" ]] && SELECTED_TASKS+=("${AVAILABLE_KEYS[$i]}")
        done

    else
        echo -e "\n${W}╔══════════════════════════════════════╗${NC}"
        echo -e "${W}║    sysmaint — System Maintenance     ║${NC}"
        echo -e "${W}╚══════════════════════════════════════╝${NC}\n"
        echo -e "${C}  Select tasks to run (e.g. 1 2 3 or 'all'):${NC}\n"

        for (( i=1; i<=total; i++ )); do
            printf "  ${W}[%d]${NC}  %s\n" "$i" "${AVAILABLE_LABELS[$i]}"
        done

        echo ""
        echo -ne "${Y}  ▶  Enter numbers (space separated) or 'all': ${NC}"
        local selection=""
        read -r selection

        if [[ "$selection" == "all" ]]; then
            SELECTED_TASKS=("${AVAILABLE_KEYS[@]}")
        else
            for num in ${=selection}; do
                if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= total )); then
                    SELECTED_TASKS+=("${AVAILABLE_KEYS[$num]}")
                else
                    echo -e "${R}  Invalid selection: $num — skipped${NC}"
                fi
            done
        fi
    fi

    if [[ ${#SELECTED_TASKS[@]} -eq 0 ]]; then
        echo -e "\n${Y}  No tasks selected. Exiting.${NC}\n"
        return 0
    fi

    # ============================================================
    # CONFIRMATION SUMMARY
    # ============================================================
    echo -e "\n${W}  Tasks queued to run:${NC}\n"
    for task in "${SELECTED_TASKS[@]}"; do
        echo -e "  ${G}✔${NC}  $task"
    done
    echo ""
    echo -ne "${Y}  ▶  Confirm and run? (y/n): ${NC}"
    local confirm_ans=""
    read -r confirm_ans
    if [[ "$confirm_ans" != "y" ]]; then
        echo -e "\n${Y}  Aborted.${NC}\n"
        return 0
    fi

    # ============================================================
    # PRE-FLIGHT CHECKS
    # ============================================================
    if [[ -f "$LOCK_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$LOCK_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo -e "${R}[ERROR] sysmaint is already running (PID $old_pid). Exiting.${NC}"
            return 1
        else
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "/tmp/sysmaint.lock"' EXIT
    trap 'rm -f "/tmp/sysmaint.lock"; echo "Interrupted."' INT TERM

    if ! sudo -n true 2>/dev/null; then
        _log WARN "Sudo requires password. Prompting..."
        sudo true || { _log ERROR "Sudo access denied. Aborting."; return 1; }
    fi

    mkdir -p "$LOG_DIR"
    find "$LOG_DIR" -name "sysmaint-*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null
    _log INFO "Old logs (>${LOG_RETENTION_DAYS}d) cleaned from $LOG_DIR"

    # ============================================================
    # SYSTEM SNAPSHOT — BEFORE
    # ============================================================
    START_TIME=$(date +%s)
    DISK_BEFORE=$(df -h / | awk 'NR==2 {print $4}')
    PKG_BEFORE=$(dpkg -l 2>/dev/null | grep -c '^ii')

    echo -e "\n${W}╔══════════════════════════════════════╗${NC}"
    echo -e "${W}║             Running Tasks            ║${NC}"
    echo -e "${W}╚══════════════════════════════════════╝${NC}\n"
    _log INFO "Started at $(date)"
    _log INFO "Log file : $LOG_FILE"
    _log INFO "Disk free: $DISK_BEFORE  |  Packages installed: $PKG_BEFORE"
    echo ""

    # ============================================================
    # TASK RUNNER
    # ============================================================

    # APT UPDATE
    if _has_task "update"; then
        _log INFO "Fetching package index..."
        run_cmd sudo apt update
        if [[ $? -ne 0 ]]; then
            _log ERROR "apt update failed"
            FAILED+=("apt update")
            return 1
        fi
        RAN+=("apt update")

        # List upgradable — suppress 'Listing...' line, parse cleanly
        local upgradable_list upgradable_count
        upgradable_list=$(apt list --upgradable 2>/dev/null | grep -v "^Listing" | grep '/')
        upgradable_count=$(echo "$upgradable_list" | grep -c '.' 2>/dev/null)

        if [[ $upgradable_count -eq 0 ]]; then
            _log INFO "System is up to date — nothing to upgrade"
        else
            _log INFO "$upgradable_count package(s) available to upgrade:"
            echo ""
            printf "  ${W}%-35s %s${NC}\n" "Package" "Version" | tee -a "$LOG_FILE"
            echo -e "${W}  ─────────────────────────────────────────────${NC}" | tee -a "$LOG_FILE"
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local pkg ver
                pkg=$(echo "$line" | awk -F'/' '{print $1}')
                ver=$(echo "$line" | awk '{print $2}')
                printf "  ${C}%-35s${NC} ${G}%s${NC}\n" "$pkg" "$ver" | tee -a "$LOG_FILE"
            done <<< "$upgradable_list"
            echo ""
        fi
    else
        _has_task "update" || SKIPPED+=("apt update")
    fi

    # APT UPGRADE
    if _has_task "upgrade"; then
        _log INFO "Upgrading packages..."
        run_cmd sudo apt upgrade -y
        if [[ $? -ne 0 ]]; then
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
        run_cmd sudo apt autoremove -y
        [[ $? -eq 0 ]] && RAN+=("apt autoremove") || FAILED+=("apt autoremove")
    else
        SKIPPED+=("apt autoremove")
    fi

    # APT CLEAN
    if _has_task "clean"; then
        run_cmd sudo apt clean
        [[ $? -eq 0 ]] && RAN+=("apt clean") || FAILED+=("apt clean")
    else
        SKIPPED+=("apt clean")
    fi

    # DPKG VERIFY — smart output parsing
    if _has_task "dpkg-verify"; then
        _log INFO "Verifying package integrity, This may take some time..."
        local verify_tmp verify_out
        verify_tmp=$(mktemp)
        sudo dpkg --verify > "$verify_tmp" 2>&1

        verify_out=$(cat "$verify_tmp")
        local missing_count altered_count
        missing_count=$(grep -c '^missing' "$verify_tmp" 2>/dev/null || echo 0)
        altered_count=$(grep -c '^\?\?' "$verify_tmp" 2>/dev/null || echo 0)

        # Log full output to file only
        cat "$verify_tmp" >> "$LOG_FILE"
        rm -f "$verify_tmp"

        if [[ $missing_count -eq 0 && $altered_count -eq 0 ]]; then
            _log INFO "Package integrity OK — no issues found"
            RAN+=("dpkg verify")
        else
            _log WARN "Integrity issues found: ${missing_count} missing, ${altered_count} altered files"
            _log WARN "Full details saved to log: $LOG_FILE"
            FAILED+=("dpkg verify")
        fi
    else
        SKIPPED+=("dpkg verify")
    fi

    # FLATPAK
    if _has_task "flatpak"; then
        run_cmd flatpak update -y
        [[ $? -eq 0 ]] && RAN+=("flatpak update") || FAILED+=("flatpak update")
    else
        SKIPPED+=("flatpak update")
    fi

    # SNAP
    if _has_task "snap"; then
        run_cmd sudo snap refresh
        [[ $? -eq 0 ]] && RAN+=("snap refresh") || FAILED+=("snap refresh")
    else
        SKIPPED+=("snap refresh")
    fi

    # FULL UPGRADE
    if _has_task "full-upgrade"; then
        run_cmd sudo apt full-upgrade -y
        if [[ $? -ne 0 ]]; then
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
    echo ""
    echo -e "${W}╔══════════════════════════════════════╗${NC}"
    echo -e "${W}║             Run Summary              ║${NC}"
    echo -e "${W}╚══════════════════════════════════════╝${NC}"
    echo -e "\n${G}  ✔  Ran      :${NC} ${RAN[*]:-none}"
    echo -e "${Y}  ⊘  Skipped  :${NC} ${SKIPPED[*]:-none}"
    echo -e "${R}  ✘  Failed   :${NC} ${FAILED[*]:-none}"
    echo -e "\n${C}  Disk free   :${NC} $DISK_BEFORE → $DISK_AFTER"
    echo -e "${C}  Packages    :${NC} $PKG_BEFORE → $PKG_AFTER"
    echo -e "${C}  Time taken  :${NC} ${ELAPSED}s"
    echo -e "${C}  Log saved   :${NC} $LOG_FILE\n"

    _log INFO "==== Completed in ${ELAPSED}s ===="

    if command -v notify-send &>/dev/null && ! $QUIET; then
        if [[ ${#FAILED[@]} -gt 0 ]]; then
            notify-send -u critical "sysmaint" "Completed with errors: ${FAILED[*]}"
        else
            notify-send -u normal "sysmaint" "All tasks completed in ${ELAPSED}s"
        fi
    fi
}
#=============================================================================

