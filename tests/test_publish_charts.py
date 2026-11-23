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

"""Exercise release dry-run status and file preservation with the real chart and Helm."""

from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PublishChartsTest(unittest.TestCase):
    def snapshot(self):
        index = Path(subprocess.check_output(
            ["git", "rev-parse", "--git-path", "index"], cwd=ROOT, text=True).strip())
        if not index.is_absolute():
            index = ROOT / index
        paths = [index, ROOT / ".git/config", ROOT / "index.yaml",
                 ROOT / "charts/docling-serve-helm-chart/helm-chart-sources/Chart.yaml",
                 ROOT / "charts/docling-serve-helm-chart/helm-chart-sources/values.yaml"]
        return {str(path): path.read_bytes() if path.is_file() else None for path in paths}

    def test_successful_dry_run_returns_zero_without_editing_or_staging(self):
        before = self.snapshot()
        result = subprocess.run(
            [str(ROOT / "publish_charts.sh"), "--chart-name",
             "docling-serve-helm-chart", "--dry-run"],
            cwd=ROOT, capture_output=True, text=True, timeout=60)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("Dry run complete", result.stdout)
        self.assertIn("Would bump Chart.yaml", result.stdout)
        self.assertIn("Would package chart", result.stdout)
        self.assertEqual(before, self.snapshot())

    def test_failed_dry_run_keeps_its_failure_status_and_files(self):
        before = self.snapshot()
        result = subprocess.run(
            [str(ROOT / "publish_charts.sh"), "--chart-name",
             "nonexistent-chart-regression-fixture", "--dry-run"],
            cwd=ROOT, capture_output=True, text=True, timeout=60)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Chart source directory not found", result.stdout)
        self.assertEqual(before, self.snapshot())

    def staged_in_dry_run(self, chart):
        result = subprocess.run([str(ROOT / "publish_charts.sh"), "--chart-name", chart, "--dry-run"],
                                cwd=ROOT, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        listed = result.stdout.split("Only files pertaining to the named charts would be staged:", 1)[1]
        return [line.strip()[2:] for line in listed.splitlines() if line.strip().startswith("- ")]

    def test_a_release_carries_the_charts_own_tests_and_images(self):
        before = self.snapshot()
        staged = self.staged_in_dry_run("geocoding-helm-chart")
        self.assertIn("charts/geocoding-helm-chart/tests", staged)
        self.assertIn("charts/geocoding-helm-chart/images", staged)
        self.assertFalse([path for path in staged if path.startswith("tests/") and "moved into" not in path], staged)
        self.assertEqual(before, self.snapshot())

    def test_a_chart_without_tests_stages_none(self):
        staged = self.staged_in_dry_run("docling-serve-helm-chart")
        self.assertFalse([path for path in staged if "tests" in path], staged)


if __name__ == "__main__":
    unittest.main()
