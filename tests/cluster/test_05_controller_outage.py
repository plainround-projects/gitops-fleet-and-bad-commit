"""Step 6: losing the controller pauses reconciliation, not the app; drift made meanwhile is corrected on return."""

from __future__ import annotations

import os

import pytest

from tests.conftest import Runbook
from tests.support.kube import Kube


@pytest.fixture(scope="module", autouse=True)
def stable(settled: None) -> None:
    return None


def test_the_app_serves_throughout_and_drift_is_corrected_when_the_controller_returns(
    hub: Kube, clusters: dict[str, Kube], runbook: Runbook
) -> None:
    seconds = os.environ.get("OUTAGE_SECONDS", "90")

    output = runbook.script("runbook/06-controller-outage.sh", seconds, timeout=int(seconds) + 900)

    assert "mid-outage drift: replicas=4" in output
    assert "end of outage: replicas=4" in output  # nothing reconciled while the controller was down
    assert "drift corrected" in output
    assert clusters["production"].replicas("web", "web") == 2
    log = (runbook.root / "logs" / "outage-traffic.log").read_text().split()
    assert len(log) >= int(seconds)
    assert set(log) == {"200"}, f"non-200 responses during the outage: {set(log) - {'200'}}"
    assert hub.application("web-production").sync_status == "Synced"
