#!/bin/bash
# User Data Cleanup Module

set -euo pipefail

# Clean user essentials (caches, logs, trash, crash reports)
clean_user_essentials() {
    safe_clean ~/Library/Caches/* "User app cache"
    safe_clean ~/Library/Logs/* "User app logs"
    safe_clean ~/.Trash/* "Trash"

    # Empty trash on mounted volumes
    if [[ -d "/Volumes" ]]; then
        for volume in /Volumes/*; do
            [[ -d "$volume" && -d "$volume/.Trashes" && -w "$volume" ]] || continue

            # Skip network volumes
            local fs_type=$(command df -T "$volume" 2> /dev/null | tail -1 | awk '{print $2}')
            case "$fs_type" in
                nfs | smbfs | afpfs | cifs | webdav) continue ;;
            esac

            # Verify volume is mounted and not a symlink
            mount | grep -q "on $volume " || continue
            [[ -L "$volume/.Trashes" ]] && continue
            [[ "$DRY_RUN" == "true" ]] && continue

            # Safely iterate and remove each item
            while IFS= read -r -d '' item; do
                safe_remove "$item" true || true
            done < <(command find "$volume/.Trashes" -mindepth 1 -maxdepth 1 -print0 2> /dev/null || true)
        done
    fi

    safe_clean ~/Library/DiagnosticReports/* "Diagnostic reports"
    safe_clean ~/Library/Caches/com.apple.QuickLook.thumbnailcache "QuickLook thumbnails"
    safe_clean ~/Library/Caches/Quick\ Look/* "QuickLook cache"
    safe_clean ~/Library/Caches/com.apple.iconservices* "Icon services cache"
    safe_clean ~/Library/Caches/CloudKit/* "CloudKit cache"

    # Clean incomplete downloads
    safe_clean ~/Downloads/*.download "Incomplete downloads (Safari)"
    safe_clean ~/Downloads/*.crdownload "Incomplete downloads (Chrome)"
    safe_clean ~/Downloads/*.part "Incomplete downloads (partial)"

    # Additional user-level caches
    safe_clean ~/Library/Autosave\ Information/* "Autosave information"
    safe_clean ~/Library/IdentityCaches/* "Identity caches"
    safe_clean ~/Library/Suggestions/* "Suggestions cache (Siri)"
    safe_clean ~/Library/Calendars/Calendar\ Cache "Calendar cache"
    safe_clean ~/Library/Application\ Support/AddressBook/Sources/*/Photos.cache "Address Book photo cache"
}

# Clean Finder metadata (.DS_Store files)
clean_finder_metadata() {
    if [[ "$PROTECT_FINDER_METADATA" == "true" ]]; then
        note_activity
        echo -e "  ${GRAY}${ICON_SUCCESS}${NC} Finder metadata (whitelisted)"
    else
        clean_ds_store_tree "$HOME" "Home directory (.DS_Store)"

        if [[ -d "/Volumes" ]]; then
            for volume in /Volumes/*; do
                [[ -d "$volume" && -w "$volume" ]] || continue

                local fs_type=""
                fs_type=$(command df -T "$volume" 2> /dev/null | tail -1 | awk '{print $2}')
                case "$fs_type" in
                    nfs | smbfs | afpfs | cifs | webdav) continue ;;
                esac

                clean_ds_store_tree "$volume" "$(basename "$volume") volume (.DS_Store)"
            done
        fi
    fi
}

# Clean macOS system caches
clean_macos_system_caches() {
    safe_clean ~/Library/Saved\ Application\ State/* "Saved application states"
    safe_clean ~/Library/Caches/com.apple.spotlight "Spotlight cache"
    safe_clean ~/Library/Caches/com.apple.photoanalysisd "Photo analysis cache"
    safe_clean ~/Library/Caches/com.apple.akd "Apple ID cache"
    safe_clean ~/Library/Caches/com.apple.Safari/Webpage\ Previews/* "Safari webpage previews"
    safe_clean ~/Library/Application\ Support/CloudDocs/session/db/* "iCloud session cache"
    safe_clean ~/Library/Caches/com.apple.Safari/fsCachedData/* "Safari cached data"
    safe_clean ~/Library/Caches/com.apple.WebKit.WebContent/* "WebKit content cache"
    safe_clean ~/Library/Caches/com.apple.WebKit.Networking/* "WebKit network cache"
}

# Clean sandboxed app caches
clean_sandboxed_app_caches() {
    safe_clean ~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/* "Wallpaper agent cache"
    safe_clean ~/Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches/* "Media analysis cache"
    safe_clean ~/Library/Containers/com.apple.AppStore/Data/Library/Caches/* "App Store cache"
    safe_clean ~/Library/Containers/com.apple.configurator.xpc.InternetService/Data/tmp/* "Apple Configurator temp files"
    safe_clean ~/Library/Containers/*/Data/Library/Caches/* "Sandboxed app caches"
}

# Clean browser caches (Safari, Chrome, Edge, Firefox, etc.)
clean_browsers() {
    safe_clean ~/Library/Caches/com.apple.Safari/* "Safari cache"

    # Chrome/Chromium
    safe_clean ~/Library/Caches/Google/Chrome/* "Chrome cache"
    safe_clean ~/Library/Application\ Support/Google/Chrome/*/Application\ Cache/* "Chrome app cache"
    safe_clean ~/Library/Application\ Support/Google/Chrome/*/GPUCache/* "Chrome GPU cache"
    safe_clean ~/Library/Caches/Chromium/* "Chromium cache"

    safe_clean ~/Library/Caches/com.microsoft.edgemac/* "Edge cache"
    safe_clean ~/Library/Caches/company.thebrowser.Browser/* "Arc cache"
    safe_clean ~/Library/Caches/company.thebrowser.dia/* "Dia cache"
    safe_clean ~/Library/Caches/BraveSoftware/Brave-Browser/* "Brave cache"
    safe_clean ~/Library/Caches/Firefox/* "Firefox cache"
    safe_clean ~/Library/Caches/com.operasoftware.Opera/* "Opera cache"
    safe_clean ~/Library/Caches/com.vivaldi.Vivaldi/* "Vivaldi cache"
    safe_clean ~/Library/Caches/Comet/* "Comet cache"
    safe_clean ~/Library/Caches/com.kagi.kagimacOS/* "Orion cache"
    safe_clean ~/Library/Caches/zen/* "Zen cache"
    safe_clean ~/Library/Application\ Support/Firefox/Profiles/*/cache2/* "Firefox profile cache"

    # Service Worker CacheStorage (all profiles)
    # Limit search depth to prevent hanging on large profile directories
    while IFS= read -r sw_path; do
        [[ -z "$sw_path" ]] && continue
        local profile_name=$(basename "$(dirname "$(dirname "$sw_path")")")
        local browser_name="Chrome"
        [[ "$sw_path" == *"Microsoft Edge"* ]] && browser_name="Edge"
        [[ "$sw_path" == *"Brave"* ]] && browser_name="Brave"
        [[ "$sw_path" == *"Arc"* ]] && browser_name="Arc"
        [[ "$profile_name" != "Default" ]] && browser_name="$browser_name ($profile_name)"
        clean_service_worker_cache "$browser_name" "$sw_path"
    done < <(find "$HOME/Library/Application Support/Google/Chrome" \
        "$HOME/Library/Application Support/Microsoft Edge" \
        "$HOME/Library/Application Support/BraveSoftware/Brave-Browser" \
        "$HOME/Library/Application Support/Arc/User Data" \
        -maxdepth 6 -type d -name "CacheStorage" -path "*/Service Worker/*" 2> /dev/null || true)
}

# Clean cloud storage app caches
clean_cloud_storage() {
    safe_clean ~/Library/Caches/com.dropbox.* "Dropbox cache"
    safe_clean ~/Library/Caches/com.getdropbox.dropbox "Dropbox cache"
    safe_clean ~/Library/Caches/com.google.GoogleDrive "Google Drive cache"
    safe_clean ~/Library/Caches/com.baidu.netdisk "Baidu Netdisk cache"
    safe_clean ~/Library/Caches/com.alibaba.teambitiondisk "Alibaba Cloud cache"
    safe_clean ~/Library/Caches/com.box.desktop "Box cache"
    safe_clean ~/Library/Caches/com.microsoft.OneDrive "OneDrive cache"
}

# Clean office application caches
clean_office_applications() {
    safe_clean ~/Library/Caches/com.microsoft.Word "Microsoft Word cache"
    safe_clean ~/Library/Caches/com.microsoft.Excel "Microsoft Excel cache"
    safe_clean ~/Library/Caches/com.microsoft.Powerpoint "Microsoft PowerPoint cache"
    safe_clean ~/Library/Caches/com.microsoft.Outlook/* "Microsoft Outlook cache"
    safe_clean ~/Library/Caches/com.apple.iWork.* "Apple iWork cache"
    safe_clean ~/Library/Caches/com.kingsoft.wpsoffice.mac "WPS Office cache"
    safe_clean ~/Library/Caches/org.mozilla.thunderbird/* "Thunderbird cache"
    safe_clean ~/Library/Caches/com.apple.mail/* "Apple Mail cache"
}

# Clean virtualization tools
clean_virtualization_tools() {
    safe_clean ~/Library/Caches/com.vmware.fusion "VMware Fusion cache"
    safe_clean ~/Library/Caches/com.parallels.* "Parallels cache"
    safe_clean ~/VirtualBox\ VMs/.cache "VirtualBox cache"
    safe_clean ~/.vagrant.d/tmp/* "Vagrant temporary files"
}

# Clean Application Support logs and caches
clean_application_support_logs() {
    # Check permission
    if [[ ! -d "$HOME/Library/Application Support" ]] || ! ls "$HOME/Library/Application Support" > /dev/null 2>&1; then
        note_activity
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Skipped: No permission to access Application Support"
        return 0
    fi

    # Show loading indicator for this potentially slow operation
    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning Application Support directories..."
    fi

    # Clean log directories and cache patterns with iteration limit
    # Limit iterations to balance thoroughness and performance
    local iteration_count=0
    local max_iterations=100
    local cleaned_any=false

    for app_dir in ~/Library/Application\ Support/*; do
        [[ -d "$app_dir" ]] || continue

        # Safety: limit iterations to avoid excessive scanning
        ((iteration_count++))
        if [[ $iteration_count -gt $max_iterations ]]; then
            break
        fi

        app_name=$(basename "$app_dir")

        # Skip system and protected apps
        # Convert to lowercase for case-insensitive matching
        local app_name_lower
        app_name_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')
        case "$app_name_lower" in
            com.apple.* | adobe* | jetbrains* | 1password | claude | *clashx* | *clash* | mihomo* | *surge* | iterm* | warp* | kitty* | alacritty* | wezterm* | ghostty*)
                continue
                ;;
        esac

        # Clean log directories
        if [[ -d "$app_dir/log" ]] && ls "$app_dir/log" > /dev/null 2>&1; then
            safe_clean "$app_dir/log"/* "App logs: $app_name"
        fi
        if [[ -d "$app_dir/logs" ]] && ls "$app_dir/logs" > /dev/null 2>&1; then
            safe_clean "$app_dir/logs"/* "App logs: $app_name"
        fi
        if [[ -d "$app_dir/activitylog" ]] && ls "$app_dir/activitylog" > /dev/null 2>&1; then
            safe_clean "$app_dir/activitylog"/* "Activity logs: $app_name"
        fi

        # Clean common cache patterns (Service Worker, Code Cache, Crashpad)
        if [[ -d "$app_dir/Cache/Cache_Data" ]] && ls "$app_dir/Cache/Cache_Data" > /dev/null 2>&1; then
            safe_clean "$app_dir/Cache/Cache_Data" "Cache data: $app_name"
        fi
        if [[ -d "$app_dir/Code Cache/js" ]] && ls "$app_dir/Code Cache/js" > /dev/null 2>&1; then
            safe_clean "$app_dir/Code Cache/js"/* "Code cache: $app_name"
        fi
        if [[ -d "$app_dir/Crashpad/completed" ]] && ls "$app_dir/Crashpad/completed" > /dev/null 2>&1; then
            safe_clean "$app_dir/Crashpad/completed"/* "Crash reports: $app_name"
        fi

        # Clean Service Worker caches (CacheStorage and ScriptCache) with timeout protection
        while IFS= read -r -d '' sw_cache; do
            local profile_path=$(dirname "$(dirname "$sw_cache")")
            local profile_name=$(basename "$profile_path")
            [[ "$profile_name" == "User Data" ]] && profile_name=$(basename "$(dirname "$profile_path")")
            clean_service_worker_cache "$app_name ($profile_name)" "$sw_cache"
        done < <(find "$app_dir" -maxdepth 4 -type d \( -name "CacheStorage" -o -name "ScriptCache" \) -path "*/Service Worker/*" -print0 2> /dev/null || true)

        # Clean stale update downloads (older than 7 days) with timeout protection
        if [[ -d "$app_dir/update" ]] && ls "$app_dir/update" > /dev/null 2>&1; then
            while IFS= read -r update_dir; do
                local dir_age_days=$((($(date +%s) - $(get_file_mtime "$update_dir")) / 86400))
                if [[ $dir_age_days -ge $MOLE_TEMP_FILE_AGE_DAYS ]]; then
                    safe_clean "$update_dir" "Stale update: $app_name"
                fi
            done < <(command find "$app_dir/update" -mindepth 1 -maxdepth 1 -type d 2> /dev/null || true)
        fi
    done

    # Clean Group Containers logs with timeout protection
    if [[ -d "$HOME/Library/Group Containers" ]]; then
        while IFS= read -r logs_dir; do
            local container_name=$(basename "$(dirname "$logs_dir")")
            safe_clean "$logs_dir"/* "Group container logs: $container_name"
        done < <(command find "$HOME/Library/Group Containers" -maxdepth 2 -type d -name "Logs" 2> /dev/null || true)
    fi

    # Stop loading indicator
    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi
}

# Check and show iOS device backup info
check_ios_device_backups() {
    local backup_dir="$HOME/Library/Application Support/MobileSync/Backup"
    if [[ -d "$backup_dir" ]] && command find "$backup_dir" -mindepth 1 -maxdepth 1 2> /dev/null | read -r _; then
        local backup_kb=$(get_path_size_kb "$backup_dir")
        if [[ -n "${backup_kb:-}" && "$backup_kb" -gt 102400 ]]; then
            local backup_human=$(command du -sh "$backup_dir" 2> /dev/null | awk '{print $1}')
            note_activity
            echo -e "  Found ${GREEN}${backup_human}${NC} iOS backups"
            echo -e "  You can delete them manually: ${backup_dir}"
        fi
    fi
}

# Clean Apple Silicon specific caches
# Env: IS_M_SERIES
clean_apple_silicon_caches() {
    if [[ "$IS_M_SERIES" != "true" ]]; then
        return 0
    fi

    safe_clean /Library/Apple/usr/share/rosetta/rosetta_update_bundle "Rosetta 2 cache"
    safe_clean ~/Library/Caches/com.apple.rosetta.update "Rosetta 2 user cache"
    safe_clean ~/Library/Caches/com.apple.amp.mediasevicesd "Apple Silicon media service cache"
}
