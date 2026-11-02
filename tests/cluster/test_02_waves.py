"""Step 3: waves with a health gate, and a production sync window."""

from __future__ import annotations

import pytest

from tests.conftest import Runbook
from tests.support.kube import Kube
from tests.support.waiting import wait_until


@pytest.fixture(scope="module", autouse=True)
def closed_window(settled: None, runbook: Runbook) -> None:
    runbook.script("runbook/window.sh", "closed")


def test_a_good_change_goes_dev_then_staging_and_waits_outside_the_window(
    hub: Kube, clusters: dict[str, Kube], runbook: Runbook
) -> None:
    runbook.script("runbook/03-waves.sh", "good")
    change = (runbook.clone / ".." / "good-commit").resolve().read_text().strip()

    assert clusters["dev"].image("web", "web") == "plainround/web:1.1.0"
    assert clusters["staging"].image("web", "web") == "plainround/web:1.1.0"
    assert hub.application("web-staging").applied_revision == change
    # Production is pinned to the commit but must not have applied it: the window is closed.
    # The ApplicationSet controller notices the new pin on its own schedule, so wait for the Application to carry it.
    wait_until(
        "web-production to carry the pinned commit",
        lambda: hub.application("web-production").target_revision == change,
        timeout=300,
    )
    wait_until(
        "web-production to be OutOfSync",
        lambda: hub.application("web-production").sync_status == "OutOfSync",
        timeout=300,
    )
    production = hub.application("web-production")
    assert production.target_revision == change
    assert production.sync_status == "OutOfSync"
    assert production.applied_revision != change
    assert clusters["production"].image("web", "web") == "plainround/web:1.0.0"


def test_a_good_change_outside_the_window_is_applied_once_the_window_opens(
    hub: Kube, clusters: dict[str, Kube], runbook: Runbook
) -> None:
    runbook.script("runbook/03-waves.sh", "open")

    wait_until(
        "production to run 1.1.0",
        lambda: clusters["production"].image("web", "web") == "plainround/web:1.1.0",
        timeout=120,
    )
    assert hub.application("web-production").sync_status == "Synced"


def test_a_change_that_fails_its_health_check_in_dev_never_reaches_staging_or_production(
    hub: Kube, clusters: dict[str, Kube], runbook: Runbook
) -> None:
    staging_before = hub.application("web-staging").target_revision
    production_before = hub.application("web-production").target_revision

    output = runbook.script("runbook/03-waves.sh", "bad")

    assert hub.application("web-dev").health_status == "Degraded"
    assert hub.application("web-staging").target_revision == staging_before
    assert hub.application("web-production").target_revision == production_before
    assert "pinned to" in output
    assert hub.application("web-staging").health_status == "Healthy"


def test_git_revert_returns_dev_to_healthy(hub: Kube, runbook: Runbook) -> None:
    runbook.script("runbook/03-waves.sh", "revert")

    assert hub.application("web-dev").health_status == "Healthy"
