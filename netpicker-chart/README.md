# Netpicker Helm Chart

This Helm chart deploys the Netpicker application on a Kubernetes cluster.

## Prerequisites

- Kubernetes 1.21+
- Helm 3.2.0+
- Longhorn (instructions below)
- An NFS client on every node, but only if you set the shared volumes to
  `ReadWriteMany`. Install `nfs-common` on Debian and Ubuntu, or `nfs-utils`
  on RHEL and Rocky. See [Persistence](#persistence).

## Installing Longhorn

Longhorn supplies the `ReadWriteOnce` block volumes that the chart makes by
default. It also supplies the `ReadWriteMany` shared volumes, which you need
only to spread the pods over more than one node. Install Longhorn before you
install this chart:

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update
helm install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace
```

Longhorn makes a storage class with the name `longhorn`. The value
`global.storageClass` points to it.

Longhorn keeps 3 copies of each volume by default. A cluster with fewer than 3
nodes keeps the volumes in the `Degraded` state. On a small cluster, set the
number of copies to the number of nodes:

```bash
helm install longhorn longhorn/longhorn --namespace longhorn-system \
  --create-namespace --set defaultSettings.defaultReplicaCount=1
```

## Installing the Chart

To install the chart with the release name `netpicker`:

```bash
helm install netpicker .
```

The command deploys Netpicker on the Kubernetes cluster with default configuration. The [Parameters](#parameters) section lists the parameters that can be configured during installation.

Make sure you have installed Longhorn as described in the [Installing Longhorn](#installing-longhorn) section before deploying this chart.

## Uninstalling the Chart

To uninstall/delete the `netpicker` deployment:

```bash
helm uninstall netpicker
```

## Secrets

The chart collects the necessary secrets from the v1/secret whose name can be defined in Global parameters (`secretConfig`).

For frictionless installation the chart comes with the "default" secret.
You can create your own secret that uses specialized secret stores to retrieve the values from.

## Parameters

### Global parameters

| Name                      | Description                                     | Value             |
| ------------------------- | ----------------------------------------------- | ----------------- |
| `global.imageRegistry`    | Global Docker image registry                    | `""`              |
| `global.imagePullSecrets` | Global Docker registry secret names as an array | `[]`              |
| `global.storageClass`     | Default StorageClass for every volume that sets no class of its own | `"longhorn"`      |
| `global.secretConfig`     | Global name of the secret used to set ENV       | `"default"`       |

### Storage Class parameters

| Name                                | Description                                 | Value                   |
| ----------------------------------- | ------------------------------------------- | ----------------------- |
| `storageClass.enabled`              | Enable the creation of the storage class    | `false`                 |
| `storageClass.name`                 | Name of the storage class                   | `local-storage`         |
| `storageClass.isDefault`            | Set as the default storage class            | `false`                 |
| `storageClass.provisioner`          | Provisioner for dynamic volume provisioning | `rancher.io/local-path` |
| `storageClass.parameters`           | Parameters for the provisioner              | `{}`                    |
| `storageClass.volumeBindingMode`    | Volume binding mode                         | `WaitForFirstConsumer`  |
| `storageClass.reclaimPolicy`        | Reclaim policy for the storage class        | `Delete`                |
| `storageClass.allowVolumeExpansion` | Allow volumes to be expanded                | `true`                  |
| `storageClass.mountOptions`         | Mount options for the storage class         | `[noatime, nodiratime]` |

### Common parameters

| Name               | Description                                                                               | Value |
| ------------------ | ----------------------------------------------------------------------------------------- | ----- |
| `nameOverride`     | String to partially override netpicker.fullname template (will maintain the release name) | `""`  |
| `fullnameOverride` | String to fully override netpicker.fullname template                                      | `""`  |

### Image parameters

| Name                    | Description                | Value           |
| ----------------------- | -------------------------- | --------------- |
| `images.api.repository` | API image repository       | `netpicker/api` |
| `images.api.tag`        | API image tag              | `2.7.6`         |
| `images.api.pullPolicy` | API image pull policy      | `IfNotPresent`  |
| `images.db.repository`  | Database image repository  | `netpicker/db`  |
| `images.db.tag`         | Database image tag         | `latest`        |
| `images.db.pullPolicy`  | Database image pull policy | `IfNotPresent`  |

For other image parameters, please refer to the values.yaml file.

### Database parameters

| Name                     | Description                                       | Value       |
| ------------------------ | ------------------------------------------------- | ----------- |
| `db.enabled`             | Enable database deployment                        | `true`      |
| `db.postgresPassword`    | PostgreSQL password                               | `s3rgts0p!` |
| `db.persistence.enabled` | Enable persistence using PVC                      | `true`      |
| `db.persistence.size`    | PVC Storage Request for PostgreSQL volume         | `8Gi`       |
| `db.persistence.accessMode` | Access mode for the PostgreSQL volume          | `ReadWriteOnce` |
| `db.persistence.storageClass` | StorageClass for the PostgreSQL volume. Empty means `global.storageClass` | `""` |
| `db.service.type`        | Kubernetes Service type                           | `ClusterIP` |
| `db.service.port`        | PostgreSQL service port                           | `5432`      |
| `db.resources`           | The resources limits for the PostgreSQL container | `{}`        |

### API parameters

| Name                      | Description                                | Value          |
| ------------------------- | ------------------------------------------ | -------------- |
| `api.enabled`             | Enable API deployment                      | `true`         |
| `api.alembicVersion`      | Alembic version                            | `3201afd119b9` |
| `api.jwtSecret`           | JWT secret (key)                           | `<random>`     |
| `api.logLevel`            | Log level                                  | `INFO`         |
| `api.uvicornRootPath`     | Uvicorn root path                          | `/`            |
| `api.service.type`        | Kubernetes Service type                    | `ClusterIP`    |
| `api.service.port`        | API service port                           | `8000`         |
| `api.resources`           | The resources limits for the API container | `{}`           |
| `api.persistence.enabled` | Enable persistence using PVC               | `true`         |
| `api.persistence.size`    | PVC Storage Request for API volume         | `1Gi`          |

For other parameters, please refer to the values.yaml file.

### Persistence parameters

| Name                              | Description                                 | Value           |
| --------------------------------- | ------------------------------------------- | --------------- |
| `persistence.accessMode`          | Access mode for the shared volumes          | `ReadWriteOnce` |
| `persistence.storageClass`        | StorageClass for the shared volumes. Empty means `global.storageClass` | `""`            |
| `persistence.dcVol.enabled`       | Enable persistence for the dc volume        | `true`          |
| `persistence.dcVol.size`          | PVC Storage Request for the dc volume       | `1Gi`           |
| `persistence.transferium.enabled` | Enable persistence for transferium          | `true`          |
| `persistence.transferium.size`    | PVC Storage Request for transferium volume  | `1Gi`           |
| `persistence.secret.enabled`      | Enable the shared secrets volume            | `true`          |
| `persistence.secret.size`         | PVC Storage Request for the secrets volume  | `1Gi`           |

## Configuration and installation details

### Persistence

The chart uses two groups of volumes.

**Shared volumes.** More than one pod mounts each of these volumes. They use
the `persistence.accessMode` parameter and the `persistence.storageClass`
parameter.

| Volume | Pods that mount it |
| ------ | ------------------ |
| `api-data` | api, celery, db-migration |
| `dc-vol` | celery, kibbitzer, agent |
| `gitd-data` | gitd, frontend |
| `transferium` | celery, transferium |
| `secret` | agent, kibbitzer |

The default access mode is `ReadWriteOnce`. Such a volume attaches to one
node, but all the pods on that node can mount it. **All the pods in the table
above must therefore run on the same node.** A pod that Kubernetes puts on
another node cannot attach the volume and stays in the `Pending` state. On a
cluster with one worker node, this always holds. On a larger cluster, keep the
pods together with a `nodeSelector` or with a node affinity rule.

With `ReadWriteOnce`, these deployments also use the `Recreate` update
strategy. A rolling update starts the new pod before it stops the old one, and
the new pod cannot attach the volume. `Recreate` stops the old pod first. The
chart makes this change for you, and it costs a short interruption during an
upgrade. With `ReadWriteMany`, the deployments keep the rolling update.

To spread these pods over more than one node, set `ReadWriteMany`:

```yaml
persistence:
  accessMode: "ReadWriteMany"
```

The storage system must supply that mode:

- Longhorn starts an NFS share manager pod for each `ReadWriteMany` volume.
  Every node then needs an NFS client. See [Prerequisites](#prerequisites).
- Ceph and NetApp Trident serve `ReadWriteMany` from a different storage class
  than `ReadWriteOnce`. Also set `persistence.storageClass`. See
  [Other CSI storage systems](#other-csi-storage-systems).

**Single writer volumes.** One pod mounts each of these volumes. Each one has
its own access mode parameter, and the default value is `ReadWriteOnce`. Each
one also has its own storage class parameter. Longhorn gives a block volume,
which is the correct type for a database.

| Volume | Access mode parameter | Storage class parameter |
| ------ | --------------------- | ----------------------- |
| db data | `db.persistence.accessMode` | `db.persistence.storageClass` |
| `redis-data` | `redis.persistence.accessMode` | `redis.persistence.storageClass` |
| `syslogng-data` | `syslogng.persistence.accessMode` | `syslogng.persistence.storageClass` |

Each storage class parameter has the default value `""`, which means
`global.storageClass`. Set one only if that volume needs another class.

Do not put the database on a `ReadWriteMany` volume. PostgreSQL needs correct
file locking, and an NFS share can damage the data.

### Other CSI storage systems

The chart works with any storage system that has a CSI driver, because it
names the storage class in the values only. With the default access modes, one
storage class for `ReadWriteOnce` volumes is enough:

```yaml
global:
  storageClass: "ceph-block"
```

You need a second class only if you set the shared volumes to
`ReadWriteMany`. Longhorn serves both access modes from one storage class, but
Ceph and NetApp Trident do not. They serve each access mode from a different
driver. Name the block class in `global.storageClass` and name the file class
in `persistence.storageClass`.

**Rook-Ceph**, with the class names of your cluster:

```yaml
global:
  storageClass: "ceph-block"   # rbd.csi.ceph.com, ReadWriteOnce
persistence:
  accessMode: "ReadWriteMany"
  storageClass: "cephfs"       # cephfs.csi.ceph.com, ReadWriteMany
```

**NetApp Trident**:

```yaml
global:
  storageClass: "ontap-san"    # iSCSI or NVMe, ReadWriteOnce
persistence:
  accessMode: "ReadWriteMany"
  storageClass: "ontap-nas"    # NFS, ReadWriteMany
```

Find the names of the classes in your cluster with this command:

```bash
kubectl get storageclass
```

To use the default storage class of the cluster, set `global.storageClass` to
`""`. The chart then makes each claim with no `storageClassName` field.

### Local storage instead of Longhorn

You can run the chart on local storage, but on one node only. Local storage
gives no `ReadWriteMany` volumes, so keep the default access modes. Set these
values:

```yaml
global:
  storageClass: "local-storage"
storageClass:
  enabled: true
```

Then install a local provisioner, for example Rancher's Local Path Provisioner:

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml
```

All pods must then run on the same node, because a local volume exists on one
node only. Pods that cannot reach their volume stay in the `Pending` state.

### Ingress

This chart provides support for Ingress resources. If you have an ingress controller installed on your cluster, such as [nginx-ingress](https://kubeapps.com/charts/stable/nginx-ingress) or [traefik](https://kubeapps.com/charts/stable/traefik) you can utilize the ingress controller to expose Netpicker.

To enable ingress integration, set `ingress.enabled` to `true`. The `ingress.hostname` property can be used to set the host name. The `ingress.tls` parameter can be used to add the TLS configuration for this host.

### TLS Secrets

The chart also facilitates the creation of TLS secrets for use with the Ingress controller, with different options for certificate management.
