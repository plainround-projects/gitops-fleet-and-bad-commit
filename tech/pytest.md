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
