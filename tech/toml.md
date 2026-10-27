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
