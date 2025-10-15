#!/bin/bash
set -euo pipefail

# =======================
# MariaDB Galera HA Watchdog OPTIMIZADO
# =======================

# ====== CONFIG OPTIMIZADO =======
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
# Imagen más liviana para operaciones de fix
FIX_IMAGE="${FIX_IMAGE:-busybox:1.36}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

# Timeouts optimizados (en segundos para cálculos)
SLEEP_SECONDS="${SLEEP_SECONDS:-30}"
POD_CREATION_TIMEOUT="${POD_CREATION_TIMEOUT:-60}"
POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-30}"
POD_DELETE_FAST_TIMEOUT="${POD_DELETE_FAST_TIMEOUT:-90}"
BOOTSTRAP_READY_TIMEOUT="${BOOTSTRAP_READY_TIMEOUT:-120}"

TMP_DIR="${TMP_DIR:-$(mktemp -d -t ha-watchdog-XXXXXX)}"
LOCK_FILE="${LOCK_FILE:-${TMP_DIR}/watchdog.lock}"
LOCK_TTL="${LOCK_TTL:-600}"
COOLOFF_ON_FAIL="${COOLOFF_ON_FAIL:-90}"
RUNNING_STALE="${RUNNING_STALE:-300}"
# FORZAR 3 RÉPLICAS PARA HA - SIEMPRE
DESIRED_REPLICAS="${DESIRED_REPLICAS:-3}"
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
  local formatted_message
  formatted_message=$(printf '%b' "$message")
  
  # Si no hay webhook configurado, solo logear
  if [ -z "$SLACK_WEBHOOK_URL" ]; then
    log "[SLACK DISABLED] $formatted_message"
    return 0
  fi

  if ! have_cmd python3; then
    log "[SLACK] python3 no disponible para escapar payload, omitiendo notificación. Mensaje: $formatted_message"
    return 1
  fi
  
  local timestamp=$(date +%s)
  local escaped_message
  escaped_message=$(python3 -c 'import json,sys; msg=sys.stdin.read(); print(json.dumps(msg)[1:-1], end="")' <<<"$formatted_message")

  local payload=$(cat <<EOF
{
  "username": "MariaDB Watchdog",
  "icon_emoji": ":dog:",
  "attachments": [
    {
      "color": "$color",
      "title": "$title",
      "text": "$escaped_message",
      "fallback": "$escaped_message",
      "mrkdwn_in": ["text", "fields"],
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
  
  if curl --fail -X POST -H 'Content-type: application/json' \
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
  send_slack_notification "$1" "#ff0000" ":red_circle: CRÍTICO - MariaDB Cluster"
}

send_slack_warning() {
  send_slack_notification "$1" "#ff9900" ":warning: ADVERTENCIA - MariaDB Cluster"
}

send_slack_info() {
  send_slack_notification "$1" "#36a64f" ":white_check_mark: ÉXITO - MariaDB Cluster"
}

send_slack_recovery_start() {
  local replicas="$1"
  local message="*Cluster MariaDB completamente caído detectado*\n\n"
  message="${message}:bar_chart: *Estado actual:*\n"
  message="${message}• Réplicas configuradas: ${replicas}\n"
  message="${message}• Pods Ready: 0\n"
  message="${message}• PVC afectado: \`${PVC}\`\n\n"
  message="${message}:wrench: *Iniciando recuperación automática...*\n"
  message="${message}_El proceso tomará aproximadamente 1-2 minutos_"
  
  send_slack_critical "$message"
}

send_slack_recovery_step() {
  local step="$1"
  local total="$2"
  local description="$3"
  local message="*Recuperación en progreso* (${step}/${total})\n\n"
  message="${message}:arrows_counterclockwise: ${description}"
  
  send_slack_notification "$message" "#439FE0" ":wrench: Recuperando - MariaDB Cluster"
}

send_slack_recovery_success() {
  local replicas="$1"
  local duration="$2"
  local message="*Recuperación completada exitosamente* :white_check_mark:\n\n"
  message="${message}:bar_chart: *Estado final:*\n"
  message="${message}• Cluster operativo: :white_check_mark:\n"
  message="${message}• Réplicas activas: ${replicas}\n"
  message="${message}• Duración: ${duration}s\n\n"
  message="${message}El cluster MariaDB Galera está funcionando normalmente."
  
  send_slack_info "$message"
}

send_slack_recovery_failed() {
  local error="$1"
  local message="*Recuperación FALLIDA* :x:\n\n"
  message="${message}:warning: *Error:*\n"
  message="${message}\`\`\`${error}\`\`\`\n\n"
  message="${message}:red_circle: *Acción requerida:*\n"
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
  log "Escalando ${STS} a $1 réplicas..."
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

ensure_minimum_replicas(){
  local desired="$DESIRED_REPLICAS"
  local current scaled=0
  current=$(get_replicas || echo 0)
  if [ "$current" -lt "$desired" ]; then
    log "Réplicas configuradas (${current}) por debajo del mínimo HA (${desired}); escalando inmediatamente."
    send_slack_warning "Se detectaron ${current} réplicas configuradas en ${NS}/${STS}. Forzando escalado a ${desired} para mantener Alta Disponibilidad."
    scale_sts "$desired"
    scaled=1
  fi

  if [ "$scaled" -eq 1 ]; then
    log "Verificando estado del cluster tras escalado automático a ${desired} réplicas..."
    if wait_all_replicas_ready "$desired"; then
      log "✓ Escalado automático completado: ${desired} réplicas listas."
      send_slack_info "Escalado automático completado en ${NS}/${STS}: ${desired} réplicas listas tras ajuste de Alta Disponibilidad."
    else
      log "⚠️ Escalado automático no alcanzó todas las réplicas Ready."
      send_slack_warning "Escalado automático en ${NS}/${STS} no logró ${desired} réplicas Ready en el tiempo esperado. Revisar estado del cluster."
    fi
  fi
}

wait_delete_pods(){
  log "Eliminación rápida de pods..."
  
  # Forzar eliminación inmediata
  kubectl -n "$NS" --context="$CTX" delete pods -l app="${STS}" --force --grace-period=0 >/dev/null 2>&1 || true
  
  # Espera optimizada
  local i=0
  while [ $i -lt 18 ]; do  # 90s máximo
    if ! pods_of_sts_exist; then 
      log "✓ Pods eliminados rápidamente"
      return 0
    fi
    sleep 5
    i=$((i+1))
  done
  
  log "⚠️ Eliminación tomó más tiempo del esperado, continuando..."
  return 0
}

create_fix_pod(){
  local pvc_name="$1"
  log "Creando pod temporal optimizado..."
  
  # Pre-crear el pod de forma asíncrona
  kubectl -n "$NS" --context="$CTX" apply -f - <<EOF >/dev/null 2>&1 &
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
    readinessProbe:
      exec:
        command: ["/bin/sh", "-c", "test -f /bin/sh"]
      initialDelaySeconds: 1
      periodSeconds: 1
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
  priorityClassName: system-node-critical
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ${pvc_name}
EOF
  
  local creation_pid=$!
  
  # Esperar creación con timeout reducido
  log "Esperando creación del pod (${POD_CREATION_TIMEOUT}s)..."
  if timeout "${POD_CREATION_TIMEOUT}s" bash -c "
    until kubectl -n '$NS' --context='$CTX' get pod/mariadb-fix >/dev/null 2>&1; do
      sleep 1
    done
  "; then
    log "✓ Pod creado exitosamente"
    wait $creation_pid 2>/dev/null
  else
    log "ERROR: Timeout en creación del pod"
    kill $creation_pid 2>/dev/null 2>&1
    return 1
  fi
  
  # Esperar readiness optimizado
  log "Esperando que pod temporal esté listo..."
  if kubectl -n "$NS" --context="$CTX" wait --for=condition=Ready pod/mariadb-fix --timeout="${POD_READY_TIMEOUT}s" >/dev/null 2>&1; then
    log "✓ Pod temporal listo en ${POD_READY_TIMEOUT}s"
    return 0
  else
    log "ERROR: Pod temporal no quedó listo en el tiempo esperado"
    return 1
  fi
}

fix_grastate(){
  log "Ajustando grastate.dat (versión optimizada)..."
  
  kubectl -n "$NS" --context="$CTX" exec mariadb-fix -- /bin/sh -c '
    set -e
    DATA_MOUNT="'"${DATA_DIR}"'"
    
    echo "[recovery] Buscando grastate.dat..."
    
    # Búsqueda optimizada
    TARGET_FILE=$(find "$DATA_MOUNT" -maxdepth 3 -name grastate.dat -type f 2>/dev/null | head -1)
    
    if [ -z "$TARGET_FILE" ]; then
      echo "[recovery] No encontrado, creando en $DATA_MOUNT/data"
      mkdir -p "$DATA_MOUNT/data"
      TARGET_FILE="$DATA_MOUNT/data/grastate.dat"
    fi
    
    TARGET_DIR=$(dirname "$TARGET_FILE")
    
    # Limpieza rápida
    echo "[recovery] Limpiando archivos de Galera..."
    rm -f "$TARGET_DIR"/gvwstate.dat \
          "$TARGET_DIR"/galera.cache \
          "$TARGET_DIR"/galera.cache.lock \
          "$TARGET_DIR"/galera.state \
          "$TARGET_DIR"/gcache.* 2>/dev/null || true
    
    # Procesamiento eficiente
    echo "[recovery] Procesando: $TARGET_FILE"
    if [ -f "$TARGET_FILE" ]; then
      if grep -q "^safe_to_bootstrap: 0" "$TARGET_FILE"; then
        sed -i "s/^safe_to_bootstrap: 0/safe_to_bootstrap: 1/" "$TARGET_FILE"
        echo "[recovery] ✓ safe_to_bootstrap: 0 → 1"
      elif ! grep -q "^safe_to_bootstrap:" "$TARGET_FILE"; then
        echo "safe_to_bootstrap: 1" >> "$TARGET_FILE"
        echo "[recovery] ✓ safe_to_bootstrap: 1 agregado"
      else
        echo "[recovery] safe_to_bootstrap ya está en 1"
      fi
    else
      cat > "$TARGET_FILE" << GRastate
# GALERA saved state
version: 2.1
uuid:    00000000-0000-0000-0000-000000000000
seqno:   -1
safe_to_bootstrap: 1
GRastate
      echo "[recovery] ✓ Nuevo grastate.dat creado"
    fi
    
    # Permisos optimizados
    chown -R 1001:1001 "$TARGET_DIR" 2>/dev/null || true
    echo "[recovery] ✓ Proceso completado"
  ' 2>&1 | while IFS= read -r line; do
    log "$line"
  done
  
  local exit_code=${PIPESTATUS[0]}
  if [ $exit_code -eq 0 ]; then
    log "✓ Ajuste de grastate.dat completado"
    return 0
  else
    log "ERROR: Falló el ajuste de grastate.dat"
    return 1
  fi
}

delete_fix_pod(){
  log "Eliminando pod temporal..."
  kubectl -n "$NS" --context="$CTX" delete pod mariadb-fix --force --grace-period=0 --ignore-not-found >/dev/null 2>&1
}

wait_sts_healthy(){
  log "Esperando que ${STS}-0 esté listo (timeout: ${BOOTSTRAP_READY_TIMEOUT}s)..."
  local t=0
  local max_attempts=$((BOOTSTRAP_READY_TIMEOUT/5))
  
  while [ $t -lt $max_attempts ]; do
    local ready
    ready=$(count_ready_pods || echo 0)
    if [ "$ready" -ge 1 ]; then 
      log "✓ ${STS}-0 está listo"
      return 0
    fi
    sleep 5
    t=$((t+1))
  done
  log "ERROR: Timeout esperando ${STS}-0"
  return 1
}

# Función MEJORADA para escalar a todas las réplicas
wait_all_replicas_ready(){
  local desired="$1"
  log "Esperando que todas las ${desired} réplicas estén listas..."
  
  local t=0
  local max_attempts=60  # 5 minutos máximo
  
  while [ $t -lt $max_attempts ]; do
    local ready
    ready=$(count_ready_pods || echo 0)
    if [ "$ready" -eq "$desired" ]; then 
      log "✓ Todas las ${desired} réplicas están listas"
      return 0
    fi
    # Nombre del servicio (esto debe ser único por servicio o contexto)
    service_name="mariadb-galera-dev"

    # Archivo temporal único para cada servicio
    LAST_READY_FILE="/tmp/.last_ready_notified_${CTX}_${NS}_${STS}"

    # Leer el último valor notificado si existe, sino usar -1 (un valor imposible)
    if [ -f "$LAST_READY_FILE" ]; then
      last_ready=$(cat "$LAST_READY_FILE")
    else
      last_ready=-1
    fi

    # Obtener el valor actual de "ready"
    ready=$(count_ready_pods || echo 0)

    # Verificar si ya están todas las réplicas listas
    if [ "$ready" -eq "$desired" ]; then
      log "✓ Todas las ${desired} réplicas están listas"
      return 0
    fi

    # Lógica de notificación
    if [ "$ready" -gt 0 ] && [ "$ready" -lt "$desired" ]; then
      if [ "$ready" -ne "$last_ready" ]; then
        send_slack_warning "${ready}/${desired} réplicas listas"
        echo "$ready" > "$LAST_READY_FILE"  # Guardar el valor actual de "ready"
      fi
    fi

    # Limpiar el archivo temporal
    # rm "$LAST_READY_FILE"

    # Registro de progreso
    log "Progreso: ${ready}/${desired} réplicas listas"
    sleep 5
    t=$((t+1))
  done
  
  local final_ready=$(count_ready_pods || echo 0)
  log "⚠️ Timeout: Solo ${final_ready}/${desired} réplicas listas"
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
  log ">>> INICIANDO RECUPERACIÓN OPTIMIZADA"
  log "=========================================="
  
  # SIEMPRE USAR 3 RÉPLICAS PARA HA - IGNORAR EL ESTADO ACTUAL
  local desired_replicas="$DESIRED_REPLICAS"
  log "Configurando cluster para Alta Disponibilidad: ${desired_replicas} réplicas"
  
  # Notificar inicio
  send_slack_recovery_start "$desired_replicas"
  
  # Paso 1: Escalar a 0
  log "PASO 1/7: Escalando ${STS} a 0"
  send_slack_recovery_step "1" "7" "Escalando StatefulSet a 0 para limpieza segura..."
  scale_sts 0
  wait_delete_pods
  
  # Paso 2: Crear pod temporal optimizado
  log "PASO 2/7: Creando pod temporal optimizado con PVC $PVC"
  send_slack_recovery_step "2" "7" "Creando pod temporal optimizado para acceder al volumen de datos..."
  if ! create_fix_pod "$PVC"; then
    send_slack_recovery_failed "No se pudo crear el pod temporal"
    return 1
  fi
  
  # Paso 3: Ajustar grastate.dat optimizado
  log "PASO 3/7: Ajustando grastate.dat (optimizado)"
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
  sleep 2
  
  # Paso 5: Bootstrap con 1 réplica
  log "PASO 5/7: Re-escalando ${STS} a 1 (bootstrap)"
  send_slack_recovery_step "5" "7" "Iniciando bootstrap del cluster con pod-0..."
  scale_sts 1
  
  # Paso 6: Esperar pod-0 optimizado
  log "PASO 6/7: Esperando ${STS}-0 listo (optimizado)..."
  send_slack_recovery_step "6" "7" "Esperando que pod-0 complete el bootstrap..."
  if ! wait_sts_healthy; then
    local error_msg="${STS}-0 no quedó listo tras bootstrap"
    log "ERROR: $error_msg"
    send_slack_recovery_failed "$error_msg"
    return 1
  fi
  
  # Paso 7: Escalar a 3 RÉPLICAS PARA HA y esperar
  log "PASO 7/7: Escalando ${STS} a ${desired_replicas} réplicas (HA)"
  send_slack_recovery_step "7" "7" "Escalando cluster a ${desired_replicas} réplicas para Alta Disponibilidad..."
  scale_sts "$desired_replicas"
  
  # ESPERAR ACTIVAMENTE A QUE TODAS LAS RÉPLICAS ESTÉN LISTAS
  log "Esperando que todas las ${desired_replicas} réplicas estén listas..."
  if wait_all_replicas_ready "$desired_replicas"; then
    log "✓ Todas las ${desired_replicas} réplicas están operativas - Cluster HA listo"
  else
    log "⚠️ No todas las réplicas están listas, pero el cluster está operativo"
  fi
  
  local end_time=$(date +%s)
  local duration=$((end_time - start_time))
  
  # Verificar estado final
  local final_ready=$(count_ready_pods)
  local final_replicas=$(get_replicas)
  
  log "=========================================="
  log ">>> RECUPERACIÓN COMPLETADA (${duration}s)"
  log ">>> ESTADO FINAL: ${final_ready}/${final_replicas} réplicas listas"
  log ">>> CLUSTER HA CONFIGURADO PARA ${desired_replicas} RÉPLICAS"
  log "=========================================="
  
  # Notificar éxito
  send_slack_recovery_success "$final_replicas" "$duration"
  
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
log "Iniciando MariaDB HA Watchdog (VERSIÓN OPTIMIZADA)"
log "Namespace: $NS | StatefulSet: $STS | Context: $CTX"
log "PVC: $PVC | Slack: $([ -n "$SLACK_WEBHOOK_URL" ] && echo "Enabled" || echo "Disabled")"
log "Timeouts optimizados: Pod Creation: ${POD_CREATION_TIMEOUT}s, Pod Ready: ${POD_READY_TIMEOUT}s"

# Mostrar réplicas actuales al inicio y configuración HA
current_replicas=$(get_replicas)
log "Réplicas actuales detectadas: ${current_replicas}"
log "CONFIGURACIÓN HA: Siempre escalando a ${DESIRED_REPLICAS} réplicas para Alta Disponibilidad"
ensure_minimum_replicas

# Verificar dependencias
if ! have_cmd timeout; then
  log "ERROR: El comando 'timeout' no está disponible. Instale coreutils."
  exit 1
fi

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

  ensure_minimum_replicas
  
  # Verificar si se necesita recuperación
  if should_recover || [ "$force_run" -eq 1 ]; then
    set_lock "running"
    
    if recovery_once; then
      clear_lock
      force_run=0
      # Esperar un poco más después de recuperación exitosa
      sleep 30
    else
      set_lock "cooloff"
      log "Recuperación fallida, entrando en cooldown ${COOLOFF_ON_FAIL}s."
      sleep "$COOLOFF_ON_FAIL"
    fi
  else
    # Log periódico cuando todo está OK (cada 20 iteraciones = ~10 minutos)
    if [ $((iteration % 20)) -eq 0 ]; then
      ensure_minimum_replicas
      ready=$(count_ready_pods)
      replicas=$(get_replicas)
      log "Cluster OK (${ready}/${replicas} Ready)"
      # Si hay menos réplicas de las deseadas, log warning
      if [ "$replicas" -lt "$DESIRED_REPLICAS" ]; then
        log "⚠️  ADVERTENCIA: Cluster con solo ${replicas} réplicas (se esperaban ${DESIRED_REPLICAS} para HA)"
      fi
    fi
    sleep "$SLEEP_SECONDS"
  fi
done

