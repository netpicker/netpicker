# Netpicker Helm Chart

This Helm chart deploys the Netpicker application on a Kubernetes cluster.

## Prerequisites

- Kubernetes 1.19+
- Helm 3.2.0+
- Local Path Provisioner (instructions below)

## Installing the Local Path Provisioner

Before installing the chart, you need to install the Local Path Provisioner:

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml
```

## Installing the Chart

To install the chart with the release name `netpicker`:

```bash
# Install the chart
helm install netpicker ./netpicker-chart
```

The command deploys Netpicker on the Kubernetes cluster with default configuration. The [Parameters](#parameters) section lists the parameters that can be configured during installation.

Make sure you have installed the Local Path Provisioner as described in the [Installing the Local Path Provisioner](#installing-the-local-path-provisioner) section before deploying this chart.

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

| Name                                | Description                                 | Value                   |
| ----------------------------------- | ------------------------------------------- | ----------------------- |
| `storageClass.enabled`              | Enable the creation of the storage class    | `true`                  |
| `storageClass.name`                 | Name of the storage class                   | `local-storage`         |
| `storageClass.isDefault`            | Set as the default storage class            | `true`                  |
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

### Persistence parameters

| Name                              | Description                                | Value           |
| --------------------------------- | ------------------------------------------ | --------------- |
| `persistence.accessMode`          | Access mode for all PVCs                   | `ReadWriteOnce` |
| `persistence.config.enabled`      | Enable persistence for config              | `true`          |
| `persistence.config.size`         | PVC Storage Request for config volume      | `1Gi`           |
| `persistence.transferium.enabled` | Enable persistence for transferium         | `true`          |
| `persistence.transferium.size`    | PVC Storage Request for transferium volume | `1Gi`           |

## Configuration and installation details

### Persistence and Local Storage Provisioning

The Netpicker chart is configured to use local filesystem storage through a dynamic provisioner. It requires Rancher's Local Path Provisioner (`rancher.io/local-path`), which should be installed before deploying this chart as described in the [Installing the Local Path Provisioner](#installing-the-local-path-provisioner) section.

If you prefer to use a different storage provisioner, you can modify the `storageClass` parameters accordingly.

Other local storage provisioner options include:

- `k8s.io/minikube-hostpath` for Minikube
- `openebs.io/local` for OpenEBS Local PV

The `WaitForFirstConsumer` volume binding mode ensures that volumes are created on the nodes where the pods are scheduled, which is important for local storage.

All persistent volume claims are configured to use the `ReadWriteOnce` access mode by default, which is compatible with local storage. This can be changed by setting the `persistence.accessMode` parameter.

### Ingress

This chart provides support for Ingress resources. If you have an ingress controller installed on your cluster, such as [nginx-ingress](https://kubeapps.com/charts/stable/nginx-ingress) or [traefik](https://kubeapps.com/charts/stable/traefik) you can utilize the ingress controller to expose Netpicker.

To enable ingress integration, set `ingress.enabled` to `true`. The `ingress.hostname` property can be used to set the host name. The `ingress.tls` parameter can be used to add the TLS configuration for this host.

### TLS Secrets

The chart also facilitates the creation of TLS secrets for use with the Ingress controller, with different options for certificate management.
