# TOML (pyproject.toml)

## 1. What it is

TOML is a simple configuration file format of `[tables]` and `key = value` lines. `pyproject.toml` is the standard file Python tools read for the project's name, dependencies and each tool's settings.

## 2. Why this repository uses it

One file configures pytest, coverage, ruff and mypy and pins the Python dependencies.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `pyproject.toml` | project metadata and tool tables |

## 4. How it works underneath

- `[project]` names the project and lists `dependencies`; `[project.optional-dependencies]` groups extras such as `dev`.
- `[tool.<name>]` tables hold the settings of pytest, coverage, ruff and mypy; each tool finds its own table.
- Values are strings in quotes, numbers, booleans (`true`), and arrays (`["a", "b"]`).
- Versions written `==x.y.z` are exact.

## 5. Walkthrough of this repository's use

The shape is the same as in the first project (`[project]` with `dependencies = ["pyyaml==6.0.3"]`, `[project.optional-dependencies] dev = [...]`, and `[tool.*]` tables). The differences: `pythonpath = [".", "scripts"]`, coverage `source = ["tests/support", "scripts"]`, mypy `files = ["tests", "scripts"]` with `explicit_package_bases = true` and `mypy_path = "scripts:."`, and the `ANN401` ignore for tests. Each table is explained in the note of its tool.

<!-- full-walkthrough:begin -->
### 5.A Full walkthrough: the whole `pyproject.toml`

**TOML** files are made of **tables**: a heading in square brackets followed by `key = value` lines. A dotted heading is a table inside a table. Values are text in quotes, numbers, `true`/`false`, or lists in square brackets.

```toml
[project]
name = "gitops-fleet-and-bad-commit-tests"
version = "0.1.0"
description = "Cluster and offline tests for the fleet-and-bad-commit GitOps project"
requires-python = ">=3.12"
dependencies = ["pyyaml==6.0.3"]

[project.optional-dependencies]
dev = ["pytest==9.0.2", "pytest-cov==7.0.0", "ruff==0.14.10", "mypy==1.19.1", "yamllint==1.38.0", "types-PyYAML==6.0.12.20250915"]

[tool.pytest.ini_options]
testpaths = ["tests"]
pythonpath = [".", "scripts"]
addopts = "-ra --strict-markers"
markers = [
  "cluster: needs the kind cluster from `make up` and runs the scripted runbook against it",
]

[tool.coverage.run]
source = ["tests/support", "scripts"]
branch = true

[tool.coverage.report]
show_missing = true
fail_under = 90

[tool.ruff]
line-length = 120
target-version = "py312"

[tool.ruff.lint]
select = ["E", "F", "I", "B", "UP", "SIM", "D", "ANN", "S", "PT", "RUF"]
ignore = ["D203", "D213"]

[tool.ruff.lint.per-file-ignores]
"tests/**" = ["S101", "S603", "S607", "D", "ANN401"]
"tests/support/**" = ["S101", "S603", "S607", "ANN401"]

[tool.mypy]
python_version = "3.12"
strict = true
files = ["tests", "scripts"]
explicit_package_bases = true
mypy_path = "scripts:."
```

- `[project]`: package name, version, description, `requires-python = ">=3.12"`, and `dependencies = ["pyyaml==6.0.3"]` (the one library the code needs, at an exact version). `[project.optional-dependencies]` `dev = […]` lists the development tools at exact versions: the test runner and its coverage plug-in, the linter/formatter, the type checker, the YAML checker and type information for PyYAML.
- `[tool.pytest.ini_options]`: `testpaths = ["tests"]` where to look; `pythonpath = [".", "scripts"]` where Python looks for imports (so a test can `import check_clusters`); `addopts = "-ra --strict-markers"` always-on options (`-ra` show a reason for every non-passing test; `--strict-markers` unknown labels are errors); `markers` registers the one label `cluster`.
- `[tool.coverage.run]`: measure the test helpers and the scripts (`source`), counting both ways of every `if` (`branch = true`). `[tool.coverage.report]`: `show_missing` prints missing lines; `fail_under = 90` fails below 90 percent.
- `[tool.ruff]`: line length 120 and the Python version. `[tool.ruff.lint]`: `select` turns on groups of rules by letter (E/F errors, I import order, B likely bugs, UP old syntax, SIM simplifications, D docstrings, ANN missing type hints, S security, PT pytest style, RUF extras); `ignore` turns off two docstring rules that contradict others. `per-file-ignores`: tests may use `assert` (S101), start programs (S603, S607), need no docstrings (D) and use the `Any` type (ANN401).
- `[tool.mypy]`: strict type checking of `tests` and `scripts`; `explicit_package_bases` and `mypy_path` say where imports start.
<!-- full-walkthrough:end -->

## 6. Try it yourself

1. `python3 -c "import tomllib; print(tomllib.load(open('pyproject.toml','rb'))['tool']['pytest']['ini_options']['pythonpath'])"` : `['.', 'scripts']`.
2. `grep -n '^\[' pyproject.toml` : every table.
3. Set `fail_under = 99` and run `make test-offline` : the coverage gate fails.
4. `.venv/bin/ruff check --show-settings . | head`.
5. `.venv/bin/mypy --show-config 2>/dev/null | head` (or read the table).

## 7. Mistakes people make

- Unquoted strings, or YAML-style `key: value`.
- Putting a setting in the wrong `[tool.*]` table, where the tool never reads it.

## 8. Check yourself

1. What is a TOML table?
   *Answer:* A `[name]` heading that groups the keys below it.
2. Where do tool settings go in `pyproject.toml`?
   *Answer:* Under `[tool.<toolname>]`.
3. What does `==6.0.3` mean?
   *Answer:* Exactly that version.
4. How is a list written?
   *Answer:* In square brackets with quoted items.
5. Which file lists the project's dependencies?
   *Answer:* `pyproject.toml`, under `[project]`.

## 9. Further reading

- TOML 1.0: <https://toml.io/en/v1.0.0>. pyproject.toml guide: <https://packaging.python.org/en/latest/guides/writing-pyproject-toml/>.
