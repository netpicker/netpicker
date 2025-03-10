# Netpicker Helm Chart

This Helm chart deploys the Netpicker application on a Kubernetes cluster.

## Prerequisites

- Kubernetes 1.19+
- Helm 3.2.0+
- PV provisioner support in the underlying infrastructure (for persistent volumes)

## Installing the Chart

To install the chart with the release name `netpicker`:

```bash
helm install netpicker ./netpicker-chart
```

The command deploys Netpicker on the Kubernetes cluster with default configuration. The [Parameters](#parameters) section lists the parameters that can be configured during installation.

## Uninstalling the Chart

To uninstall/delete the `netpicker` deployment:

```bash
helm uninstall netpicker
```

## Parameters

### Global parameters

| Name                      | Description                                     | Value             |
| ------------------------- | ----------------------------------------------- | ----------------- |
| `global.imageRegistry`    | Global Docker image registry                    | `""`              |
| `global.imagePullSecrets` | Global Docker registry secret names as an array | `[]`              |
| `global.storageClass`     | Global StorageClass for Persistent Volume(s)    | `"local-storage"` |

### Storage Class parameters

| Name                                | Description                              | Value                   |
| ----------------------------------- | ---------------------------------------- | ----------------------- |
| `storageClass.enabled`              | Enable the creation of the storage class | `true`                  |
| `storageClass.name`                 | Name of the storage class                | `local-storage`         |
| `storageClass.isDefault`            | Set as the default storage class         | `true`                  |
| `storageClass.reclaimPolicy`        | Reclaim policy for the storage class     | `Retain`                |
| `storageClass.allowVolumeExpansion` | Allow volumes to be expanded             | `true`                  |
| `storageClass.mountOptions`         | Mount options for the storage class      | `[noatime, nodiratime]` |

### Common parameters

| Name               | Description                                                                               | Value |
| ------------------ | ----------------------------------------------------------------------------------------- | ----- |
| `nameOverride`     | String to partially override netpicker.fullname template (will maintain the release name) | `""`  |
| `fullnameOverride` | String to fully override netpicker.fullname template                                      | `""`  |

### Image parameters

| Name                    | Description                | Value           |
| ----------------------- | -------------------------- | --------------- |
| `images.api.repository` | API image repository       | `netpicker/api` |
| `images.api.tag`        | API image tag              | `2.1.3`         |
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
| `db.service.type`        | Kubernetes Service type                           | `ClusterIP` |
| `db.service.port`        | PostgreSQL service port                           | `5432`      |
| `db.resources`           | The resources limits for the PostgreSQL container | `{}`        |

### API parameters

| Name                      | Description                                | Value          |
| ------------------------- | ------------------------------------------ | -------------- |
| `api.enabled`             | Enable API deployment                      | `true`         |
| `api.alembicVersion`      | Alembic version                            | `8d64b01e52b7` |
| `api.logLevel`            | Log level                                  | `INFO`         |
| `api.uvicornRootPath`     | Uvicorn root path                          | `/`            |
| `api.service.type`        | Kubernetes Service type                    | `ClusterIP`    |
| `api.service.port`        | API service port                           | `8000`         |
| `api.resources`           | The resources limits for the API container | `{}`           |
| `api.persistence.enabled` | Enable persistence using PVC               | `true`         |
| `api.persistence.size`    | PVC Storage Request for API volume         | `1Gi`          |

For other parameters, please refer to the values.yaml file.

## Configuration and installation details

### Persistence

The Netpicker chart mounts persistent volumes for various components. The chart supports persistence and uses a PVC to store data.

### Ingress

This chart provides support for Ingress resources. If you have an ingress controller installed on your cluster, such as [nginx-ingress](https://kubeapps.com/charts/stable/nginx-ingress) or [traefik](https://kubeapps.com/charts/stable/traefik) you can utilize the ingress controller to expose Netpicker.

To enable ingress integration, set `ingress.enabled` to `true`. The `ingress.hostname` property can be used to set the host name. The `ingress.tls` parameter can be used to add the TLS configuration for this host.

### TLS Secrets

The chart also facilitates the creation of TLS secrets for use with the Ingress controller, with different options for certificate management.
