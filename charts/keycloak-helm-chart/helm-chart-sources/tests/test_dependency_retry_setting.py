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

"""The bootstrap Job reads the platform's dependency-retry setting (FORWARDMEASURE_DEPENDENCY_RETRY_*)
with the same defaults and rules as every service, and waits for a user it just created within it.

Runs the real script's functions, its entry point cut off; no Keycloak, no cluster, no container.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).parents[1] / "files/bootstrap-admin.sh"
PREFIX = "FORWARDMEASURE_DEPENDENCY_RETRY_"


def run(driver, **setting):
    with tempfile.TemporaryDirectory() as root:
        sleeps = Path(root) / "sleeps"
        script = SCRIPT.read_text().rsplit('main "$@"', 1)[0] + r'''
sleep() { printf '%s\n' "$1" >> "$SLEEPS"; }
''' + driver
        environment = {key: value for key, value in os.environ.items() if not key.startswith(PREFIX)}
        environment.update({PREFIX + key: value for key, value in setting.items()}, SLEEPS=str(sleeps))
        result = subprocess.run(["sh", "-c", script], env=environment, capture_output=True, text=True,
                                timeout=60)
        return result, sleeps.read_text().split() if sleeps.exists() else []


SHOW = r'''
kc_read_retry_setting
printf '%s %s %s %s %s %s\n' "$KC_RETRY_ATTEMPTS" "$KC_RETRY_INITIAL_SECONDS" "$KC_RETRY_MAXIMUM_SECONDS" \
  "$KC_RETRY_MULTIPLIER" "$KC_RETRY_JITTER" "$KC_CONNECT_TIMEOUT_SECONDS"
'''


class TheSetting(unittest.TestCase):
    def test_unset_is_the_platform_documented_defaults(self):
        result, _ = run(SHOW)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("10 1 60 2 0.2 30", result.stdout.strip())

    def test_every_key_is_read(self):
        result, _ = run(SHOW, ATTEMPTS="4", INITIAL_BACKOFF="PT0.5S", MAXIMUM_BACKOFF="PT1H30M",
                        MULTIPLIER="1.5", JITTER="0", CONNECT_TIMEOUT="P1DT1S")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("4 0.5 5400 1.5 0 86401", result.stdout.strip())

    def test_a_value_the_job_cannot_use_stops_it_naming_the_variable(self):
        for key, value in [("ATTEMPTS", "0"), ("ATTEMPTS", "ten"), ("ATTEMPTS", "-1"),
                           ("INITIAL_BACKOFF", "1s"), ("INITIAL_BACKOFF", "PT"), ("INITIAL_BACKOFF", "-PT1S"),
                           ("MAXIMUM_BACKOFF", "P"), ("MULTIPLIER", "0.5"), ("MULTIPLIER", "two"),
                           ("JITTER", "1.5"), ("JITTER", "-0.1"), ("CONNECT_TIMEOUT", "PT0S")]:
            with self.subTest(key=key, value=value):
                result, _ = run(SHOW + "\nprintf continued\n", **{key: value})
                self.assertNotEqual(0, result.returncode)
                self.assertNotIn("continued", result.stdout)
                self.assertIn(f"ERROR {PREFIX}{key} must be", result.stderr)

    def test_a_maximum_below_the_initial_back_off_is_refused(self):
        result, _ = run(SHOW, INITIAL_BACKOFF="PT10S", MAXIMUM_BACKOFF="PT5S")
        self.assertNotEqual(0, result.returncode)
        self.assertIn(f"ERROR {PREFIX}MAXIMUM_BACKOFF must be at least the initial back-off", result.stderr)

    def test_the_waits_grow_by_the_multiplier_up_to_the_maximum(self):
        result, _ = run(r'''
kc_read_retry_setting
for n in 1 2 3 4 5; do printf '%s\n' "$(kc_retry_wait "$n")"; done
''', INITIAL_BACKOFF="PT1S", MAXIMUM_BACKOFF="PT5S", MULTIPLIER="2", JITTER="0")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(["1.000", "2.000", "4.000", "5.000", "5.000"], result.stdout.split())

    def test_each_wait_is_up_to_the_jitter_of_it_shorter(self):
        result, _ = run(r'''
kc_read_retry_setting
for n in 1 2 3 4 5 6 7 8; do printf '%s\n' "$(kc_retry_wait 4)"; done
''', INITIAL_BACKOFF="PT1S", MAXIMUM_BACKOFF="PT1M", MULTIPLIER="2", JITTER="0.5")
        self.assertEqual(0, result.returncode, result.stderr)
        for wait in map(float, result.stdout.split()):
            self.assertGreaterEqual(wait, 4.0)
            self.assertLessEqual(wait, 8.0)


AWAIT = r'''
lookups=0
lookup() {
  lookups=$((lookups + 1))
  printf '%s\n' "$1" >> "$SLEEPS.lookups"
  [ "$(wc -l < "$SLEEPS.lookups")" -lt "$VISIBLE_AT" ] || printf '%s' "id-of-$1"
}
kc_await_user_id lookup fixture-user
printf 'found %s\n' "$KC_AWAITED_ID"
'''


class AUserJustCreated(unittest.TestCase):
    def test_is_looked_up_again_with_the_setting_back_off_until_keycloak_returns_it(self):
        os.environ["VISIBLE_AT"] = "3"
        self.addCleanup(os.environ.pop, "VISIBLE_AT")
        result, sleeps = run(AWAIT, ATTEMPTS="3", INITIAL_BACKOFF="PT2S", MULTIPLIER="3", JITTER="0")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("found id-of-fixture-user", result.stdout)
        self.assertEqual(["2.000", "6.000"], sleeps)
        self.assertIn("User 'fixture-user' not yet queryable (attempt 2 of 3)", result.stderr)

    def test_ends_the_job_naming_the_user_after_the_last_attempt(self):
        os.environ["VISIBLE_AT"] = "4"
        self.addCleanup(os.environ.pop, "VISIBLE_AT")
        result, sleeps = run(AWAIT, ATTEMPTS="3", INITIAL_BACKOFF="PT0S", MAXIMUM_BACKOFF="PT0S")
        self.assertNotEqual(0, result.returncode)
        self.assertNotIn("found", result.stdout)
        self.assertEqual(2, len(sleeps))
        self.assertIn("ERROR User POST succeeded but 'fixture-user' not found after 3 attempts", result.stderr)


if __name__ == "__main__":
    unittest.main()
