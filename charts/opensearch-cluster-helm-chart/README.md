# opensearch-cluster Helm Chart

Deploys an `OpenSearchCluster` CR via the
[opensearch-k8s-operator](https://github.com/opensearch-project/opensearch-k8s-operator)
with:
- **cert-manager + letsencrypt** for TLS certificates
- **Kubernetes Gateway API** for external traffic routing (replaces Istio VirtualService)
- **External Secrets Operator** pulling admin credentials from a `ClusterSecretStore`
- **Istio sidecar exclusion** so OpenSearch's own TLS is not double-wrapped

## Prerequisites

| Dependency | Purpose |
|---|---|
| [opensearch-k8s-operator](https://opensearch-project.github.io/opensearch-k8s-operator/) | Reconciles `OpenSearchCluster` |
| [cert-manager](https://cert-manager.io) ≥ 1.14, `--set config.enableGatewayAPI=true` | TLS certificates via letsencrypt |
| `ClusterIssuer` for letsencrypt | Referenced by `certManager.clusterIssuerName` |
| Istio ≥ 1.18 (or other Gateway controller) | Gateway API + sidecar injection |
| [External Secrets Operator](https://external-secrets.io) | Syncs admin credentials from fake store |
| `fake-secret-store` ClusterSecretStore | Must contain admin username/password keys |

## Quick start

```bash
# 1. Add the required keys to your fake ClusterSecretStore
kubectl edit clustersecretstore fake-secret-store
# Add under spec.provider.fake.data:
#   - key: "/opensearch/admin/username"
#     value: "admin"
#   - key: "/opensearch/admin/password"
#     value: "<STRONG_PASSWORD>"

# 2. Install the chart
helm install opensearch ./opensearch-cluster-v2 \
  --namespace opensearch \
  --create-namespace \
  --set certManager.clusterIssuerName=letsencrypt-prod \
  --set certManager.http.dnsNames[0]=opensearch.example.com \
  --set certManager.dashboards.dnsNames[0]=kibana.example.com \
  --set gateway.enabled=true \
  --set gateway.gatewayClassName=istio \
  --set gateway.gatewayNamespace=istio-system \
  --set gateway.dashboards.host=kibana.example.com
```

## Architecture

```
┌─────────────────── namespace: opensearch ──────────────────────────┐
│  PeerAuthentication: PERMISSIVE                                     │
│                                                                     │
│  ┌──────────────┐  9300/TLS (self-signed) ┌──────────────┐         │
│  │ masters (×3) │◄──────────────────────►│ masters (×3) │         │
│  └──────┬───────┘                         └──────────────┘         │
│         │ 9200/TLS (cert-manager)                                   │
│  ┌──────▼───────┐                                                   │
│  │  data (×3)   │                                                   │
│  └──────────────┘                                                   │
│  ┌────────────────────┐                                             │
│  │ Dashboards (×1)    │ 5601/TLS (cert-manager)                     │
│  └────────────────────┘                                             │
│  ┌────────────────────────────────────────┐                         │
│  │ ExternalSecret → fake-secret-store     │                         │
│  │ → opensearch-admin-credentials Secret  │                         │
│  └────────────────────────────────────────┘                         │
└─────────────────────────────────────────────────────────────────────┘
         ▲ cert-manager issues opensearch-http-tls
         ▲ cert-manager issues opensearch-dashboards-tls

┌─────────────── namespace: istio-system ─────────────────────────────┐
│  Gateway (gatewayClassName: istio)                                  │
│    listener https-dashboards :443 → ReferenceGrant → Secret        │
│    listener http-dashboards  :80  → redirect 301                   │
│  HTTPRoute: kibana.example.com → opensearch-dashboards:5601        │
│  HTTPRoute: HTTP 301 redirect                                       │
└─────────────────────────────────────────────────────────────────────┘
```

## Ports

| Port | Description | TLS source |
|------|-------------|------------|
| 9200 | REST API | cert-manager |
| 9300 | Transport (internal only) | Operator self-signed CA |
| 9400 | gRPC (3.x, disabled) | Operator |
| 5601 | Dashboards | cert-manager |

## Istio integration

Two mechanisms keep OpenSearch's own TLS from conflicting with Istio:

1. **Pod annotations** on every node pool and Dashboards exclude OpenSearch
   ports (9200/9300/9400) from Istio's iptables capture.
2. **PeerAuthentication `PERMISSIVE`** so Istio doesn't enforce mTLS policy
   on those ports either.

Routing uses the **Kubernetes Gateway API** (Gateway + HTTPRoute) instead of
Istio VirtualService, making the chart controller-agnostic.

## External Secrets Operator

The `ExternalSecret` CR syncs admin credentials from `fake-secret-store`:

```yaml
# Add to your ClusterSecretStore spec.provider.fake.data:
- key: "/opensearch/admin/username"
  value: "admin"
- key: "/opensearch/admin/password"
  value: "<your-password>"
```

The resulting `opensearch-admin-credentials` Secret is referenced by the
`OpenSearchCluster` CR at `spec.security.config.adminCredentialsSecret`.

## Key values

| Key | Default | Description |
|-----|---------|-------------|
| `clusterName` | `opensearch` | CR name and K8s service name |
| `general.version` | `2.19.2` | OpenSearch version |
| `externalSecret.clusterSecretStoreName` | `fake-secret-store` | ClusterSecretStore name |
| `externalSecret.adminCredentials.usernameRemoteKey` | `/opensearch/admin/username` | Key path in the store |
| `externalSecret.adminCredentials.passwordRemoteKey` | `/opensearch/admin/password` | Key path in the store |
| `certManager.clusterIssuerName` | `letsencrypt-prod` | cert-manager ClusterIssuer |
| `certManager.http.dnsNames` | `[]` | Extra SANs for REST API cert |
| `certManager.dashboards.dnsNames` | `[]` | Extra SANs for Dashboards cert |
| `gateway.enabled` | `false` | Create Gateway API resources |
| `gateway.gatewayClassName` | `istio` | GatewayClass (istio/cilium/envoy-gateway) |
| `gateway.gatewayNamespace` | `istio-system` | Namespace for the Gateway resource |
| `gateway.dashboards.host` | `""` | External hostname for Dashboards |
| `gateway.referenceGrant.enabled` | `true` | Cross-namespace Secret access |
| `istio.peerAuthentication.mode` | `PERMISSIVE` | Istio mTLS policy |
