#!/bin/bash
set -euo pipefail

# MariaDB HA Watchdog Installation Script
# This script installs the mariadb-ha-watchdog service and script

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Log functions
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define source and destination paths
WATCHDOG_SCRIPT="$SCRIPT_DIR/mariadb-ha-watchdog.sh"
SERVICE_FILE="$SCRIPT_DIR/mariadb-ha-watchdog.service"
DEST_SCRIPT="/usr/local/bin/mariadb-ha-watchdog.sh"
DEST_SERVICE="/etc/systemd/system/mariadb-ha-watchdog.service"

log_info "Starting MariaDB HA Watchdog installation..."

# Check if source files exist
if [ ! -f "$WATCHDOG_SCRIPT" ]; then
    log_error "Watchdog script not found: $WATCHDOG_SCRIPT"
    exit 1
fi

if [ ! -f "$SERVICE_FILE" ]; then
    log_error "Service file not found: $SERVICE_FILE"
    exit 1
fi

# Stop service if already running
if systemctl is-active --quiet mariadb-ha-watchdog.service; then
    log_info "Stopping existing mariadb-ha-watchdog service..."
    systemctl stop mariadb-ha-watchdog.service
fi

# Copy watchdog script
log_info "Installing watchdog script to $DEST_SCRIPT..."
cp "$WATCHDOG_SCRIPT" "$DEST_SCRIPT"
chmod +x "$DEST_SCRIPT"
chown root:root "$DEST_SCRIPT"

# Copy service file
log_info "Installing systemd service to $DEST_SERVICE..."
cp "$SERVICE_FILE" "$DEST_SERVICE"
chmod 644 "$DEST_SERVICE"
chown root:root "$DEST_SERVICE"

# Reload systemd daemon
log_info "Reloading systemd daemon..."
systemctl daemon-reload

# Enable service
log_info "Enabling mariadb-ha-watchdog service..."
systemctl enable mariadb-ha-watchdog.service

# Start service
log_info "Starting mariadb-ha-watchdog service..."
systemctl start mariadb-ha-watchdog.service

# Check service status
sleep 2
if systemctl is-active --quiet mariadb-ha-watchdog.service; then
    log_info "✓ MariaDB HA Watchdog service installed and started successfully!"
    echo ""
    log_info "Service status:"
    systemctl status mariadb-ha-watchdog.service --no-pager -l
    echo ""
    log_info "Useful commands:"
    echo "  - Check status:  systemctl status mariadb-ha-watchdog"
    echo "  - View logs:     journalctl -u mariadb-ha-watchdog -f"
    echo "  - Stop service:  systemctl stop mariadb-ha-watchdog"
    echo "  - Restart:       systemctl restart mariadb-ha-watchdog"
    echo "  - Disable:       systemctl disable mariadb-ha-watchdog"
else
    log_error "Service failed to start. Check logs with: journalctl -u mariadb-ha-watchdog -n 50"
    exit 1
fi
