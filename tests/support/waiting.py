"""Poll until a condition holds, with the clock and the sleep injected so the logic is testable."""

from __future__ import annotations

import time
from collections.abc import Callable

from tests.support.shell import CommandError


class WaitTimeout(AssertionError):
    """The condition did not hold within the time allowed."""


def wait_until[T](
    description: str,
    probe: Callable[[], T | None | bool],
    *,
    timeout: float,
    interval: float = 2.0,
    clock: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
) -> T:
    """Call ``probe`` until it returns something truthy and return that value.

    A probe may raise CommandError (for example ``kubectl get`` on an object that does not exist yet);
    that counts as "not yet". Any other exception is a bug in the test and propagates.
    """
    deadline = clock() + timeout
    last_problem = "the probe returned a falsy value"
    while True:
        try:
            value = probe()
            if value:
                return value  # type: ignore[return-value]
            last_problem = f"the probe returned {value!r}"
        except CommandError as error:
            last_problem = str(error).splitlines()[0]
        if clock() >= deadline:
            raise WaitTimeout(f"timed out after {timeout:g}s waiting for {description}: {last_problem}")
        sleep(interval)
