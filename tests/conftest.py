"""Fixtures shared by the offline and cluster tests."""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from tests.support.kube import Kube
from tests.support.shell import run

ROOT = Path(__file__).resolve().parent.parent
STAGES = ("dev", "staging", "production")


def pytest_collection_modifyitems(items: list[pytest.Item]) -> None:
    """Tests under tests/cluster are marked ``cluster`` so `-m "not cluster"` runs the offline ones."""
    for item in items:
        if "tests/cluster" in str(item.fspath).replace(os.sep, "/"):
            item.add_marker(pytest.mark.cluster)


@pytest.fixture(scope="session")
def root() -> Path:
    """The repository root."""
    return ROOT


@pytest.fixture(scope="session")
def hub() -> Kube:
    """kubectl pinned to the hub; the tests need `make up` to have run."""
    client = Kube("kind-fleet-hub")
    if client.kubectl("get", "namespace", "argocd", check=False).returncode != 0:
        pytest.fail("the fleet is not up: run `make up` first", pytrace=False)
    return client


@pytest.fixture(scope="session")
def clusters(hub: Kube) -> dict[str, Kube]:
    """kubectl for each workload cluster, by stage."""
    return {stage: Kube(f"kind-fleet-{stage}") for stage in STAGES}


class Runbook:
    """Calls the scripts under scripts/ (the same ones a person runs) and returns what they printed."""

    def __init__(self, root: Path) -> None:
        """Remember where the scripts live."""
        self.root = root

    def script(self, relative: str, *args: str, check: bool = True, timeout: float = 1800) -> str:
        """Run ``scripts/<relative>``; return its combined output."""
        result = run([str(self.root / "scripts" / relative), *args], cwd=self.root, check=check, timeout=timeout)
        return result.output

    def try_script(self, relative: str, *args: str, timeout: float = 1800) -> tuple[int, str]:
        """Run a script that may fail on purpose; return (exit status, combined output)."""
        result = run([str(self.root / "scripts" / relative), *args], cwd=self.root, check=False, timeout=timeout)
        return result.returncode, result.output

    @property
    def clone(self) -> Path:
        """The working clone of the repository the hub watches."""
        return self.root / ".work" / "gitops-fleet"

    def git(self, *args: str) -> str:
        """Run git in the working clone and return its standard output."""
        return run(["git", "-C", str(self.clone), *args]).stdout

    def head(self) -> str:
        """The commit at the tip of main in the working clone."""
        return self.git("rev-parse", "main").strip()

    def stage_revision(self, stage: str) -> str:
        """The revision clusters/<stage>.yaml pins, as committed on main."""
        for line in self.git("show", f"main:clusters/{stage}.yaml").splitlines():
            if line.startswith("revision:"):
                return line.split(":", 1)[1].strip()
        raise AssertionError(f"no revision in clusters/{stage}.yaml")


@pytest.fixture(scope="session")
def runbook(root: Path) -> Runbook:
    """The runbook scripts."""
    return Runbook(root)
