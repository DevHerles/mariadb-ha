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
AUTO_STORAGE_CLASS=true
DELETE_PULL_SECRET=false
PULL_SECRET=""
# Indicadores de override por CLI
CLI_DELETE_NAMESPACE_SET=false
CLI_DELETE_STORAGE_CLASS_SET=false
CLI_DELETE_DATA_PVCS_SET=false
CLI_FORCE_SET=false
CLI_DELETE_PULL_SECRET_SET=false

# Variables globales cargadas desde el config
DEPLOYMENT_NAME=""
NAMESPACE=""
STORAGE_CLASS=""
HELM_SECRET_NAME=""

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
    AUTO_STORAGE_CLASS=$(to_bool "$(yq eval '.storage.autoGenerate // true' "$config_file")")

    local raw_storage_class
    raw_storage_class=$(yq eval '.storage.className // ""' "$config_file")

    if [[ "$AUTO_STORAGE_CLASS" == "true" ]]; then
        if [[ -n "$raw_storage_class" && "$raw_storage_class" != "null" ]]; then
            log_warn "storage.className definido pero será ignorado porque storage.autoGenerate=true"
        fi
        STORAGE_CLASS=$(generate_storage_class_name)
    else
        if [[ -z "$raw_storage_class" || "$raw_storage_class" == "null" ]]; then
            log_error "storage.className debe definirse cuando storage.autoGenerate=false"
            exit 1
        fi
        STORAGE_CLASS="$raw_storage_class"
    fi

    HELM_SECRET_NAME="${DEPLOYMENT_NAME}-mariadb-galera"
    PULL_SECRET=$(yq eval '.registry.pullSecret // ""' "$config_file")

    if [[ -z "$DEPLOYMENT_NAME" || "$DEPLOYMENT_NAME" == "null" ]]; then
        log_error "deployment.name no está definido en $config_file"
        exit 1
    fi

    if [[ -z "$NAMESPACE" || "$NAMESPACE" == "null" ]]; then
        log_error "deployment.namespace no está definido en $config_file"
        exit 1
    fi

    if [[ -z "$STORAGE_CLASS" || "$STORAGE_CLASS" == "null" ]]; then
        log_error "storage.className no está definido en $config_file"
        exit 1
    fi

    local cfg_delete_namespace cfg_delete_storage_class cfg_delete_data_pvcs cfg_delete_pull_secret cfg_force
    cfg_delete_namespace=$(yq eval '.cleanup.deleteNamespace // false' "$config_file")
    cfg_delete_storage_class=$(yq eval '.cleanup.deleteStorageClass // false' "$config_file")
    cfg_delete_data_pvcs=$(yq eval '.cleanup.deleteDataPVCs // false' "$config_file")
    cfg_delete_pull_secret=$(yq eval '.cleanup.deletePullSecret // false' "$config_file")
    cfg_force=$(yq eval '.cleanup.force // false' "$config_file")

    if [[ "$CLI_DELETE_NAMESPACE_SET" != "true" ]]; then
        DELETE_NAMESPACE=$(to_bool "$cfg_delete_namespace")
    fi

    if [[ "$CLI_DELETE_STORAGE_CLASS_SET" != "true" ]]; then
        DELETE_STORAGE_CLASS=$(to_bool "$cfg_delete_storage_class")
    fi

    if [[ "$CLI_DELETE_DATA_PVCS_SET" != "true" ]]; then
        DELETE_DATA_PVCS=$(to_bool "$cfg_delete_data_pvcs")
    fi

    if [[ "$CLI_DELETE_PULL_SECRET_SET" != "true" ]]; then
        DELETE_PULL_SECRET=$(to_bool "$cfg_delete_pull_secret")
    fi

    if [[ "$CLI_FORCE_SET" != "true" ]]; then
        FORCE=$(to_bool "$cfg_force")
    fi

    log_info "Parámetros cargados:"
    log_info "  Deployment: $DEPLOYMENT_NAME"
    log_info "  Namespace: $NAMESPACE"
    log_info "  StorageClass: $STORAGE_CLASS"
    log_info "  Eliminar PVCs de datos: $DELETE_DATA_PVCS"
    log_info "  Eliminar pull secret: $DELETE_PULL_SECRET"
    log_info "  Eliminar namespace: $DELETE_NAMESPACE"
    log_info "  Eliminar StorageClass: $DELETE_STORAGE_CLASS"
    log_info "  Forzar (sin confirmación): $FORCE"
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
    delete_pvs_for_claim "${DEPLOYMENT_NAME}-backup-pvc"
}

delete_pvs_for_claim() {
    local claim=$1
    if [[ -z "$claim" ]]; then
        return
    fi

    local claim_ref="$NAMESPACE/$claim"
    mapfile -t pv_names < <(kubectl get pv --no-headers | awk -v ref="$claim_ref" '$6 == ref {print $1}')

    if [[ ${#pv_names[@]} -eq 0 ]]; then
        log_info "    No se encontraron PVs asociados a $claim"
        return
    fi

    for pv in "${pv_names[@]}"; do
        [[ -z "$pv" ]] && continue
        log_info "    Eliminando PV asociado: $pv"
        kubectl delete pv "$pv"
    done
}

delete_orphan_data_pvs() {
    local claim_prefix="data-${DEPLOYMENT_NAME}"
    local claim_ref_prefix="${NAMESPACE}/${claim_prefix}"
    mapfile -t pv_names < <(kubectl get pv --no-headers | awk -v ref="$claim_ref_prefix" '$6 ~ "^" ref {print $1}')

    if [[ ${#pv_names[@]} -eq 0 ]]; then
        return
    fi

    log_info "Eliminando PVs huérfanos de datos:"
    for pv in "${pv_names[@]}"; do
        [[ -z "$pv" ]] && continue
        log_info "  - PV: $pv"
        kubectl delete pv "$pv"
    done
}

delete_data_pvcs() {
    if [[ "$DELETE_DATA_PVCS" != "true" ]]; then
        return
    fi

    log_info "Buscando PVCs de datos asociados al cluster..."
    mapfile -t pvc_list < <(kubectl get pvc -n "$NAMESPACE" -l app.kubernetes.io/instance="$DEPLOYMENT_NAME" -o name)

    if [[ ${#pvc_list[@]} -eq 0 ]]; then
        log_warn "No se encontraron PVCs de datos para eliminar."
    else
        log_info "Eliminando PVCs de datos:"
        for pvc in "${pvc_list[@]}"; do
            echo "  - $pvc"
            kubectl delete "$pvc" -n "$NAMESPACE"
            local pvc_name="${pvc#persistentvolumeclaim/}"
            delete_pvs_for_claim "$pvc_name"
        done
    fi

    delete_orphan_data_pvs
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

delete_pull_secret() {
    if [[ "$DELETE_PULL_SECRET" != "true" ]]; then
        return
    fi

    if [[ -z "$PULL_SECRET" || "$PULL_SECRET" == "null" ]]; then
        log_warn "No se pudo determinar el pull secret desde la configuración. Se omite la eliminación."
        return
    fi

    log_info "Eliminando pull secret (si existe): $PULL_SECRET"
    kubectl delete secret "$PULL_SECRET" -n "$NAMESPACE" --ignore-not-found
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
      --delete-pull-secret  Eliminar el pull secret definido en registry.pullSecret
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
                CLI_DELETE_DATA_PVCS_SET=true
                shift
                ;;
            --delete-namespace)
                DELETE_NAMESPACE=true
                CLI_DELETE_NAMESPACE_SET=true
                shift
                ;;
            --delete-storage-class)
                DELETE_STORAGE_CLASS=true
                CLI_DELETE_STORAGE_CLASS_SET=true
                shift
                ;;
            --delete-pull-secret)
                DELETE_PULL_SECRET=true
                CLI_DELETE_PULL_SECRET_SET=true
                shift
                ;;
            -f|--force)
                FORCE=true
                CLI_FORCE_SET=true
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
    delete_pull_secret
    delete_storage_class
    delete_namespace

    log_info "═══════════════════════════════════════════════════════════"
    log_info "✓ Desinstalación completada"
    log_info "═══════════════════════════════════════════════════════════"
}

main "$@"
