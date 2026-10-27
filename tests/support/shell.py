"""Run external commands and report what they did, with typed results and a named error."""

from __future__ import annotations

import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class CommandResult:
    """The outcome of one finished command."""

    args: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str

    @property
    def output(self) -> str:
        """Standard output and standard error together, the way a terminal shows them."""
        return self.stdout + self.stderr


class CommandError(RuntimeError):
    """A command exited with a non-zero status (or did not finish in time)."""

    def __init__(self, result: CommandResult) -> None:
        """Keep the whole result so the test report shows what the command printed."""
        self.result = result
        command = " ".join(result.args)
        super().__init__(f"{command!r} exited {result.returncode}\n{result.output.strip()}")


def run(
    args: Sequence[str],
    *,
    cwd: Path | None = None,
    env: Mapping[str, str] | None = None,
    check: bool = True,
    timeout: float = 300,
) -> CommandResult:
    """Run ``args`` and return the result; raise CommandError on a non-zero exit when ``check`` is set."""
    try:
        completed = subprocess.run(
            list(args),
            cwd=cwd,
            env=None if env is None else dict(env),
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as expired:
        stdout = expired.stdout.decode() if isinstance(expired.stdout, bytes) else (expired.stdout or "")
        result = CommandResult(tuple(args), 124, stdout, f"timed out after {timeout}s")
        raise CommandError(result) from expired
    result = CommandResult(tuple(args), completed.returncode, completed.stdout, completed.stderr)
    if check and result.returncode != 0:
        raise CommandError(result)
    return result
