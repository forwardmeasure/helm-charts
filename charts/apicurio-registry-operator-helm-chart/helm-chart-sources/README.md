# Apicurio Registry Operator

This chart vendors the CRD from the upstream Apicurio Registry `3.3.0`
standalone operator manifest and installs the corresponding released operator
image. Registry instances are intentionally owned by a separate deployment
chart. This chart does not build or deploy code from the mutable `main` branch.

Upstream manifest:

`https://raw.githubusercontent.com/Apicurio/apicurio-registry/3.3.0/operator/install/apicurio-registry-operator-3.3.0.yaml`

SHA-256 of the complete downloaded upstream manifest:

`e30fa2df5224abe87c074ba33e2caffa33bb01c062600d670cda47f26463b5dd`

The upstream ClusterRole has intentionally been split into a namespace-scoped
Role plus a minimal ClusterRole that can only read the
`apicurioregistries3.registry.apicur.io` CRD. The watched namespace is set
explicitly to the Helm release namespace rather than inferred from an OLM
annotation.

The CRD is installed through Helm's `crds/` lifecycle and is not deleted during
release uninstall. Helm also does not upgrade files in `crds/` automatically,
so every operator upgrade must explicitly review and apply the upstream CRD
change before upgrading the controller and Registry resource.

The operator, Registry application, UI, and GitOps Sync image references are
pinned by digest. Their digests were resolved from the official `3.3.0` Quay
tags; upgrading requires changing both the chart version metadata and digests.
