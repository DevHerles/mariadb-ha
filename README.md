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

2. Install mariadb in high availability mode
```bash
kubectl apply -f mariadb.yaml -n mariadb
```
