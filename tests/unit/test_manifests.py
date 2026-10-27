"""Offline checks of the fleet repository: the app, the generators, the projects and the policy."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

import pytest
import yaml

from tests.support.shell import run


def load(root: Path, relative: str) -> list[dict[str, Any]]:
    return [doc for doc in yaml.safe_load_all((root / "manifests" / relative).read_text()) if doc]


@pytest.fixture(scope="module")
def app(root: Path) -> dict[tuple[str, str], dict[str, Any]]:
    output = run(["kubectl", "kustomize", str(root / "manifests/apps/web/base")]).stdout
    return {(doc["kind"], doc["metadata"]["name"]): doc for doc in yaml.safe_load_all(output) if doc}


def test_the_app_is_the_lessons_four_objects(app: dict[tuple[str, str], dict[str, Any]]) -> None:
    assert set(app) == {
        ("Namespace", "web"),
        ("ConfigMap", "web-config"),
        ("Deployment", "web"),
        ("Service", "web"),
    }


def test_the_namespace_is_protected_from_pruning(app: dict[tuple[str, str], dict[str, Any]]) -> None:
    annotations = app[("Namespace", "web")]["metadata"]["annotations"]

    assert annotations["argocd.argoproj.io/sync-options"] == "Prune=false"


def test_the_service_is_a_node_port_the_traffic_test_can_reach_from_the_host(
    app: dict[tuple[str, str], dict[str, Any]],
) -> None:
    service = app[("Service", "web")]["spec"]

    assert (service["type"], service["ports"][0]["nodePort"]) == ("NodePort", 30080)


def test_the_deployment_runs_two_unprivileged_replicas_from_the_allowed_registry(
    app: dict[tuple[str, str], dict[str, Any]],
) -> None:
    spec = app[("Deployment", "web")]["spec"]
    container = spec["template"]["spec"]["containers"][0]

    assert spec["replicas"] == 2
    assert container["image"].startswith("plainround/")
    assert container["securityContext"]["allowPrivilegeEscalation"] is False
    assert "privileged" not in container["securityContext"]


def test_the_web_applicationset_builds_one_application_per_labelled_cluster_from_its_stage_file(
    root: Path,
) -> None:
    appset = load(root, "hub/appset-web.yaml")[0]["spec"]
    clusters, git = appset["generators"][0]["matrix"]["generators"]

    assert clusters["clusters"]["selector"]["matchLabels"] == {"app": "web"}
    assert git["git"]["files"] == [{"path": "clusters/{{ .metadata.labels.stage }}.yaml"}]
    assert appset["template"]["metadata"]["name"] == "web-{{ .name }}"
    assert appset["template"]["spec"]["source"]["targetRevision"] == "{{ .revision }}"
    assert appset["template"]["spec"]["project"] == "{{ .metadata.labels.stage }}"


def test_every_application_self_heals_and_prune_comes_from_the_stage_file(root: Path) -> None:
    patch = load(root, "hub/appset-web.yaml")[0]["spec"]["templatePatch"]

    assert "selfHeal: true" in patch
    assert "prune: {{ .prune }}" in patch


def test_the_policy_applicationset_uses_the_same_cluster_selector_as_the_app(root: Path) -> None:
    web = load(root, "hub/appset-web.yaml")[0]["spec"]["generators"][0]["matrix"]["generators"][0]
    policy = load(root, "hub/appset-policy.yaml")[0]["spec"]["generators"][0]

    assert policy["clusters"] == web["clusters"]


def test_only_production_has_a_sync_window(root: Path) -> None:
    projects = {doc["metadata"]["name"]: doc for doc in load(root, "hub/projects.yaml")}

    assert projects["production"]["spec"]["syncWindows"][0]["kind"] == "allow"
    assert not any("syncWindows" in projects[name]["spec"] for name in ("dev", "staging", "fleet-policy"))


def test_every_project_allows_only_the_fleet_repository(root: Path) -> None:
    for project in load(root, "hub/projects.yaml"):
        assert project["spec"]["sourceRepos"] == ["http://git-server.git-server.svc.cluster.local/gitops-fleet.git"]


def test_the_policy_rejects_privileged_containers_and_foreign_images_and_denies(root: Path) -> None:
    policy, binding = load(root, "policy/no-privileged.yaml")
    messages = [rule["message"] for rule in policy["spec"]["validations"]]

    assert messages == ["privileged containers are not allowed", "images must come from plainround/"]
    assert binding["spec"]["validationActions"] == ["Deny"]
    assert policy["spec"]["failurePolicy"] == "Fail"


def test_the_policy_covers_deployments_and_pods(root: Path) -> None:
    policy = load(root, "policy/no-privileged.yaml")[0]
    covered = {
        (rule["apiGroups"][0], rule["resources"][0]) for rule in policy["spec"]["matchConstraints"]["resourceRules"]
    }

    assert covered == {("apps", "deployments"), ("", "pods")}


def test_the_policy_binding_leaves_the_system_namespaces_alone(root: Path) -> None:
    binding = load(root, "policy/no-privileged.yaml")[1]
    excluded = binding["spec"]["matchResources"]["namespaceSelector"]["matchExpressions"][0]["values"]

    assert {"kube-system", "argocd"} <= set(excluded)


def test_committed_stage_files_name_a_branch_and_seeding_pins_the_later_stages(root: Path) -> None:
    assert [
        (root / f"manifests/clusters/{stage}.yaml").read_text().count("revision: main")
        for stage in ("dev", "staging", "production")
    ] == [1, 1, 1]
    seed = (root / "scripts/seed-repo.sh").read_text()
    assert re.search(r"set_stage_value staging revision", seed)
    assert re.search(r"set_stage_value production revision", seed)


def test_the_argo_cd_version_in_the_kustomization_matches_versions_env(root: Path) -> None:
    pinned = re.search(r"argo-cd/(v[\d.]+)/", (root / "platform/argocd/kustomization.yaml").read_text())
    versions = dict(
        line.split("=", 1)
        for line in (root / "versions.env").read_text().splitlines()
        if "=" in line and line[0] != "#"
    )

    assert pinned is not None
    assert pinned.group(1) == versions["ARGOCD_VERSION"]
