#!/bin/bash
set -euo pipefail

# =======================
# MariaDB Galera HA Watchdog con Notificaciones Slack
#
# Detecta caídas totales y fuerza recuperación segura:
# - Escala STS a 0 para eliminar pods
# - Crea pod temporal con PVC para limpiar archivos galera
# - Ajusta grastate.dat para bootstrap
# - Escala STS a 1 y luego a replicas deseadas
# - Notifica cada paso crítico a Slack
#
# Uso:
#   CTX=my-k8s-context SLACK_WEBHOOK_URL=https://hooks.slack.com/... ./mariadb-ha-watchdog.sh
#   ./mariadb-ha-watchdog.sh --unlock    # limpia lock
#   ./mariadb-ha-watchdog.sh --force     # fuerza ejecución ignorando lock
#
# Variables configurables (env):
#   NS, STS, CTX, DATA_DIR, FIX_IMAGE, SLEEP_SECONDS, PVC, SLACK_WEBHOOK_URL
# =======================

# ====== CONFIG =======
NS="${NS:-nextcloud}"
STS="${STS:-mariadb}"
CTX="${CTX:-}"
if [ -z "$CTX" ]; then
  echo "ERROR: CTX is empty (Kubernetes context required)"
  exit 1
fi
PVC="${PVC:-}"
if [ -z "$PVC" ]; then
  echo "ERROR: PVC is empty, it should be similar to: data-${STS}-0"
  exit 1
fi

DATA_DIR="${DATA_DIR:-/bitnami/mariadb}"
FIX_IMAGE="${FIX_IMAGE:-tanzu-harbor.pngd.gob.pe/pcm/mariadb-galera:12.0.2-debian-12-r0}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

SLEEP_SECONDS="${SLEEP_SECONDS:-30}"
TMP_DIR="${TMP_DIR:-$(mktemp -d -t ha-watchdog-XXXXXX)}"
LOCK_FILE="${LOCK_FILE:-${TMP_DIR}/watchdog.lock}"
LOCK_TTL="${LOCK_TTL:-600}"
COOLOFF_ON_FAIL="${COOLOFF_ON_FAIL:-90}"
RUNNING_STALE="${RUNNING_STALE:-300}"
WAIT_POD_DELETE_TIMEOUT="${WAIT_POD_DELETE_TIMEOUT:-180s}"
WAIT_FIX_READY_TIMEOUT="${WAIT_FIX_READY_TIMEOUT:-180s}"
WAIT_STS_READY_TIMEOUT="${WAIT_STS_READY_TIMEOUT:-300s}"
DESIRED_REPLICAS_DEFAULT="${DESIRED_REPLICAS_DEFAULT:-3}"
# =====================

# Log con timestamp
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

# Check si comando existe
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

# Comprobación rápida acceso API
check_api() {
  kubectl --request-timeout=5s version >/dev/null 2>&1
}

# ----- Slack Notifications -----
send_slack_notification() {
  local message="$1"
  local color="${2:-#36a64f}"  # Verde por defecto
  local title="${3:-MariaDB Watchdog}"
  
  # Si no hay webhook configurado, solo logear
  if [ -z "$SLACK_WEBHOOK_URL" ]; then
    log "[SLACK DISABLED] $message"
    return 0
  fi
  
  local timestamp=$(date +%s)
  local payload=$(cat <<EOF
{
  "username": "MariaDB Watchdog",
  "icon_emoji": ":dog:",
  "attachments": [
    {
      "color": "$color",
      "title": "$title",
      "text": "$message",
      "fields": [
        {
          "title": "Namespace",
          "value": "$NS",
          "short": true
        },
        {
          "title": "StatefulSet",
          "value": "$STS",
          "short": true
        },
        {
          "title": "Context",
          "value": "$CTX",
          "short": true
        },
        {
          "title": "Timestamp",
          "value": "$(date '+%Y-%m-%d %H:%M:%S')",
          "short": true
        }
      ],
      "footer": "MariaDB HA Watchdog",
      "ts": $timestamp
    }
  ]
}
EOF
)
  
  if curl -X POST -H 'Content-type: application/json' \
      --data "$payload" \
      --max-time 10 \
      --silent \
      "$SLACK_WEBHOOK_URL" > /dev/null 2>&1; then
    log "[SLACK] Notification sent successfully"
  else
    log "[SLACK] Failed to send notification (non-blocking)"
  fi
}

send_slack_critical() {
  send_slack_notification "$1" "#ff0000" "🔴 CRÍTICO - MariaDB Cluster"
}

send_slack_warning() {
  send_slack_notification "$1" "#ff9900" "⚠️ ADVERTENCIA - MariaDB Cluster"
}

send_slack_info() {
  send_slack_notification "$1" "#36a64f" "✅ ÉXITO - MariaDB Cluster"
}

send_slack_recovery_start() {
  local replicas="$1"
  local message="*Cluster MariaDB completamente caído detectado*\n\n"
  message="${message}📊 *Estado actual:*\n"
  message="${message}• Réplicas configuradas: ${replicas}\n"
  message="${message}• Pods Ready: 0\n"
  message="${message}• PVC afectado: \`${PVC}\`\n\n"
  message="${message}🔧 *Iniciando recuperación automática...*\n"
  message="${message}_El proceso tomará aproximadamente 3-5 minutos_"
  
  send_slack_critical "$message"
}

send_slack_recovery_step() {
  local step="$1"
  local total="$2"
  local description="$3"
  local message="*Recuperación en progreso* (${step}/${total})\n\n"
  message="${message}🔄 ${description}"
  
  send_slack_notification "$message" "#439FE0" "🔧 Recuperando - MariaDB Cluster"
}

send_slack_recovery_success() {
  local replicas="$1"
  local duration="$2"
  local message="*Recuperación completada exitosamente* ✅\n\n"
  message="${message}📊 *Estado final:*\n"
  message="${message}• Cluster operativo: ✅\n"
  message="${message}• Réplicas activas: ${replicas}\n"
  message="${message}• Duración: ${duration}s\n\n"
  message="${message}El cluster MariaDB Galera está funcionando normalmente."
  
  send_slack_info "$message"
}

send_slack_recovery_failed() {
  local error="$1"
  local message="*Recuperación FALLIDA* ❌\n\n"
  message="${message}⚠️ *Error:*\n"
  message="${message}\`\`\`${error}\`\`\`\n\n"
  message="${message}🔴 *Acción requerida:*\n"
  message="${message}Se requiere intervención manual. El watchdog reintentará automáticamente."
  
  send_slack_critical "$message"
}

# ----- Lock handling -----
read_lock() {
  [ -f "$LOCK_FILE" ] || { echo "ts=0 state=none"; return 0; }
  local ts state
  ts=$(sed -n 's/^ts:\s*//p' "$LOCK_FILE" 2>/dev/null || echo 0)
  state=$(sed -n 's/^state:\s*//p' "$LOCK_FILE" 2>/dev/null | tr -d '\r' || echo none)
  echo "ts=${ts:-0} state=${state:-none}"
}

set_lock() {
  printf "ts:%s\nstate:%s\n" "$(date +%s)" "$1" > "$LOCK_FILE"
}

clear_lock() { 
  rm -f "$LOCK_FILE" 2>/dev/null || true
}

# ----- kubectl helpers -----
get_replicas(){
  kubectl -n "$NS" --context="$CTX" get sts "$STS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0
}

pods_of_sts_exist(){
  kubectl -n "$NS" --context="$CTX" get pods -o name 2>/dev/null | grep -q "^pod/${STS}-"
}

scale_sts(){
  kubectl -n "$NS" --context="$CTX" scale sts "$STS" --replicas="$1" >/dev/null
}

count_ready_pods(){
  if have_cmd jq; then
    kubectl -n "$NS" --context="$CTX" get pods -o json 2>/dev/null | \
      jq '[.items[] | select(.metadata.name|test("^'"$STS"'-[0-9]+$"))
           | (.status.conditions // [])[]?
           | select(.type=="Ready" and .status=="True")]
           | length' || echo 0
  else
    kubectl -n "$NS" --context="$CTX" get pods 2>/dev/null | \
      awk -v pfx="${STS}-" '$1 ~ ("^"pfx) && $3=="Running" {c++} END{print c+0}'
  fi
}

wait_delete_pods(){
  log "Esperando eliminación de pods..."
  
  # Espera eliminación pods con label app=STS
  if kubectl -n "$NS" --context="$CTX" get pods -l app="${STS}" >/dev/null 2>&1; then
    for p in $(kubectl -n "$NS" --context="$CTX" get pods -l app="${STS}" -o name 2>/dev/null); do
      kubectl -n "$NS" --context="$CTX" wait --for=delete "$p" --timeout="${WAIT_POD_DELETE_TIMEOUT}" 2>/dev/null || true
    done
  fi
  
  # Espera hasta que no queden pods del STS
  local i=0
  while [ $i -lt 36 ]; do
    pods_of_sts_exist || { log "Pods eliminados correctamente"; return 0; }
    sleep 5
    i=$((i+1))
  done
  
  log "Timeout esperando eliminación, continuando..."
  return 0
}

create_fix_pod(){
  local pvc_name="$1"
  log "Creando pod temporal para ajustar grastate.dat..."
  
  kubectl -n "$NS" --context="$CTX" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: mariadb-fix
  namespace: ${NS}
spec:
  restartPolicy: Never
  securityContext:
    runAsUser: 0
    runAsGroup: 0
    fsGroup: 0
    runAsNonRoot: false
  containers:
  - name: fix
    image: ${FIX_IMAGE}
    command: ["/bin/sh","-c","sleep 1800"]
    volumeMounts:
    - name: data
      mountPath: ${DATA_DIR}
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ${pvc_name}
EOF
  
  log "Esperando que pod temporal esté listo..."
  if kubectl -n "$NS" --context="$CTX" wait --for=condition=Ready pod/mariadb-fix --timeout="${WAIT_FIX_READY_TIMEOUT}" >/dev/null 2>&1; then
    log "Pod temporal listo"
  else
    log "ERROR: Pod temporal no quedó listo"
    return 1
  fi
}

fix_grastate(){
  log "Ajustando grastate.dat y limpiando archivos de Galera..."
  
  kubectl -n "$NS" --context="$CTX" exec mariadb-fix -- /bin/bash -c '
    set -e
    DATA_MOUNT="'"${DATA_DIR}"'"
    
    echo "[recovery] Iniciando limpieza en $DATA_MOUNT"
    
    TARGET_FILES=$(find "$DATA_MOUNT" -maxdepth 6 -name grastate.dat 2>/dev/null | sort)
    if [ -z "$TARGET_FILES" ]; then
      echo "[recovery] No se encontró grastate.dat, creando directorio data"
      mkdir -p "$DATA_MOUNT/data"
      TARGET_FILES="$DATA_MOUNT/data/grastate.dat"
    fi
    
    for TARGET_FILE in $TARGET_FILES; do
      echo "[recovery] Procesando: $TARGET_FILE"
      TARGET_DIR=$(dirname "$TARGET_FILE")
      
      # Limpiar archivos de Galera
      rm -f "$TARGET_DIR"/gvwstate.dat \
            "$TARGET_DIR"/galera.cache \
            "$TARGET_DIR"/galera.cache.lock \
            "$TARGET_DIR"/galera.state \
            "$TARGET_DIR"/gcache.page* \
            "$TARGET_DIR"/gcache.* \
            "$TARGET_DIR"/gcache* 2>/dev/null || true
      
      # Ajustar safe_to_bootstrap
      if [ -f "$TARGET_FILE" ]; then
        if grep -q "^safe_to_bootstrap: 0" "$TARGET_FILE"; then
          sed -i "s/^safe_to_bootstrap: 0/safe_to_bootstrap: 1/" "$TARGET_FILE"
          echo "[recovery] ✓ Cambiado safe_to_bootstrap de 0 a 1"
        elif ! grep -q "^safe_to_bootstrap:" "$TARGET_FILE"; then
          echo "safe_to_bootstrap: 1" >> "$TARGET_FILE"
          echo "[recovery] ✓ Agregado safe_to_bootstrap: 1"
        else
          echo "[recovery] safe_to_bootstrap ya está en 1"
        fi
      else
        UUID=$( (command -v uuidgen >/dev/null 2>&1 && uuidgen) || \
                (cat /proc/sys/kernel/random/uuid 2>/dev/null) || \
                echo 00000000-0000-0000-0000-000000000000 )
        {
          echo "# GALERA saved state"
          echo "version: 2.1"
          echo "uuid:    $UUID"
          echo "seqno:   -1"
          echo "safe_to_bootstrap: 1"
        } > "$TARGET_FILE"
        echo "[recovery] ✓ Nuevo grastate.dat creado"
      fi
    done
    
    # Ajustar permisos
    MARIADB_UID=$(id -u mysql 2>/dev/null || echo 1001)
    MARIADB_GID=$(id -g mysql 2>/dev/null || echo 1001)
    chown -R "${MARIADB_UID}:${MARIADB_GID}" "$DATA_MOUNT" 2>/dev/null || true
    chmod -R g+rwX "$DATA_MOUNT" 2>/dev/null || true
    
    echo "[recovery] ✓ Limpieza completada"
  ' 2>&1 | while IFS= read -r line; do
    log "$line"
  done
  
  local exit_code=${PIPESTATUS[0]}
  if [ $exit_code -eq 0 ]; then
    log "Ajuste de grastate.dat completado exitosamente"
    return 0
  else
    log "ERROR: Falló el ajuste de grastate.dat"
    return 1
  fi
}

delete_fix_pod(){
  log "Eliminando pod temporal..."
  kubectl -n "$NS" --context="$CTX" delete pod mariadb-fix --ignore-not-found
}

wait_sts_healthy(){
  log "Esperando que ${STS}-0 esté listo..."
  local t=0
  while [ $t -lt 60 ]; do
    local ready
    ready=$(count_ready_pods || echo 0)
    if [ "$ready" -ge 1 ]; then 
      log "${STS}-0 está listo"
      return 0
    fi
    sleep 5
    t=$((t+1))
  done
  log "ERROR: Timeout esperando ${STS}-0"
  return 1
}

should_recover(){
  local replicas
  replicas=$(get_replicas || echo 0)
  if [ "$replicas" -eq 0 ]; then 
    return 1
  fi
  
  local ready
  ready=$(count_ready_pods || echo 0)
  if [ "$ready" -eq 0 ]; then 
    return 0
  fi
  
  return 1
}

recovery_once(){
  local start_time=$(date +%s)
  
  log "=========================================="
  log ">>> INICIANDO RECUPERACIÓN"
  log "=========================================="
  
  local replicas desired
  replicas=$(get_replicas || echo 0)
  desired=${replicas:-$DESIRED_REPLICAS_DEFAULT}
  
  # Notificar inicio
  send_slack_recovery_start "$desired"
  
  # Paso 1: Escalar a 0
  log "PASO 1/7: Escalando ${STS} a 0"
  send_slack_recovery_step "1" "7" "Escalando StatefulSet a 0 para limpieza segura..."
  scale_sts 0
  wait_delete_pods
  
  # Paso 2: Crear pod temporal
  log "PASO 2/7: Creando pod temporal con PVC $PVC"
  send_slack_recovery_step "2" "7" "Creando pod temporal para acceder al volumen de datos..."
  if ! create_fix_pod "$PVC"; then
    send_slack_recovery_failed "No se pudo crear el pod temporal"
    return 1
  fi
  
  # Paso 3: Ajustar grastate.dat
  log "PASO 3/7: Ajustando grastate.dat y limpiando archivos"
  send_slack_recovery_step "3" "7" "Ajustando \`grastate.dat\` (safe_to_bootstrap=1) y limpiando caché de Galera..."
  if ! fix_grastate; then
    send_slack_recovery_failed "Falló el ajuste de grastate.dat"
    delete_fix_pod
    return 1
  fi
  
  # Paso 4: Eliminar pod temporal
  log "PASO 4/7: Eliminando pod temporal"
  send_slack_recovery_step "4" "7" "Eliminando pod temporal..."
  delete_fix_pod
  sleep 3
  
  # Paso 5: Bootstrap con 1 réplica
  log "PASO 5/7: Re-escalando ${STS} a 1 (bootstrap)"
  send_slack_recovery_step "5" "7" "Iniciando bootstrap del cluster con pod-0..."
  scale_sts 1
  
  # Paso 6: Esperar pod-0
  log "PASO 6/7: Esperando ${STS}-0 listo..."
  send_slack_recovery_step "6" "7" "Esperando que pod-0 complete el bootstrap..."
  if ! wait_sts_healthy; then
    local error_msg="${STS}-0 no quedó listo tras bootstrap"
    log "ERROR: $error_msg"
    send_slack_recovery_failed "$error_msg"
    return 1
  fi
  
  # Paso 7: Escalar a réplicas deseadas
  if [ "$desired" -gt 1 ]; then
    log "PASO 7/7: Escalando ${STS} a $desired réplicas"
    send_slack_recovery_step "7" "7" "Escalando cluster a ${desired} réplicas..."
    scale_sts "$desired"
    sleep 10
  fi
  
  local end_time=$(date +%s)
  local duration=$((end_time - start_time))
  
  log "=========================================="
  log ">>> RECUPERACIÓN COMPLETADA (${duration}s)"
  log "=========================================="
  
  # Notificar éxito
  send_slack_recovery_success "$desired" "$duration"
  
  return 0
}

# --- Opciones ---
force_run=0
unlock=0
while (( $# > 0 )); do
  case "$1" in
    --force) force_run=1 ;;
    --unlock) unlock=1 ;;
    *) echo "Uso: $0 [--force|--unlock]"; exit 1 ;;
  esac
  shift
done

if [ "$unlock" -eq 1 ]; then
  clear_lock
  log "Lock eliminado manualmente."
  exit 0
fi

# Verificar configuración mínima
log "Iniciando MariaDB HA Watchdog"
log "Namespace: $NS | StatefulSet: $STS | Context: $CTX"
log "PVC: $PVC | Slack: $([ -n "$SLACK_WEBHOOK_URL" ] && echo "Enabled" || echo "Disabled")"

# --- Main loop ---
iteration=0
while true; do
  iteration=$((iteration + 1))
  
  # Verificar API cada iteración
  if ! check_api; then
    log "Error: No se puede acceder a la API de Kubernetes."
    sleep "$SLEEP_SECONDS"
    continue
  fi
  
  # Leer lock
  lock_data=$(read_lock)
  lock_ts=$(echo "$lock_data" | awk '{print $1}' | cut -d= -f2)
  lock_state=$(echo "$lock_data" | awk '{print $2}' | cut -d= -f2)
  now=$(date +%s)
  age=$((now - lock_ts))
  
  # Limpieza automática lock
  if [ "$lock_state" = "cooloff" ] && [ "$age" -gt "$LOCK_TTL" ]; then
    log "Lock 'cooloff' expirado (${age}s > ${LOCK_TTL}s); limpiando."
    clear_lock
    lock_state="none"
  elif [ "$lock_state" = "running" ] && [ "$age" -gt "$RUNNING_STALE" ]; then
    log "Lock 'running' obsoleto (${age}s > ${RUNNING_STALE}s); limpiando."
    clear_lock
    lock_state="none"
  fi
  
  if [ "$lock_state" != "none" ] && [ "$force_run" -eq 0 ]; then
    if [ $((iteration % 6)) -eq 0 ]; then
      log "Lock activo (${lock_state}), esperando..."
    fi
    sleep "$SLEEP_SECONDS"
    continue
  fi
  
  # Verificar si se necesita recuperación
  if should_recover || [ "$force_run" -eq 1 ]; then
    set_lock "running"
    
    if recovery_once; then
      clear_lock
      force_run=0
    else
      set_lock "cooloff"
      log "Recuperación fallida, entrando en cooldown ${COOLOFF_ON_FAIL}s."
      sleep "$COOLOFF_ON_FAIL"
    fi
  else
    # Log periódico cuando todo está OK (cada 20 iteraciones = ~10 minutos)
    if [ $((iteration % 20)) -eq 0 ]; then
      local ready=$(count_ready_pods)
      local replicas=$(get_replicas)
      log "Cluster OK (${ready}/${replicas} Ready)"
    fi
    sleep "$SLEEP_SECONDS"
  fi
done
