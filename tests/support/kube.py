"""A small read-mostly view of the hub's Argo CD Applications and of the workload clusters, through kubectl."""

from __future__ import annotations

import json
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Any

from tests.support.shell import CommandResult, run


@dataclass(frozen=True)
class ApplicationState:
    """What the hub's controller reports about one Application."""

    name: str
    sync_status: str
    health_status: str
    revision: str
    target_revision: str
    operation_phase: str
    operation_message: str
    applied_revision: str
    pending_prune: tuple[str, ...]
    server: str


class Kube:
    """kubectl pinned to one context, so a test can never touch another cluster."""

    def __init__(
        self,
        context: str,
        runner: Callable[..., CommandResult] = run,
    ) -> None:
        """Remember the kubectl context (for kind ``kind-<cluster>``); ``runner`` is replaceable in tests."""
        self.context = context
        self._runner = runner

    def kubectl(self, *args: str, check: bool = True) -> CommandResult:
        """Run kubectl against this context."""
        command: Sequence[str] = ["kubectl", "--context", self.context, *args]
        return self._runner(command, check=check, timeout=120)

    def get(self, kind: str, name: str, namespace: str | None = None) -> dict[str, Any]:
        """Return one object as parsed JSON; raises CommandError when it does not exist."""
        scope = ["-n", namespace] if namespace else []
        parsed: dict[str, Any] = json.loads(self.kubectl("get", kind, name, *scope, "-o", "json").stdout)
        return parsed

    def list_names(self, kind: str, namespace: str | None = None, selector: str | None = None) -> list[str]:
        """The names of all objects of a kind (optionally filtered by a label selector), sorted."""
        scope = ["-n", namespace] if namespace else []
        label = ["-l", selector] if selector else []
        output = self.kubectl("get", kind, *scope, *label, "-o", "name").stdout
        return sorted(line.split("/", 1)[1] for line in output.split() if "/" in line)

    def exists(self, kind: str, name: str, namespace: str | None = None) -> bool:
        """True when the object exists."""
        scope = ["-n", namespace] if namespace else []
        return self.kubectl("get", kind, name, *scope, check=False).returncode == 0

    def application(self, name: str) -> ApplicationState:
        """The controller's view of an Application in the ``argocd`` namespace."""
        application = self.get("application", name, "argocd")
        status = application.get("status", {})
        operation = status.get("operationState", {})
        resources: list[dict[str, Any]] = status.get("resources", [])
        return ApplicationState(
            name=name,
            sync_status=status.get("sync", {}).get("status", ""),
            health_status=status.get("health", {}).get("status", ""),
            revision=status.get("sync", {}).get("revision", ""),
            target_revision=application["spec"]["source"].get("targetRevision", ""),
            operation_phase=operation.get("phase", ""),
            operation_message=operation.get("message", ""),
            applied_revision=operation.get("syncResult", {}).get("revision", ""),
            pending_prune=tuple(f"{r['kind']}/{r['name']}" for r in resources if r.get("requiresPruning")),
            server=application["spec"]["destination"].get("server", ""),
        )

    def deployment(self, namespace: str, name: str) -> dict[str, Any]:
        """A Deployment as parsed JSON."""
        return self.get("deployment", name, namespace)

    def replicas(self, namespace: str, name: str) -> int:
        """The replica count the Deployment asks for."""
        return int(self.deployment(namespace, name)["spec"]["replicas"])

    def image(self, namespace: str, name: str) -> str:
        """The image of the Deployment's first container."""
        return str(self.deployment(namespace, name)["spec"]["template"]["spec"]["containers"][0]["image"])
