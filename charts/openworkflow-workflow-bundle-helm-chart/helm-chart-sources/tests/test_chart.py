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

"""Template tests of the workflow bundle chart (contract bundling, chart 0.3.0); no cluster."""

import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

CHART = Path(__file__).resolve().parents[1]

DEFINITION = """\
document: {dsl: '1.0.3', namespace: "@WORKFLOW_NAMESPACE@", name: resolution-application, version: '1.3.0'}
input:
  schema:
    resource:
      endpoint: "@BUNDLE_DID@/resolution-application.contract.json#/$defs/input"
do:
  - run:
      call: openapi
      with:
        document:
          endpoint: "@BUNDLE_DID:selfsame@/selfsame.openapi.yaml"
        operationId: getResolutionRun
"""

# The shared platform.contractDigests: every workflow namespace's contracts image digest.
DIGESTS = {
    "entity-intelligence": "sha256:" + "c" * 64,
    "selfsame": "sha256:" + "d" * 64,
    "indexical": "sha256:" + "e" * 64,
    "platform-contracts": "sha256:" + "f" * 64,
}

WORKFLOWS = {
    "workflowNamespace": "entity-intelligence",
    "scope": "platform",
    "didMethod": "fwm",
    "definitions": {"resolution-application.yaml": DEFINITION},
    "contractBundles": {"selfsame": {"workflowNamespace": "selfsame", "scope": "platform"}},
    "contractDigests": DIGESTS,
    "tenants": ["acme"],
    "fowf": {
        "definitionBaseUrl": "http://openworkflow-definition-management.openworkflow.svc",
        "keycloakTokenUrl": "https://keycloak.example/realms/platform/protocol/openid-connect/token",
    },
    "registry": {"apiUrl": "http://apicurio.registry.svc/apis/registry/v3"},
    "image": {"digest": "sha256:" + "a" * 64},
}

CONTRACTS = {
    "workflowNamespace": "entity-intelligence",
    "scope": "platform",
    "didMethod": "fwm",
    "contracts": {
        "repository": "docker.io/forwardmeasure/entity-intelligence-contracts",
        "digest": "sha256:" + "b" * 64,
    },
    "contractDigests": DIGESTS,
    "fowf": WORKFLOWS["fowf"],
    "registry": WORKFLOWS["registry"],
    "image": WORKFLOWS["image"],
}

CONTRACT_DIGESTS = "openworkflow.forwardmeasure.com/contract-digests"


def values(base, **changes):
    result = copy.deepcopy(base)
    for key, value in changes.items():
        if value is None:
            result.pop(key, None)
        else:
            result[key] = value
    return result


def render(chart_values, success=True):
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "values.yaml"
        path.write_text(yaml.safe_dump(chart_values))
        result = subprocess.run(
            ["helm", "template", "fei", str(CHART), "-n", "openworkflow", "-f", str(path)],
            text=True, capture_output=True)
    if not success:
        if result.returncode == 0:
            raise AssertionError("Invalid values rendered successfully")
        return result.stderr
    if result.returncode:
        raise AssertionError(result.stderr)
    return [doc for doc in yaml.safe_load_all(result.stdout) if doc]


def jobs(docs):
    return {doc["metadata"]["name"]: doc for doc in docs if doc["kind"] == "Job"}


def pod_annotations(job):
    return job["spec"]["template"]["metadata"].get("annotations", {})


def env(job):
    container = job["spec"]["template"]["spec"]["containers"][0]
    return {entry["name"]: entry.get("value") for entry in container["env"]}


class Refusals(unittest.TestCase):
    def test_an_undeclared_alias_fails_to_render(self):
        error = render(values(WORKFLOWS, contractBundles={}), success=False)
        self.assertIn(
            'definition resolution-application.yaml uses @BUNDLE_DID:selfsame@, but '
            'contractBundles declares no alias "selfsame"', error)

    def test_contract_bundles_is_required_with_definitions(self):
        error = render(values(WORKFLOWS, contractBundles=None), success=False)
        self.assertIn("contractBundles is required with definitions", error)

    def test_an_alias_needs_its_bundles_namespace_and_scope(self):
        error = render(
            values(WORKFLOWS, contractBundles={"selfsame": {"workflowNamespace": "selfsame"}}),
            success=False)
        self.assertIn("contractBundles.selfsame.scope is required", error)
        error = render(
            values(WORKFLOWS, contractBundles={"selfsame": {"scope": "platform"}}), success=False)
        self.assertIn("contractBundles.selfsame.workflowNamespace is required", error)

    def test_a_missing_scope_fails_to_render(self):
        for base in (WORKFLOWS, CONTRACTS):
            error = render(values(base, scope=None), success=False)
            self.assertIn("scope is required: platform", error)

    def test_a_missing_did_method_fails_to_render(self):
        error = render(values(WORKFLOWS, didMethod=None), success=False)
        self.assertIn("didMethod is required: definition resolution-application.yaml", error)
        # An alias alone needs the DID method too.
        aliased = values(
            WORKFLOWS,
            didMethod=None,
            definitions={"x.yaml": "endpoint: '@BUNDLE_DID:selfsame@/selfsame.openapi.yaml'\n"})
        self.assertIn("didMethod is required: definition x.yaml", render(aliased, success=False))

    def test_contracts_need_the_did_method(self):
        error = render(values(CONTRACTS, didMethod=None), success=False)
        self.assertIn(
            "didMethod is required when contracts are given: every uploaded version records its"
            " bundle's DID", error)

    def test_a_declared_role_names_a_contract_file_and_is_a_role(self):
        for roles, message in (
                ({"rag-api.yaml": "RAG"},
                 "contracts.roles.rag-api.yaml RAG must be lowercase letters and digits"),
                ({"rag-api.yaml": "model_openai"},
                 "contracts.roles.rag-api.yaml model_openai must be lowercase letters and digits"),
                ({"rag api": "rag"},
                 "contracts.roles key rag api must be a contract file's name"),
                (["rag"], "contracts.roles must map a contract file's name to its role")):
            with self.subTest(roles=roles):
                image = dict(CONTRACTS["contracts"], roles=roles)
                error = render(values(CONTRACTS, contracts=image), success=False)
                self.assertIn(message, error)

    def test_the_old_api_documents_key_is_refused(self):
        error = render(values(CONTRACTS, apiDocuments={"a.yaml": "x: 1\n"}), success=False)
        self.assertIn("apiDocuments is renamed contracts", error)

    def test_a_release_with_nothing_to_publish_or_upload_fails_to_render(self):
        error = render(values(CONTRACTS, contracts={}), success=False)
        self.assertIn("definitions or contracts must be given", error)

    def test_a_contracts_image_without_a_digest_fails_to_render(self):
        for digest in (None, "", "latest", "sha256:" + "B" * 64, "sha256:" + "b" * 63):
            with self.subTest(digest=digest):
                image = {"repository": CONTRACTS["contracts"]["repository"]}
                if digest is not None:
                    image["digest"] = digest
                error = render(values(CONTRACTS, contracts=image), success=False)
                self.assertIn(
                    "contracts.digest is required: the contracts image "
                    "docker.io/forwardmeasure/entity-intelligence-contracts by its sha256 digest", error)

    def test_a_contracts_image_without_a_repository_fails_to_render(self):
        error = render(values(CONTRACTS, contracts={"digest": "sha256:" + "b" * 64}), success=False)
        self.assertIn("contracts.repository is required", error)

    def test_contract_file_contents_in_the_release_are_refused(self):
        error = render(
            values(CONTRACTS, contracts={"entity-intelligence-api.yaml": "openapi: 3.1.0\n"}),
            success=False)
        self.assertIn(
            "contracts.entity-intelligence-api.yaml: contracts is the bundle's contracts image, "
            "{repository, digest, roles}; contract files no longer travel inside the release", error)

    def test_contracts_need_the_registry(self):
        error = render(values(CONTRACTS, registry={"apiUrl": ""}), success=False)
        self.assertIn("registry.apiUrl is required when contracts are given", error)
        error = render(values(WORKFLOWS, registry={"apiUrl": ""}), success=False)
        self.assertIn("registry.apiUrl is required when definitions name bundle contracts", error)


class Jobs(unittest.TestCase):
    def test_a_workflows_release_renders_only_the_publish_job(self):
        docs = render(WORKFLOWS)
        self.assertEqual(["fei-workflows"], sorted(jobs(docs)))
        publish = jobs(docs)["fei-workflows"]
        variables = env(publish)
        self.assertEqual("publish", variables["OPENWORKFLOW_PUBLISHER_RUN"])
        self.assertEqual(
            {"selfsame": {"workflowNamespace": "selfsame", "scope": "platform"}},
            json.loads(variables["OPENWORKFLOW_PUBLISHER_CONTRACT_BUNDLES"]))
        self.assertEqual(
            "http://apicurio.registry.svc/apis/registry/v3",
            variables["OPENWORKFLOW_PUBLISHER_REGISTRY_URL"])
        self.assertNotIn("OPENWORKFLOW_PUBLISHER_RESOURCES_DIR", variables)
        config_maps = sorted(doc["metadata"]["name"] for doc in docs if doc["kind"] == "ConfigMap")
        self.assertEqual(["fei-workflows"], config_maps)

    def test_an_empty_alias_map_is_a_stated_choice(self):
        own = values(
            WORKFLOWS,
            contractBundles={},
            definitions={"own.yaml": "endpoint: '@BUNDLE_DID@/own.contract.json'\n"})
        self.assertEqual(["fei-workflows"], sorted(jobs(render(own))))

    def test_the_definitions_configmap_carries_the_declared_bundles(self):
        declared = values(
            WORKFLOWS,
            contractBundles={"selfsame": {"workflowNamespace": "selfsame", "scope": "platform"}},
            definitions={"own.yaml": "endpoint: '@BUNDLE_DID:selfsame@/selfsame.openapi.yaml'\n"})
        definitions = next(
            doc for doc in render(declared)
            if doc["kind"] == "ConfigMap" and doc["metadata"]["name"] == "fei-workflows")
        self.assertEqual(
            {"selfsame": {"workflowNamespace": "selfsame", "scope": "platform"}},
            json.loads(
                definitions["metadata"]["annotations"]["openworkflow.forwardmeasure.com/contract-bundles"]))

    def test_the_upload_job_declares_the_bundles_its_contract_files_reference(self):
        declared = dict(
            CONTRACTS,
            contractBundles={"platform": {"workflowNamespace": "platform-contracts", "scope": "platform"}})
        variables = env(jobs(render(declared))["fei-workflows-contracts"])
        self.assertEqual(
            {"platform": {"workflowNamespace": "platform-contracts", "scope": "platform"}},
            json.loads(variables["OPENWORKFLOW_PUBLISHER_CONTRACT_BUNDLES"]))
        self.assertNotIn(
            "OPENWORKFLOW_PUBLISHER_CONTRACT_BUNDLES",
            env(jobs(render(CONTRACTS))["fei-workflows-contracts"]))

    def test_a_contracts_release_renders_only_the_upload_job(self):
        docs = render(CONTRACTS)
        self.assertEqual(["fei-workflows-contracts"], sorted(jobs(docs)))
        upload = jobs(docs)["fei-workflows-contracts"]
        variables = env(upload)
        self.assertEqual("upload", variables["OPENWORKFLOW_PUBLISHER_RUN"])
        self.assertEqual("/contracts", variables["OPENWORKFLOW_PUBLISHER_RESOURCES_DIR"])
        self.assertEqual("platform", variables["OPENWORKFLOW_PUBLISHER_REGISTRY_SCOPE"])
        self.assertNotIn("OPENWORKFLOW_PUBLISHER_DEFINITIONS_DIR", variables)
        # A platform bundle's group needs no tenant id, so no definition management.
        self.assertNotIn("OPENWORKFLOW_PUBLISHER_DEFINITION_BASE_URL", variables)

    def test_a_contracts_release_copies_its_contracts_image_and_renders_no_configmap_of_files(self):
        docs = render(CONTRACTS)
        # No contract file travels in the release: no ConfigMap at all for a contracts-only release.
        self.assertEqual([], [doc["metadata"]["name"] for doc in docs if doc["kind"] == "ConfigMap"])
        pod = jobs(docs)["fei-workflows-contracts"]["spec"]["template"]["spec"]
        [copier] = pod["initContainers"]
        self.assertEqual(
            "docker.io/forwardmeasure/entity-intelligence-contracts@sha256:" + "b" * 64,
            copier["image"])
        self.assertEqual(["cp", "-R", "/contracts/.", "/bundle-contracts/"], copier["command"])
        self.assertEqual([{"name": "contracts", "mountPath": "/bundle-contracts"}], copier["volumeMounts"])
        self.assertEqual(
            {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
             "capabilities": {"drop": ["ALL"]}},
            copier["securityContext"])
        [upload] = pod["containers"]
        self.assertIn(
            {"name": "contracts", "mountPath": "/contracts", "readOnly": True}, upload["volumeMounts"])
        self.assertIn({"name": "contracts", "emptyDir": {}}, pod["volumes"])
        self.assertNotIn("configMap", json.dumps(pod["volumes"]))

    def test_a_workflows_release_renders_no_contracts_copier(self):
        pod = jobs(render(WORKFLOWS))["fei-workflows"]["spec"]["template"]["spec"]
        self.assertNotIn("initContainers", pod)

    def test_the_upload_records_the_bundles_did_and_no_roles_unless_declared(self):
        docs = render(CONTRACTS)
        variables = env(jobs(docs)["fei-workflows-contracts"])
        self.assertEqual("fwm", variables["FORWARDMEASURE_DID_METHOD"])
        self.assertNotIn("OPENWORKFLOW_PUBLISHER_CONTRACT_ROLES", variables)

    def test_a_role_the_release_declares_reaches_the_upload(self):
        roles = {"rag-api.yaml": "rag"}
        rag = values(
            CONTRACTS,
            workflowNamespace="rag",
            contracts=dict(CONTRACTS["contracts"], roles=roles))
        upload = jobs(render(rag))["fei-workflows-contracts"]
        self.assertEqual(roles, json.loads(env(upload)["OPENWORKFLOW_PUBLISHER_CONTRACT_ROLES"]))

    def test_a_release_with_both_uploads_before_it_publishes(self):
        both = values(WORKFLOWS, contracts=CONTRACTS["contracts"])
        rendered = jobs(render(both))
        self.assertEqual(["fei-workflows", "fei-workflows-contracts"], sorted(rendered))
        weight = lambda job: int(job["metadata"]["annotations"]["helm.sh/hook-weight"])
        self.assertLess(weight(rendered["fei-workflows-contracts"]), weight(rendered["fei-workflows"]))

    def test_tenant_scoped_contracts_need_and_carry_their_tenants(self):
        tenant = values(CONTRACTS, scope="tenant")
        self.assertIn("tenants must list at least one tenant alias", render(tenant, success=False))
        tenant["tenants"] = ["acme", "globex"]
        upload = jobs(render(tenant))["fei-workflows-contracts"]
        self.assertEqual("acme,globex", env(upload)["OPENWORKFLOW_PUBLISHER_TENANTS"])
        # Each tenant's id, for its own group, comes from definition management.
        self.assertEqual(
            WORKFLOWS["fowf"]["definitionBaseUrl"],
            env(upload)["OPENWORKFLOW_PUBLISHER_DEFINITION_BASE_URL"])
        no_definitions = dict(tenant, fowf={"keycloakTokenUrl": WORKFLOWS["fowf"]["keycloakTokenUrl"]})
        self.assertIn(
            "fowf.definitionBaseUrl is required with scope tenant",
            render(no_definitions, success=False))


class ContractDigests(unittest.TestCase):
    """Each Job carries the contracts image digest of every bundle its release names, and its own
    bundle's when its definitions name them (@BUNDLE_DID@), so new contracts of either change the
    release's render and the installer re-syncs it."""

    BOTH = {"selfsame": {"workflowNamespace": "selfsame", "scope": "platform"},
            "indexical": {"workflowNamespace": "indexical", "scope": "platform"}}

    def test_the_publish_job_carries_the_digest_of_each_named_bundle(self):
        publish = jobs(render(values(WORKFLOWS, contractBundles=self.BOTH)))["fei-workflows"]
        # WORKFLOWS' definition names its own bundle's contracts too (@BUNDLE_DID@): under @self.
        self.assertEqual(
            {"@self": DIGESTS["entity-intelligence"], "indexical": DIGESTS["indexical"],
             "selfsame": DIGESTS["selfsame"]},
            json.loads(pod_annotations(publish)[CONTRACT_DIGESTS]))
        # In a stable order, key by key.
        self.assertEqual(
            '{"@self":"%s","indexical":"%s","selfsame":"%s"}'
            % (DIGESTS["entity-intelligence"], DIGESTS["indexical"], DIGESTS["selfsame"]),
            pod_annotations(publish)[CONTRACT_DIGESTS])
        # The publisher's own view of the bundles is unchanged: no digest in it.
        self.assertEqual(
            self.BOTH, json.loads(env(publish)["OPENWORKFLOW_PUBLISHER_CONTRACT_BUNDLES"]))

    def test_the_upload_job_carries_the_digest_of_each_bundle_its_files_reference(self):
        declared = values(
            CONTRACTS,
            contractBundles={"platform": {"workflowNamespace": "platform-contracts", "scope": "platform"}})
        upload = jobs(render(declared))["fei-workflows-contracts"]
        self.assertEqual(
            {"platform": DIGESTS["platform-contracts"]},
            json.loads(pod_annotations(upload)[CONTRACT_DIGESTS]))

    def test_a_release_naming_no_bundles_contracts_carries_no_digests(self):
        plain = values(
            WORKFLOWS,
            contractBundles={},
            definitions={"plain.yaml": "endpoint: 'https://example.test/plain.yaml'\n"})
        self.assertNotIn(CONTRACT_DIGESTS, pod_annotations(jobs(render(plain))["fei-workflows"]))
        self.assertNotIn(
            CONTRACT_DIGESTS, pod_annotations(jobs(render(CONTRACTS))["fei-workflows-contracts"]))

    def test_a_named_bundles_new_digest_changes_the_render(self):
        changed = dict(DIGESTS, selfsame="sha256:" + "1" * 64)
        self.assertNotEqual(render(WORKFLOWS), render(values(WORKFLOWS, contractDigests=changed)))
        declared = values(
            CONTRACTS,
            contractBundles={"platform": {"workflowNamespace": "platform-contracts", "scope": "platform"}})
        changed = dict(DIGESTS, **{"platform-contracts": "sha256:" + "1" * 64})
        self.assertNotEqual(render(declared), render(values(declared, contractDigests=changed)))

    def test_another_bundles_new_digest_leaves_the_render_unchanged(self):
        # WORKFLOWS names only selfsame's and its own: Indexical's new contracts change nothing.
        changed = dict(DIGESTS, indexical="sha256:" + "1" * 64)
        self.assertEqual(render(WORKFLOWS), render(values(WORKFLOWS, contractDigests=changed)))
        # A contracts-only release follows no own digest here: its own image is contracts.digest.
        changed = dict(changed, **{"entity-intelligence": "sha256:" + "2" * 64})
        self.assertEqual(render(CONTRACTS), render(values(CONTRACTS, contractDigests=changed)))
        self.assertNotIn(
            CONTRACT_DIGESTS, pod_annotations(jobs(render(CONTRACTS))["fei-workflows-contracts"]))

    def test_its_own_contracts_new_digest_changes_a_bundle_that_names_them(self):
        own = values(
            WORKFLOWS,
            contractBundles={},
            definitions={"own.yaml": "endpoint: '@BUNDLE_DID@/own.contract.json'\n"})
        publish = jobs(render(own))["fei-workflows"]
        self.assertEqual(
            {"@self": DIGESTS["entity-intelligence"]},
            json.loads(pod_annotations(publish)[CONTRACT_DIGESTS]))
        changed = dict(DIGESTS, **{"entity-intelligence": "sha256:" + "2" * 64})
        self.assertNotEqual(render(own), render(values(own, contractDigests=changed)))

    def test_its_own_contracts_new_digest_leaves_a_bundle_that_names_none_unchanged(self):
        aliased = values(
            WORKFLOWS,
            definitions={"x.yaml": "endpoint: '@BUNDLE_DID:selfsame@/selfsame.openapi.yaml'\n"})
        self.assertEqual(
            {"selfsame": DIGESTS["selfsame"]},
            json.loads(pod_annotations(jobs(render(aliased))["fei-workflows"])[CONTRACT_DIGESTS]))
        changed = dict(DIGESTS, **{"entity-intelligence": "sha256:" + "2" * 64})
        self.assertEqual(render(aliased), render(values(aliased, contractDigests=changed)))

    def test_a_bundle_naming_its_own_contracts_needs_its_own_digest(self):
        missing = {key: value for key, value in DIGESTS.items() if key != "entity-intelligence"}
        error = render(values(WORKFLOWS, contractDigests=missing), success=False)
        self.assertIn(
            'contractDigests has no digest for workflow namespace "entity-intelligence", this bundle\'s'
            ' own, whose contracts its definitions name (@BUNDLE_DID@)', error)
        for digest in ("", "latest", "sha256:" + "C" * 64):
            with self.subTest(digest=digest):
                error = render(
                    values(WORKFLOWS, contractDigests=dict(DIGESTS, **{"entity-intelligence": digest})),
                    success=False)
                self.assertIn(
                    "contractDigests.entity-intelligence is required: the contracts image of this bundle,"
                    " whose contracts its definitions name (@BUNDLE_DID@), by its sha256 digest", error)

    def test_a_named_bundle_whose_namespace_has_no_digest_fails_to_render(self):
        missing = {key: value for key, value in DIGESTS.items() if key != "selfsame"}
        error = render(values(WORKFLOWS, contractDigests=missing), success=False)
        self.assertIn(
            'contractDigests has no digest for workflow namespace "selfsame", which '
            'contractBundles.selfsame names', error)
        declared = values(
            CONTRACTS,
            contractBundles={"platform": {"workflowNamespace": "platform", "scope": "platform"}})
        error = render(declared, success=False)
        self.assertIn(
            'contractDigests has no digest for workflow namespace "platform", which '
            'contractBundles.platform names', error)

    def test_a_named_bundle_without_a_sha256_digest_fails_to_render(self):
        for digest in ("", "latest", "sha256:" + "D" * 64, "sha256:" + "d" * 63):
            with self.subTest(digest=digest):
                error = render(values(WORKFLOWS, contractDigests=dict(DIGESTS, selfsame=digest)), success=False)
                self.assertIn(
                    "contractDigests.selfsame is required: the contracts image of the bundle "
                    "contractBundles.selfsame names, by its sha256 digest", error)
        # An unnamed bundle's empty pin is not this release's concern.
        self.assertTrue(render(values(WORKFLOWS, contractDigests=dict(DIGESTS, indexical=""))))

    def test_contract_digests_is_required(self):
        for base in (WORKFLOWS, CONTRACTS):
            for digests in (None, {}, ["sha256:" + "c" * 64]):
                with self.subTest(release="workflows" if base is WORKFLOWS else "contracts", digests=digests):
                    error = render(values(base, contractDigests=digests), success=False)
                    self.assertIn("contractDigests is required: every workflow namespace's contracts"
                                  " image digest", error)


if __name__ == "__main__":
    unittest.main()
