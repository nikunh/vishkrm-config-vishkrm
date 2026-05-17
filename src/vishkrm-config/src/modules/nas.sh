#!/usr/bin/env zsh

# Vishkrm Configuration Utility - NAS Configuration Module
# Integration with connect-nas command

# NAS Configuration Menu
nas_config_menu() {
    while true; do
        style_subheader "📡 NAS Configuration" "Network Attached Storage Management" "#00aaff"

        local choice=$(choose_option "Select NAS option:" \
            "🔗 Connect to NAS" \
            "🚀 Quick Mount (Standard Locations)" \
            "📋 Show Current Mounts" \
            "🔓 Unmount NAS Share" \
            "ℹ️  NAS Connection Help" \
            "⬅️  Back to Main Menu")

        case "$choice" in
            "🔗 Connect to NAS")
                connect_to_nas
                ;;
            "🚀 Quick Mount (Standard Locations)")
                quick_mount_nas
                ;;
            "📋 Show Current Mounts")
                show_current_mounts
                ;;
            "🔓 Unmount NAS Share")
                unmount_nas_share
                ;;
            "ℹ️  NAS Connection Help")
                show_nas_help
                ;;
            "⬅️  Back to Main Menu"|*)
                return 0
                ;;
        esac
    done
}

# Connect to NAS using the connect-nas script
connect_to_nas() {
    style_subheader "🔗 Connect to NAS" "Launch NAS connection utility" "#00ff00"

    echo ""
    if command -v connect-nas &>/dev/null; then
        style_info "Launching NAS connector..."
        echo ""
        connect-nas
    else
        style_error "❌ connect-nas command not found"
        echo ""
        style_info "The NAS connector feature may not be installed."
        echo "Please ensure the nas-connector feature is included in your devcontainer.json"
    fi

    echo ""
    wait_for_user
}

# Quick Mount using nas-connector's standard locations feature
quick_mount_nas() {
    style_subheader "🚀 Quick Mount" "Mount standard NAS locations" "#00ff00"

    echo ""
    if command -v connect-nas &>/dev/null; then
        style_info "Launching Quick Mount utility..."
        echo ""
        # Call connect-nas with environment variable to trigger quick mount mode
        QUICK_MOUNT=true connect-nas
    else
        style_error "❌ connect-nas command not found"
        echo ""
        style_info "The NAS connector feature may not be installed."
        echo "Please ensure the nas-connector feature is included in your devcontainer.json"
    fi

    echo ""
    wait_for_user
}

# Show current mount points
show_current_mounts() {
    style_subheader "📋 Current NAS Mounts" "" "#ffff00"

    echo ""
    style_info "Current mount points:"

    # Show all mounts that look like NAS/CIFS/SMB
    local mounts=$(mount | grep -E "(cifs|smbfs|nfs)" 2>/dev/null)

    if [[ -n "$mounts" ]]; then
        echo "$mounts" | while read -r line; do
            style_success "✅ $line"
        done
    else
        style_warning "⚠️  No NAS mounts found"
    fi

    echo ""
    style_info "All current mounts in /home/vishkrm:"
    ls -la /home/vishkrm/ | grep "^l\|^d" | grep -v "^\.$\|^\.\.$" || style_warning "No mounted directories found"

    echo ""
    wait_for_user
}

# Unmount NAS shares
unmount_nas_share() {
    style_subheader "🔓 Unmount NAS Share" "Select share to unmount" "#ff8800"

    echo ""
    # Find mounted NAS shares
    local nas_mounts=$(mount | grep -E "(cifs|smbfs|nfs)" | awk '{print $3}' 2>/dev/null)

    if [[ -z "$nas_mounts" ]]; then
        style_warning "⚠️  No NAS mounts found to unmount"
        echo ""
        wait_for_user
        return 0
    fi

    echo "Select mount point to unmount:"
    echo "$nas_mounts" | nl -w2 -s') '
    echo ""

    read -p "Enter number (or press Enter to cancel): " selection

    if [[ -n "$selection" && "$selection" =~ ^[0-9]+$ ]]; then
        local mount_point=$(echo "$nas_mounts" | sed -n "${selection}p")
        if [[ -n "$mount_point" ]]; then
            echo ""
            style_info "Unmounting: $mount_point"
            if sudo umount "$mount_point" 2>/dev/null; then
                style_success "✅ Successfully unmounted $mount_point"
            else
                style_error "❌ Failed to unmount $mount_point"
            fi
        else
            style_error "❌ Invalid selection"
        fi
    else
        style_info "Unmount cancelled"
    fi

    echo ""
    wait_for_user
}

# Show NAS connection help
show_nas_help() {
    style_subheader "ℹ️  NAS Connection Help" "Troubleshooting and tips" "#00ffff"

    echo ""
    style_info "🔧 Available Commands:"
    echo "  ${CYAN}connect-nas${RESET}        - Interactive NAS connection utility"
    echo "  ${CYAN}vishkrm-config${RESET}      - This configuration menu"
    echo ""

    style_info "🌐 Supported Protocols:"
    echo "  • SMB/CIFS (Windows/Samba shares)"
    echo "  • SSH/SFTP (Secure shell file transfer)"
    echo "  • FTP/FTPS (File transfer protocol)"
    echo ""

    style_info "🔍 Troubleshooting:"
    echo "  • ${CYAN}Check prerequisites${RESET}: Ensure CIFS utilities are installed"
    echo "  • ${CYAN}Network connectivity${RESET}: Verify server is reachable"
    echo "  • ${CYAN}Credentials${RESET}: Double-check username and password"
    echo "  • ${CYAN}Permissions${RESET}: Some mounts require sudo privileges"
    echo ""

    style_info "📁 Common Mount Locations:"
    echo "  • ${CYAN}/home/vishkrm/synnas_home${RESET}    - Home directory share"
    echo "  • ${CYAN}/home/vishkrm/.ssh${RESET}            - SSH keys from NAS"
    echo "  • ${CYAN}/home/vishkrm/.aws${RESET}            - AWS credentials from NAS"
    echo ""

    style_info "💡 Tips:"
    echo "  • Use 'Quick Mount' for standard locations"
    echo "  • Browse shares to find specific folders"
    echo "  • Mount points are created automatically"
    echo ""

    wait_for_user
}