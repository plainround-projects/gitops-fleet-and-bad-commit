#!/usr/bin/env python3
"""Check the per-stage files the ApplicationSet's Git generator reads.

    check_clusters.py <repository-root>

Each clusters/<stage>.yaml must name its own stage, a revision, a boolean ``prune`` and a non-negative
``observeSeconds``; production must declare a ``syncWindow`` equal to the one in hub/projects.yaml.
Exit status 0 means every file is well formed.
"""

from __future__ import annotations

import re
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import yaml

STAGES = ("dev", "staging", "production")
WINDOW = re.compile(r"^(\d{2}):00-(\d{2}):00 UTC$")


def stage_problems(stage: str, document: dict[str, Any]) -> Iterator[str]:
    """Yield one message per way a stage file is malformed."""
    if document.get("stage") != stage:
        yield f"{stage}: stage must be {stage!r}, found {document.get('stage')!r}"
    if not isinstance(document.get("revision"), str) or not document["revision"]:
        yield f"{stage}: revision must be a branch name or a commit"
    if not isinstance(document.get("prune"), bool):
        yield f"{stage}: prune must be true or false"
    seconds = document.get("observeSeconds")
    if not isinstance(seconds, int) or isinstance(seconds, bool) or seconds < 0:
        yield f"{stage}: observeSeconds must be a non-negative integer"
    if stage == "production" and document.get("prune") is not False:
        yield "production: prune must be false"


def window_problems(root: Path, document: dict[str, Any]) -> Iterator[str]:
    """Yield a message when production's syncWindow and the AppProject's window disagree."""
    match = WINDOW.match(str(document.get("syncWindow", "")))
    if match is None:
        yield "production: syncWindow must look like '22:00-23:00 UTC'"
        return
    start, end = int(match.group(1)), int(match.group(2))
    projects = [p for p in yaml.safe_load_all((root / "hub/projects.yaml").read_text()) if p]
    production = next(p for p in projects if p["metadata"]["name"] == "production")
    window = production["spec"]["syncWindows"][0]
    expected = f"0 {start} * * *"
    duration = f"{(end - start) % 24}h"
    found = (window["schedule"], window["duration"], window["kind"])
    if found != (expected, duration, "allow"):
        yield (
            f"production: hub/projects.yaml has {window['schedule']!r} for {window['duration']}, "
            f"expected {expected!r} for {duration}"
        )


def check(root: Path) -> list[str]:
    """Return every problem under ``root/clusters``."""
    problems: list[str] = []
    documents: dict[str, dict[str, Any]] = {}
    for stage in STAGES:
        path = root / "clusters" / f"{stage}.yaml"
        if not path.is_file():
            problems.append(f"{stage}: {path.name} is missing")
            continue
        documents[stage] = yaml.safe_load(path.read_text())
        problems.extend(stage_problems(stage, documents[stage]))
    if "production" in documents:
        problems.extend(window_problems(root, documents["production"]))
    return problems


def main(argv: list[str]) -> int:
    """Command-line entry point."""
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    problems = check(Path(argv[1]))
    for problem in problems:
        print(f"clusters: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
