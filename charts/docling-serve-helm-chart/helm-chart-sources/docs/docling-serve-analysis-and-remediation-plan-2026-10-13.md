# Docling Serve analysis and remediation plan — complete reference

Reference captured October 13, 2026, America/New_York. The complete planning response below is retained as originally delivered. Its statements about actions not performed describe the planning review; subsequent implementation is documented separately in the chart README and implementation handover.

The original tentative NLP ownership suggestion has since been reconsidered. The current recommendation is a separate top-level `forwardmeasure-document-understanding` repository, with NLP as a consumer. See the [implementation handover](docling-serve-chart-implementation-2026-10-13.md#should-there-be-a-separate-client-component) for the corrected component boundary. The historical planning response remains intact below.

---

**We are behind on Docling software, but the selected standard model weights are current. DocLang is already available in the deployed image; the newer releases improve its fidelity and integration.**

My recommendation is to repair the chart, qualify **Docling Serve 1.37.0** as one complete dependency set, establish reproducible model preparation, and add DocLang as a validated document representation within the existing evidence pipeline.

Everything below is a proposed plan. **I made no repository or cluster configuration changes, installed nothing, and submitted no document-conversion jobs.** The additional live investigation consisted of reading installed code, querying existing endpoints, inspecting model files, and verifying checksums.

As of **October 13, 2026**, the version comparison is:

| Component | Installed | Latest stable / included in Serve 1.37.0 | Assessment |
|---|---:|---:|---|
| Docling Serve | 1.31.0 | **1.37.0** | Behind |
| Docling / `docling-slim` | 2.121.0 | **2.138.0** | Behind |
| Docling Core | 2.92.0 | **2.101.1** | Behind |
| Docling Jobkit | 3.4.0 | **3.8.2** | Behind |
| Docling IBM Models | 3.14.0 | **4.0.3** | Behind |
| Docling Parse | 7.15.0 | **7.22.3** | Behind |
| DocLang toolkit | **0.7.3** | **0.7.3** | Current toolkit release |
| ForwardMeasure chart | Deployed **0.0.8** | Locally packaged **0.0.9** | Platform pin remains on 0.0.8 |

Serve **1.37.0 was released today at 10:10 a.m. EDT**. Its release notes identify the complete library set above. This should be evaluated as a coordinated upgrade; separately upgrading individual Python libraries inside the existing image would produce a different, unqualified combination. [Serve changelog and dependency versions](https://raw.githubusercontent.com/docling-project/docling-serve/v1.37.0/CHANGELOG.md), [Docling 2.138.0 release](https://github.com/docling-project/docling/releases/tag/v2.138.0), [DocLang toolkit release](https://github.com/doclang-project/doclang/releases/tag/v0.7.3).

There are also changes relevant to this deployment beyond new formats: newer Serve releases add capability discovery, revised UI behavior, chart-extraction runtimes and additional queue controls; Core 2.101.1 fixes URL address validation and connection pinning; Jobkit 3.8.2 fixes application of RQ job timeouts and cancellation of abandoned Ray conversions. These require compatibility and recovery checks alongside conversion-quality checks. [Core release](https://github.com/docling-project/docling-core/releases/tag/v2.101.1), [Jobkit release](https://github.com/docling-project/docling-jobkit/releases/tag/v3.8.2).

The model investigation gives a more precise answer than a package-version comparison alone.

I recomputed the checksums of **all 50 files** listed in the existing model manifest. Every checksum matched. I also compared the **seven Hugging Face weight files** against current upstream SHA-256 metadata:

| Selected model family | Files checked against upstream | Result |
|---|---|---|
| Layout Heron | PyTorch weights | Matches current repository weights |
| Layout Heron ONNX | ONNX weights | Matches current repository weights |
| TableFormer V1 | Accurate and fast weights | Both match |
| CodeFormulaV2 | Model weights | Matches |
| DocumentFigureClassifier v2.5 | PyTorch and ONNX weights | Both match |
| RapidOCR | PP-OCRv6 small detection/recognition files are present | Existing manifest verified; upstream currency not independently established for every OCR asset |
| EasyOCR | CRAFT, English and Latin recognition files are present | Existing manifest verified; language coverage still needs explicit assessment |
| Whole-document VLM models | No Granite Docling or Granite Vision directories in the PVC | **Not prepared in the deployed model store** |

This establishes artifact integrity and currency for the selected Hugging Face weights. It does **not** establish conversion quality, the actual inference backend used for every request, or support for every language. [Heron model](https://huggingface.co/docling-project/docling-layout-heron), [TableFormer V1 repository](https://huggingface.co/docling-project/docling-models), [CodeFormulaV2](https://huggingface.co/docling-project/CodeFormulaV2), [Figure classifier](https://huggingface.co/docling-project/DocumentFigureClassifier-v2.5).

The upstream model catalogue contains alternatives worth evaluating, but their roles differ:

| Capability | Existing selection | Candidates to assess | Proposed treatment |
|---|---|---|---|
| Layout detection | Heron | Heron 101; Egret medium, large and xlarge | Keep Heron as the comparison baseline; measure quality and resource use |
| Table structure | TableFormer V1 | TableFormer V2 | Compare merged cells, reading order and cell-text alignment |
| OCR | Existing PP-OCRv6 / EasyOCR assets | Explicit language and inference-backend profiles | Prepare the languages actually required |
| Code/formula enrichment | CodeFormulaV2 weights | CodeFormulaV2 and Granite Docling presets | Set the default explicitly rather than inheriting an upgrade change |
| Whole-page VLM conversion | None deployed | Granite Docling 258M; existing Granite Vision 3.2 preset; other supported presets if needed | Prepare and qualify separate profiles |
| Chart/table visual extraction | None established | Granite Vision 4.1 through the appropriate extraction preset | Treat as a separate enrichment capability |

The current upstream layout default remains Heron. Larger alternatives therefore should be assessed against independently expected results, rather than selected solely because they are larger or newer. [Layout catalogue](https://raw.githubusercontent.com/docling-project/docling/v2.138.0/docling/datamodel/layout_model_specs.py), [Stage presets](https://raw.githubusercontent.com/docling-project/docling/v2.138.0/docling/datamodel/stage_model_specs.py), [TableFormer V2](https://huggingface.co/docling-project/TableFormerV2).

In particular, **Granite Vision 4.1 is not a direct replacement for the chart’s whole-page `granite_vision` preset**. The page-conversion preset uses Granite Vision 3.2 and produces Markdown; the newer chart-extraction configuration uses specialized prompts and outputs. Updating `vlm-large` to the numerically newest Granite Vision repository without changing and qualifying its task configuration would repeat the model-role mismatch that chart 0.0.9 attempted to correct. [VLM definitions](https://raw.githubusercontent.com/docling-project/docling/v2.138.0/docling/datamodel/vlm_model_specs.py), [Chart-extraction configuration](https://raw.githubusercontent.com/docling-project/docling/v2.138.0/docling/datamodel/chart_extraction_options.py).

DocLang deserves adoption work, but it should be understood as a representation and interchange format.

**DocLang represents structured document content in constrained XML.** It can carry document hierarchy, semantic elements, geometry, tables, images and metadata. The specification currently identifies version **0.7**. That specification version is distinct from the toolkit package version **0.7.3**. Its recommended XML extension is `.dclg`; `.dclx` is a ZIP/OPC package containing the document and associated parts such as images. [DocLang specification](https://raw.githubusercontent.com/doclang-project/doclang/main/spec.md).

The deployed API already advertises:

- Input formats `xml_doclang` and `dclx`.
- Output formats `doclang` and `dclx`.
- The installed DocLang toolkit, version 0.7.3.

Those are source and schema facts. **A successful DocLang or DCLX conversion, validation, or round trip has not yet been established in this deployment.**

For the platform, I propose these roles:

| Representation | Proposed role |
|---|---|
| Original evidence bytes | Immutable source evidence, with its original hash and storage version |
| Docling JSON | Rich structured conversion result retained for audit, processing and comparison |
| DocLang XML | Versioned interchange and structured input for extraction or retrieval |
| DCLX archive | Portable package containing DocLang and associated assets |
| Markdown / text | Human-readable or simplified downstream derivatives |
| DocTags | Model-oriented representation where a selected conversion model uses it |

DocLang will not recover information a converter failed to extract. It also does not establish the truth of extracted claims or make an inference trustworthy merely by giving it structure. Its practical benefit is preserving more of the conversion result and allowing later stages to reference that structure.

There are four implementation details that matter here:

- **Recent fidelity fixes:** Core releases after the installed 2.92.0 improve mixed-content preservation, captions, footnotes, groups, page-spanning content and serialization behavior. These are material reasons to qualify the newer Core before adopting DocLang for evidence processing. [Core 2.100.0 changes](https://github.com/docling-project/docling-core/releases/tag/v2.100.0).
- **Namespace handling:** the serializer defaults to omitting the XML namespace. Full validation needs an explicit namespace strategy, either namespaced serialization or the toolkit’s documented namespace normalization.
- **Validation runtime:** Saxon/C is absent from the deployed image. The toolkit’s default full validation requires a Schematron backend; XSD-only validation must be reported as such. [Toolkit validation instructions](https://github.com/doclang-project/doclang/blob/v0.7.3/doclang/README.md).
- **Content and image selection:** the DocLang serializer defaults to all content layers, and export methods have image-handling defaults. We must explicitly control which layers and assets enter analyst views or model prompts. DCLX packaging and validation options also need explicit configuration. [Serializer defaults](https://raw.githubusercontent.com/docling-project/docling-core/v2.101.1/docling_core/transforms/serializer/doclang.py), [Export and archive methods](https://raw.githubusercontent.com/docling-project/docling-core/v2.101.1/docling_core/types/doc/document.py).

I would carry out the remediation in the following order.

1. **Freeze the baseline and define the acceptance contract.**

   Record the deployed chart, Helm values, image digest, package versions, Service DNS name, storage details and verified model manifest. Preserve the existing chart 0.0.8 configuration as the rollback reference.

   Define supported deployment profiles, document formats, languages, enrichments and output representations. Separately record processing limits, acceptable conversion quality, expected concurrency and recovery requirements. These are product and operating decisions; the current chart defaults do not establish them.

   Build a small, independently reviewed document corpus covering digital PDFs, scanned pages, multicolumn text, rotated pages, merged-cell tables, formulas, code, figures and redacted evidence. Include relevant languages and difficult documents from the intended workload.

   **Acceptance:** every subsequent change can be tied to an identified requirement, baseline and expected result.

2. **Repair chart validation and configuration ownership.**

   Add a `values.schema.json` and template checks for relationships that JSON Schema alone cannot conveniently enforce.

   Validate `mode`, pipeline names, resource quantities, replica counts, image references, model preparation settings and storage combinations. Reject unsupported CPU/VLM-large selection with a useful message. Reject an unknown pipeline before it renders null resource requests. Require a valid model source rather than allowing a deployment to reference an absent PVC.

   Replace the incomplete static-PV path with either a fully specified, validated volume source or a reference to externally provisioned storage. Keep dynamic PVC provisioning supported.

   Give the download-library ConfigMap a release-specific name. Add configuration checksums to the pod template so relevant changes cause a rollout. Preserve explicit ServiceAccount names such as the current `docling`, because their IAM bindings are operational dependencies.

   **Acceptance:** all supported combinations render valid Kubernetes objects; invalid combinations fail clearly; two releases can coexist in one namespace.

3. **Use upstream health endpoints correctly.**

   Both the installed version and the target version expose these endpoints:

   | Probe | Proposed endpoint | Purpose |
   |---|---|---|
   | Startup | `/ready` | Wait for initialization and required model loading |
   | Readiness | `/ready` | Stop routing when the processor or backend is unavailable |
   | Liveness | `/livez` | Restart when the background processor has failed |

   `/health` unconditionally reports success and should no longer be used as the sole signal for all three probes. There is no need to invent a replacement health implementation. [Upstream endpoint implementation](https://raw.githubusercontent.com/docling-project/docling-serve/v1.37.0/docling_serve/app.py).

   Expose probe timeout, period and failure-threshold settings separately. Determine startup budgets from measured cold and warm initialization for each profile. Preserve the distinction between a dead processor and a temporary backend outage: the latter should remove readiness without automatically causing repeated restarts.

   **Acceptance:** initialization blocks readiness; processor failure removes readiness and triggers recovery; a backend interruption does not cause a restart storm.

4. **Make model preparation reproducible and independent of ordinary pod startup.**

   Define one authoritative model inventory containing the stage or preset, repository, immutable revision, required files, checksums, license, inference backend and compatible runtime/bundle versions.

   Remove unconditional standard-model downloads from each serving-pod start. The current image already contains the standard models at `/opt/app-root/src/.cache/docling/models`, and the upstream image build downloads standard assets. The chart currently overrides that path and performs another download. [Upstream image build](https://raw.githubusercontent.com/docling-project/docling-serve/v1.37.0/Containerfile).

   Support two explicit preparation sources: use the qualified image’s bundled assets, or prepare an immutable external bundle for a selected model profile. A mixed profile must have one complete resolved inventory and artifact root.

   For external preparation, stage files separately, validate completeness and checksums, and publish the completed bundle atomically. A `config.json` file must never establish completion. Replace destructive stale-lock removal with ownership-aware locking and recovery. A failed preparation must leave the previous complete bundle usable.

   Manifests should cover the selected model set, not every directory found under the cache—including unrelated models or filesystem directories.

   **Acceptance:** warm restarts make no model-download requests; partial copies cannot be accepted; concurrent preparation cannot publish a corrupt bundle; rollback can select the previous bundle.

5. **Separate model storage, download cache and processing scratch space.**

   Make the three storage purposes explicit:

   | Storage purpose | Required behavior |
   |---|---|
   | Qualified model assets | Immutable during serving; mounted read-only where practical |
   | Hugging Face download cache | Used during preparation; persistence and cleanup defined explicitly |
   | Processing scratch/results | Writable, bounded and governed by the selected job backend |

   Repair the current `HF_HOME`/`HF_HUB_CACHE` configuration. The configured path is outside the persistent model mount. If serving is fully offline, runtime downloads should be prevented; if a download cache remains necessary, mount it deliberately.

   Replace recursive `chmod 0777` with appropriate ownership and group permissions. Provide bounded writable directories for scratch files and any inference caches before enabling a read-only root filesystem.

   **Preserve the existing PVC during migration.** Its disk has a `Delete` reclaim policy. Changing creation flags or switching a Helm-owned PVC to `existingClaim` can remove it from the rendered release. The storage transition must be reviewed and tested before any manifest ownership change; do not assume an upgrade will retain it automatically.

   **Acceptance:** storage survives the intended upgrade and rollback; runtime writes stay in declared locations; restarting a pod does not recreate or redownload its model store.

6. **Qualify the complete 1.37.0 image set.**

   Add digest support to the chart’s image helper. Apply it consistently to serving and preparation images. Set meaningful version metadata instead of `appVersion: latest`.

   I verified publication of these target images:

   | Target image | Registry manifest digest |
   |---|---|
   | `quay.io/docling-project/docling-serve-cpu:v1.37.0` | `sha256:6eda9c524992147c1b0b06a1a9be4894bd68b1f43c86d92c32f996c4c60d18a3` |
   | `quay.io/docling-project/docling-serve-cu128:v1.37.0` | `sha256:2aa6fc687c9211911b51ad2a60c33028358973fd053be9dd1cc4646017dfc76d` |
   | `quay.io/docling-project/docling-serve-cu130:v1.37.0` | `sha256:6fa19475d5f2db563d94b61a167588dba5897a3323d2bba390b4a1e679e38ef1` |

   These are registry references, **not images qualified through execution here**. Confirm architecture selection and inspect installed versions in the actual evaluation containers. [CPU tag metadata](https://quay.io/api/v1/repository/docling-project/docling-serve-cpu/tag/?specificTag=v1.37.0), [CUDA 12.8 metadata](https://quay.io/api/v1/repository/docling-project/docling-serve-cu128/tag/?specificTag=v1.37.0), [CUDA 13 metadata](https://quay.io/api/v1/repository/docling-project/docling-serve-cu130/tag/?specificTag=v1.37.0).

   Keep CUDA 12.8 as the first GPU compatibility candidate because it matches the chart’s existing image family. Qualify driver compatibility, accelerator detection and actual GPU use before considering CUDA 13. Changing the application release does not require changing CUDA families.

   Capture and compare the upstream OpenAPI contract. Regenerate affected clients through the existing contract-first workflow and account for removed endpoints and changed options.

   **Acceptance:** package versions, API behavior, selected models and accelerator behavior match the recorded image identity.

7. **Set authentication, caller access and processing limits explicitly.**

   Add Secret-backed environment references for the Docling API key. Keep Hugging Face download credentials separate from service authentication credentials. Do not place secret values in Helm values, generated ConfigMaps, workflow inputs or logs.

   Keep Docling internal. Restrict namespace traffic to identified callers and required dependencies through NetworkPolicy. Determine whether its currently shared Google service-account permissions are actually needed for the chosen model and storage arrangement.

   Apply non-root execution, capability dropping and explicit writable mounts where supported by the image and GPU runtime. Disable Kubernetes API token mounting when the process has no Kubernetes API requirement.

   Define finite document-byte, page, processing-time, image-scale, concurrency and scratch-space limits. Establish a controlled bulk profile where larger documents are required; do not silently truncate a document to satisfy a limit.

   Prefer caller-controlled evidence retrieval and upload over unrestricted document URL fetching. Where URLs are necessary, qualify signed-storage URLs, redirects, DNS handling and intended egress destinations.

   **Acceptance:** unauthorized callers cannot submit or retrieve work; oversize work fails predictably; allowed storage retrieval still works; credentials and document content remain absent from logs.

8. **Choose and implement the asynchronous recovery model before adding replicas.**

   The existing local engine keeps its task queue and results in process memory. More pods would not provide a shared task registry, and the RWO model disk adds placement constraints.

   | Option | Suitable use | Required work |
   |---|---|---|
   | Local engine | Deliberate single-instance compute service with replay managed by FOWF | Define task-loss recovery, drain behavior and idempotent result persistence |
   | RQ engine | Shared task state and independently scalable workers | Qualify Redis-compatible storage, workers, timeouts, result retention and recovery |
   | Ray engine | Workloads that justify distributed model serving | Qualify its additional runtime and operating requirements |

   **My recommendation for shared asynchronous workers is to evaluate RQ first.** Reuse platform-managed infrastructure where compatible, but do not assume the existing Valkey deployment is automatically suitable for Docling queues. Confirm command compatibility, durability, memory/eviction policy, authentication and workload isolation.

   FOWF remains the durable business orchestrator. Persist the conversion identity before dispatch, correlate Docling task IDs, and make FEI result persistence idempotent. Handle uncertain submission and result-retrieval outcomes explicitly. Do not claim exactly-once inference.

   Result retention must cover the retry and persistence window. An API pod being ready must not be treated as proof that a worker has loaded the required models.

   **Acceptance:** worker and API restarts, response loss, retry and result expiry produce defined outcomes without duplicated business results or permanently stranded work.

9. **Make model selection explicit at admission and benchmark every adopted profile.**

   Retain the supported CPU/GPU profiles, but separate deployment resource selection from request pipeline selection. A pod annotation does not force a request onto a VLM pipeline.

   Pin defaults for layout, tables, OCR, code/formula enrichment, whole-page VLM conversion and chart extraction. This is especially important for code/formula processing: Serve 1.37.0 uses a Granite Docling default, while the current PVC contains CodeFormulaV2 and no Granite Docling weights.

   Advertise only prepared and permitted presets. Validate capability discovery against actual accepted requests, including default-preset resolution.

   Benchmark candidates against the baseline corpus. Record reading-order errors, OCR accuracy, table-cell fidelity, formula/code quality, provenance completeness, latency, memory, GPU usage and failure rates. Include model preparation and warm-start costs.

   **Acceptance:** every enabled preset has its required assets and backend, a documented purpose, measured behavior and independently assessed quality.

10. **Add a versioned DocLang conversion and validation stage.**

    Generate upstream clients from the pinned contract rather than hand-writing a replacement client. Request Docling JSON and DocLang together where appropriate; use the artifact-output path for DCLX and associated images.

    Validate XML structure and Schematron rules with a pinned schema/toolkit/backend. Choose namespace normalization deliberately. Preserve original output bytes and hashes when normalization creates a second representation. Do not apply silent “repair” to malformed model output and then describe it as the original valid result.

    Reject DTD/entity references and uncontrolled external references. Bound XML depth, size and element count. For archives, qualify member paths, member count, expanded size, compression behavior and asset references.

    Test names, labels, tables, captions, footnotes, lists, figures, mixed content, multiple pages and non-ASCII text through round trips. Define acceptable geometry tolerances; a compact representation can normalize or quantize positions, so exact native coordinates should remain available in the retained structured result.

    **Acceptance:** validation results are recorded, required semantics survive round trips, and malformed or excessive input fails with a structured error.

11. **Integrate DocLang with evidence provenance and the existing FEI/FOWF boundaries.**

    Preserve the original evidence hash and object version. Record conversion image identity, package versions, model-bundle identity, request-options digest, output hashes, validation result and source references.

    Store document bodies and archives in object storage. Pass bounded references through FOWF, following its existing data-placement rule. Workers use authorized FEI APIs for result persistence.

    Maintain traceable references from extraction results to document elements, pages and source locations. Preserve authenticated caller versus asserted subject. Treat imported governance metadata and document content as untrusted input; they cannot grant permissions.

    Select content layers for each downstream purpose. A complete audit artifact and an authorized model prompt may contain different permitted content. Redaction and victim-protection requirements must survive conversion and derivative generation.

    Reuse FEI’s existing extraction/result structures where they fit. The current FEI contract still describes extraction and reprocessing as dependent on the backend decision, so adoption must include that contract decision and inspection of the existing extraction-agent implementation.

    **Acceptance:** original evidence, conversion artifacts and extracted claims remain connected, tenant-correct and reviewable through the real API and Studio.

12. **Complete verification, publication, rollout and rollback as separate stages.**

    Build the fixtures first. Run source, contract, frontend and Helm checks appropriate to the changes, then execute the agreed integration and recovery programme. Publish the chart through the repository’s release automation; do not overwrite existing chart packages or invent a manual versioning procedure.

    Update the platform chart pin only after the new chart is published and qualified. Preserve the existing Service DNS identity. Perform a controlled rollout with admission/drain behavior appropriate to the selected task backend.

    Keep the old image, chart values and model bundle available. A Helm rollback alone does not restore lost task state or undo changed output contracts.

    **Acceptance:** the release has identified images, charts, models, contract versions, execution evidence and an exercised rollback procedure.

The implementation ownership would be:

| Location | Planned responsibility |
|---|---|
| [Chart values](/home/pn/Documents/code/forwardmeasure/helm-charts/charts/docling-serve-helm-chart/helm-chart-sources/values.yaml) and a new values schema | Valid profiles, images, limits, storage and backend settings |
| [Deployment template](/home/pn/Documents/code/forwardmeasure/helm-charts/charts/docling-serve-helm-chart/helm-chart-sources/templates/deployment.yaml) | Probes, Secret references, storage mounts, security context and rollout behavior |
| [Download library template](/home/pn/Documents/code/forwardmeasure/helm-charts/charts/docling-serve-helm-chart/helm-chart-sources/templates/model-download-lib-configmap.yaml) | Replacement or repair of preparation, completion checks and manifest handling |
| Existing PV/PVC templates | Valid storage configuration and migration-safe ownership |
| New optional chart templates | Preparation Job, NetworkPolicy, worker deployments and monitoring resources where selected |
| [Platform Docling release values](/home/pn/Documents/code/forwardmeasure/forwardmeasure-platform/deploy/helmfile/releases/docling/base.yaml.gotmpl) | Explicit production selection and model/backend configuration |
| [Platform chart versions](/home/pn/Documents/code/forwardmeasure/forwardmeasure-platform/deploy/helmfile/environments/chart-versions.yaml) | Published chart selection |
| `forwardmeasure-nlp` integration ownership, to be confirmed | Generated upstream client and reusable conversion/validation integration |
| FEI and FOWF | Authorized evidence admission, durable orchestration, typed results and Studio integration |

The verification programme should cover the following outcomes:

| Area | Required evidence |
|---|---|
| Chart configuration | All five supported CPU/GPU combinations; invalid enums, resources, storage and image settings rejected |
| Release isolation | Two releases in one namespace without resource-name collisions |
| Model preparation | Empty store, complete store, corrupt file, partial copy, concurrent preparers and interrupted preparation |
| Offline operation | Warm restart and enabled-model inference without unexpected model downloads |
| Probes | Slow initialization, processor failure and temporary backend outage |
| Storage | Fresh install, upgrade, node replacement and rollback without unintended PVC deletion |
| CPU conversion | Independent expected text, structure, tables and provenance |
| GPU conversion | Actual accelerator use, profile resource limits and sustained operation |
| Model selection | Explicit/default presets, unprepared presets and disallowed configurations |
| DocLang XML | Well-formedness, namespace strategy, XSD and Schematron results |
| DCLX | Packaging, assets, page images, import/export and bounded archive processing |
| Round trips | Lists, mixed text, captions, footnotes, tables, figures, geometry and custom fields |
| Content handling | Hidden layers, annotations, redactions and authorized prompt selection |
| Async recovery | API/worker restart, uncertain submission, duplicate delivery, result expiry and persistence failure |
| Security | Missing/wrong credentials, unauthorized callers and wrong-tenant evidence/result access |
| Limits | Oversize files, excessive pages, long processing and scratch exhaustion |
| Platform integration | Quarkus, Spring and Micronaut; applicable Kafka Streams and both Pekko persistence profiles |
| Studio | Real persisted progress, results, errors and source-evidence references |

Before implementation, these decisions should be confirmed:

| Decision | My recommendation |
|---|---|
| Upgrade target | Qualify the complete **Serve 1.37.0** image set |
| Initial model baseline | Preserve current standard selections explicitly; benchmark alternatives |
| Asynchronous backend | Evaluate **RQ** for shared workers; retain local mode only with an explicit replay/recovery contract |
| Model source | Use qualified image-bundled standard assets where sufficient; prepare immutable external bundles for adopted extensions |
| DocLang role | Adopt as a validated, versioned derivative/interchange format while retaining original evidence and Docling JSON |
| Validation | Full XSD and Schematron validation with a pinned backend |
| Workload policy | Define supported languages, enrichments, limits and quality thresholds from the intended evidence workload |
| FEI integration | Confirm the existing extraction-agent location and its admission/result contract |

**The first release should close the chart and operational defects without silently changing conversion semantics.** Model-family changes and DocLang adoption should carry their own recorded quality, fidelity and recovery evidence. Production rollout and publication remain future actions requiring authorization.
