#!/bin/bash
# Mole - Common Functions Library
# Shared utilities and functions for all modules

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_COMMON_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_COMMON_LOADED=1

# Color definitions (readonly for safety)
readonly ESC=$'\033'
readonly GREEN="${ESC}[0;32m"
readonly BLUE="${ESC}[0;34m"
readonly CYAN="${ESC}[0;36m"
readonly YELLOW="${ESC}[0;33m"
readonly PURPLE="${ESC}[0;35m"
readonly PURPLE_BOLD="${ESC}[1;35m"
readonly RED="${ESC}[0;31m"
readonly GRAY="${ESC}[0;90m"
readonly NC="${ESC}[0m"

# Icon definitions
readonly ICON_CONFIRM="◎"
readonly ICON_ADMIN="⚙"
readonly ICON_SUCCESS="✓"
readonly ICON_ERROR="☻"
readonly ICON_EMPTY="○"
readonly ICON_SOLID="●"
readonly ICON_LIST="•"
readonly ICON_ARROW="➤"
readonly ICON_WARNING="☻"
readonly ICON_NAV_UP="↑"
readonly ICON_NAV_DOWN="↓"
readonly ICON_NAV_LEFT="←"
readonly ICON_NAV_RIGHT="→"

# Global configuration constants
readonly MOLE_TEMP_FILE_AGE_DAYS=7       # Temp file cleanup threshold
readonly MOLE_ORPHAN_AGE_DAYS=60         # Orphaned data threshold
readonly MOLE_MAX_PARALLEL_JOBS=15       # Parallel job limit
readonly MOLE_MAIL_DOWNLOADS_MIN_KB=5120 # Mail attachments size threshold (~5MB)
readonly MOLE_LOG_AGE_DAYS=30            # System log retention
readonly MOLE_CRASH_REPORT_AGE_DAYS=30   # Crash report retention
readonly MOLE_SAVED_STATE_AGE_DAYS=7     # App saved state retention
readonly MOLE_TM_BACKUP_SAFE_HOURS=48    # Time Machine failed backup safety window

# Whitelist configuration
readonly FINDER_METADATA_SENTINEL="FINDER_METADATA"
declare -a DEFAULT_WHITELIST_PATTERNS=(
    "$HOME/Library/Caches/ms-playwright*"
    "$HOME/.cache/huggingface*"
    "$HOME/.m2/repository/*"
    "$HOME/.ollama/models/*"
    "$HOME/Library/Caches/com.nssurge.surge-mac/*"
    "$HOME/Library/Application Support/com.nssurge.surge-mac/*"
    "$HOME/Library/Caches/org.R-project.R/R/renv/*"
    "$FINDER_METADATA_SENTINEL"
)

# Check if System Integrity Protection is enabled
# Returns: 0 if SIP is enabled, 1 if disabled or cannot determine
is_sip_enabled() {
    if ! command -v csrutil > /dev/null 2>&1; then
        # If csrutil not available, assume SIP is enabled for safety
        return 0
    fi

    local sip_status
    sip_status=$(csrutil status 2> /dev/null || echo "")

    if echo "$sip_status" | grep -qi "enabled"; then
        return 0
    else
        return 1
    fi
}

# Check if running in interactive terminal
# Returns: 0 if interactive (stdout is a terminal), 1 otherwise
# Usage: if is_interactive; then echo "Interactive mode"; fi
is_interactive() {
    [[ -t 1 ]]
}

# Get spinner characters (overridable via MO_SPINNER_CHARS)
mo_spinner_chars() {
    local chars="${MO_SPINNER_CHARS:-|/-\\}"
    [[ -z "$chars" ]] && chars="|/-\\"
    printf "%s" "$chars"
}

# BSD stat compatibility
readonly STAT_BSD="/usr/bin/stat"

# Get file size in bytes using BSD stat
get_file_size() {
    local file="$1"
    local result
    result=$($STAT_BSD -f%z "$file" 2> /dev/null)
    echo "${result:-0}"
}

# Get file modification time (epoch seconds) using BSD stat
get_file_mtime() {
    local file="$1"
    [[ -z "$file" ]] && { echo "0"; return; }
    local result
    result=$($STAT_BSD -f%m "$file" 2> /dev/null)
    echo "${result:-0}"
}

# Get file owner username using BSD stat
get_file_owner() {
    local file="$1"
    $STAT_BSD -f%Su "$file" 2> /dev/null || echo ""
}

# Security and Path Validation Functions

# Validates path for deletion (absolute, no control chars, not system dir)
validate_path_for_deletion() {
    local path="$1"

    # Check path is not empty
    if [[ -z "$path" ]]; then
        log_error "Path validation failed: empty path"
        return 1
    fi

    # Check path is absolute
    if [[ "$path" != /* ]]; then
        log_error "Path validation failed: path must be absolute: $path"
        return 1
    fi

    # Check for path traversal attempts
    if [[ "$path" =~ \.\. ]]; then
        log_error "Path validation failed: path traversal not allowed: $path"
        return 1
    fi

    # Check path doesn't contain dangerous characters
    if [[ "$path" =~ [[:cntrl:]] ]] || [[ "$path" =~ $'\n' ]]; then
        log_error "Path validation failed: contains control characters: $path"
        return 1
    fi

    # Check path isn't critical system directory
    case "$path" in
        / | /bin | /sbin | /usr | /usr/bin | /usr/sbin | /etc | /var | /System | /System/* | /Library/Extensions)
            log_error "Path validation failed: critical system directory: $path"
            return 1
            ;;
    esac

    # Path is safe
    return 0
}

# Safe wrapper around rm -rf with path validation and logging
# Usage: safe_remove "/path" [silent]
safe_remove() {
    local path="$1"
    local silent="${2:-false}"

    # Validate path
    if ! validate_path_for_deletion "$path"; then
        return 1
    fi

    # Check if path exists
    if [[ ! -e "$path" ]]; then
        return 0
    fi

    # Perform the deletion (log only on error)
    if rm -rf "$path" 2> /dev/null; then
        return 0
    else
        [[ "$silent" != "true" ]] && log_error "Failed to remove: $path"
        return 1
    fi
}

# Safe sudo remove with validation (rejects symlinks)
# Usage: safe_sudo_remove "/path"
safe_sudo_remove() {
    local path="$1"

    # Validate path
    if ! validate_path_for_deletion "$path"; then
        log_error "Path validation failed for sudo remove: $path"
        return 1
    fi

    # Check if path exists
    if [[ ! -e "$path" ]]; then
        return 0
    fi

    # Additional check: reject symlinks for sudo operations
    if [[ -L "$path" ]]; then
        log_error "Refusing to sudo remove symlink: $path"
        return 1
    fi

    # Perform the deletion (log only on error)
    if sudo rm -rf "$path" 2> /dev/null; then
        return 0
    else
        log_error "Failed to remove (sudo): $path"
        return 1
    fi
}

# Safe find delete with depth limit and validation
# Usage: safe_find_delete "/dir" "pattern" age_days "f|d"
safe_find_delete() {
    local base_dir="$1"
    local pattern="$2"
    local age_days="${3:-7}"
    local type_filter="${4:-f}"

    # Validate base directory exists and is not a symlink
    if [[ ! -d "$base_dir" ]]; then
        log_error "Directory does not exist: $base_dir"
        return 1
    fi

    if [[ -L "$base_dir" ]]; then
        log_error "Refusing to search symlinked directory: $base_dir"
        return 1
    fi

    # Validate type filter
    if [[ "$type_filter" != "f" && "$type_filter" != "d" ]]; then
        log_error "Invalid type filter: $type_filter (must be 'f' or 'd')"
        return 1
    fi

    # Execute find with safety limits
    command find "$base_dir" \
        -maxdepth 3 \
        -name "$pattern" \
        -type "$type_filter" \
        -mtime "+$age_days" \
        -delete 2> /dev/null || true

    return 0
}

# Safe sudo find delete (same as safe_find_delete with sudo)
# Usage: safe_sudo_find_delete "/dir" "pattern" age_days "f|d"
safe_sudo_find_delete() {
    local base_dir="$1"
    local pattern="$2"
    local age_days="${3:-7}"
    local type_filter="${4:-f}"

    # Validate base directory exists and is not a symlink
    if [[ ! -d "$base_dir" ]]; then
        log_error "Directory does not exist: $base_dir"
        return 1
    fi

    if [[ -L "$base_dir" ]]; then
        log_error "Refusing to search symlinked directory: $base_dir"
        return 1
    fi

    # Validate type filter
    if [[ "$type_filter" != "f" && "$type_filter" != "d" ]]; then
        log_error "Invalid type filter: $type_filter (must be 'f' or 'd')"
        return 1
    fi

    # Execute find with safety limits
    sudo command find "$base_dir" \
        -maxdepth 3 \
        -name "$pattern" \
        -type "$type_filter" \
        -mtime "+$age_days" \
        -delete 2> /dev/null || true

    return 0
}

# Logging configuration
readonly LOG_FILE="${HOME}/.config/mole/mole.log"
readonly LOG_MAX_SIZE_DEFAULT=1048576 # 1MB

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")" 2> /dev/null || true

# Log rotation check (called once at startup, not per log entry)
rotate_log_once() {
    # Skip if already checked this session
    [[ -n "${MOLE_LOG_ROTATED:-}" ]] && return 0
    export MOLE_LOG_ROTATED=1

    local max_size="${MOLE_MAX_LOG_SIZE:-$LOG_MAX_SIZE_DEFAULT}"
    if [[ -f "$LOG_FILE" ]] && [[ $(get_file_size "$LOG_FILE") -gt "$max_size" ]]; then
        mv "$LOG_FILE" "${LOG_FILE}.old" 2> /dev/null || true
        touch "$LOG_FILE" 2> /dev/null || true
    fi
}

# Simplified logging functions (no per-call rotation check)
log_info() {
    echo -e "${BLUE}$1${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1" >> "$LOG_FILE" 2> /dev/null || true
}

log_success() {
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $1" >> "$LOG_FILE" 2> /dev/null || true
}

log_warning() {
    echo -e "${YELLOW}$1${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1" >> "$LOG_FILE" 2> /dev/null || true
}

log_error() {
    echo -e "${RED}${ICON_ERROR}${NC} $1" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE" 2> /dev/null || true
}

# Debug logging - only shown when MO_DEBUG=1
debug_log() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        echo -e "${GRAY}[DEBUG]${NC} $*" >&2
    fi
}

# Run command with optional error handling
# Usage: run_silent command args...  # Ignore errors
#        run_logged command args...  # Log errors but continue
run_silent() {
    "$@" > /dev/null 2>&1 || true
}

run_logged() {
    local cmd="$1"
    if ! "$@" 2>&1 | tee -a "$LOG_FILE" > /dev/null; then
        log_warning "Command failed: $cmd"
        return 1
    fi
    return 0
}

# Call rotation check once when common.sh is sourced
rotate_log_once

# Print formatted summary block with heading and details
# Args: $1=status (ignored), $2=heading, $@=details
print_summary_block() {
    local heading=""

    if [[ $# -gt 0 ]]; then
        shift
    fi

    if [[ $# -gt 0 ]]; then
        heading="$1"
        shift
    fi

    local -a details=("$@")
    local divider="======================================================================"

    echo "$divider"
    if [[ -n "$heading" ]]; then
        echo -e "${BLUE}${heading}${NC}"
    fi
    for detail in "${details[@]}"; do
        [[ -z "$detail" ]] && continue
        echo -e "${detail}"
    done
    echo "$divider"
}

# Detect CPU architecture (Apple Silicon or Intel)
detect_architecture() {
    if [[ "$(uname -m)" == "arm64" ]]; then
        echo "Apple Silicon"
    else
        echo "Intel"
    fi
}

# Get free disk space on root volume (human-readable)
get_free_space() {
    command df -h / | awk 'NR==2 {print $4}'
}

# Clear terminal screen and move cursor to home
clear_screen() {
    printf '\033[2J\033[H'
}

# Hide terminal cursor
hide_cursor() {
    [[ -t 1 ]] || return 0
    # Output to stderr for consistency with spinner, ensure unbuffered
    printf '\033[?25l' >&2
}

# Show terminal cursor
show_cursor() {
    [[ -t 1 ]] || return 0
    # Output to stderr for consistency with spinner, ensure unbuffered
    printf '\033[?25h' >&2
}

# Read single keypress and return normalized key name
# Returns: ENTER, SPACE, UP, DOWN, LEFT, RIGHT, QUIT, DELETE, CHAR:<c>
read_key() {
    local key rest read_status

    # Read with explicit status check
    IFS= read -r -s -n 1 key
    read_status=$?

    # Handle read failure (Ctrl+D, EOF, etc.) - treat as quit
    if [[ $read_status -ne 0 ]]; then
        echo "QUIT"
        return 0
    fi

    # Raw typing mode (filter): map most keys to CHAR:<key>
    if [[ "${MOLE_READ_KEY_FORCE_CHAR:-}" == "1" ]]; then
        if [[ -z "$key" ]]; then
            echo "ENTER"
            return 0
        fi
        case "$key" in
            $'\n' | $'\r') echo "ENTER" ;;
            $'\x7f' | $'\x08') echo "DELETE" ;;
            $'\x1b') echo "QUIT" ;; # ESC cancels filter
            [[:print:]]) echo "CHAR:$key" ;;
            *) echo "OTHER" ;;
        esac
        return 0
    fi

    # Empty key = Enter
    if [[ -z "$key" ]]; then
        echo "ENTER"
        return 0
    fi

    case "$key" in
        $'\n' | $'\r') echo "ENTER" ;;
        ' ') echo "SPACE" ;;
        'q' | 'Q') echo "QUIT" ;;
        'h') echo "LEFT" ;;
        'j') echo "DOWN" ;;
        'k') echo "UP" ;;
        'l') echo "RIGHT" ;;
        'm' | 'M') echo "MORE" ;;
        'v' | 'V') echo "VERSION" ;;
        't' | 'T') echo "TOUCHID" ;;
        'u' | 'U') echo "UPDATE" ;;
        'R') echo "RETRY" ;;
        'o' | 'O') echo "OPEN" ;;
        '/') echo "FILTER" ;;
        $'\x03') echo "QUIT" ;; # Ctrl+C
        $'\x7f' | $'\x08') echo "DELETE" ;;
        $'\x1b')
            # ESC sequence - could be arrow key, delete key, or ESC alone
            if IFS= read -r -s -n 1 -t 1 rest 2> /dev/null; then
                if [[ "$rest" == "[" ]]; then
                    # ESC [ sequence
                    if IFS= read -r -s -n 1 -t 1 rest2 2> /dev/null; then
                        case "$rest2" in
                            "A") echo "UP" ;;
                            "B") echo "DOWN" ;;
                            "C") echo "RIGHT" ;;
                            "D") echo "LEFT" ;;
                            "3")
                                # Delete key: ESC [ 3 ~
                                IFS= read -r -s -n 1 -t 1 rest3 2> /dev/null
                                [[ "$rest3" == "~" ]] && echo "DELETE" || echo "OTHER"
                                ;;
                            *) echo "OTHER" ;;
                        esac
                    else
                        echo "QUIT"
                    fi
                elif [[ "$rest" == "O" ]]; then
                    # ESC O sequence (application keypad mode)
                    if IFS= read -r -s -n 1 -t 1 rest2 2> /dev/null; then
                        case "$rest2" in
                            "A") echo "UP" ;;
                            "B") echo "DOWN" ;;
                            "C") echo "RIGHT" ;;
                            "D") echo "LEFT" ;;
                            *) echo "OTHER" ;;
                        esac
                    else
                        echo "OTHER"
                    fi
                else
                    echo "OTHER"
                fi
            else
                # ESC alone
                echo "QUIT"
            fi
            ;;
        [[:print:]]) echo "CHAR:$key" ;;
        *) echo "OTHER" ;;
    esac
}

# Drain pending keyboard/mouse input to prevent accidental triggers
drain_pending_input() {
    local drained=0
    # Single pass with 0.01s timeout is sufficient for mouse wheel events
    while IFS= read -r -s -n 1 -t 0.01 _ 2> /dev/null; do
        ((drained++))
        [[ $drained -gt 100 ]] && break
    done
}

# Initialize timeout command (gtimeout or timeout)
if [[ -z "${MO_TIMEOUT_INITIALIZED:-}" ]]; then
    MO_TIMEOUT_BIN=""
    for candidate in gtimeout timeout; do
        if command -v "$candidate" > /dev/null 2>&1; then
            MO_TIMEOUT_BIN="$candidate"
            break
        fi
    done
    export MO_TIMEOUT_INITIALIZED=1
fi

# Run command with timeout (uses gtimeout/timeout if available, fallback to kill)
# Args: $1=seconds, $@=command
run_with_timeout() {
    local duration="${1:-0}"
    shift || true

    if [[ ! "$duration" =~ ^[0-9]+$ ]]; then
        duration=0
    fi

    if [[ "$duration" -le 0 ]]; then
        "$@"
        return $?
    fi

    if [[ -n "${MO_TIMEOUT_BIN:-}" ]]; then
        "$MO_TIMEOUT_BIN" "$duration" "$@"
        return $?
    fi

    "$@" &
    local cmd_pid=$!

    # More efficient wait: use wait with timeout in subshell
    (
        sleep "$duration" &
        local timer_pid=$!
        wait "$cmd_pid" 2> /dev/null && kill "$timer_pid" 2> /dev/null && exit 0
        kill -TERM "$cmd_pid" 2> /dev/null || true
        sleep 0.5
        kill -KILL "$cmd_pid" 2> /dev/null || true
        exit 124
    ) &
    local watcher_pid=$!

    wait "$cmd_pid" 2> /dev/null
    local exit_code=$?
    kill "$watcher_pid" 2> /dev/null || true
    wait "$watcher_pid" 2> /dev/null || true
    return $exit_code
}

# Menu display helper
show_menu_option() {
    local number="$1"
    local text="$2"
    local selected="$3"

    if [[ "$selected" == "true" ]]; then
        echo -e "${CYAN}${ICON_ARROW} $number. $text${NC}"
    else
        echo "  $number. $text"
    fi
}

# Error handling
# File size utilities
# Convert bytes to human readable format
bytes_to_human() {
    local bytes="$1"
    if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then
        echo "0B"
        return 1
    fi

    if ((bytes >= 1073741824)); then # >= 1GB
        local divisor=1073741824
        local whole=$((bytes / divisor))
        local remainder=$((bytes % divisor))
        local frac=$(((remainder * 100 + divisor / 2) / divisor)) # Two decimals, rounded
        if ((frac >= 100)); then
            frac=0
            ((whole++))
        fi
        printf "%d.%02dGB\n" "$whole" "$frac"
        return 0
    fi

    if ((bytes >= 1048576)); then # >= 1MB
        local divisor=1048576
        local whole=$((bytes / divisor))
        local remainder=$((bytes % divisor))
        local frac=$(((remainder * 10 + divisor / 2) / divisor)) # One decimal, rounded
        if ((frac >= 10)); then
            frac=0
            ((whole++))
        fi
        printf "%d.%01dMB\n" "$whole" "$frac"
        return 0
    fi

    if ((bytes >= 1024)); then                     # >= 1KB
        local rounded_kb=$(((bytes + 512) / 1024)) # Nearest integer KB
        printf "%dKB\n" "$rounded_kb"
        return 0
    fi

    printf "%dB\n" "$bytes"
}

# Calculate directory size in bytes
# List login items (one per line)
list_login_items() {
    if ! command -v osascript > /dev/null 2>&1; then
        return
    fi

    local raw_items
    raw_items=$(osascript -e 'tell application "System Events" to get the name of every login item' 2> /dev/null || echo "")
    [[ -z "$raw_items" || "$raw_items" == "missing value" ]] && return

    IFS=',' read -ra login_items_array <<< "$raw_items"
    for entry in "${login_items_array[@]}"; do
        local trimmed
        trimmed=$(echo "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [[ -n "$trimmed" ]] && printf "%s\n" "$trimmed"
    done
}

# Permission checks
# Check if Touch ID is configured for sudo
check_touchid_support() {
    if [[ -f /etc/pam.d/sudo ]]; then
        grep -q "pam_tid.so" /etc/pam.d/sudo 2> /dev/null
        return $?
    fi
    return 1
}

# Check if Mac is in clamshell mode (lid closed with external display)
is_clamshell_mode() {
    # ioreg is missing (not macOS) -> treat as lid open
    if ! command -v ioreg > /dev/null 2>&1; then
        return 1
    fi

    # Check if lid is closed; ignore pipeline failures so set -e doesn't exit
    local clamshell_state=""
    clamshell_state=$( (ioreg -r -k AppleClamshellState -d 4 2> /dev/null |
        grep "AppleClamshellState" |
        head -1) || true)

    if [[ "$clamshell_state" =~ \"AppleClamshellState\"\ =\ Yes ]]; then
        return 0 # Lid is closed
    fi
    return 1 # Lid is open
}

# Manual password input (no Touch ID)
_request_password() {
    local tty_path="$1"
    local attempts=0
    local show_hint=true

    # Extra safety: ensure sudo cache is cleared before password input
    sudo -k 2> /dev/null

    while ((attempts < 3)); do
        local password=""

        # Show hint on first attempt about Touch ID appearing again
        if [[ $show_hint == true ]] && check_touchid_support; then
            echo -e "${GRAY}Note: Touch ID dialog may appear once more - just cancel it${NC}" > "$tty_path"
            show_hint=false
        fi

        printf "${PURPLE}${ICON_ARROW}${NC} Password: " > "$tty_path"
        IFS= read -r -s password < "$tty_path" || password=""
        printf "\n" > "$tty_path"

        if [[ -z "$password" ]]; then
            unset password
            ((attempts++))
            if [[ $attempts -lt 3 ]]; then
                echo -e "${YELLOW}${ICON_WARNING}${NC} Password cannot be empty" > "$tty_path"
            fi
            continue
        fi

        # Verify password with sudo
        # NOTE: macOS PAM will trigger Touch ID before password auth - this is system behavior
        if printf '%s\n' "$password" | sudo -S -p "" -v > /dev/null 2>&1; then
            unset password
            return 0
        fi

        unset password
        ((attempts++))
        if [[ $attempts -lt 3 ]]; then
            echo -e "${YELLOW}${ICON_WARNING}${NC} Incorrect password, try again" > "$tty_path"
        fi
    done

    return 1
}

# Request sudo access with Touch ID support
# Usage: request_sudo_access "prompt message"
request_sudo_access() {
    local prompt_msg="${1:-Admin access required}"

    # Check if already have sudo access
    if sudo -n true 2> /dev/null; then
        return 0
    fi

    # Get TTY path
    local tty_path="/dev/tty"
    if [[ ! -r "$tty_path" || ! -w "$tty_path" ]]; then
        tty_path=$(tty 2> /dev/null || echo "")
        if [[ -z "$tty_path" || ! -r "$tty_path" || ! -w "$tty_path" ]]; then
            log_error "No interactive terminal available"
            return 1
        fi
    fi

    sudo -k

    # Check if in clamshell mode - if yes, skip Touch ID entirely
    if is_clamshell_mode; then
        echo -e "${PURPLE}${ICON_ARROW}${NC} ${prompt_msg}"
        _request_password "$tty_path"
        return $?
    fi

    # Not in clamshell mode - try Touch ID if configured
    if ! check_touchid_support; then
        echo -e "${PURPLE}${ICON_ARROW}${NC} ${prompt_msg}"
        _request_password "$tty_path"
        return $?
    fi

    # Touch ID is available and not in clamshell mode
    echo -e "${PURPLE}${ICON_ARROW}${NC} ${prompt_msg} ${GRAY}(Touch ID or password)${NC}"

    # Start sudo in background so we can monitor and control it
    sudo -v < /dev/null > /dev/null 2>&1 &
    local sudo_pid=$!

    # Wait for sudo to complete or timeout (5 seconds)
    local elapsed=0
    local timeout=50 # 50 * 0.1s = 5 seconds
    while ((elapsed < timeout)); do
        if ! kill -0 "$sudo_pid" 2> /dev/null; then
            # Process exited
            wait "$sudo_pid" 2> /dev/null
            local exit_code=$?
            if [[ $exit_code -eq 0 ]] && sudo -n true 2> /dev/null; then
                # Touch ID succeeded
                return 0
            fi
            # Touch ID failed or cancelled
            break
        fi
        sleep 0.1
        ((elapsed++))
    done

    # Touch ID failed/cancelled - clean up thoroughly before password input

    # Kill the sudo process if still running
    if kill -0 "$sudo_pid" 2> /dev/null; then
        kill -9 "$sudo_pid" 2> /dev/null
        wait "$sudo_pid" 2> /dev/null || true
    fi

    # Clear sudo state immediately
    sudo -k 2> /dev/null

    # IMPORTANT: Wait longer for macOS to fully close Touch ID UI and SecurityAgent
    # Without this delay, subsequent sudo calls may re-trigger Touch ID
    sleep 1

    # Clear any leftover prompts on the screen
    printf "\r\033[2K" > "$tty_path"

    # Now use our password input (this should not trigger Touch ID again)
    _request_password "$tty_path"
    return $?
}

# Legacy sudo request (no Touch ID, password only)
request_sudo() {
    echo "This operation requires administrator privileges."
    echo -n "Please enter your password: "
    read -r -s password
    echo
    if echo "$password" | sudo -S true 2> /dev/null; then
        return 0
    else
        log_error "Invalid password or cancelled"
        return 1
    fi
}

# Update Mole via Homebrew with timeout and error handling
# Args: $1=current_version, Env: MO_BREW_UPDATE_TIMEOUT
update_via_homebrew() {
    local version="${1:-unknown}"

    # Set up cleanup trap to kill background process on interruption
    local brew_pid=""
    local brew_tmp_file=""
    local brew_exit_file=""
    # shellcheck disable=SC2329
    cleanup_brew_update() {
        if [[ -n "$brew_pid" ]] && kill -0 "$brew_pid" 2> /dev/null; then
            kill -TERM "$brew_pid" 2> /dev/null || true
            wait "$brew_pid" 2> /dev/null || true
        fi
        [[ -n "$brew_tmp_file" ]] && rm -f "$brew_tmp_file"
        [[ -n "$brew_exit_file" ]] && rm -f "$brew_exit_file"
        [[ -t 1 ]] && stop_inline_spinner
    }
    trap cleanup_brew_update INT TERM

    if [[ -t 1 ]]; then
        start_inline_spinner "Updating Homebrew..."
    else
        echo "Updating Homebrew..." >&2
    fi

    # Run brew update with timeout to prevent hanging
    # Use background process to allow interruption
    local brew_update_timeout="${MO_BREW_UPDATE_TIMEOUT:-300}"
    brew_tmp_file=$(mktemp -t mole-brew-update 2> /dev/null || echo "/tmp/mole-brew-update.$$")

    # Redirect brew output to temp file to avoid interfering with spinner
    # Store exit code in a separate file to avoid wait issues with zsh
    brew_exit_file="${brew_tmp_file}.exit"
    (
        brew update > "$brew_tmp_file" 2>&1 < /dev/null
        echo $? > "$brew_exit_file"
    ) &
    brew_pid=$!
    local elapsed=0

    # Wait for completion or timeout
    while kill -0 $brew_pid 2> /dev/null; do
        if [[ $elapsed -ge $brew_update_timeout ]]; then
            kill -TERM $brew_pid 2> /dev/null || true
            sleep 0.5
            if [[ -t 1 ]]; then stop_inline_spinner; fi
            rm -f "$brew_tmp_file" "$brew_exit_file"
            trap - INT TERM
            log_error "Homebrew update timed out (${brew_update_timeout}s)"
            return 1
        fi
        sleep 1
        ((elapsed++))
    done

    # Give the subshell a moment to write exit code
    sleep 0.1

    trap - INT TERM

    # Get brew update exit code from file instead of wait
    local brew_exit=0
    if [[ -f "$brew_exit_file" ]]; then
        brew_exit=$(cat "$brew_exit_file" 2> /dev/null || echo "0")
    fi
    rm -f "$brew_exit_file"

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    # Check if update failed with a real error (not just "already up-to-date")
    local brew_update_success=true
    local update_output=""

    if [[ -f "$brew_tmp_file" ]]; then
        update_output=$(cat "$brew_tmp_file" 2> /dev/null)
    fi

    # Check for errors in output (brew update may return 0 even on failure)
    if [[ -n "$update_output" ]] && echo "$update_output" | grep -qiE "(^Error:|fatal:)"; then
        brew_update_success=false
    fi

    if [[ $brew_exit -ne 0 ]]; then
        brew_update_success=false
    fi

    # Show appropriate message
    if [[ "$brew_update_success" == "false" ]]; then
        echo -e "${YELLOW}${ICON_WARNING}${NC} Homebrew update skipped (check network or proxy)" >&2
    else
        # Only show success if there were no errors
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Homebrew formulae updated" >&2
    fi

    rm -f "$brew_tmp_file"

    if [[ -t 1 ]]; then
        start_inline_spinner "Upgrading Mole..."
    else
        echo "Upgrading Mole..." >&2
    fi
    local upgrade_output
    upgrade_output=$(brew upgrade mole 2>&1) || true
    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    if echo "$upgrade_output" | grep -q "already installed"; then
        # Get current version
        local current_version
        current_version=$(brew list --versions mole 2> /dev/null | awk '{print $2}')
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Already on latest version (${current_version:-$version})" >&2
    elif echo "$upgrade_output" | grep -q "Error:"; then
        log_error "Homebrew upgrade failed"
        echo "$upgrade_output" | grep "Error:" >&2
        return 1
    else
        # Show relevant output, filter noise
        echo "$upgrade_output" | grep -Ev "^(==>|Updating Homebrew|Warning:)" >&2 || true
        # Get new version
        local new_version
        new_version=$(brew list --versions mole 2> /dev/null | awk '{print $2}')
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Updated to latest version (${new_version:-$version})" >&2
    fi

    # Clear version check cache
    rm -f "$HOME/.cache/mole/update_message"
    return 0
}

# Load basic configuration
load_config() {
    MOLE_MAX_LOG_SIZE="${MOLE_MAX_LOG_SIZE:-1048576}"
}

# Initialize configuration on sourcing
load_config

# ============================================================================
# Spinner and Progress Indicators
# ============================================================================

# Global spinner process ID
INLINE_SPINNER_PID=""

# Start an inline spinner (rotating character)
start_inline_spinner() {
    stop_inline_spinner 2> /dev/null || true
    local message="$1"

    if [[ -t 1 ]]; then
        (
            trap 'exit 0' TERM INT EXIT
            local chars
            chars="$(mo_spinner_chars)"
            [[ -z "$chars" ]] && chars="|/-\\"
            local i=0
            while true; do
                local c="${chars:$((i % ${#chars})):1}"
                # Output to stderr to avoid interfering with stdout
                printf "\r${MOLE_SPINNER_PREFIX:-}${BLUE}%s${NC} %s" "$c" "$message" >&2 || exit 0
                ((i++))
                # macOS supports decimal sleep, this is the primary target
                sleep 0.1 2> /dev/null || sleep 1 2> /dev/null || exit 0
            done
        ) &
        INLINE_SPINNER_PID=$!
        disown 2> /dev/null || true
    else
        echo -n "  ${BLUE}|${NC} $message" >&2
    fi
}

# Stop inline spinner
stop_inline_spinner() {
    if [[ -n "$INLINE_SPINNER_PID" ]]; then
        # Try graceful TERM first, then force KILL if needed
        if kill -0 "$INLINE_SPINNER_PID" 2> /dev/null; then
            kill -TERM "$INLINE_SPINNER_PID" 2> /dev/null || true
            sleep 0.05 2> /dev/null || true
            # Force kill if still running
            kill -KILL "$INLINE_SPINNER_PID" 2> /dev/null || true
        fi
        wait "$INLINE_SPINNER_PID" 2> /dev/null || true
        INLINE_SPINNER_PID=""
        # Clear the line - use \033[2K to clear entire line, not just to end
        [[ -t 1 ]] && printf "\r\033[2K" >&2
    fi
}

# ============================================================================
# User Interaction - Confirmation Dialogs
# ============================================================================

# ============================================================================
# Temporary File Management
# ============================================================================

# Global temp file tracking
declare -a MOLE_TEMP_FILES=()
declare -a MOLE_TEMP_DIRS=()

# Create tracked temporary file
# Returns: temp file path
create_temp_file() {
    local temp
    temp=$(mktemp) || return 1
    MOLE_TEMP_FILES+=("$temp")
    echo "$temp"
}

# Create tracked temporary directory
# Returns: temp directory path
create_temp_dir() {
    local temp
    temp=$(mktemp -d) || return 1
    MOLE_TEMP_DIRS+=("$temp")
    echo "$temp"
}

# Create temp file with prefix (for analyze.sh compatibility)
# Cleanup all tracked temp files
cleanup_temp_files() {
    local file
    if [[ ${#MOLE_TEMP_FILES[@]} -gt 0 ]]; then
        for file in "${MOLE_TEMP_FILES[@]}"; do
            [[ -f "$file" ]] && rm -f "$file" 2> /dev/null || true
        done
    fi

    if [[ ${#MOLE_TEMP_DIRS[@]} -gt 0 ]]; then
        for file in "${MOLE_TEMP_DIRS[@]}"; do
            [[ -d "$file" ]] && rm -rf "$file" 2> /dev/null || true
        done
    fi

    MOLE_TEMP_FILES=()
    MOLE_TEMP_DIRS=()
}

# Auto-cleanup on script exit (call this in main scripts)
# ============================================================================
# Lightweight spinner helper wrappers
# ============================================================================
# Usage: with_spinner "Message" cmd arg...
# Set MOLE_SPINNER_PREFIX="  " for indented spinner (e.g., in clean context)
with_spinner() {
    local msg="$1"
    shift || true
    local timeout="${MOLE_CMD_TIMEOUT:-180}" # Default 3min timeout

    if [[ -t 1 ]]; then
        start_inline_spinner "$msg"
    fi

    # Run command with timeout protection
    if command -v timeout > /dev/null 2>&1; then
        # GNU timeout available
        timeout "$timeout" "$@" > /dev/null 2>&1 || {
            local exit_code=$?
            if [[ -t 1 ]]; then stop_inline_spinner; fi
            # Exit code 124 means timeout
            [[ $exit_code -eq 124 ]] && echo -e "  ${YELLOW}${ICON_WARNING}${NC} $msg timed out (skipped)" >&2
            return $exit_code
        }
    else
        # Fallback: run in background with manual timeout
        "$@" > /dev/null 2>&1 &
        local cmd_pid=$!
        local elapsed=0
        while kill -0 $cmd_pid 2> /dev/null; do
            if [[ $elapsed -ge $timeout ]]; then
                kill -TERM $cmd_pid 2> /dev/null || true
                wait $cmd_pid 2> /dev/null || true
                if [[ -t 1 ]]; then stop_inline_spinner; fi
                echo -e "  ${YELLOW}${ICON_WARNING}${NC} $msg timed out (skipped)" >&2
                return 124
            fi
            sleep 1
            ((elapsed++))
        done
        wait $cmd_pid 2> /dev/null || {
            local exit_code=$?
            if [[ -t 1 ]]; then stop_inline_spinner; fi
            return $exit_code
        }
    fi

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi
}

# ============================================================================
# Cache/tool cleanup abstraction
# ============================================================================
# clean_tool_cache "Label" command...
clean_tool_cache() {
    local label="$1"
    shift || true
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${YELLOW}→${NC} $label (would clean)"
        return 0
    fi
    if MOLE_SPINNER_PREFIX="  " with_spinner "$label" "$@"; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $label"
    else
        local exit_code=$?
        # Timeout returns 124, don't show error message (already shown by with_spinner)
        if [[ $exit_code -ne 124 ]]; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} $label failed (skipped)" >&2
        fi
    fi
    return 0 # Always return success to continue cleanup
}

# ============================================================================
# Unified confirmation prompt with consistent style
# ============================================================================

# Unified action prompt
# Usage: prompt_action "action" "cancel_text" -> returns 0 for yes, 1 for no
# Example: prompt_action "enable" "quit" -> "☛ Press Enter to enable, ESC to quit: "
# Get optimal parallel job count based on CPU cores

# ============================================================================
# Size helpers
# ============================================================================

# Get path size in KB using du
# Args: $1 - path to measure
# Returns: size in KB, or 0 if path doesn't exist or error occurs
get_path_size_kb() {
    local path="$1"
    [[ -z "$path" || ! -e "$path" ]] && { echo "0"; return; }
    local result
    result=$(command du -sk "$path" 2> /dev/null | awk '{print $1}')
    echo "${result:-0}"
}

bytes_to_human_kb() { bytes_to_human "$((${1:-0} * 1024))"; }

# ============================================================================
# mktemp unification wrappers (register access)
# ============================================================================
register_temp_file() { MOLE_TEMP_FILES+=("$1"); }
register_temp_dir() { MOLE_TEMP_DIRS+=("$1"); }

mktemp_file() {
    local f
    f=$(mktemp) || return 1
    register_temp_file "$f"
    echo "$f"
}

# ============================================================================
# Uninstall helper abstractions
# ============================================================================
force_kill_app() {
    # Args: app_name [app_path]; tries graceful then force kill; returns 0 if stopped, 1 otherwise
    local app_name="$1"
    local app_path="${2:-}"

    # Get the executable name from bundle if app_path is provided
    local exec_name=""
    if [[ -n "$app_path" && -e "$app_path/Contents/Info.plist" ]]; then
        exec_name=$(defaults read "$app_path/Contents/Info.plist" CFBundleExecutable 2> /dev/null || echo "")
    fi

    # Use executable name for precise matching, fallback to app name
    local match_pattern="${exec_name:-$app_name}"

    # Check if process is running using exact match only
    if ! pgrep -x "$match_pattern" > /dev/null 2>&1; then
        return 0
    fi

    # Try graceful termination first
    pkill -x "$match_pattern" 2> /dev/null || true
    sleep 2

    # Check again after graceful kill
    if ! pgrep -x "$match_pattern" > /dev/null 2>&1; then
        return 0
    fi

    # Force kill if still running
    pkill -9 -x "$match_pattern" 2> /dev/null || true
    sleep 2

    # If still running and sudo is available, try with sudo
    if pgrep -x "$match_pattern" > /dev/null 2>&1; then
        if sudo -n true 2> /dev/null; then
            sudo pkill -9 -x "$match_pattern" 2> /dev/null || true
            sleep 2
        fi
    fi

    # Final check with longer timeout for stubborn processes
    local retries=3
    while [[ $retries -gt 0 ]]; do
        if ! pgrep -x "$match_pattern" > /dev/null 2>&1; then
            return 0
        fi
        sleep 1
        ((retries--))
    done

    # Still running after all attempts
    pgrep -x "$match_pattern" > /dev/null 2>&1 && return 1 || return 0
}

# Remove application icons from the Dock (best effort)
remove_apps_from_dock() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi

    local plist="$HOME/Library/Preferences/com.apple.dock.plist"
    [[ -f "$plist" ]] || return 0

    if ! command -v python3 > /dev/null 2>&1; then
        return 0
    fi

    # Execute Python helper to prune dock entries for the given app paths.
    # Exit status 2 means entries were removed.
    local target_count=$#

    python3 - "$@" << 'PY'
import os
import plistlib
import subprocess
import sys
import urllib.parse

plist_path = os.path.expanduser('~/Library/Preferences/com.apple.dock.plist')
if not os.path.exists(plist_path):
    sys.exit(0)

def normalise(path):
    if not path:
        return ''
    return os.path.normpath(os.path.realpath(path.rstrip('/')))

targets = {normalise(arg) for arg in sys.argv[1:] if arg}
targets = {t for t in targets if t}
if not targets:
    sys.exit(0)

with open(plist_path, 'rb') as fh:
    try:
        data = plistlib.load(fh)
    except Exception:
        sys.exit(0)

apps = data.get('persistent-apps')
if not isinstance(apps, list):
    sys.exit(0)

changed = False
filtered = []
for item in apps:
    try:
        url = item['tile-data']['file-data']['_CFURLString']
    except (KeyError, TypeError):
        filtered.append(item)
        continue

    if not isinstance(url, str):
        filtered.append(item)
        continue

    parsed = urllib.parse.urlparse(url)
    path = urllib.parse.unquote(parsed.path or '')
    if not path:
        filtered.append(item)
        continue

    candidate = normalise(path)
    if any(candidate == t or candidate.startswith(t + os.sep) for t in targets):
        changed = True
        continue

    filtered.append(item)

if not changed:
    sys.exit(0)

data['persistent-apps'] = filtered
with open(plist_path, 'wb') as fh:
    try:
        plistlib.dump(data, fh, fmt=plistlib.FMT_BINARY)
    except Exception:
        plistlib.dump(data, fh)

# Restart Dock to apply changes (ignore errors)
try:
    subprocess.run(['killall', 'Dock'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
except Exception:
    pass

sys.exit(2)
PY
    local python_status=$?
    if [[ $python_status -eq 2 ]]; then
        if [[ $target_count -gt 1 ]]; then
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Removed app icons from Dock"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Removed app icon from Dock"
        fi
        return 0
    fi
    return $python_status
}

# Get optimal parallel job count based on CPU cores
get_optimal_parallel_jobs() {
    local operation_type="${1:-default}"
    local cpu_cores
    cpu_cores=$(sysctl -n hw.ncpu 2> /dev/null || echo 4)
    case "$operation_type" in
        scan | io)
            echo $((cpu_cores * 2))
            ;;
        compute)
            echo "$cpu_cores"
            ;;
        *)
            echo $((cpu_cores + 2))
            ;;
    esac
}

# ============================================================================
# Sudo Keepalive Management
# ============================================================================

# Start sudo keepalive process
# Returns: PID of the keepalive process
start_sudo_keepalive() {
    (
        local retry_count=0
        while true; do
            if ! sudo -n -v 2> /dev/null; then
                ((retry_count++))
                if [[ $retry_count -ge 3 ]]; then
                    exit 1
                fi
                sleep 5
                continue
            fi
            retry_count=0
            sleep 30
            kill -0 "$$" 2> /dev/null || exit
        done
    ) 2> /dev/null &
    echo $!
}

# Stop sudo keepalive process
# Args: $1 - PID of the keepalive process
stop_sudo_keepalive() {
    local pid="${1:-}"
    if [[ -n "$pid" ]]; then
        kill "$pid" 2> /dev/null || true
        wait "$pid" 2> /dev/null || true
    fi
}

# ============================================================================
# Section Management
# ============================================================================

# Section tracking variables
TRACK_SECTION=0
SECTION_ACTIVITY=0

# Start a new section
start_section() {
    TRACK_SECTION=1
    SECTION_ACTIVITY=0
    echo ""
    echo -e "${PURPLE_BOLD}${ICON_ARROW} $1${NC}"
}

# End a section (show "Nothing to tidy" if no activity)
end_section() {
    if [[ $TRACK_SECTION -eq 1 && $SECTION_ACTIVITY -eq 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Nothing to tidy"
    fi
    TRACK_SECTION=0
}

# Mark activity in current section
note_activity() {
    if [[ $TRACK_SECTION -eq 1 ]]; then
        SECTION_ACTIVITY=1
    fi
}

# ============================================================================
# App Management Functions
# ============================================================================

# System critical components that should NEVER be uninstalled
readonly SYSTEM_CRITICAL_BUNDLES=(
    "com.apple.*" # System essentials
    "loginwindow"
    "dock"
    "systempreferences"
    "finder"
    "safari"
    "keychain*"
    "security*"
    "bluetooth*"
    "wifi*"
    "network*"
    "tcc"
    "notification*"
    "accessibility*"
    "universalaccess*"
    "HIToolbox*"
    "textinput*"
    "TextInput*"
    "keyboard*"
    "Keyboard*"
    "inputsource*"
    "InputSource*"
    "keylayout*"
    "KeyLayout*"
    "GlobalPreferences"
    ".GlobalPreferences"
    # Input methods (critical for international users)
    "com.tencent.inputmethod.QQInput"
    "com.sogou.inputmethod.*"
    "com.baidu.inputmethod.*"
    "com.apple.inputmethod.*"
    "com.googlecode.rimeime.*"
    "im.rime.*"
    "org.pqrs.Karabiner*"
    "*.inputmethod"
    "*.InputMethod"
    "*IME"
    "com.apple.inputsource*"
    "com.apple.TextInputMenuAgent"
    "com.apple.TextInputSwitcher"
)

# Apps with important data/licenses - protect during cleanup but allow uninstall
readonly DATA_PROTECTED_BUNDLES=(
    # ============================================================================
    # System Utilities & Cleanup Tools
    # ============================================================================
    "com.nektony.*"                 # App Cleaner & Uninstaller
    "com.macpaw.*"                  # CleanMyMac, CleanMaster
    "com.freemacsoft.AppCleaner"    # AppCleaner
    "com.omnigroup.omnidisksweeper" # OmniDiskSweeper
    "com.daisydiskapp.*"            # DaisyDisk
    "com.tunabellysoftware.*"       # Disk Utility apps
    "com.grandperspectiv.*"         # GrandPerspective
    "com.binaryfruit.*"             # FusionCast

    # ============================================================================
    # Password Managers & Security
    # ============================================================================
    "com.1password.*" # 1Password
    "com.agilebits.*" # 1Password legacy
    "com.lastpass.*"  # LastPass
    "com.dashlane.*"  # Dashlane
    "com.bitwarden.*" # Bitwarden
    "com.keepassx.*"  # KeePassXC
    "org.keepassx.*"  # KeePassX
    "com.authy.*"     # Authy
    "com.yubico.*"    # YubiKey Manager

    # ============================================================================
    # Development Tools - IDEs & Editors
    # ============================================================================
    "com.jetbrains.*"              # JetBrains IDEs (IntelliJ, DataGrip, etc.)
    "JetBrains*"                   # JetBrains Application Support folders
    "com.microsoft.VSCode"         # Visual Studio Code
    "com.visualstudio.code.*"      # VS Code variants
    "com.sublimetext.*"            # Sublime Text
    "com.sublimehq.*"              # Sublime Merge
    "com.microsoft.VSCodeInsiders" # VS Code Insiders
    "com.apple.dt.Xcode"           # Xcode (keep settings)
    "com.coteditor.CotEditor"      # CotEditor
    "com.macromates.TextMate"      # TextMate
    "com.panic.Nova"               # Nova
    "abnerworks.Typora"            # Typora (Markdown editor)
    "com.uranusjr.macdown"         # MacDown

    # ============================================================================
    # Development Tools - Database Clients
    # ============================================================================
    "com.sequelpro.*"                   # Sequel Pro
    "com.sequel-ace.*"                  # Sequel Ace
    "com.tinyapp.*"                     # TablePlus
    "com.dbeaver.*"                     # DBeaver
    "com.navicat.*"                     # Navicat
    "com.mongodb.compass"               # MongoDB Compass
    "com.redis.RedisInsight"            # Redis Insight
    "com.pgadmin.pgadmin4"              # pgAdmin
    "com.eggerapps.Sequel-Pro"          # Sequel Pro legacy
    "com.valentina-db.Valentina-Studio" # Valentina Studio
    "com.dbvis.DbVisualizer"            # DbVisualizer

    # ============================================================================
    # Development Tools - API & Network
    # ============================================================================
    "com.postmanlabs.mac"      # Postman
    "com.konghq.insomnia"      # Insomnia
    "com.CharlesProxy.*"       # Charles Proxy
    "com.proxyman.*"           # Proxyman
    "com.getpaw.*"             # Paw
    "com.luckymarmot.Paw"      # Paw legacy
    "com.charlesproxy.charles" # Charles
    "com.telerik.Fiddler"      # Fiddler
    "com.usebruno.app"         # Bruno (API client)

    # Network Proxy & VPN Tools (protect all variants)
    "*clash*"               # All Clash variants (ClashX, ClashX Pro, Clash Verge, etc)
    "*Clash*"               # Capitalized variants
    "com.nssurge.surge-mac" # Surge
    "mihomo*"               # Mihomo Party and variants
    "*openvpn*"             # OpenVPN Connect and variants
    "*OpenVPN*"             # OpenVPN capitalized variants
    "net.openvpn.*"         # OpenVPN bundle IDs

    # ============================================================================
    # Development Tools - Git & Version Control
    # ============================================================================
    "com.github.GitHubDesktop"       # GitHub Desktop
    "com.sublimemerge"               # Sublime Merge
    "com.torusknot.SourceTreeNotMAS" # SourceTree
    "com.git-tower.Tower*"           # Tower
    "com.gitfox.GitFox"              # GitFox
    "com.github.Gitify"              # Gitify
    "com.fork.Fork"                  # Fork
    "com.axosoft.gitkraken"          # GitKraken

    # ============================================================================
    # Development Tools - Terminal & Shell
    # ============================================================================
    "com.googlecode.iterm2"  # iTerm2
    "net.kovidgoyal.kitty"   # Kitty
    "io.alacritty"           # Alacritty
    "com.github.wez.wezterm" # WezTerm
    "com.hyper.Hyper"        # Hyper
    "com.mizage.divvy"       # Divvy
    "com.fig.Fig"            # Fig (terminal assistant)
    "dev.warp.Warp-Stable"   # Warp
    "com.termius-dmg"        # Termius (SSH client)

    # ============================================================================
    # Development Tools - Docker & Virtualization
    # ============================================================================
    "com.docker.docker"             # Docker Desktop
    "com.getutm.UTM"                # UTM
    "com.vmware.fusion"             # VMware Fusion
    "com.parallels.desktop.*"       # Parallels Desktop
    "org.virtualbox.app.VirtualBox" # VirtualBox
    "com.vagrant.*"                 # Vagrant
    "com.orbstack.OrbStack"         # OrbStack

    # ============================================================================
    # System Monitoring & Performance
    # ============================================================================
    "com.bjango.istatmenus*"       # iStat Menus
    "eu.exelban.Stats"             # Stats
    "com.monitorcontrol.*"         # MonitorControl
    "com.bresink.system-toolkit.*" # TinkerTool System
    "com.mediaatelier.MenuMeters"  # MenuMeters
    "com.activity-indicator.app"   # Activity Indicator
    "net.cindori.sensei"           # Sensei

    # ============================================================================
    # Window Management & Productivity
    # ============================================================================
    "com.macitbetter.*"            # BetterTouchTool, BetterSnapTool
    "com.hegenberg.*"              # BetterTouchTool legacy
    "com.manytricks.*"             # Moom, Witch, Name Mangler, Resolutionator
    "com.divisiblebyzero.*"        # Spectacle
    "com.koingdev.*"               # Koingg apps
    "com.if.Amphetamine"           # Amphetamine
    "com.lwouis.alt-tab-macos"     # AltTab
    "net.matthewpalmer.Vanilla"    # Vanilla
    "com.lightheadsw.Caffeine"     # Caffeine
    "com.contextual.Contexts"      # Contexts
    "com.amethyst.Amethyst"        # Amethyst
    "com.knollsoft.Rectangle"      # Rectangle
    "com.knollsoft.Hookshot"       # Hookshot
    "com.surteesstudios.Bartender" # Bartender
    "com.gaosun.eul"               # eul (system monitor)
    "com.pointum.hazeover"         # HazeOver

    # ============================================================================
    # Launcher & Automation
    # ============================================================================
    "com.runningwithcrayons.Alfred"   # Alfred
    "com.raycast.macos"               # Raycast
    "com.blacktree.Quicksilver"       # Quicksilver
    "com.stairways.keyboardmaestro.*" # Keyboard Maestro
    "com.manytricks.Butler"           # Butler
    "com.happenapps.Quitter"          # Quitter
    "com.pilotmoon.scroll-reverser"   # Scroll Reverser
    "org.pqrs.Karabiner-Elements"     # Karabiner-Elements
    "com.apple.Automator"             # Automator (system, but keep user workflows)

    # ============================================================================
    # Note-Taking & Documentation
    # ============================================================================
    "com.bear-writer.*"           # Bear
    "com.typora.*"                # Typora
    "com.ulyssesapp.*"            # Ulysses
    "com.literatureandlatte.*"    # Scrivener
    "com.dayoneapp.*"             # Day One
    "notion.id"                   # Notion
    "md.obsidian"                 # Obsidian
    "com.logseq.logseq"           # Logseq
    "com.evernote.Evernote"       # Evernote
    "com.onenote.mac"             # OneNote
    "com.omnigroup.OmniOutliner*" # OmniOutliner
    "net.shinyfrog.bear"          # Bear legacy
    "com.goodnotes.GoodNotes"     # GoodNotes
    "com.marginnote.MarginNote*"  # MarginNote
    "com.roamresearch.*"          # Roam Research
    "com.reflect.ReflectApp"      # Reflect
    "com.inkdrop.*"               # Inkdrop

    # ============================================================================
    # Design & Creative Tools
    # ============================================================================
    "com.adobe.*"             # Adobe Creative Suite
    "com.bohemiancoding.*"    # Sketch
    "com.figma.*"             # Figma
    "com.framerx.*"           # Framer
    "com.zeplin.*"            # Zeplin
    "com.invisionapp.*"       # InVision
    "com.principle.*"         # Principle
    "com.pixelmatorteam.*"    # Pixelmator
    "com.affinitydesigner.*"  # Affinity Designer
    "com.affinityphoto.*"     # Affinity Photo
    "com.affinitypublisher.*" # Affinity Publisher
    "com.linearity.curve"     # Linearity Curve
    "com.canva.CanvaDesktop"  # Canva
    "com.maxon.cinema4d"      # Cinema 4D
    "com.autodesk.*"          # Autodesk products
    "com.sketchup.*"          # SketchUp

    # ============================================================================
    # Communication & Collaboration
    # ============================================================================
    "com.tencent.xinWeChat"                   # WeChat (Chinese users)
    "com.tencent.qq"                          # QQ
    "com.alibaba.DingTalkMac"                 # DingTalk
    "com.alibaba.AliLang.osx"                 # AliLang (retain login/config data)
    "com.alibaba.alilang3.osx.ShipIt"         # AliLang updater component
    "com.alibaba.AlilangMgr.QueryNetworkInfo" # AliLang network helper
    "us.zoom.xos"                             # Zoom
    "com.microsoft.teams*"                    # Microsoft Teams
    "com.slack.Slack"                         # Slack
    "com.hnc.Discord"                         # Discord
    "org.telegram.desktop"                    # Telegram
    "ru.keepcoder.Telegram"                   # Telegram legacy
    "net.whatsapp.WhatsApp"                   # WhatsApp
    "com.skype.skype"                         # Skype
    "com.cisco.webexmeetings"                 # Webex
    "com.ringcentral.RingCentral"             # RingCentral
    "com.readdle.smartemail-Mac"              # Spark Email
    "com.airmail.*"                           # Airmail
    "com.postbox-inc.postbox"                 # Postbox
    "com.tinyspeck.slackmacgap"               # Slack legacy

    # ============================================================================
    # Task Management & Productivity
    # ============================================================================
    "com.omnigroup.OmniFocus*" # OmniFocus
    "com.culturedcode.*"       # Things
    "com.todoist.*"            # Todoist
    "com.any.do.*"             # Any.do
    "com.ticktick.*"           # TickTick
    "com.microsoft.to-do"      # Microsoft To Do
    "com.trello.trello"        # Trello
    "com.asana.nativeapp"      # Asana
    "com.clickup.*"            # ClickUp
    "com.monday.desktop"       # Monday.com
    "com.airtable.airtable"    # Airtable
    "com.notion.id"            # Notion (also note-taking)
    "com.linear.linear"        # Linear

    # ============================================================================
    # File Transfer & Sync
    # ============================================================================
    "com.panic.transmit*"            # Transmit (FTP/SFTP)
    "com.binarynights.ForkLift*"     # ForkLift
    "com.noodlesoft.Hazel"           # Hazel
    "com.cyberduck.Cyberduck"        # Cyberduck
    "io.filezilla.FileZilla"         # FileZilla
    "com.apple.Xcode.CloudDocuments" # Xcode Cloud Documents
    "com.synology.*"                 # Synology apps

    # ============================================================================
    # Screenshot & Recording
    # ============================================================================
    "com.cleanshot.*"                   # CleanShot X
    "com.xnipapp.xnip"                  # Xnip
    "com.reincubate.camo"               # Camo
    "com.tunabellysoftware.ScreenFloat" # ScreenFloat
    "net.telestream.screenflow*"        # ScreenFlow
    "com.techsmith.snagit*"             # Snagit
    "com.techsmith.camtasia*"           # Camtasia
    "com.obsidianapp.screenrecorder"    # Screen Recorder
    "com.kap.Kap"                       # Kap
    "com.getkap.*"                      # Kap legacy
    "com.linebreak.CloudApp"            # CloudApp
    "com.droplr.droplr-mac"             # Droplr

    # ============================================================================
    # Media & Entertainment
    # ============================================================================
    "com.spotify.client"      # Spotify
    "com.apple.Music"         # Apple Music
    "com.apple.podcasts"      # Apple Podcasts
    "com.apple.FinalCutPro"   # Final Cut Pro
    "com.apple.Motion"        # Motion
    "com.apple.Compressor"    # Compressor
    "com.blackmagic-design.*" # DaVinci Resolve
    "com.colliderli.iina"     # IINA
    "org.videolan.vlc"        # VLC
    "io.mpv"                  # MPV
    "com.noodlesoft.Hazel"    # Hazel (automation)
    "tv.plex.player.desktop"  # Plex
    "com.netease.163music"    # NetEase Music

    # ============================================================================
    # License Management & App Stores
    # ============================================================================
    "com.paddle.Paddle*"          # Paddle (license management)
    "com.setapp.DesktopClient"    # Setapp
    "com.devmate.*"               # DevMate (license framework)
    "org.sparkle-project.Sparkle" # Sparkle (update framework)
)

# Legacy function - preserved for backward compatibility
# Use should_protect_from_uninstall() or should_protect_data() instead
readonly PRESERVED_BUNDLE_PATTERNS=("${SYSTEM_CRITICAL_BUNDLES[@]}" "${DATA_PROTECTED_BUNDLES[@]}")

# Check whether a bundle ID matches a pattern (supports globs)
bundle_matches_pattern() {
    local bundle_id="$1"
    local pattern="$2"

    [[ -z "$pattern" ]] && return 1

    # shellcheck disable=SC2254  # allow glob pattern matching for bundle rules
    case "$bundle_id" in
        $pattern) return 0 ;;
    esac
    return 1
}

# Check if app is a system component that should never be uninstalled
should_protect_from_uninstall() {
    local bundle_id="$1"
    for pattern in "${SYSTEM_CRITICAL_BUNDLES[@]}"; do
        if bundle_matches_pattern "$bundle_id" "$pattern"; then
            return 0
        fi
    done
    return 1
}

# Check if app data should be protected during cleanup (but app can be uninstalled)
should_protect_data() {
    local bundle_id="$1"
    # Protect both system critical and data protected bundles during cleanup
    for pattern in "${SYSTEM_CRITICAL_BUNDLES[@]}" "${DATA_PROTECTED_BUNDLES[@]}"; do
        if bundle_matches_pattern "$bundle_id" "$pattern"; then
            return 0
        fi
    done
    return 1
}

# Find and list app-related files (consolidated from duplicates)
find_app_files() {
    local bundle_id="$1"
    local app_name="$2"
    local -a files_to_clean=()

    # ============================================================================
    # User-level files (no sudo required)
    # ============================================================================

    # Application Support
    [[ -d ~/Library/Application\ Support/"$app_name" ]] && files_to_clean+=("$HOME/Library/Application Support/$app_name")
    [[ -d ~/Library/Application\ Support/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/Application Support/$bundle_id")

    # Caches
    [[ -d ~/Library/Caches/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/Caches/$bundle_id")
    [[ -d ~/Library/Caches/"$app_name" ]] && files_to_clean+=("$HOME/Library/Caches/$app_name")

    # Preferences
    [[ -f ~/Library/Preferences/"$bundle_id".plist ]] && files_to_clean+=("$HOME/Library/Preferences/$bundle_id.plist")
    while IFS= read -r -d '' pref; do
        files_to_clean+=("$pref")
    done < <(command find ~/Library/Preferences/ByHost \( -name "$bundle_id*.plist" \) -print0 2> /dev/null)

    # Logs
    [[ -d ~/Library/Logs/"$app_name" ]] && files_to_clean+=("$HOME/Library/Logs/$app_name")
    [[ -d ~/Library/Logs/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/Logs/$bundle_id")

    # Crash Reports and Diagnostics
    while IFS= read -r -d '' report; do
        files_to_clean+=("$report")
    done < <(command find ~/Library/Logs/DiagnosticReports \( -name "*$app_name*" -o -name "*$bundle_id*" \) -print0 2> /dev/null)

    # Saved Application State
    [[ -d ~/Library/Saved\ Application\ State/"$bundle_id".savedState ]] && files_to_clean+=("$HOME/Library/Saved Application State/$bundle_id.savedState")

    # Containers (sandboxed apps)
    [[ -d ~/Library/Containers/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/Containers/$bundle_id")

    # Group Containers
    while IFS= read -r -d '' container; do
        files_to_clean+=("$container")
    done < <(command find ~/Library/Group\ Containers -type d \( -name "*$bundle_id*" \) -print0 2> /dev/null)

    # WebKit data
    [[ -d ~/Library/WebKit/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/WebKit/$bundle_id")
    [[ -d ~/Library/WebKit/com.apple.WebKit.WebContent/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/WebKit/com.apple.WebKit.WebContent/$bundle_id")

    # HTTP Storage
    [[ -d ~/Library/HTTPStorages/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/HTTPStorages/$bundle_id")

    # Cookies
    [[ -f ~/Library/Cookies/"$bundle_id".binarycookies ]] && files_to_clean+=("$HOME/Library/Cookies/$bundle_id.binarycookies")

    # Launch Agents (user-level)
    [[ -f ~/Library/LaunchAgents/"$bundle_id".plist ]] && files_to_clean+=("$HOME/Library/LaunchAgents/$bundle_id.plist")

    # Application Scripts
    [[ -d ~/Library/Application\ Scripts/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/Application Scripts/$bundle_id")

    # Services
    [[ -d ~/Library/Services/"$app_name".workflow ]] && files_to_clean+=("$HOME/Library/Services/$app_name.workflow")

    # Internet Plug-Ins
    while IFS= read -r -d '' plugin; do
        files_to_clean+=("$plugin")
    done < <(command find ~/Library/Internet\ Plug-Ins \( -name "$bundle_id*" -o -name "$app_name*" \) -print0 2> /dev/null)

    # QuickLook Plugins
    [[ -d ~/Library/QuickLook/"$app_name".qlgenerator ]] && files_to_clean+=("$HOME/Library/QuickLook/$app_name.qlgenerator")

    # Preference Panes
    [[ -d ~/Library/PreferencePanes/"$app_name".prefPane ]] && files_to_clean+=("$HOME/Library/PreferencePanes/$app_name.prefPane")

    # Screen Savers
    [[ -d ~/Library/Screen\ Savers/"$app_name".saver ]] && files_to_clean+=("$HOME/Library/Screen Savers/$app_name.saver")

    # Frameworks
    [[ -d ~/Library/Frameworks/"$app_name".framework ]] && files_to_clean+=("$HOME/Library/Frameworks/$app_name.framework")

    # CoreData
    while IFS= read -r -d '' coredata; do
        files_to_clean+=("$coredata")
    done < <(command find ~/Library/CoreData \( -name "*$bundle_id*" -o -name "*$app_name*" \) -print0 2> /dev/null)

    # Autosave Information
    [[ -d ~/Library/Autosave\ Information/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/Autosave Information/$bundle_id")

    # Contextual Menu Items
    [[ -d ~/Library/Contextual\ Menu\ Items/"$app_name".plugin ]] && files_to_clean+=("$HOME/Library/Contextual Menu Items/$app_name.plugin")

    # Receipts (user-level)
    while IFS= read -r -d '' receipt; do
        files_to_clean+=("$receipt")
    done < <(command find ~/Library/Receipts \( -name "*$bundle_id*" -o -name "*$app_name*" \) -print0 2> /dev/null)

    # Spotlight Plugins
    [[ -d ~/Library/Spotlight/"$app_name".mdimporter ]] && files_to_clean+=("$HOME/Library/Spotlight/$app_name.mdimporter")

    # Scripting Additions
    while IFS= read -r -d '' scripting; do
        files_to_clean+=("$scripting")
    done < <(command find ~/Library/ScriptingAdditions \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # Color Pickers
    [[ -d ~/Library/ColorPickers/"$app_name".colorPicker ]] && files_to_clean+=("$HOME/Library/ColorPickers/$app_name.colorPicker")

    # Quartz Compositions
    while IFS= read -r -d '' composition; do
        files_to_clean+=("$composition")
    done < <(command find ~/Library/Compositions \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # Address Book Plug-Ins
    while IFS= read -r -d '' plugin; do
        files_to_clean+=("$plugin")
    done < <(command find ~/Library/Address\ Book\ Plug-Ins \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # Mail Bundles
    while IFS= read -r -d '' bundle; do
        files_to_clean+=("$bundle")
    done < <(command find ~/Library/Mail/Bundles \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # Input Managers (app-specific only)
    while IFS= read -r -d '' manager; do
        files_to_clean+=("$manager")
    done < <(command find ~/Library/InputManagers \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # Custom Sounds
    while IFS= read -r -d '' sound; do
        files_to_clean+=("$sound")
    done < <(command find ~/Library/Sounds \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # Plugins
    while IFS= read -r -d '' plugin; do
        files_to_clean+=("$plugin")
    done < <(command find ~/Library/Plugins \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # Private Frameworks
    while IFS= read -r -d '' framework; do
        files_to_clean+=("$framework")
    done < <(command find ~/Library/PrivateFrameworks \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # Audio Plug-Ins
    while IFS= read -r -d '' plugin; do
        files_to_clean+=("$plugin")
    done < <(command find ~/Library/Audio/Plug-Ins \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # Components
    while IFS= read -r -d '' component; do
        files_to_clean+=("$component")
    done < <(command find ~/Library/Components \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # Metadata
    while IFS= read -r -d '' metadata; do
        files_to_clean+=("$metadata")
    done < <(command find ~/Library/Metadata \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # Workflows
    [[ -d ~/Library/Workflows/"$app_name".workflow ]] && files_to_clean+=("$HOME/Library/Workflows/$app_name.workflow")
    while IFS= read -r -d '' workflow; do
        files_to_clean+=("$workflow")
    done < <(command find ~/Library/Workflows \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # Favorites (excluding Safari)
    while IFS= read -r -d '' favorite; do
        # Skip Safari favorites
        case "$favorite" in
            *Safari*) continue ;;
        esac
        files_to_clean+=("$favorite")
    done < <(command find ~/Library/Favorites \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # Unix-style configuration directories and files (cross-platform apps)
    [[ -d ~/.config/"$app_name" ]] && files_to_clean+=("$HOME/.config/$app_name")
    [[ -d ~/.local/share/"$app_name" ]] && files_to_clean+=("$HOME/.local/share/$app_name")
    [[ -d ~/."$app_name" ]] && files_to_clean+=("$HOME/.$app_name")
    [[ -f ~/."${app_name}rc" ]] && files_to_clean+=("$HOME/.${app_name}rc")

    # Only print if array has elements to avoid unbound variable error
    if [[ ${#files_to_clean[@]} -gt 0 ]]; then
        printf '%s\n' "${files_to_clean[@]}"
    fi
}

# Find system-level app files (requires sudo)
find_app_system_files() {
    local bundle_id="$1"
    local app_name="$2"
    local -a system_files=()

    # System Application Support
    [[ -d /Library/Application\ Support/"$app_name" ]] && system_files+=("/Library/Application Support/$app_name")
    [[ -d /Library/Application\ Support/"$bundle_id" ]] && system_files+=("/Library/Application Support/$bundle_id")

    # System Launch Agents
    [[ -f /Library/LaunchAgents/"$bundle_id".plist ]] && system_files+=("/Library/LaunchAgents/$bundle_id.plist")

    # System Launch Daemons
    [[ -f /Library/LaunchDaemons/"$bundle_id".plist ]] && system_files+=("/Library/LaunchDaemons/$bundle_id.plist")

    # Privileged Helper Tools
    while IFS= read -r -d '' helper; do
        system_files+=("$helper")
    done < <(command find /Library/PrivilegedHelperTools \( -name "$bundle_id*" \) -print0 2> /dev/null)

    # System Preferences
    [[ -f /Library/Preferences/"$bundle_id".plist ]] && system_files+=("/Library/Preferences/$bundle_id.plist")

    # Installation Receipts
    while IFS= read -r -d '' receipt; do
        system_files+=("$receipt")
    done < <(command find /private/var/db/receipts \( -name "*$bundle_id*" \) -print0 2> /dev/null)

    # System Logs
    [[ -d /Library/Logs/"$app_name" ]] && system_files+=("/Library/Logs/$app_name")
    [[ -d /Library/Logs/"$bundle_id" ]] && system_files+=("/Library/Logs/$bundle_id")

    # System Crash Reports and Diagnostics
    while IFS= read -r -d '' report; do
        system_files+=("$report")
    done < <(command find /Library/Logs/DiagnosticReports \( -name "*$app_name*" -o -name "*$bundle_id*" \) -print0 2> /dev/null)

    # System Frameworks
    [[ -d /Library/Frameworks/"$app_name".framework ]] && system_files+=("/Library/Frameworks/$app_name.framework")

    # System Internet Plug-Ins
    while IFS= read -r -d '' plugin; do
        system_files+=("$plugin")
    done < <(command find /Library/Internet\ Plug-Ins \( -name "$bundle_id*" -o -name "$app_name*" \) -print0 2> /dev/null)

    # System QuickLook Plugins
    [[ -d /Library/QuickLook/"$app_name".qlgenerator ]] && system_files+=("/Library/QuickLook/$app_name.qlgenerator")

    # System Receipts
    while IFS= read -r -d '' receipt; do
        system_files+=("$receipt")
    done < <(command find /Library/Receipts \( -name "*$bundle_id*" -o -name "*$app_name*" \) -print0 2> /dev/null)

    # System Spotlight Plugins
    [[ -d /Library/Spotlight/"$app_name".mdimporter ]] && system_files+=("/Library/Spotlight/$app_name.mdimporter")

    # System Scripting Additions
    while IFS= read -r -d '' scripting; do
        system_files+=("$scripting")
    done < <(command find /Library/ScriptingAdditions \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # System Color Pickers
    [[ -d /Library/ColorPickers/"$app_name".colorPicker ]] && system_files+=("/Library/ColorPickers/$app_name.colorPicker")

    # System Quartz Compositions
    while IFS= read -r -d '' composition; do
        system_files+=("$composition")
    done < <(command find /Library/Compositions \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # System Address Book Plug-Ins
    while IFS= read -r -d '' plugin; do
        system_files+=("$plugin")
    done < <(command find /Library/Address\ Book\ Plug-Ins \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # System Mail Bundles
    while IFS= read -r -d '' bundle; do
        system_files+=("$bundle")
    done < <(command find /Library/Mail/Bundles \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # System Input Managers
    while IFS= read -r -d '' manager; do
        system_files+=("$manager")
    done < <(command find /Library/InputManagers \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # System Sounds
    while IFS= read -r -d '' sound; do
        system_files+=("$sound")
    done < <(command find /Library/Sounds \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # System Contextual Menu Items
    while IFS= read -r -d '' item; do
        system_files+=("$item")
    done < <(command find /Library/Contextual\ Menu\ Items \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # System Preference Panes
    [[ -d /Library/PreferencePanes/"$app_name".prefPane ]] && system_files+=("/Library/PreferencePanes/$app_name.prefPane")

    # System Screen Savers
    [[ -d /Library/Screen\ Savers/"$app_name".saver ]] && system_files+=("/Library/Screen Savers/$app_name.saver")

    # System Caches
    [[ -d /Library/Caches/"$bundle_id" ]] && system_files+=("/Library/Caches/$bundle_id")
    [[ -d /Library/Caches/"$app_name" ]] && system_files+=("/Library/Caches/$app_name")

    # System Audio Plug-Ins
    while IFS= read -r -d '' plugin; do
        system_files+=("$plugin")
    done < <(command find /Library/Audio/Plug-Ins \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # System Components
    while IFS= read -r -d '' component; do
        system_files+=("$component")
    done < <(command find /Library/Components \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # System Extensions
    while IFS= read -r -d '' extension; do
        system_files+=("$extension")
    done < <(command find /Library/Extensions \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2> /dev/null)

    # Only print if array has elements
    if [[ ${#system_files[@]} -gt 0 ]]; then
        printf '%s\n' "${system_files[@]}"
    fi
}

# Calculate total size of files (consolidated from duplicates)
calculate_total_size() {
    local files="$1"
    local total_kb=0

    while IFS= read -r file; do
        if [[ -n "$file" && -e "$file" ]]; then
            local size_kb
            size_kb=$(get_path_size_kb "$file")
            ((total_kb += size_kb))
        fi
    done <<< "$files"

    echo "$total_kb"
}

# Get normalized brand name (bash 3.2 compatible using case statement)
get_brand_name() {
    local name="$1"

    # Brand name mapping for better user recognition
    case "$name" in
        "qiyimac" | "爱奇艺") echo "iQiyi" ;;
        "wechat" | "微信") echo "WeChat" ;;
        "QQ") echo "QQ" ;;
        "VooV Meeting" | "腾讯会议") echo "VooV Meeting" ;;
        "dingtalk" | "钉钉") echo "DingTalk" ;;
        "NeteaseMusic" | "网易云音乐") echo "NetEase Music" ;;
        "BaiduNetdisk" | "百度网盘") echo "Baidu NetDisk" ;;
        "alipay" | "支付宝") echo "Alipay" ;;
        "taobao" | "淘宝") echo "Taobao" ;;
        "futunn" | "富途牛牛") echo "Futu NiuNiu" ;;
        "tencent lemon" | "Tencent Lemon Cleaner") echo "Tencent Lemon" ;;
        "keynote" | "Keynote") echo "Keynote" ;;
        "pages" | "Pages") echo "Pages" ;;
        "numbers" | "Numbers") echo "Numbers" ;;
        *) echo "$name" ;; # Return original if no mapping found
    esac
}
