#!/usr/bin/env zsh

# Vishkrm Configuration Utility - Blue-Green Deployment Module
# Handles V2 build triggering, status monitoring, and switching

# Blue-Green Deployment Menu
bluegreen_menu() {
    while true; do
        style_header "🔵🟢 Blue-Green Deployment" "Zero-Downtime DevContainer Management"
        
        # Get current status
        local coord_dir="/coordination"
        local active_version=$(cat "$coord_dir/current-active-version" 2>/dev/null || echo "v1")
        local v1_status=$(cat "$coord_dir/devcontainer-v1-status" 2>/dev/null || echo "active")
        local v2_status=$(cat "$coord_dir/devcontainer-v2-status" 2>/dev/null || echo "none")
        local build_progress=$(cat "$coord_dir/v2-build-progress" 2>/dev/null)
        local switch_request=$(cat "$coord_dir/switch-request" 2>/dev/null)
        
        # Status display
        echo ""
        style_info "Current Status:"
        
        # Active version status - GREEN for active, WHITE for standby
        if [[ "$active_version" == "v1" ]]; then
            style_success "  🟢 V1: Active (Port 2225)"
        else
            style_success "  🟢 V2: Active (Port 2225)"
            style_info "  ⚪ V1: Standby (Port 2226)"
        fi
        
        # V2 status
        case "$v2_status" in
            "none"|"")
                style_info "  ⚪ V2: Not Built"
                ;;
            "building")
                if [[ -n "$build_progress" ]]; then
                    style_warning "  🟡 V2: Building ($build_progress%)"
                else
                    style_warning "  🟡 V2: Building..."
                fi
                ;;
            "ready")
                style_success "  🟢 V2: Ready (Port 2226)"
                ;;
            "failed")
                style_error "  🔴 V2: Build Failed"
                ;;
        esac
        
        # Switch status
        if [[ -n "$switch_request" ]]; then
            style_warning "  🔄 Switch in progress: $switch_request"
        fi
        
        echo ""
        
        # Menu options based on current state
        local menu_options=()
        
        # Always available options
        menu_options+=("📊 Show Detailed Status")
        menu_options+=("📋 View Deployment History")
        
        # State-specific options
        case "$v2_status" in
            "none"|"")
                menu_options+=("🏗️  Trigger V2 Build")
                ;;
            "building")
                menu_options+=("👀 Monitor Build Progress")
                menu_options+=("🛑 Cancel Build")
                ;;
            "ready")
                menu_options+=("🔍 Test V2 (SSH to 2226)")
                menu_options+=("🔄 Switch to V2")
                menu_options+=("🗑️  Discard V2")
                ;;
            "failed")
                menu_options+=("🔧 Retry V2 Build")
                menu_options+=("📝 View Build Logs")
                menu_options+=("🗑️  Clear Failed Build")
                ;;
        esac
        
        # Rollback option if we're on V2
        if [[ "$active_version" == "v2" ]]; then
            menu_options+=("⏪ Rollback to V1")
        fi
        
        # Cleanup options
        if [[ "$v1_status" == "standby" || "$v2_status" == "standby" ]]; then
            menu_options+=("🧹 Cleanup Inactive Version")
        fi
        
        menu_options+=("🔙 Back to Main Menu")
        
        local choice=$(choose_option "Select action:" "${menu_options[@]}")
        
        case "$choice" in
            "🏗️  Trigger V2 Build")
                bluegreen_trigger_build
                ;;
            "👀 Monitor Build Progress")
                bluegreen_monitor_build
                ;;
            "🛑 Cancel Build")
                bluegreen_cancel_build
                ;;
            "🔍 Test V2 (SSH to 2226)")
                bluegreen_test_v2
                ;;
            "🔄 Switch to V2")
                bluegreen_switch_to_v2
                ;;
            "⏪ Rollback to V1")
                bluegreen_rollback_to_v1
                ;;
            "🗑️  Discard V2"|"🗑️  Clear Failed Build")
                bluegreen_cleanup_v2
                ;;
            "🧹 Cleanup Inactive Version")
                bluegreen_cleanup_inactive
                ;;
            "🔧 Retry V2 Build")
                bluegreen_trigger_build
                ;;
            "📊 Show Detailed Status")
                bluegreen_show_detailed_status
                ;;
            "📝 View Build Logs")
                bluegreen_show_build_logs
                ;;
            "📋 View Deployment History")
                bluegreen_show_history
                ;;
            "🔙 Back to Main Menu")
                break
                ;;
        esac
    done
}

# Trigger V2 build
bluegreen_trigger_build() {
    style_header "🏗️  Triggering V2 Build"
    
    local coord_dir="/coordination"
    
    # Confirmation
    echo ""
    style_warning "This will:"
    echo "  • Build new DevContainer with latest features"
    echo "  • Create V2 container alongside current V1"  
    echo "  • Take 5-10 minutes to complete"
    echo "  • Use significant system resources"
    echo ""
    
    if ! gum confirm "Proceed with V2 build?"; then
        return
    fi
    
    # Write coordination files to trigger build
    echo "v2-build-requested" > "$coord_dir/build-request"
    echo "$(date -u +%s)" > "$coord_dir/build-request-time" 
    echo "user-initiated" > "$coord_dir/build-trigger-source"
    echo "building" > "$coord_dir/v2-build-status"
    echo "0" > "$coord_dir/v2-build-progress"
    
    style_success "✅ V2 build request sent!"
    echo ""
    style_info "Base container will detect the request and begin building..."
    style_info "Use 'Monitor Build Progress' to track status."
    
    read -p "Press Enter to continue..." -r
}

# Monitor build progress
bluegreen_monitor_build() {
    style_header "👀 Monitoring V2 Build Progress"
    
    local coord_dir="/coordination"
    echo ""
    style_info "Press Ctrl+C to stop monitoring (build continues in background)"
    echo ""
    
    while true; do
        local status=$(cat "$coord_dir/v2-build-status" 2>/dev/null)
        local progress=$(cat "$coord_dir/v2-build-progress" 2>/dev/null)
        local start_time=$(cat "$coord_dir/v2-build-start" 2>/dev/null)
        
        # Clear line and show status
        printf "\r\033[K"
        
        case "$status" in
            "building")
                if [[ -n "$progress" ]]; then
                    printf "🟡 Building V2: $progress%% complete"
                else
                    printf "🟡 Building V2: Starting..."
                fi
                
                # Show elapsed time if available
                if [[ -n "$start_time" ]]; then
                    local elapsed=$(( $(date +%s) - start_time ))
                    printf " (${elapsed}s elapsed)"
                fi
                ;;
            "ready")
                printf "\n🟢 V2 build completed successfully!\n"
                break
                ;;
            "failed")
                printf "\n🔴 V2 build failed!\n"
                break
                ;;
            *)
                printf "⚪ Build status unknown"
                ;;
        esac
        
        sleep 2
    done
    
    read -p "Press Enter to continue..." -r
}

# Switch to V2
bluegreen_switch_to_v2() {
    style_header "🔄 Switching to V2"
    
    echo ""
    style_warning "This will:"
    echo "  • Switch SSH port 2225 from V1 → V2"
    echo "  • Move V1 to standby port 2226 (for rollback)"
    echo "  • Cause 2-3 seconds of SSH interruption"
    echo "  • Make V2 the new active version"
    echo ""
    
    if ! gum confirm "Proceed with switch to V2?"; then
        return
    fi
    
    # Signal switch request
    echo "switch-to-v2" > "/coordination/switch-request"
    echo "$(date -u +%s)" > "/coordination/switch-request-time"
    
    style_success "✅ Switch request sent!"
    echo ""
    style_info "Port forwarding will switch momentarily..."
    style_warning "Your SSH session may disconnect - reconnect to same port 2225"
    
    read -p "Press Enter to continue..." -r
}

# Test V2 on port 2226
bluegreen_test_v2() {
    style_header "🔍 Testing V2 Container"
    
    echo ""
    style_info "To test V2 before switching, use:"
    echo ""
    style_code "ssh -p 2226 vishkrm@localhost"
    echo ""
    style_info "Or from external host:"
    style_code "ssh -p 2226 vishkrm@your-server-ip"
    echo ""
    style_warning "Remember: V2 is on port 2226 until you switch!"
    
    read -p "Press Enter to continue..." -r
}

# Show detailed status
bluegreen_show_detailed_status() {
    style_header "📊 Detailed Blue-Green Status"
    
    local coord_dir="/coordination"
    
    echo ""
    style_info "🔧 Container Information:"
    echo "  Current Container: $(hostname)"
    echo "  Container Version: ${DEVCONTAINER_VERSION:-v1}"
    echo ""
    
    style_info "🎯 Active Configuration:" 
    echo "  Active Version: $(cat "$coord_dir/current-active-version" 2>/dev/null || echo "v1")"
    echo "  SSH Port (Active): 2225"
    echo ""
    
    style_info "📊 Version Status:"
    echo "  V1 Status: $(cat "$coord_dir/devcontainer-v1-status" 2>/dev/null || echo "unknown")"
    echo "  V2 Status: $(cat "$coord_dir/devcontainer-v2-status" 2>/dev/null || echo "none")"
    echo ""
    
    # Build information
    local build_start=$(cat "$coord_dir/v2-build-start" 2>/dev/null)
    if [[ -n "$build_start" ]]; then
        style_info "🏗️  Build Information:"
        local elapsed=$(( $(date +%s) - build_start ))
        echo "  Build Started: $(date -d "@$build_start" 2>/dev/null || echo "Unknown")"
        echo "  Elapsed Time: ${elapsed}s"
        echo "  Progress: $(cat "$coord_dir/v2-build-progress" 2>/dev/null || echo "0")%"
    fi
    
    echo ""
    
    # Health information
    style_info "💚 Health Status:"
    local v1_health=$(cat "$coord_dir/devcontainer-v1-healthy" 2>/dev/null)
    local v2_health=$(cat "$coord_dir/devcontainer-v2-healthy" 2>/dev/null)
    
    if [[ -n "$v1_health" ]]; then
        local v1_age=$(( $(date +%s) - v1_health ))
        echo "  V1 Last Healthy: ${v1_age}s ago"
    fi
    
    if [[ -n "$v2_health" ]]; then
        local v2_age=$(( $(date +%s) - v2_health ))
        echo "  V2 Last Healthy: ${v2_age}s ago"
    fi
    
    read -p "Press Enter to continue..." -r
}

# Show deployment history
bluegreen_show_history() {
    style_header "📋 Deployment History"
    
    local coord_dir="/coordination"
    local history_file="$coord_dir/deployment-history"
    
    echo ""
    if [[ -f "$history_file" ]]; then
        style_info "Recent deployments:"
        echo ""
        cat "$history_file" 2>/dev/null || style_dim "No history available"
    else
        style_dim "No deployment history available yet"
    fi
    
    read -p "Press Enter to continue..." -r
}

# Show build logs
bluegreen_show_build_logs() {
    style_header "📝 V2 Build Logs"
    
    echo ""
    style_info "Checking for build logs..."
    echo ""
    
    # Try to find build logs
    local log_files=(
        "/logs/v2-build.log"
        "/coordination/v2-build.log" 
        "/tmp/v2-build.log"
    )
    
    local found_logs=false
    for log_file in "${log_files[@]}"; do
        if [[ -f "$log_file" ]]; then
            style_success "Found logs: $log_file"
            echo ""
            tail -50 "$log_file" 2>/dev/null || echo "Could not read log file"
            found_logs=true
            break
        fi
    done
    
    if [[ "$found_logs" == "false" ]]; then
        style_warning "No build logs found. Check these locations:"
        for log_file in "${log_files[@]}"; do
            echo "  $log_file"
        done
    fi
    
    read -p "Press Enter to continue..." -r
}

# Cleanup functions
bluegreen_cleanup_v2() {
    style_header "🗑️  Cleanup V2"
    
    echo ""
    style_warning "This will permanently remove V2 container and build artifacts."
    echo ""
    
    if gum confirm "Proceed with V2 cleanup?"; then
        echo "cleanup-v2" > "/coordination/cleanup-request"
        echo "$(date -u +%s)" > "/coordination/cleanup-request-time"
        
        # Reset V2 status
        rm -f "/coordination/v2-build-status" 2>/dev/null
        rm -f "/coordination/v2-build-progress" 2>/dev/null
        echo "none" > "/coordination/devcontainer-v2-status"
        
        style_success "✅ V2 cleanup request sent!"
    fi
    
    read -p "Press Enter to continue..." -r
}

bluegreen_cancel_build() {
    style_header "🛑 Cancel V2 Build"
    
    echo ""
    style_warning "This will stop the current V2 build process."
    echo ""
    
    if gum confirm "Cancel V2 build?"; then
        echo "cancel-build" > "/coordination/build-cancel-request"
        echo "$(date -u +%s)" > "/coordination/build-cancel-time"
        
        style_success "✅ Build cancellation requested!"
        echo ""
        style_info "Build process will stop within 30 seconds."
    fi
    
    read -p "Press Enter to continue..." -r
}

bluegreen_rollback_to_v1() {
    style_header "⏪ Rollback to V1"
    
    echo ""
    style_warning "This will:"
    echo "  • Switch SSH port 2225 from V2 → V1"
    echo "  • Make V1 active again"
    echo "  • Keep V2 available for cleanup"
    echo ""
    
    if gum confirm "Proceed with rollback to V1?"; then
        echo "rollback-to-v1" > "/coordination/rollback-request"
        echo "$(date -u +%s)" > "/coordination/rollback-request-time"
        
        style_success "✅ Rollback request sent!"
        echo ""
        style_info "Port forwarding will switch back to V1..."
    fi
    
    read -p "Press Enter to continue..." -r
}