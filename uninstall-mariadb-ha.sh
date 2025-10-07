#!/bin/bash

################################################################################
# Script de Desinstalación de MariaDB Galera en Alta Disponibilidad
# Uso: ./uninstall-mariadb-ha.sh -c config.yaml [opciones]
# Ejemplo: ./uninstall-mariadb-ha.sh -c mariadb-config.yaml --delete-data-pvcs --delete-namespace --delete-storage-class
################################################################################

set -e

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Flags
DELETE_NAMESPACE=false
DELETE_STORAGE_CLASS=false
DELETE_DATA_PVCS=false
FORCE=false

# Variables globales cargadas desde el config
DEPLOYMENT_NAME=""
NAMESPACE=""
STORAGE_CLASS=""
HELM_SECRET_NAME=""

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_dependencies() {
    log_info "Validando dependencias..."

    local deps=("kubectl" "helm" "yq")
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
    STORAGE_CLASS=$(yq eval '.storage.className' "$config_file")
    HELM_SECRET_NAME="${DEPLOYMENT_NAME}-mariadb-galera"
}

confirm_action() {
    if [[ "$FORCE" == "true" ]]; then
        return
    fi

    echo ""
    log_warn "Esta operación eliminará el release Helm y recursos asociados."
    if [[ "$DELETE_DATA_PVCS" == "true" ]]; then
        log_warn "- Se eliminarán los PVCs de datos del cluster."
    fi
    if [[ "$DELETE_NAMESPACE" == "true" ]]; then
        log_warn "- Se eliminará el namespace completo: $NAMESPACE"
    fi
    if [[ "$DELETE_STORAGE_CLASS" == "true" ]]; then
        log_warn "- Se eliminará el StorageClass: $STORAGE_CLASS"
    fi
    echo ""
    read -r -p "¿Deseas continuar? [y/N]: " confirmation
    if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
        log_info "Operación cancelada por el usuario."
        exit 0
    fi
}

delete_backup_resources() {
    log_info "Eliminando CronJob de backup (si existe)..."
    kubectl delete cronjob "${DEPLOYMENT_NAME}-backup" -n "$NAMESPACE" --ignore-not-found

    log_info "Eliminando PVC de backups (si existe)..."
    kubectl delete pvc "${DEPLOYMENT_NAME}-backup-pvc" -n "$NAMESPACE" --ignore-not-found
}

delete_data_pvcs() {
    if [[ "$DELETE_DATA_PVCS" != "true" ]]; then
        return
    fi

    log_info "Buscando PVCs de datos asociados al cluster..."
    mapfile -t pvc_list < <(kubectl get pvc -n "$NAMESPACE" -l app.kubernetes.io/instance="$DEPLOYMENT_NAME" -o name)

    if [[ ${#pvc_list[@]} -eq 0 ]]; then
        log_warn "No se encontraron PVCs de datos para eliminar."
        return
    fi

    log_info "Eliminando PVCs de datos:"
    for pvc in "${pvc_list[@]}"; do
        echo "  - $pvc"
        kubectl delete "$pvc" -n "$NAMESPACE"
    done
}

delete_helm_release() {
    if helm status "$DEPLOYMENT_NAME" -n "$NAMESPACE" > /dev/null 2>&1; then
        log_info "Desinstalando release Helm: $DEPLOYMENT_NAME (namespace: $NAMESPACE)"
        helm uninstall "$DEPLOYMENT_NAME" -n "$NAMESPACE"
        log_info "✓ Release eliminado correctamente"
    else
        log_warn "Release Helm no encontrado en el namespace. Se omite la desinstalación."
    fi
}

delete_secret() {
    log_info "Eliminando secreto residual (si existe): $HELM_SECRET_NAME"
    kubectl delete secret "$HELM_SECRET_NAME" -n "$NAMESPACE" --ignore-not-found
}

delete_storage_class() {
    if [[ "$DELETE_STORAGE_CLASS" != "true" ]]; then
        return
    fi

    if [[ -z "$STORAGE_CLASS" || "$STORAGE_CLASS" == "null" ]]; then
        log_warn "No se pudo determinar el StorageClass desde la configuración. Se omite la eliminación."
        return
    fi

    log_info "Eliminando StorageClass: $STORAGE_CLASS"
    kubectl delete storageclass "$STORAGE_CLASS" --ignore-not-found
}

delete_namespace() {
    if [[ "$DELETE_NAMESPACE" != "true" ]]; then
        return
    fi

    log_info "Eliminando namespace completo: $NAMESPACE"
    kubectl delete namespace "$NAMESPACE"
}

print_usage() {
    cat <<EOF
Uso: $0 [-c <config.yaml>] [opciones]

Opciones:
  -c, --config              Archivo de configuración YAML usado en el despliegue (por defecto: mariadb-config.yaml)
      --delete-data-pvcs    Eliminar PVCs de datos creados por la release
      --delete-namespace    Eliminar el namespace completo una vez desinstalado
      --delete-storage-class Eliminar el StorageClass definido en el config
  -f, --force               No solicitar confirmación interactiva
  -h, --help                Mostrar esta ayuda
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
            --delete-data-pvcs)
                DELETE_DATA_PVCS=true
                shift
                ;;
            --delete-namespace)
                DELETE_NAMESPACE=true
                shift
                ;;
            --delete-storage-class)
                DELETE_STORAGE_CLASS=true
                shift
                ;;
            -f|--force)
                FORCE=true
                shift
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
    log_info "Iniciando desinstalación de MariaDB Galera HA"
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Usando archivo de configuración: $config_file"

    check_dependencies
    parse_config "$config_file"
    confirm_action
    delete_backup_resources
    delete_helm_release
    delete_data_pvcs
    delete_secret
    delete_storage_class
    delete_namespace

    log_info "═══════════════════════════════════════════════════════════"
    log_info "✓ Desinstalación completada"
    log_info "═══════════════════════════════════════════════════════════"
}

main "$@"
