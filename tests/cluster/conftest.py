"""The fleet's cluster tests run in file order; each module starts from the state the one before it left (clean)."""

from __future__ import annotations

from functools import partial

import pytest

from tests.conftest import Runbook
from tests.support.kube import Kube
from tests.support.waiting import wait_until


def _settled(hub: Kube, stage: str) -> bool:
    state = hub.application(f"web-{stage}")
    return state.sync_status == "Synced" and state.health_status == "Healthy"


@pytest.fixture(scope="module")
def settled(hub: Kube) -> None:
    """Every stage is Synced and Healthy before a module starts."""
    for stage in ("dev", "staging", "production"):
        wait_until(f"web-{stage} Synced and Healthy", partial(_settled, hub, stage), timeout=300)


@pytest.fixture
def window_closed(runbook: Runbook) -> None:
    """Production's sync window is twelve hours away."""
    runbook.script("runbook/window.sh", "closed")
