# pytest

## 1. What it is

pytest is a Python test runner. It finds files named `test_*.py`, runs every function named `test_*`, and reports which passed. A test passes when it finishes without an error; the `assert` statement raises one when its condition is false.

## 2. Why this repository uses it

Offline tests prove the files are well formed (stage files, the window equality, the generators, the projects, the policy rules, the best-case arithmetic) without a cluster; cluster tests run the lesson against four clusters.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `tests/unit/` | file shape, generators, projects, policy rules, best-case arithmetic, helpers |
| `tests/cluster/` | the cluster tests (generator, waves, policy, destructive commit, outage) |
| `tests/conftest.py` | fixtures, the `cluster` marker |
| `pyproject.toml` | `pythonpath = [".", "scripts"]`, coverage over `tests/support` and `scripts` |

## 4. How it works underneath

- A **fixture** is a function marked `@pytest.fixture` that builds something a test needs (a client, a folder). A test asks for it by writing the fixture's name as a parameter. `scope="session"` builds it once for the whole run, `scope="module"` once per file.
- A **marker** (`@pytest.mark.cluster`) tags tests; `-m "not cluster"` selects or skips tags. `--strict-markers` makes an unregistered tag an error.
- `conftest.py` files hold fixtures shared by the tests in their folder.
- `monkeypatch` and `tmp_path` are built-in fixtures for replacing things and getting a throwaway folder.
- `pytest-cov` measures which lines the tests ran; `fail_under = 90` fails the run below 90 percent.

## 5. Walkthrough of this repository's use

```toml
[tool.pytest.ini_options]
pythonpath = [".", "scripts"]
markers = ["cluster: needs the clusters from `make up` and runs the scripted runbook against them"]
[tool.coverage.run]
source = ["tests/support", "scripts"]
```
`pythonpath` lets tests `import check_clusters`. Coverage measures the helpers and the checker. One marker: `cluster`.

What the offline tests prove: stage files are well formed (a table of bad files and the messages they give); production's sync window equals the AppProject's; the matrix generator, `templatePatch`, `missingkey=error` and the project/destination settings are present in the ApplicationSet file; each policy rule is in the policy; `best-case.sh` prints 135 s and, with `--lesson`, 1000 s (16 min 40 s). The cluster tests call the same runbook scripts and then assert on the hub's Applications and on the workload clusters.

<!-- full-walkthrough:begin -->
### 5.A Full walkthrough: every test file

**A pytest primer.**
- A **test** is a function whose name starts with `test_`. pytest finds it, calls it, and reports "passed" if it ends without an error. The keyword `assert condition` raises an error when the condition is false; so each `assert` is one thing the test insists must be true.
- A **fixture** is a function marked `@pytest.fixture` that prepares something a test needs. A test asks for it by writing its name as a parameter; pytest calls the fixture and passes the result in. `scope="session"` means "make it once for the whole run", `scope="module"` "once per test file", no scope "once per test". `autouse=True` means "apply it to every test without being asked".
- A **marker** is a label on tests (`@pytest.mark.cluster`). `pytest -m "not cluster"` runs only tests without the label.
- A file named `conftest.py` is read automatically by pytest; fixtures defined there are available to all tests next to it.
- The tests are of two kinds. **Unit tests** (`tests/unit/`) need no cluster: they use fakes. **Cluster tests** (`tests/cluster/`, `tests/compare/`) run the real scripts against a running cluster.


#### `tests/conftest.py`: shared fixtures

```python
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

```

- Docstring, imports, `ROOT` (the repository folder, found from this file's path) and `STAGES`. The hook `pytest_collection_modifyitems` adds the `cluster` marker to every test under `tests/cluster`, so `-m "not cluster"` selects the offline tests.

```python
def provider() -> str:
    """The context prefix of the cluster provider `make up` used: k3d or kind."""
    contexts = run(["kubectl", "config", "get-contexts", "-o", "name"], check=False).stdout.split()
    return "k3d" if "k3d-fleet-hub" in contexts else "kind"


@pytest.fixture(scope="session")
def root() -> Path:
    """The repository root."""
    return ROOT


@pytest.fixture(scope="session")
def hub() -> Kube:
    """kubectl pinned to the hub; the tests need `make up` to have run."""
    client = Kube(f"{provider()}-fleet-hub")
    if client.kubectl("get", "namespace", "argocd", check=False).returncode != 0:
        pytest.fail("the fleet is not up: run `make up` first", pytrace=False)
    return client


@pytest.fixture(scope="session")
def clusters(hub: Kube) -> dict[str, Kube]:
    """kubectl for each workload cluster, by stage."""
    return {stage: Kube(f"{provider()}-fleet-{stage}") for stage in STAGES}
```

- `provider()` returns `k3d` if the `kubectl` context `k3d-fleet-hub` exists, else `kind` (it reads `kubectl config get-contexts -o name`). The fixture `root` hands out the repository folder. `hub` creates a `Kube` pinned to the hub's context and fails with a clear message if the `argocd` namespace is missing (the fleet is not up). `clusters` returns a dictionary of one `Kube` per stage (a **dictionary comprehension**).

```python
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
```

- `class Runbook` runs the repository's scripts as a person would. `script(relative, *args, check=True, timeout=1800)` returns everything the script printed. `try_script` runs a script that **may fail on purpose** and returns `(exit status, output)`. `clone` is the working clone's path; `git(*args)` runs Git in it; `head()` is the newest commit of `main`; `stage_revision(stage)` reads `revision:` from `clusters/<stage>.yaml` as committed on `main` (`git show main:clusters/<stage>.yaml`, then the first line that starts with `revision:`; `line.split(":", 1)[1].strip()` keeps the part after the first colon; `raise AssertionError(…)` if there is none). The `runbook` fixture creates one.

#### `tests/cluster/conftest.py`

```python
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
```

- `_settled(hub, stage)` is true when `web-<stage>` is Synced and Healthy. The module-scoped fixture `settled` waits (up to 5 minutes each, `wait_until`) for all three stages before a test file starts; `partial(_settled, hub, stage)` makes a new function with the first arguments already filled in (`functools.partial`), because `wait_until` needs a function with no arguments. The function-scoped fixture `window_closed` runs `window.sh closed` so production's sync window is twelve hours away.

#### `tests/cluster/test_01_generator.py`

```python
"""Step 2: one Application per registered cluster, and a fourth cluster adds one with no new manifest."""

from __future__ import annotations

from tests.conftest import Runbook
from tests.support.kube import Kube
from tests.support.waiting import wait_until


def test_the_three_applications_were_generated_not_written(hub: Kube) -> None:
    assert hub.list_names("applications", "argocd", "app=web") == ["web-dev", "web-production", "web-staging"]

    owners = hub.get("application", "web-dev", "argocd")["metadata"]["ownerReferences"]
    assert [(owner["kind"], owner["name"]) for owner in owners] == [("ApplicationSet", "web-fleet")]


def test_each_application_points_at_its_own_cluster_and_its_stage_project(hub: Kube) -> None:
    servers = {stage: hub.application(f"web-{stage}").server for stage in ("dev", "staging", "production")}

    assert all(servers[stage].startswith("https://") and f"fleet-{stage}" in servers[stage] for stage in servers)
    assert all(server.endswith(":6443") for server in servers.values())
    projects = {stage: hub.get("application", f"web-{stage}", "argocd")["spec"]["project"] for stage in servers}
    assert projects == {"dev": "dev", "staging": "staging", "production": "production"}


def test_only_dev_follows_main_and_the_later_stages_are_pinned(hub: Kube, runbook: Runbook) -> None:
    assert hub.application("web-dev").target_revision == "main"
    assert hub.application("web-staging").target_revision == runbook.stage_revision("staging")
    assert hub.application("web-production").target_revision == runbook.stage_revision("production")
    assert runbook.stage_revision("staging") != "main"


def test_a_fourth_cluster_gets_an_application_with_no_new_manifest_and_leaves_with_it(
    hub: Kube, runbook: Runbook
) -> None:
    before = hub.list_names("applications", "argocd", "app=web")
    try:
        runbook.script("runbook/02-generate-apps.sh", "add")
        assert hub.list_names("applications", "argocd", "app=web") == sorted([*before, "web-demo4"])
        state = hub.application("web-demo4")
        assert (state.sync_status, state.health_status) == ("Synced", "Healthy")
    finally:
        runbook.script("runbook/02-generate-apps.sh", "remove", check=False)

    wait_until(
        "web-demo4 to be gone",
        lambda: hub.list_names("applications", "argocd", "app=web") == before,
        timeout=60,
    )
```

- Test 1: the three Applications `web-dev`, `web-production`, `web-staging` exist, and the first is **owned by** the ApplicationSet `web-fleet` (`metadata.ownerReferences` records who created an object): they were generated, not written. Test 2: each Application's destination is an `https://…:6443` address containing `fleet-<stage>` and its project is the stage's project. Test 3: only dev follows `main`; the others are pinned to the commit written in their stage files. Test 4: registering a fourth cluster (`02-generate-apps.sh add`) adds `web-demo4` that becomes Synced and Healthy; the `try … finally` block runs `remove` even if an assert fails; afterwards `wait_until` the list is back to the original.

#### `tests/cluster/test_02_waves.py`

```python
"""Step 3: waves with a health gate, and a production sync window."""

from __future__ import annotations

import pytest

from tests.conftest import Runbook
from tests.support.kube import Kube
from tests.support.waiting import wait_until


@pytest.fixture(scope="module", autouse=True)
def closed_window(settled: None, runbook: Runbook) -> None:
    runbook.script("runbook/window.sh", "closed")


def test_a_good_change_goes_dev_then_staging_and_waits_outside_the_window(
    hub: Kube, clusters: dict[str, Kube], runbook: Runbook
) -> None:
    runbook.script("runbook/03-waves.sh", "good")
    change = (runbook.clone / ".." / "good-commit").resolve().read_text().strip()

    assert clusters["dev"].image("web", "web") == "plainround/web:1.1.0"
    assert clusters["staging"].image("web", "web") == "plainround/web:1.1.0"
    assert hub.application("web-staging").applied_revision == change
    # Production is pinned to the commit but must not have applied it: the window is closed.
    # The ApplicationSet controller notices the new pin on its own schedule, so wait for the Application to carry it.
    wait_until(
        "web-production to carry the pinned commit",
        lambda: hub.application("web-production").target_revision == change,
        timeout=300,
    )
    wait_until(
        "web-production to be OutOfSync",
        lambda: hub.application("web-production").sync_status == "OutOfSync",
        timeout=300,
    )
    production = hub.application("web-production")
    assert production.target_revision == change
    assert production.sync_status == "OutOfSync"
    assert production.applied_revision != change
    assert clusters["production"].image("web", "web") == "plainround/web:1.0.0"


def test_a_good_change_outside_the_window_is_applied_once_the_window_opens(
    hub: Kube, clusters: dict[str, Kube], runbook: Runbook
) -> None:
    runbook.script("runbook/03-waves.sh", "open")

    wait_until(
        "production to run 1.1.0",
        lambda: clusters["production"].image("web", "web") == "plainround/web:1.1.0",
        timeout=120,
    )
    assert hub.application("web-production").sync_status == "Synced"


def test_a_change_that_fails_its_health_check_in_dev_never_reaches_staging_or_production(
    hub: Kube, clusters: dict[str, Kube], runbook: Runbook
) -> None:
    staging_before = hub.application("web-staging").target_revision
    production_before = hub.application("web-production").target_revision

    output = runbook.script("runbook/03-waves.sh", "bad")

    assert hub.application("web-dev").health_status == "Degraded"
    assert hub.application("web-staging").target_revision == staging_before
    assert hub.application("web-production").target_revision == production_before
    assert "pinned to" in output
    assert hub.application("web-staging").health_status == "Healthy"


def test_git_revert_returns_dev_to_healthy(hub: Kube, runbook: Runbook) -> None:
    runbook.script("runbook/03-waves.sh", "revert")

    assert hub.application("web-dev").health_status == "Healthy"
```

- The module fixture `closed_window` (`autouse=True`: applied to every test without being asked) waits for the stages to settle and closes production's window. Test 1: a good change reaches dev and staging (image `1.1.0`), staging's applied revision is the new commit, and production is **pinned** to it but `OutOfSync`, has not applied it and still runs `1.0.0`: the window is closed. Test 2: after `03-waves.sh open`, `wait_until` production runs `1.1.0` and is Synced. Test 3: a change that fails its health check in dev: dev is `Degraded`, the pins of staging and production did **not** move, the script says "pinned to" and staging is still Healthy. Test 4: `git revert` returns dev to Healthy.

- Changed after the first live run: the second test no longer reads production's Application at once after the script returns. The Application's `targetRevision` comes from the ApplicationSet, which notices a new pin in `clusters/production.yaml` on its own schedule (it can take a minute), so the test waits (`wait_until`, up to five minutes) first until the Application carries the pinned commit and then until it reports `OutOfSync`. The first live run failed because the test read the old pin (`5b2b647...`) instead of the new one.

#### `tests/cluster/test_03_policy.py`

```python
"""Step 4: one admission policy in every cluster refuses a privileged pod and a foreign image, in its own words."""

from __future__ import annotations

from functools import partial

import pytest

from tests.conftest import STAGES, Runbook
from tests.support.kube import Kube
from tests.support.shell import run
from tests.support.waiting import wait_until


def gave_up(hub: Kube, stage: str) -> bool:
    """Whether the controller has given up the stage's sync (Failed or Error)."""
    return hub.application(f"web-{stage}").operation_phase in {"Failed", "Error"}


@pytest.fixture(scope="module", autouse=True)
def open_window(settled: None, runbook: Runbook) -> None:
    runbook.script("runbook/window.sh", "open")


def test_the_policy_is_installed_in_every_cluster_by_the_applicationset(hub: Kube, clusters: dict[str, Kube]) -> None:
    assert hub.list_names("applications", "argocd", "app=policy") == [f"policy-{stage}" for stage in sorted(STAGES)]
    for kube in clusters.values():
        assert kube.exists("validatingadmissionpolicy", "no-privileged-or-foreign-images")
        assert kube.exists("validatingadmissionpolicybinding", "no-privileged-or-foreign-images")


@pytest.mark.parametrize(
    ("kind", "message"),
    [("privileged", "privileged containers are not allowed"), ("foreign", "images must come from plainround/")],
)
def test_a_refused_commit_fails_the_sync_in_every_cluster_with_the_policys_message(
    hub: Kube, clusters: dict[str, Kube], runbook: Runbook, kind: str, message: str
) -> None:
    output = runbook.script("runbook/04-policy.sh", kind)

    for stage in STAGES:
        # The controller retries a refused sync five times with a growing delay (about five minutes). Dev follows main, so
        # it goes through that twice: once for the bad commit and once for the commit that pins the later stages.
        wait_until(f"web-{stage} to give up the sync", partial(gave_up, hub, stage), timeout=1200)
        state = hub.application(f"web-{stage}")
        assert message in state.operation_message
        assert message in output
        assert "ValidatingAdmissionPolicy" in state.operation_message
    runbook.script("runbook/04-policy.sh", "revert")


def test_no_cluster_ever_ran_the_refused_manifest(clusters: dict[str, Kube]) -> None:
    for kube in clusters.values():
        assert kube.image("web", "web").startswith("plainround/web:")


def test_a_privileged_pod_is_refused_with_no_controller_involved(clusters: dict[str, Kube]) -> None:
    for kube in clusters.values():
        result = run(
            [
                "kubectl",
                "--context",
                kube.context,
                "-n",
                "default",  # the web namespace's stricter PodSecurity label answers first, in its own words
                "run",
                "attacker",
                "--image=plainround/web:1.0.0",
                "--privileged",
                "--restart=Never",
            ],
            check=False,
        )

        assert result.returncode != 0
        assert "privileged containers are not allowed" in result.output
```

- The fixture `open_window` opens production's window so production tries the sync too. Test 1: the policy objects exist in every cluster, and there are three `policy-<stage>` Applications. Test 2 (parametrized over two bad commits: `privileged` and `foreign`): in every stage the sync phase is `Failed` or `Error` and the failure message contains the policy's own text and the words `ValidatingAdmissionPolicy`; then the revert runs. Test 3: no cluster ever ran the refused manifest (the image is still `plainround/web:…`). Test 4: `kubectl run attacker --privileged` directly in each cluster is refused with the policy's message; the long list of strings is the command as separate words.

- Changed after the live runs: (1) the test waits (`wait_until` with `gave_up`, up to 20 minutes) until each stage's operation phase reads `Failed` or `Error`. Argo CD retries a refused sync five times with a growing delay, about five minutes, and dev, which follows `main`, goes through that twice, once for the bad commit and once for the commit that pins the later stages; a ten-minute wait ended four seconds too early. `gave_up` is a small named function and `functools.partial(gave_up, hub, stage)` fixes its arguments in advance (a lambda in a loop would trip the type checker and hide the loop variable). (2) The last test runs `kubectl run --privileged` in the `default` namespace: the `web` namespace has the stricter PodSecurity label, which refuses the pod first with `violates PodSecurity "restricted:latest"` and never shows the policy's text.

#### `tests/cluster/test_04_destructive_commit.py`

```python
"""Step 5: a commit that deletes the namespace manifest deletes nothing; the controller flags it; revert clears it."""

from __future__ import annotations

import pytest

from tests.conftest import STAGES, Runbook
from tests.support.kube import Kube


@pytest.fixture(scope="module", autouse=True)
def open_window(settled: None, runbook: Runbook) -> None:
    runbook.script("runbook/window.sh", "open")


def test_the_deletion_leaves_the_namespace_and_the_workloads_running_and_the_controller_flags_it(
    hub: Kube, clusters: dict[str, Kube], runbook: Runbook
) -> None:
    runbook.script("runbook/05-destructive-commit.sh", "commit")

    for stage in ("production", "dev"):
        state = hub.application(f"web-{stage}")
        assert state.sync_status == "OutOfSync"
        assert "Namespace/web" in state.pending_prune
        namespace = clusters[stage].get("namespace", "web")
        assert namespace["status"]["phase"] == "Active"
        assert "deletionTimestamp" not in namespace["metadata"]
        assert clusters[stage].deployment("web", "web")["status"]["readyReplicas"] == 2


def test_git_revert_clears_the_difference_everywhere(hub: Kube, runbook: Runbook) -> None:
    runbook.script("runbook/05-destructive-commit.sh", "revert")

    for stage in STAGES:
        state = hub.application(f"web-{stage}")
        assert (state.sync_status, state.health_status) == ("Synced", "Healthy")
        assert state.pending_prune == ()
```

- After `05-destructive-commit.sh commit`, for production and dev: the Application is `OutOfSync`, `Namespace/web` is in `pending_prune`, the namespace is still `Active` with no `deletionTimestamp`, and two replicas are ready: nothing was deleted. After `revert`, every stage is Synced and Healthy with nothing pending.

#### `tests/cluster/test_05_controller_outage.py`

```python
"""Step 6: losing the controller pauses reconciliation, not the app; drift made meanwhile is corrected on return."""

from __future__ import annotations

import os

import pytest

from tests.conftest import Runbook
from tests.support.kube import Kube


@pytest.fixture(scope="module")
def open_window(runbook: Runbook) -> None:
    """Production's window is open: the correction after the outage is a sync, which a closed window holds."""
    runbook.script("runbook/window.sh", "open")


@pytest.fixture(scope="module", autouse=True)
def stable(open_window: None, settled: None) -> None:
    """The window opens first, then the fleet must be settled (a production left in drift settles only inside it)."""
    return None


def test_the_app_serves_throughout_and_drift_is_corrected_when_the_controller_returns(
    hub: Kube, clusters: dict[str, Kube], runbook: Runbook
) -> None:
    seconds = os.environ.get("OUTAGE_SECONDS", "90")

    output = runbook.script("runbook/06-controller-outage.sh", seconds, timeout=int(seconds) + 900)

    assert "mid-outage drift: replicas=4" in output
    assert "end of outage: replicas=4" in output  # nothing reconciled while the controller was down
    assert "drift corrected" in output
    assert clusters["production"].replicas("web", "web") == 2
    log = (runbook.root / "logs" / "outage-traffic.log").read_text().split()
    assert len(log) >= int(seconds)
    assert set(log) == {"200"}, f"non-200 responses during the outage: {set(log) - {'200'}}"
    assert hub.application("web-production").sync_status == "Synced"
```

- The fixture `stable` waits for settled stages and returns nothing. The test reads `OUTAGE_SECONDS` from the environment (default `90`), runs the outage script with a timeout longer than the outage, and asserts: the drift was applied (`mid-outage drift: replicas=4`), nothing reconciled while the controller was down (`end of outage: replicas=4`), the drift was corrected, production is back to 2 replicas, the traffic log has at least as many lines as the outage had seconds, **every** line is `200` (the application served throughout) and production is Synced.

- Changed after the live runs: the module now opens production's sync window before it checks that the fleet is settled. The correction of drift after the outage is itself a sync, and production's sync window (one hour of the day) holds back every sync outside it: one run crossed an hour boundary during the outage, the window closed, and the drift stayed. The window fixture `open_window` runs `window.sh open` (the window of the current hour); the autouse fixture `stable` lists `open_window` before `settled` in its parameters, and pytest builds the fixtures left to right, so the window opens first and a production left in drift by an earlier failure can settle. (A test that straddles an hour boundary can still lose the window; a rerun fixes it.)


#### `tests/unit/test_best_case.py`

```python
"""Step 1: the design states how long a change takes to reach production at best, computed from the repository."""

from __future__ import annotations

import re
from pathlib import Path

from tests.support.shell import run


def seconds_in(output: str) -> int:
    match = re.search(r"= (\d+)s", output)
    assert match is not None, output
    return int(match.group(1))


def number(path: Path, pattern: str) -> int:
    match = re.search(pattern, path.read_text())
    assert match is not None
    return int(match.group(1))


def test_the_configured_best_case_is_one_poll_two_requeues_and_two_observation_windows(root: Path) -> None:
    output = run([str(root / "scripts/best-case.sh")]).stdout

    poll = number(root / "platform/argocd/controller-settings.yaml", r"timeout\.reconciliation: (\d+)s")
    requeue = number(root / "manifests/hub/appset-web.yaml", r"requeueAfterSeconds: (\d+)")
    dev = number(root / "manifests/clusters/dev.yaml", r"observeSeconds: (\d+)")
    staging = number(root / "manifests/clusters/staging.yaml", r"observeSeconds: (\d+)")
    assert seconds_in(output) == poll + dev + requeue + staging + requeue
    assert "what stops it" in output


def test_the_lesson_numbers_give_sixteen_minutes_forty_seconds_through_git(root: Path) -> None:
    output = run([str(root / "scripts/best-case.sh"), "--lesson"]).stdout

    assert seconds_in(output) == 60 + 300 + 20 + 600 + 20
    assert "16 min 40 s" in output
```

- `seconds_in(output)` finds `= 135s` in the script's output with a regular expression and returns the number; `number(path, pattern)` reads a number out of a file. Test 1: the configured best case equals the poll interval + dev observation + requeue + staging observation + requeue, each read from its own file. Test 2: with the lesson's numbers it is 60 + 300 + 20 + 600 + 20 = 1000 seconds and the text says `16 min 40 s`.

#### `tests/unit/test_check_clusters.py`

```python
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
```

- `tree_from` copies the `manifests` folder so a test can damage the copy; `edit(path, **changes)` loads a YAML file, updates keys and writes it back. Tests: the shipped files are well formed; a missing stage file is reported; a parametrized test names each malformed field (wrong stage, empty revision, `"yes"` for prune, negative or boolean `observeSeconds`); production must not prune; a sync window that disagrees with the project is reported; a window in the wrong format is reported; a window that wraps midnight (`23:00-00:00`) is compared modulo 24 hours, so changing the project's cron hour to 23 makes it valid; and `main` returns 1, 0 or 2.

#### `tests/unit/test_kube.py`

```python
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
```

- `FakeKubectl` is a fake runner that answers from canned JSON (an Application with a pending prune, a Deployment) and records every command. Tests: the Application state is read correctly (statuses, revisions, applied revision, pending prune, server); an Application without a status reads as empty strings and an empty tuple; the Deployment helpers; `list_names` strips the kind and sorts and passes the selector (`-l`); `exists` is True/False.

#### `tests/unit/test_manifests.py`

```python
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
```

- `load(root, relative)` parses a manifest file into a list of dictionaries. The fixture `app` builds the application base with `kubectl kustomize`. Tests: the app is the four objects; the namespace has the annotation `argocd.argoproj.io/sync-options: Prune=false`; the Service is a NodePort on 30080; the Deployment has two replicas, an image from `plainround/` and no `privileged` setting; the web ApplicationSet is a matrix of a cluster selector and a git file path with the template names; every Application self-heals and gets `prune` from the stage file; the policy ApplicationSet uses the same cluster selector; only production has a sync window; every project allows only the fleet repository; the policy has the two messages, denies, and fails closed; it covers Deployments and Pods; its binding leaves system namespaces alone; the committed stage files name `main` and the seed script pins the later stages; the Argo CD version in the Kustomize file equals `versions.env`.

#### `tests/unit/test_shell.py` and `tests/unit/test_waiting.py`

#### `tests/unit/test_shell.py`

```python
from __future__ import annotations

import pytest

from tests.support.shell import CommandError, run


def test_run_returns_output_and_status() -> None:
    result = run(["sh", "-c", "echo out; echo err >&2; exit 0"])

    assert (result.returncode, result.stdout, result.stderr) == (0, "out\n", "err\n")
    assert result.output == "out\nerr\n"
```

- Test 1 runs `sh -c "echo out; echo err >&2; exit 0"`, a tiny shell program that prints one line to each output stream and exits with 0. The assert compares a triple: exit code `0`, standard output `"out\n"`, standard error `"err\n"`. `result.output` must be the two joined.

```python
def test_a_failing_command_raises_with_its_output() -> None:
    with pytest.raises(CommandError) as raised:
        run(["sh", "-c", "echo broken >&2; exit 3"])

    assert raised.value.result.returncode == 3
    assert "broken" in str(raised.value)
```

- Test 2: `with pytest.raises(CommandError) as raised:` says "an error of this kind **must** happen inside this block; the test fails if it does not". The command exits with code 3. Afterwards the test checks the error carries the result (exit code 3) and that its text contains `broken`.

```python
def test_check_false_returns_the_failure_instead_of_raising() -> None:
    assert run(["sh", "-c", "exit 4"], check=False).returncode == 4
```

- Test 3: with `check=False` no error is raised; the exit code `4` comes back.

```python
def test_a_command_that_runs_too_long_is_reported_as_timed_out() -> None:
    with pytest.raises(CommandError, match=r"timed out after 0\.2s"):
        run(["sleep", "5"], timeout=0.2)
```

- Test 4: `sleep 5` with a timeout of `0.2` seconds must raise `CommandError` whose message matches the pattern `timed out after 0\.2s` (the backslash makes the dot a literal dot in the regular expression).

#### `tests/unit/test_waiting.py`

```python
from __future__ import annotations

import pytest

from tests.support.shell import CommandError, CommandResult
from tests.support.waiting import WaitTimeout, wait_until

```

- Imports, including the real `wait_until` and `WaitTimeout`.

```python
class FakeClock:
    """A clock that only moves when the code sleeps."""

    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds
```

- `FakeClock` is a clock that moves only when the code sleeps. `__call__` makes an object callable like a function (`clock()` returns `now`); `sleep` adds the seconds to `now`. With it, the test passes `clock=clock, sleep=clock.sleep`, and no real time passes.

```python
def test_returns_the_probe_value_as_soon_as_it_is_truthy() -> None:
    clock = FakeClock()
    answers = iter([None, False, "ready"])

    value = wait_until("the answer", lambda: next(answers), timeout=30, interval=2, clock=clock, sleep=clock.sleep)

    assert value == "ready"
    assert clock.now == 4.0
```

- `iter([None, False, "ready"])` makes an iterator; `next(answers)` returns the next item each call. The probe answers "nothing", "no", then "ready". With an interval of 2 seconds, `wait_until` must return `"ready"` after two sleeps: the fake clock must read `4.0`.

```python
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
```

- A probe that fails with `CommandError` twice, then returns True. The test shows a failing command counts as "not yet": `wait_until` returns `True` and the probe was called exactly three times. `calls = {"count": 0}` is a dictionary used as a counter that the inner function can change.

```python
def test_times_out_and_says_what_it_last_saw() -> None:
    clock = FakeClock()

    with pytest.raises(WaitTimeout, match=r"timed out after 10s waiting for the sync: the probe returned False"):
        wait_until("the sync", lambda: False, timeout=10, interval=3, clock=clock, sleep=clock.sleep)

    assert clock.now >= 10
```

- A probe that is always False with a 10-second timeout: `pytest.raises(WaitTimeout, match=…)` demands the message `timed out after 10s waiting for the sync: the probe returned False`. The clock must have passed 10 seconds.

```python
def test_a_bug_in_the_probe_is_not_swallowed() -> None:
    clock = FakeClock()

    def probe() -> bool:
        raise KeyError("status")

    with pytest.raises(KeyError):
        wait_until("anything", probe, timeout=10, clock=clock, sleep=clock.sleep)
```

- A probe that raises `KeyError` (a bug in the test, not a `CommandError`) must **not** be swallowed: `wait_until` lets it escape and the test expects exactly that.
<!-- full-walkthrough:end -->

## 6. Try it yourself

1. `make test-offline` : 41 pass.
2. `.venv/bin/pytest tests/unit -q -v | head -30` : one line per test.
3. `.venv/bin/pytest -m cluster --collect-only -q` : the cluster tests.
4. `.venv/bin/pytest tests/unit -q -k best_case` : the arithmetic.
5. `.venv/bin/pytest tests/unit -q --cov --cov-report=term-missing` : coverage lines.

## 7. Mistakes people make

- Tests that depend on the order they run in. Here each cluster module resets the demo first.
- Real sleeps in tests. The waiting helper takes an injected clock, so its tests take no time.
- Marking a test "skip" to make a run green. A skip hides a real failure.

## 8. Check yourself

1. How does pytest find tests?
   *Answer:* Files named `test_*.py` and functions named `test_*`.
2. What is a fixture?
   *Answer:* A function that builds something a test needs, passed in by parameter name.
3. What does `-m "not cluster"` do?
   *Answer:* It runs only tests that do not carry the `cluster` marker.
4. What makes a test fail?
   *Answer:* An exception, usually from a false `assert`.
5. What does `fail_under = 90` do?
   *Answer:* It fails the run when less than 90 percent of the measured lines ran.

## 9. Further reading

- pytest documentation: <https://docs.pytest.org/en/stable/> (version 9). pytest-cov: <https://pytest-cov.readthedocs.io/>.
