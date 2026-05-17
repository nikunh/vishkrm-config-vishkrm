#!/usr/bin/env zsh

# SSH Health Monitor Script
# Monitors SSH service health and automatically restarts if needed
# Designed to run via cron every 2 minutes

# Configuration
SSH_PORT=2222
LOG_FILE="/var/log/ssh-monitor.log"
MAX_LOG_SIZE=1048576  # 1MB
PIDFILE="/var/run/ssh-monitor.pid"

# Function to log with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Function to rotate logs if they get too large
rotate_logs() {
    if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt $MAX_LOG_SIZE ]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
        log_message "Log rotated due to size limit"
    fi
}

# Function to check if SSH is running
check_ssh_running() {
    if pgrep -f "sshd.*${SSH_PORT}" >/dev/null 2>&1; then
        return 0  # SSH is running
    else
        return 1  # SSH is not running
    fi
}

# Function to check if SSH port is listening
check_ssh_port() {
    if netstat -tlnp 2>/dev/null | grep -q ":${SSH_PORT} "; then
        return 0  # Port is listening
    else
        return 1  # Port is not listening
    fi
}

# Function to start SSH service
start_ssh() {
    log_message "Starting SSH service on port ${SSH_PORT}"
    
    # Ensure directories exist
    mkdir -p /var/run/sshd
    mkdir -p /var/log
    
    # Generate SSH host keys if missing
    if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
        log_message "Generating SSH host keys"
        ssh-keygen -A >/dev/null 2>&1
    fi
    
    # Start SSH daemon
    if /usr/sbin/sshd -f /etc/ssh/sshd_config -p ${SSH_PORT} -D >/dev/null 2>&1 & then
        local ssh_pid=$!
        sleep 2
        
        if check_ssh_running; then
            log_message "SSH service started successfully (PID: ${ssh_pid})"
            return 0
        else
            log_message "SSH service failed to start properly"
            return 1
        fi
    else
        log_message "Failed to execute SSH daemon"
        return 1
    fi
}

# Function to get runtime user from environment or current context
get_runtime_user() {
    # Try environment variables first (from docker-compose)
    if [ -n "${RUNTIME_USER:-}" ]; then
        echo "${RUNTIME_USER}"
        return
    fi
    
    # Try to detect from HOME environment
    if [ -n "${HOME:-}" ] && [ "${HOME}" != "/" ] && [ "${HOME}" != "/root" ]; then
        basename "${HOME}"
        return
    fi
    
    # Try to get from current user context
    if [ "${USER:-}" != "root" ] && [ -n "${USER:-}" ]; then
        echo "${USER}"
        return
    fi
    
    # Fall back to discovering from /home directory
    local home_user=$(ls -1 /home 2>/dev/null | head -1)
    if [ -n "${home_user}" ]; then
        echo "${home_user}"
        return
    fi
    
    # Final fallback to vishkrm for backward compatibility
    echo "vishkrm"
}

# Function to ensure runtime user is configured
check_runtime_user() {
    local runtime_user=$(get_runtime_user)
    
    if id "${runtime_user}" >/dev/null 2>&1; then
        # Set user password if needed (use username as password for simplicity)
        echo "${runtime_user}:${runtime_user}" | chpasswd >/dev/null 2>&1
        passwd -u "${runtime_user}" >/dev/null 2>&1
        usermod -s /usr/bin/zsh "${runtime_user}" >/dev/null 2>&1
        log_message "Runtime user '${runtime_user}' configured successfully"
        return 0
    else
        log_message "Warning: runtime user '${runtime_user}' not found"
        return 1
    fi
}

# Function to create SSH configuration if missing
ensure_ssh_config() {
    local runtime_user=$(get_runtime_user)
    local config_file="/etc/ssh/sshd_config.d/${runtime_user}.conf"
    
    if [ ! -f "${config_file}" ]; then
        log_message "Creating SSH configuration for user '${runtime_user}'"
        tee "${config_file}" >/dev/null << EOF
# Runtime SSH Configuration for ${runtime_user}
Port 2222
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
PidFile /var/run/sshd-${runtime_user}.pid
EOF
    fi
}

# Main monitoring function
monitor_ssh() {
    # Prevent multiple instances
    if [ -f "$PIDFILE" ]; then
        local old_pid=$(cat "$PIDFILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            exit 0  # Another instance is running
        fi
    fi
    echo $$ > "$PIDFILE"
    
    # Rotate logs if needed
    rotate_logs
    
    # Ensure SSH configuration exists
    ensure_ssh_config
    
    # Check runtime user
    check_runtime_user
    
    # Check if SSH is running and port is listening
    local ssh_running=false
    local port_listening=false
    
    if check_ssh_running; then
        ssh_running=true
    fi
    
    if check_ssh_port; then
        port_listening=true
    fi
    
    # Determine action needed
    if $ssh_running && $port_listening; then
        # Everything is working fine
        log_message "SSH service healthy (running and listening on port ${SSH_PORT})"
    elif $ssh_running && ! $port_listening; then
        # SSH process exists but port not listening - restart needed
        log_message "SSH process exists but port ${SSH_PORT} not listening - restarting service"
        pkill -f "sshd.*${SSH_PORT}" 2>/dev/null
        sleep 1
        start_ssh
    elif ! $ssh_running; then
        # SSH not running - start it
        log_message "SSH service not running - starting service"
        start_ssh
    fi
    
    # Clean up PID file
    rm -f "$PIDFILE"
}

# Handle script arguments
case "${1:-monitor}" in
    "monitor")
        monitor_ssh
        ;;
    "start")
        start_ssh
        ;;
    "check")
        if check_ssh_running && check_ssh_port; then
            echo "SSH service is healthy"
            exit 0
        else
            echo "SSH service has issues"
            exit 1
        fi
        ;;
    "install-cron")
        echo "Installing SSH monitor cron job..."
        # Add cron job to run every 2 minutes
        (crontab -l 2>/dev/null; echo "*/2 * * * * /usr/local/lib/vishkrm-config/ssh-monitor.sh monitor >/dev/null 2>&1") | crontab -
        echo "SSH monitor cron job installed (runs every 2 minutes)"
        ;;
    "remove-cron")
        echo "Removing SSH monitor cron job..."
        crontab -l 2>/dev/null | grep -v "ssh-monitor.sh" | crontab -
        echo "SSH monitor cron job removed"
        ;;
    "status")
        echo "SSH Monitor Status:"
        echo "=================="
        if check_ssh_running; then
            echo "✅ SSH daemon running on port ${SSH_PORT}"
        else
            echo "❌ SSH daemon not running"
        fi
        
        if check_ssh_port; then
            echo "✅ Port ${SSH_PORT} is listening"
        else
            echo "❌ Port ${SSH_PORT} not listening"
        fi
        
        if [ -f "$LOG_FILE" ]; then
            echo ""
            echo "Recent log entries:"
            tail -5 "$LOG_FILE"
        fi
        ;;
    "logs")
        if [ -f "$LOG_FILE" ]; then
            tail -20 "$LOG_FILE"
        else
            echo "No log file found at $LOG_FILE"
        fi
        ;;
    *)
        echo "Usage: $0 {monitor|start|check|install-cron|remove-cron|status|logs}"
        echo ""
        echo "Commands:"
        echo "  monitor      - Check and restart SSH if needed (default)"
        echo "  start        - Start SSH service"
        echo "  check        - Check SSH health (exit 0 if healthy)"
        echo "  install-cron - Install cron job for automatic monitoring"
        echo "  remove-cron  - Remove cron job"
        echo "  status       - Show current SSH status"
        echo "  logs         - Show recent monitor logs"
        exit 1
        ;;
esac