"""Step 5: a commit that deletes the namespace manifest deletes nothing; the controller flags it; revert clears it."""

from __future__ import annotations

import pytest

from tests.conftest import STAGES, Runbook
from tests.support.kube import Kube


@pytest.fixture(scope="module", autouse=True)
def open_window(settled: None, runbook: Runbook) -> None:
    runbook.script("runbook/window.sh", "open")


def test_the_deletion_leaves_the_namespace_and_the_workloads_running_and_the_controller_flags_it(
    hub: Kube, clusters: dict[str, Kube], runbook: Runbook
) -> None:
    runbook.script("runbook/05-destructive-commit.sh", "commit")

    for stage in ("production", "dev"):
        state = hub.application(f"web-{stage}")
        assert state.sync_status == "OutOfSync"
        assert "Namespace/web" in state.pending_prune
        namespace = clusters[stage].get("namespace", "web")
        assert namespace["status"]["phase"] == "Active"
        assert "deletionTimestamp" not in namespace["metadata"]
        assert clusters[stage].deployment("web", "web")["status"]["readyReplicas"] == 2


def test_git_revert_clears_the_difference_everywhere(hub: Kube, runbook: Runbook) -> None:
    runbook.script("runbook/05-destructive-commit.sh", "revert")

    for stage in STAGES:
        state = hub.application(f"web-{stage}")
        assert (state.sync_status, state.health_status) == ("Synced", "Healthy")
        assert state.pending_prune == ()
