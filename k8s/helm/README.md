# Kubernetes Monitoring with Helm

This directory contains Helm values files for deploying a comprehensive monitoring stack on Kubernetes using Prometheus, Grafana, and Loki.

## Overview

The monitoring stack consists of:

- **Prometheus** - Metrics collection and storage
- **Grafana** - Visualization and dashboarding
- **Loki** - Log aggregation and querying
- **Promtail** - Log collection agent
- **Node Exporter** - Hardware and OS metrics
- **Kube State Metrics** - Kubernetes cluster state metrics
- **Alertmanager** - Alert routing and management

## Files

### `prometheus-kube-stack-values.yml`

Values file for the `kube-prometheus-stack` Helm chart, which includes:

- **Prometheus Server**: Configured with 7-day retention and resource limits
- **Grafana**: 
  - Exposed via ingress at `grafana.k8s.iradukunda.me`
  - Persistent storage enabled (5Gi)
  - Admin credentials managed via environment variables
  - SSL/TLS with Let's Encrypt
- **Node Exporter**: Collects hardware and OS metrics from cluster nodes
- **Kube State Metrics**: Exposes Kubernetes cluster state metrics
- **Alertmanager**: Handles alert routing and notifications

### `loki-values.yml`

Values file for the Loki stack Helm chart, which includes:

- **Loki**: Log aggregation with 5Gi persistent storage
- **Promtail**: Log collection agent deployed as DaemonSet
- **Grafana Integration**: Disabled since Grafana is provided by the prometheus stack

## Access

### Grafana Dashboard

- **URL**: https://grafana.k8s.iradukunda.me
- **Username**: admin
- **Password**: Value set in `$GRAFANA_ADMIN_PASSWORD`

### Port Forwarding (Alternative Access)

If ingress is not configured:

```bash
# Grafana
kubectl port-forward -n monitoring svc/prometheus-stack-grafana 3000:80

# Prometheus
kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-prometheus 9090:9090

# Alertmanager
kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-alertmanager 9093:9093
```

## Configuration Details

### Resource Allocation

| Component | CPU Request | Memory Request | CPU Limit | Memory Limit |
|-----------|-------------|----------------|-----------|--------------|
| Prometheus | 250m | 512Mi | 500m | 1Gi |
| Grafana | - | - | - | - |
| Loki | 100m | 256Mi | 200m | 512Mi |
| Promtail | 50m | 128Mi | 100m | 256Mi |
| Node Exporter | 100m | 128Mi | 200m | 256Mi |
| Kube State Metrics | 50m | 64Mi | 100m | 128Mi |
| Alertmanager | 100m | 128Mi | 200m | 256Mi |

### Storage

- **Grafana**: 5Gi persistent volume
- **Loki**: 5Gi persistent volume
- **Storage Class**: `do-block-storage` (DigitalOcean Block Storage)

### Data Retention

- **Prometheus**: 7 days
- **Loki**: Configured based on storage capacity

## Monitoring Capabilities

### Metrics Collection

- **Cluster Metrics**: CPU, memory, disk, network usage
- **Pod Metrics**: Resource consumption, status, restart counts
- **Node Metrics**: Hardware metrics, system performance
- **Application Metrics**: Custom metrics via ServiceMonitor CRDs

### Log Collection

- **Container Logs**: All pod logs collected via Promtail
- **System Logs**: Node-level system logs
- **Application Logs**: Structured and unstructured application logs

### Dashboards

Grafana comes pre-configured with:
- Kubernetes cluster overview
- Node exporter metrics
- Pod and container metrics
- Persistent volume usage
- Network traffic analysis

## Troubleshooting

### Check Pod Status

```bash
kubectl get pods -n monitoring
```

### View Logs

```bash
# Prometheus
kubectl logs -n monitoring deployment/prometheus-stack-kube-prom-prometheus

# Grafana
kubectl logs -n monitoring deployment/prometheus-stack-grafana

# Loki
kubectl logs -n monitoring deployment/loki

# Promtail
kubectl logs -n monitoring daemonset/loki-promtail
```

### Verify ServiceMonitors

```bash
kubectl get servicemonitors -n monitoring
```

## Upgrading

```bash
# Update Helm repositories
helm repo update

# Upgrade Prometheus stack
helm upgrade prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values prometheus-kube-stack-values.yml

# Upgrade Loki stack
helm upgrade loki grafana/loki-stack \
  --namespace monitoring \
  --values loki-values.yml
```

## Customization

### Adding Custom Dashboards

Place JSON dashboard files in a ConfigMap and Grafana will automatically import them:

```bash
kubectl create configmap custom-dashboard \
  --from-file=dashboard.json \
  -n monitoring
```

### Adding ServiceMonitors

Create ServiceMonitor resources to scrape custom application metrics:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-app
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: my-app
  endpoints:
  - port: metrics
```

## Security Considerations

- Grafana admin password is managed via environment variables
- SSL/TLS encryption enabled for web interfaces
- RBAC permissions configured for service accounts
- Network policies can be applied for additional security

## Support

For issues related to:
- **Helm Charts**: Check official documentation
- **Configuration**: Review values files in this directory
- **Kubernetes**: Verify cluster resources and permissions