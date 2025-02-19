#!/bin/bash
set -e  # Detiene la ejecución si hay un error

# Configuración
SRC_DIR="/mnt/vw/mariadb-mariadb-backup-pvc-pvc-e6a0313c-494c-4001-8fcf-162d6eb122c7"
DEST_DIR="/mnt/pngd_vaultwarden"
REMOTE_USER="root"
REMOTE_HOST="10.9.9.27"
LOG_FILE="$HOME/vaultwarden_backup_sync.log"

# Buscar el último archivo de backup
LATEST_BACKUP=$(ls -t "$SRC_DIR"/vaultwarden-backup-*.sql.gz | head -1)

if [ -z "$LATEST_BACKUP" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - No backup files found! Exiting..." | tee -a "$LOG_FILE"
  exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Copying $LATEST_BACKUP to $REMOTE_HOST:$DEST_DIR" | tee -a "$LOG_FILE"

# Ejecutar rsync para copiar el archivo al servidor remoto
rsync -avz "$LATEST_BACKUP" "$REMOTE_USER@$REMOTE_HOST:$DEST_DIR" | tee -a "$LOG_FILE"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Sync completed successfully!" | tee -a "$LOG_FILE"

