#!/bin/bash

################################################################################
# Script de Despliegue Automático de MariaDB Galera con Bootstrap Inteligente
# Detecta automáticamente si es primer despliegue y configura bootstrap
# Uso: ./deploy-mariadb-ha-auto.sh -c config.yaml
################################################################################

set -e

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

HELM_SECRET_NAME=""
DEBUG_ENABLED="false"
GALERA_ENABLED=true
GALERA_FORCE_BOOTSTRAP="false"
GALERA_BOOTSTRAP_NODE=""
GALERA_FORCE_SAFE_BOOTSTRAP="false"
HELM_RELEASE_EXISTS="false"
IS_FIRST_DEPLOYMENT="false"

# Función para logging
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

to_bool() {
    local value="${1,,}"
    case "$value" in
        true|1|y|yes) echo "true" ;;
        *) echo "false" ;;
    esac
}

# Función para validar dependencias
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

# Función para detectar si es primer despliegue
detect_first_deployment() {
    log_info "Detectando estado del cluster..."
    
    # Verificar si existe el release de Helm
    if helm status "$DEPLOYMENT_NAME" -n "$NAMESPACE" &> /dev/null; then
        HELM_RELEASE_EXISTS="true"
        log_debug "Release Helm encontrado: $DEPLOYMENT_NAME"
    else
        HELM_RELEASE_EXISTS="false"
        log_debug "Release Helm no encontrado"
    fi
    
    # Verificar si existen PVCs con datos
    local pvc_count=$(kubectl get pvc -n "$NAMESPACE" \
        -l app.kubernetes.io/instance="$DEPLOYMENT_NAME" \
        --ignore-not-found 2>/dev/null | grep -c "data-" || echo "0")
    
    log_debug "PVCs de datos encontrados: $pvc_count"
    
    # Verificar si existen pods
    local pod_count=$(kubectl get pods -n "$NAMESPACE" \
        -l app.kubernetes.io/instance="$DEPLOYMENT_NAME" \
        --ignore-not-found 2>/dev/null | grep -c "mariadb-galera" || echo "0")
    
    log_debug "Pods encontrados: $pod_count"
    
    # Verificar si existe un ConfigMap de estado
    local state_cm="${DEPLOYMENT_NAME}-galera-state"
    local cluster_initialized="false"
    
    if kubectl get configmap "$state_cm" -n "$NAMESPACE" &> /dev/null; then
        cluster_initialized=$(kubectl get configmap "$state_cm" -n "$NAMESPACE" \
            -o jsonpath='{.data.cluster_initialized}' 2>/dev/null || echo "false")
        log_debug "ConfigMap de estado encontrado. cluster_initialized=$cluster_initialized"
    else
        log_debug "ConfigMap de estado no encontrado"
    fi
    
    # Lógica de detección
    if [[ "$HELM_RELEASE_EXISTS" == "false" ]] && [[ "$pvc_count" == "0" ]] && [[ "$cluster_initialized" == "false" ]]; then
        IS_FIRST_DEPLOYMENT="true"
        log_info "🆕 PRIMER DESPLIEGUE detectado"
        log_info "   → Bootstrap automático será habilitado"
    else
        IS_FIRST_DEPLOYMENT="false"
        log_info "♻️  DESPLIEGUE EXISTENTE detectado"
        log_info "   → Bootstrap automático será deshabilitado"
    fi
}

# Función para parsear el archivo de configuración
parse_config() {
    local config_file=$1
    
    if [[ ! -f "$config_file" ]]; then
        log_error "Archivo de configuración no encontrado: $config_file"
        exit 1
    fi
    
    log_info "Parseando configuración desde: $config_file"
    
    # Leer variables usando yq
    DEPLOYMENT_NAME=$(yq eval '.deployment.name' "$config_file")
    NAMESPACE=$(yq eval '.deployment.namespace' "$config_file")
    HELM_SECRET_NAME="${DEPLOYMENT_NAME}-mariadb-galera"
    CHART_VERSION=$(yq eval '.deployment.chartVersion // "latest"' "$config_file")
    
    # Storage
    STORAGE_CLASS=$(yq eval '.storage.className' "$config_file")
    STORAGE_SIZE=$(yq eval '.storage.size' "$config_file")
    NFS_SERVER=$(yq eval '.storage.nfs.server' "$config_file")
    NFS_PATH=$(yq eval '.storage.nfs.path' "$config_file")
    
    # Credenciales
    ROOT_PASSWORD=$(yq eval '.credentials.rootPassword' "$config_file")
    DB_USERNAME=$(yq eval '.credentials.username' "$config_file")
    DB_PASSWORD=$(yq eval '.credentials.password' "$config_file")
    DB_NAME=$(yq eval '.credentials.database' "$config_file")
    BACKUP_PASSWORD=$(yq eval '.credentials.backupPassword' "$config_file")
    
    # Registry
    IMAGE_REGISTRY=$(yq eval '.registry.url' "$config_file")
    PULL_SECRET=$(yq eval '.registry.pullSecret' "$config_file")
    DEBUG_ENABLED=$(to_bool "$(yq eval '.debug.enabled // false' "$config_file")")
    GALERA_ENABLED=$(to_bool "$(yq eval '.galera.enabled // true' "$config_file")")
    
    # HA Configuration
    REPLICA_COUNT=$(yq eval '.ha.replicaCount // 3' "$config_file")
    MIN_AVAILABLE=$(yq eval '.ha.minAvailable // 2' "$config_file")
    
    # Resources
    CPU_REQUEST=$(yq eval '.resources.requests.cpu // "500m"' "$config_file")
    MEM_REQUEST=$(yq eval '.resources.requests.memory // "2Gi"' "$config_file")
    CPU_LIMIT=$(yq eval '.resources.limits.cpu // "2000m"' "$config_file")
    MEM_LIMIT=$(yq eval '.resources.limits.memory // "4Gi"' "$config_file")
    
    # Backup
    BACKUP_ENABLED=$(yq eval '.backup.enabled // false' "$config_file")
    BACKUP_SCHEDULE=$(yq eval '.backup.schedule // "0 2 * * *"' "$config_file")
    BACKUP_RETENTION=$(yq eval '.backup.retention // 7' "$config_file")
}

# Función para configurar bootstrap automático
configure_bootstrap() {
    if [[ "$IS_FIRST_DEPLOYMENT" == "true" ]]; then
        log_info "Configurando bootstrap para primer despliegue..."
        GALERA_FORCE_BOOTSTRAP="true"
        GALERA_BOOTSTRAP_NODE="0"
        GALERA_FORCE_SAFE_BOOTSTRAP="true"
        log_info "  ✓ forceBootstrap: true"
        log_info "  ✓ bootstrapFromNode: 0"
        log_info "  ✓ forceSafeToBootstrap: true"
    else
        log_info "Configurando para cluster existente..."
        GALERA_FORCE_BOOTSTRAP="false"
        GALERA_BOOTSTRAP_NODE=""
        GALERA_FORCE_SAFE_BOOTSTRAP="false"
        log_info "  ✓ forceBootstrap: false"
        log_info "  ✓ Configuración normal de HA"
    fi
}

# Función para crear namespace
create_namespace() {
    log_info "Verificando namespace: $NAMESPACE"
    
    if kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_warn "Namespace $NAMESPACE ya existe"
    else
        log_info "Creando namespace: $NAMESPACE"
        kubectl create namespace "$NAMESPACE"
        kubectl label namespace "$NAMESPACE" name="$NAMESPACE"
    fi
}

# Función para crear o actualizar ConfigMap de estado
create_state_configmap() {
    local state_cm="${DEPLOYMENT_NAME}-galera-state"
    
    log_info "Creando ConfigMap de estado del cluster..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: $state_cm
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/instance: $DEPLOYMENT_NAME
    app.kubernetes.io/component: galera-state
data:
  cluster_initialized: "true"
  first_deployment_date: "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  last_update_date: "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  deployment_count: "1"
EOF
    
    log_info "✓ ConfigMap de estado creado"
}

# Función para verificar y crear el provisioner NFS si no existe
create_nfs_provisioner() {
    local provisioner_name="cluster.local/nfs-${DEPLOYMENT_NAME}-provisioner"
    local nfs_server="$NFS_SERVER"
    local nfs_path="$NFS_PATH"
    
    log_info "Verificando provisioner NFS: $provisioner_name"
    
    if kubectl get deployment "nfs-${DEPLOYMENT_NAME}-provisioner" -n infra &> /dev/null; then
        log_warn "Provisioner NFS ya existe: nfs-${DEPLOYMENT_NAME}-provisioner"
        return 0
    fi
    
    log_info "Creando nuevo provisioner NFS para el cluster..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-${DEPLOYMENT_NAME}-provisioner
  namespace: infra
  labels:
    app: nfs-subdir-external-provisioner
    release: nfs-${DEPLOYMENT_NAME}-provisioner
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nfs-subdir-external-provisioner
      release: nfs-${DEPLOYMENT_NAME}-provisioner
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: nfs-subdir-external-provisioner
        release: nfs-${DEPLOYMENT_NAME}-provisioner
    spec:
      serviceAccountName: nfs-subdir-external-provisionerwso2
      containers:
      - env:
        - name: PROVISIONER_NAME
          value: ${provisioner_name}
        - name: NFS_SERVER
          value: ${nfs_server}
        - name: NFS_PATH
          value: ${nfs_path}
        image: tanzu-harbor.pngd.gob.pe/deploy/nfs-subdir-external-provisioner:v4.0.2
        imagePullPolicy: IfNotPresent
        name: nfs-subdir-external-provisioner
        resources: 
          requests:
            cpu: 10m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi
        securityContext: {}
        volumeMounts:
        - mountPath: /persistentvolumes
          name: nfs-subdir-external-provisioner-root
      volumes:
      - name: nfs-subdir-external-provisioner-root
        nfs:
          path: ${nfs_path}
          server: ${nfs_server}
EOF

    log_info "Esperando a que el provisioner esté ready..."
    kubectl wait --for=condition=ready pod \
        -l release=nfs-${DEPLOYMENT_NAME}-provisioner \
        -n infra \
        --timeout=120s
    
    log_info "✓ Provisioner NFS creado exitosamente: ${provisioner_name}"
}

# Función para crear StorageClass
create_storage_class() {
    local storage_class="$STORAGE_CLASS"
    local provisioner_name="cluster.local/nfs-${DEPLOYMENT_NAME}-provisioner"
    
    log_info "Verificando StorageClass: $storage_class"
    
    if kubectl get storageclass "$storage_class" &> /dev/null; then
        log_warn "StorageClass $storage_class ya existe"
        local current_provisioner=$(kubectl get storageclass "$storage_class" -o jsonpath='{.provisioner}')
        if [[ "$current_provisioner" != "$provisioner_name" ]]; then
            log_warn "StorageClass usa provisioner diferente: $current_provisioner"
            log_info "Actualizando StorageClass para usar: $provisioner_name"
            kubectl delete storageclass "$storage_class"
        else
            log_info "StorageClass ya usa el provisioner correcto"
            return 0
        fi
    fi

    log_info "Creando StorageClass: $storage_class con provisioner: $provisioner_name"
    
    cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $storage_class
provisioner: $provisioner_name
parameters:
  mountPermissions: "0777"
  mountOptions: "nfsvers=3,tcp,timeo=600,retrans=2"
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF
    
    log_info "✓ StorageClass creado exitosamente"
}

# Función para recuperar cluster cuando no hay pods ready
recover_cluster_if_needed() {
    if [[ "$IS_FIRST_DEPLOYMENT" == "true" ]]; then
        return
    fi

    local sts_name="${DEPLOYMENT_NAME}-mariadb-galera"
    if ! kubectl get sts "$sts_name" -n "$NAMESPACE" &>/dev/null; then
        log_debug "StatefulSet $sts_name no encontrado; omitiendo recuperación forzada"
        return
    fi

    local selector="app.kubernetes.io/name=mariadb-galera,app.kubernetes.io/instance=$DEPLOYMENT_NAME"
    local pods_output
    pods_output=$(kubectl get pods -n "$NAMESPACE" -l "$selector" --no-headers 2>/dev/null || true)
    local total_pods
    total_pods=$(printf "%s\n" "$pods_output" | sed '/^\s*$/d' | wc -l | tr -d ' ')
    local ready_pods=0
    if [[ -n "$pods_output" ]]; then
        ready_pods=$(printf "%s\n" "$pods_output" | awk '$2 ~ /^[0-9]+\/[0-9]+$/ {split($2,a,"/"); if (a[1]==a[2] && a[1]>0) ready++} END{print ready+0}')
    fi

    if (( total_pods == 0 )); then
        log_warn "No se encontraron pods activos del cluster. Se intentará recuperación de datos previa al despliegue."
    elif (( ready_pods > 0 )); then
        log_info "Cluster con pods en ejecución detectado (${ready_pods}/${total_pods}). No se requiere recuperación forzada."
        return
    else
        log_warn "Cluster sin pods Ready (${ready_pods}/${total_pods}). Se procederá con recuperación forzada antes del despliegue."
    fi

    local pvc_name="data-${sts_name}-0"
    if ! kubectl get pvc "$pvc_name" -n "$NAMESPACE" &>/dev/null; then
        log_warn "PVC $pvc_name no encontrado. No se puede forzar automáticamente safe_to_bootstrap."
        return
    fi

    log_info "Escalando StatefulSet $sts_name a 0 para limpieza segura..."
    kubectl scale sts "$sts_name" --replicas=0 -n "$NAMESPACE"

    log_info "Esperando eliminación de pods previos..."
    local elapsed=0
    while kubectl get pods -n "$NAMESPACE" -l "$selector" --no-headers 2>/dev/null | grep -q '.'; do
        sleep 5
        elapsed=$((elapsed+5))
        if (( elapsed >= 180 )); then
            log_warn "Timeout esperando eliminación de pods previos. Continuando con la recuperación."
            break
        fi
    done

    local fix_pod="${DEPLOYMENT_NAME}-galera-recovery"
    local fix_image_registry="$IMAGE_REGISTRY"
    if [[ -z "$fix_image_registry" || "$fix_image_registry" == "null" ]]; then
        fix_image_registry="docker.io/bitnami"
    fi
    local fix_image="${fix_image_registry}/mariadb-galera:12.0.2-debian-12-r0"

    log_info "Creando pod temporal $fix_pod para ajustar safe_to_bootstrap..."
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $fix_pod
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  securityContext:
    runAsUser: 0
    runAsGroup: 0
    fsGroup: 0
    runAsNonRoot: false
$(if [[ -n "$PULL_SECRET" && "$PULL_SECRET" != "null" ]]; then
cat <<EOS
  imagePullSecrets:
    - name: $PULL_SECRET
EOS
fi)
  containers:
  - name: fix
    image: $fix_image
    command: ["/bin/sh","-c","sleep 600"]
    volumeMounts:
    - name: data
      mountPath: /bitnami/mariadb
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: $pvc_name
EOF

    if ! kubectl wait -n "$NAMESPACE" --for=condition=Ready pod/"$fix_pod" --timeout=180s; then
        log_warn "No se pudo preparar el pod temporal $fix_pod. Cancelando recuperación forzada."
        kubectl delete pod "$fix_pod" -n "$NAMESPACE" --ignore-not-found
        return
    fi

    log_info "Marcando safe_to_bootstrap=1 en los archivos encontrados..."
    if ! kubectl exec -n "$NAMESPACE" "$fix_pod" -- /bin/bash -c '
set -e
DATA_MOUNT="/bitnami/mariadb"
TARGET_FILES=$(find "$DATA_MOUNT" -maxdepth 6 -name grastate.dat 2>/dev/null | sort)
if [ -z "$TARGET_FILES" ]; then
  mkdir -p "$DATA_MOUNT/data"
  TARGET_FILES="$DATA_MOUNT/data/grastate.dat"
fi
for TARGET_FILE in $TARGET_FILES; do
  echo "[recovery] Ajustando safe_to_bootstrap en $TARGET_FILE"
  TARGET_DIR=$(dirname "$TARGET_FILE")
  rm -f "$TARGET_DIR"/gvwstate.dat "$TARGET_DIR"/galera.cache "$TARGET_DIR"/galera.cache.lock "$TARGET_DIR"/galera.state \
        "$TARGET_DIR"/gcache.page* "$TARGET_DIR"/gcache.* "$TARGET_DIR"/gcache* 2>/dev/null || true
  if [ -f "$TARGET_FILE" ]; then
    if grep -q "^safe_to_bootstrap: 0" "$TARGET_FILE"; then
      sed -i "s/^safe_to_bootstrap: 0/safe_to_bootstrap: 1/" "$TARGET_FILE"
    elif ! grep -q "^safe_to_bootstrap:" "$TARGET_FILE"; then
      echo "safe_to_bootstrap: 1" >> "$TARGET_FILE"
    fi
  else
    UUID=$( (command -v uuidgen >/dev/null 2>&1 && uuidgen) || (cat /proc/sys/kernel/random/uuid 2>/dev/null) || echo 00000000-0000-0000-0000-000000000000 )
    {
      echo "# GALERA saved state"
      echo "version: 2.1"
      echo "uuid:    $UUID"
      echo "seqno:   -1"
      echo "safe_to_bootstrap: 1"
    } > "$TARGET_FILE"
  fi
done
MARIADB_UID=$(id -u mysql 2>/dev/null || echo 1001)
MARIADB_GID=$(id -g mysql 2>/dev/null || echo 1001)
chown -R "${MARIADB_UID}:${MARIADB_GID}" "$DATA_MOUNT" 2>/dev/null || true
chmod -R g+rwX "$DATA_MOUNT" 2>/dev/null || true
'; then
        log_warn "Falló el ajuste de safe_to_bootstrap. Eliminando pod temporal $fix_pod."
        kubectl delete pod "$fix_pod" -n "$NAMESPACE" --ignore-not-found
        return
    fi

    kubectl delete pod "$fix_pod" -n "$NAMESPACE" --ignore-not-found

    log_info "Re-escalando StatefulSet $sts_name a 1 réplica para bootstrap seguro..."
    kubectl scale sts "$sts_name" --replicas=1 -n "$NAMESPACE"
    if ! kubectl wait --for=condition=ready pod/"${sts_name}-0" -n "$NAMESPACE" --timeout=300s; then
        log_warn "Timeout esperando que ${sts_name}-0 quede Ready tras recuperación. Continuando de todas maneras."
    fi

    if (( REPLICA_COUNT > 1 )); then
        log_info "Escalando StatefulSet $sts_name a $REPLICA_COUNT réplicas..."
        kubectl scale sts "$sts_name" --replicas="$REPLICA_COUNT" -n "$NAMESPACE"
    fi

    log_info "Recuperación previa al despliegue completada."
}

# Función para generar values.yaml con bootstrap automático
generate_values() {
    log_info "Generando values.yaml optimizado para HA..."
    
    local cluster_bootstrap="false"
    local force_safe_to_bootstrap="false"
    if [[ "$IS_FIRST_DEPLOYMENT" == "true" ]]; then
        cluster_bootstrap="true"
        force_safe_to_bootstrap="true"
    fi
    
    cat > "/tmp/${DEPLOYMENT_NAME}-values.yaml" <<EOF
################################################################################
# MariaDB Galera HA Configuration - Auto Bootstrap
# Deployment: $DEPLOYMENT_NAME
# Namespace: $NAMESPACE
# First Deployment: $IS_FIRST_DEPLOYMENT
# Generated: $(date)
################################################################################

global:
  storageClass: "$STORAGE_CLASS"
  imageRegistry: "$IMAGE_REGISTRY"
  imagePullSecrets:
    - $PULL_SECRET
  security:
    allowInsecureImages: true

image:
  registry: $IMAGE_REGISTRY
  repository: mariadb-galera
  tag: 12.0.2-debian-12-r0
  pullPolicy: IfNotPresent
  pullSecrets:
    - $PULL_SECRET
  debug: true

## Autenticación
auth:
  rootPassword: "$ROOT_PASSWORD"
  username: "$DB_USERNAME"
  password: "$DB_PASSWORD"
  database: "$DB_NAME"
  replicationPassword: "$BACKUP_PASSWORD"
  forcePassword: true
  usePasswordFiles: false

rootUser:
  password: "$ROOT_PASSWORD"

db:
  user: "$DB_USERNAME"
  password: "$DB_PASSWORD"

replicationUser:
  password: "$BACKUP_PASSWORD"

primary:
  image:
    debug: true
  extraEnvVars:
    - name: BITNAMI_DEBUG
      value: "true"
    - name: NAMI_DEBUG
      value: "--log-level trace"

## Configuración de Galera Cluster con Bootstrap Automático
galera:
  enabled: $GALERA_ENABLED
  name: "${DEPLOYMENT_NAME}-cluster"
  bootstrap:
    bootstrapFromNode: 0
    forceSafeToBootstrap: $force_safe_to_bootstrap

  cluster:
    name: "${DEPLOYMENT_NAME}-cluster"
    bootstrap: $cluster_bootstrap
  
  mariabackup:
    user: mariadbbackup
    password: "$BACKUP_PASSWORD"
  
  extraFlags: |
    --wsrep_slave_threads=4
    --wsrep_retry_autocommit=3
    --wsrep_provider_options="gcache.size=1G; gcache.page_size=1G"
    --innodb_flush_log_at_trx_commit=2
    --innodb_buffer_pool_size=1G
    --innodb_log_file_size=256M
    --log-error-verbosity=3
    --wsrep_debug=1

## Réplicas
replicaCount: $REPLICA_COUNT

## Update Strategy
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    partition: 0

## Recursos
resources:
  requests:
    memory: "$MEM_REQUEST"
    cpu: "$CPU_REQUEST"
  limits:
    memory: "$MEM_LIMIT"
    cpu: "$CPU_LIMIT"

## Persistencia
persistence:
  enabled: true
  storageClass: "$STORAGE_CLASS"
  accessModes:
    - ReadWriteOnce
  size: $STORAGE_SIZE
  annotations:
    volume.beta.kubernetes.io/storage-class: "$STORAGE_CLASS"
  selector: {}

## Affinity
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: mariadb-galera
            app.kubernetes.io/instance: $DEPLOYMENT_NAME
        topologyKey: kubernetes.io/hostname

## Pod Disruption Budget
podDisruptionBudget:
  enabled: true
  minAvailable: $MIN_AVAILABLE
  maxUnavailable: null

## Probes
livenessProbe:
  enabled: true
  initialDelaySeconds: 120
  periodSeconds: 10
  timeoutSeconds: 5
  successThreshold: 1
  failureThreshold: 3

readinessProbe:
  enabled: true
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  successThreshold: 1
  failureThreshold: 3

startupProbe:
  enabled: true
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  successThreshold: 1
  failureThreshold: 30

## Service
service:
  type: ClusterIP
  port: 3306
  headless:
    publishNotReadyAddresses: true

## Metrics
metrics:
  enabled: true
  image:
    registry: $IMAGE_REGISTRY
    repository: mysqld-exporter
    tag: 0.17.2-debian-12-r16
    pullPolicy: IfNotPresent
    pullSecrets:
      - $PULL_SECRET
  
  resources:
    requests:
      memory: "128Mi"
      cpu: "100m"
    limits:
      memory: "256Mi"
      cpu: "200m"
  
  serviceMonitor:
    enabled: false

## Configuración de MariaDB
config: |
  [mysqld]
  bind-address=0.0.0.0
  max_connections=500
  innodb_buffer_pool_size=1G
  innodb_log_file_size=256M
  innodb_flush_log_at_trx_commit=2
  log_bin=mysql-bin
  binlog_format=ROW
  wsrep_on=ON
  wsrep_provider=/opt/bitnami/mariadb/lib/libgalera_smm.so
  wsrep_sst_method=mariabackup
  wsrep_debug=1
  log_error_verbosity=3
  general_log=1
  general_log_file=/opt/bitnami/mariadb/logs/general.log

## Security Context para NFS
podSecurityContext:
  enabled: false

containerSecurityContext:
  enabled: false

securityContext:
  runAsUser: 0
  runAsGroup: 0
  fsGroup: 0
  fsGroupChangePolicy: "OnRootMismatch"

## Volume Permissions
volumePermissions:
  enabled: true
  image:
    registry: $IMAGE_REGISTRY
    repository: os-shell
    tag: 12-debian-12-r36
    pullPolicy: IfNotPresent
    pullSecrets:
      - $PULL_SECRET
  securityContext:
    runAsUser: 0
    runAsGroup: 0
    fsGroup: 0
  resources:
    requests:
      memory: "64Mi"
      cpu: "50m"
    limits:
      memory: "128Mi"
      cpu: "100m"

EOF

    log_info "✓ Values.yaml generado: /tmp/${DEPLOYMENT_NAME}-values.yaml"
    
    if [[ "$IS_FIRST_DEPLOYMENT" == "true" ]]; then
        log_info "   → Configurado con BOOTSTRAP AUTOMÁTICO"
    else
        log_info "   → Configurado para CLUSTER EXISTENTE"
    fi
}

# Función para instalar/actualizar Helm Chart
deploy_mariadb() {
    log_info "Desplegando MariaDB Galera HA..."
    local values_file="/tmp/${DEPLOYMENT_NAME}-values.yaml"
    local -a helm_password_args=(
        "--set-string" "auth.rootPassword=$ROOT_PASSWORD"
        "--set-string" "auth.password=$DB_PASSWORD"
        "--set-string" "auth.replicationPassword=$BACKUP_PASSWORD"
        "--set-string" "galera.mariabackup.password=$BACKUP_PASSWORD"
        "--set-string" "rootUser.password=$ROOT_PASSWORD"
        "--set-string" "db.password=$DB_PASSWORD"
        "--set-string" "replicationUser.password=$BACKUP_PASSWORD"
    )
    
    # Agregar repositorio de Bitnami si no existe
    if ! helm repo list | grep -q "bitnami"; then
        log_info "Agregando repositorio Bitnami..."
        helm repo add bitnami https://charts.bitnami.com/bitnami
    fi
    
    helm repo update
    
    # Instalar o actualizar
    if [[ "$HELM_RELEASE_EXISTS" == "true" ]]; then
        recover_cluster_if_needed
        log_warn "Deployment existente encontrado. Actualizando..."
        helm upgrade "$DEPLOYMENT_NAME" bitnami/mariadb-galera \
            --namespace "$NAMESPACE" \
            --values "$values_file" \
            "${helm_password_args[@]}" \
            --wait \
            --timeout 10m
    else
        log_info "Instalando nuevo deployment con BOOTSTRAP AUTOMÁTICO..."
        helm install "$DEPLOYMENT_NAME" bitnami/mariadb-galera \
            --namespace "$NAMESPACE" \
            --values "$values_file" \
            "${helm_password_args[@]}" \
            --wait \
            --timeout 10m \
            --create-namespace
    fi
    
    log_info "✓ MariaDB Galera desplegado exitosamente"
}

# Función para verificar el estado del cluster
verify_deployment() {
    log_info "Verificando estado del deployment..."
    
    # Esperar a que todos los pods estén listos
    log_info "Esperando a que los pods estén listos..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=mariadb-galera,app.kubernetes.io/instance="$DEPLOYMENT_NAME" \
        -n "$NAMESPACE" \
        --timeout=600s || {
            log_error "Timeout esperando pods ready. Mostrando logs del pod-0..."
            kubectl logs -n "$NAMESPACE" "${DEPLOYMENT_NAME}-mariadb-galera-0" --tail=50
            return 1
        }
    
    # Mostrar estado de los pods
    log_info "Estado de los pods:"
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance="$DEPLOYMENT_NAME"
    
    # Verificar cluster size
    log_info "Verificando tamaño del cluster Galera..."
    local cluster_size=$(kubectl exec -n "$NAMESPACE" "${DEPLOYMENT_NAME}-mariadb-galera-0" -- \
        mysql -uroot -p"$ROOT_PASSWORD" -e "SHOW STATUS LIKE 'wsrep_cluster_size';" -sN | awk '{print $2}')
    
    log_info "Cluster size: $cluster_size / $REPLICA_COUNT"
    
    if [[ "$cluster_size" == "$REPLICA_COUNT" ]]; then
        log_info "✓ Cluster formado correctamente con $cluster_size nodos"
    else
        log_warn "⚠ Cluster size no coincide. Esperado: $REPLICA_COUNT, Actual: $cluster_size"
    fi
    
    # Verificar PVCs
    log_info "Estado de los PVCs:"
    kubectl get pvc -n "$NAMESPACE" -l app.kubernetes.io/instance="$DEPLOYMENT_NAME"
    
    log_info "✓ Verificación completada"
}

# Función para mostrar información de conexión
show_connection_info() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "Información de Conexión"
    log_info "═══════════════════════════════════════════════════════"
    echo ""
    echo "Deployment Name: $DEPLOYMENT_NAME"
    echo "Namespace: $NAMESPACE"
    echo "Database: $DB_NAME"
    echo "Username: $DB_USERNAME"
    echo "Primer Despliegue: $IS_FIRST_DEPLOYMENT"
    echo ""
    
    local service_base="${DEPLOYMENT_NAME}-mariadb-galera"
    
    echo "Servicio de escritura/lectura:"
    echo "  ${service_base}.${NAMESPACE}.svc.cluster.local:3306"
    echo ""
    echo "Servicio headless (acceso directo a pods):"
    echo "  ${service_base}-headless.${NAMESPACE}.svc.cluster.local:3306"
    echo ""
    echo "Pods individuales:"
    for i in $(seq 0 $((REPLICA_COUNT-1))); do
        echo "  ${service_base}-${i}.${service_base}-headless.${NAMESPACE}.svc.cluster.local:3306"
    done
    echo ""
    echo "Para obtener la contraseña root:"
    echo "  kubectl get secret $HELM_SECRET_NAME -n $NAMESPACE -o jsonpath='{.data.mariadb-root-password}' | base64 -d"
    echo ""
    echo "Verificar estado del cluster:"
    echo "  kubectl exec -n $NAMESPACE ${service_base}-0 -- mysql -uroot -p -e \"SHOW STATUS LIKE 'wsrep%';\""
    echo ""
    log_info "═══════════════════════════════════════════════════════"
}

# Función para crear script de backup
create_backup_script() {
    if [[ "$BACKUP_ENABLED" != "true" ]]; then
        return
    fi
    
    log_info "Creando CronJob de backup..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${DEPLOYMENT_NAME}-backup
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/instance: $DEPLOYMENT_NAME
spec:
  schedule: "$BACKUP_SCHEDULE"
  successfulJobsHistoryLimit: $BACKUP_RETENTION
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        metadata:
          labels:
            app.kubernetes.io/instance: $DEPLOYMENT_NAME
        spec:
          restartPolicy: OnFailure
          imagePullSecrets:
          - name: $PULL_SECRET
          containers:
          - name: mariadb-backup
            image: ${IMAGE_REGISTRY}/mariadb-galera:12.0.2-debian-12-r0
            env:
            - name: MARIADB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: $HELM_SECRET_NAME
                  key: mariadb-root-password
            - name: DEPLOYMENT_NAME
              value: "$DEPLOYMENT_NAME"
            - name: NAMESPACE
              value: "$NAMESPACE"
            - name: BACKUP_RETENTION
              value: "$BACKUP_RETENTION"
            volumeMounts:
            - name: backup-storage
              mountPath: /backup
            command:
            - /bin/bash
            - -c
            - |
              set -e
              
              echo "=========================================="
              echo "Iniciando backup de MariaDB Galera"
              echo "Fecha: \$(date)"
              echo "Deployment: \$DEPLOYMENT_NAME"
              echo "Namespace: \$NAMESPACE"
              echo "=========================================="
              
              SERVICE_NAME="\${DEPLOYMENT_NAME}-mariadb-galera.\${NAMESPACE}.svc.cluster.local"
              BACKUP_FILE="/backup/backup-\$(date +%Y%m%d-%H%M%S).sql.gz"
              
              echo "Creando backup en: \$BACKUP_FILE"
              
              /opt/bitnami/mariadb/bin/mariadb-dump \
                -h"\$SERVICE_NAME" \
                -uroot \
                -p"\$MARIADB_ROOT_PASSWORD" \
                --all-databases \
                --single-transaction \
                --quick \
                --routines \
                --triggers \
                --events \
                --hex-blob \
                --add-drop-database \
                2>&1 | gzip > "\$BACKUP_FILE"
              
              echo "✓ Backup completado: \$(du -h "\$BACKUP_FILE" | cut -f1)"
              
              # Limpiar backups antiguos
              find /backup -name "backup-*.sql.gz" -mtime +\$BACKUP_RETENTION -delete
              
              echo "=========================================="
          volumes:
          - name: backup-storage
            persistentVolumeClaim:
              claimName: ${DEPLOYMENT_NAME}-backup-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${DEPLOYMENT_NAME}-backup-pvc
  namespace: $NAMESPACE
spec:
  storageClassName: $STORAGE_CLASS
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 50Gi
EOF
    
    log_info "✓ CronJob de backup creado"
}

# Función principal
main() {
    local config_file="mariadb-config.yaml"
    
    # Parse argumentos
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                config_file="$2"
                shift 2
                ;;
            -h|--help)
                echo "Uso: $0 [-c <config.yaml>]"
                echo ""
                echo "Opciones:"
                echo "  -c, --config    Archivo de configuración YAML (por defecto: mariadb-config.yaml)"
                echo "  -h, --help      Mostrar esta ayuda"
                echo ""
                echo "Características:"
                echo "  • Detección automática de primer despliegue"
                echo "  • Bootstrap automático de Galera en primer deploy"
                echo "  • Configuración inteligente para clusters existentes"
                echo "  • Persistencia de estado mediante ConfigMap"
                exit 0
                ;;
            *)
                log_error "Opción desconocida: $1"
                exit 1
                ;;
        esac
    done
    
    log_info "═══════════════════════════════════════════════════════"
    log_info "🚀 Despliegue Automático de MariaDB Galera HA"
    log_info "═══════════════════════════════════════════════════════"
    log_info "Usando archivo de configuración: $config_file"
    echo ""
    
    check_dependencies
    parse_config "$config_file"
    create_namespace
    detect_first_deployment
    configure_bootstrap
    create_nfs_provisioner
    create_storage_class
    generate_values
    deploy_mariadb
    
    # Crear ConfigMap de estado después del primer despliegue exitoso
    if [[ "$IS_FIRST_DEPLOYMENT" == "true" ]]; then
        create_state_configmap
    fi
    
    create_backup_script
    verify_deployment
    show_connection_info
    
    echo ""
    log_info "═══════════════════════════════════════════════════════"
    log_info "✓ Despliegue completado exitosamente"
    log_info "═══════════════════════════════════════════════════════"
    
    if [[ "$IS_FIRST_DEPLOYMENT" == "true" ]]; then
        echo ""
        log_info "📝 Notas importantes:"
        log_info "   • Este fue un PRIMER DESPLIEGUE con bootstrap automático"
        log_info "   • El ConfigMap '${DEPLOYMENT_NAME}-galera-state' ha sido creado"
        log_info "   • Futuros deploys usarán configuración normal de HA"
        log_info "   • No necesitas modificar la configuración manualmente"
    fi
}

# Ejecutar
main "$@"

