#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "release_latest", Path(__file__).resolve().parents[1] / "scripts/release-latest.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseLatestTests(unittest.TestCase):
    @patch.object(release.subprocess, "check_output")
    def test_older_retry_does_not_replace_newer_release(self, gh):
        gh.return_value = "v2026.10.22.1000\nv2026.10.21.900\n"
        self.assertFalse(release.should_be_latest("2026.10.21.900"))
        self.assertIn("--paginate", gh.call_args.args[0])
        self.assertIn(".[] | select(.draft == false and .prerelease == false) | .tag_name", gh.call_args.args[0])

    @patch.object(release.subprocess, "check_output")
    def test_numeric_order_not_lexical_order(self, gh):
        gh.return_value = "v2026.9.30.2359\nv2026.10.1.711\n"
        self.assertTrue(release.should_be_latest("2026.10.1.1000"))
        gh.return_value = "v2026.10.1.1000\n"
        self.assertFalse(release.should_be_latest("2026.10.1.711"))

    @patch.object(release.subprocess, "check_output")
    def test_first_timestamp_release(self, gh):
        for tags in ("", "v1.2.3\n"):
            gh.return_value = tags
            self.assertTrue(release.should_be_latest("2026.10.22.1000"))

    @patch.object(release.subprocess, "check_output")
    def test_api_failure_does_not_promote_release(self, gh):
        gh.side_effect = subprocess.CalledProcessError(1, "gh")
        with self.assertRaises(subprocess.CalledProcessError):
            release.should_be_latest("2026.10.22.1000")

    def test_invalid_candidate_rejected(self):
        for version in ("1.2.3", "2026.2.30.1000", "2026.10.22.2460"):
            with self.assertRaises(ValueError):
                release.should_be_latest(version)


if __name__ == "__main__":
    unittest.main()
