# Netpicker Docker Compose to Kubernetes Helm Chart Conversion

This repository contains a Kubernetes Helm chart for the Netpicker application, converted from the original Docker Compose configuration.

## Directory Structure

- `docker-compose.yml` - Original Docker Compose configuration
- `netpicker-chart/` - Helm chart for Kubernetes deployment
  - `Chart.yaml` - Chart metadata
  - `values.yaml` - Default configuration values
  - `templates/` - Kubernetes resource templates
  - `README.md` - Chart documentation

## Conversion Details

The conversion from Docker Compose to Kubernetes Helm chart includes:

1. **Services to Deployments**: Each service in the Docker Compose file has been converted to a Kubernetes Deployment with appropriate container specifications.

2. **Networking**: Docker Compose service links have been replaced with Kubernetes Services to enable inter-service communication.

3. **Volumes**: Docker volumes have been converted to Persistent Volume Claims (PVCs).

4. **Environment Variables**: Environment variables from Docker Compose have been mapped to container environment variables in Kubernetes.

5. **Health Checks**: Docker health checks have been converted to Kubernetes liveness and readiness probes.

## Usage

### Prerequisites

- Kubernetes 1.19+
- Helm 3.2.0+
- PV provisioner support in the underlying infrastructure

### Installation

```bash
# Install the chart with the release name "netpicker"
helm install netpicker ./netpicker-chart

# Alternatively, package the chart first
./package-chart.sh
helm install netpicker ./netpicker-chart-0.1.0.tgz
```

### Configuration

The Helm chart can be configured by modifying the `values.yaml` file or by providing custom values during installation:

```bash
helm install netpicker ./netpicker-chart --set api.logLevel=DEBUG
```

## Differences from Docker Compose

While the Helm chart aims to replicate the Docker Compose setup as closely as possible, there are some differences due to the nature of Kubernetes:

1. **Networking**: Kubernetes uses its own networking model, which differs from Docker Compose's network links.

2. **Volume Management**: Kubernetes requires PersistentVolumes and PersistentVolumeClaims instead of Docker volumes.

3. **Resource Management**: Kubernetes allows for more granular resource allocation (CPU, memory) for containers.

4. **Scaling**: Kubernetes makes it easier to scale services independently.

## Customization

The Helm chart is designed to be customizable. Common customization options include:

- Changing image versions
- Modifying resource limits
- Configuring persistence
- Setting up Ingress for external access

Refer to the chart's `README.md` for detailed configuration options.
