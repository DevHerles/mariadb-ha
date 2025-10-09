#!/bin/bash

################################################################################
# Script de Despliegue Dinámico de MariaDB Galera en Alta Disponibilidad
# Uso: ./deploy-mariadb-ha.sh -c config.yaml
################################################################################

set -e

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

HELM_SECRET_NAME=""
AUTO_STORAGE_CLASS=true

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
    AUTO_STORAGE_CLASS=$(to_bool "$(yq eval '.storage.autoGenerate // true' "$config_file")")
    
    # Storage
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

# Función para crear StorageClass NFS
create_storage_class() {
    log_info "Verificando StorageClass: $STORAGE_CLASS"
    
    if kubectl get storageclass "$STORAGE_CLASS" &> /dev/null; then
        log_warn "StorageClass $STORAGE_CLASS ya existe, omitiendo creación"
        return
    fi

    log_info "Creando StorageClass: $STORAGE_CLASS"
    
    cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $STORAGE_CLASS
provisioner: cluster.local/nfs-subdir-external-provisionerwso2
parameters:
  server: $NFS_SERVER
  share: $NFS_PATH
  mountPermissions: "0755"
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF
    
    log_info "✓ StorageClass creado exitosamente"
}

# Función para generar values.yaml optimizado para HA
generate_values() {
    log_info "Generando values.yaml optimizado para HA..."
    
    cat > "/tmp/${DEPLOYMENT_NAME}-values.yaml" <<EOF
################################################################################
# MariaDB Galera HA Configuration
# Deployment: $DEPLOYMENT_NAME
# Namespace: $NAMESPACE
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

## Configuración de Galera Cluster
galera:
  name: "${DEPLOYMENT_NAME}-cluster"
  
  bootstrap:
    bootstrapFromNode: 0
    forceSafeToBootstrap: false
  
  mariabackup:
    user: mariadbbackup
    password: "$BACKUP_PASSWORD"
  
  ## Configuración crítica para HA
  cluster:
    name: "${DEPLOYMENT_NAME}-cluster"
    bootstrap: true
  
  ## Parámetros de configuración de Galera
  extraFlags: |
    --wsrep_slave_threads=4
    --wsrep_retry_autocommit=3
    --wsrep_provider_options="gcache.size=1G; gcache.page_size=1G"
    --innodb_flush_log_at_trx_commit=2
    --innodb_buffer_pool_size=1G
    --innodb_log_file_size=256M

## Réplicas - CRÍTICO para HA (mínimo 3)
replicaCount: $REPLICA_COUNT

## Update Strategy - Rolling updates para HA
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    partition: 0

## Recursos - Ajustados para producción
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

## Affinity - CRÍTICO para HA (distribuir pods en diferentes nodos)
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: mariadb-galera
            app.kubernetes.io/instance: $DEPLOYMENT_NAME
        topologyKey: kubernetes.io/hostname
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: node-role.kubernetes.io/worker
              operator: In
              values:
                - "true"

## Tolerations para deployment críticos
tolerations: []

## Pod Disruption Budget - CRÍTICO para HA
podDisruptionBudget:
  enabled: true
  minAvailable: $MIN_AVAILABLE
  maxUnavailable: null

## Probes - Ajustadas para HA
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
  annotations:
    service.alpha.kubernetes.io/tolerate-unready-endpoints: "true"

## Metrics - Monitoreo en producción
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
    namespace: $NAMESPACE
    interval: 30s
    scrapeTimeout: 10s

## Configuración de MariaDB
config: |
  [mysqld]
  ## Configuración de red
  bind-address=0.0.0.0
  max_connections=500
  connect_timeout=10
  wait_timeout=28800
  
  ## Configuración de caché
  table_open_cache=4000
  table_definition_cache=2000
  query_cache_size=0
  query_cache_type=0
  
  ## InnoDB Settings
  innodb_buffer_pool_size=1G
  innodb_log_file_size=256M
  innodb_flush_method=O_DIRECT
  innodb_flush_log_at_trx_commit=2
  innodb_file_per_table=1
  innodb_io_capacity=200
  innodb_read_io_threads=4
  innodb_write_io_threads=4
  
  ## Binary Log
  log_bin=mysql-bin
  binlog_format=ROW
  expire_logs_days=7
  max_binlog_size=100M
  
  ## Slow Query Log
  slow_query_log=1
  slow_query_log_file=/opt/bitnami/mariadb/logs/slow.log
  long_query_time=2
  
  ## Galera Settings
  wsrep_on=ON
  wsrep_provider=/opt/bitnami/mariadb/lib/libgalera_smm.so
  wsrep_sst_method=mariabackup
  wsrep_slave_threads=4
  wsrep_retry_autocommit=3
  
  ## Replicación
  binlog_do_db=$DB_NAME
  
  ## Performance
  max_allowed_packet=256M
  max_heap_table_size=64M
  tmp_table_size=64M
  
  ## Seguridad
  local_infile=0

## Init Scripts (si necesitas)
# initdbScriptsConfigMap: "mariadb-init-scripts"

## Security Context
podSecurityContext:
  enabled: true
  fsGroup: 1001
  runAsGroup: 1001
  runAsUser: 1001
  runAsNonRoot: true

containerSecurityContext:
  enabled: true
  runAsUser: 1001
  runAsGroup: 1001
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL

## Network Policy (opcional, ajustar según necesidad)
networkPolicy:
  enabled: false

## Pod Labels y Annotations
podLabels:
  app: mariadb-galera
  environment: production
  deployment: $DEPLOYMENT_NAME

podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9104"

## Volume Permissions (para NFS)
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
    if helm list -n "$NAMESPACE" | grep -q "$DEPLOYMENT_NAME"; then
        log_warn "Deployment existente encontrado. Actualizando..."
        helm upgrade "$DEPLOYMENT_NAME" bitnami/mariadb-galera \
            --namespace "$NAMESPACE" \
            --values "$values_file" \
            "${helm_password_args[@]}" \
            --wait \
            --timeout 10m
    else
        log_info "Instalando nuevo deployment..."
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
        --timeout=600s
    
    # Mostrar estado de los pods
    log_info "Estado de los pods:"
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance="$DEPLOYMENT_NAME"
    
    # Verificar PVCs
    log_info "Estado de los PVCs:"
    kubectl get pvc -n "$NAMESPACE" -l app.kubernetes.io/instance="$DEPLOYMENT_NAME"
    
    log_info "✓ Verificación completada"
}

# Función para mostrar información de conexión
show_connection_info() {
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Información de Conexión"
    log_info "═══════════════════════════════════════════════════════════"
    echo ""
    echo "Deployment Name: $DEPLOYMENT_NAME"
    echo "Namespace: $NAMESPACE"
    echo "Database: $DB_NAME"
    echo "Username: $DB_USERNAME"
    echo ""
    
    # El chart de Bitnami agrega el sufijo -mariadb-galera automáticamente
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
    echo "Comando de conexión desde un pod:"
    echo "  kubectl run -it --rm mysql-client --image=mysql:8.0 --restart=Never -- \\"
    echo "    mysql -h${service_base}.${NAMESPACE}.svc.cluster.local -u${DB_USERNAME} -p"
    echo ""
    log_info "═══════════════════════════════════════════════════════════"
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
              
              # Lista de servicios a probar en orden
              SERVICES=(
                "\${DEPLOYMENT_NAME}-mariadb-galera.\${NAMESPACE}.svc.cluster.local"
                "\${DEPLOYMENT_NAME}-mariadb-galera"
                "\${DEPLOYMENT_NAME}-mariadb-galera-headless.\${NAMESPACE}.svc.cluster.local"
                "\${DEPLOYMENT_NAME}-mariadb-galera-headless"
                "\${DEPLOYMENT_NAME}-mariadb-galera-0.\${DEPLOYMENT_NAME}-mariadb-galera-headless.\${NAMESPACE}.svc.cluster.local"
                "\${DEPLOYMENT_NAME}-mariadb-galera-0.\${DEPLOYMENT_NAME}-mariadb-galera-headless"
              )
              
              SERVICE_NAME=""
              
              # Probar cada servicio
              echo "Probando conectividad..."
              for svc in "\${SERVICES[@]}"; do
                echo "  Probando: \$svc"
                if mysql -h"\$svc" -uroot -p"\$MARIADB_ROOT_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; then
                  SERVICE_NAME="\$svc"
                  echo "  ✓ Conectado exitosamente"
                  break
                else
                  echo "  ✗ Falló"
                fi
              done
              
              if [ -z "\$SERVICE_NAME" ]; then
                echo ""
                echo "✗ Error fatal: No se pudo conectar a ningún servicio"
                echo "Servicios probados:"
                printf '%s\n' "\${SERVICES[@]}"
                exit 1
              fi
              
              echo ""
              echo "✓ Usando servicio: \$SERVICE_NAME"
              echo ""
              
              # Crear backup
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
              
              # Verificar resultado
              if [ ! -f "\$BACKUP_FILE" ]; then
                echo "✗ Error: Archivo de backup no fue creado"
                exit 1
              fi
              
              BACKUP_SIZE=\$(stat -c%s "\$BACKUP_FILE" 2>/dev/null || stat -f%z "\$BACKUP_FILE" 2>/dev/null)
              
              if [ "\$BACKUP_SIZE" -lt 1000 ]; then
                echo "✗ Error: Backup demasiado pequeño (\$BACKUP_SIZE bytes)"
                echo "Contenido del backup:"
                zcat "\$BACKUP_FILE" | head -20
                exit 1
              fi
              
              echo "✓ Backup completado exitosamente"
              echo "Tamaño: \$(du -h "\$BACKUP_FILE" | cut -f1)"
              ls -lh "\$BACKUP_FILE"
              
              # Verificar contenido
              echo ""
              echo "Primeras líneas del backup:"
              zcat "\$BACKUP_FILE" | head -5
              
              # Limpiar backups antiguos
              echo ""
              echo "Limpiando backups antiguos (retención: \$BACKUP_RETENTION días)..."
              BEFORE=\$(ls -1 /backup/backup-*.sql.gz 2>/dev/null | wc -l)
              find /backup -name "backup-*.sql.gz" -mtime +\$BACKUP_RETENTION -delete
              AFTER=\$(ls -1 /backup/backup-*.sql.gz 2>/dev/null | wc -l)
              DELETED=\$((BEFORE - AFTER))
              echo "Backups eliminados: \$DELETED"
              
              echo ""
              echo "Backups disponibles:"
              ls -lht /backup/backup-*.sql.gz 2>/dev/null | head -10 || echo "No hay otros backups"
              
              echo ""
              echo "=========================================="
              echo "Backup finalizado exitosamente"
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
                exit 0
                ;;
            *)
                log_error "Opción desconocida: $1"
                exit 1
                ;;
        esac
    done
    
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Iniciando Despliegue de MariaDB Galera HA"
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Usando archivo de configuración: $config_file"
    
    check_dependencies
    parse_config "$config_file"
    create_namespace
    create_storage_class
    generate_values
    deploy_mariadb
    create_backup_script
    verify_deployment
    show_connection_info
    
    log_info "═══════════════════════════════════════════════════════════"
    log_info "✓ Despliegue completado exitosamente"
    log_info "═══════════════════════════════════════════════════════════"
}

# Ejecutar
main "$@"
