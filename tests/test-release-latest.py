#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "release_latest", Path(__file__).resolve().parents[1] / "scripts/release-latest.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class FakeGitHub:
    def __init__(self, candidate="v2026.10.21.900", published=(), drafts=()):
        self.candidate = candidate
        self.published = set(published)
        self.drafts = set(drafts) | {candidate}
        self.latest = max(published, default=None)
        self.edits = []
        self.on_publish = lambda: None
        self.on_promote = lambda: None
        self.fail_lookup = False
        self.queries = []

    def query(self, args, **kwargs):
        self.queries.append(args)
        if args[1] == "api":
            if self.fail_lookup:
                raise subprocess.CalledProcessError(1, args)
            return "\n".join(sorted(self.published))
        if args[3] == "--json":
            return self.latest or ""
        return json.dumps(dict(tagName=self.candidate, isPrerelease=False,
                               isDraft=self.candidate not in self.published))

    def edit(self, args, **kwargs):
        self.edits.append(args)
        tag = args[3]
        if "--draft=false" in args:
            assert "--latest=false" in args
            self.published.add(tag)
            self.drafts.discard(tag)
            self.on_publish()
        else:
            assert tag in self.published and "--latest=true" in args
            self.latest = tag
            self.on_promote()


class ReleaseLatestTests(unittest.TestCase):
    def publish(self, github):
        with patch.object(release.subprocess, "check_output", side_effect=github.query), \
             patch.object(release.subprocess, "run", side_effect=github.edit):
            return release.publish_and_reconcile(github.candidate[1:], pause=lambda _: None)

    def test_older_retry_promotes_existing_newer_release(self):
        gh = FakeGitHub(published=("v2026.10.22.1000",))
        self.assertEqual(self.publish(gh), "v2026.10.22.1000")
        self.assertEqual(gh.latest, "v2026.10.22.1000")
        self.assertIn("--paginate", next(query for query in gh.queries if query[1] == "api"))

    def test_newer_draft_published_between_preflight_and_publication(self):
        newer = "v2026.10.22.1000"
        gh = FakeGitHub(drafts=(newer,))
        gh.on_publish = lambda: gh.published.add(newer)
        self.assertEqual(self.publish(gh), newer)
        self.assertNotIn(["gh", "release", "edit", gh.candidate, "--latest=true"], gh.edits)

    def test_newer_release_published_between_selection_and_edit(self):
        newer = "v2026.10.22.1000"
        gh = FakeGitHub(drafts=(newer,))
        gh.on_promote = lambda: gh.published.add(newer)
        self.assertEqual(self.publish(gh), newer)
        self.assertEqual(gh.latest, newer)
        self.assertEqual(len(gh.edits), 3)

    def test_draft_does_not_hide_current_stable_release(self):
        gh = FakeGitHub(drafts=("v2026.10.22.1000",))
        self.assertEqual(self.publish(gh), gh.candidate)

    def test_numeric_order_not_lexical_order(self):
        gh = FakeGitHub(candidate="v2026.10.1.1000", published=("v2026.9.30.2359", "v2026.10.1.711"))
        self.assertEqual(self.publish(gh), gh.candidate)

    def test_first_timestamp_release(self):
        for tags in ((), ("v1.2.3",)):
            gh = FakeGitHub(published=tags)
            self.assertEqual(self.publish(gh), gh.candidate)

    def test_preflight_failure_keeps_draft(self):
        gh = FakeGitHub()
        gh.fail_lookup = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish(gh)
        self.assertEqual(gh.edits, [])
        self.assertNotIn(gh.candidate, gh.published)

    def test_resume_after_post_publication_failure(self):
        gh = FakeGitHub(published=("v2026.10.22.1000",))
        gh.on_publish = lambda: setattr(gh, "fail_lookup", True)
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish(gh)
        self.assertIn(gh.candidate, gh.published)
        gh.fail_lookup = False
        self.assertEqual(self.publish(gh), "v2026.10.22.1000")
        self.assertEqual(sum("--draft=false" in args for args in gh.edits), 1)

    def test_latest_verification_detects_interference(self):
        gh = FakeGitHub(published=("v2026.10.20.900",))
        gh.on_promote = lambda: setattr(gh, "latest", "v2026.10.20.900")
        with self.assertRaisesRegex(RuntimeError, "kept changing"):
            self.publish(gh)

    def test_invalid_candidate_rejected(self):
        for version in ("1.2.3", "2026.2.30.1000", "2026.10.22.2460"):
            with self.assertRaises(ValueError):
                release.publish_and_reconcile(version)


if __name__ == "__main__":
    unittest.main()
