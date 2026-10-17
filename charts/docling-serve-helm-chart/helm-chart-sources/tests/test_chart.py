#!/usr/bin/env python3
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements. See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License. You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Chart rendering and model-publication regressions; no cluster/inference tests."""

import hashlib
import importlib.util
import json
import multiprocessing
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml

CHART = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "docling_preparation", CHART / "files/model-preparation.py")
MODELS = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = MODELS
spec.loader.exec_module(MODELS)


class UniqueLoader(yaml.SafeLoader):
    pass


def unique_mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise AssertionError("Duplicate YAML key: " + str(key))
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)


def render(values=None, release="docling", success=True, namespace="docling-serve"):
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "values.yaml"
        path.write_text(yaml.safe_dump(values or {}))
        result = subprocess.run(
            ["helm", "template", release, str(CHART), "-n", namespace,
             "-f", str(path)], text=True, capture_output=True)
    if not success:
        if result.returncode == 0:
            raise AssertionError("Invalid values rendered successfully")
        return result.stderr
    if result.returncode:
        raise AssertionError(result.stderr)
    return [doc for doc in yaml.load_all(result.stdout, Loader=UniqueLoader) if doc]


def resource(docs, kind):
    return next(doc for doc in docs if doc["kind"] == kind)


class ChartContracts(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("DOCLING_TEST_IMAGE_MODELS") == "1",
                         "Set DOCLING_TEST_IMAGE_MODELS=1 to qualify the cached preparation image")
    def test_pinned_image_provides_required_ocr_assets(self):
        docs = render({"modelDownload": {"enabled": True}})
        config = json.loads(resource(docs, "ConfigMap")["data"]["models.json"])
        # OCR has no repository-download fallback: qualify real assets, offline.
        code = """
import json, runpy, sys
from pathlib import Path
preparer = runpy.run_path('/qualification/model-preparation.py')
config = json.load(sys.stdin)
models = [item for item in config['repositories'] if 'directory' in item]
assert models, 'No bundled OCR inventories selected'
for model in models:
    preparer['validate_model'](
        Path('/opt/app-root/src/.cache/docling/models') / model['directory'], model)
    print('Validated pinned image OCR assets: ' + model['directory'])
"""
        result = subprocess.run(
            ["docker", "run", "--rm", "-i", "--network", "none", "--pull", "never",
             "--entrypoint", "python", "--mount",
             f"type=bind,src={CHART / 'files/model-preparation.py'},dst=/qualification/model-preparation.py,readonly",
             config["image"], "-c", code],
            input=json.dumps(config), text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_all_five_supported_profiles(self):
        for mode, pipeline in [
                ("cpu", "standard"), ("cpu", "vlm-small"), ("gpu", "standard"),
                ("gpu", "vlm-small"), ("gpu", "vlm-large")]:
            with self.subTest(mode=mode, pipeline=pipeline):
                docs = render({"mode": mode, "pipeline": pipeline,
                               "modelDownload": {"enabled": True}})
                pod = resource(docs, "Deployment")["spec"]["template"]["spec"]
                main = pod["containers"][0]
                self.assertIn("@sha256:", main["image"])
                self.assertEqual(main["startupProbe"]["httpGet"]["path"], "/ready")
                self.assertEqual(main["readinessProbe"]["httpGet"]["path"], "/ready")
                self.assertEqual(main["livenessProbe"]["httpGet"]["path"], "/livez")
                self.assertEqual(resource(docs, "Deployment")["spec"]["strategy"]["type"], "Recreate")
                env = main["env"]
                self.assertEqual(len(env), len({entry["name"] for entry in env}))
                values = {entry["name"]: entry.get("value") for entry in env}
                self.assertEqual(int(values["DOCLING_SERVE_MAX_FILE_SIZE"]), 104857600)
                self.assertIn("/.bundles/", values["DOCLING_SERVE_ARTIFACTS_PATH"])
                self.assertEqual(pod["initContainers"][0]["name"], "prepare-models")
                self.assertIn("docling-serve-cpu@", pod["initContainers"][0]["image"])
                self.assertEqual(main["volumeMounts"][-1]["readOnly"], True)
                if mode == "gpu":
                    self.assertEqual(main["resources"]["requests"]["nvidia.com/gpu"], 1)
                    self.assertEqual(main["resources"]["limits"]["nvidia.com/gpu"], 1)
                if pipeline != "standard":
                    self.assertEqual(values["DOCLING_SERVE_ALLOWED_VLM_PRESETS"],
                                     "granite_docling" if pipeline == "vlm-small" else "granite_vision")

    def test_include_vlm_decouples_vlm_from_boot_pipeline(self):
        # pipeline stays "standard" (boot/sizing) but granite is bundled and allowed.
        docs = render({"pipeline": "standard",
                       "modelDownload": {"enabled": True, "includeVlm": ["vlm-small"]}})
        main = resource(docs, "Deployment")["spec"]["template"]["spec"]["containers"][0]
        values = {e["name"]: e.get("value") for e in main["env"]}
        self.assertEqual(values["DOCLING_SERVE_ALLOWED_VLM_PRESETS"], "granite_docling")
        # standard boot: no default VLM forced.
        self.assertNotIn("DOCLING_SERVE_DEFAULT_VLM_PRESET", values)
        inventory = json.loads(resource(docs, "ConfigMap")["data"]["models.json"])
        self.assertIn("ibm-granite/granite-docling-258M",
                      [r.get("repo") for r in inventory["repositories"]])

    def test_include_vlm_default_is_absent_and_requires_a_prepared_bundle(self):
        # Default: no includeVlm -> no VLM env, unchanged behaviour.
        docs = render({"pipeline": "standard", "modelDownload": {"enabled": True}})
        values = {e["name"]: e.get("value")
                  for e in resource(docs, "Deployment")["spec"]["template"]["spec"]
                  ["containers"][0]["env"]}
        self.assertNotIn("DOCLING_SERVE_ALLOWED_VLM_PRESETS", values)
        # image source has no VLM assets: includeVlm must be rejected.
        error = render({"persistence": {"create": False},
                        "modelDownload": {"includeVlm": ["vlm-small"]}}, success=False)
        self.assertIn("includeVlm requires a prepared bundle", error)
        # vlm-large is GPU-only.
        error = render({"mode": "cpu",
                        "modelDownload": {"enabled": True, "includeVlm": ["vlm-large"]}},
                       success=False)
        self.assertIn("cannot contain vlm-large in cpu mode", error)

    def test_image_models_do_not_download_or_reference_a_pvc(self):
        docs = render({"persistence": {"create": False}})
        pod = resource(docs, "Deployment")["spec"]["template"]["spec"]
        self.assertNotIn("initContainers", pod)
        self.assertFalse(any("persistentVolumeClaim" in v for v in pod["volumes"]))
        env = {e["name"]: e["value"] for e in pod["containers"][0]["env"]}
        self.assertEqual(env["DOCLING_SERVE_ARTIFACTS_PATH"],
                         "/opt/app-root/src/.cache/docling/models")
        self.assertTrue(env["HF_HUB_CACHE"].startswith(env["HF_HOME"] + "/"))
        self.assertTrue(any(m["mountPath"] == "/opt/docling-serve/cache"
                            for m in pod["containers"][0]["volumeMounts"]))

    def test_legacy_values_keep_service_claim_and_identity(self):
        docs = render({"modelDownload": {"enabled": True},
                       "persistence": {"create": True, "existingClaim": "", "size": "64Gi"},
                       "serviceAccount": {"name": "docling"}})
        self.assertEqual(resource(docs, "Service")["metadata"]["name"], "docling-docling-serve")
        claim = resource(docs, "PersistentVolumeClaim")
        self.assertEqual(claim["metadata"]["name"], "docling-docling-serve-cache")
        self.assertEqual(claim["metadata"]["annotations"]["helm.sh/resource-policy"], "keep")
        self.assertEqual(resource(docs, "ServiceAccount")["metadata"]["name"], "docling")

    def test_release_names_do_not_collide(self):
        first = render({"modelDownload": {"enabled": True}}, "one")
        second = render({"modelDownload": {"enabled": True}}, "two")
        first_names = {(d["kind"], d["metadata"]["name"]) for d in first}
        second_names = {(d["kind"], d["metadata"]["name"]) for d in second}
        self.assertFalse(first_names & second_names)

    def test_external_claim_is_read_only_and_never_recreated(self):
        docs = render({"modelSource": "pvc", "persistence": {"existingClaim": "external-models"}})
        self.assertFalse(any(d["kind"] in ["PersistentVolume", "PersistentVolumeClaim"] for d in docs))
        pod = resource(docs, "Deployment")["spec"]["template"]["spec"]
        self.assertIn("--legacy", pod["initContainers"][0]["args"])
        self.assertTrue(pod["containers"][0]["volumeMounts"][-1]["readOnly"])

    def test_static_pv_has_a_real_source_and_empty_class(self):
        docs = render({"persistence": {"bindToPv": True,
                      "volumeSource": {"csi": {"driver": "pd.csi.storage.gke.io", "volumeHandle": "disk-identity"}}}})
        pv = resource(docs, "PersistentVolume")
        claim = resource(docs, "PersistentVolumeClaim")
        self.assertEqual(pv["spec"]["csi"]["volumeHandle"], "disk-identity")
        self.assertEqual(claim["spec"]["volumeName"], pv["metadata"]["name"])
        self.assertEqual(claim["spec"]["storageClassName"], "")

    def test_authentication_and_backend_credentials_are_secret_references(self):
        docs = render({"replicaCount": 2, "engine": {"kind": "rq", "redisSecret": {"name": "queue-url"}},
                       "auth": {"enabled": True, "existingSecret": "docling-api-key"},
                       "envSecretRefs": {"EXTERNAL_PASSWORD": {"name": "peer-secret", "key": "password"}}})
        env = {e["name"]: e for e in resource(docs, "Deployment")["spec"]["template"]["spec"]["containers"][0]["env"]}
        for name in ["DOCLING_SERVE_API_KEY", "DOCLING_SERVE_ENG_RQ_REDIS_URL", "EXTERNAL_PASSWORD"]:
            self.assertNotIn("value", env[name])
            self.assertIn("secretKeyRef", env[name]["valueFrom"])

    def test_static_pv_names_include_namespace_for_cluster_scope(self):
        values = {"persistence": {"bindToPv": True,
                  "volumeSource": {"nfs": {"server": "storage", "path": "/models"}}}}
        first = resource(render(values, namespace="first"), "PersistentVolume")
        second = resource(render(values, namespace="second"), "PersistentVolume")
        self.assertNotEqual(first["metadata"]["name"], second["metadata"]["name"])

    def test_network_policy_distinguishes_unrestricted_and_denied_egress(self):
        policy = resource(render({"networkPolicy": {"enabled": True}}), "NetworkPolicy")
        self.assertEqual(policy["spec"]["ingress"], [])
        self.assertNotIn("egress", policy["spec"])
        policy = resource(render({"networkPolicy": {"enabled": True, "egress": []}}), "NetworkPolicy")
        self.assertEqual(policy["spec"]["egress"], [])
        self.assertIn("Egress", policy["spec"]["policyTypes"])

    def test_job_can_prepare_on_the_server_node_without_entering_service_endpoints(self):
        docs = render({"mode": "gpu", "pipeline": "vlm-small",
                       "modelDownload": {"enabled": True, "preparation": "job"}})
        job = resource(docs, "Job")["spec"]["template"]
        service = resource(docs, "Service")["spec"]["selector"]
        self.assertFalse(all(job["metadata"]["labels"].get(k) == v for k, v in service.items()))
        rule = job["spec"]["affinity"]["podAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"][-1]
        self.assertEqual(rule["topologyKey"], "kubernetes.io/hostname")
        self.assertEqual(rule["labelSelector"]["matchLabels"], service)
        self.assertTrue(job["spec"]["tolerations"])
        init = resource(docs, "Deployment")["spec"]["template"]["spec"]["initContainers"][0]
        self.assertEqual(init["args"][0], "verify")
        self.assertIn("--wait-timeout", init["args"])

    def test_configuration_change_forces_rollout_and_bundle_change(self):
        first = render({"modelDownload": {"enabled": True}})
        second = render({"modelDownload": {"enabled": True, "ensembleModels": ["layout", "tableformer", "rapidocr"]},
                         "env": {"CUSTOM_SWITCH": "changed"}})
        a = resource(first, "Deployment")["spec"]["template"]
        b = resource(second, "Deployment")["spec"]["template"]
        self.assertNotEqual(a["metadata"]["annotations"]["checksum/configuration"],
                            b["metadata"]["annotations"]["checksum/configuration"])
        self.assertNotEqual(a["metadata"]["annotations"]["checksum/model-preparation"],
                            b["metadata"]["annotations"]["checksum/model-preparation"])
        a_env = {e["name"]: e.get("value") for e in a["spec"]["containers"][0]["env"]}
        b_env = {e["name"]: e.get("value") for e in b["spec"]["containers"][0]["env"]}
        self.assertNotEqual(a_env["DOCLING_SERVE_ARTIFACTS_PATH"], b_env["DOCLING_SERVE_ARTIFACTS_PATH"])

    def test_preparation_job_gets_new_name_for_immutable_template_changes(self):
        first = render({"modelDownload": {"enabled": True, "preparation": "job"}})
        second = render({"modelDownload": {"enabled": True, "preparation": "job",
                         "resources": {"cpu": {"limits": {"memory": "5Gi"}}}}})
        self.assertNotEqual(resource(first, "Job")["metadata"]["name"],
                            resource(second, "Job")["metadata"]["name"])
        # Resource tuning does not invalidate an otherwise identical model bundle.
        self.assertEqual(resource(first, "ConfigMap")["data"]["models.json"],
                         resource(second, "ConfigMap")["data"]["models.json"])

    def test_ray_requires_and_renders_an_explicit_cluster_address(self):
        docs = render({"engine": {"kind": "ray", "redisSecret": {"name": "ray-redis"}},
                       "env": {"DOCLING_SERVE_ENG_RAY_ADDRESS": "ray://cluster:10001"}})
        env = {e["name"]: e for e in resource(docs, "Deployment")["spec"]["template"]["spec"]["containers"][0]["env"]}
        self.assertEqual(env["DOCLING_SERVE_ENG_RAY_ADDRESS"]["value"], "ray://cluster:10001")
        self.assertIn("secretKeyRef", env["DOCLING_SERVE_ENG_RAY_REDIS_URL"]["valueFrom"])

    def test_tag_override_requires_clearing_digest_and_propagates_to_preparation(self):
        docs = render({"image": {"tag": "v1.31.0", "cpu": {"digest": ""}},
                       "modelDownload": {"enabled": True}})
        pod = resource(docs, "Deployment")["spec"]["template"]["spec"]
        self.assertTrue(pod["containers"][0]["image"].endswith(":v1.31.0"))
        self.assertEqual(pod["containers"][0]["image"], pod["initContainers"][0]["image"])

    def test_invalid_configurations_fail_before_install(self):
        invalid = [
            {"mode": "bogus"}, {"pipeline": "bogus"}, {"mode": "cpu", "pipeline": "vlm-large"},
            {"pipeline": "vlm-small"}, {"modelSource": "image", "modelDownload": {"enabled": True}},
            {"modelSource": "pvc", "persistence": {"create": False}},
            {"persistence": {"bindToPv": True}},
            {"persistence": {"bindToPv": True, "existingClaim": "models"}},
            {"modelDownload": {"enabled": True}, "persistence": {"accessMode": "ReadOnlyMany"}},
            {"modelDownload": {"enabled": True, "preparation": "job"},
             "persistence": {"accessMode": "ReadWriteOncePod"}},
            {"auth": {"enabled": True}}, {"replicaCount": 2}, {"engine": {"kind": "rq"}},
            {"engine": {"kind": "ray", "redisSecret": {"name": "backend"}}},
            {"modelSource": "pvc", "strategy": {"type": "RollingUpdate"}},
            {"limits": {"maxFileSize": 0}},
            {"image": {"cpu": {"digest": "sha256:short"}}},
            {"env": {"DOCLING_SERVE_ARTIFACTS_PATH": "/other"}},
            {"env": {"EXTRA": "plain"}, "envSecretRefs": {"EXTRA": {"name": "secret", "key": "value"}}},
            {"modelDownload": {"enabled": True, "ensembleModels": ["unknown"]}},
            {"modelDownload": {"enabled": True, "ensembleModels": []}},
            {"modelDownload": {"enabled": True, "revisions": {"vlm-small": "main"}}},
            {"pipeline": "vlm-small", "modelDownload": {"enabled": True,
             "hfRepos": {"vlm-small": "other/model"}}},
        ]
        for values in invalid:
            with self.subTest(values=values):
                render(values, success=False)


def make_model(directory, payload=b"synthetic weights"):
    directory.mkdir(parents=True)
    (directory / "config.json").write_text("{}")
    (directory / "model.safetensors").write_bytes(payload)


def configuration():
    config = {"formatVersion": 1, "image": "fixture@sha256:" + "a" * 64,
              "repositories": [{"repo": "fixture/model", "revision": "b" * 40,
                                "requiredFiles": ["config.json", "model.safetensors"],
                                "sha256": {"model.safetensors": hashlib.sha256(b"synthetic weights").hexdigest()}}]}
    identity = hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()
    return config, identity


def competing_preparer(cache, bundled, staging, counter):
    config, identity = configuration()
    def fetch(model, target):
        with counter.get_lock():
            counter.value += 1
        make_model(target)
    MODELS.prepare(Path(cache), Path(bundled), Path(staging), config, identity, 10, fetch)


def hold_lock(cache, acquired):
    with MODELS.bundle_lock(Path(cache), 10):
        acquired.set()
        multiprocessing.Event().wait(30)


class ModelPublication(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cache = self.root / "cache"
        self.bundled = self.root / "image"
        self.bundled.mkdir()
        self.staging = self.root / "staging"
        self.config, self.identity = configuration()

    def test_config_only_directory_is_not_a_model(self):
        partial = self.bundled / "fixture--model"
        partial.mkdir()
        (partial / "config.json").write_text("{}")
        with self.assertRaises(MODELS.InvalidModel):
            MODELS.validate_model(partial, self.config["repositories"][0])

    def test_warm_cache_never_fetches_models(self):
        make_model(self.bundled / "fixture--model")
        def unexpected_fetch(*args):
            self.fail("Warm/bundled preparation unexpectedly fetched a model")
        first = MODELS.prepare(self.cache, self.bundled, self.staging,
                               self.config, self.identity, 1, unexpected_fetch)
        second = MODELS.prepare(self.cache, self.bundled, self.staging,
                                self.config, self.identity, 1, unexpected_fetch)
        self.assertEqual(first, second)
        self.assertTrue(MODELS.verify_bundle(first, self.config, self.identity))

    def test_corrupt_published_bundle_fails_without_overwriting_evidence(self):
        make_model(self.bundled / "fixture--model")
        final = MODELS.prepare(self.cache, self.bundled, self.staging, self.config, self.identity, 1)
        damaged = final / "fixture--model/model.safetensors"
        damaged.write_bytes(b"corrupt")
        self.assertFalse(MODELS.verify_bundle(final, self.config, self.identity))
        with self.assertRaises(MODELS.InvalidModel):
            MODELS.prepare(self.cache, self.bundled, self.staging, self.config, self.identity, 1)
        self.assertEqual(damaged.read_bytes(), b"corrupt")

    def test_failed_download_cannot_publish_or_damage_previous_bundle(self):
        make_model(self.bundled / "fixture--model")
        final = MODELS.prepare(self.cache, self.bundled, self.staging, self.config, self.identity, 1)
        second = json.loads(json.dumps(self.config))
        second["repositories"].append({"repo": "fixture/missing", "revision": "c" * 40,
                                       "requiredFiles": ["config.json", "model.safetensors"]})
        def fail_download(model, target):
            target.mkdir()
            (target / "config.json").write_text("{}")
            raise OSError("Interrupted fixture download")
        with self.assertRaises(OSError):
            MODELS.prepare(self.cache, self.bundled, self.staging, second, "d" * 64, 1, fail_download)
        self.assertFalse((self.cache / ".bundles" / ("d" * 64)).exists())
        self.assertTrue(MODELS.verify_bundle(final, self.config, self.identity))

    def test_incomplete_old_directory_is_quarantined_before_atomic_publication(self):
        partial = self.cache / ".bundles" / self.identity
        partial.mkdir(parents=True)
        (partial / "partial").write_text("unfinished")
        make_model(self.bundled / "fixture--model")
        final = MODELS.prepare(self.cache, self.bundled, self.staging, self.config, self.identity, 1)
        self.assertTrue(MODELS.verify_bundle(final, self.config, self.identity))
        self.assertEqual(len(list((self.cache / ".incomplete").iterdir())), 1)

    def test_weight_index_requires_all_shards(self):
        directory = self.bundled / "sharded"
        directory.mkdir()
        (directory / "model.safetensors.index.json").write_text(
            json.dumps({"weight_map": {"tensor": "missing.safetensors"}}))
        with self.assertRaises(MODELS.InvalidModel):
            MODELS.validate_model(directory, {"requiredFiles": ["model.safetensors.index.json"]})

    def test_extra_files_and_symlinks_invalidate_published_inventory(self):
        make_model(self.bundled / "fixture--model")
        final = MODELS.prepare(self.cache, self.bundled, self.staging, self.config, self.identity, 1)
        extra = final / "fixture--model/untracked.json"
        extra.write_text("{}")
        self.assertFalse(MODELS.verify_bundle(final, self.config, self.identity))
        extra.unlink()
        extra.symlink_to(self.root / "outside")
        self.assertFalse(MODELS.verify_bundle(final, self.config, self.identity))

    def test_manifest_cannot_read_outside_model_root(self):
        for name in ["../outside", "/outside", "model/../../outside", "model\\outside"]:
            with self.subTest(name=name), self.assertRaises(MODELS.InvalidModel):
                MODELS.safe_path(self.cache, name)

    def test_model_copy_rejects_source_symlinks_before_copying(self):
        source = self.bundled / "fixture--model"
        make_model(source)
        outside = self.root / "outside-secret"
        outside.write_text("must not be copied")
        (source / "unexpected.txt").symlink_to(outside)
        target = self.root / "destination"
        with self.assertRaises(MODELS.InvalidModel):
            MODELS.copy_model(source, target)
        self.assertFalse(target.exists())

    def test_two_preparers_publish_once(self):
        context = multiprocessing.get_context("fork")
        counter = context.Value("i", 0)
        processes = [context.Process(target=competing_preparer,
                     args=(str(self.cache), str(self.bundled), str(self.staging), counter))
                     for _ in range(2)]
        try:
            for process in processes:
                process.start()
            for process in processes:
                process.join(15)
                self.assertEqual(process.exitcode, 0)
            self.assertEqual(counter.value, 1)
            self.assertTrue(MODELS.verify_bundle(self.cache / ".bundles" / self.identity,
                                                self.config, self.identity))
        finally:
            for process in processes:
                if process.is_alive():
                    process.terminate()
                    process.join()

    def test_lock_owner_death_releases_lock_without_deleting_it(self):
        context = multiprocessing.get_context("fork")
        acquired = context.Event()
        owner = context.Process(target=hold_lock, args=(str(self.cache), acquired))
        owner.start()
        try:
            self.assertTrue(acquired.wait(10))
            lock = self.cache / ".model-preparation.lock"
            inode = lock.stat().st_ino
            with self.assertRaises(MODELS.InvalidModel):
                with MODELS.bundle_lock(self.cache, 0.1):
                    self.fail("Acquired a lock still held by another process")
            owner.terminate()
            owner.join(10)
            with MODELS.bundle_lock(self.cache, 1):
                self.assertEqual(lock.stat().st_ino, inode)
        finally:
            if owner.is_alive():
                owner.terminate()
                owner.join()


if __name__ == "__main__":
    unittest.main(verbosity=2)
