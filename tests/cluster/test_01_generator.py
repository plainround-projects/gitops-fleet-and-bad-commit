"""Step 2: one Application per registered cluster, and a fourth cluster adds one with no new manifest."""

from __future__ import annotations

from tests.conftest import Runbook
from tests.support.kube import Kube
from tests.support.waiting import wait_until


def test_the_three_applications_were_generated_not_written(hub: Kube) -> None:
    assert hub.list_names("applications", "argocd", "app=web") == ["web-dev", "web-production", "web-staging"]

    owners = hub.get("application", "web-dev", "argocd")["metadata"]["ownerReferences"]
    assert [(owner["kind"], owner["name"]) for owner in owners] == [("ApplicationSet", "web-fleet")]


def test_each_application_points_at_its_own_cluster_and_its_stage_project(hub: Kube) -> None:
    servers = {stage: hub.application(f"web-{stage}").server for stage in ("dev", "staging", "production")}

    assert servers == {stage: f"https://fleet-{stage}-control-plane:6443" for stage in servers}
    projects = {stage: hub.get("application", f"web-{stage}", "argocd")["spec"]["project"] for stage in servers}
    assert projects == {"dev": "dev", "staging": "staging", "production": "production"}


def test_only_dev_follows_main_and_the_later_stages_are_pinned(hub: Kube, runbook: Runbook) -> None:
    assert hub.application("web-dev").target_revision == "main"
    assert hub.application("web-staging").target_revision == runbook.stage_revision("staging")
    assert hub.application("web-production").target_revision == runbook.stage_revision("production")
    assert runbook.stage_revision("staging") != "main"


def test_a_fourth_cluster_gets_an_application_with_no_new_manifest_and_leaves_with_it(
    hub: Kube, runbook: Runbook
) -> None:
    before = hub.list_names("applications", "argocd", "app=web")
    try:
        runbook.script("runbook/02-generate-apps.sh", "add")
        assert hub.list_names("applications", "argocd", "app=web") == sorted([*before, "web-demo4"])
        state = hub.application("web-demo4")
        assert (state.sync_status, state.health_status) == ("Synced", "Healthy")
    finally:
        runbook.script("runbook/02-generate-apps.sh", "remove", check=False)

    wait_until(
        "web-demo4 to be gone",
        lambda: hub.list_names("applications", "argocd", "app=web") == before,
        timeout=60,
    )
