# ruff

## 1. What it is

ruff is a fast tool that does two jobs: it **lints** (finds likely mistakes and style problems) and it **formats** (rewrites code to one consistent layout).

## 2. Why this repository uses it

Consistent, readable Python with docstrings, type annotations and security checks, enforced by `make lint` and CI.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `pyproject.toml` | `[tool.ruff]`, `[tool.ruff.lint]`, per-file ignores |
| `Makefile` | `ruff check .` and `ruff format --check .` in `lint`; `make format` fixes |
| `tests/**/*.py` | the code it checks |

## 4. How it works underneath

- Rules have letter codes. `select = [...]` in `pyproject.toml` turns on groups: `E`/`F` (errors), `I` (import order), `B` (likely bugs), `UP` (outdated syntax), `SIM` (simplifications), `D` (docstrings), `ANN` (missing type annotations), `S` (security), `PT` (pytest style), `RUF`.
- `per-file-ignores` switches rules off for some paths: tests may use `assert` (rule `S101`).
- `ruff check` reports problems; `ruff check --fix` repairs the safe ones; `ruff format --check` fails if a file would be changed by the formatter.

## 5. Walkthrough of this repository's use

```toml
[tool.ruff]
line-length = 120
target-version = "py312"
[tool.ruff.lint]
select = ["E", "F", "I", "B", "UP", "SIM", "D", "ANN", "S", "PT", "RUF"]
ignore = ["D203", "D213"]
[tool.ruff.lint.per-file-ignores]
"tests/**" = ["S101", "S603", "S607", "D"]
"tests/support/**" = ["S101", "S603", "S607"]
```
`line-length = 120` is the width both the linter and the formatter use. `target-version = "py312"` allows Python 3.12 syntax (it lets `UP` suggest modern forms). The `select` letters are explained in section 4. `D203` and `D213` conflict with `D211` and `D212` (two docstring styles), so one of each pair is ignored. The per-file ignores allow `assert` in tests (`S101`) and calls to `subprocess` with a list (`S603`, `S607`: starting a program found on `PATH`) in the helper that exists to run commands; test modules also skip the docstring rules (`D`).

### What differs here
`per-file-ignores` also allows `ANN401` in tests (a deliberate `Any` for loosely typed JSON). Ruff checks `tests/` and `scripts/check_clusters.py`.

## 6. Try it yourself

1. `.venv/bin/ruff check .` : `All checks passed!`.
2. `.venv/bin/ruff format --check .` : `N files already formatted`.
3. Add `import os` unused to a test file, run `ruff check .` : `F401 imported but unused`.
4. `.venv/bin/ruff check --fix .` : repairs what is safe to repair.
5. `.venv/bin/ruff rule S101` : prints the rule's explanation.

## 7. Mistakes people make

- Silencing a rule everywhere because one place trips it; use a narrow ignore with a reason.
- Running the formatter and linter with different line lengths. Both read the same `pyproject.toml`.

## 8. Check yourself

1. What are the two jobs of ruff?
   *Answer:* Linting and formatting.
2. What does the `S` group check?
   *Answer:* Common security problems.
3. What does `ruff format --check` do?
   *Answer:* Fails if any file is not already formatted, without changing it.
4. Why does `tests/**` ignore `S101`?
   *Answer:* Tests are supposed to use `assert`.
5. Where are the rules configured?
   *Answer:* In the `[tool.ruff]` tables of `pyproject.toml`.

## 9. Further reading

- ruff documentation: <https://docs.astral.sh/ruff/> (pinned 0.14.10) and the rule list <https://docs.astral.sh/ruff/rules/>.
