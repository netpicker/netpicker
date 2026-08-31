# Netpicker Helm Chart

This Helm chart deploys the Netpicker application on a Kubernetes cluster.

## Prerequisites

- Kubernetes 1.21+
- Helm 3.2.0+
- Longhorn (instructions below)
- An NFS client on every node. Longhorn needs it for the shared volumes.
  Install `nfs-common` on Debian and Ubuntu, or `nfs-utils` on RHEL and Rocky.

## Installing Longhorn

The chart keeps four volumes that more than one pod mounts. These volumes need
the `ReadWriteMany` access mode. Longhorn supplies this mode, and it also
supplies the `ReadWriteOnce` block volumes for the database, for Redis, and for
syslog-ng. Install Longhorn before you install this chart:

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
| `global.storageClass`     | Global StorageClass for Persistent Volume(s)    | `"longhorn"`      |
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
| `persistence.accessMode`          | Access mode for the shared volumes          | `ReadWriteMany` |
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
the `persistence.accessMode` parameter, and the default value is
`ReadWriteMany`. Longhorn starts an NFS share manager pod for each one.

| Volume | Pods that mount it |
| ------ | ------------------ |
| `api-data` | api, celery, db-migration |
| `dc-vol` | celery, kibbitzer, agent |
| `gitd-data` | gitd, frontend |
| `transferium` | celery, transferium |
| `secret` | agent, kibbitzer |

**Single writer volumes.** One pod mounts each of these volumes. Each one has
its own parameter, and the default value is `ReadWriteOnce`. Longhorn gives a
block volume, which is the correct type for a database.

| Volume | Parameter |
| ------ | --------- |
| db data | `db.persistence.accessMode` |
| `redis-data` | `redis.persistence.accessMode` |
| `syslogng-data` | `syslogng.persistence.accessMode` |

Do not put the database on a `ReadWriteMany` volume. PostgreSQL needs correct
file locking, and an NFS share can damage the data.

### Local storage instead of Longhorn

You can run the chart on local storage, but on one node only. Local storage
gives no `ReadWriteMany` volumes. Set these values:

```yaml
global:
  storageClass: "local-storage"
storageClass:
  enabled: true
persistence:
  accessMode: "ReadWriteOnce"
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
