# mypy

## 1. What it is

mypy reads Python type hints and reports places where the types do not fit, without running the code. With `strict = true` it also demands a hint on every function.

## 2. Why this repository uses it

The helpers are the foundation of the tests; typed code catches mistakes (a missing field, a wrong return) before a slow cluster run.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `pyproject.toml` | `[tool.mypy] strict = true`, `files = ["tests"]` |
| `Makefile` | `mypy` inside `lint` |
| `requirements-dev.lock` | `types-PyYAML` supplies PyYAML's types |

## 4. How it works underneath

- mypy builds a model of each function's inputs and outputs from the hints and checks every call against it.
- `Any` switches checking off for a value. Strict mode warns when `Any` leaks in.
- Libraries need type information: some ship it, others have a `types-<name>` package (`types-PyYAML` here).
- `# type: ignore[code]` silences one named error on one line.

## 5. Walkthrough of this repository's use

```toml
[tool.mypy]
python_version = "3.12"
strict = true
files = ["tests"]
```
`strict = true` is a bundle of options: every function needs annotations, no implicit `Any`, no untyped calls, unused ignores are errors. The code shows the typing features it needs: `Callable[..., CommandResult]` for an injectable runner, `dict[str, Any]` for parsed JSON, `tuple[str, ...]` for a variable-length tuple, `T | None | bool` unions, and a `# type: ignore[return-value]` in `wait_until` where mypy cannot prove that a truthy `T | None | bool` is a `T`.

### What differs here
```toml
files = ["tests", "scripts"]
explicit_package_bases = true
mypy_path = "scripts:."
```
`scripts/check_clusters.py` is Python too, so mypy checks `tests` and `scripts`. `mypy_path` and `explicit_package_bases` tell it where imports start.

## 6. Try it yourself

1. `.venv/bin/mypy` : `Success: no issues found in 22 source files` (the count may differ).
2. Change `-> int` to `-> str` on `deployment_replicas`, run `mypy` : an `Incompatible return value type` error.
3. `.venv/bin/mypy --strict --no-incremental tests/support/shell.py` : check one file.
4. `grep -rn 'type: ignore' tests | wc -l` : how many ignores exist (very few).
5. `.venv/bin/pip show types-PyYAML | head -2` : the stub package.

## 7. Mistakes people make

- Sprinkling `# type: ignore` to get green. Each one here names the exact error and is rare.
- Using `Any` to avoid describing a shape; a `TypedDict` or dataclass describes it.

## 8. Check yourself

1. Does mypy run your program?
   *Answer:* No. It reads the code and the hints only.
2. What does `strict = true` add?
   *Answer:* It demands annotations and warns about loose typing such as unneeded `Any`.
3. Why install `types-PyYAML`?
   *Answer:* PyYAML ships without type information; this package supplies it.
4. What does `# type: ignore[attr-defined]` do?
   *Answer:* Silences that one error code on that line.
5. Which folder does mypy check here?
   *Answer:* The folders listed in `files` in `pyproject.toml`.

## 9. Further reading

- mypy documentation: <https://mypy.readthedocs.io/en/stable/> (pinned 1.19.1).
