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
        "resolution-application.contract.json": '{"$defs": {"input": {"type": "object"}}}',
        "entity-intelligence-api.yaml": "openapi: 3.1.0\n",
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

    def test_a_contract_entry_is_its_text_or_content_and_a_role(self):
        for entry, message in (
                ({"content": "openapi: 3.1.0\n", "role": "RAG"},
                 "contracts.rag-api.yaml.role RAG must be lowercase letters and digits"),
                ({"content": "openapi: 3.1.0\n", "role": "model_openai"},
                 "contracts.rag-api.yaml.role model_openai must be lowercase letters and digits"),
                ({"role": "rag"}, "contracts.rag-api.yaml.content is required"),
                ({"content": "openapi: 3.1.0\n", "rol": "rag"},
                 "contracts.rag-api.yaml has rol: an entry is the file's text, or {content, role}"),
                (["openapi: 3.1.0\n"], "contracts.rag-api.yaml must be the file's text, or {content, role}")):
            error = render(values(CONTRACTS, contracts={"rag-api.yaml": entry}), success=False)
            self.assertIn(message, error)

    def test_the_old_api_documents_key_is_refused(self):
        error = render(values(CONTRACTS, apiDocuments={"a.yaml": "x: 1\n"}), success=False)
        self.assertIn("apiDocuments is renamed contracts", error)

    def test_a_release_with_nothing_to_publish_or_upload_fails_to_render(self):
        error = render(values(CONTRACTS, contracts={}), success=False)
        self.assertIn("definitions or contracts must hold at least one file", error)

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

    def test_a_contracts_release_renders_only_the_upload_job(self):
        docs = render(CONTRACTS)
        self.assertEqual(["fei-workflows-contracts"], sorted(jobs(docs)))
        upload = jobs(docs)["fei-workflows-contracts"]
        variables = env(upload)
        self.assertEqual("upload", variables["OPENWORKFLOW_PUBLISHER_RUN"])
        self.assertEqual("/contracts", variables["OPENWORKFLOW_PUBLISHER_RESOURCES_DIR"])
        self.assertEqual("platform", variables["OPENWORKFLOW_PUBLISHER_REGISTRY_SCOPE"])
        self.assertNotIn("OPENWORKFLOW_PUBLISHER_DEFINITIONS_DIR", variables)
        contracts = next(
            doc for doc in docs
            if doc["kind"] == "ConfigMap" and doc["metadata"]["name"] == "fei-workflows-contracts")
        self.assertEqual(sorted(CONTRACTS["contracts"]), sorted(contracts["data"]))
        # Contract files are not workflows: tenant administration reads labelled ConfigMaps as such.
        self.assertNotIn(
            "openworkflow.forwardmeasure.com/workflow-bundle", contracts["metadata"]["labels"])
        volumes = upload["spec"]["template"]["spec"]["volumes"]
        self.assertIn(
            {"name": "contracts", "configMap": {"name": "fei-workflows-contracts"}}, volumes)

    def test_the_upload_records_the_bundles_did_and_no_roles_unless_declared(self):
        docs = render(CONTRACTS)
        variables = env(jobs(docs)["fei-workflows-contracts"])
        self.assertEqual("fwm", variables["FORWARDMEASURE_DID_METHOD"])
        self.assertNotIn("OPENWORKFLOW_PUBLISHER_CONTRACT_ROLES", variables)
        contracts = next(
            doc for doc in docs
            if doc["kind"] == "ConfigMap" and doc["metadata"]["name"] == "fei-workflows-contracts")
        self.assertNotIn("annotations", contracts["metadata"])

    def test_a_role_the_release_declares_reaches_the_upload_and_the_contracts_config_map(self):
        text = "openapi: 3.1.0\ninfo: {title: RAG, version: 1.0.0}\n"
        rag = values(
            CONTRACTS,
            workflowNamespace="rag",
            contracts={
                "rag-api.yaml": {"content": text, "role": "rag"},
                "rag-common.yaml": "openapi: 3.1.0\n",
            })
        docs = render(rag)
        roles = {"rag-api.yaml": "rag"}
        upload = jobs(docs)["fei-workflows-contracts"]
        self.assertEqual(roles, json.loads(env(upload)["OPENWORKFLOW_PUBLISHER_CONTRACT_ROLES"]))
        contracts = next(
            doc for doc in docs
            if doc["kind"] == "ConfigMap" and doc["metadata"]["name"] == "fei-workflows-contracts")
        self.assertEqual(text, contracts["data"]["rag-api.yaml"], "the file's text, exactly")
        self.assertEqual("openapi: 3.1.0\n", contracts["data"]["rag-common.yaml"])
        self.assertEqual(
            roles,
            json.loads(
                contracts["metadata"]["annotations"]["openworkflow.forwardmeasure.com/contract-roles"]))

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


if __name__ == "__main__":
    unittest.main()
