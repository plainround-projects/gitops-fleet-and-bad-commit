"""scripts/check_clusters.py: the per-stage files the ApplicationSet reads."""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest
import yaml
from check_clusters import check, main, stage_problems


def tree_from(root: Path, target: Path) -> Path:
    shutil.copytree(root / "manifests", target)
    return target


def edit(path: Path, **changes: object) -> None:
    document = yaml.safe_load(path.read_text())
    document.update(changes)
    path.write_text(yaml.safe_dump(document))


def test_the_shipped_files_are_well_formed(root: Path) -> None:
    assert check(root / "manifests") == []


def test_a_missing_stage_file_is_reported(root: Path, tmp_path: Path) -> None:
    tree = tree_from(root, tmp_path / "tree")
    (tree / "clusters/staging.yaml").unlink()

    assert "staging: staging.yaml is missing" in check(tree)


@pytest.mark.parametrize(
    ("changes", "fragment"),
    [
        ({"stage": "qa"}, "stage must be 'dev'"),
        ({"revision": ""}, "revision must be a branch name or a commit"),
        ({"prune": "yes"}, "prune must be true or false"),
        ({"observeSeconds": -1}, "observeSeconds must be a non-negative integer"),
        ({"observeSeconds": True}, "observeSeconds must be a non-negative integer"),
    ],
)
def test_each_malformed_field_is_named(changes: dict[str, object], fragment: str) -> None:
    document: dict[str, object] = {"stage": "dev", "revision": "main", "prune": True, "observeSeconds": 30}
    document.update(changes)

    assert any(fragment in problem for problem in stage_problems("dev", document))


def test_production_must_not_prune(root: Path, tmp_path: Path) -> None:
    tree = tree_from(root, tmp_path / "tree")
    edit(tree / "clusters/production.yaml", prune=True)

    assert "production: prune must be false" in check(tree)


def test_a_window_that_disagrees_with_the_project_is_reported(root: Path, tmp_path: Path) -> None:
    tree = tree_from(root, tmp_path / "tree")
    edit(tree / "clusters/production.yaml", syncWindow="03:00-04:00 UTC")

    assert any("hub/projects.yaml has" in problem for problem in check(tree))


def test_a_window_in_the_wrong_format_is_reported(root: Path, tmp_path: Path) -> None:
    tree = tree_from(root, tmp_path / "tree")
    edit(tree / "clusters/production.yaml", syncWindow="after dinner")

    assert any("syncWindow must look like" in problem for problem in check(tree))


def test_a_window_that_wraps_midnight_is_compared_modulo_24_hours(root: Path, tmp_path: Path) -> None:
    tree = tree_from(root, tmp_path / "tree")
    edit(tree / "clusters/production.yaml", syncWindow="23:00-00:00 UTC")
    projects = tree / "hub/projects.yaml"
    projects.write_text(projects.read_text().replace('"0 22 * * *"', '"0 23 * * *"'))

    assert check(tree) == []


def test_main_returns_one_on_a_problem_zero_when_clean_and_two_on_bad_usage(root: Path, tmp_path: Path) -> None:
    tree = tree_from(root, tmp_path / "tree")
    edit(tree / "clusters/dev.yaml", prune="maybe")

    assert main(["check_clusters.py", str(tree)]) == 1
    assert main(["check_clusters.py", str(root / "manifests")]) == 0
    assert main(["check_clusters.py"]) == 2
