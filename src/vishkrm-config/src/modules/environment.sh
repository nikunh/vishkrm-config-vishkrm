#!/usr/bin/env zsh

# Vishkrm Configuration Utility - Environment Module
# Environment settings and configuration management

# Environment settings
environment_settings() {
    local choice=$(choose_option "Environment Settings:" \
        "📊 View environment variables" \
        "🔧 Edit PATH" \
        "🎨 Configure shell theme" \
        "⚙️  Configure aliases" \
        "⬅️  Back")
    
    case "$choice" in
        "📊 View environment variables")
            view_env_vars
            ;;
        "🔧 Edit PATH")
            edit_path
            ;;
        "🎨 Configure shell theme")
            configure_theme
            ;;
        "⚙️  Configure aliases")
            configure_aliases
            ;;
        "⬅️  Back"|*)
            return 0
            ;;
    esac
}

# View environment variables
view_env_vars() {
    style_subheader "📊 Environment Variables" ""
    
    local important_vars=("PATH" "HOME" "SHELL" "TERM" "EDITOR" "LANG" "AWS_PROFILE" "KUBECONFIG")
    
    for var in "${important_vars[@]}"; do
        local value=$(eval echo "\$$var")
        if [ -n "$value" ]; then
            style_success "$var: $value"
        else
            style_warning "$var: (not set)"
        fi
    done
    
    wait_for_user
}

# Edit PATH
edit_path() {
    style_subheader "Current PATH entries:" ""
    echo "$PATH" | tr ':' '\n' | nl
    
    local choice=$(choose_option "PATH actions:" \
        "➕ Add new path" \
        "📋 Show current PATH" \
        "🔄 Reload PATH from .zshrc" \
        "⬅️  Back")
    
    case "$choice" in
        "➕ Add new path")
            local new_path=$(get_input "Enter new PATH entry...")
            if [ -n "$new_path" ]; then
                echo "export PATH=\"$new_path:\$PATH\"" >> "$HOME/.zshrc"
                style_success "✅ Added to PATH (restart shell to apply)"
            fi
            ;;
        "📋 Show current PATH")
            echo "$PATH" | tr ':' '\n' | gum format
            ;;
        "🔄 Reload PATH from .zshrc")
            source "$HOME/.zshrc"
            style_success "✅ PATH reloaded"
            ;;
        *)
            return 0
            ;;
    esac
}

# Configure theme
configure_theme() {
    style_subheader "🎨 Theme Configuration" "" "#ff8800"
    
    local themes=("robbyrussell" "agnoster" "powerlevel10k" "spaceship" "vishkrm")
    local current_theme=$(grep "ZSH_THEME=" "$HOME/.zshrc" | cut -d'"' -f2)
    
    style_warning "Current theme: $current_theme"
    
    local new_theme=$(printf '%s\n' "${themes[@]}" | gum choose --header "Select theme:")
    
    if [ -n "$new_theme" ]; then
        sed -i "s/ZSH_THEME=.*/ZSH_THEME=\"$new_theme\"/" "$HOME/.zshrc"
        style_success "✅ Theme changed to $new_theme (restart shell to apply)"
    fi
}

# Configure aliases
configure_aliases() {
    style_subheader "⚙️  Alias Configuration" ""
    
    local choice=$(choose_option "Alias actions:" \
        "📋 Show current aliases" \
        "➕ Add new alias" \
        "🔧 Edit alias file" \
        "⬅️  Back")
    
    case "$choice" in
        "📋 Show current aliases")
            alias | gum format
            ;;
        "➕ Add new alias")
            local alias_name=$(get_input "Alias name (e.g., 'll')...")
            local alias_command=$(get_input "Command (e.g., 'ls -la')...")
            if [ -n "$alias_name" ] && [ -n "$alias_command" ]; then
                echo "alias $alias_name='$alias_command'" >> "$HOME/.zshrc"
                style_success "✅ Alias added (restart shell to apply)"
            fi
            ;;
        "🔧 Edit alias file")
            if command -v nvim &>/dev/null; then
                nvim "$HOME/.zshrc"
            elif command -v vim &>/dev/null; then
                vim "$HOME/.zshrc"
            else
                nano "$HOME/.zshrc"
            fi
            ;;
        *)
            return 0
            ;;
    esac
}
