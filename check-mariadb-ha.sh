#!/bin/bash

################################################################################
# Script de Verificación de MariaDB Galera HA
# Uso: ./check-mariadb-ha.sh -c config.yaml
# Valida pods, servicios, PVCs y estado interno de Galera.
################################################################################

set -euo pipefail

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

DEPLOYMENT_NAME=""
NAMESPACE=""
STORAGE_CLASS=""
REPLICA_COUNT=""
ROOT_PASSWORD=""
HELM_SECRET_NAME=""
AUTO_STORAGE_CLASS=true

ERROR_COUNT=0
WARN_COUNT=0
declare -a POD_LIST=()

to_bool() {
    local value="${1,,}"
    case "$value" in
        true|1|y|yes) echo "true" ;;
        *) echo "false" ;;
    esac
}

sanitize_name() {
    local name="$1"
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    echo "$(echo "$name" | sed 's/[^a-z0-9-]/-/g')"
}

generate_storage_class_name() {
    local base="${DEPLOYMENT_NAME}-${NAMESPACE}-sc"
    echo "$(sanitize_name "$base")"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    ((WARN_COUNT++)) || true
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    ((ERROR_COUNT++)) || true
}

check_dependencies() {
    log_info "Validando dependencias..."

    local deps=("kubectl" "yq" "base64")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_error "Dependencia no encontrada: $dep"
            exit 1
        fi
    done

    log_info "✓ Todas las dependencias están instaladas"
}

parse_config() {
    local config_file=$1

    if [[ ! -f "$config_file" ]]; then
        log_error "Archivo de configuración no encontrado: $config_file"
        exit 1
    fi

    log_info "Cargando configuración desde: $config_file"

    DEPLOYMENT_NAME=$(yq eval '.deployment.name' "$config_file")
    NAMESPACE=$(yq eval '.deployment.namespace' "$config_file")
    AUTO_STORAGE_CLASS=$(to_bool "$(yq eval '.storage.autoGenerate // true' "$config_file")")
    local raw_storage_class
    raw_storage_class=$(yq eval '.storage.className // ""' "$config_file")
    if [[ "$AUTO_STORAGE_CLASS" == "true" ]]; then
        STORAGE_CLASS=$(generate_storage_class_name)
    else
        STORAGE_CLASS="$raw_storage_class"
    fi
    REPLICA_COUNT=$(yq eval '.ha.replicaCount // "null"' "$config_file")
    ROOT_PASSWORD=$(yq eval '.credentials.rootPassword // ""' "$config_file")
    HELM_SECRET_NAME="${DEPLOYMENT_NAME}-mariadb-galera"

    if [[ -z "$DEPLOYMENT_NAME" || "$DEPLOYMENT_NAME" == "null" ]]; then
        log_error "deployment.name no está definido en $config_file"
        exit 1
    fi

    if [[ -z "$NAMESPACE" || "$NAMESPACE" == "null" ]]; then
        log_error "deployment.namespace no está definido en $config_file"
        exit 1
    fi

    if [[ -z "$STORAGE_CLASS" || "$STORAGE_CLASS" == "null" ]]; then
        log_warn "storage.className no está definido. Algunas validaciones se omitirán."
    fi
}

ensure_root_password() {
    if [[ -n "$ROOT_PASSWORD" && "$ROOT_PASSWORD" != "null" ]]; then
        return
    fi

    log_warn "Contraseña root no encontrada en el config. Intentando leer el secreto: $HELM_SECRET_NAME"

    local secret_b64
    if secret_b64=$(kubectl get secret "$HELM_SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.mariadb-root-password}' 2>/dev/null); then
        if ROOT_PASSWORD=$(printf '%s' "$secret_b64" | base64 --decode 2>/dev/null); then
            log_info "Contraseña root obtenida desde el secreto."
            return
        fi
    fi

    log_error "No se pudo obtener la contraseña root. Proporciona credentials.rootPassword o asegúrate de que el secreto exista."
    exit 1
}

collect_pods() {
    log_info "Obteniendo lista de pods del cluster..."

    mapfile -t POD_LIST < <(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$DEPLOYMENT_NAME" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

    if [[ ${#POD_LIST[@]} -eq 0 ]]; then
        log_error "No se encontraron pods para la release $DEPLOYMENT_NAME en el namespace $NAMESPACE"
        exit 1
    fi

    log_info "Pods detectados (${#POD_LIST[@]}): ${POD_LIST[*]}"
}

check_pods() {
    log_info "Validando estado de los pods..."

    for pod in "${POD_LIST[@]}"; do
        local phase ready restarts age

        phase=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
        ready=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')
        restarts=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{range .status.containerStatuses[*]}{.restartCount}{end}')
        age=$(kubectl get pod "$pod" -n "$NAMESPACE" --no-headers | awk '{print $6}')

        log_info "  Pod: $pod | Phase: $phase | Ready: ${ready:-N/A} | Restarts: ${restarts:-0} | Age: ${age:-N/A}"

        if [[ "$phase" != "Running" ]]; then
            log_error "    Pod $pod no está en estado Running"
            continue
        fi

        if [[ "$ready" != "True" ]]; then
            log_error "    Pod $pod no está marcado como Ready"
        fi
    done
}

check_galera() {
    log_info "Validando estado de Galera en cada nodo..."

    local query="SHOW STATUS WHERE Variable_name IN ('wsrep_cluster_status','wsrep_cluster_size','wsrep_ready','wsrep_connected','wsrep_local_state_comment');"
    local expected_size
    expected_size=${REPLICA_COUNT:-${#POD_LIST[@]}}
    if [[ "$expected_size" == "null" || -z "$expected_size" ]]; then
        expected_size=${#POD_LIST[@]}
    fi

    for pod in "${POD_LIST[@]}"; do
        local output
        if ! output=$(kubectl exec "$pod" -n "$NAMESPACE" -- env MYSQL_PWD="$ROOT_PASSWORD" mysql -uroot --connect-timeout=5 --batch --skip-column-names -e "$query" 2>/dev/null); then
            log_error "    No se pudo ejecutar el query de estado Galera en $pod"
            continue
        fi

        declare -A status_map=()
        while IFS=$'\t' read -r key value; do
            [[ -z "$key" ]] && continue
            status_map["$key"]=$value
        done <<< "$output"

        local cluster_size=${status_map["wsrep_cluster_size"]:-"N/A"}
        local cluster_status=${status_map["wsrep_cluster_status"]:-"N/A"}
        local ready=${status_map["wsrep_ready"]:-"N/A"}
        local connected=${status_map["wsrep_connected"]:-"N/A"}
        local state_comment=${status_map["wsrep_local_state_comment"]:-"N/A"}

        log_info "  $pod | size=$cluster_size | status=$cluster_status | ready=$ready | connected=$connected | state=$state_comment"

        if [[ "$cluster_status" != "Primary" ]]; then
            log_error "    Cluster status en $pod es $cluster_status (esperado: Primary)"
        fi

        if [[ "$ready" != "ON" ]]; then
            log_error "    wsrep_ready en $pod es $ready (esperado: ON)"
        fi

        if [[ "$connected" != "ON" ]]; then
            log_error "    wsrep_connected en $pod es $connected (esperado: ON)"
        fi

        if [[ "$state_comment" != "Synced" ]]; then
            log_error "    wsrep_local_state_comment en $pod es $state_comment (esperado: Synced)"
        fi

        if [[ "$cluster_size" != "$expected_size" ]]; then
            log_error "    wsrep_cluster_size en $pod es $cluster_size (esperado: $expected_size)"
        fi
    done
}

check_services() {
    log_info "Validando servicios asociados..."
    kubectl get svc -n "$NAMESPACE" -l "app.kubernetes.io/instance=$DEPLOYMENT_NAME"
}

check_pvcs() {
    log_info "Validando PVCs asociados..."

    local pvc_lines=()
    mapfile -t pvc_lines < <(kubectl get pvc -n "$NAMESPACE" -l "app.kubernetes.io/instance=$DEPLOYMENT_NAME" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}')

    if [[ ${#pvc_lines[@]} -eq 0 ]]; then
        log_warn "No se encontraron PVCs asociados al cluster."
        return
    fi

    for line in "${pvc_lines[@]}"; do
        IFS=$'\t' read -r pvc_name pvc_status <<< "$line"
        log_info "  PVC: $pvc_name | Status: $pvc_status"
        if [[ "$pvc_status" != "Bound" ]]; then
            log_error "    PVC $pvc_name no está en estado Bound"
        fi
    done
}

print_summary() {
    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Resultados de la verificación"
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Errores: $ERROR_COUNT | Advertencias: $WARN_COUNT"

    if [[ $ERROR_COUNT -eq 0 ]]; then
        log_info "✓ Cluster MariaDB Galera operativo y sincronizado."
        exit 0
    else
        log_error "✗ Se detectaron problemas en el cluster. Revisa los mensajes anteriores."
        exit 1
    fi
}

print_usage() {
    cat <<EOF
Uso: $0 [-c <config.yaml>] [-h]

Opciones:
  -c, --config    Archivo de configuración YAML usado en el despliegue (por defecto: mariadb-config.yaml)
  -h, --help      Mostrar esta ayuda
EOF
}

main() {
    local config_file="mariadb-config.yaml"

    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                config_file="$2"
                shift 2
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                log_error "Opción desconocida: $1"
                print_usage
                exit 1
                ;;
        esac
    done

    log_info "═══════════════════════════════════════════════════════════"
    log_info "Chequeo de estado MariaDB Galera HA"
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Usando archivo de configuración: $config_file"

    check_dependencies
    parse_config "$config_file"
    ensure_root_password
    collect_pods
    check_pods
    check_galera
    check_services
    check_pvcs
    print_summary
}

main "$@"
