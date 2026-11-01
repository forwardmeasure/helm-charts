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
audit found **five charts with a GCP construct lacking a neutral seam (all fixed)** and **one
structural gap left for a reviewed follow-up** (`platform-routing` DNS-01). Nothing else is buried.

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

## One structural gap — fix next (not done here; changes a values contract)

- **platform-routing** — `templates/certificates.yaml` hardcodes a GCP Cloud DNS ACME DNS-01 solver
  (`solvers[].dns01.cloudDNS` + `gcpProject`/`gcpCredentialsSecret`). Opt-in (`clusterIssuer.enabled`)
  but GCP-only when on; AWS needs `route53:`, Azure `azureDNS:`. A DNS-01 solver can't be made
  "neutral" like a storage class. **Recommended fix (the platform-secrets pattern):** replace the
  hardcoded `cloudDNS` block with a `clusterIssuer.solvers` passthrough (`toYaml`), and move the
  provider block into each per-cloud overlay. Deferred because it changes the chart's values contract
  and the `forwardmeasure-platform` consumer overlay must change in lockstep — do it as one reviewed
  change with both sides render-verified. (The same GCP-only DNS-01 logic may also live in the
  consumer repos' local charts — `platform-bootstrap`, `letsencrypt-dns01`; fold them into this one
  abstraction rather than fixing three copies.)

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

1. Land the `platform-routing` DNS-01 passthrough (above) + fold in the consumer-repo copies.
2. For each product, add `releases/<name>/aws/` and `/azure/` overlays mirroring the `gcp/` one
   (WI annotation → `eks.amazonaws.com/role-arn` / `azure.workload.identity/client-id`; drop
   `cloudSqlProxy` — RDS/Azure DB connect directly; storage class per cloud).
3. The stateful charts now inherit the cluster's default StorageClass; set an explicit per-cloud
   class in the overlay only if a non-default (e.g. gp3, managed-csi) is wanted.
