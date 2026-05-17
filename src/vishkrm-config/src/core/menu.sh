#!/usr/bin/env zsh

# Vishkrm Configuration Utility - Core Menu System
# Main menu and navigation logic

# Load common library
source "$VISHKRM_CONFIG_DIR/lib/common.sh"

# Main header
main_header() {
    style_header "🛠️  Vishkrm Configuration Utility" "Shellinator Reloaded Management Console"
}

# Main menu function
main_menu() {
    while true; do
        main_header
        
        local choice=$(choose_option "Select configuration area:" \
            "📦 DevContainer Features" \
            "📚 Dotfiles Help" \
            "🔗 Persistent Files Setup" \
            "🎭 Branch Personality Info" \
            "📡 NAS Configuration" \
            "🔐 SSH Service Management" \
            "🔍 System Verification" \
            "⚙️  Environment Settings" \
            "📊 System Information" \
            "🔄 Reload Shell Configuration" \
            "🚪 Exit")
        
        case "$choice" in
            "📦 DevContainer Features")
                # Load features module on-demand
                if load_module "features"; then
                    features_menu
                fi
                ;;
            "📚 Dotfiles Help")
                # Load dotfiles module on-demand
                if load_module "dotfiles"; then
                    dotfiles_help_menu
                fi
                ;;
            "🔗 Persistent Files Setup")
                # Load persistent files module on-demand
                if load_module "persistent-files"; then
                    persistent_files_menu
                fi
                ;;
            "📡 NAS Configuration")
                # Load NAS module on-demand
                if load_module "nas"; then
                    nas_config_menu
                fi
                ;;
            "🔐 SSH Service Management")
                # Load SSH module on-demand
                if load_module "ssh"; then
                    ssh_menu
                fi
                ;;
            "🎭 Branch Personality Info")
                # Load personality module on-demand (updated for branch-based system)
                if load_module "personality"; then
                    personality_menu
                fi
                ;;
            "🔍 System Verification")
                # Load verification module on-demand
                if load_module "verification"; then
                    verification_menu
                fi
                ;;
            "⚙️  Environment Settings")
                # Load environment module on-demand
                if load_module "environment"; then
                    environment_settings
                fi
                ;;
            "📊 System Information")
                # Load system module on-demand
                if load_module "system"; then
                    system_information
                fi
                ;;
            "🔄 Reload Shell Configuration")
                # This is simple enough to keep inline
                reload_shell_config
                ;;
            "🚪 Exit"|*)
                style_success "👋 Goodbye!"
                exit 0
                ;;
        esac
    done
}

# Simple reload function (kept inline for performance)
reload_shell_config() {
    style_subheader "🔄 Reloading shell configuration..." "" "#ff8800"
    
    if [ -f "$HOME/.zshrc" ]; then
        source "$HOME/.zshrc"
        style_success "✅ Shell configuration reloaded"
    else
        style_error "❌ .zshrc not found"
    fi
    
    wait_for_user
}
