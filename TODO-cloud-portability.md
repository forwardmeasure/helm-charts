# TODO: audit every chart's cloud-provider-specific content

## Why

`keycloak-helm-chart` was found to have two GCP-only features baked directly
into its own templates: a `gcp.workloadIdentity` block that creates real GCP
IAM resources via Config Connector CRDs (`templates/gcp/gcp-iam-service-account.yaml`,
`gcp-iam-policy.yaml`), and a `cloudSqlProxy` sidecar hardcoded to GCP's
Cloud SQL Auth Proxy binary (`gcr.io/cloud-sql-connectors/cloud-sql-proxy`).
Both are opt-in (default `enabled: false`) and don't block deploying the
chart cloud-neutrally, but there's no equivalent for AWS/Azure, and nothing
else in this repo has been checked for the same pattern. Consumers of these
charts (`forwardmeasure-platform`, `forwardmeasure-openworkflow`) now
correctly layer cloud-specific *values* on top of cloud-neutral bases
(`releases/<name>/base.yaml.gotmpl` + `releases/<name>/gcp/base.yaml.gotmpl`),
but that only works correctly if the charts themselves are honest about what
parts of them are cloud-specific.

This file is a checklist for a systematic pass through every chart in this
repo, not a review itself — go chart by chart, apply the checklist, fix what
needs fixing, and note what you found even where nothing needed changing.

## What "correct" looks like (the pattern already proven here)

`keycloak-helm-chart`'s `cloudSqlProxy` block is the reference example after
this session's fix — model new work on it, not on how it looked before:

- Cloud-specific values live under a clearly-named key (`cloudSqlProxy`,
  `gcp.workloadIdentity`), never bare at the top level.
- Every cloud-specific template block is gated behind an explicit `enabled`
  flag, default `false`, so the chart is fully cloud-neutral when unset.
- Where a cloud-specific *authentication* mechanism has more than one real
  option (a mounted static credentials file vs. ambient Workload Identity),
  both are supported behind a sub-flag (`cloudSqlProxy.ambientCredentials`) -
  don't force consumers into the less secure option because it's the one
  that happened to be implemented first.
- Generic, provider-agnostic escape hatches (`serviceAccount.annotations`,
  `extraVolumes`, `extraEnv`, `extraContainers` — check whether each chart
  already has these) are kept independent of any single cloud's named block,
  so e.g. AWS IRSA can be wired up via `serviceAccount.annotations` today
  even without the chart having first-class AWS support.
- `values.yaml` documents, in a comment, what's cloud-specific and why.

`platform-secrets-helm-chart` is the reference example for a chart that's
*inherently* cloud-specific in what it configures (a secret store backend
has no cloud-neutral form) — it stays fully generic itself
(`templates/cluster-secret-store.yaml` is a pure `toYaml` passthrough of
whatever `clusterSecretStore.provider` is given) and pushes 100% of the
cloud-specific decision into the *values* layer, where it belongs.

## Per-chart checklist

For each chart under `charts/`, check for and resolve:

1. **Cloud-specific K8s annotations/labels** hardcoded without a flag:
   `iam.gke.io/gcp-service-account`, `eks.amazonaws.com/role-arn`,
   `azure.workload.identity/client-id`, `cloud.google.com/*`,
   `service.beta.kubernetes.io/aws-*`, `service.beta.kubernetes.io/azure-*`.
2. **Cloud-specific CSI drivers or storage classes** hardcoded (not just
   defaulted) in PV/PVC templates: `*.csi.storage.gke.io`, `efs.csi.aws.com`,
   `ebs.csi.aws.com`, `disk.csi.azure.com`, `file.csi.azure.com`, or a
   `storageClassName` default that only exists on one cloud (`standard-rwo`,
   `gp2`/`gp3`, `premium-rwo`) presented as if it were universal.
3. **Cloud-specific sidecar/init containers or images**: proxy/connector
   binaries (`gcr.io/cloud-sql-connectors/*` and equivalents), cloud SDK
   images, anything that only functions against one cloud's API.
4. **Cloud-specific CRDs** (Config Connector `*.cnrm.cloud.google.com`,
   AWS Controllers for Kubernetes, Azure Service Operator, or similar) that
   create real cloud resources as a side effect of installing the chart.
5. **Node selectors/tolerations/affinity defaulting to one cloud's naming**
   (e.g. `cloud.google.com/gke-accelerator` in `docling-serve-helm-chart`'s
   `values.yaml` — confirm whether this is a live default or just
   documentation-by-example, and if live, gate or generalize it).
6. **Environment variables that only make sense on one cloud**
   (`GOOGLE_APPLICATION_CREDENTIALS` and equivalents) - confirm these are
   gated the same way the resources that need them are.
7. Where cloud-specific content is found and is staying (because it's a
   real, wanted feature): confirm it's opt-in/default-off, confirm a
   generic escape hatch still exists alongside it for other clouds where
   applicable, and add/update the `values.yaml` comment explaining it.
8. Where cloud-specific content is found and *shouldn't* be there (e.g. a
   hardcoded annotation with no flag at all): fix it to match the pattern
   above rather than deleting the capability outright, unless it's
   genuinely dead/unreferenced.

## Charts already spot-checked this session — confirmed cloud-specific content to resolve

(Found via a grep sweep, not a full read — treat as a starting point per
chart, not a complete list of everything in that chart.)

- **`keycloak-helm-chart`** — `gcp.workloadIdentity` (Config Connector CRDs,
  `templates/gcp/`) and `cloudSqlProxy` (already fixed to support ambient
  credentials this session - confirm the `gcp.workloadIdentity`/Config
  Connector path is actually used anywhere real, or whether it's dead code
  now that `serviceAccount.annotations` is the pattern actually in use in
  `forwardmeasure-platform`'s `releases/keycloak/gcp/base.yaml.gotmpl`; if
  dead, remove it rather than leave two competing WI mechanisms).
- **`quarkus-service-helm-chart`** — has its own `cloudSqlProxySidecar`
  helper (`templates/_helpers.tpl`, confirmed GCP-only, matches
  data-fabric's usage) plus a `test-values-map-gcp.yaml` test fixture and
  Spark executor pod template content (`templates/spark-executor-pod-template-configmap.yaml`)
  worth checking for cloud-specific node selectors.
- **`quarkus-funqy-helm-chart`** — flagged by the same sweep as
  `quarkus-service-helm-chart` (shares helper patterns); check whether it
  has the same `cloudSqlProxySidecar`-style capability or something else.
- **`geocoding-helm-chart`** (nominatim) — flagged across `_helpers.tpl`,
  `nominatim-deployment.yaml`, `nominatim-import-job.yaml`, and
  `values.yaml`; this session's Terraform work already granted its
  workload identity `roles/cloudsql.client`-equivalent access, so this
  chart's actual GCP wiring is relevant to real, current work, not
  hypothetical.
- **`platform-routing-helm-chart`** — `templates/certificates.yaml` and
  `values.yaml`/`values-example.yaml.gotmpl`; likely the DNS-01 ACME solver
  concern already known to be GCP Cloud-DNS-only in the *consumer* repos'
  own local charts (`forwardmeasure-platform`'s `charts/platform-bootstrap`,
  `forwardmeasure-openworkflow`'s `charts/letsencrypt-dns01`) - worth
  checking whether this shared chart has the identical limitation and
  whether it should be the one place this gets a real provider abstraction,
  rather than three separate copies of the same GCP-only logic.
- **`kserve-model-serving-helm-chart`**, **`livy-helm-chart`**,
  **`model-cache-helm-chart`** — smaller hits (`service-account.yaml`/
  `values.yaml` only in each), likely just a `serviceAccount.annotations`
  or similar single field; confirm they follow the generic-escape-hatch
  pattern already and don't need changes, or fix if not.
- **`docling-serve-helm-chart`** — `values.yaml:154`,
  `cloud.google.com/gke-accelerator: nvidia-l4` as a node-selector-style
  default; confirm whether this is live and gate/generalize if so.

## Charts not flagged by the grep sweep — still worth a pass

`apicurio-registry-deployment-helm-chart`, `apicurio-registry-operator-helm-chart`,
`camel-karavan-helm-chart`, `hugegraph-helm-chart`, `itineris-helm-chart`,
`k8ssandra-cluster-helm-chart`, `kafka-deployment-helm-chart`,
`knative-crd-helm-chart`, `model-service-helm-chart`,
`opensearch-cluster-helm-chart`, `triton-model-serving-helm-chart`,
`zookeeper-cluster-helm-chart` — a keyword grep won't catch a hardcoded
storage class or LB annotation that isn't cloud-named, and these are
storage-heavy stateful charts (`k8ssandra`, `opensearch-cluster`, `zookeeper`,
`kafka`) where that's a real risk. Run the checklist above on each.

## How to verify a fix (don't skip this)

For every chart touched, confirm with a real render, not just a read:

```bash
helm template test <chart-dir> --set <cloudFlag>.enabled=true [--set ...] | grep -A10 <expected-resource>
helm template test <chart-dir>   # defaults - confirm nothing cloud-specific leaks in when disabled
```

Matches how every fix in this session was actually verified (e.g. the
`keycloak-helm-chart` `ambientCredentials` fix: rendered both
`ambientCredentials: true` and the pre-existing static-key default, and
confirmed the exact set of resources/env vars/volumes present or absent in
each). A chart that "looks right" on read but was never actually rendered is
not verified.

## Deliverable

A short summary (one paragraph per chart) of what was found and fixed,
covering **every** chart listed above (both the spot-checked and
not-yet-checked groups) — for review before merging any of it.
