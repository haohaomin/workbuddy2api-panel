#!/usr/bin/env python3
"""Decide Latest by timestamp, including when an older failed release is retried."""
from datetime import datetime
import re
import subprocess
import sys


def version_key(tag):
    if not re.fullmatch(r"v\d{4}\.\d{1,2}\.\d{1,2}\.\d{3,4}", tag):
        return None
    year, month, day, clock = map(int, tag[1:].split("."))
    try:
        return datetime(year, month, day, clock // 100, clock % 100)
    except ValueError:
        return None


def should_be_latest(version):
    candidate = version_key("v" + version)
    if candidate is None:
        raise ValueError("Invalid timestamp release version")
    # List all published stable releases, not just the currently pinned Latest.
    # API errors must abort publishing rather than silently assume no newer release.
    tags = subprocess.check_output([
        "gh", "api", "--paginate", "repos/{owner}/{repo}/releases?per_page=100",
        "--jq", ".[] | select(.draft == false and .prerelease == false) | .tag_name",
    ], text=True).splitlines()
    return not any(key > candidate for tag in tags if (key := version_key(tag)) is not None)


if __name__ == "__main__":
    print("true" if should_be_latest(sys.argv[1]) else "false")
