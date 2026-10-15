# Docling Serve chart implementation and client-component recommendation

Date: October 13, 2026. This records the implementation following the [complete reference plan](docling-serve-analysis-and-remediation-plan-2026-10-13.md). The historical plan is preserved in full; this handover records what has actually changed and what remains to be qualified.

**Deployment follow-up, October 15, 2026:** the earlier observations below remain historical. The platform installer was still pinned to chart 0.0.8; even published 0.0.9 contains Serve 1.31.0. The platform pin is now prepared for 0.0.10, which must be published and merged into `develop` before installation. The publisher's EXIT-trap defect described below is fixed with two regression tests. A temporary 0.0.10 package rendered with the actual production Helmfile values passed Kubernetes server dry-run, and all 26 chart tests passed. `Chart.yaml` remains untouched for the publisher. No release has been pushed or applied to the cluster. See the [release procedure](../README.md#making-the-platform-installer-select-this-chart).

## Delivered scope

The changes and reference documents are in `charts/docling-serve-helm-chart/helm-chart-sources`. Keeping the documents with the chart sources ensures the existing publisher stages them with the chart. The [chart README](../README.md) documents configuration and migration.

`Chart.yaml` was left unchanged, including version **0.0.9** and its existing appVersion. Existing packaged charts, the repository index and platform release pins have not been changed. No commit, push, publication, deployment, live conversion or real-model download was performed.

### Implemented chart changes

| Finding | Implementation | Practical limit |
|---|---|---|
| Software behind the reviewed release | CPU and CUDA 12.8 Serve v1.37.0 registry digests; top-level image tag for release automation | Source defaults are upgraded; the installed workload is not |
| Serving/preparation image drift | Preparation defaults inherit serving image identity; CPU preparation is the default for both serving modes | Explicit overrides remain operator-owned compatibility choices |
| Unconditional health checks | Startup/readiness use /ready; liveness uses /livez | Processor and backend failure behavior still needs live qualification |
| Invalid values and missing storage | JSON values schema and cross-field template checks | Render validation cannot verify a real Secret, disk, worker or accelerator |
| Shared resource-name collisions | Release-specific ServiceAccount and versioned model ConfigMaps; namespace/release-specific static PV names | Explicit name overrides can still intentionally share identities |
| Incomplete static PV | A real CSI/NFS/local/hostPath source is required; local storage requires node affinity | A renderable source is not qualification of that storage backend |
| PVC removal and single-node attach risks | Existing ordinary claim name retained, keep annotation, Recreate default, explicit external claims and RWX checks | Keep does not change a backing disk's Delete reclaim policy or replace backups |
| Runtime files mixed into model storage | Separate bounded cache, scratch, /tmp and preparation staging volumes; server model mount read only | Scratch and local async results remain ephemeral |
| Recursive 0777 and implicit privilege | Nonroot UID/fsGroup, disabled default root fixer, restricted optional root adjustment, no token automount, dropped capabilities, seccomp | Read-only root filesystem remains an unqualified opt-in |
| Partial models treated as complete | Required files, known standard weight checksums, nonempty weights and complete shard-index validation | VLM/OCR first-copy inventory is tied to pinned revision/image rather than a prelisted checksum for every file |
| Mutable/repeated downloads | Pinned HF commits; qualified bundled-image assets preferred; content inventory determines immutable bundle root | Enabled inference options still require workload-specific asset qualification |
| Copy/publication interruption | Same-filesystem staging/publication, complete marker and explicit quarantine of incomplete destinations | Process-interruption tests do not establish storage power-failure durability |
| Corrupt warm cache | Recomputed manifest inventory; corrupt completed bundles fail and remain intact | Operator repair and retention policy are intentionally explicit |
| Concurrent preparers | Bounded POSIX flock, owner-death recovery without deleting another owner's lock | Storage must implement POSIX locking and atomic rename |
| GPU preparation and Job scheduling | CPU preparation image, GPU taint tolerations, same-node Job affinity for RWO, bounded verification wait | Node capacity and real scheduler behavior still need qualification |
| Job update immutability | Job names change with values/script/chart version; versioned model ConfigMaps | Job mode remains opt-in; deadlines and Helm timeout must suit actual preparation |
| Missing authentication and caller controls | Secret-backed API key, secret-backed backend settings, optional NetworkPolicy and PDB | Defaults remain compatible; real credentials, callers and worker/backend infrastructure must be supplied |
| Invalid horizontal scale with local task state | Multiple local API replicas rejected; RQ/Ray require backend Secret; Ray also requires address | Shared workers are not installed by this chart |
| Unbounded conversion settings | Configurable initial file/page/timeout/source/image-scale limits and ephemeral-storage requests/limits | These are initial guardrails, not a throughput or acceptance result |
| Silent baseline/default changes | Explicit Heron, TableFormer V1 accurate, CodeFormulaV2 and classifier defaults | Actual output quality and default-preset resolution still need evaluation |
| Missing chart regressions | Strict lint, five-profile rendering, invalid values, resource isolation, migration identity and model failure tests | Tests use synthetic weights and do not run Docling inference |

### Bundle provenance

The completion manifest includes the resolved inventory/configuration digest, preparation image identity, installed package versions, per-model origin and every selected file's size and SHA-256 hash.

A copied image model records image origin. A downloaded model records repository and immutable revision. This distinction avoids claiming that every non-weight image file came from the inventory's requested HF commit. Known standard weight hashes must match before an image copy qualifies.

The existing legacy model root is not deleted or rewritten during managed-bundle preparation. New content goes below `.bundles/<id>`. Different inventory/image identities retain separate roots for explicit rollback and retention management.

## Verification evidence and remaining acceptance

The local runner is:

```bash
cd charts/docling-serve-helm-chart/helm-chart-sources
./test-chart.sh
```

It executes strict Helm lint and **26 unittest test methods**, with additional subtests covering all five supported profiles and invalid configurations. Model-publication tests use tiny synthetic weight files and controlled download doubles, including real concurrent processes and owner-death flock recovery. They do not contact Hugging Face or submit a conversion.

The repository publisher's dry run passed strict Helm lint, read image metadata v1.37.0 and proposed chart version 0.0.10, leaving Chart.yaml and the repository unchanged. It printed its complete dry-run output but exited with status 1 because its existing EXIT cleanup trap returns false under `set -e` when TMP_INDEX is empty. The same shell pattern was reproduced independently; changing the conditional to an `if` statement returns status 0. The publishing script was not changed as part of this chart implementation. Treat this as a separate release-automation defect rather than a passing publisher exit status.

Package contents and package rendering are checked separately, including the runtime preparation script and exclusion of the local regression tests. Actual publishing remains a later release step.

Before upgrading production, complete at least:

1. Review effective platform values, especially explicit old image/preparation overrides and probe overrides. Preserve the existing ServiceAccount and claim ownership. The platform's current chart pin still points to 0.0.8.
2. Preserve/snapshot the existing disk according to its reclaim policy; record current values and immutable image identity.
3. Prepare the proposed release in an isolated test installation. Check Secret references, permissions, admission, actual node placement and RWO Job co-location where selected.
4. Run independent standard conversion fixtures and confirm no unexpected inference-time downloads. Test every adopted enrichment, OCR language and explicit/default preset. An upstream default alias is not necessarily excluded by a named preset allow-list.
5. Measure slow boot, failed worker, queue/backend outage, limits, cancellation and scratch exhaustion. Exercise restart/replay and result persistence for the chosen task backend.
6. Run real GPU conversion only for adopted GPU profiles, confirming actual device use, memory and sustained operation.
7. Qualify DocLang XML/DCLX conversion and import/export, XSD plus Schematron validation, assets, content layers and provenance. Pin the validation backend; its presence is not established by the current image.
8. Publish through `publish_charts.sh`, then update the platform pin through its established workflow. Roll out with the chosen task-drain/recovery policy and exercise rollback.

Authentication defaults are deliberately not switched on without an existing Secret and configured callers. Namespace ingress policy is deliberately not populated with guessed workload identities. Those require concrete platform integration, not arbitrary chart defaults.

RQ is still a recommendation to evaluate, not an implemented external worker deployment or an established Redis/Valkey compatibility result. Local state loss remains relevant even with better probes, Recreate strategy and a PDB.

## Should there be a separate client component?

**Yes. Create a separate top-level repository named `forwardmeasure-document-intelligence`, with a generated Docling transport client behind a product-neutral API.** Document conversion, OCR, page layout, tables, figures, multimodal processing and DocLang representations form a capability with its own contracts and runtime dependencies. NLP can consume its text and structured artifacts, alongside FEI and other products.

The earlier suggestion to nest this component under `forwardmeasure-nlp` inferred ownership from that repository's existing Maven structure. A reusable module pattern does not establish the right architectural boundary. Reuse platform build and contract-generation conventions while giving document understanding independent ownership and releases. This is the corrected recommendation, not a repository already created or a component already implemented.

A new client does not require a new always-running Java service. Docling Serve is already the conversion runtime. Add a separate service boundary only when authorization, language-specific validation or deployment isolation requires one.

The scope should distinguish three responsibilities:

| Responsibility | Owner |
|---|---|
| Product-neutral document conversion, artifact descriptors, DocLang validation and upstream client compatibility | Document-understanding component |
| Evidence authorization, tenant admission, extraction semantics, claims and business result persistence | FEI and the existing extraction capability |
| Durable retries, deadlines, replay, progress and business execution lifecycle | FOWF |

The component should work outside FEI and FOWF. It should not own their tenant databases, workflow state, investigation rules or claim ontology.

### What is already in the authorized legacy directory?

The inspected directory is:

`/home/pn/Documents/code/forwardmeasure/data-fabric/data-fabric-api-language-bindings/java/information-extraction-service`

The checked-in directory contains four POM files, forming a parent and three binding modules:

| Module | Observed purpose |
|---|---|
| information-extraction-service-binding | Parent reactor for Information Extraction API bindings |
| information-extraction-service-models | Generated business API models |
| information-extraction-service-client-apachehttp | Generated Java Apache HttpClient API client |
| information-extraction-service-server-jaxrs | Generated JAX-RS server contracts |

The client POM uses OpenAPI Generator's Java/apache-httpclient generator against `information-extraction-api.yaml`. It generates APIs separately from models, uses Jakarta configuration, includes the OpenAPI resource and declares an HttpClient 5 dependency. Its model and client package names are under `com.forwardmeasure.datafabric.informationextraction`.

There is **no checked-in Docling transport, conversion orchestration or DocLang validation implementation in this specific directory**. This finding does not claim the wider Data Fabric repository contains none; that wider repository was not searched for this request.

Reuse the separation of generated API/models and the published contract pattern. Do not carry legacy business DTOs or Data Fabric coordinates into the document-understanding core. Do not copy old generator templates, transport settings or blanket test skips without confirming they match current platform conventions. Generated-code exemptions do not exempt handwritten conversion/admission adapters.

### Proposed Maven structure

Start with the layers needed by a real consumer, rather than creating every optional artifact immediately:

```text
forwardmeasure-document-intelligence/
  forwardmeasure-document-intelligence-contracts/
  forwardmeasure-docling-api-models/
  forwardmeasure-docling-client-java/
  forwardmeasure-document-intelligence-core/
  forwardmeasure-document-intelligence-bom/
  # Add framework/validation adapters as actual integration requires them.
```

The upstream API snapshot may live in a contracts/specifications artifact under the chosen repository's established contract packaging convention. Keep vendor DTOs in the generated Docling boundary. Prefer existing shared artifact-reference, identity, error and provenance contracts over inventing equivalent local classes.

- **Contracts:** product-neutral conversion requests, adopted options, input/output artifact references, capability constraints, validation reports and provenance. Bodies/archives stay in object storage; contract results carry bounded references.
- **Generated upstream models/client:** pinned Serve OpenAPI snapshot, version/checksum metadata, generated Java DTOs and transport; no handwritten reimplementation of endpoint DTOs.
- **Core:** map admitted options to Docling requests, upload/submit/poll/fetch/cancel, enforce bounded responses, translate errors and expose stable typed outcomes. Preserve raw versioned Docling JSON instead of reconstructing the complete Docling Python object model in Java.
- **Validation adapter:** pinned DocLang specification/toolkit/backend, XSD and Schematron results, controlled XML handling and DCLX archive/asset validation. Do not assume the generated REST client supplies this function or that a Java XSD parser implements the toolkit's full semantics.
- **Framework adapters when needed:** Quarkus, Spring Boot and Micronaut configuration, lifecycle, secret wiring, transport deadlines and telemetry around the same core. They should not duplicate conversion logic.
- **BOM:** coherent versions for the selected published contracts, generated client and core.

Before generating, inspect the pinned OpenAPI surface for multipart upload, asynchronous status/results, artifact download, cancellation and capability discovery. Verify support for unions, nullable fields, inline schemas and large/streamed results in the selected generator/library. Prefer the platform's current generated-client convention over introducing a transport solely because the legacy POM used it.

### Required execution contract

A shared task backend improves transport state but does not by itself provide business exactly-once behavior. Define:

1. An operation key derived from authorized source evidence identity/version/hash, conversion image, model inventory, selected options and output contract versions.
2. Product-owned durable admission and attempt state. A network timeout after submission is an uncertain outcome; do not blindly create another conversion or claim.
3. Persisted task handles and status before following the operation through polling or notifications. Handles are operational references, not the durable evidence artifact.
4. Bounded polling, deadline and cancellation semantics coordinated with FOWF; identify which failures can be retried or reconciled.
5. Durable result storage and provenance before reporting business completion. Preserve original evidence, Docling JSON and accepted DocLang/DCLX artifacts with hashes, storage versions and validation outcome.
6. Idempotent FEI result writes through authorized generated APIs. Workflow workers should not write directly to business databases.
7. Structured errors and safe diagnostics using current shared platform contracts; never log document bodies, raw credentials or token-bearing upstream exception text as routine diagnostics.

The service API key authenticates the workload to Docling. It does not replace authorization for a tenant's input evidence or output artifact. Imported DocLang governance metadata and document content remain untrusted input.

### DocLang responsibility

Treat DocLang as a versioned representation, not a conversion-accuracy certificate. Retain original bytes and native Docling JSON. Record the serializer/schema/toolkit/backend versions, namespaces and content-layer policy.

Bound XML size/depth/elements and disable external entity/DTD resolution. Bound archive paths, member count, expanded size and compression behavior, and verify DCLX asset references. Preserve original output hashes when normalization produces a second artifact. Geometry, mixed text, lists, captions, tables, figures, custom fields and hidden layers need round-trip fixtures.

Validation may require a Python/Saxon-backed adapter or another qualified implementation. Select that deployment and licensing/runtime combination deliberately; the client-module proposal does not silently add a validator service or install a backend into the chart.

### Suggested implementation sequence

1. Record independent document-understanding ownership and its product-neutral API boundary in the new top-level repository.
2. Select and snapshot the exact upstream contract; generate a client using the platform's current contract tooling.
3. Build the smallest standard conversion path with immutable source references, explicit options, bounded artifacts and provenance.
4. Integrate one FEI worker through FOWF, using durable admission/result APIs and real object storage.
5. Prove uncertain submission, duplicate delivery, process restart, result expiry, cancellation and persistence failure behavior.
6. Add DocLang XML/DCLX validation and round trips before enabling it as an accepted downstream artifact.
7. Add adopted GPU/enrichment profiles and framework parity evidence; publish independently versioned artifacts for NLP, FEI and other consumers.

No Java component, client generation or business contract change has been made in this task. The recommendation and inspection are complete; implementation requires the separate component work described above.

## Primary upstream references

- [Serve 1.37.0 source and changelog](https://github.com/docling-project/docling-serve/tree/v1.37.0).
- [Serve settings: API key, limits, preset lists, RQ/Ray configuration](https://github.com/docling-project/docling-serve/blob/v1.37.0/docling_serve/settings.py).
- [Jobkit 3.8.2 converter manager: preset registries and default aliases](https://github.com/docling-project/docling-jobkit/blob/v3.8.2/docling_jobkit/convert/manager.py).
- [Docling 2.138.0 stage specifications](https://github.com/docling-project/docling/blob/v2.138.0/docling/datamodel/stage_model_specs.py).
- [Docling 2.138.0 VLM specifications](https://github.com/docling-project/docling/blob/v2.138.0/docling/datamodel/vlm_model_specs.py).
- [DocLang toolkit 0.7.3](https://github.com/doclang-project/doclang/releases/tag/v0.7.3).

These sources describe upstream behavior; local chart tests establish only the specific rendering and publication guarantees stated above.

## Client implementation follow-up — 2026-10-14

The standalone `forwardmeasure-document-intelligence` component now implements the generated Serve client, portable contracts, bounded transport, artifact persistence, provenance, DocLang/DCLX validation, Spring/Quarkus/Micronaut bindings, CLI and component BOM. Its OpenAPI source is the full schema extracted from the exact pinned 1.37.0 CPU image (23 paths, 166 schemas); a reproducible Java generation normalization retains all paths and schemas. Postman assets moved into that component. Historical deployment observations above remain observations of Serve 1.31.0. The live cluster has not been upgraded by the client implementation. See the component README and implementation evidence for current scope and qualification.
