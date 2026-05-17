#!/usr/bin/env zsh

# Vishkrm Configuration Utility - System Module
# System information and diagnostics

# System information
system_information() {
    style_subheader "📊 System Information" "" "#00ff00"
    
    style_success "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    style_success "Kernel: $(uname -r)"
    style_success "Architecture: $(uname -m)"
    style_success "User: $(whoami)"
    style_success "Shell: $SHELL"
    style_success "Home: $HOME"
    style_success "Uptime: $(uptime -p)"
    style_success "Memory: $(free -h | grep Mem | awk '{print $3"/"$2}') used"
    style_success "Disk: $(df -h / | tail -n1 | awk '{print $5}') used"
    style_success "CPU Cores: $(nproc)"
    
    wait_for_user
}
