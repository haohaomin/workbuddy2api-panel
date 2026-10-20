#!/usr/bin/env python3
"""Reserve a Shanghai timestamp tag for the exact commit being built."""
from datetime import datetime, timedelta, timezone
import os
import re
import subprocess
import time


TAG = re.compile(r"v\d{4}\.\d{1,2}\.\d{1,2}\.\d{3,4}\Z")


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def timestamp():
    now = datetime.now(timezone(timedelta(hours=8)))
    return f"{now.year}.{now.month}.{now.day}.{now.hour}{now.minute:02d}"


def resolve(ref, sha, now=timestamp, pause=time.sleep):
    if ref.startswith("refs/tags/"):
        tag = ref.removeprefix("refs/tags/")
        if not TAG.fullmatch(tag):
            raise ValueError("Release tags must use the Shanghai timestamp format")
        return tag[1:]
    if ref != "refs/heads/main":
        return now()  # Manual builds of other branches are artifacts only.

    git("fetch", "origin", "--tags")
    # Reruns and a simultaneous manual tag must use the same version.
    existing = [tag for tag in git("tag", "--points-at", sha).splitlines()
                if TAG.fullmatch(tag)]
    if existing:
        return max(existing, key=lambda tag: tuple(map(int, tag[1:].split("."))))[1:]

    for _ in range(13):
        version = now()
        tag = "v" + version
        matches = git("tag", "--list", tag)
        if not matches:
            # Push the build SHA, never the branch tip (which may have advanced).
            pushed = subprocess.run(["git", "push", "origin", f"{sha}:refs/tags/{tag}"])
            if pushed.returncode == 0:
                return version
            git("fetch", "origin", "--tags")
            if not git("tag", "--list", tag):
                raise RuntimeError("Could not push release tag; check repository permissions/network")
        if git("rev-parse", f"refs/tags/{tag}^{{commit}}") == sha:
            return version
        # Another commit owns this minute. Wait for the clock, never overwrite it.
        pause(10)
        git("fetch", "origin", "--tags")
    raise RuntimeError("Timestamp remained occupied for two minutes; rerun the workflow")


if __name__ == "__main__":
    version = resolve(os.environ["GITHUB_REF"], os.environ["GITHUB_SHA"])
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"version={version}\n")
    print(f"Resolved version: {version}")
