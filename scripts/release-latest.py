#!/usr/bin/env python3
"""Publish without promotion, then reconcile Latest under binaries-release lock."""
from datetime import datetime
import json
import re
import subprocess
import sys
import time


def version_key(tag):
    if not re.fullmatch(r"v\d{4}\.\d{1,2}\.\d{1,2}\.\d{3,4}", tag):
        return None
    year, month, day, clock = map(int, tag[1:].split("."))
    try:
        return datetime(year, month, day, clock // 100, clock % 100)
    except ValueError:
        return None


def published_tags():
    # API errors propagate; a failed lookup must never authorize promotion.
    return subprocess.check_output([
        "gh", "api", "--paginate", "repos/{owner}/{repo}/releases?per_page=100",
        "--jq", ".[] | select(.draft == false and .prerelease == false) | .tag_name",
    ], text=True).splitlines()


def newest_tag(tags):
    timestamps = [(key, tag) for tag in tags if (key := version_key(tag)) is not None]
    if not timestamps:
        raise RuntimeError("No published timestamp release found")
    return max(timestamps)[1]


def publish_and_reconcile(version, pause=time.sleep):
    tag = "v" + version
    if version_key(tag) is None:
        raise ValueError("Invalid timestamp release version")
    candidate = json.loads(subprocess.check_output([
        "gh", "release", "view", tag, "--json", "tagName,isDraft,isPrerelease",
    ], text=True))
    if candidate["tagName"] != tag or candidate["isPrerelease"]:
        raise ValueError("Expected a stable release with the requested timestamp")
    published_tags()  # Preflight: leave a draft untouched if the API is unavailable.
    if candidate["isDraft"]:
        subprocess.run(["gh", "release", "edit", tag, "--draft=false", "--latest=false"], check=True)

    # All repository publishers must use the workflow's binaries-release group.
    # Re-read AFTER publishing, and promote the highest published timestamp,
    # which may be another release. Recheck after editing to reconcile an
    # out-of-band publication during the API calls instead of trusting a boolean
    # calculated while that release was still a draft.
    for attempt in range(5):
        tags = published_tags()
        if tag not in tags:
            raise RuntimeError("Published candidate is missing; rerun to reconcile Latest")
        newest = newest_tag(tags)
        subprocess.run(["gh", "release", "edit", newest, "--latest=true"], check=True)
        confirmed = newest_tag(published_tags())
        latest = subprocess.check_output([
            "gh", "release", "view", "--json", "tagName", "--jq", ".tagName",
        ], text=True).strip()
        if newest == confirmed == latest:
            return newest
        if attempt < 4:
            pause(1)
    raise RuntimeError("Release state kept changing; rerun to reconcile Latest")


if __name__ == "__main__":
    print("Latest: " + publish_and_reconcile(sys.argv[1]))
