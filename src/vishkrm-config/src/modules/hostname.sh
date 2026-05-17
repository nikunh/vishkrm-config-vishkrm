#!/usr/bin/env zsh
# Version-Aware Hostname Management Module
# Provides meaningful hostnames for DevContainers based on version and environment

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Environment detection
detect_environment() {
    local hostname=$(hostname 2>/dev/null || echo "unknown")
    local environment="unknown"
    
    # Detect environment based on hostname patterns
    if [[ "$hostname" == *"-local" ]]; then
        environment="local"
    elif [[ "$hostname" == *"-v1" ]] || [[ "$hostname" == *"-v2" ]]; then
        environment="production"
    elif [[ "$hostname" == "shellinator-"* ]]; then
        environment="production"
    else
        environment="development"
    fi
    
    echo "$environment"
}

# Version detection from various sources
detect_version() {
    local version="v1"  # Default
    
    # Try multiple detection methods in order of preference
    
    # 1. Environment variable
    if [[ -n "${DEVCONTAINER_VERSION}" ]]; then
        version="$DEVCONTAINER_VERSION"
    
    # 2. Hostname pattern
    elif [[ "$(hostname)" == *"-v2"* ]]; then
        version="v2"
    elif [[ "$(hostname)" == *"-v1"* ]]; then
        version="v1"
    
    # 3. Coordination directory
    elif [[ -f "/coordination/current-active-version" ]]; then
        local coord_version=$(cat /coordination/current-active-version 2>/dev/null || echo "v1")
        if [[ "$coord_version" == "v2" ]]; then
            version="v2"
        fi
    
    # 4. SSH port detection (last resort)
    elif [[ "${SSH_PORT}" == "2226" ]]; then
        version="v2"
    fi
    
    echo "$version"
}

# Generate meaningful hostname
generate_hostname() {
    local version=$(detect_version)
    local environment=$(detect_environment)
    local base_name="shellinator"
    
    case "$environment" in
        "local")
            echo "${base_name}-${version}-local"
            ;;
        "production")
            echo "${base_name}-${version}"
            ;;
        "development"|*)
            echo "${base_name}-${version}-dev"
            ;;
    esac
}

# Update hostname resolution
fix_hostname_resolution() {
    local current_hostname=$(hostname 2>/dev/null || echo "unknown")
    local target_hostname=$(generate_hostname)
    
    # Always ensure current hostname resolves
    if ! grep -q "$current_hostname" /etc/hosts 2>/dev/null; then
        echo "127.0.0.1 $current_hostname" | sudo tee -a /etc/hosts >/dev/null 2>&1 || true
    fi
    
    # Add target hostname if different
    if [[ "$current_hostname" != "$target_hostname" ]]; then
        if ! grep -q "$target_hostname" /etc/hosts 2>/dev/null; then
            echo "127.0.0.1 $target_hostname" | sudo tee -a /etc/hosts >/dev/null 2>&1 || true
        fi
    fi
}

# Set PS1 hostname display
update_ps1_hostname() {
    local meaningful_hostname=$(generate_hostname)
    
    # Export for use in shell prompts
    export SHELLINATOR_HOSTNAME="$meaningful_hostname"
    
    # Update /etc/hostname if we have permission (mainly for display purposes)
    if [[ -w /etc/hostname ]] 2>/dev/null; then
        echo "$meaningful_hostname" > /etc/hostname 2>/dev/null || true
    fi
}

# Show hostname information
show_hostname_info() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    Hostname Information                       ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    
    local current_hostname=$(hostname 2>/dev/null || echo "unknown")
    local target_hostname=$(generate_hostname)
    local version=$(detect_version)
    local environment=$(detect_environment)
    
    echo -e "Current hostname:     ${YELLOW}$current_hostname${NC}"
    echo -e "Meaningful hostname:  ${GREEN}$target_hostname${NC}"
    echo -e "Detected version:     ${BLUE}$version${NC}"
    echo -e "Environment:          ${CYAN}$environment${NC}"
    
    if [[ -n "${SHELLINATOR_HOSTNAME}" ]]; then
        echo -e "Shell display name:   ${MAGENTA}$SHELLINATOR_HOSTNAME${NC}"
    fi
}

# Initialize hostname system
init_hostname_system() {
    fix_hostname_resolution
    update_ps1_hostname
}

# Menu interface for hostname management
show_hostname_menu() {
    while true; do
        echo -e "\n${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║                   Hostname Management                        ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
        
        local options=(
            "📊 Show hostname information"
            "🔧 Fix hostname resolution"
            "🎯 Update shell display name"
            "🔄 Reinitialize hostname system"
            "⬅️  Back to main menu"
        )
        
        local choice
        if command -v gum >/dev/null 2>&1; then
            choice=$(printf '%s\n' "${options[@]}" | gum choose)
        else
            echo "Available options:"
            for i in "${!options[@]}"; do
                echo "$((i+1)). ${options[$i]}"
            done
            echo -n "Choose an option (1-${#options[@]}): "
            read -r selection
            choice="${options[$((selection-1))]}"
        fi
        
        case "$choice" in
            "📊 Show hostname information")
                show_hostname_info
                echo -e "\nPress Enter to continue..."
                read
                ;;
            "🔧 Fix hostname resolution")
                echo -e "${YELLOW}Fixing hostname resolution...${NC}"
                fix_hostname_resolution
                echo -e "${GREEN}✅ Hostname resolution updated${NC}"
                echo -e "\nPress Enter to continue..."
                read
                ;;
            "🎯 Update shell display name")
                echo -e "${YELLOW}Updating shell display name...${NC}"
                update_ps1_hostname
                echo -e "${GREEN}✅ Shell display name updated${NC}"
                echo -e "Note: New shell sessions will show: ${MAGENTA}$SHELLINATOR_HOSTNAME${NC}"
                echo -e "\nPress Enter to continue..."
                read
                ;;
            "🔄 Reinitialize hostname system")
                echo -e "${YELLOW}Reinitializing hostname system...${NC}"
                init_hostname_system
                echo -e "${GREEN}✅ Hostname system reinitialized${NC}"
                echo -e "\nPress Enter to continue..."
                read
                ;;
            "⬅️  Back to main menu"|*)
                return 0
                ;;
        esac
    done
}

# Auto-initialization (called when module is sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Script is being run directly
    show_hostname_menu
else
    # Script is being sourced, auto-initialize
    init_hostname_system >/dev/null 2>&1 || true
fi