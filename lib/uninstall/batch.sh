#!/bin/bash

set -euo pipefail

# Ensure common.sh is loaded
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -z "${MOLE_COMMON_LOADED:-}" ]] && source "$SCRIPT_DIR/lib/core/common.sh"

# Batch uninstall functionality with minimal confirmations
# Replaces the overly verbose individual confirmation approach

# Decode and validate base64 encoded file list
# Returns decoded string if valid, empty string otherwise
decode_file_list() {
    local encoded="$1"
    local app_name="$2"
    local decoded

    # Decode base64 data
    if ! decoded=$(printf '%s' "$encoded" | base64 -d 2> /dev/null); then
        log_error "Failed to decode file list for $app_name"
        echo ""
        return 1
    fi

    # Validate decoded data doesn't contain null bytes
    if [[ "$decoded" =~ $'\0' ]]; then
        log_warning "File list for $app_name contains null bytes, rejecting"
        echo ""
        return 1
    fi

    # Validate paths look reasonable (each line should be a path or empty)
    while IFS= read -r line; do
        if [[ -n "$line" && ! "$line" =~ ^/ ]]; then
            log_warning "Invalid path in file list for $app_name: $line"
            echo ""
            return 1
        fi
    done <<< "$decoded"

    echo "$decoded"
    return 0
}
# Note: find_app_files() and calculate_total_size() functions now in lib/core/common.sh

# Stop Launch Agents and Daemons for an app
# Args: $1 = bundle_id, $2 = has_system_files (true/false)
stop_launch_services() {
    local bundle_id="$1"
    local has_system_files="${2:-false}"

    # User-level Launch Agents
    for plist in ~/Library/LaunchAgents/"$bundle_id"*.plist; do
        [[ -f "$plist" ]] && launchctl unload "$plist" 2> /dev/null || true
    done

    # System-level services (requires sudo)
    if [[ "$has_system_files" == "true" ]]; then
        for plist in /Library/LaunchAgents/"$bundle_id"*.plist; do
            [[ -f "$plist" ]] && sudo launchctl unload "$plist" 2> /dev/null || true
        done
        for plist in /Library/LaunchDaemons/"$bundle_id"*.plist; do
            [[ -f "$plist" ]] && sudo launchctl unload "$plist" 2> /dev/null || true
        done
    fi
}

# Remove a list of files (handles both regular files and symlinks)
# Args: $1 = file_list (newline-separated), $2 = use_sudo (true/false)
# Returns: number of files removed
remove_file_list() {
    local file_list="$1"
    local use_sudo="${2:-false}"
    local count=0

    while IFS= read -r file; do
        [[ -n "$file" && -e "$file" ]] || continue

        if [[ -L "$file" ]]; then
            # Symlink: use direct rm
            if [[ "$use_sudo" == "true" ]]; then
                sudo rm "$file" 2> /dev/null && ((count++)) || true
            else
                rm "$file" 2> /dev/null && ((count++)) || true
            fi
        else
            # Regular file/directory: use safe_remove
            if [[ "$use_sudo" == "true" ]]; then
                safe_sudo_remove "$file" && ((count++)) || true
            else
                safe_remove "$file" true && ((count++)) || true
            fi
        fi
    done <<< "$file_list"

    echo "$count"
}

# Batch uninstall with single confirmation
batch_uninstall_applications() {
    local total_size_freed=0

    if [[ ${#selected_apps[@]} -eq 0 ]]; then
        log_warning "No applications selected for uninstallation"
        return 0
    fi

    # Pre-process: Check for running apps and calculate total impact
    local -a running_apps=()
    local -a sudo_apps=()
    local total_estimated_size=0
    local -a app_details=()
    local -a dock_cleanup_paths=()

    # Silent analysis without spinner output (avoid visual flicker)
    for selected_app in "${selected_apps[@]}"; do
        [[ -z "$selected_app" ]] && continue
        IFS='|' read -r _ app_path app_name bundle_id _ _ <<< "$selected_app"

        # Check if app is running (use app path for precise matching)
        if pgrep -f "$app_path" > /dev/null 2>&1; then
            running_apps+=("$app_name")
        fi

        # Check if app requires sudo to delete
        if [[ ! -w "$(dirname "$app_path")" ]] || [[ "$(get_file_owner "$app_path")" == "root" ]]; then
            sudo_apps+=("$app_name")
        fi

        # Calculate size for summary (including system files)
        local app_size_kb=$(du -sk "$app_path" 2> /dev/null | awk '{print $1}' || echo "0")
        local related_files=$(find_app_files "$bundle_id" "$app_name")
        local related_size_kb=$(calculate_total_size "$related_files")
        local system_files=$(find_app_system_files "$bundle_id" "$app_name")
        local system_size_kb=$(calculate_total_size "$system_files")
        local total_kb=$((app_size_kb + related_size_kb + system_size_kb))
        ((total_estimated_size += total_kb))

        # Check if system files require sudo
        if [[ -n "$system_files" ]]; then
            sudo_apps+=("$app_name")
        fi

        # Store details for later use
        # Base64 encode file lists to handle multi-line data safely (single line)
        local encoded_files
        encoded_files=$(printf '%s' "$related_files" | base64 | tr -d '\n')
        local encoded_system_files
        encoded_system_files=$(printf '%s' "$system_files" | base64 | tr -d '\n')
        app_details+=("$app_name|$app_path|$bundle_id|$total_kb|$encoded_files|$encoded_system_files")
    done

    # Format size display (convert KB to bytes for bytes_to_human())
    local size_display=$(bytes_to_human "$((total_estimated_size * 1024))")

    # Display detailed file list for each app before confirmation
    echo ""
    echo -e "${PURPLE}Files to be removed:${NC}"
    echo ""
    for detail in "${app_details[@]}"; do
        IFS='|' read -r app_name app_path bundle_id total_kb encoded_files encoded_system_files <<< "$detail"
        local related_files=$(decode_file_list "$encoded_files" "$app_name")
        local system_files=$(decode_file_list "$encoded_system_files" "$app_name")
        local app_size_display=$(bytes_to_human "$((total_kb * 1024))")

        echo -e "${BLUE}${ICON_CONFIRM}${NC} ${app_name} ${GRAY}(${app_size_display})${NC}"
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $(echo "$app_path" | sed "s|$HOME|~|")"

        # Show related files (limit to 5 most important ones for brevity)
        local file_count=0
        local max_files=5
        while IFS= read -r file; do
            if [[ -n "$file" && -e "$file" ]]; then
                if [[ $file_count -lt $max_files ]]; then
                    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $(echo "$file" | sed "s|$HOME|~|")"
                fi
                ((file_count++))
            fi
        done <<< "$related_files"

        # Show system files
        local sys_file_count=0
        while IFS= read -r file; do
            if [[ -n "$file" && -e "$file" ]]; then
                if [[ $sys_file_count -lt $max_files ]]; then
                    echo -e "  ${BLUE}${ICON_SOLID}${NC} System: $file"
                fi
                ((sys_file_count++))
            fi
        done <<< "$system_files"

        # Show count of remaining files if truncated
        local total_hidden=$((file_count > max_files ? file_count - max_files : 0))
        ((total_hidden += sys_file_count > max_files ? sys_file_count - max_files : 0))
        if [[ $total_hidden -gt 0 ]]; then
            echo -e "  ${GRAY}  ... and ${total_hidden} more files${NC}"
        fi
    done

    # Show summary and get batch confirmation first (before asking for password)
    local app_total=${#selected_apps[@]}
    local app_text="app"
    [[ $app_total -gt 1 ]] && app_text="apps"

    echo ""
    local removal_note="Remove ${app_total} ${app_text}"
    [[ -n "$size_display" ]] && removal_note+=" (${size_display})"
    if [[ ${#running_apps[@]} -gt 0 ]]; then
        removal_note+=" ${YELLOW}[Running]${NC}"
    fi
    echo -ne "${PURPLE}${ICON_ARROW}${NC} ${removal_note}  ${GREEN}Enter${NC} confirm, ${GRAY}ESC${NC} cancel: "

    drain_pending_input # Clean up any pending input before confirmation
    IFS= read -r -s -n1 key || key=""
    drain_pending_input # Clean up any escape sequence remnants
    case "$key" in
        $'\e' | q | Q)
            echo ""
            echo ""
            return 0
            ;;
        "" | $'\n' | $'\r' | y | Y)
            printf "\r\033[K" # Clear the prompt line
            ;;
        *)
            echo ""
            echo ""
            return 0
            ;;
    esac

    # User confirmed, now request sudo access if needed
    if [[ ${#sudo_apps[@]} -gt 0 ]]; then
        # Check if sudo is already cached
        if ! sudo -n true 2> /dev/null; then
            if ! request_sudo_access "Admin required for system apps: ${sudo_apps[*]}"; then
                echo ""
                log_error "Admin access denied"
                return 1
            fi
        fi
        # Start sudo keepalive with robust parent checking
        parent_pid=$$
        (while true; do
            # Check if parent process still exists first
            if ! kill -0 "$parent_pid" 2> /dev/null; then
                exit 0
            fi
            sudo -n true
            sleep 60
        done 2> /dev/null) &
        sudo_keepalive_pid=$!
    fi

    if [[ -t 1 ]]; then start_inline_spinner "Uninstalling apps..."; fi

    # Force quit running apps first (batch)
    # Note: Apps are already killed in the individual uninstall loop below with app_path for precise matching

    # Perform uninstallations (silent mode, show results at end)
    if [[ -t 1 ]]; then stop_inline_spinner; fi
    local success_count=0 failed_count=0
    local -a failed_items=()
    local -a success_items=()
    for detail in "${app_details[@]}"; do
        IFS='|' read -r app_name app_path bundle_id total_kb encoded_files encoded_system_files <<< "$detail"
        local related_files=$(decode_file_list "$encoded_files" "$app_name")
        local system_files=$(decode_file_list "$encoded_system_files" "$app_name")
        local reason=""
        local needs_sudo=false
        [[ ! -w "$(dirname "$app_path")" || "$(get_file_owner "$app_path")" == "root" ]] && needs_sudo=true

        # Stop Launch Agents and Daemons before removal
        local has_system_files="false"
        [[ -n "$system_files" ]] && has_system_files="true"
        stop_launch_services "$bundle_id" "$has_system_files"

        # Force quit app if still running
        if ! force_kill_app "$app_name" "$app_path"; then
            reason="still running"
        fi

        # Remove the application
        if [[ -z "$reason" ]]; then
            if [[ "$needs_sudo" == true ]]; then
                safe_sudo_remove "$app_path" || reason="remove failed"
            else
                safe_remove "$app_path" true || reason="remove failed"
            fi
        fi

        # Remove user-level and system-level files
        if [[ -z "$reason" ]]; then
            # Remove user-level files
            remove_file_list "$related_files" "false" > /dev/null
            # Remove system-level files (requires sudo)
            remove_file_list "$system_files" "true" > /dev/null

            ((total_size_freed += total_kb))
            ((success_count++))
            ((files_cleaned++))
            ((total_items++))
            success_items+=("$app_name")
            dock_cleanup_paths+=("$app_path")
        else
            ((failed_count++))
            failed_items+=("$app_name:$reason")
        fi
    done

    # Summary
    local freed_display
    freed_display=$(bytes_to_human "$((total_size_freed * 1024))")

    local summary_status="success"
    local -a summary_details=()

    if [[ $success_count -gt 0 ]]; then
        local success_list="${success_items[*]}"
        local success_text="app"
        [[ $success_count -gt 1 ]] && success_text="apps"
        local success_line="Removed ${success_count} ${success_text}"
        if [[ -n "$freed_display" ]]; then
            success_line+=", freed ${GREEN}${freed_display}${NC}"
        fi

        # Format app list with max 3 per line
        if [[ -n "$success_list" ]]; then
            local idx=0
            local is_first_line=true
            local current_line=""

            for app_name in "${success_items[@]}"; do
                local display_item="${GREEN}${app_name}${NC}"

                if ((idx % 3 == 0)); then
                    # Start new line
                    if [[ -n "$current_line" ]]; then
                        summary_details+=("$current_line")
                    fi
                    if [[ "$is_first_line" == true ]]; then
                        # First line: append to success_line
                        current_line="${success_line}: $display_item"
                        is_first_line=false
                    else
                        # Subsequent lines: just the apps
                        current_line="$display_item"
                    fi
                else
                    # Add to current line
                    current_line="$current_line, $display_item"
                fi
                ((idx++))
            done
            # Add the last line
            if [[ -n "$current_line" ]]; then
                summary_details+=("$current_line")
            fi
        else
            summary_details+=("$success_line")
        fi
    fi

    if [[ $failed_count -gt 0 ]]; then
        summary_status="warn"

        local failed_names=()
        for item in "${failed_items[@]}"; do
            local name=${item%%:*}
            failed_names+=("$name")
        done
        local failed_list="${failed_names[*]}"

        local reason_summary="could not be removed"
        if [[ $failed_count -eq 1 ]]; then
            local first_reason=${failed_items[0]#*:}
            case "$first_reason" in
                still*running*) reason_summary="is still running" ;;
                remove*failed*) reason_summary="could not be removed" ;;
                permission*) reason_summary="permission denied" ;;
                *) reason_summary="$first_reason" ;;
            esac
        fi
        summary_details+=("Failed: ${RED}${failed_list}${NC} ${reason_summary}")
    fi

    if [[ $success_count -eq 0 && $failed_count -eq 0 ]]; then
        summary_status="info"
        summary_details+=("No applications were uninstalled.")
    fi

    print_summary_block "$summary_status" "Uninstall complete" "${summary_details[@]}"
    printf '\n'

    if [[ ${#dock_cleanup_paths[@]} -gt 0 ]]; then
        remove_apps_from_dock "${dock_cleanup_paths[@]}"
    fi

    # Clean up sudo keepalive if it was started
    if [[ -n "${sudo_keepalive_pid:-}" ]]; then
        kill "$sudo_keepalive_pid" 2> /dev/null || true
        wait "$sudo_keepalive_pid" 2> /dev/null || true
        sudo_keepalive_pid=""
    fi

    # Invalidate cache if any apps were successfully uninstalled
    if [[ $success_count -gt 0 ]]; then
        local cache_file="$HOME/.cache/mole/app_scan_cache"
        rm -f "$cache_file" 2> /dev/null || true
    fi

    ((total_size_cleaned += total_size_freed))
    unset failed_items
}
