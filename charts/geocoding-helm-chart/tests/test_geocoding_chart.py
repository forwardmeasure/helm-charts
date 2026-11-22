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

"""The geocoding chart: its images are deployed by digest; the database server, a dependency, is
waited for with bounded exponential back-off taken from values and then fails naming the database;
Nominatim's import, valid work in progress, is waited for as long as it takes; and no retry, back-off
or probe value is written into a template or script.

Renders the chart with Helm only, and runs the API's wait script from the rendered Deployment, and
the image's wait and download scripts, with stand-ins for pg_isready, psql, curl, sleep and date.
Nothing is installed and no container runs.
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

CHART_DIRECTORY = Path(__file__).resolve().parents[1]
CHART = CHART_DIRECTORY / "helm-chart-sources"
IMAGE_SCRIPTS = CHART_DIRECTORY / "images/nominatim/scripts"
ALWAYS = 10**6
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
                               "-f", file.name], stdin=subprocess.DEVNULL, capture_output=True, text=True)


def kinds(text, kind):
    return {item["metadata"]["name"]: item for item in yaml.safe_load_all(text)
            if item and item["kind"] == kind}


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
            executable(directory, "sleep", f'echo "$1" >> {state}/sleeps\n')
            executable(directory, "date", f"""\
                now=$(cat {state}/date 2>/dev/null || echo 1700000000); echo $((now + 604800)) > {state}/date
                echo "$now"
                """)
            environment = {"PATH": f"{directory}:{os.environ['PATH']}", "PGHOST": "127.0.0.1", "PGPORT": "5432",
                           "PGDATABASE": "nominatim", "PGUSER": "nominatim", "PGPASSWORD": "not-a-secret",
                           "PGMAINTENANCEDATABASE": "postgres"}
            for item in container.get("env") or []:
                environment[item["name"]] = item["value"]
            result = subprocess.run(["bash", "-c", command[2]], env=environment, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                    timeout=60)
            psql_calls = int((state / "psql").read_text()) if (state / "psql").exists() else 0
            self.pg_isready_calls = int((state / "pg_isready").read_text()) if (state / "pg_isready").exists() else 0
            self.sleeps = (state / "sleeps").read_text().split() if (state / "sleeps").exists() else []
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
        # No clock on the import wait: the only timeout is one connection attempt's.
        self.assertEqual(["DATABASE_WAIT_CONNECT_TIMEOUT_SECONDS"],
                         [item["name"] for item in container.get("env") or [] if "TIMEOUT" in item["name"]])
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
        # Each attempt at the server is reported with its number (at most databaseWait.attempts).
        self.assertEqual(3, result.stdout.count("no response"), result.stdout)

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


    def test_a_database_that_never_answers_fails_after_the_default_attempts(self):
        result, _ = self.run_wait(self.wait_container(), pg_isready_failures=ALWAYS, psql_answers=[(0, "", "")])
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertEqual(10, self.pg_isready_calls)
        self.assertEqual(["1", "2", "4", "8", "16", "32", "60", "60", "60"], self.sleeps)
        self.assertIn("database nominatim", result.stderr)
        self.assertIn("after 10 attempts", result.stderr)

    def test_every_database_wait_value_comes_from_values(self):
        container = self.wait_container(merged({"nominatim.databaseWait": {
            "attempts": 4, "connectTimeoutSeconds": 7, "initialBackoffSeconds": 5,
            "maximumBackoffSeconds": 40, "backoffMultiplier": 3}}))
        env = {item["name"]: item["value"] for item in container["env"]}
        self.assertEqual("7", env["DATABASE_WAIT_CONNECT_TIMEOUT_SECONDS"])
        result, _ = self.run_wait(container, pg_isready_failures=ALWAYS, psql_answers=[(0, "", "")])
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertEqual(4, self.pg_isready_calls)
        self.assertEqual(["5", "15", "40"], self.sleeps)

    def test_the_server_recovering_within_the_attempts_is_waited_for(self):
        result, _ = self.run_wait(self.wait_container(merged({"nominatim.api.waitForImport": False})),
                                  pg_isready_failures=9, psql_answers=[(0, "", "")])
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(10, self.pg_isready_calls)

    def test_the_import_wait_polls_at_the_configured_interval(self):
        container = self.wait_container(merged({"nominatim.api.importWait": {"pollIntervalSeconds": 45}}))
        result, calls = self.run_wait(container, pg_isready_failures=0,
                                      psql_answers=[(0, "", ""), (0, "", ""), (0, "5.3.2-0\n", "")])
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(3, calls)
        self.assertEqual(["45", "45"], self.sleeps)

    def test_losing_the_server_during_the_import_wait_applies_the_bounded_wait_again(self):
        # The server answers once, then is lost (psql exit 2) and never answers again.
        lost = (2, "", "psql: error: connection to server failed\n")
        result, calls = self._run_wait_up_then_down(self.wait_container(), lost)
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertEqual(1, calls)
        self.assertEqual(11, self.pg_isready_calls)
        self.assertIn("Lost PostgreSQL", result.stdout)
        self.assertIn("after 10 attempts", result.stderr)

    def _run_wait_up_then_down(self, container, psql_answer):
        """pg_isready answers on its first call only; psql always gives psql_answer."""
        command = container["command"]
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as counters:
            state = Path(counters)
            code, out, err = psql_answer
            executable(directory, "pg_isready", f"""\
                count=$(cat {state}/pg_isready 2>/dev/null || echo 0); echo $((count + 1)) > {state}/pg_isready
                if [ "$count" -eq 0 ]; then echo "accepting connections"; exit 0; fi
                echo "no response" >&2; exit 2
                """)
            executable(directory, "psql", f"""\
                count=$(cat {state}/psql 2>/dev/null || echo 0); echo $((count + 1)) > {state}/psql
                printf '%s' {json.dumps(out)}; printf '%s' {json.dumps(err)} >&2; exit {code}
                """)
            executable(directory, "sleep", f'echo "$1" >> {state}/sleeps\n')
            environment = {"PATH": f"{directory}:{os.environ['PATH']}", "PGHOST": "127.0.0.1", "PGPORT": "5432",
                           "PGDATABASE": "nominatim", "PGUSER": "nominatim", "PGPASSWORD": "not-a-secret"}
            for item in container.get("env") or []:
                environment[item["name"]] = item["value"]
            result = subprocess.run(["bash", "-c", command[2]], env=environment, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                    timeout=60)
            self.pg_isready_calls = int((state / "pg_isready").read_text())
            return result, int((state / "psql").read_text()) if (state / "psql").exists() else 0

    def test_invalid_retry_values_are_refused(self):
        for path, value in (("nominatim.databaseWait.attempts", 0),
                            ("nominatim.databaseWait.backoffMultiplier", 1.5),
                            ("nominatim.databaseWait.maximumBackoffSeconds", 0),
                            ("nominatim.import.download.connectTimeoutSeconds", -1),
                            ("nominatim.api.importWait.pollIntervalSeconds", 0),
                            ("postgres.readinessProbe.timeoutSeconds", 0)):
            result = render(merged({path: value}))
            self.assertNotEqual(0, result.returncode, f"{path}={value} was accepted")
            self.assertIn(path.split(".")[-1], result.stderr, path)
        result = render(merged({"nominatim.databaseWait": {"attempts": 3, "connectTimeoutSeconds": 3,
                                                           "initialBackoffSeconds": 10, "maximumBackoffSeconds": 5,
                                                           "backoffMultiplier": 2}}))
        self.assertNotEqual(0, result.returncode, "a maximum back-off below the initial one was accepted")
        self.assertIn("maximumBackoffSeconds", result.stderr)

    def test_the_in_chart_postgres_probes_come_from_values(self):
        probes = {"initialDelaySeconds": 11, "periodSeconds": 12, "timeoutSeconds": 13, "failureThreshold": 14}
        values = merged({"postgres.enabled": True, "database.createSecret": True, "cloudSqlProxy.enabled": False,
                         "postgres.readinessProbe": probes, "postgres.livenessProbe": probes})
        result = render(values)
        self.assertEqual(0, result.returncode, result.stderr)
        container = next(iter(kinds(result.stdout, "StatefulSet").values()))["spec"]["template"]["spec"]["containers"][0]
        for probe in ("readinessProbe", "livenessProbe"):
            self.assertEqual(probes, {key: container[probe][key] for key in probes}, probe)

    def test_the_import_job_gets_its_database_wait_and_download_settings(self):
        values = merged({"nominatim.import.enabled": True,
                         "nominatim.import.download": {"attempts": 3, "connectTimeoutSeconds": 4,
                                                       "initialBackoffSeconds": 5, "maximumBackoffSeconds": 6,
                                                       "backoffMultiplier": 2}})
        result = render(values)
        self.assertEqual(0, result.returncode, result.stderr)
        job = next(iter(kinds(result.stdout, "Job").values()))
        container = next(item for item in job["spec"]["template"]["spec"]["containers"] if item["name"] == "import")
        env = {item["name"]: item.get("value") for item in container["env"]}
        self.assertEqual({"DOWNLOAD_ATTEMPTS": "3", "DOWNLOAD_CONNECT_TIMEOUT_SECONDS": "4",
                          "DOWNLOAD_INITIAL_BACKOFF_SECONDS": "5", "DOWNLOAD_MAXIMUM_BACKOFF_SECONDS": "6",
                          "DOWNLOAD_BACKOFF_MULTIPLIER": "2"},
                         {key: env[key] for key in env if key.startswith("DOWNLOAD_")})
        self.assertEqual("10", env["DATABASE_WAIT_ATTEMPTS"])

    def test_no_retry_or_probe_number_is_written_into_a_template_or_script(self):
        offenders = []
        for path in list((CHART / "templates").glob("*")) + list(IMAGE_SCRIPTS.glob("*.sh")):
            for number, line in enumerate(path.read_text().splitlines(), 1):
                stripped = line.strip()
                if stripped.startswith("#"):
                    continue
                for word in ("sleep ", "--retry", "--retry-delay", "timeoutSeconds:", "periodSeconds:",
                             "failureThreshold:", "initialDelaySeconds:", "backoffLimit:"):
                    if word in stripped and "{{" not in stripped and "${" not in stripped:
                        offenders.append(f"{path.name}:{number}: {stripped}")
        self.assertEqual([], offenders)


class ImageWaitScriptTest(unittest.TestCase):
    def run_script(self, failures, environment_overrides=None):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as counters:
            state = Path(counters)
            executable(directory, "pg_isready", f"""\
                count=$(cat {state}/pg_isready 2>/dev/null || echo 0); echo $((count + 1)) > {state}/pg_isready
                if [ "$count" -lt {failures} ]; then echo "no response" >&2; exit 2; fi
                echo "accepting connections"
                """)
            executable(directory, "sleep", f'echo "$1" >> {state}/sleeps\n')
            environment = {"PATH": f"{directory}:{os.environ['PATH']}", "PGHOST": "db", "PGPORT": "5432",
                           "PGDATABASE": "nominatim", "PGUSER": "nominatim", "DATABASE_WAIT_ATTEMPTS": "3",
                           "DATABASE_WAIT_CONNECT_TIMEOUT_SECONDS": "2", "DATABASE_WAIT_INITIAL_BACKOFF_SECONDS": "2",
                           "DATABASE_WAIT_MAXIMUM_BACKOFF_SECONDS": "3", "DATABASE_WAIT_BACKOFF_MULTIPLIER": "2"}
            environment.update(environment_overrides or {})
            result = subprocess.run(["bash", str(IMAGE_SCRIPTS / "forwardmeasure-wait-for-postgres.sh")],
                                    env=environment, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
            sleeps = (state / "sleeps").read_text().split() if (state / "sleeps").exists() else []
            calls = int((state / "pg_isready").read_text()) if (state / "pg_isready").exists() else 0
            return result, calls, sleeps

    def test_it_fails_after_its_attempts_naming_the_database(self):
        result, calls, sleeps = self.run_script(failures=ALWAYS)
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertEqual(3, calls)
        self.assertEqual(["2", "3"], sleeps)
        self.assertIn("database nominatim", result.stderr)

    def test_it_succeeds_when_the_server_answers_in_time(self):
        result, calls, _ = self.run_script(failures=2)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(3, calls)

    def test_it_refuses_to_run_without_its_settings(self):
        result, calls, _ = self.run_script(failures=0, environment_overrides={"DATABASE_WAIT_ATTEMPTS": ""})
        self.assertNotEqual(0, result.returncode)
        self.assertIn("DATABASE_WAIT_ATTEMPTS", result.stderr)
        self.assertEqual(0, calls)


class ImageDownloadTest(unittest.TestCase):
    def run_download(self, failures):
        script = (IMAGE_SCRIPTS / "forwardmeasure-nominatim-import.sh").read_text()
        start = script.index("download_with_backoff() {")
        end = script.index("\n}\n", start) + 3
        function = script[start:end]
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as counters:
            state = Path(counters)
            executable(directory, "curl", f"""\
                count=$(cat {state}/curl 2>/dev/null || echo 0); echo $((count + 1)) > {state}/curl
                echo "$@" >> {state}/curl-args
                if [ "$count" -lt {failures} ]; then exit 56; fi
                exit 0
                """)
            executable(directory, "sleep", f'echo "$1" >> {state}/sleeps\n')
            environment = {"PATH": f"{directory}:{os.environ['PATH']}", "USER_AGENT": "test",
                           "DOWNLOAD_ATTEMPTS": "4", "DOWNLOAD_CONNECT_TIMEOUT_SECONDS": "9",
                           "DOWNLOAD_INITIAL_BACKOFF_SECONDS": "1", "DOWNLOAD_MAXIMUM_BACKOFF_SECONDS": "3",
                           "DOWNLOAD_BACKOFF_MULTIPLIER": "2"}
            result = subprocess.run(["bash", "-c", "set -euo pipefail\n" + function +
                                     '\ndownload_with_backoff https://example.test/x.osm.pbf "$0"', "/dev/null"],
                                    env=environment, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
            sleeps = (state / "sleeps").read_text().split() if (state / "sleeps").exists() else []
            return result, int((state / "curl").read_text()), sleeps, (state / "curl-args").read_text()

    def test_a_download_that_keeps_failing_fails_after_its_attempts_naming_the_url(self):
        result, calls, sleeps, args = self.run_download(failures=ALWAYS)
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertEqual(4, calls)
        self.assertEqual(["1", "2", "3"], sleeps)
        self.assertIn("https://example.test/x.osm.pbf", result.stderr)
        self.assertIn("--connect-timeout 9", args)
        self.assertIn("--continue-at -", args)

    def test_a_download_that_recovers_within_its_attempts_succeeds(self):
        result, calls, _, _ = self.run_download(failures=2)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(3, calls)


if __name__ == "__main__":
    unittest.main()
