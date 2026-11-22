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

"""The geocoding chart: its images are deployed by digest, and the Nominatim API waits for the
database and for Nominatim's import to finish for as long as that takes, never giving up on a clock.

Renders the chart with Helm only, and runs the API's wait script from the rendered Deployment with
stand-ins for pg_isready, psql, sleep and date. Nothing is installed and no container runs.
"""

import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import textwrap
import unittest

import yaml

CHART = Path(__file__).resolve().parents[1] / "charts/geocoding-helm-chart/helm-chart-sources"
PROXY_DIGEST = "sha256:" + "a" * 64
NOMINATIM_DIGEST = "sha256:" + "b" * 64
LIBPOSTAL_DIGEST = "sha256:" + "c" * 64
# A platform installation's shape: an existing credentials Secret, Cloud SQL through the proxy, no
# in-chart database, no import Job.
VALUES = {
    "serviceAccount": {"create": True, "name": "nominatim-runtime"},
    "database": {"createSecret": False, "credentialsSecret": "geocoding-database-credentials"},
    "postgres": {"enabled": False},
    "cloudSqlProxy": {
        "enabled": True,
        "instanceConnectionName": "project:region:instance",
        "image": {"repository": "gcr.io/cloud-sql-connectors/cloud-sql-proxy", "tag": "2.25.3",
                  "digest": PROXY_DIGEST},
    },
    "nominatim": {
        "image": {"repository": "docker.io/forwardmeasure/nominatim", "tag": "0.0.1", "digest": NOMINATIM_DIGEST},
        "api": {"waitForImport": True},
        "import": {"enabled": False},
    },
    "libpostal": {
        "image": {"repository": "docker.io/forwardmeasure/libpostal-service", "tag": "0.0.1",
                  "digest": LIBPOSTAL_DIGEST},
    },
}


def render(values):
    with tempfile.NamedTemporaryFile("w", suffix=".yaml") as file:
        json.dump(values, file)
        file.flush()
        return subprocess.run(["helm", "template", "geocoding", str(CHART), "--namespace", "geocoding",
                               "-f", file.name], capture_output=True, text=True)


def deployments(text):
    return {item["metadata"]["name"]: item for item in yaml.safe_load_all(text)
            if item and item["kind"] == "Deployment"}


def merged(overrides):
    values = json.loads(json.dumps(VALUES))
    for path, value in overrides.items():
        node = values
        *parents, last = path.split(".")
        for key in parents:
            node = node.setdefault(key, {})
        node[last] = value
    return values


def executable(directory, name, body):
    path = Path(directory) / name
    path.write_text("#!/usr/bin/env bash\n" + textwrap.dedent(body))
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class GeocodingChartTest(unittest.TestCase):
    def rendered(self, values=VALUES):
        result = render(values)
        self.assertEqual(0, result.returncode, result.stderr)
        return deployments(result.stdout)

    def wait_container(self, values=VALUES):
        api = self.rendered(values)["geocoding-nominatim"]
        containers = {item["name"]: item for item in api["spec"]["template"]["spec"]["initContainers"]}
        return containers["wait-for-database"]

    def run_wait(self, container, pg_isready_failures, psql_answers):
        """Runs the container's command with stand-ins; psql_answers is one (exit code, stdout, stderr)
        per call, the last repeated. Every date call jumps a week ahead, so any clock in the script
        would expire."""
        command = container["command"]
        self.assertEqual(["/bin/bash", "-c"], command[:2],
                         "the wait is the chart's own script, not one baked into the image")
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as counters:
            state = Path(counters)
            for index, (code, out, err) in enumerate(psql_answers):
                (state / f"answer-{index}.code").write_text(str(code))
                (state / f"answer-{index}.out").write_text(out)
                (state / f"answer-{index}.err").write_text(err)
            last = len(psql_answers) - 1
            executable(directory, "pg_isready", f"""\
                count=$(cat {state}/pg_isready 2>/dev/null || echo 0); echo $((count + 1)) > {state}/pg_isready
                if [ "$count" -lt {pg_isready_failures} ]; then echo "no response" >&2; exit 2; fi
                echo "accepting connections"
                """)
            executable(directory, "psql", f"""\
                count=$(cat {state}/psql 2>/dev/null || echo 0); echo $((count + 1)) > {state}/psql
                index=$(( count < {last} ? count : {last} ))
                cat {state}/answer-$index.out
                cat {state}/answer-$index.err >&2
                exit "$(cat {state}/answer-$index.code)"
                """)
            executable(directory, "sleep", "exit 0\n")
            executable(directory, "date", f"""\
                now=$(cat {state}/date 2>/dev/null || echo 1700000000); echo $((now + 604800)) > {state}/date
                echo "$now"
                """)
            environment = {"PATH": f"{directory}:{os.environ['PATH']}", "PGHOST": "127.0.0.1", "PGPORT": "5432",
                           "PGDATABASE": "nominatim", "PGUSER": "nominatim", "PGPASSWORD": "not-a-secret",
                           "PGMAINTENANCEDATABASE": "postgres"}
            for item in container.get("env") or []:
                environment[item["name"]] = item["value"]
            result = subprocess.run(["bash", "-c", command[2]], env=environment, capture_output=True, text=True,
                                    timeout=60)
            psql_calls = int((state / "psql").read_text()) if (state / "psql").exists() else 0
            return result, psql_calls

    def test_every_image_is_referenced_by_its_digest(self):
        rendered = self.rendered()
        expected = {
            "geocoding-nominatim": {"cloud-sql-proxy": f"gcr.io/cloud-sql-connectors/cloud-sql-proxy@{PROXY_DIGEST}",
                                    "wait-for-database": f"docker.io/forwardmeasure/nominatim@{NOMINATIM_DIGEST}",
                                    "nominatim": f"docker.io/forwardmeasure/nominatim@{NOMINATIM_DIGEST}"},
            "geocoding-libpostal": {"libpostal": f"docker.io/forwardmeasure/libpostal-service@{LIBPOSTAL_DIGEST}"},
        }
        for name, images in expected.items():
            spec = rendered[name]["spec"]["template"]["spec"]
            found = {item["name"]: item["image"] for item in spec.get("initContainers", []) + spec["containers"]}
            self.assertEqual(images, found, name)

    def test_an_image_without_a_digest_is_referenced_by_its_tag(self):
        rendered = self.rendered(merged({"libpostal.image.digest": ""}))
        container = rendered["geocoding-libpostal"]["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual("docker.io/forwardmeasure/libpostal-service:0.0.1", container["image"])

    def test_the_api_waits_for_the_import_however_long_it_takes(self):
        container = self.wait_container()
        self.assertFalse([item["name"] for item in container.get("env") or [] if "TIMEOUT" in item["name"]])
        missing = (1, "", 'ERROR:  relation "nominatim_properties" does not exist\n')
        unfinished = (0, "", "")
        # A hundred checks before the marker appears; each date call has moved a week on.
        answers = [missing] * 60 + [unfinished] * 40 + [(0, "5.3.2-0\n", "")]
        result, calls = self.run_wait(container, pg_isready_failures=3, psql_answers=answers)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(101, calls)
        self.assertIn("5.3.2-0", result.stdout)
        # Each state is reported when it changes, not on every attempt, and with its reason.
        self.assertEqual(1, result.stdout.count('relation "nominatim_properties" does not exist'), result.stdout)
        self.assertEqual(1, result.stdout.count("no response"), result.stdout)

    def test_a_notice_is_not_taken_for_the_import_marker(self):
        notice = (0, "", "NOTICE:  something the server said\n")
        result, calls = self.run_wait(self.wait_container(), pg_isready_failures=0,
                                      psql_answers=[notice, notice, (0, "5.3.2-0\n", "")])
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(3, calls)

    def test_without_waiting_for_the_import_it_waits_only_for_the_server(self):
        container = self.wait_container(merged({"nominatim.api.waitForImport": False}))
        result, calls = self.run_wait(container, pg_isready_failures=2, psql_answers=[(1, "", "unused\n")])
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(0, calls)

    def test_a_wait_timeout_is_refused(self):
        result = render(merged({"nominatim.api.waitTimeoutSeconds": 345600}))
        self.assertNotEqual(0, result.returncode, "a wait timeout was accepted")
        self.assertIn("nominatim.api.waitTimeoutSeconds", result.stderr)


if __name__ == "__main__":
    unittest.main()
