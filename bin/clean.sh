#!/bin/bash
# Mole - Deeper system cleanup
# Complete cleanup with smart password handling

set -euo pipefail

# Fix locale issues (avoid Perl warnings on non-English systems)
export LC_ALL=C
export LANG=C

# Get script directory and source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"
source "$SCRIPT_DIR/../lib/core/sudo.sh"
source "$SCRIPT_DIR/../lib/clean/brew.sh"
source "$SCRIPT_DIR/../lib/clean/caches.sh"
source "$SCRIPT_DIR/../lib/clean/apps.sh"
source "$SCRIPT_DIR/../lib/clean/dev.sh"
source "$SCRIPT_DIR/../lib/clean/app_caches.sh"
source "$SCRIPT_DIR/../lib/clean/system.sh"
source "$SCRIPT_DIR/../lib/clean/user.sh"
source "$SCRIPT_DIR/../lib/clean/maintenance.sh"

# Configuration
SYSTEM_CLEAN=false
DRY_RUN=false
PROTECT_FINDER_METADATA=false
IS_M_SERIES=$([[ "$(uname -m)" == "arm64" ]] && echo "true" || echo "false")

# Export list configuration
EXPORT_LIST_FILE="$HOME/.config/mole/clean-list.txt"
CURRENT_SECTION=""

# Protected Service Worker domains (web-based editing tools)
readonly PROTECTED_SW_DOMAINS=(
    "capcut.com"
    "photopea.com"
    "pixlr.com"
)

# Whitelist patterns (loaded from common.sh)
# FINDER_METADATA_SENTINEL and DEFAULT_WHITELIST_PATTERNS defined in lib/core/common.sh
declare -a WHITELIST_PATTERNS=()
WHITELIST_WARNINGS=()

# Load user-defined whitelist
if [[ -f "$HOME/.config/mole/whitelist" ]]; then
    while IFS= read -r line; do
        # Trim whitespace
        # shellcheck disable=SC2295
        line="${line#"${line%%[![:space:]]*}"}"
        # shellcheck disable=SC2295
        line="${line%"${line##*[![:space:]]}"}"

        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        # Expand tilde to home directory
        [[ "$line" == ~* ]] && line="${line/#~/$HOME}"

        # Security: reject path traversal attempts
        if [[ "$line" =~ \.\. ]]; then
            WHITELIST_WARNINGS+=("Path traversal not allowed: $line")
            continue
        fi

        # Skip validation for special sentinel values
        if [[ "$line" != "$FINDER_METADATA_SENTINEL" ]]; then
            # Path validation with support for spaces and wildcards
            # Allow: letters, numbers, /, _, ., -, @, spaces, and * anywhere in path
            if [[ ! "$line" =~ ^[a-zA-Z0-9/_.@\ *-]+$ ]]; then
                WHITELIST_WARNINGS+=("Invalid path format: $line")
                continue
            fi

            # Require absolute paths (must start with /)
            if [[ "$line" != /* ]]; then
                WHITELIST_WARNINGS+=("Must be absolute path: $line")
                continue
            fi
        fi

        # Reject paths with consecutive slashes (e.g., //)
        if [[ "$line" =~ // ]]; then
            WHITELIST_WARNINGS+=("Consecutive slashes: $line")
            continue
        fi

        # Prevent critical system directories
        case "$line" in
            / | /System | /System/* | /bin | /bin/* | /sbin | /sbin/* | /usr/bin | /usr/bin/* | /usr/sbin | /usr/sbin/* | /etc | /etc/* | /var/db | /var/db/*)
                WHITELIST_WARNINGS+=("Protected system path: $line")
                continue
                ;;
        esac

        duplicate="false"
        if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
            for existing in "${WHITELIST_PATTERNS[@]}"; do
                if [[ "$line" == "$existing" ]]; then
                    duplicate="true"
                    break
                fi
            done
        fi
        [[ "$duplicate" == "true" ]] && continue
        WHITELIST_PATTERNS+=("$line")
    done < "$HOME/.config/mole/whitelist"
else
    WHITELIST_PATTERNS=("${DEFAULT_WHITELIST_PATTERNS[@]}")
fi

if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
    for entry in "${WHITELIST_PATTERNS[@]}"; do
        if [[ "$entry" == "$FINDER_METADATA_SENTINEL" ]]; then
            PROTECT_FINDER_METADATA=true
            break
        fi
    done
fi
total_items=0

# Tracking variables
TRACK_SECTION=0
SECTION_ACTIVITY=0
files_cleaned=0
total_size_cleaned=0
whitelist_skipped_count=0

note_activity() {
    if [[ $TRACK_SECTION -eq 1 ]]; then
        SECTION_ACTIVITY=1
    fi
}

# Cleanup background processes
CLEANUP_DONE=false
cleanup() {
    local signal="${1:-EXIT}"
    local exit_code="${2:-$?}"

    # Prevent multiple executions
    if [[ "$CLEANUP_DONE" == "true" ]]; then
        return 0
    fi
    CLEANUP_DONE=true

    # Stop all spinners and clear the line
    if [[ -n "$INLINE_SPINNER_PID" ]]; then
        kill "$INLINE_SPINNER_PID" 2> /dev/null || true
        wait "$INLINE_SPINNER_PID" 2> /dev/null || true
        INLINE_SPINNER_PID=""
    fi

    # Clear any spinner output - spinner outputs to stderr
    if [[ -t 1 ]]; then
        printf "\r\033[K" >&2
    fi

    # Stop sudo session
    stop_sudo_session

    show_cursor

    # If interrupted, show message
    if [[ "$signal" == "INT" ]] || [[ $exit_code -eq 130 ]]; then
        printf "\r\033[K" >&2
        echo -e "${YELLOW}Interrupted by user${NC}" >&2
    fi
}

trap 'cleanup EXIT $?' EXIT
trap 'cleanup INT 130; exit 130' INT
trap 'cleanup TERM 143; exit 143' TERM

start_section() {
    TRACK_SECTION=1
    SECTION_ACTIVITY=0
    CURRENT_SECTION="$1"
    debug_log "Starting section: $1"
    echo ""
    echo -e "${PURPLE_BOLD}${ICON_ARROW} $1${NC}"

    # Write section header to export list in dry-run mode
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "" >> "$EXPORT_LIST_FILE"
        echo "=== $1 ===" >> "$EXPORT_LIST_FILE"
    fi
}

end_section() {
    if [[ $TRACK_SECTION -eq 1 && $SECTION_ACTIVITY -eq 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Nothing to clean"
        debug_log "End section: ${CURRENT_SECTION:-unknown} (no activity)"
    else
        debug_log "End section: ${CURRENT_SECTION:-unknown} (had activity: $SECTION_ACTIVITY)"
    fi
    TRACK_SECTION=0
}

safe_clean() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi

    local description
    local -a targets

    if [[ $# -eq 1 ]]; then
        description="$1"
        targets=("$1")
    else
        # Get last argument as description
        description="${*: -1}"
        # Get all arguments except last as targets array
        targets=("${@:1:$#-1}")
    fi

    debug_log "safe_clean: description='$description', target_count=${#targets[@]}"

    local removed_any=0
    local total_size_bytes=0
    local total_count=0
    local skipped_count=0

    # Optimized parallel processing for better performance
    local -a existing_paths=()
    for path in "${targets[@]}"; do
        local skip=false

        # Hard-coded protection for critical apps (cannot be disabled by user)
        case "$path" in
            *clash* | *Clash* | *surge* | *Surge* | *mihomo* | *openvpn* | *OpenVPN*)
                skip=true
                ((skipped_count++))
                ;;
        esac

        [[ "$skip" == "true" ]] && continue

        # Check user-defined whitelist
        if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
            for w in "${WHITELIST_PATTERNS[@]}"; do
                # Match both exact path and glob pattern
                # shellcheck disable=SC2053
                if [[ "$path" == "$w" ]] || [[ $path == $w ]]; then
                    skip=true
                    ((skipped_count++))
                    break
                fi
            done
        fi
        [[ "$skip" == "true" ]] && continue
        [[ -e "$path" ]] && existing_paths+=("$path")
    done

    # Update global whitelist skip counter
    if [[ $skipped_count -gt 0 ]]; then
        ((whitelist_skipped_count += skipped_count))
    fi

    if [[ ${#existing_paths[@]} -eq 0 ]]; then
        return 0
    fi

    # Show progress indicator for potentially slow operations
    if [[ ${#existing_paths[@]} -gt 3 ]]; then
        local total_paths=${#existing_paths[@]}
        if [[ -t 1 ]]; then MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning $total_paths items..."; fi
        local temp_dir
        temp_dir=$(create_temp_dir)

        # Parallel processing (bash 3.2 compatible)
        local -a pids=()
        local idx=0
        local completed=0
        for path in "${existing_paths[@]}"; do
            (
                local size
                # Get size quickly with depth limit
                size=$(get_path_size_kb "$path")
                [[ -z "$size" || ! "$size" =~ ^[0-9]+$ ]] && size=0
                local count
                # Quick file count - limit for performance
                if [[ "$size" -gt 0 ]]; then
                    count=$(find "$path" -type f 2> /dev/null | head -1000 | wc -l | tr -d ' ')
                    [[ -z "$count" || ! "$count" =~ ^[0-9]+$ ]] && count=0
                else
                    count=0
                fi
                # Use index + PID for unique filename
                local tmp_file="$temp_dir/result_${idx}.$$"
                echo "$size $count" > "$tmp_file"
                mv "$tmp_file" "$temp_dir/result_${idx}" 2> /dev/null || true
            ) &
            pids+=($!)
            ((idx++))

            if ((${#pids[@]} >= MOLE_MAX_PARALLEL_JOBS)); then
                wait "${pids[0]}" 2> /dev/null || true
                pids=("${pids[@]:1}")
                ((completed++))
                # Update progress every 10 items for smoother display
                if [[ -t 1 ]] && ((completed % 10 == 0)); then
                    stop_inline_spinner
                    MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning items ($completed/$total_paths)..."
                fi
            fi
        done

        for pid in "${pids[@]}"; do
            wait "$pid" 2> /dev/null || true
            ((completed++))
        done

        # Read results using same index
        idx=0
        for path in "${existing_paths[@]}"; do
            local result_file="$temp_dir/result_${idx}"
            if [[ -f "$result_file" ]]; then
                read -r size count < "$result_file" 2> /dev/null || true
                if [[ "$count" -gt 0 && "$size" -gt 0 ]]; then
                    if [[ "$DRY_RUN" != "true" ]]; then
                        # Handle symbolic links separately (only remove the link, not the target)
                        if [[ -L "$path" ]]; then
                            rm "$path" 2> /dev/null || true
                        else
                            safe_remove "$path" true || true
                        fi
                    fi
                    ((total_size_bytes += size))
                    ((total_count += count))
                    removed_any=1
                fi
            fi
            ((idx++))
        done

        # Temp dir will be auto-cleaned by cleanup_temp_files
    else
        # Show progress for small batches too (simpler jobs)
        local total_paths=${#existing_paths[@]}
        if [[ -t 1 ]]; then MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning $total_paths items..."; fi

        for path in "${existing_paths[@]}"; do
            local size_bytes count
            # Get size quickly with depth limit
            size_bytes=$(get_path_size_kb "$path")
            [[ -z "$size_bytes" || ! "$size_bytes" =~ ^[0-9]+$ ]] && size_bytes=0
            # Quick file count for display - limit for performance
            if [[ "$size_bytes" -gt 0 ]]; then
                count=$(find "$path" -type f 2> /dev/null | head -1000 | wc -l | tr -d ' ')
                [[ -z "$count" || ! "$count" =~ ^[0-9]+$ ]] && count=0
            else
                count=0
            fi

            if [[ "$count" -gt 0 && "$size_bytes" -gt 0 ]]; then
                if [[ "$DRY_RUN" != "true" ]]; then
                    # Handle symbolic links separately (only remove the link, not the target)
                    if [[ -L "$path" ]]; then
                        rm "$path" 2> /dev/null || true
                    else
                        safe_remove "$path" true || true
                    fi
                fi
                ((total_size_bytes += size_bytes))
                ((total_count += count))
                removed_any=1
            fi
        done
    fi

    # Clear progress / stop spinner before showing result
    if [[ -t 1 ]]; then
        stop_inline_spinner
        echo -ne "\r\033[K"
    fi

    if [[ $removed_any -eq 1 ]]; then
        # Convert KB to bytes for bytes_to_human()
        local size_human=$(bytes_to_human "$((total_size_bytes * 1024))")

        local label="$description"
        if [[ ${#targets[@]} -gt 1 ]]; then
            label+=" ${#targets[@]} items"
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}→${NC} $label ${YELLOW}($size_human dry)${NC}"

            # Group paths by parent directory for export (Bash 3.2 compatible)
            local paths_temp=$(create_temp_file)

            idx=0
            for path in "${existing_paths[@]}"; do
                local size=0

                # Get size from result file if it exists (parallel processing with temp_dir)
                if [[ -n "${temp_dir:-}" && -f "$temp_dir/result_${idx}" ]]; then
                    read -r size count < "$temp_dir/result_${idx}" 2> /dev/null || true
                else
                    # Get size directly (small batch processing or no temp_dir)
                    size=$(get_path_size_kb "$path" 2> /dev/null || echo "0")
                fi

                [[ "$size" == "0" || -z "$size" ]] && {
                    ((idx++))
                    continue
                }

                # Write parent|size|path to temp file
                echo "$(dirname "$path")|$size|$path" >> "$paths_temp"
                ((idx++))
            done

            # Group and export paths
            if [[ -f "$paths_temp" && -s "$paths_temp" ]]; then
                # Sort by parent directory to group children together
                sort -t'|' -k1,1 "$paths_temp" | awk -F'|' '
                {
                    parent = $1
                    size = $2
                    path = $3

                    parent_size[parent] += size
                    if (parent_count[parent] == 0) {
                        parent_first[parent] = path
                    }
                    parent_count[parent]++
                }
                END {
                    for (parent in parent_size) {
                        if (parent_count[parent] > 1) {
                            printf "%s|%d|%d\n", parent, parent_size[parent], parent_count[parent]
                        } else {
                            printf "%s|%d|1\n", parent_first[parent], parent_size[parent]
                        }
                    }
                }
                ' | while IFS='|' read -r display_path total_size child_count; do
                    local size_human=$(bytes_to_human "$((total_size * 1024))")
                    if [[ $child_count -gt 1 ]]; then
                        echo "$display_path  # $size_human ($child_count items)" >> "$EXPORT_LIST_FILE"
                    else
                        echo "$display_path  # $size_human" >> "$EXPORT_LIST_FILE"
                    fi
                done

                rm -f "$paths_temp"
            fi
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $label ${GREEN}($size_human)${NC}"
        fi
        ((files_cleaned += total_count))
        ((total_size_cleaned += total_size_bytes))
        ((total_items++))
        note_activity
    fi

    return 0
}

start_cleanup() {
    clear
    printf '\n'
    echo -e "${PURPLE_BOLD}Clean Your Mac${NC}"
    echo ""

    debug_log "Starting cleanup process"
    debug_log "DRY_RUN=$DRY_RUN, SYSTEM_CLEAN=$SYSTEM_CLEAN"

    if [[ "$DRY_RUN" != "true" && -t 0 ]]; then
        echo -e "${YELLOW}☻${NC} First time? Run ${GRAY}mo clean --dry-run${NC} first to preview changes"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}Dry Run Mode${NC} - Preview only, no deletions"
        echo ""
        SYSTEM_CLEAN=false
        debug_log "Dry run mode enabled"

        # Initialize export list file
        mkdir -p "$(dirname "$EXPORT_LIST_FILE")"
        cat > "$EXPORT_LIST_FILE" << EOF
# Mole Cleanup Preview - $(date '+%Y-%m-%d %H:%M:%S')
#
# How to protect files:
# 1. Copy any path below to ~/.config/mole/whitelist
# 2. Run: mo clean --whitelist
#
# Example:
#   /Users/*/Library/Caches/com.example.app
#

EOF
        return
    fi

    if [[ -t 0 ]]; then
        echo -ne "${PURPLE}${ICON_ARROW}${NC} System caches need sudo — ${GREEN}Enter${NC} continue, ${GRAY}Space${NC} skip: "

        # Use read_key to properly handle all key inputs
        local choice
        choice=$(read_key)

        # Check for cancel (ESC or Q)
        if [[ "$choice" == "QUIT" ]]; then
            echo -e " ${GRAY}Cancelled${NC}"
            exit 0
        fi

        # Space = skip
        if [[ "$choice" == "SPACE" ]]; then
            echo -e " ${GRAY}Skipped${NC}"
            echo ""
            SYSTEM_CLEAN=false
        # Enter = yes, do system cleanup
        elif [[ "$choice" == "ENTER" ]]; then
            printf "\r\033[K" # Clear the prompt line
            if ensure_sudo_session "System cleanup requires admin access"; then
                SYSTEM_CLEAN=true
                echo -e "${GREEN}${ICON_SUCCESS}${NC} Admin access granted"
                echo ""
            else
                SYSTEM_CLEAN=false
                echo ""
                echo -e "${YELLOW}Authentication failed${NC}, continuing with user-level cleanup"
            fi
        else
            # Other keys (including arrow keys) = skip, no message needed
            SYSTEM_CLEAN=false
        fi
    else
        SYSTEM_CLEAN=false
        echo ""
        echo "Running in non-interactive mode"
        echo "  • System-level cleanup skipped (requires interaction)"
        echo "  • User-level cleanup will proceed automatically"
        echo ""
    fi
}

# Clean Service Worker CacheStorage with domain protection

perform_cleanup() {
    echo -e "${BLUE}${ICON_ADMIN}${NC} $(detect_architecture) | Free space: $(get_free_space)"

    debug_log "Whitelist patterns loaded: ${#WHITELIST_PATTERNS[@]}"
    if [[ "${MO_DEBUG:-}" == "1" && ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        for pattern in "${WHITELIST_PATTERNS[@]}"; do
            debug_log "  Whitelist: $pattern"
        done
    fi

    # Pre-check TCC permissions upfront (delegated to clean_caches module)
    check_tcc_permissions

    # Show whitelist info if patterns are active
    if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        # Count predefined vs custom patterns
        local predefined_count=0
        local custom_count=0

        for pattern in "${WHITELIST_PATTERNS[@]}"; do
            local is_predefined=false
            for default in "${DEFAULT_WHITELIST_PATTERNS[@]}"; do
                if [[ "$pattern" == "$default" ]]; then
                    is_predefined=true
                    break
                fi
            done

            if [[ "$is_predefined" == "true" ]]; then
                ((predefined_count++))
            else
                ((custom_count++))
            fi
        done

        # Display whitelist status
        if [[ $custom_count -gt 0 && $predefined_count -gt 0 ]]; then
            echo -e "${BLUE}${ICON_SUCCESS}${NC} Whitelist: $predefined_count core + $custom_count custom patterns active"
        elif [[ $custom_count -gt 0 ]]; then
            echo -e "${BLUE}${ICON_SUCCESS}${NC} Whitelist: $custom_count custom patterns active"
        elif [[ $predefined_count -gt 0 ]]; then
            echo -e "${BLUE}${ICON_SUCCESS}${NC} Whitelist: $predefined_count core patterns active"
        fi
    fi

    # Initialize counters
    total_items=0
    files_cleaned=0
    total_size_cleaned=0

    # ===== 1. Deep system cleanup (if admin) - Do this first while sudo is fresh =====
    if [[ "$SYSTEM_CLEAN" == "true" ]]; then
        start_section "Deep system"
        # Deep system cleanup (delegated to clean_system module)
        clean_deep_system
        end_section
    fi

    # Show whitelist warnings if any
    if [[ ${#WHITELIST_WARNINGS[@]} -gt 0 ]]; then
        echo ""
        for warning in "${WHITELIST_WARNINGS[@]}"; do
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Whitelist: $warning"
        done
    fi

    # ===== 2. User essentials =====
    start_section "User essentials"
    # User essentials cleanup (delegated to clean_user_data module)
    clean_user_essentials
    end_section

    start_section "Finder metadata"
    # Finder metadata cleanup (delegated to clean_user_data module)
    clean_finder_metadata
    end_section

    # ===== 3. macOS system caches =====
    start_section "macOS system caches"
    # macOS system caches cleanup (delegated to clean_user_data module)
    clean_macos_system_caches
    end_section

    # ===== 4. Sandboxed app caches =====
    start_section "Sandboxed app caches"
    # Sandboxed app caches cleanup (delegated to clean_user_data module)
    clean_sandboxed_app_caches
    end_section

    # ===== 5. Browsers =====
    start_section "Browsers"
    # Browser caches cleanup (delegated to clean_user_data module)
    clean_browsers
    end_section

    # ===== 6. Cloud storage =====
    start_section "Cloud storage"
    # Cloud storage caches cleanup (delegated to clean_user_data module)
    clean_cloud_storage
    end_section

    # ===== 7. Office applications =====
    start_section "Office applications"
    # Office applications cleanup (delegated to clean_user_data module)
    clean_office_applications
    end_section

    # ===== 8. Developer tools =====
    start_section "Developer tools"
    # Developer tools cleanup (delegated to clean_dev module)
    clean_developer_tools
    end_section

    # ===== 9. Development applications =====
    start_section "Development applications"
    # User GUI applications cleanup (delegated to clean_user_apps module)
    clean_user_gui_applications
    end_section

    # ===== 10. Virtualization tools =====
    start_section "Virtual machine tools"
    # Virtualization tools cleanup (delegated to clean_user_data module)
    clean_virtualization_tools
    end_section

    # ===== 11. Application Support logs and caches cleanup =====
    start_section "Application Support"
    # Clean logs, Service Worker caches, Code Cache, Crashpad, stale updates, Group Containers
    clean_application_support_logs
    end_section

    # ===== 12. Orphaned app data cleanup =====
    # Only touch apps missing from scan + 60+ days inactive
    # Skip protected vendors, keep Preferences/Application Support
    start_section "Uninstalled app data"

    # Check if we have permission to access Library folders
    # Use simple ls test instead of find to avoid hanging
    local has_library_access=true
    if ! ls "$HOME/Library/Caches" > /dev/null 2>&1; then
        has_library_access=false
    fi

    if [[ "$has_library_access" == "false" ]]; then
        note_activity
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Skipped: No permission to access Library folders"
        echo -e "  ${GRAY}Tip: Grant 'Full Disk Access' to iTerm2/Terminal in System Settings${NC}"
    else

        local -r ORPHAN_AGE_THRESHOLD=60 # 60 days - good balance between safety and cleanup

        # Build list of installed application bundle identifiers
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning installed applications..."
        local installed_bundles=$(create_temp_file)

        # Simplified: only scan primary locations (reduces scan time by ~70%)
        local -a search_paths=(
            "/Applications"
            "$HOME/Applications"
        )

        # Scan for .app bundles - optimized with PlistBuddy and xargs
        for search_path in "${search_paths[@]}"; do
            [[ -d "$search_path" ]] || continue
            find "$search_path" -maxdepth 3 -name "Info.plist" -path "*/Contents/Info.plist" 2> /dev/null |
                xargs -I {} /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" {} 2> /dev/null |
                grep -v "^$" >> "$installed_bundles" || true
        done

        # Get running applications - timeout protection for osascript
        run_with_timeout 5 osascript -e 'tell application "System Events" to get bundle identifier of every application process' 2> /dev/null |
            tr ',' '\n' | sed -e 's/^ *//;s/ *$//' -e '/^$/d' >> "$installed_bundles" || true

        # Get LaunchAgents
        find ~/Library/LaunchAgents /Library/LaunchAgents -name "*.plist" -type f 2> /dev/null |
            xargs -I {} basename {} .plist >> "$installed_bundles" 2> /dev/null || true

        # Deduplicate
        sort -u "$installed_bundles" -o "$installed_bundles"

        local app_count=$(wc -l < "$installed_bundles" 2> /dev/null | tr -d ' ')
        stop_inline_spinner
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Found $app_count active/installed apps"

        # Track statistics
        local orphaned_count=0
        local total_orphaned_kb=0

        # Check if bundle is orphaned - conservative approach
        is_orphaned() {
            local bundle_id="$1"
            local directory_path="$2"

            # Skip system-critical and protected apps
            if should_protect_data "$bundle_id"; then
                return 1
            fi

            # Check if app exists in our scan
            if grep -q "^$bundle_id$" "$installed_bundles" 2> /dev/null; then
                return 1
            fi

            # Extra check for system bundles
            case "$bundle_id" in
                com.apple.* | loginwindow | dock | systempreferences | finder | safari)
                    return 1
                    ;;
            esac

            # Skip major vendors
            case "$bundle_id" in
                com.adobe.* | com.microsoft.* | com.google.* | org.mozilla.* | com.jetbrains.* | com.docker.*)
                    return 1
                    ;;
            esac

            # Check file age - only clean if 60+ days inactive
            # Use modification time (mtime) instead of access time (atime)
            # because macOS disables atime updates by default for performance
            if [[ -e "$directory_path" ]]; then
                local last_modified_epoch=$(get_file_mtime "$directory_path")
                local current_epoch=$(date +%s)
                local days_since_modified=$(((current_epoch - last_modified_epoch) / 86400))

                if [[ $days_since_modified -lt $ORPHAN_AGE_THRESHOLD ]]; then
                    return 1
                fi
            fi

            return 0
        }

        # Unified orphaned resource scanner (caches, logs, states, webkit, HTTP, cookies)
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning orphaned app resources..."

        # Define resource types to scan
        # CRITICAL: NEVER add LaunchAgents or LaunchDaemons (breaks login items/startup apps)
        local -a resource_types=(
            "$HOME/Library/Caches|Caches|com.*:org.*:net.*:io.*"
            "$HOME/Library/Logs|Logs|com.*:org.*:net.*:io.*"
            "$HOME/Library/Saved Application State|States|*.savedState"
            "$HOME/Library/WebKit|WebKit|com.*:org.*:net.*:io.*"
            "$HOME/Library/HTTPStorages|HTTP|com.*:org.*:net.*:io.*"
            "$HOME/Library/Cookies|Cookies|*.binarycookies"
        )

        orphaned_count=0

        for resource_type in "${resource_types[@]}"; do
            IFS='|' read -r base_path label patterns <<< "$resource_type"

            # Check both existence and permission to avoid hanging
            if [[ ! -d "$base_path" ]]; then
                continue
            fi

            # Quick permission check - if we can't ls the directory, skip it
            if ! ls "$base_path" > /dev/null 2>&1; then
                continue
            fi

            # Build file pattern array
            local -a file_patterns=()
            IFS=':' read -ra pattern_arr <<< "$patterns"
            for pat in "${pattern_arr[@]}"; do
                file_patterns+=("$base_path/$pat")
            done

            # Scan and clean orphaned items
            for item_path in "${file_patterns[@]}"; do
                # Use shell glob (no ls needed)
                # Limit iterations to prevent hanging on directories with too many files
                local iteration_count=0
                local max_iterations=100

                for match in $item_path; do
                    [[ -e "$match" ]] || continue

                    # Safety: limit iterations to prevent infinite loops on massive directories
                    ((iteration_count++))
                    if [[ $iteration_count -gt $max_iterations ]]; then
                        break
                    fi

                    # Extract bundle ID from filename
                    local bundle_id=$(basename "$match")
                    bundle_id="${bundle_id%.savedState}"
                    bundle_id="${bundle_id%.binarycookies}"

                    if is_orphaned "$bundle_id" "$match"; then
                        # Use timeout to prevent du from hanging on large/problematic directories
                        local size_kb
                        size_kb=$(run_with_timeout 2 du -sk "$match" 2> /dev/null | awk '{print $1}' || echo "0")
                        if [[ -z "$size_kb" || "$size_kb" == "0" ]]; then
                            continue
                        fi
                        safe_clean "$match" "Orphaned $label: $bundle_id"
                        ((orphaned_count++))
                        ((total_orphaned_kb += size_kb))
                    fi
                done
            done
        done

        stop_inline_spinner

        if [[ $orphaned_count -gt 0 ]]; then
            local orphaned_mb=$(echo "$total_orphaned_kb" | awk '{printf "%.1f", $1/1024}')
            echo "  ${GREEN}${ICON_SUCCESS}${NC} Cleaned $orphaned_count items (~${orphaned_mb}MB)"
            note_activity
        fi

        rm -f "$installed_bundles"

    fi # end of has_library_access check

    end_section

    # ===== 13. Apple Silicon optimizations =====
    if [[ "$IS_M_SERIES" == "true" ]]; then
        start_section "Apple Silicon updates"
        safe_clean /Library/Apple/usr/share/rosetta/rosetta_update_bundle "Rosetta 2 cache"
        safe_clean ~/Library/Caches/com.apple.rosetta.update "Rosetta 2 user cache"
        safe_clean ~/Library/Caches/com.apple.amp.mediasevicesd "Apple Silicon media service cache"
        # Skip: iCloud sync cache, may affect device pairing
        # safe_clean ~/Library/Caches/com.apple.bird.lsuseractivity "User activity cache"
        end_section
    fi

    # ===== 14. iOS device backups =====
    start_section "iOS device backups"
    # iOS device backups check (delegated to clean_user_data module)
    check_ios_device_backups
    end_section

    # ===== 15. Time Machine failed backups =====
    start_section "Time Machine failed backups"
    # Time Machine failed backups cleanup (delegated to clean_system module)
    clean_time_machine_failed_backups
    end_section

    # ===== 16. System maintenance =====
    start_section "System maintenance"
    # Broken preferences and login items cleanup (delegated to clean_maintenance module)
    clean_maintenance
    end_section

    # ===== Final summary =====
    echo ""

    local summary_heading=""
    local summary_status="success"
    if [[ "$DRY_RUN" == "true" ]]; then
        summary_heading="Dry run complete - no changes made"
    else
        summary_heading="Cleanup complete"
    fi

    local -a summary_details=()

    if [[ $total_size_cleaned -gt 0 ]]; then
        local freed_gb
        freed_gb=$(echo "$total_size_cleaned" | awk '{printf "%.2f", $1/1024/1024}')

        if [[ "$DRY_RUN" == "true" ]]; then
            # Build compact stats line for dry run
            local stats="Potential space: ${GREEN}${freed_gb}GB${NC}"
            [[ $files_cleaned -gt 0 ]] && stats+=" | Files: $files_cleaned"
            [[ $total_items -gt 0 ]] && stats+=" | Categories: $total_items"
            [[ $whitelist_skipped_count -gt 0 ]] && stats+=" | Protected: $whitelist_skipped_count"
            summary_details+=("$stats")

            # Add summary to export file
            {
                echo ""
                echo "# ============================================"
                echo "# Summary"
                echo "# ============================================"
                echo "# Potential cleanup: ${freed_gb}GB"
                echo "# Files: $files_cleaned"
                echo "# Categories: $total_items"
                [[ $whitelist_skipped_count -gt 0 ]] && echo "# Protected by whitelist: $whitelist_skipped_count"
            } >> "$EXPORT_LIST_FILE"

            summary_details+=("Detailed file list: ${GRAY}$EXPORT_LIST_FILE${NC}")
            summary_details+=("Use ${GRAY}mo clean --whitelist${NC} to add protection rules")
        else
            summary_details+=("Space freed: ${GREEN}${freed_gb}GB${NC}")
            summary_details+=("Free space now: $(get_free_space)")

            if [[ $files_cleaned -gt 0 && $total_items -gt 0 ]]; then
                local stats="Files cleaned: $files_cleaned | Categories: $total_items"
                [[ $whitelist_skipped_count -gt 0 ]] && stats+=" | Protected: $whitelist_skipped_count"
                summary_details+=("$stats")
            elif [[ $files_cleaned -gt 0 ]]; then
                local stats="Files cleaned: $files_cleaned"
                [[ $whitelist_skipped_count -gt 0 ]] && stats+=" | Protected: $whitelist_skipped_count"
                summary_details+=("$stats")
            elif [[ $total_items -gt 0 ]]; then
                local stats="Categories: $total_items"
                [[ $whitelist_skipped_count -gt 0 ]] && stats+=" | Protected: $whitelist_skipped_count"
                summary_details+=("$stats")
            fi

            if [[ $(echo "$freed_gb" | awk '{print ($1 >= 1) ? 1 : 0}') -eq 1 ]]; then
                local movies
                movies=$(echo "$freed_gb" | awk '{printf "%.0f", $1/4.5}')
                if [[ $movies -gt 0 ]]; then
                    summary_details+=("Equivalent to ~$movies 4K movies of storage.")
                fi
            fi
        fi
    else
        summary_status="info"
        if [[ "$DRY_RUN" == "true" ]]; then
            summary_details+=("No significant reclaimable space detected (system already clean).")
        else
            summary_details+=("System was already clean; no additional space freed.")
        fi
        summary_details+=("Free space now: $(get_free_space)")
    fi

    print_summary_block "$summary_status" "$summary_heading" "${summary_details[@]}"
    printf '\n'
}

main() {
    # Parse args (only dry-run and whitelist)
    for arg in "$@"; do
        case "$arg" in
            "--dry-run" | "-n")
                DRY_RUN=true
                ;;
            "--whitelist")
                source "$SCRIPT_DIR/../lib/manage/whitelist.sh"
                manage_whitelist
                exit 0
                ;;
        esac
    done

    start_cleanup
    hide_cursor
    perform_cleanup
    show_cursor
}

main "$@"
