"""Step 1: the design states how long a change takes to reach production at best, computed from the repository."""

from __future__ import annotations

import re
from pathlib import Path

from tests.support.shell import run


def seconds_in(output: str) -> int:
    match = re.search(r"= (\d+)s", output)
    assert match is not None, output
    return int(match.group(1))


def number(path: Path, pattern: str) -> int:
    match = re.search(pattern, path.read_text())
    assert match is not None
    return int(match.group(1))


def test_the_configured_best_case_is_one_poll_two_requeues_and_two_observation_windows(root: Path) -> None:
    output = run([str(root / "scripts/best-case.sh")]).stdout

    poll = number(root / "platform/argocd/controller-settings.yaml", r"timeout\.reconciliation: (\d+)s")
    requeue = number(root / "manifests/hub/appset-web.yaml", r"requeueAfterSeconds: (\d+)")
    dev = number(root / "manifests/clusters/dev.yaml", r"observeSeconds: (\d+)")
    staging = number(root / "manifests/clusters/staging.yaml", r"observeSeconds: (\d+)")
    assert seconds_in(output) == poll + dev + requeue + staging + requeue
    assert "what stops it" in output


def test_the_lesson_numbers_give_sixteen_minutes_forty_seconds_through_git(root: Path) -> None:
    output = run([str(root / "scripts/best-case.sh"), "--lesson"]).stdout

    assert seconds_in(output) == 60 + 300 + 20 + 600 + 20
    assert "16 min 40 s" in output
