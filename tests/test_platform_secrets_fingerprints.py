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

"""platform-secrets renders each Secret's content fingerprint onto its ExternalSecret and Secret.

A changed fingerprint changes the ExternalSecret, so External Secrets Operator synchronizes it during
the Helm upgrade; an unchanged one renders byte-identical. Renders the chart with Helm only.
"""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

CHART = Path(__file__).resolve().parents[1] / "charts/platform-secrets-helm-chart/helm-chart-sources"
ANNOTATION = "platform.forwardmeasure.com/credential-fingerprint"
SECRETS = [
    {"name": "composed", "enabled": True, "identityClientCredentials": True, "namespaces": ["ns-a", "ns-b"],
     "templateData": {"CLIENT": "{{ .client }}"}, "remoteRefs": [{"secretKey": "client", "remoteKey": "rc"}]},
    {"name": "copied", "enabled": True, "namespaces": ["ns-a"],
     "remoteRefs": [{"secretKey": "password", "remoteKey": "rp"}]},
]


def render(fingerprints):
    with tempfile.NamedTemporaryFile("w", suffix=".yaml") as values:
        json.dump({"secrets": SECRETS, "credentialFingerprints": fingerprints}, values)
        values.flush()
        return subprocess.run(["helm", "template", "platform-secrets", str(CHART), "-f", values.name],
                              check=True, capture_output=True, text=True).stdout


def external_secrets(text):
    return {(item["metadata"]["namespace"], item["metadata"]["name"]): item
            for item in yaml.safe_load_all(text) if item and item["kind"] == "ExternalSecret"}


class FingerprintTest(unittest.TestCase):
    def test_the_fingerprint_is_on_the_external_secret_and_its_secret(self):
        rendered = external_secrets(render({"ns-a": {"composed": "f1", "copied": "f2"}}))
        for key, fingerprint in ((("ns-a", "composed"), "f1"), (("ns-a", "copied"), "f2")):
            item = rendered[key]
            self.assertEqual(fingerprint, item["metadata"]["annotations"][ANNOTATION])
            self.assertEqual(fingerprint, item["spec"]["target"]["template"]["metadata"]["annotations"][ANNOTATION])
        # A template with metadata only, for a Secret copied as is: its data stays spec.data.
        self.assertNotIn("data", rendered[("ns-a", "copied")]["spec"]["target"]["template"])
        self.assertEqual({"CLIENT": "{{ .client }}"},
                         rendered[("ns-a", "composed")]["spec"]["target"]["template"]["data"])

    def test_a_secret_without_a_fingerprint_renders_as_before(self):
        rendered = external_secrets(render({"ns-a": {"composed": "f1"}}))
        for key in (("ns-b", "composed"), ("ns-a", "copied")):
            self.assertNotIn("annotations", rendered[key]["metadata"])
        self.assertNotIn("template", rendered[("ns-a", "copied")]["spec"]["target"])
        self.assertNotIn("metadata", rendered[("ns-b", "composed")]["spec"]["target"]["template"])

    def test_the_same_fingerprints_render_byte_identical_and_a_change_touches_only_its_secret(self):
        first = {"ns-a": {"composed": "f1", "copied": "f2"}, "ns-b": {"composed": "f3"}}
        self.assertEqual(render(first), render(json.loads(json.dumps(first))))
        before = external_secrets(render(first))
        after = external_secrets(render({**first, "ns-a": {"composed": "f1", "copied": "f2-rotated"}}))
        self.assertEqual({("ns-a", "copied")}, {key for key in before if before[key] != after[key]})


if __name__ == "__main__":
    unittest.main()
