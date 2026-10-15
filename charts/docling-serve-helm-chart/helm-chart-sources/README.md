# ForwardMeasure Docling Serve chart

This chart deploys Docling Serve with CPU or NVIDIA GPU resource profiles. The defaults select the complete Docling Serve **v1.37.0** image set reviewed on October 13, 2026. CPU and CUDA 12.8 images are pinned by registry digest.

The [Postman deployment collection](postman/README.md) provides health checks, standard and asynchronous conversions, DocLang/DCLX examples and optional VLM/authentication checks. Importable copies are also available in `/home/pn` beside the existing Geocoding collection.

The full investigation and proposed platform work are preserved in [the reference plan](docs/docling-serve-analysis-and-remediation-plan-2026-10-13.md). Implementation scope, validation evidence and the client-component recommendation are in [the implementation handover](docs/docling-serve-chart-implementation-2026-10-13.md). The documents live with the chart sources so the existing publisher includes them in the release commit.

## Release and qualification status

Chart sources have been changed and verified locally. No chart has been published, no platform chart pin has been changed, and no Kubernetes workload has been upgraded by this work.

`Chart.yaml` is deliberately unchanged, including its version and appVersion. The repository's `publish_charts.sh` performs version changes during publication. The new top-level `image.tag: v1.37.0` provides the publisher with appVersion metadata; deployment image identity comes from the nested CPU/GPU digest.

Helm rendering and synthetic model-publication tests do not establish conversion quality, GPU compatibility, DocLang fidelity or production capacity. Run the deployment qualification programme in the reference plan before production rollout.

## Profiles and request selection

| mode | pipeline | Assets | Notes |
|---|---|---|---|
| cpu | standard | Image-bundled or prepared standard assets | Default |
| cpu | vlm-small | Standard assets plus Granite Docling 258M | Requires prepared PVC; latency must be measured |
| gpu | standard | Image-bundled or prepared standard assets | Default GPU selector is GKE NVIDIA L4 |
| gpu | vlm-small | Standard assets plus Granite Docling 258M | Requires prepared PVC |
| gpu | vlm-large | Standard assets plus Granite Vision 3.2 2B | Requires prepared PVC |

CPU with `vlm-large` is rejected. General `nodeSelector`, `affinity` and `tolerations` work for CPU deployments. GPU scheduling adds `gpu.nodeSelector` and `gpu.tolerations`; GPU resources appear in both requests and limits.

**The chart's pipeline setting selects preparation, resource limits and the server's VLM preset. Callers still select the conversion pipeline per request.** A VLM caller must submit `options.pipeline: vlm` and, when explicit, `options.vlm_pipeline_preset: granite_docling` or `granite_vision`. Omitting request pipeline selection still selects the standard conversion pipeline.

The standard baseline explicitly selects Heron through `docling_layout_default`, TableFormer V1 accurate, CodeFormulaV2 and the document figure classifier preset. The chart does not substitute Granite Vision 4.1 for the whole-page Granite Vision 3.2 preset.

Preset restrictions require runtime qualification. Upstream Jobkit builds a `default` alias independently of its allowed-preset list. An allow-list or advertised capability alone therefore does not establish that every possible request resolves to a prepared model. The client/admission layer must gate adopted options, and qualification must exercise named and default presets. Enabling picture description, chart extraction, chunking, another OCR language, or another model can require additional assets.

## Image identity

Digest takes precedence over tag:

```yaml
image:
  tag: v1.37.0
  cpu:
    digest: sha256:6eda9c524992147c1b0b06a1a9be4894bd68b1f43c86d92c32f996c4c60d18a3
  gpu:
    digest: sha256:2aa6fc687c9211911b51ad2a60c33028358973fd053be9dd1cc4646017dfc76d
```

To select another tag deliberately, clear the applicable digest and set the tag. Otherwise changing a tag cannot change the image:

```yaml
image:
  tag: v1.37.0
  cpu:
    digest: ""
```

Empty `modelDownload.image.<mode>` repository/tag/digest fields inherit the corresponding serving image identity. `modelDownload.useCpuImage: true` uses the CPU preparation image even for a GPU server. Preparation normally downloads or copies files and does not require GPU allocation. An explicit preparation-image override is a separate compatibility decision.

## Model sources

`modelSource` accepts `auto`, `image` or `pvc`. In auto mode, `modelDownload.enabled: true` selects a managed PVC bundle; false selects image-bundled standard models.

### Image-bundled standard models

The normal standard profile reads assets from `paths.imageModels`, defaulting to `/opt/app-root/src/.cache/docling/models`. No model preparation init container or model PVC mount is used. Hugging Face runtime caches, scratch and temporary files have separate writable volumes.

For a **fresh** standard installation that does not require a model PVC:

```yaml
modelSource: image
modelDownload:
  enabled: false
persistence:
  create: false
```

`persistence.create` deliberately defaults to true so an upgrade does not abruptly remove a previously Helm-owned PVC. An image-mode deployment may consequently retain an unused claim. See the migration procedure before disabling it on an existing release.

Whole-document VLM profiles reject image mode because their extra repositories are not established as image-bundled assets.

### Managed immutable PVC bundle

For chart-managed preparation:

```yaml
modelSource: pvc
modelDownload:
  enabled: true
  preparation: init
persistence:
  create: true
  size: 64Gi
  accessMode: ReadWriteOnce
strategy:
  type: Recreate
```

The selected `ensembleModels` tokens resolve through `modelDownload.namedModels`. Hugging Face repositories use immutable commit revisions, required-file inventories and known SHA-256 hashes for the standard weights. VLM repositories have immutable revisions; the large model requires an index and every referenced weight shard. OCR directories are sourced from the pinned preparation image.

The preparer first validates suitable bundled image assets. It fetches missing repository assets at their pinned revision into a local staging emptyDir. It never invokes a mutable "download all current models" command. Its completion manifest records the requested inventory, preparation image, actual origin of each model, installed package versions, and every selected file's size and checksum. Image-copy origin is recorded as an image identity; it does not claim the image's non-weight files were downloaded at the requested Hugging Face revision.

A resolved inventory and preparation image determine a bundle ID. Models are published under:

```text
<paths.models>/.bundles/<bundle-id>/
  <repository-or-OCR-directory>/
  .complete.json
```

The server mounts the PVC read only and uses that exact bundle root. A valid warm bundle is fully verified before use, with no preparation download. Incomplete unmarked destinations are quarantined. A corrupt completed bundle causes an explicit failure and is preserved for investigation; repair requires an operator to identify and quarantine the corrupt bundle before preparing it again. Previous bundles and the legacy root remain intact.

Preparation uses a POSIX advisory lock released by the kernel when its owning process dies. Publication uses an atomic rename from a temporary directory on the same PVC. The storage backend must support these filesystem semantics. **GCS FUSE and other object-store mounts are not qualified for this preparation protocol.** Merely rendering a CSI source does not establish filesystem compatibility. Abrupt node or storage failure still requires backend-specific recovery qualification; the tests establish process-level interruption behavior.

Do not delete a shared lock file to "clear" a lock. Do not automatically remove completed bundles. Retained versions, quarantine entries and staging space need an explicit capacity and retention policy.

### Job preparation

```yaml
modelDownload:
  enabled: true
  preparation: job
  job:
    activeDeadlineSeconds: 3600
    ttlSecondsAfterFinished: 86400
```

This creates an ordinary Job rather than a Helm hook. The server's verification init container waits, with a bounded timeout, for the required complete bundle. Job names include a digest of values, preparation script and chart version so upgrades create a new Job instead of trying to change an immutable Pod template. Model inventory and script ConfigMaps are also versioned by content.

For a ReadWriteOnce claim, the Job has required same-node affinity to the server Pod. The server can be scheduled while still waiting in its init container; the Job joins that node and prepares the volume. The node must have room for the server's effective Pod request and the preparation Job. Override Job affinity/selectors only with compatible scheduling constraints. GPU taint tolerations are inherited by the Job, but the CPU preparation container requests no GPU.

Job Pods use a distinct application label so they cannot enter the Service's endpoints or count as server Pods. If the Job has expired or been removed, an identical Helm reconciliation can recreate it; a complete bundle is verified and reused.

ReadWriteOncePod supports init preparation, but cannot support this two-Pod Job protocol and is rejected. ReadOnlyMany cannot be used for writable preparation. ReadWriteMany supports multiple preparers if the backend implements the required POSIX lock and rename semantics.

### Externally prepared PVC

```yaml
modelSource: pvc
modelDownload:
  enabled: false
persistence:
  create: false
  existingClaim: externally-prepared-models
```

This expects the selected model directories directly under `paths.models`. A verification init container checks required files, known weight hashes and, when present, the legacy `.docling-serve.manifest`. It does not write a new manifest or model files. The chart creates neither a PVC nor a PV for `existingClaim`.

An existing claim containing this chart's `.bundles/` layout should stay in managed-bundle mode: supply `existingClaim`, keep `modelDownload.enabled: true` and use the same inventory/image identity. Init preparation then verifies and reuses the warm bundle. External legacy mode cannot select an inner bundle through `paths.models`, because that setting specifies the PVC mount location, not a subdirectory within the claim.

## Storage ownership and migration

The existing release name `docling` retains:

- Service and Deployment: `docling-docling-serve`.
- Default claim: `docling-docling-serve-cache`.
- Explicit `serviceAccount.name: docling`, when supplied by existing platform values.

Default ServiceAccount names are now release-specific. Explicit shared names still require the owner to manage their Helm ownership; use `serviceAccount.create: false` for a supplied account owned elsewhere. ServiceAccount token automount is disabled by default.

PVC retention adds `helm.sh/resource-policy: keep`. This is a Helm ownership safeguard; **it does not change the underlying PV's reclaim policy or create a disk backup**. The observed GKE disk uses a Delete reclaim policy, so preservation also depends on retaining the claim and the storage operator's snapshot/reclaim policy. A retained resource is left behind on uninstall and needs deliberate management before a reinstall can adopt it.

For the existing dynamically provisioned claim:

1. Preserve release name, claim name, access mode, storage class, capacity and explicit ServiceAccount override.
2. Take the agreed storage backup/snapshot and retain the old release values/image identity.
3. Render the new chart against reviewed release values. Replace old explicit image and preparation-image tag overrides deliberately; do not assume inherited defaults replace supplied values.
4. Upgrade with `persistence.create: true` and `persistence.retain: true`, preserving Helm ownership. Do not switch a bound dynamic claim to static binding or alter immutable claim fields.
5. Verify retention metadata and the new profile. A first managed-bundle preparation uses the existing disk but creates a new immutable bundle, leaving the old root available for rollback.
6. If switching to image models, first complete the upgrade that adds retention while still rendering the PVC. Only in a later reviewed upgrade disable creation or transfer ownership. Do not combine first-time retention and claim removal in one step.

Preparation staging, bundle publication and retained older bundles require free space. Validate disk usage before migration. The old 64Gi size is preserved as a compatibility default, not a calculated sizing result.

Static PV creation requires `persistence.bindToPv: true` and exactly one real `volumeSource` (`csi`, `nfs`, `local` or `hostPath`). Local sources require node affinity. A default static PV name includes both namespace and release identity because PVs are cluster-scoped. Prefer explicitly provisioned storage or an external claim where ownership is already established. `persistence.volumeName` can bind to a pre-existing PV without creating one.

The default Recreate strategy avoids overlapping Pods attaching a single-node model disk. It introduces downtime and does not drain or preserve local asynchronous tasks. RollingUpdate with PVC models requires ReadWriteMany.

## Authentication, network policy and task engines

API-key authentication is enabled only when a real Secret is supplied:

```yaml
auth:
  enabled: true
  existingSecret: docling-api-key
  secretKey: api-key
```

The chart reads `DOCLING_SERVE_API_KEY` through secretKeyRef. It does not generate credentials or create a Secret. Callers must use the upstream API-key header and receive the credential through the platform's established secret delivery process. Missing/wrong keys and health-probe access require integration qualification. The stock defaults leave authentication disabled for compatibility with existing callers.

`envSecretRefs` supports other secret-backed settings. Dedicated chart-managed environment variables cannot also be supplied through `env`, `gpuEnv` or `envSecretRefs`. Plain environment maps merge deterministically, with GPU values taking precedence; rendered names are unique.

`networkPolicy.enabled: true` creates server ingress isolation. An empty ingress list denies caller ingress. Supply rules with real approved namespace **and** workload selectors and the actual serving port; no caller identities have been invented or enabled by this change.

`networkPolicy.egress: null` leaves egress unrestricted by this policy; `[]` selects egress isolation and denies it all. Explicit rules must account for DNS, the chosen task backend, enabled remote sources/targets and model preparation. Init preparation shares the server Pod's policy. The separate preparation Job is outside this server policy's selector and needs its own namespace/workload egress controls where required. NetworkPolicy enforcement depends on the cluster's networking implementation.

Local engine remains the default, with one API replica and one local worker. Task state and scratch results are ephemeral. The chart rejects multiple local API replicas because subsequent requests can reach a Pod that does not own the task.

For an independently provisioned RQ installation:

```yaml
replicaCount: 2
engine:
  kind: rq
  redisSecret:
    name: docling-rq-url
    key: url
modelSource: image
```

The chart does not deploy Redis/Valkey, RQ workers, Ray infrastructure, autoscaling or business workflow orchestration. Provision and qualify the selected backend/workers separately. For Ray, also supply `env.DOCLING_SERVE_ENG_RAY_ADDRESS` or its secret reference. Multiple API replicas using PVC models require ReadWriteMany; image models avoid model-volume attachment constraints.

An optional `podDisruptionBudget` is available, but does not make a single local worker highly available or protect results through a restart. API-key authentication does not implement tenant authorization; the owning product must validate tenant evidence access and authorized conversion requests.

## Probes, limits and runtime security

Startup and readiness use `/ready`; liveness uses `/livez`. Startup gates liveness/readiness until model and backend initialization has completed. The old unconditional `/health` response is not used for these decisions.

Configurable finite defaults are 100MiB per input, 1,000 pages, 3,600 seconds document timeout, three sources per request and maximum image scale 2. These are initial guardrails; workload quality, memory, queueing and end-to-end timeout behavior must be measured. They do not bound every ZIP/XML expansion or total scratch usage, and application timeout is not necessarily worker termination.

Runtime cache (8Gi), scratch (8Gi), temporary files (1Gi) and preparation staging (16Gi) use bounded emptyDir volumes. Requests and limits include ephemeral storage. They are initial defaults, not verified capacity estimates. emptyDir data disappears on Pod replacement; neither local async results nor these cache mounts provide durable artifact retention.

Containers run as UID 1001 with a configured fsGroup, RuntimeDefault seccomp, dropped capabilities and no privilege escalation. The default permission-fixing root init container is disabled; the opt-in fallback adjusts only the volume root to 0770 rather than applying recursive 0777. Storage drivers must honor the ownership strategy.

`readOnlyRootFilesystem` remains false pending real runtime compatibility testing. It is configurable, with cache/scratch/tmp mounts prepared for an eventual qualified read-only profile. Extra runtime writes and framework caches still need measurement before enabling it.

## Local validation and publication

Requirements for the regression runner: Helm 3, Python 3 on Linux and PyYAML. No Kubernetes connection or Hugging Face download is needed.

```bash
./test-chart.sh
```

Tests exercise all five profiles, invalid configuration rejection, stable identities, release isolation, secret references, model-root selection, bounded mounts, Job isolation/scheduling, versioned Job names, static storage and synthetic model-publication failures.

The model tests include checksum damage, partial/interrupted download, incomplete quarantine, missing shards, unexpected files, source symlinks, path traversal, two concurrent preparers and death of a lock owner. Their tiny fixture weights do not test a real model.

From the repository root, the publisher can be inspected without mutation:

```bash
bash publish_charts.sh --chart-name docling-serve-helm-chart --dry-run
```

Run actual publication only as the separately authorized release step. Existing packages and index.yaml remain unchanged by this implementation. Tests and their runner are excluded from the Helm package; the runtime preparation script is included.

The current publisher has an existing EXIT-trap issue: after printing a complete dry run it returns status 1 when its temporary index path is empty under `set -e`. The dry run still confirms image metadata and the proposed version; its process exit status is not a successful release check. This defect is documented in the handover, and the publisher remains unchanged.

The Java client, artifact/provenance library, DocLang validation, framework bindings and Postman assets are implemented in the sibling `forwardmeasure-document-intelligence` repository. See [client documentation](../../../../forwardmeasure-document-intelligence/README.md).
