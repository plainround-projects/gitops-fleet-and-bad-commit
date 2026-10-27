from __future__ import annotations

import pytest

from tests.support.shell import CommandError, CommandResult
from tests.support.waiting import WaitTimeout, wait_until


class FakeClock:
    """A clock that only moves when the code sleeps."""

    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


def test_returns_the_probe_value_as_soon_as_it_is_truthy() -> None:
    clock = FakeClock()
    answers = iter([None, False, "ready"])

    value = wait_until("the answer", lambda: next(answers), timeout=30, interval=2, clock=clock, sleep=clock.sleep)

    assert value == "ready"
    assert clock.now == 4.0


def test_a_failing_command_counts_as_not_yet() -> None:
    clock = FakeClock()
    calls = {"count": 0}

    def probe() -> bool:
        calls["count"] += 1
        if calls["count"] < 3:
            raise CommandError(CommandResult(("kubectl", "get"), 1, "", "NotFound"))
        return True

    assert wait_until("the object", probe, timeout=30, interval=1, clock=clock, sleep=clock.sleep) is True
    assert calls["count"] == 3


def test_times_out_and_says_what_it_last_saw() -> None:
    clock = FakeClock()

    with pytest.raises(WaitTimeout, match=r"timed out after 10s waiting for the sync: the probe returned False"):
        wait_until("the sync", lambda: False, timeout=10, interval=3, clock=clock, sleep=clock.sleep)

    assert clock.now >= 10


def test_a_bug_in_the_probe_is_not_swallowed() -> None:
    clock = FakeClock()

    def probe() -> bool:
        raise KeyError("status")

    with pytest.raises(KeyError):
        wait_until("anything", probe, timeout=10, clock=clock, sleep=clock.sleep)
