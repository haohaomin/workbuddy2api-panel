#!/usr/bin/env python3
"""Exercise tag reservation against a real local Git remote, without GitHub."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "release_version", Path(__file__).resolve().parents[1] / "scripts/release-version.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseVersionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.previous = Path.cwd()
        root = Path(self.directory.name)
        subprocess.run(["git", "init", "--bare", str(root / "remote.git")],
                       check=True, capture_output=True)
        (root / "work").mkdir()
        os.chdir(root / "work")
        release.git("init", "-b", "main")
        release.git("config", "user.name", "Release Test")
        release.git("config", "user.email", "test@example.invalid")
        release.git("remote", "add", "origin", str(root / "remote.git"))
        release.git("commit", "--allow-empty", "-m", "first")
        self.first = release.git("rev-parse", "HEAD")
        release.git("commit", "--allow-empty", "-m", "second")
        self.second = release.git("rev-parse", "HEAD")
        release.git("push", "origin", "main")

    def tearDown(self):
        os.chdir(self.previous)
        self.directory.cleanup()

    def test_exact_build_commit_and_rerun(self):
        value = release.resolve("refs/heads/main", self.first, now=lambda: "2026.10.20.711")
        self.assertEqual(value, "2026.10.20.711")
        self.assertTrue(release.git("ls-remote", "origin", "refs/tags/v" + value).startswith(self.first))
        self.assertEqual(release.resolve("refs/heads/main", self.first,
                                        now=lambda: "2026.10.20.712"), value)

    def test_collision_waits_without_overwriting(self):
        release.git("tag", "v2026.10.20.711", self.first)
        release.git("push", "origin", "v2026.10.20.711")
        times = iter(["2026.10.20.711", "2026.10.20.712"])
        waits = []
        value = release.resolve("refs/heads/main", self.second,
                                now=lambda: next(times), pause=waits.append)
        self.assertEqual(value, "2026.10.20.712")
        self.assertEqual(waits, [10])
        self.assertEqual(release.git("rev-parse", "v2026.10.20.711"), self.first)

    def test_manual_tag_and_preview_do_not_create_tags(self):
        self.assertEqual(release.resolve("refs/tags/v2026.10.20.711", self.first), "2026.10.20.711")
        self.assertEqual(release.resolve("refs/heads/feature", self.first,
                                        now=lambda: "2026.10.20.712"), "2026.10.20.712")
        self.assertEqual(release.git("ls-remote", "--tags", "origin"), "")
        with self.assertRaises(ValueError):
            release.resolve("refs/tags/v1.2.3", self.first)

    def test_push_failure_does_not_return_a_version(self):
        remote = Path(release.git("remote", "get-url", "origin"))
        hook = remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        with self.assertRaisesRegex(RuntimeError, "Could not push"):
            release.resolve("refs/heads/main", self.first, now=lambda: "2026.10.20.711")


if __name__ == "__main__":
    unittest.main()
