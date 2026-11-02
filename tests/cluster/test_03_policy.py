"""Step 4: one admission policy in every cluster refuses a privileged pod and a foreign image, in its own words."""

from __future__ import annotations

from functools import partial

import pytest

from tests.conftest import STAGES, Runbook
from tests.support.kube import Kube
from tests.support.shell import run
from tests.support.waiting import wait_until


def gave_up(hub: Kube, stage: str) -> bool:
    """Whether the controller has given up the stage's sync (Failed or Error)."""
    return hub.application(f"web-{stage}").operation_phase in {"Failed", "Error"}


@pytest.fixture(scope="module", autouse=True)
def open_window(settled: None, runbook: Runbook) -> None:
    runbook.script("runbook/window.sh", "open")


def test_the_policy_is_installed_in_every_cluster_by_the_applicationset(hub: Kube, clusters: dict[str, Kube]) -> None:
    assert hub.list_names("applications", "argocd", "app=policy") == [f"policy-{stage}" for stage in sorted(STAGES)]
    for kube in clusters.values():
        assert kube.exists("validatingadmissionpolicy", "no-privileged-or-foreign-images")
        assert kube.exists("validatingadmissionpolicybinding", "no-privileged-or-foreign-images")


@pytest.mark.parametrize(
    ("kind", "message"),
    [("privileged", "privileged containers are not allowed"), ("foreign", "images must come from plainround/")],
)
def test_a_refused_commit_fails_the_sync_in_every_cluster_with_the_policys_message(
    hub: Kube, clusters: dict[str, Kube], runbook: Runbook, kind: str, message: str
) -> None:
    output = runbook.script("runbook/04-policy.sh", kind)

    for stage in STAGES:
        # The controller retries a refused sync five times with a growing delay (about five minutes). Dev follows main,
        # so it goes through that twice: for the bad commit, and for the commit that pins the later stages.
        wait_until(f"web-{stage} to give up the sync", partial(gave_up, hub, stage), timeout=1200)
        state = hub.application(f"web-{stage}")
        assert message in state.operation_message
        assert message in output
        assert "ValidatingAdmissionPolicy" in state.operation_message
    runbook.script("runbook/04-policy.sh", "revert")


def test_no_cluster_ever_ran_the_refused_manifest(clusters: dict[str, Kube]) -> None:
    for kube in clusters.values():
        assert kube.image("web", "web").startswith("plainround/web:")


def test_a_privileged_pod_is_refused_with_no_controller_involved(clusters: dict[str, Kube]) -> None:
    for kube in clusters.values():
        result = run(
            [
                "kubectl",
                "--context",
                kube.context,
                "-n",
                "default",  # the web namespace's stricter PodSecurity label answers first, in its own words
                "run",
                "attacker",
                "--image=plainround/web:1.0.0",
                "--privileged",
                "--restart=Never",
            ],
            check=False,
        )

        assert result.returncode != 0
        assert "privileged containers are not allowed" in result.output
