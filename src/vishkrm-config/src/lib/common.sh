#!/usr/bin/env zsh

# Vishkrm Configuration Utility - Common Library
# Shared functions and utilities for all modules

# Check if gum is available
check_gum() {
    if ! command -v gum &> /dev/null; then
        echo "Error: gum is required but not installed."
        echo "Please install gum first: https://github.com/charmbracelet/gum"
        exit 1
    fi
}

# Common styling functions
style_header() {
    local title="$1"
    local subtitle="$2"
    gum style --foreground="#00ff00" --border="double" --padding="1" --margin="1" \
        "$title" \
        "$subtitle"
}

style_subheader() {
    local title="$1"
    local subtitle="$2"
    local color="${3:-#0088ff}"
    gum style --foreground="$color" --border="rounded" --padding="1" --margin="1" \
        "$title" \
        "$subtitle"
}

style_success() {
    local message="$1"
    gum style --foreground="2" "$message"
}

style_error() {
    local message="$1"
    gum style --foreground="1" "$message"
}

style_warning() {
    local message="$1"
    gum style --foreground="3" "$message"
}

style_info() {
    local message="$1"
    gum style --foreground="8" "$message"
}

style_dim() {
    local message="$1"
    gum style --foreground="240" "$message"
}

# Common user interaction functions
confirm_action() {
    local message="$1"
    gum confirm "$message"
}

get_input() {
    local placeholder="$1"
    local default="$2"
    if [ -n "$default" ]; then
        gum input --placeholder "$placeholder" --value "$default"
    else
        gum input --placeholder "$placeholder"
    fi
}

get_password() {
    local placeholder="$1"
    gum input --placeholder "$placeholder" --password
}

choose_option() {
    local header="$1"
    shift
    gum choose --header "$header" "$@"
}

# Common utility functions
get_user_ids() {
    export VISHKRM_UID=$(id -u vishkrm)
    export VISHKRM_GID=$(id -g vishkrm)
}

wait_for_user() {
    local message="${1:-Press Enter to continue...}"
    style_info "$message"
    read -r
}

# Module loading function
load_module() {
    local module_name="$1"
    local module_path="$VISHKRM_CONFIG_DIR/modules/${module_name}.sh"
    
    if [ -f "$module_path" ]; then
        source "$module_path"
        return 0
    else
        style_error "Module $module_name not found at $module_path"
        return 1
    fi
}

# Spinner wrapper
run_with_spinner() {
    local title="$1"
    local command="$2"
    gum spin --title "$title" -- $command
}

# Initialize common variables
init_common() {
    # Set the base directory for the vishkrm-config utility
    export VISHKRM_CONFIG_DIR="${VISHKRM_CONFIG_DIR:-/usr/local/lib/vishkrm-config}"
    
    # Get user IDs
    get_user_ids
    
    # Check for required tools
    check_gum
}
