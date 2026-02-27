# ---------------------------------------------------------------------------
# platform-secrets values
#
# secrets: is a list of ExternalSecret definitions. Each entry controls
# which namespaces receive the secret and what remote keys to fetch.
#
# Cloud-specific secrets are added in the appropriate values layer:
#   values/platform-secrets/gcp/base.yaml.gotmpl
#   values/platform-secrets/aws/base.yaml.gotmpl
#   values/platform-secrets/azure/base.yaml.gotmpl
#
# secretStoreRef controls which ClusterSecretStore is used globally.
# Override per-cloud when switching from fake to a real backend.
# ---------------------------------------------------------------------------

secretStoreRef:
  name: fake-secret-store
  kind: ClusterSecretStore

refreshInterval: 1h

secrets: []