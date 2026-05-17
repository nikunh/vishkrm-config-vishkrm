#!/usr/bin/env zsh

# Vishkrm Configuration Utility - Dotfiles Module
# View dotfiles help and documentation

# Dotfiles help menu
dotfiles_help_menu() {
    # Check if dotfiles fragment exists
    local DOTFILES_FRAGMENT="/usr/local/lib/vishkrm-config/fragments/dotfiles/dotfiles-help.fragment"

    if [ ! -f "$DOTFILES_FRAGMENT" ]; then
        style_subheader "📚 Dotfiles Help" "Dotfiles not installed" "#e74c3c"
        echo ""
        style_error "❌ Dotfiles are not installed"
        echo ""
        echo "To install dotfiles:"
        echo "  1. Configure DevPod dotfiles URL:"
        echo "     devpod context set-options -o DOTFILES_URL=https://github.com/nikunh/shellinator-dotfiles-vishkrm.git"
        echo ""
        echo "  2. Rebuild your workspace:"
        echo "     devpod up --recreate"
        echo ""
        wait_for_user
        return
    fi

    # Source the dotfiles fragment to load the help function
    source "$DOTFILES_FRAGMENT" 2>/dev/null || {
        style_error "❌ Failed to load dotfiles fragment"
        wait_for_user
        return
    }

    # Clear screen and display help
    clear
    style_subheader "📚 Dotfiles Help" "Personal aliases and functions" "#4a90e2"
    echo ""

    # Call the dotfiles_help function from the fragment
    if type dotfiles_help &>/dev/null; then
        dotfiles_help
    else
        style_error "❌ dotfiles_help function not found in fragment"
        echo ""
        echo "Fragment contents:"
        cat "$DOTFILES_FRAGMENT"
    fi

    echo ""
    wait_for_user
}
