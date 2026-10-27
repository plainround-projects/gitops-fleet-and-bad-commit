from __future__ import annotations

import pytest

from tests.support.shell import CommandError, run


def test_run_returns_output_and_status() -> None:
    result = run(["sh", "-c", "echo out; echo err >&2; exit 0"])

    assert (result.returncode, result.stdout, result.stderr) == (0, "out\n", "err\n")
    assert result.output == "out\nerr\n"


def test_a_failing_command_raises_with_its_output() -> None:
    with pytest.raises(CommandError) as raised:
        run(["sh", "-c", "echo broken >&2; exit 3"])

    assert raised.value.result.returncode == 3
    assert "broken" in str(raised.value)


def test_check_false_returns_the_failure_instead_of_raising() -> None:
    assert run(["sh", "-c", "exit 4"], check=False).returncode == 4


def test_a_command_that_runs_too_long_is_reported_as_timed_out() -> None:
    with pytest.raises(CommandError, match=r"timed out after 0\.2s"):
        run(["sleep", "5"], timeout=0.2)
