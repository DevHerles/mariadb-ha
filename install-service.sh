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

# Usage function
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Install MariaDB HA Watchdog service with custom configuration.

OPTIONS:
    -n, --namespace NS          Kubernetes namespace (required)
    -s, --statefulset STS       StatefulSet name (required)
    -c, --context CTX           Kubernetes context (required)
    -p, --pvc PVC               PVC name (required)
    -d, --description DESC      Service description (optional, default: "MariaDB Galera HA Watchdog")
    -h, --help                  Show this help message

EXAMPLE:
    sudo $0 -n nextcloud -s mariadb -c my-k8s-context -d "MariaDB Galera HA Watchdog (Nextcloud)"

EOF
    exit 1
}

# Initialize variables
NS=""
STS=""
CTX=""
PVC=""
DESCRIPTION="MariaDB Galera HA Watchdog"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NS="$2"
            shift 2
            ;;
        -s|--statefulset)
            STS="$2"
            shift 2
            ;;
        -c|--context)
            CTX="$2"
            shift 2
            ;;
        -p|--pvc)
            PVC="$2"
            shift 2
            ;;
        -d|--description)
            DESCRIPTION="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [ -z "$NS" ] || [ -z "$STS" ] || [ -z "$CTX" ] || [ -z "$PVC" ]; then
    log_error "Missing required parameters!"
    echo ""
    usage
fi

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
DEST_SERVICE="/etc/systemd/system/mariadb-ha-watchdog-$NS-$STS-$CTX.service"
TEMP_SERVICE="/tmp/mariadb-ha-watchdog-$NS-$STS-$CTX.service.tmp"

log_info "Starting MariaDB HA Watchdog installation..."
log_info "Configuration:"
log_info "  Namespace:    $NS"
log_info "  StatefulSet:  $STS"
log_info "  Context:      $CTX"
log_info "  PVC:          $PVC"
log_info "  Description:  $DESCRIPTION"

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
if systemctl is-active --quiet mariadb-ha-watchdog-$NS-$STS-$CTX.service; then
    log_info "Stopping existing mariadb-ha-watchdog service..."
    systemctl stop mariadb-ha-watchdog-$NS-$STS-$CTX.service
fi

# Copy watchdog script
log_info "Installing watchdog script to $DEST_SCRIPT..."
cp "$WATCHDOG_SCRIPT" "$DEST_SCRIPT"
chmod +x "$DEST_SCRIPT"
chown root:root "$DEST_SCRIPT"

# Update service file with provided parameters
log_info "Configuring service file with custom parameters..."
sed -e "s|Description=.*|Description=$DESCRIPTION|" \
    -e "s|Environment=NS=<.*>|Environment=NS=$NS|" \
    -e "s|Environment=STS=<.*>|Environment=STS=$STS|" \
    -e "s|Environment=CTX=<.*>|Environment=CTX=$CTX|" \
    -e "s|Environment=PVC=<.*>|Environment=PVC=$PVC|" \
    "$SERVICE_FILE" > "$TEMP_SERVICE"

# Copy configured service file
log_info "Installing systemd service to $DEST_SERVICE..."
cp "$TEMP_SERVICE" "$DEST_SERVICE"
chmod 644 "$DEST_SERVICE"
chown root:root "$DEST_SERVICE"

# Clean up temporary file
rm -f "$TEMP_SERVICE"

# Reload systemd daemon
log_info "Reloading systemd daemon..."
systemctl daemon-reload

# Enable service
log_info "Enabling mariadb-ha-watchdog service..."
systemctl enable mariadb-ha-watchdog-$NS-$STS-$CTX.service

# Start service
log_info "Starting mariadb-ha-watchdog service..."
systemctl start mariadb-ha-watchdog-$NS-$STS-$CTX.service

# Check service status
sleep 2
if systemctl is-active --quiet mariadb-ha-watchdog-$NS-$STS-$CTX.service; then
    log_info "✓ MariaDB HA Watchdog service installed and started successfully!"
    echo ""
    log_info "Service status:"
    systemctl status mariadb-ha-watchdog-$NS-$STS-$CTX.service --no-pager -l
    echo ""
    log_info "Useful commands:"
    echo "  - Check status:  systemctl status mariadb-ha-watchdog-$NS-$STS-$CTX.service"
    echo "  - View logs:     journalctl -u mariadb-ha-watchdog-$NS-$STS-$CTX.service -f"
    echo "  - Stop service:  systemctl stop mariadb-ha-watchdog-$NS-$STS-$CTX.service"
    echo "  - Restart:       systemctl restart mariadb-ha-watchdog-$NS-$STS-$CTX.service"
    echo "  - Disable:       systemctl disable mariadb-ha-watchdog-$NS-$STS-$CTX.service"
else
    log_error "Service failed to start. Check logs with: journalctl -u mariadb-ha-watchdog-$NS-$STS-$CTX.service -n 50"
    exit 1
fi


