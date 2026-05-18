#!/usr/bin/env zsh

# Vishkrm Configuration Utility — GUI Server module
# Controls gui-server-vishkrm (xpra HTML5): master switch + per-app toggles.
# State persisted to ~/.config/vishkrm/gui-state.json (NAS-symlinked via nas-connector D12).

source "$VISHKRM_CONFIG_DIR/lib/common.sh"

GUI_STATE_FILE="$HOME/.config/vishkrm/gui-state.json"
GUI_OBSIDIAN_APPIMAGE="$HOME/.local/bin/Obsidian.AppImage"

# Initialize default state file if missing
gui_state_init() {
    mkdir -p "$(dirname "$GUI_STATE_FILE")"
    if [ ! -f "$GUI_STATE_FILE" ]; then
        cat > "$GUI_STATE_FILE" << 'EOF'
{
  "master": false,
  "port": 14500,
  "display": 100,
  "apps": {
    "firefox":  {"enabled": false, "cmd": "firefox"},
    "obsidian": {"enabled": false, "cmd": "~/.local/bin/Obsidian.AppImage --no-sandbox --appimage-extract-and-run"}
  }
}
EOF
        style_success "✅ Initialized $GUI_STATE_FILE with defaults (master OFF, all apps OFF)"
    fi
}

# Read JSON field
gui_get() { jq -r "$1" "$GUI_STATE_FILE" 2>/dev/null; }

# Write JSON field (in-place)
gui_set() {
    local filter="$1"
    local tmp; tmp=$(mktemp)
    jq "$filter" "$GUI_STATE_FILE" > "$tmp" && mv "$tmp" "$GUI_STATE_FILE"
}

# Download Obsidian AppImage if not present
gui_install_obsidian() {
    if [ -x "$GUI_OBSIDIAN_APPIMAGE" ]; then
        style_success "✅ Obsidian AppImage already at $GUI_OBSIDIAN_APPIMAGE"
        return 0
    fi
    style_info "Fetching latest Obsidian release URL from GitHub..."
    local url
    url=$(curl -fsSL https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest \
        | jq -r '.assets[] | select(.name | test("Obsidian-[0-9.]+\\.AppImage$")) | .browser_download_url' \
        | head -1)
    if [ -z "$url" ]; then
        style_error "❌ Could not determine Obsidian AppImage URL"
        return 1
    fi
    style_info "Downloading from $url ..."
    mkdir -p "$(dirname "$GUI_OBSIDIAN_APPIMAGE")"
    curl -fL "$url" -o "$GUI_OBSIDIAN_APPIMAGE" && chmod +x "$GUI_OBSIDIAN_APPIMAGE"
    if [ -x "$GUI_OBSIDIAN_APPIMAGE" ]; then
        style_success "✅ Obsidian installed at $GUI_OBSIDIAN_APPIMAGE"
    else
        style_error "❌ Obsidian download failed"
        return 1
    fi
}

# Restart xpra if master is ON (called after any toggle change)
gui_restart_if_running() {
    local master; master=$(gui_get '.master')
    [ "$master" != "true" ] && return 0
    style_info "Restarting xpra session to apply changes..."
    gui-server-stop >/dev/null 2>&1 || true
    sleep 1
    gui-server-start
}

# Toggle master switch
gui_toggle_master() {
    local cur; cur=$(gui_get '.master')
    if [ "$cur" = "true" ]; then
        gui_set '.master = false'
        style_warning "Master switch → OFF. Stopping xpra..."
        gui-server-stop
    else
        gui_set '.master = true'
        style_success "Master switch → ON. Starting xpra..."
        gui-server-start
    fi
}

# Toggle per-app enabled flag
gui_toggle_app() {
    local app="$1"
    local cur; cur=$(gui_get ".apps.\"$app\".enabled")
    if [ "$cur" = "true" ]; then
        gui_set ".apps.\"$app\".enabled = false"
        style_warning "$app → OFF"
    else
        # Apps that need install at toggle-on time
        case "$app" in
            obsidian)
                if ! gui_install_obsidian; then
                    style_error "Not enabling $app — install failed."
                    return 1
                fi
                ;;
        esac
        gui_set ".apps.\"$app\".enabled = true"
        style_success "$app → ON"
    fi
    gui_restart_if_running
}

# Status display
gui_status() {
    style_subheader "🖥️  GUI Server Status" "" "#0088ff"
    gui-server-status
}

# Sub-menu: per-app toggles
gui_apps_menu() {
    while true; do
        local choices=()
        local apps; apps=$(gui_get '.apps | keys[]')
        while IFS= read -r app; do
            local en; en=$(gui_get ".apps.\"$app\".enabled")
            local mark="[ ]"
            [ "$en" = "true" ] && mark="[X]"
            choices+=("$mark $app")
        done <<< "$apps"
        choices+=("⬅️  Back")
        local choice; choice=$(choose_option "Toggle GUI apps (changes apply on restart of xpra):" "${choices[@]}")
        case "$choice" in
            "⬅️  Back"|"") return ;;
            *)
                # Strip "[X] " or "[ ] " prefix. Use `] ` as the anchor — `#* `
                # alone matches the space INSIDE `[ ]` for the OFF case, leaving
                # `] firefox` and creating a phantom app key on every toggle.
                local app="${choice#*\] }"
                gui_toggle_app "$app"
                ;;
        esac
    done
}

# Main GUI Server menu (entry point from main_menu)
gui_server_menu() {
    gui_state_init
    while true; do
        local master; master=$(gui_get '.master')
        local mark="[OFF]"
        [ "$master" = "true" ] && mark="[ON ]"
        local choice; choice=$(choose_option "🖥️  GUI Server  (current: $mark):" \
            "🔁 Toggle master switch  ($mark)" \
            "🎨 GUI Apps (per-app toggles)" \
            "📊 Status" \
            "⬅️  Back to main menu")
        case "$choice" in
            "🔁 Toggle master switch  "*) gui_toggle_master ;;
            "🎨 GUI Apps (per-app toggles)") gui_apps_menu ;;
            "📊 Status") gui_status ;;
            "⬅️  Back to main menu"|"") return ;;
        esac
    done
}
