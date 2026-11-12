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

WORKFLOWS = {
    "workflowNamespace": "entity-intelligence",
    "scope": "platform",
    "didMethod": "fwm",
    "definitions": {"resolution-application.yaml": DEFINITION},
    "contractBundles": {"selfsame": {"workflowNamespace": "selfsame", "scope": "platform"}},
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
    "fowf": WORKFLOWS["fowf"],
    "registry": WORKFLOWS["registry"],
    "image": WORKFLOWS["image"],
}


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


if __name__ == "__main__":
    unittest.main()
