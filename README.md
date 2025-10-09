0. Prerequisites
```bash
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm repo update
```

1. Install NFS Subdir External Provisioner

```bash
❯ helm upgrade --install nfs-subdir-external-provisioner -n mariadb \
    nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    --set nfs.server=10.9.9.27 \
    --set nfs.path=/mnt/valutwarden \
    --set storageClass.name=nfs-client \
    --set storageClass.defaultClass=false \
    --set nfs.mountOptions={vers=4.1} 
```

## Despliegue recomendado (Helm + script)

1. Ajusta `mariadb-config.yaml` con tus parámetros (namespace, credenciales, storage, registry).
2. Ejecuta el script limpio de despliegue:

```bash
./deploy-mariadb-ha-v2.sh            # usa mariadb-config.yaml por defecto
# o
./deploy-mariadb-ha-v2.sh -c otro-config.yaml
```

El script creará/actualizará el secreto de credenciales, generará un `values.yaml` temporal y lanzará `helm upgrade --install` para `bitnami/mariadb-galera`. Al finalizar mostrará el estado y cómo obtener la contraseña.

3. Para desinstalar y limpiar PVC/PV en caso de reinstalación completa:

```bash
./uninstall-mariadb-ha.sh --delete-data-pvcs --force
```

El script eliminará la release, los PVC y los PV huérfanos asociados. Añade `--delete-namespace` o `--delete-storage-class` si necesitas borrar esos recursos también.

---

### Campos relevantes en `mariadb-config.yaml`

```yaml
registry:
  url: "tanzu-harbor.pngd.gob.pe/pcm"            # Host (puede incluir prefijo de proyecto)
  pullSecret: "harbor-registry-secret"
  repository: "mariadb-galera"                   # Repositorio de la imagen principal (ej: mef/mariadb-galera)
  tag: "12.0.2-debian-12-r0"
  metricsRepository: "mysqld-exporter"           # Opcional: repositorio para el exporter
  metricsTag: "0.17.2-debian-12-r16"
  volumePermissionsRepository: "os-shell"        # Opcional: repositorio para el init de permisos
  volumePermissionsTag: "12-debian-12-r36"
```

---

2. Install mariadb in high availability mode (YAML estático legado)
```bash
kubectl apply -f mariadb.yaml -n mariadb
```

# @mariadb-ha-watchdog.sh — Watchdog para recuperación automática de StatefulSet MariaDB/Galera

`@mariadb-ha-watchdog.sh` es un script de bash que actúa como watchdog para un StatefulSet (STS) de MariaDB con Galera en Kubernetes. Detecta cuando todos los pods del STS están caídos y realiza una recuperación automática segura.

---

## Objetivo

Detectar caídas totales del cluster MariaDB/Galera (todos los pods caídos) y realizar:

- Escalado a 0 réplicas para eliminar pods.
- Creación de un pod temporal que monta el PVC del nodo 0.
- Limpieza de archivos conflictivos (galera.cache, gcache, etc).
- Modificación segura de `grastate.dat` para permitir bootstrap.
- Escalado a 1 réplica para bootstrap.
- Escalado a las réplicas deseadas.

---

## Requisitos

- `kubectl` instalado y configurado con acceso al cluster.
- Imagen Docker accesible para el pod temporal con herramientas básicas (`sh`, `kubectl exec`).
- Opcionalmente `jq` para conteo preciso de pods Ready.

---

## Variables configurables (variables de entorno)

| Variable                 | Descripción                                                     | Valor por defecto                                    |
|-------------------------|-----------------------------------------------------------------|----------------------------------------------------|
| `NS`                    | Namespace donde está el StatefulSet                              | `nextcloud`                                        |
| `STS`                   | Nombre del StatefulSet                                           | `mariadb`                                          |
| `CTX`                   | Contexto de Kubernetes (`kubectl --context`) **REQUIRED**       | *Ninguno* (el script falla si no está definido)    |
| `DATA_DIR`              | Directorio donde se monta el volumen de datos                   | `/var/lib/mysql`                                   |
| `FIX_IMAGE`             | Imagen Docker para el pod temporal de reparación                | `tanzu-harbor.pngd.gob.pe/mef-ped-prod/mariadb:10.6` |
| `SLEEP_SECONDS`         | Intervalo entre chequeos del watchdog (segundos)                | `30`                                               |
| `LOCK_FILE`             | Archivo para lock                                                 | `/tmp/ha-watchdog-XXXXXX/watchdog.lock`            |
| `LOCK_TTL`              | Tiempo máximo para lock en estado "cooloff" (segundos)          | `600`                                              |
| `COOLOFF_ON_FAIL`       | Tiempo de espera tras recuperación fallida (segundos)           | `90`                                               |
| `RUNNING_STALE`         | Tiempo para limpiar lock "running" colgado (segundos)           | `300`                                              |
| `WAIT_POD_DELETE_TIMEOUT` | Timeout para esperar eliminación de pods                       | `180s`                                             |
| `WAIT_FIX_READY_TIMEOUT` | Timeout para esperar pod temporal listo                         | `180s`                                             |
| `WAIT_STS_READY_TIMEOUT` | Timeout para esperar mariadb-0 listo                            | `300s`                                             |
| `DESIRED_REPLICAS_DEFAULT` | Réplicas por defecto si no se detecta valor en StatefulSet    | `3`                                                |

---

## Uso

```bash
# Definir contexto y lanzar watchdog
CTX=wso2-prod-tpm NS=wso2 STS=mariadb ./mariadb-ha-watchdog.sh

# Limpiar lock manualmente
./mariadb-ha-watchdog.sh --unlock

# Forzar ejecución ignorando lock
./mariadb-ha-watchdog.sh --force
```

## Instalar servicio systemd

```bash
./install-service.sh
```
