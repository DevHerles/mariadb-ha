#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    cat <<EOF
Uso: sudo $0 -n <namespace> -s <statefulset> -c <context> [opciones]

Opciones:
  -n, --namespace NS      Namespace del StatefulSet (obligatorio)
  -s, --statefulset STS   Nombre del StatefulSet (obligatorio)
  -c, --context CTX       Contexto de kubectl usado por el servicio (obligatorio)
  -b, --remove-binary     Eliminar /usr/local/bin/mariadb-ha-watchdog.sh si no lo usa otro servicio
  -h, --help              Mostrar esta ayuda

Ejemplo:
  sudo $0 -n database-dev -s mariadb-galera-dev -c wso2-prod-tmp -b
EOF
    exit 1
}

NS=""
STS=""
CTX=""
REMOVE_BINARY="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)   NS="$2"; shift 2 ;;
        -s|--statefulset) STS="$2"; shift 2 ;;
        -c|--context)     CTX="$2"; shift 2 ;;
        -b|--remove-binary) REMOVE_BINARY="true"; shift ;;
        -h|--help)        usage ;;
        *) log_error "Opción desconocida: $1"; usage ;;
    esac
done

if [[ -z "$NS" || -z "$STS" || -z "$CTX" ]]; then
    log_error "Debes indicar namespace, statefulset y contexto."
    usage
fi

if [[ "$EUID" -ne 0 ]]; then
    log_error "Este script requiere privilegios de root. Ejecuta con sudo."
    exit 1
fi

SERVICE_NAME="mariadb-ha-watchdog-${NS}-${STS}-${CTX}.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
BIN_PATH="/usr/local/bin/mariadb-ha-watchdog.sh"

log_info "Eliminando servicio ${SERVICE_NAME}..."

if systemctl is-active --quiet "$SERVICE_NAME"; then
    log_info "Deteniendo servicio..."
    systemctl stop "$SERVICE_NAME" || log_warn "No se pudo detener ${SERVICE_NAME} (quizá ya estaba detenido)."
fi

if systemctl list-unit-files --type=service --no-legend | awk '{print $1}' | grep -Fxq "$SERVICE_NAME"; then
    log_info "Deshabilitando servicio..."
    systemctl disable "$SERVICE_NAME" >/dev/null || log_warn "No se pudo deshabilitar ${SERVICE_NAME}."
else
    log_warn "El servicio ${SERVICE_NAME} no figura en la lista de units persistentes."
fi

if [[ -f "$SERVICE_PATH" ]]; then
    log_info "Eliminando unit file ${SERVICE_PATH}..."
    rm -f "$SERVICE_PATH"
else
    log_warn "Unit file ${SERVICE_PATH} no encontrado."
fi

log_info "Recargando daemon de systemd..."
systemctl daemon-reload
systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true

if [[ "$REMOVE_BINARY" == "true" ]]; then
    if [[ -f "$BIN_PATH" ]]; then
        if systemctl list-unit-files --type=service --no-legend | awk '{print $1}' | grep -q "^mariadb-ha-watchdog-.*\.service$"; then
            log_warn "Quedan otros servicios watchdog registrados; no se elimina ${BIN_PATH}."
        else
            log_info "Eliminando binario ${BIN_PATH}..."
            rm -f "$BIN_PATH"
        fi
    else
        log_warn "Binario ${BIN_PATH} no encontrado."
    fi
else
    log_info "Binario principal conservado (usa -b para eliminarlo)."
fi

log_info "✓ Servicio ${SERVICE_NAME} eliminado."

