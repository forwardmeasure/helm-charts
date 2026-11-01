# Cloud-portability audit — Helm charts + releases (2026-11-01)

Written for: platform engineers reviewing cross-cloud readiness before an AWS/Azure deploy.

Executes `TODO-cloud-portability.md`. Scope: every chart under `charts/`, plus the product
`deploy/helmfile` release layer. Goal: find GCP-specific constructs buried where a cloud-neutral
seam should be. Method: a categorized marker sweep (annotations, CSI/storage classes, LB
annotations, node selectors, Config Connector CRDs, cloud credential env) across all charts, then
targeted reads of the stateful/storage charts (where a hardcoded class won't trip a keyword grep),
and `helm template` render verification of every fix. `helm` v4.2.2 locally — no cloud creds needed.

## Verdict

The architecture is fundamentally portable: cloud specifics go through generic escape hatches
(`serviceAccount.annotations`, `nodeSelector`, `extraEnv`/`extraVolumes`), opt-in named blocks
(`cloudSqlProxy`, default off), per-cloud release overlays (`releases/<name>/gcp/base.yaml.gotmpl`),
and required-value CSI (`model-cache`). The Terraform outputs contract is already cloud-neutral. The
audit found **five charts with a GCP construct lacking a neutral seam** plus **a DNS-01 solver
layering defect in two cert-issuer charts** — all fixed and render-verified. Nothing else is buried.

## Fixed this pass (render-verified)

- **k8ssandra-cluster** — `defaults.storageClassName` and the `dc1` resource hardcoded `standard`
  (a GKE class name) → `""` (the cluster's default StorageClass, portable; cloud-specific class via
  overlay). Rendered: emits empty `storageClassName`.
- **zookeeper-cluster** — `persistence.storageClass: "standard-rwo"` (GKE-only) → `""`. Rendered.
- **hugegraph** — `store` and `pd` `persistence.storageClass: standard-rwo` (GKE-only) → `""` (×2).
- **docling-serve** — `gpu.nodeSelector: {cloud.google.com/gke-accelerator: nvidia-l4}` was a live
  GKE-only default → `{}` with per-cloud examples (GKE/EKS/AKS) documented; set via overlay.
- **keycloak** — removed the dead GCP **Config Connector** path (`templates/gcp/gcp-iam-service-account.yaml`,
  `gcp-iam-policy.yaml`, and the `gcp.workloadIdentity` values block). It was default-off, unused
  (the real consumer wires Workload Identity through `serviceAccount.annotations` +
  `cloudSqlProxy.ambientCredentials`), GCP-only, and a second competing WI mechanism. Rendered: the
  SA still gets its WI annotation via `serviceAccount.annotations`; no Config Connector CRDs emitted.

## ACME DNS-01 solver — a layering defect, now fixed (both charts)

The cert-manager ClusterIssuer hardcoded a GCP **Cloud DNS** DNS-01 solver directly in the shared
(cloud-neutral) chart layer — a layering bug, not a "needs more cloud branches" problem. A DNS-01
solver is irreducibly cloud-specific (cloudDNS / route53 / azureDNS), so the chart should carry none
of it and pass the whole solver list through from the per-cloud values overlay, exactly as
`platform-secrets` passes its secret-store backend through. Two charts had it; both fixed, both
render-verified:

- **platform-routing** (`templates/certificates.yaml`) — replaced the hardcoded `cloudDNS` block with
  a `clusterIssuer.solvers` passthrough (`toYaml`) + a cloud-neutral `privateKeySecretRef`; dropped
  `gcpProject`/`gcpCredentialsSecret`. The `forwardmeasure-platform` consumer now layers a new
  `releases/platform-routing/gcp/base.yaml.gotmpl` (the cloudDNS solver) over a neutral base with no
  GCP in it, and the helmfile layers that overlay on `$cloud == gcp`.
- **platform-bootstrap** (`forwardmeasure-platform` local chart; the **live** issuer, via the
  `platform-certificates` release that `platform-routing` depends on) — same passthrough fix;
  `releases/platform-certificates/gcp/base.yaml.gotmpl` now supplies the cloudDNS solver
  (project-only, ambient Workload Identity) instead of a bare `gcpProject`.

The TODO's third suspected copy (`forwardmeasure-openworkflow/charts/letsencrypt-dns01`) no longer
exists — OpenWorkflow moved to the shared platform gateway/certificates, so there was nothing to fold.
AWS/Azure now only need their own solver in a per-cloud overlay; neither chart needs touching.

## GCP-specific but correct — no change (opt-in block / generic escape hatch)

- **java-microservice**, **quarkus-service**, **quarkus-funqy**, **decision-engine** — `cloudSqlProxy`
  opt-in named block (default off; the cloud-sql-proxy binary is GCP-only but gated), WI via
  `serviceAccount.annotations`. The reference pattern.
- **platform-secrets** — inherently cloud-specific (secret-store backend); pure `toYaml` passthrough,
  100% of the cloud choice in values. Reference example.
- **model-cache** — CSI `driver`/`volumeHandle` are *required* values (chart fails if unset), so the
  cloud supplies them; `storageClass` via values. Correct CSI abstraction.
- **geocoding** (nominatim) — `storageClass` via values; WI via the generic annotations hatch. GCP
  wiring is through values/overlay, not hardcoded.
- **kserve-model-serving**, **livy** — WI via `serviceAccount.annotations` only.

## Clean — no cloud-specific content (generic hatches only)

apicurio-registry-deployment, apicurio-registry-operator (storageClassName appears only in the
upstream CRD's OpenAPI schema, not as a value), camel-karavan, itineris-helm-chart, kafka-deployment
(Strimzi CR; storage via values/operator), knative-crd, model-service, opa, openworkflow-workflow-bundle,
opensearch-cluster (generic pod/opensearch annotations; storage via operator/values),
triton-model-serving. All use `annotations: {}` / `nodeSelector: {}`-style generic hatches with no
hardcoded cloud binding found by the marker sweep. (Caveat from the TODO: a marker sweep can't prove
a stateful chart never hardcodes a class in a path not matched — these had none in the obvious spots.)

## Release (helmfile) layer

The per-cloud overlay pattern is established and correct: products layer `releases/<name>/gcp/base.yaml.gotmpl`
over a cloud-neutral `releases/<name>/base.yaml.gotmpl`, and GCP specifics (the WI annotation value,
`cloudSqlProxy.enabled`, instance connection names) live in the `gcp/` overlay or are gated
(`{{- with .Values.runtimeServiceAccountAnnotation }}`, `cloudSqlProxy.enabled: {{ dig ... false }}`),
not leaking into the neutral base. **The release-layer gap for AWS/Azure is simply that only `gcp/`
overlays exist** — each product needs parallel `aws/` + `azure/` overlays created when those clouds
are targeted (the same shape of work as the Terraform per-cloud parity; see the multi-cloud parity note).

## How to finish AWS/Azure enablement (when targeted)

1. Add the ACME solver to each cloud's cert-issuer overlay — `releases/platform-certificates/aws/`
   (route53) and `/azure/` (azureDNS), mirroring the `gcp/` one. The charts are already solver-agnostic.
2. For each product, add `releases/<name>/aws/` and `/azure/` overlays mirroring the `gcp/` one
   (WI annotation → `eks.amazonaws.com/role-arn` / `azure.workload.identity/client-id`; drop
   `cloudSqlProxy` — RDS/Azure DB connect directly; storage class per cloud).
3. The stateful charts now inherit the cluster's default StorageClass; set an explicit per-cloud
   class in the overlay only if a non-default (e.g. gp3, managed-csi) is wanted.
