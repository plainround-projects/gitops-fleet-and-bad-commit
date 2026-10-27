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
