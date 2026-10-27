from __future__ import annotations

import json
from collections.abc import Sequence
from typing import Any

from tests.support.kube import Kube
from tests.support.shell import CommandError, CommandResult


class FakeKubectl:
    """Answers kubectl calls from a table of canned JSON, and records each command line."""

    def __init__(self, objects: dict[str, Any], names: str = "") -> None:
        self.objects = objects
        self.names = names
        self.commands: list[Sequence[str]] = []

    def __call__(self, args: Sequence[str], *, check: bool = True, timeout: float = 0) -> CommandResult:
        self.commands.append(args)
        if "-o" in args and args[args.index("-o") + 1] == "name":
            return CommandResult(tuple(args), 0, self.names, "")
        key = f"{args[args.index('get') + 1]}/{args[args.index('get') + 2]}"
        if key in self.objects:
            return CommandResult(tuple(args), 0, json.dumps(self.objects[key]), "")
        result = CommandResult(tuple(args), 1, "", "NotFound")
        if check:
            raise CommandError(result)
        return result


APPLICATION = {
    "spec": {
        "source": {"targetRevision": "abc123"},
        "destination": {"server": "https://fleet-dev-control-plane:6443"},
    },
    "status": {
        "sync": {"status": "OutOfSync", "revision": "abc123"},
        "health": {"status": "Healthy"},
        "operationState": {
            "phase": "Succeeded",
            "message": "successfully synced",
            "syncResult": {"revision": "abc123"},
        },
        "resources": [
            {"kind": "Namespace", "name": "web", "requiresPruning": True},
            {"kind": "Service", "name": "web"},
        ],
    },
}
DEPLOYMENT = {"spec": {"replicas": 2, "template": {"spec": {"containers": [{"image": "plainround/web:1.0.0"}]}}}}


def kube_with(names: str = "") -> tuple[Kube, FakeKubectl]:
    fake = FakeKubectl({"application/web-dev": APPLICATION, "deployment/web": DEPLOYMENT}, names)
    return Kube("kind-test", runner=fake), fake


def test_application_state_reads_status_spec_and_pending_prune() -> None:
    kube, _ = kube_with()

    state = kube.application("web-dev")

    assert (state.sync_status, state.health_status, state.revision) == ("OutOfSync", "Healthy", "abc123")
    assert (state.operation_phase, state.applied_revision) == ("Succeeded", "abc123")
    assert state.pending_prune == ("Namespace/web",)
    assert state.target_revision == "abc123"
    assert state.server.endswith("fleet-dev-control-plane:6443")


def test_an_application_without_status_reads_as_empty_strings() -> None:
    fake = FakeKubectl({"application/web-dev": {"spec": {"source": {}, "destination": {}}}})

    state = Kube("kind-test", runner=fake).application("web-dev")

    assert (state.sync_status, state.health_status, state.applied_revision, state.pending_prune) == (
        "",
        "",
        "",
        (),
    )


def test_deployment_fields() -> None:
    kube, _ = kube_with()

    assert kube.replicas("web", "web") == 2
    assert kube.image("web", "web") == "plainround/web:1.0.0"


def test_list_names_strips_the_kind_and_sorts() -> None:
    kube, fake = kube_with(names="application.argoproj.io/web-staging\napplication.argoproj.io/web-dev\n")

    assert kube.list_names("applications", "argocd", "app=web") == ["web-dev", "web-staging"]
    assert fake.commands[0][:3] == ["kubectl", "--context", "kind-test"]
    assert "-l" in fake.commands[0]


def test_exists_is_false_for_a_missing_object_and_true_for_a_present_one() -> None:
    kube, _ = kube_with()

    assert kube.exists("deployment", "web", "web") is True
    assert kube.exists("deployment", "gone", "web") is False
