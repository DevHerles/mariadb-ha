# MariaDB Galera HA Toolkit

Colección de scripts para desplegar, validar, recuperar y administrar clústeres MariaDB Galera en Kubernetes con un alto nivel de automatización. Está pensada para entornos donde se requiere bootstrap seguro, almacenamiento NFS compartido, backups programados y un watchdog con alertas.

---

## 1. Requisitos Previos
- Acceso a un clúster Kubernetes con privilegios administrativos (`kubectl` configurado).
- Herramientas locales: `kubectl`, `helm`, `yq`, `bash`, `curl`, `uuidgen` (o similar). Para algunas rutas de recuperación se usa `jq` y `python3`.
- Acceso a un repositorio de imágenes (por ejemplo, Harbor) y a un punto de montaje NFS accesible desde todos los nodos.
- Para ejecutar el watchdog como servicio: máquina Linux con `systemd`, privilegios `sudo` y conectividad hacia el clúster.

---

## 2. Estructura del Repositorio

| Archivo / Carpeta | Descripción |
|-------------------|-------------|
| `mariadb-dev.yaml` | Plantilla de configuración con parámetros de despliegue, credenciales, Storage y políticas de limpieza. |
| `deploy-mariadb-ha.sh` | Script principal de despliegue/actualización del chart `bitnami/mariadb-galera`, detecta primer deploy y gestiona bootstrap seguro. |
| `check-mariadb-ha.sh` | Validador del estado del clúster (pods, Galera, servicios, PVCs). |
| `uninstall-mariadb-ha.sh` | Desinstalador con opciones para eliminar PVCs, namespace, StorageClass y secretos. |
| `mariadb-ha-watchdog.sh` | Watchdog que repara clústeres completamente caídos, limpia artefactos de Galera y escala a las réplicas deseadas. |
| `install-service.sh` / `uninstall-watchdog-service.sh` | Scripts para instalar/desinstalar el watchdog como servicio `systemd`. |
| `mariadb-ha-watchdog.service` | Plantilla del unit file de `systemd` (para ajustes manuales). |

> Nota: Revisa las plantillas antes de ejecutar en producción; las contraseñas incluidas son de demostración.

---

## 3. Flujo de Trabajo Sugerido

1. Ajusta la configuración base (`mariadb-dev.yaml`) con tus datos y guárdala como `mariadb-config.yaml`.
2. Asegura que exista un provisioner NFS (puedes reutilizar uno general o dejar que el script despliegue uno dedicado).
3. Ejecuta `./deploy-mariadb-ha.sh` (o `-c <archivo>`).
4. Valida el entorno con `./check-mariadb-ha.sh`.
5. Instala el watchdog como servicio si necesitas recuperación automática en caso de fallos.
6. Programa revisiones periódicas de backups y estado; desinstala con `./uninstall-mariadb-ha.sh` cuando sea necesario.

---

## 4. Configuración (`mariadb-config.yaml`)

La plantilla incluye todas las secciones claves. Principales campos:

| Sección | Campos | Explicación |
|---------|--------|-------------|
| `deployment` | `name`, `namespace`, `chartVersion` | Identidad del release Helm y namespace de destino. |
| `storage` | `className`, `size`, `nfs.server`, `nfs.path` | Detalle del StorageClass y punto NFS. |
| `credentials` | `rootPassword`, `username`, `password`, `database`, `backupPassword` | Credenciales iniciales del chart y de SST/backup. |
| `registry` | `url`, `pullSecret` | Registry privado a usar y secreto asociado. |
| `ha` | `replicaCount`, `minAvailable` | Parámetros de alta disponibilidad y pod disruption budget. |
| `resources` | `requests/limits`, `vpa` | Límites por pod y política de Vertical Pod Autoscaler. |
| `backup` | `enabled`, `schedule`, `retention` | CronJob de backups lógicos (`mysqldump` + gzip). |
| `galera` | `enabled` | Mantén en `true` para desplegar Galera (bootstrap automático). |
| `debug` | `enabled` | Incrementa verbosidad del chart. |
| `cleanup` | `deleteDataPVCs`, `deleteNamespace`, `deleteStorageClass`, `deletePullSecret`, `force` | Se usan por el desinstalador como defaults. |

> Recomendación: almacena las credenciales reales en un gestor de secretos o Kubernetes Secret y evita versionarlas.

---

## 5. Despliegue Automatizado (`deploy-mariadb-ha.sh`)

### Uso Básico
```bash
./deploy-mariadb-ha.sh                # usa mariadb-config.yaml
./deploy-mariadb-ha.sh -c otra.yaml   # ruta personalizada
```

### Funcionalidad Clave
- Valida dependencias (`kubectl`, `helm`, `yq`).
- Crea namespace, provisioner NFS dedicado y StorageClass si no existen.
- Detecta primer despliegue (sin release, sin PVCs, sin ConfigMap) y habilita bootstrap seguro de Galera (`forceBootstrap`, `bootstrapFromNode=0`, `safe_to_bootstrap=1`).
- Genera un `values.yaml` temporal con configuración completa (servicios, probes, métricas, seguridad, etc.).
- Lanza `helm upgrade --install` con passwords por `--set-string`.
- Si hay un release existente pero sin pods `Ready`, realiza recuperación forzada: escala a 0, crea pod temporal, limpia `galera.cache`/`gvwstate.dat`, ajusta `grastate.dat`, escala primero a 1 y luego al número deseado.
- Crea un CronJob de backup (`<deployment>-backup`) y su PVC `RWX`.
- Crea/actualiza un `VerticalPodAutoscaler` apuntando al StatefulSet del chart.
- Muestra estado final de pods, PVCs y datos de conexión (servicio clusterIP y headless).

### Flags Disponibles
- `-c, --config <archivo>`: usa un YAML diferente a `mariadb-config.yaml`.
- `-h, --help`: muestra ayuda resumida.

> El script usa el namespace `infra` para instalar el provisioner NFS dedicado; ajusta manualmente si tu clúster usa una convención diferente.

---

## 6. Verificación del Clúster (`check-mariadb-ha.sh`)

### Uso
```bash
./check-mariadb-ha.sh          # lee mariadb-config.yaml
./check-mariadb-ha.sh -c prod.yaml
./check-mariadb-ha.sh --help
```

### Qué Valida
- Estado y reinicios de pods (`Running` y `Ready`).
- Variables clave de Galera (`wsrep_cluster_status`, `wsrep_ready`, `wsrep_cluster_size`, `wsrep_connected`).
- Servicios y Endpoints asociados al release Helm.
- PVCs con etiqueta `app.kubernetes.io/instance=<deployment>`.
- Obtiene la contraseña root desde el config o del secreto `<deployment>-mariadb-galera`.

El script resume errores y advertencias al final y retorna código de salida distinto de cero si se detectan incidencias.

---

## 7. Watchdog de Recuperación (`mariadb-ha-watchdog.sh`)

### Objetivo
Mantener el StatefulSet de Galera con al menos 3 réplicas y recuperar automáticamente el clúster si todas las instancias caen (por ejemplo, tras un corte de energía).

### Características
- Doble lock (`running` y `cooloff`) para evitar ejecuciones simultáneas.
- Ajuste automático de `safe_to_bootstrap` y limpieza de artefactos (`galera.cache`, `gvwstate.dat`, etc.).
- Escalado a `DESIRED_REPLICAS` (default 3) si detecta réplicas insuficientes.
- Notificaciones opcionales a Slack.
- Intervalos y timeouts configurables (creación/eliminación de pods, readiness, cooldown).

### Variables Importantes
| Variable | Descripción | Default |
|----------|-------------|---------|
| `NS` | Namespace del StatefulSet | `nextcloud` |
| `STS` | StatefulSet a monitorear | `mariadb` |
| `CTX` | Contexto de kubeconfig (obligatorio) | – |
| `PVC` | PVC principal (`data-<sts>-0`) | – |
| `DATA_DIR` | Ruta de datos en el pod temporal | `/bitnami/mariadb` |
| `FIX_IMAGE` | Imagen usada para limpiar datos | `busybox:1.36` |
| `DESIRED_REPLICAS` | Réplicas a garantizar | `3` |
| `SLACK_WEBHOOK_URL` | Webhook de Slack (opcional) | vacío |
| `SLEEP_SECONDS` | Intervalo de chequeo | `30` |

### Ejecución Manual
```bash
export CTX=mi-contexto
export NS=database-dev
export STS=mariadb-galera-dev
export PVC=data-mariadb-galera-dev-0
./mariadb-ha-watchdog.sh              # monitoreo continuo
./mariadb-ha-watchdog.sh --force      # fuerza ejecución inmediata
./mariadb-ha-watchdog.sh --unlock     # elimina lock residual
```

### Instalación como Servicio systemd

```bash
sudo ./install-service.sh \
  -n database-dev \
  -s mariadb-galera-dev \
  -c wso2-prod-tmp \
  -p data-mariadb-galera-dev-0 \
  -d "MariaDB Galera HA Watchdog (WSO2 - DEV)" \
  -w https://hooks.slack.com/services/XXXX/XXXX/XXXX
```

El servicio se registra como `mariadb-ha-watchdog-<ns>-<sts>-<ctx>.service`. Comandos útiles:
```bash
systemctl status mariadb-ha-watchdog-...service
journalctl -u mariadb-ha-watchdog-...service -f
systemctl list-units --type=service --state=running | grep watchdog
```

Para removerlo:
```bash
sudo ./uninstall-watchdog-service.sh \
  -n database-dev \
  -s mariadb-galera-dev \
  -c wso2-prod-tmp \
  -b    # elimina /usr/local/bin/mariadb-ha-watchdog.sh si no hay otros servicios
```

La plantilla `mariadb-ha-watchdog.service` sirve si necesitas personalizar manualmente usuario, `KUBECONFIG`, límites, etc.

---

## 8. Backups Automáticos

Cuando `backup.enabled=true`, el despliegue crea:
- `CronJob <deployment>-backup`: ejecuta diariamente `mysqldump` + `gzip` y almacena en `/backup`.
- `PVC <deployment>-backup-pvc`: almacenamiento `RWX` de 50 Gi (ajustable editando el script o el YAML).

Los dumps se nombran `backup-YYYYMMDD-HHMMSS.sql.gz`. Se eliminan automáticamente los más antiguos que el parámetro `retention`.

Para restaurar un backup, monta el PVC en un pod utilitario o descarga el archivo vía `kubectl cp`.

---

## 9. Desinstalación y Limpieza (`uninstall-mariadb-ha.sh`)

### Uso Básico
```bash
./uninstall-mariadb-ha.sh \
  -c mariadb-config.yaml \
  --delete-data-pvcs \
  --delete-namespace \
  --delete-storage-class \
  --delete-pull-secret \
  --force
```

### Qué Elimina
- Release Helm (`helm uninstall`).
- CronJobs de backup y PVC asociados (incluyendo PV huérfanos).
- Opcional: namespace del despliegue, StorageClass generado y pull secret.
- Respeta flags definidas en `cleanup` del YAML, aunque los parámetros de CLI tienen prioridad.

`--force` omite confirmación interactiva (útil para pipelines). Si no se usa `--force`, pedirá confirmación antes de proceder.

---

## 10. Troubleshooting & Tips

- **Errores de montaje NFS:** revisa `kubectl get events -n <ns>`; verifica permisos y opciones `mountOptions`.
- **Bootstrap manual necesario:** elimina PVCs o borra el ConfigMap `<deployment>-galera-state` para forzar que el deploy se comporte como primer despliegue.
- **Sin soporte de VPA:** el script intenta instalar los CRDs oficiales (`autoscaler/vpa`). Si no tienes permisos de red para descargarlos, crea los recursos manualmente o deshabilita `resources.vpa.enabled`.
- **Contraseñas:** si el `values.yaml` temporal se elimina, la salida del script muestra solo ubicaciones; usa secretos antes de compartir logs.
- **Watchdog sin acceso a kubeconfig:** asegúrate de definir `KUBECONFIG` en el unit file o exportarlo antes de ejecutar manualmente.
- **Slack:** el watchdog utiliza `python3` para escapar el payload; instala `python3` en el host o desactiva la notificación.
- **Validaciones fallan con `x509`:** revisa tu kubeconfig y certificado de cluster; el watchdog y los scripts comparten la misma configuración.

---

## 11. Buenas Prácticas
- Mantén el archivo de configuración fuera del repositorio público (usa un repositorio privado o herramienta de secretos).
- Revisa periódicamente el tamaño del PVC de backups; rota los archivos si usas retenciones largas.
- Integra los scripts en pipelines de CI/CD para despliegues y validaciones consistentes.
- Documenta internamente cualquier cambio en imágenes personalizadas, rutas NFS o políticas de seguridad.

---

Proyecto mantenido por el equipo de la PNGD.