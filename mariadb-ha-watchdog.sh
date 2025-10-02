#!/bin/bash
set -euo pipefail

# =======================
# @dog.sh - Watchdog para recuperación automática de StatefulSet MariaDB/Galera
#
# Detecta caídas totales y fuerza recuperación segura:
# - Escala STS a 0 para eliminar pods.
# - Crea pod temporal con PVC para limpiar archivos galera.
# - Ajusta grastate.dat para bootstrap.
# - Escala STS a 1 y luego a replicas deseadas.
#
# Uso:
#   CTX=my-k8s-context ./dog.sh
#   ./dog.sh --unlock    # limpia lock
#   ./dog.sh --force     # fuerza ejecución ignorando lock
#
# Variables configurables (env):
#   NS, STS, CTX, DATA_DIR, FIX_IMAGE, SLEEP_SECONDS, PVC, etc.
# =======================

# ====== CONFIG =======
NS="${NS:-nextcloud}"                             # Namespace STS
STS="${STS:-mariadb}"                             # Nombre StatefulSet
CTX="${CTX:-}"                                    # Contexto k8s (requerido)
if [ -z "$CTX" ]; then
  echo "CTX is empty"
  exit 1
fi
PVC="${PVC:-}"
if [ -z "$PVC" ]; then
  echo "PVC is empty, it should be similar to: data-${STS}-0"
  exit 1
fi

DATA_DIR="${DATA_DIR:-/var/lib/mysql}"            # Path volumen datos en pod
FIX_IMAGE="${FIX_IMAGE:-tanzu-harbor.pngd.gob.pe/mef-ped-prod/mariadb:10.6}"  # Imagen fix pod

SLEEP_SECONDS="${SLEEP_SECONDS:-30}"               # Intervalo chequeo
TMP_DIR="${TMP_DIR:-$(mktemp -d -t ha-watchdog-XXXXXX)}"
LOCK_FILE="${LOCK_FILE:-${TMP_DIR}/watchdog.lock}" # Archivo lock
LOCK_TTL="${LOCK_TTL:-600}"                        # Max tiempo cooloff (s)
COOLOFF_ON_FAIL="${COOLOFF_ON_FAIL:-90}"           # Tiempo cooloff tras fallo (s)
RUNNING_STALE="${RUNNING_STALE:-300}"              # Lock running colgado (s)
WAIT_POD_DELETE_TIMEOUT="${WAIT_POD_DELETE_TIMEOUT:-180s}" # Timeout pod delete
WAIT_FIX_READY_TIMEOUT="${WAIT_FIX_READY_TIMEOUT:-180s}"   # Timeout fix pod ready
WAIT_STS_READY_TIMEOUT="${WAIT_STS_READY_TIMEOUT:-300s}"   # Timeout sts ready
DESIRED_REPLICAS_DEFAULT="${DESIRED_REPLICAS_DEFAULT:-3}"   # Réplicas fallback
# =====================

# Log con timestamp
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

# Check si comando existe
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

# Comprobación rápida acceso API
check_api() {
  kubectl --request-timeout=5s version >/dev/null 2>&1
}

# ----- Lock handling -----
# Lock contiene: ts:<epoch>\nstate:<running|cooloff>
read_lock() {
  [ -f "$LOCK_FILE" ] || { echo "ts=0 state=none"; return 0; }
  local ts state
  ts=$(sed -n 's/^ts:\s*//p' "$LOCK_FILE" 2>/dev/null || echo 0)
  state=$(sed -n 's/^state:\s*//p' "$LOCK_FILE" 2>/dev/null | tr -d '\r' || echo none)
  echo "ts=${ts:-0} state=${state:-none}"
}

set_lock() { # $1=state
  printf "ts:%s\nstate:%s\n" "$(date +%s)" "$1" > "$LOCK_FILE"
}

clear_lock() { rm -f "$LOCK_FILE" 2>/dev/null || true; }

# ----- kubectl helpers -----
get_replicas(){ kubectl -n "$NS" --context="$CTX" get sts "$STS" -o jsonpath='{.spec.replicas}'; }

get_pvc_template_name(){ kubectl -n "$NS" --context="$CTX" get sts "$STS" -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}'; }

pods_of_sts_exist(){ kubectl -n "$NS" --context="$CTX" get pods -o name | grep -q "^pod/${STS}-"; }

scale_sts(){ kubectl -n "$NS" --context="$CTX" scale sts "$STS" --replicas="$1" >/dev/null; }

count_ready_pods(){
  if have_cmd jq; then
    kubectl -n "$NS" --context="$CTX" get pods -o json | \
      jq '[.items[] | select(.metadata.name|test("^'"$STS"'-[0-9]+$"))
           | (.status.conditions // [])[]?
           | select(.type=="Ready" and .status=="True")]
           | length'
  else
    kubectl -n "$NS" --context="$CTX" get pods | awk -v pfx="${STS}-" '$1 ~ ("^"pfx) && $3=="Running" {c++} END{print c+0}'
  fi
}

wait_delete_pods(){
  # Espera eliminación pods con label app=STS
  if kubectl -n "$NS" --context="$CTX" get pods -l app="${STS}" >/dev/null 2>&1; then
    for p in $(kubectl -n "$NS" --context="$CTX" get pods -l app="${STS}" -o name); do
      kubectl -n "$NS" --context="$CTX" wait --for=delete "$p" --timeout="${WAIT_POD_DELETE_TIMEOUT}" || true
    done
  fi
  # Espera hasta que no queden pods del STS
  local i=0
  while [ $i -lt 36 ]; do
    pods_of_sts_exist || return 0
    sleep 5; i=$((i+1))
  done
  return 0
}

create_fix_pod(){
  local pvc_name="$1"
  kubectl -n "$NS" --context="$CTX" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: mariadb-fix
  namespace: ${NS}
spec:
  restartPolicy: Never
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
  kubectl -n "$NS" --context="$CTX" wait --for=condition=Ready pod/mariadb-fix --timeout="${WAIT_FIX_READY_TIMEOUT}" >/dev/null
}

fix_grastate(){
  # Limpia archivos conflictivos en el volumen de datos
  kubectl -n "$NS" --context="$CTX" exec mariadb-fix -- /bin/sh -c "
    set -e
    rm -f ${DATA_DIR}/gvwstate.dat ${DATA_DIR}/galera.cache ${DATA_DIR}/galera.cache.lock ${DATA_DIR}/galera.state \
          ${DATA_DIR}/gcache.page* ${DATA_DIR}/gcache.* ${DATA_DIR}/gcache* 2>/dev/null || true
    if [ -f ${DATA_DIR}/grastate.dat ]; then
      if grep -q '^safe_to_bootstrap: 0' ${DATA_DIR}/grastate.dat; then
        sed -i 's/^safe_to_bootstrap: 0/safe_to_bootstrap: 1/' ${DATA_DIR}/grastate.dat
      elif ! grep -q '^safe_to_bootstrap:' ${DATA_DIR}/grastate.dat; then
        echo 'safe_to_bootstrap: 1' >> ${DATA_DIR}/grastate.dat
      fi
    else
      UUID=\$( (command -v uuidgen >/dev/null 2>&1 && uuidgen) || (cat /proc/sys/kernel/random/uuid 2>/dev/null) || echo 00000000-0000-0000-0000-000000000000 )
      {
        echo '# GALERA saved state'
        echo 'version: 2.1'
        echo \"uuid:    \${UUID}\"
        echo 'seqno:   -1'
        echo 'safe_to_bootstrap: 1'
      } > ${DATA_DIR}/grastate.dat
    fi
    chown -R mysql:mysql ${DATA_DIR}
  "
}

delete_fix_pod(){
  kubectl -n "$NS" --context="$CTX" delete pod mariadb-fix --ignore-not-found
}

wait_sts_healthy(){
  local t=0
  while [ $t -lt 60 ]; do
    local ready
    ready=$(count_ready_pods || echo 0)
    if [ "$ready" -ge 1 ]; then return 0; fi
    sleep 5
    t=$((t+1))
  done
  return 1
}

should_recover(){
  # Recuperar si STS replicas > 0 y ningún pod está ready
  local replicas
  replicas=$(get_replicas || echo 0)
  if [ "$replicas" -eq 0 ]; then return 1; fi
  local ready
  ready=$(count_ready_pods || echo 0)
  if [ "$ready" -eq 0 ]; then return 0; fi
  return 1
}

recovery_once(){
  log ">>> RECOVERY START"
  local replicas desired replicas tmp

  replicas=$(get_replicas || echo 0)
  desired=${replicas:-$DESIRED_REPLICAS_DEFAULT}

  log "Escalando ${STS} a 0"
  scale_sts 0
  wait_delete_pods

  log "Creando pod temporal con PVC $PVC"
  create_fix_pod "$PVC"

  log "Ajustando grastate.dat y limpiando archivos"
  fix_grastate

  log "Eliminando pod temporal"
  delete_fix_pod

  log "Re-escalando ${STS} a 1 (bootstrap)"
  scale_sts 1

  log "Esperando ${STS}-0 listo..."
  if ! wait_sts_healthy; then
    log "ERROR: ${STS}-0 no quedó listo tras bootstrap"
    return 1
  fi

  if [ "$desired" -gt 1 ]; then
    log "Escalando ${STS} a $desired"
    scale_sts "$desired"
  fi

  log ">>> RECOVERY DONE"
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

# --- Main loop ---
while true; do
  check_api || { log "Error: No se puede acceder a la API de Kubernetes."; sleep "$SLEEP_SECONDS"; continue; }

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
    log "Lock 'running' demasiado viejo (${age}s > ${RUNNING_STALE}s); limpiando."
    clear_lock
    lock_state="none"
  fi

  if [ "$lock_state" != "none" ] && [ "$force_run" -eq 0 ]; then
    log "Lock activo (${lock_state}), esperando..."
    sleep "$SLEEP_SECONDS"
    continue
  fi

  if should_recover || [ "$force_run" -eq 1 ]; then
    set_lock "running"
    if recovery_once; then
      clear_lock
    else
      set_lock "cooloff"
      log "Recuperación fallida, entrando en cooldown ${COOLOFF_ON_FAIL}s."
      sleep "$COOLOFF_ON_FAIL"
    fi
  else
    sleep "$SLEEP_SECONDS"
  fi
done

