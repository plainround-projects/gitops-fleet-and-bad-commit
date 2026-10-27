# Python

## 1. What it is

Python is a general-purpose programming language. In this repository it is used for the **tests** and the small helpers behind them, not for the application itself. Version 3.12 or newer is required.

## 2. Why this repository uses it

Python appears as the **stage-file checker** (`scripts/check_clusters.py`) and as the **tests** with their helpers.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `scripts/check_clusters.py` | validates `clusters/<stage>.yaml` and the sync window |
| `tests/support/shell.py, waiting.py` | identical to the first project's |
| `tests/support/kube.py` | typed reads of the hub's Applications |
| `tests/conftest.py, tests/unit/*.py` | fixtures and tests |

## 4. How it works underneath

- `python script.py` starts the interpreter, which compiles the file to bytecode in memory and runs it. A **module** is one `.py` file; a **package** is a folder of modules (with `__init__.py`).
- **Type hints** (`def f(x: int) -> str`) are labels for people and for checkers such as mypy. Python does not enforce them when it runs.
- A **dataclass** (`@dataclass(frozen=True)`) generates `__init__` and comparison methods for a class that is just named fields; `frozen` makes it read-only.
- `from __future__ import annotations` stores hints as text so they can refer to names defined later.
- A **context manager** (`with ...:`) runs set-up and clean-up around a block. A **generic function** such as `def wait_until[T](...)` (Python 3.12 syntax) works for any type `T` and returns the same type it was given.
- `subprocess.run([...])` starts another program and captures its output. A list of arguments (not one string) avoids shell-quoting mistakes.

## 5. Walkthrough of this repository's use

`shell.py` (`run`, `CommandResult`, `CommandError`) and `waiting.py` (`wait_until`) are byte-identical to the first project's; read its Python note.

### `tests/support/kube.py`
`ApplicationState` is a frozen dataclass with `name`, `sync_status`, `health_status`, `revision`, `target_revision`, `operation_phase`, `applied_revision`, `pending_prune` and `server`. `Kube` takes an injectable runner and reads Applications on the hub. `pending_prune` is a `tuple[str, ...]` of `Kind/name` strings built from `status.resources` entries with `requiresPruning`.

### `scripts/check_clusters.py`
```python
STAGES = ("dev", "staging", "production")
WINDOW = re.compile(r"^(\d{2}):00-(\d{2}):00 UTC$")

def stage_problems(stage: str, document: dict[str, Any]) -> Iterator[str]:
    if document.get("stage") != stage:
        yield f"{stage}: stage must be {stage!r}, found {document.get('stage')!r}"
    ...
    seconds = document.get("observeSeconds")
    if not isinstance(seconds, int) or isinstance(seconds, bool) or seconds < 0:
        yield f"{stage}: observeSeconds must be a non-negative integer"
    if stage == "production" and document.get("prune") is not False:
        yield "production: prune must be false"
```
A **generator** function: each `yield` produces one message. `isinstance(seconds, bool)` is checked separately because in Python `True` is an `int`. The compiled regular expression `WINDOW` matches text like `22:00-23:00 UTC`; its two groups are the start and end hours.

```python
def window_problems(root: Path, document: dict[str, Any]) -> Iterator[str]:
    ...
    projects = [p for p in yaml.safe_load_all((root / "hub/projects.yaml").read_text()) if p]
    production = next(p for p in projects if p["metadata"]["name"] == "production")
    expected = f"0 {start} * * *"
    duration = f"{(end - start) % 24}h"
```
Loads the AppProject documents (a **list comprehension** with a filter), finds production with `next(... for ... if ...)`, and computes the cron string and duration the stage file implies (`% 24` wraps past midnight). If the project differs, a message says so. `check(root)` loops over stages, `main(argv)` prints problems to standard error and returns 1 or 0.

<!-- full-walkthrough:begin -->
### 5.A Full walkthrough: every Python helper and the stage-file checker

**A Python primer for these files.**
- A Python file is a list of statements that run from top to bottom. A line that starts with `#` is a comment. A text in three quotes `"""…"""` at the very top of a file, class or function is a **docstring**: a description for people that Python keeps attached to the thing.
- `import name` makes the code of another file available. `from package import thing` imports one item from it. A **module** is one `.py` file. A **package** is a folder of modules (`tests/support/` is one).
- A **function** is a named recipe: `def name(arguments):` followed by indented lines. Everything indented under it belongs to it (Python uses indentation, not braces). `return value` hands a value back.
- A **type hint** writes the kind of value after a name: `name: str` says "name is text", `-> int` says "this function returns a whole number". Python does not check hints when it runs; a separate tool (mypy) reads them before. Common kinds: `str` text, `int` whole number, `float` number with a fraction, `bool` True/False, `list[str]` a list of texts, `dict[str, int]` a table from texts to numbers, `tuple[str, ...]` a fixed list of texts of any length, `X | None` "an X or nothing".
- A **class** groups data and functions: `class Name:`. A function inside a class is a **method**; its first parameter `self` is the object it works on. `__init__` runs when you create an object.
- An **exception** is how Python reports an error. `raise Something(...)` raises one. `try: … except Something as name: …` catches it. A class can inherit from another: `class MyError(RuntimeError)` makes a new kind of error.
- An **f-string** is text with values inserted: `f"exited {code}"`. A **list comprehension** builds a list: `[x for x in items if x]`.
- A **dictionary** (`dict`) maps keys to values: `{"a": 1}`. `d.get("a", 0)` reads a key and returns 0 if it is missing.
- A **lambda** is a tiny unnamed function: `lambda: 5`.


#### `tests/support/__init__.py`

```python
"""Helpers the tests share: running commands, waiting for a condition, reading the controller's state."""
```

A file named `__init__.py` marks a folder as a Python package, so `from tests.support.kube import Kube` works. The only line is the docstring that says what the package holds.


#### `tests/support/shell.py`: run a program and report what it did

When a test needs to run another program (for example one of the repository's scripts), it should get back the exit code and the output, and get a clear error if the program failed. This file does that.

```python
"""Run external commands and report what they did, with typed results and a named error."""

from __future__ import annotations

import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path

```

- Line 1 is the module's docstring.
- `from __future__ import annotations` tells Python to keep type hints as plain text instead of evaluating them at once. That lets a hint mention a class defined later in the file.
- `import subprocess` loads Python's own module for starting other programs. A **subprocess** is a child process (see the Bash note).
- `from collections.abc import Mapping, Sequence` imports two names used only in type hints: a `Mapping` is anything that behaves like a dictionary, a `Sequence` is anything that behaves like a list.
- `from dataclasses import dataclass` imports a helper described just below.
- `from pathlib import Path` imports the `Path` class: an object that stands for a file or folder path.

```python
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

```

- `@dataclass(frozen=True)` is a **decorator**: a line starting with `@` that changes the class right below it. `dataclass` writes the boring parts of a class for you (the `__init__` method and a readable printout) from the list of fields. `frozen=True` makes objects **read-only** after they are created, so a result cannot be changed by mistake.
- `class CommandResult:` and its docstring: a class that holds the outcome of one finished command.
- The four lines `args`, `returncode`, `stdout`, `stderr` declare the **fields**: the command words (`tuple[str, ...]`), its exit code, what it printed on standard output, and what it printed on standard error (see the Bash note for these).
- `@property` turns the next method into something you read without parentheses (`result.output`). `output` returns the two texts joined, "the way a terminal shows them". The docstring inside the method says so.

```python
class CommandError(RuntimeError):
    """A command exited with a non-zero status (or did not finish in time)."""

    def __init__(self, result: CommandResult) -> None:
        """Keep the whole result so the test report shows what the command printed."""
        self.result = result
        command = " ".join(result.args)
        super().__init__(f"{command!r} exited {result.returncode}\n{result.output.strip()}")

```

- `class CommandError(RuntimeError)` creates a new kind of error that is a special case of `RuntimeError`. A named error lets a caller catch exactly this problem.
- `__init__(self, result)` runs when the error is created. It stores the whole result (`self.result = result`) so a test report can show what the command printed.
- `" ".join(result.args)` joins the command words with spaces into one line.
- `super().__init__(…)` calls the parent class's `__init__` with the error message. The message is an f-string: `{command!r}` inserts the command text with quotes around it (`!r` = "show it the way Python would write it in code"), `{result.returncode}` its exit code, `\n` a line break, and `result.output.strip()` the command's output without leading or trailing blank space.

```python
def run(
    args: Sequence[str],
    *,
    cwd: Path | None = None,
    env: Mapping[str, str] | None = None,
    check: bool = True,
    timeout: float = 300,
) -> CommandResult:
    """Run ``args`` and return the result; raise CommandError on a non-zero exit when ``check`` is set."""
```

- The function `run` has a long list of parameters, one per line. `args: Sequence[str]` is the command words. The lone `*` means everything after it **must be given by name** (`run(cmd, check=False)`), which makes calls readable.
- `cwd: Path | None = None` is the folder to run in, or nothing (`= None` is the default). `env: Mapping[str, str] | None = None` replaces the environment variables (see the Bash note), or nothing. `check: bool = True` says "treat a non-zero exit code as an error". `timeout: float = 300` is the longest time to wait, in seconds.
- `-> CommandResult` says what it returns. The docstring explains the behavior.

```python
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
```

- `try:` starts a block where an error may happen.
- `subprocess.run(…)` starts the program and waits for it to finish. `list(args)` copies the command words into a list. A list (not one long string) means each word is one argument and nothing is split or re-interpreted by a shell.
- `cwd=cwd` runs it in that folder. `env=None if env is None else dict(env)` uses the normal environment unless one was given (a conditional expression: `A if condition else B`).
- `capture_output=True` collects what the program prints instead of showing it. `text=True` gives text instead of raw bytes. `timeout=timeout` stops waiting after that time. `check=False` stops `subprocess` from raising an error by itself; this function does its own error handling.

```python
    except subprocess.TimeoutExpired as expired:
        stdout = expired.stdout.decode() if isinstance(expired.stdout, bytes) else (expired.stdout or "")
        result = CommandResult(tuple(args), 124, stdout, f"timed out after {timeout}s")
        raise CommandError(result) from expired
```

- `except subprocess.TimeoutExpired as expired:` runs if the program took longer than the timeout. The caught error is named `expired`.
- `expired.stdout` holds whatever the program printed before it was stopped. It may be raw bytes, text or nothing; the next line converts it to text: `decode()` turns bytes into text; `isinstance(x, bytes)` asks "is x bytes?"; `(expired.stdout or "")` means "the value, or empty text if there is none".
- A timeout is turned into a normal `CommandResult` with exit code `124` (the number the Unix `timeout` command uses) and the message `timed out after …s`, and then raised as a `CommandError`. `raise … from expired` keeps the original error attached as the cause.

```python
    result = CommandResult(tuple(args), completed.returncode, completed.stdout, completed.stderr)
    if check and result.returncode != 0:
        raise CommandError(result)
    return result
```

- If nothing went wrong, build a `CommandResult` from what `subprocess.run` returned (`completed.returncode`, `.stdout`, `.stderr`).
- `if check and result.returncode != 0:` means "if the caller wants errors and the exit code is not 0", then raise `CommandError`. Otherwise `return result` hands the result back.


#### `tests/support/waiting.py`: wait until something becomes true

A cluster does things in its own time. A test cannot say "do it, then check at once"; it must **wait** until the condition holds, but not forever. This function waits with a limit, and its clock and sleep can be replaced, so a test of the waiting itself needs no real waiting.

```python
"""Poll until a condition holds, with the clock and the sleep injected so the logic is testable."""

from __future__ import annotations

import time
from collections.abc import Callable

from tests.support.shell import CommandError


class WaitTimeout(AssertionError):
    """The condition did not hold within the time allowed."""

```

- The docstring says what the module does. `import time` loads the time functions. `from collections.abc import Callable` imports the hint for "something you can call like a function". `from tests.support.shell import CommandError` imports the error defined above.
- `class WaitTimeout(AssertionError)` is a new error for "waited too long". It inherits from `AssertionError`, the error a failed `assert` raises, so a test runner reports it as a test failure.

```python
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
```

- `def wait_until[T](` uses Python 3.12 **generic** syntax. `[T]` declares a placeholder type: whatever type the probe returns is the type this function returns. A generic function works for many types while staying checkable.
- `description: str` names what we wait for. `probe: Callable[[], T | None | bool]` is a function that takes no arguments and returns a value, nothing or a bool. `*` makes the rest keyword-only. `timeout: float` is the limit in seconds; `interval: float = 2.0` the pause between tries.
- `clock: Callable[[], float] = time.monotonic` and `sleep: Callable[[float], None] = time.sleep` are the **replaceable parts**. `time.monotonic` is a clock that only moves forward and cannot jump (unlike the wall clock). `time.sleep` pauses. A test passes fakes here.
- The docstring explains the rule for errors: a `CommandError` inside the probe (for example `kubectl get` for an object that does not exist yet) counts as "not yet"; any other error is a bug in the test and goes up.

```python
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
```

- `deadline = clock() + timeout` fixes the time at which to give up. `last_problem` remembers why the last try failed, for the final message.
- `while True:` loops forever until `return` or `raise` leaves it.
- Inside `try:`, `value = probe()` calls the probe. `if value:` is true for any "truthy" value (not `None`, `False`, `0`, empty); then `return value` ends the function and returns it. The comment `# type: ignore[return-value]` tells the type checker to skip this one line, because it cannot prove that a truthy `T | None | bool` is a `T`.
- If the value was falsy, remember that (`last_problem = f"the probe returned {value!r}"`).
- `except CommandError as error:` treats a failing command as "not yet" and remembers the first line of its message (`str(error).splitlines()[0]`).
- After each try, `if clock() >= deadline:` raises `WaitTimeout` with a message such as `timed out after 60s waiting for the app: …` (`{timeout:g}` prints the number without extra zeros). Otherwise `sleep(interval)` pauses before the next try.


#### `tests/support/kube.py`: read the hub and the clusters through `kubectl`

`kubectl` can print a Kubernetes object as **JSON**, a text format for structured data: `{"name": "web", "ports": [80, 443]}` is an *object* (curly braces, named values) holding a *list* (square brackets). `json.loads(text)` turns such text into Python dictionaries and lists.

```python
"""A small read-mostly view of the hub's Argo CD Applications and of the workload clusters, through kubectl."""

from __future__ import annotations

import json
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Any

from tests.support.shell import CommandResult, run

```

- The docstring and imports (`json`, the type hints, `dataclass`, `Any`, and `CommandResult` and `run` from `shell.py`).

```python
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

```

- A read-only dataclass `ApplicationState` holds what the hub's Argo CD reports about one Application: its `name`; the sync and health statuses; the `revision` Argo CD last compared; the `target_revision` the Application is **configured** to follow (`main` for dev, a commit hash for the pinned stages); the phase and message of the last sync operation; the `applied_revision` (the commit that last sync applied); `pending_prune` (the objects Argo CD wants to delete but may not, as `Kind/name` texts); and the `server` (the cluster the Application deploys to).

```python
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
```

- `class Kube` is `kubectl` pinned to one context so a test cannot touch another cluster. The **runner** (the function that runs commands) is passed in with a default: **dependency injection**, so unit tests give a fake. `kubectl(*args, check=True)` builds `["kubectl", "--context", <context>, *args]` and runs it with a two-minute limit.

```python
    def get(self, kind: str, name: str, namespace: str | None = None) -> dict[str, Any]:
        """Return one object as parsed JSON; raises CommandError when it does not exist."""
        scope = ["-n", namespace] if namespace else []
        parsed: dict[str, Any] = json.loads(self.kubectl("get", kind, name, *scope, "-o", "json").stdout)
        return parsed
```

- `get` fetches one object as JSON and parses it (`scope = ["-n", namespace] if namespace else []` adds the namespace flag only when given). A missing object makes `kubectl` fail, so `CommandError` is raised.

```python
    def list_names(self, kind: str, namespace: str | None = None, selector: str | None = None) -> list[str]:
        """The names of all objects of a kind (optionally filtered by a label selector), sorted."""
        scope = ["-n", namespace] if namespace else []
        label = ["-l", selector] if selector else []
        output = self.kubectl("get", kind, *scope, *label, "-o", "name").stdout
        return sorted(line.split("/", 1)[1] for line in output.split() if "/" in line)
```

- `list_names` lists the names of all objects of a kind, optionally filtered by a label selector (`-l key=value`), using `-o name`, whose output is `kind.group/name` per line. `line.split("/", 1)[1]` keeps the part after the first slash; `sorted(…)` orders the names.

```python
    def exists(self, kind: str, name: str, namespace: str | None = None) -> bool:
        """True when the object exists."""
        scope = ["-n", namespace] if namespace else []
        return self.kubectl("get", kind, name, *scope, check=False).returncode == 0
```

- `exists` is `True` when `kubectl get` succeeds (`check=False` so a missing object is an answer, not an exception).

```python
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
```

- `application` reads an Application of the hub's `argocd` namespace into an `ApplicationState`. Each `.get("x", {})` returns an empty dictionary when a level is missing (a new Application has no status yet). `pending_prune=tuple(f"{r['kind']}/{r['name']}" for r in resources if r.get("requiresPruning"))` builds a tuple of `Kind/name` texts from the resources that Argo CD says need pruning (a **generator expression** with a filter).

```python
    def deployment(self, namespace: str, name: str) -> dict[str, Any]:
        """A Deployment as parsed JSON."""
        return self.get("deployment", name, namespace)

    def replicas(self, namespace: str, name: str) -> int:
        """The replica count the Deployment asks for."""
        return int(self.deployment(namespace, name)["spec"]["replicas"])

    def image(self, namespace: str, name: str) -> str:
        """The image of the Deployment's first container."""
        return str(self.deployment(namespace, name)["spec"]["template"]["spec"]["containers"][0]["image"])
```

- `deployment` fetches a Deployment; `replicas` returns the replica count it asks for; `image` returns the first container's image (`["containers"][0]`).

#### `scripts/check_clusters.py`: the stage-file checker

A stand-alone script that tests also import. It checks the little per-stage data files that the ApplicationSet reads.

```python
#!/usr/bin/env python3
"""Check the per-stage files the ApplicationSet's Git generator reads.

    check_clusters.py <repository-root>

Each clusters/<stage>.yaml must name its own stage, a revision, a boolean ``prune`` and a non-negative
``observeSeconds``; production must declare a ``syncWindow`` equal to the one in hub/projects.yaml.
Exit status 0 means every file is well formed.
"""

from __future__ import annotations

import re
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import yaml

STAGES = ("dev", "staging", "production")
WINDOW = re.compile(r"^(\d{2}):00-(\d{2}):00 UTC$")


def stage_problems(stage: str, document: dict[str, Any]) -> Iterator[str]:
    """Yield one message per way a stage file is malformed."""
    if document.get("stage") != stage:
        yield f"{stage}: stage must be {stage!r}, found {document.get('stage')!r}"
    if not isinstance(document.get("revision"), str) or not document["revision"]:
        yield f"{stage}: revision must be a branch name or a commit"
    if not isinstance(document.get("prune"), bool):
        yield f"{stage}: prune must be true or false"
    seconds = document.get("observeSeconds")
    if not isinstance(seconds, int) or isinstance(seconds, bool) or seconds < 0:
        yield f"{stage}: observeSeconds must be a non-negative integer"
    if stage == "production" and document.get("prune") is not False:
        yield "production: prune must be false"


def window_problems(root: Path, document: dict[str, Any]) -> Iterator[str]:
    """Yield a message when production's syncWindow and the AppProject's window disagree."""
    match = WINDOW.match(str(document.get("syncWindow", "")))
    if match is None:
        yield "production: syncWindow must look like '22:00-23:00 UTC'"
        return
    start, end = int(match.group(1)), int(match.group(2))
    projects = [p for p in yaml.safe_load_all((root / "hub/projects.yaml").read_text()) if p]
    production = next(p for p in projects if p["metadata"]["name"] == "production")
    window = production["spec"]["syncWindows"][0]
    expected = f"0 {start} * * *"
    duration = f"{(end - start) % 24}h"
    found = (window["schedule"], window["duration"], window["kind"])
    if found != (expected, duration, "allow"):
        yield (
            f"production: hub/projects.yaml has {window['schedule']!r} for {window['duration']}, "
            f"expected {expected!r} for {duration}"
        )


def check(root: Path) -> list[str]:
    """Return every problem under ``root/clusters``."""
    problems: list[str] = []
    documents: dict[str, dict[str, Any]] = {}
    for stage in STAGES:
        path = root / "clusters" / f"{stage}.yaml"
        if not path.is_file():
            problems.append(f"{stage}: {path.name} is missing")
            continue
        documents[stage] = yaml.safe_load(path.read_text())
        problems.extend(stage_problems(stage, documents[stage]))
    if "production" in documents:
        problems.extend(window_problems(root, documents["production"]))
    return problems


def main(argv: list[str]) -> int:
    """Command-line entry point."""
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    problems = check(Path(argv[1]))
    for problem in problems:
        print(f"clusters: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- The docstring (lines 1-12) doubles as the usage text. `STAGES` is a tuple of the three stage names. `WINDOW = re.compile(r"^(\d{2}):00-(\d{2}):00 UTC$")` compiles a text pattern for a sync window such as `22:00-23:00 UTC`: two digits, `:00-`, two digits, `:00 UTC`; the parentheses **capture** the two hours (`re` is Python's regular-expression module; `r"…"` is a raw string so backslashes are kept).
- `stage_problems(stage, document)` is a **generator** (a function that `yield`s values one at a time). It yields a message for each problem: the file must name its own stage; `revision` must be a non-empty text; `prune` must be a real boolean (`isinstance(x, bool)`); `observeSeconds` must be a non-negative whole number (`isinstance(seconds, bool)` is checked separately because in Python `True` counts as an `int`); and production must have `prune: false`.
- `window_problems(root, document)` checks that production's `syncWindow` text matches the AppProject. `WINDOW.match(…)` applies the pattern; if it does not match, yield a message and `return`. Otherwise `start` and `end` are the two hours. It loads `hub/projects.yaml` (`yaml.safe_load_all` yields one dictionary per YAML document; `if p` skips empty ones), finds the project named `production` with `next(p for p in projects if …)`, and compares: expected schedule `f"0 {start} * * *"` (a cron expression: minute 0, hour `start`, every day) and duration `f"{(end - start) % 24}h"` (`% 24` wraps past midnight). If the project's `schedule`, `duration` and `kind` differ from those, it yields a message.
- `check(root)` loops over the three stages: a missing file is reported (`path.is_file()`); otherwise the file is parsed and `stage_problems` run; if the production file was read, `window_problems` runs too. It returns a list of messages.
- `main(argv)` is the command line: wrong arguments print the usage and return 2; otherwise it prints each problem on standard error and returns 1, or 0 when there are none. `if __name__ == "__main__": sys.exit(main(sys.argv))` runs it only when the file is run as a script.
<!-- full-walkthrough:end -->

## 6. Try it yourself

1. `.venv/bin/python scripts/check_clusters.py manifests` : exit status 0.
2. Change the schedule hour in a copy of `hub/projects.yaml` and rerun : `production: hub/projects.yaml has '0 23 * * *' for 1h, expected '0 22 * * *' for 1h`.
3. `.venv/bin/python -c "import re; print(re.match(r'^(\d{2}):00-(\d{2}):00 UTC$', '22:00-23:00 UTC').groups())"` : `('22', '23')`.
4. `.venv/bin/pytest tests/unit -q` : the offline tests.
5. `.venv/bin/mypy` : passes in strict mode.

## 7. Mistakes people make

- Installing packages into the system Python; use a virtual environment (see pip and venv).
- Mutable default arguments (`def f(x=[])`).
- Assuming type hints are checked at run time.
- Building a shell command as one string with user data inside; here the commands are lists.

## 8. Check yourself

1. Does Python check type hints when the program runs?
   *Answer:* No. A separate tool such as mypy checks them.
2. What does `frozen=True` do on a dataclass?
   *Answer:* It makes the instances read-only.
3. Why pass a list to `subprocess.run`?
   *Answer:* Each item is one argument, so no shell splitting or quoting is involved.
4. What is a module and what is a package?
   *Answer:* A module is one `.py` file; a package is a folder of modules.
5. What does `from __future__ import annotations` do?
   *Answer:* It keeps type hints as text, so they can name things defined later.

## 9. Further reading

- Python 3.13 documentation (this repository requires 3.12 or newer): <https://docs.python.org/3.13/>.
