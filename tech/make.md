# GNU Make

## 1. What it is

Make is a command-line tool that runs named recipes from a file called `Makefile`. Each recipe is a **target**. A target can list other targets or files it **depends on**, and Make runs those first. People use it as a short front door to a project: `make test` instead of remembering a long command.

## 2. Why this repository uses it

`make up` builds a hub and three workload clusters; `make run` is the whole lesson; `make test-offline` needs none of it.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `Makefile` | targets, the virtual-environment stamp, the `help` listing |

## 4. How it works underneath

- A rule looks like `target: dependency` followed by lines that start with a **tab** character. Those lines are the recipe; Make hands each line to the shell.
- When a target is a *file name*, Make compares file times: if a dependency is newer than the target, the recipe runs again; if not, Make skips it. This is how a virtual environment is built only when its lock file changes.
- A target that is not a file (`up`, `test`) is declared `.PHONY` so Make never mistakes it for a file called `up`.
- `$(NAME)` reads a variable. `?=` sets it only if the caller did not. `:=` evaluates immediately. `$$` writes a single `$` for the shell. `$@` is the target's own name.
- A line starting with `@` is not echoed. A recipe line that fails stops the whole target.
- `## text` after a target is just a comment this repository's `help` target reads back with `grep`.

## 5. Walkthrough of this repository's use

Same structure as the first project's Makefile. Differences: there is no `compare` target; `up: .env $(STAMP)` also builds `.venv` first (the validator uses it); `SCRIPTS := $(wildcard scripts/*.sh scripts/runbook/*.sh docker/git-server/entrypoint.sh)`; the `lint` target adds the cluster-file checker through `./scripts/validate.sh`; `test-offline` runs `-m "not cluster"`; and `down` deletes the hub and every workload cluster.

<!-- full-walkthrough:begin -->
### 5.A Full walkthrough: the whole `Makefile`

**Words you need first.** `make` reads a file called `Makefile`: a list of **rules** `target: prerequisites` followed by recipe lines that begin with a **tab**. `make target` first makes sure each prerequisite is up to date, then runs the recipe, each line in its own shell; if a line fails, `make` stops. A **phony** target is just a command name that always runs.

```make
# make up | run | test | lint | down      (make help lists everything)
PYTHON ?= $(shell command -v python3.13 || command -v python3.12 || command -v python3)
VENV := .venv
PY := $(VENV)/bin/python
STAMP := $(VENV)/.installed
SCRIPTS := $(wildcard scripts/*.sh scripts/runbook/*.sh docker/git-server/entrypoint.sh)

.PHONY: help install up run status test test-offline test-cluster lint format audit validate best-case down clean

help: ## list the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | sort

$(STAMP): requirements-dev.lock pyproject.toml
	$(PYTHON) -m venv $(VENV)
	$(VENV)/bin/pip install -q --require-hashes -r requirements-dev.lock
	touch $@

install: $(STAMP) ## create .venv from the lock file

.env:
	cp .env.example .env

up: .env $(STAMP) ## create the hub and three clusters, install Argo CD, register the clusters, seed the repository
	./scripts/up.sh

run: ## the whole lesson as one scripted run (needs make up)
	./scripts/run.sh

status: ## what the hub reports for every Application
	./scripts/status.sh

best-case: ## step 1: how long a change takes to reach production at best
	./scripts/best-case.sh
	./scripts/best-case.sh --lesson

validate: $(STAMP) ## kustomize, kubeconform and the cluster-file checks on manifests/
	./scripts/validate.sh

lint: $(STAMP) ## yamllint, kubeconform, shellcheck, ruff and mypy
	$(VENV)/bin/yamllint -s .
	./scripts/validate.sh
	shellcheck $(SCRIPTS)
	$(VENV)/bin/ruff check .
	$(VENV)/bin/ruff format --check .
	$(VENV)/bin/mypy

format: $(STAMP) ## format the Python
	$(VENV)/bin/ruff format .
	$(VENV)/bin/ruff check --fix .

test-offline: $(STAMP) ## unit tests and manifest checks; no cluster needed
	$(PY) -m pytest -m "not cluster" --cov --cov-report=term-missing

test-cluster: $(STAMP) ## prove the generator, waves, policy, protection and the outage on the fleet (needs make up)
	$(PY) -m pytest -m cluster

test: $(STAMP) ## everything: the offline tests, then the cluster tests (needs make up)
	$(PY) -m pytest -m "not cluster" --cov --cov-report=term-missing
	$(PY) -m pytest -m cluster

audit: $(STAMP) ## known-vulnerability check of the locked Python dependencies
	$(VENV)/bin/pip install -q pip-audit==2.9.0
	$(VENV)/bin/pip-audit --require-hashes -r requirements-dev.lock

down: ## delete all clusters of the fleet and the working clone
	./scripts/down.sh

clean: ## remove the virtual environment and caches
	rm -rf $(VENV) .pytest_cache .mypy_cache .ruff_cache .coverage htmlcov
```

- `PYTHON ?= $(shell command -v python3.13 || …)` picks the newest Python found unless you set it. `VENV := .venv`, `PY := $(VENV)/bin/python`, `STAMP := $(VENV)/.installed` define the **virtual environment** (a private copy of Python with its own installed libraries) and a marker file. `SCRIPTS := $(wildcard …)` lists every shell script for ShellCheck (a wildcard `*` means "any name").
- `.PHONY:` names the command-like targets. `help:` prints the targets and their `##` descriptions (`grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST)` finds the lines, `sed` swaps the middle for a tab, `sort` orders them; `@` hides the command).
- `$(STAMP): requirements-dev.lock pyproject.toml` rebuilds the environment when a prerequisite is newer than the marker: `venv`, then `pip install -q --require-hashes -r requirements-dev.lock` (quiet; refuse any file whose checksum is not listed; read the list from a file), then `touch $@` (`$@` = the target name). `install` is a shortcut.
- `.env:` copies `.env.example` to `.env` when `.env` is missing. `up: .env $(STAMP)` makes both and runs `./scripts/up.sh`. `run`, `status` run their scripts. `best-case:` runs the arithmetic script twice, once with the configured numbers and once with the lesson's (`--lesson`). `validate:` runs the manifest and stage-file checks.
- `lint:` six checks in order: `yamllint -s .`, `./scripts/validate.sh`, `shellcheck $(SCRIPTS)`, `ruff check .`, `ruff format --check .`, `mypy`; the first failure stops it. `format:` repairs layout and what can be repaired.
- `test-offline:` runs pytest without the cluster tests (`-m "not cluster"`) with a coverage report that lists the lines not run. `test-cluster:` only the cluster tests. `test:` both. `audit:` installs a vulnerability checker at an exact version and runs it on the locked libraries.
- `down:` runs `./scripts/down.sh`. `clean:` removes the virtual environment and caches with `rm -rf`.
<!-- full-walkthrough:end -->

## 6. Try it yourself

1. `make help` : the targets.
2. `make -n up` : what would run, without running it.
3. `make validate` : manifests, policy and `clusters/*.yaml` checks.
4. `make test-offline` : the 41 offline tests.
5. `make -n down` : the delete steps.

## 7. Mistakes people make

- **Spaces instead of a tab** in a recipe: Make says `missing separator`. The `.editorconfig` forces tabs in the Makefile.
- **Forgetting `.PHONY`**, so a file named like the target silently disables it.
- **Each recipe line runs in its own shell**, so `cd dir` on one line does not affect the next. Join lines with `&&` or `;`.
- **Putting logic in the Makefile.** Here the logic lives in scripts, which can be run, tested and shell-checked without Make.

## 8. Check yourself

1. Why must a recipe line start with a tab?
   *Answer:* That is how Make tells a recipe from a rule; spaces give a `missing separator` error.
2. What does `.PHONY` do?
   *Answer:* It marks targets that are commands, not files, so Make always runs them.
3. When does Make skip a file target?
   *Answer:* When the file exists and no dependency is newer than it.
4. What does `$$status` in a recipe become?
   *Answer:* `$status` in the shell, because Make turns `$$` into one `$`.
5. Why does a failing line stop the target?
   *Answer:* Make treats a non-zero exit from a recipe line as an error, unless the line starts with `-`.

## 9. Further reading

- GNU Make manual: <https://www.gnu.org/software/make/manual/make.html>. The Mac that built this uses GNU Make 3.81 from the system; CI uses GNU Make 4.3. The Makefile uses only features both have.
