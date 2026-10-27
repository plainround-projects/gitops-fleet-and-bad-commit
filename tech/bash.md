# Bash

## 1. What it is

Bash is a **shell**: a program that reads commands, one per line, and runs other programs. A **script** is a text file of such commands, so that a person types `./scripts/up.sh` once instead of fifty commands. Bash is also a small programming language: it has variables, functions, `if`, loops and pipes.

## 2. Why this repository uses it

The lesson is a runbook: build a fleet of clusters, generate Applications, push a change through waves behind a health gate, show policy refusing a manifest, show protections against a destructive commit, stop the controller during traffic. Each step is a script a person reads and a test runs.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `scripts/lib.sh` | helpers: two kubectl wrappers (hub and workload), Application readers, stage-file editors, `applied_at` |
| `scripts/provider.sh` | k3d or kind and the cluster lock (identical to the other projects) |
| `scripts/up.sh and what it calls` | hub, images, Git server, Argo CD, three clusters, seed, bootstrap, register |
| `scripts/register-cluster.sh` | registers a cluster with the hub |
| `scripts/gate.sh, promote.sh, best-case.sh` | waves, the health gate and the arithmetic |
| `scripts/runbook/02..06, window.sh` | the lesson steps |
| `docker/git-server/entrypoint.sh` | `sh` start-up of the Git server |

## 4. How it works underneath

- A script starts with a **shebang** line such as `#!/usr/bin/env bash`. The operating system reads it and starts that program with the file as input.
- Every command ends with an **exit code**, a number from 0 to 255. `0` means success, anything else means failure. `if`, `&&`, `||` and `until` all look at it.
- A **variable** is written `name=value` and read as `"${name}"`. Quotes stop Bash from splitting a value at spaces.
- `$(command)` runs the command and pastes its output in place. `|` (a **pipe**) sends one command's output into the next command's input.
- `source file` runs another file *inside the current shell*, so its functions and variables become available. That is how one `lib.sh` is shared.
- **Standard output** (fd 1) is the normal output; **standard error** (fd 2) is for messages. `>&2` sends output to standard error; `>/dev/null` throws it away; `2>&1` joins error into output.
- Bash does not stop on errors unless told to. The line `set -euo pipefail` tells it to: `-e` stop at the first failing command, `-u` treat an unset variable as an error, `-o pipefail` make a pipe fail when any part of it fails (not only the last).

## 5. Walkthrough of this repository's use

The shared header, `log`, `die`, `require`, `retry`, `wait_for`, `output_is` and `work_git`/`commit_and_push` are explained in the first project's Bash note. What this repository adds:

### Two clusters worth of kubectl (`lib.sh`)
```bash
HUB="fleet-hub"
STAGES=(dev staging production)
kc() { kubectl --context "${HUB_CONTEXT}" "$@"; }
wk() { local name="$1"; shift; kubectl --context "$(provider_context "$(cluster_of "${name}")")" "$@"; }
cluster_of() { echo "fleet-$1"; }
```
`kc` talks to the **hub** (where Argo CD runs), `wk <stage> ...` to a **workload** cluster (`fleet-dev`, `fleet-staging`, `fleet-production`). `shift` after reading the name drops it so `"$@"` is the kubectl command. A `case` maps each stage to a host port (`18101`...`18104`).

```bash
stage_value() { grep -E "^$2:" "${WORK_CLONE}/clusters/$1.yaml" | head -1 | sed -E "s/^$2:[[:space:]]*//; s/[\"']//g"; }
set_stage_value() { perl -pi -e "s/^$2:.*/$2: $3/" "${WORK_CLONE}/clusters/$1.yaml"; }
```
Read and write one scalar in a stage file: `grep` finds the line `key:`, `sed` strips the key and any quotes. `set_stage_value staging revision <sha>` is the whole of a **promotion**: one line of one file changes.

```bash
applied_at() {
  local stage="$1" revision="$2" applied
  applied="$(app_field "web-${stage}" '{.status.operationState.syncResult.revision}')"
  [ -n "${applied}" ] || return 1
  [ "$(app_field ... '{.status.operationState.phase}')" = "Succeeded" ] || return 1
  [ "$(app_health "${stage}")" = "Healthy" ] || return 1
  [ "${applied}" = "${revision}" ] || work_git merge-base --is-ancestor "${revision}" "${applied}" 2>/dev/null
}
```
Has the stage *successfully applied* that commit and is it Healthy? `return 1` leaves the function early with "false". The last line accepts either an exact match or that the applied commit is a **descendant** of the wanted one (`git merge-base --is-ancestor A B` exits 0 when A is an ancestor of B), because dev follows `main` and may already be ahead. The comment in the file explains why `Synced` is not required: a protected object that a commit deleted from Git leaves the app `OutOfSync` on purpose.

### The cluster fleet
`cluster-up.sh <hub|stage>` creates a cluster with a published port mapping, creates the shared Docker network once (`docker network inspect "${FLEET_NETWORK}" >/dev/null 2>&1 || docker network create ...`: "create unless it exists"), and creates the cluster on it under the machine-wide lock. `up.sh` loops over `"${STAGES[@]}"` to create three clusters, then registers each.

`register-cluster.sh`:
```bash
read_token() { kubectl --context "${context}" -n kube-system get secret argocd-manager-token -o 'jsonpath={.data.token}' | base64 -d; }
wait_for "the service account token to be issued" 60 test -n "$(read_token)"
```
(The `$(read_token)` here is evaluated once, which is fine for a wait that only checks it is non-empty after it first succeeds... in this script it is evaluated before the first poll.) The token is base64 in the Secret; `base64 -d` decodes it. The script then writes a **cluster Secret** into the hub with a here-document (`kc apply -f - <<SECRET ... SECRET`) carrying labels `app: web` and `stage: <stage>`, the API address `https://<node-container-name>:6443` (reachable over the shared Docker network) and a JSON `config` with the bearer token and the cluster's CA certificate. `--remove` deletes that Secret.

### Waves and the gate
`promote.sh` is a straight line of `if ! gate.sh ...; then log ...; exit 1; fi` checks around two `set_stage_value` + `commit_and_push` pairs. `gate.sh` has two loops: wait until the stage applied the revision (failing early if it turns Degraded at that revision or its sync failed), then **observe** for `observeSeconds`, failing the moment health changes: `elapsed=$((elapsed + 2))` in a `while [ "${elapsed}" -lt "${observe}" ]` loop. `best-case.sh` pulls numbers out of the YAML files with `grep -oE` and adds them with `$(( ))`.

### Runbook details
* `window.sh`: `10#$(date -u +%H)` forces base 10 (a leading zero would make Bash read `08` as octal and fail); `$(((h + 12) % 24))` is arithmetic with wrap-around.
* `03-waves.sh bad`: `if "${ROOT}/scripts/promote.sh" "${change}"; then die ...; fi` expects promote to **fail**.
* `04-policy.sh`: nested `case "${message}" in *"${expected}"*) ;; *) die ... ;; esac` is a "contains" test; `grep -o "denied the request: .*"` prints only the matching tail of each error.
* `06-controller-outage.sh`: `traffic &` starts a loop in the background; `traffic_pid=$!` saves its process id; `trap 'kill "${traffic_pid}" 2>/dev/null || true' EXIT` stops it on any exit. `curl -s -o /dev/null -w '%{http_code}\n' --max-time 2 ...` prints only the HTTP status code; `|| echo 000` records a failed request. `sleep $((seconds / 2))` waits half the outage. At the end `grep -vc '^200$'` counts lines that are not `200`.

<!-- full-walkthrough:begin -->
### 5.A Full walkthrough: every script

**Words you need first.** A **terminal** is a window where you type a line and press Return. The program that reads your line is a **shell**; **Bash** is the common one. A **script** is a file of shell lines you run as one command. A **command** is one line: a program name followed by **arguments**; an argument starting with a dash (`-l`) is a **flag** that switches a behavior on.

**A process.** When you run a program, the computer starts a **process**: a running copy of that program, with its own memory and its own list of settings. When a script runs, there is one process for Bash itself. Each program the script starts (for example `git`) becomes a new process, called a **child** process. When the child ends, it hands back a number to its parent. That number is the **exit code**.

**Exit codes.** An exit code is a whole number from 0 to 255. By agreement, `0` means "it worked" and any other number means "it failed" (different numbers can mean different kinds of failure). You cannot see the number on screen, but Bash keeps the code of the last command in a special variable called `$?`, and it uses the code in `if`, `&&`, `||` and loops. This is the most important idea in shell scripting: **success and failure are numbers that commands return, and the script reacts to them.**

**A variable.** A variable is a named box that holds text. You write `name=value` (no spaces around the `=`) to put text in the box, and `${name}` to read it back. The `$` means "take the value of". The braces `{ }` mark exactly where the name ends, so `${name}_file` is the value of `name` followed by `_file`.

**An environment variable.** Every process has a list of named settings called its **environment**. The shell starts every child process with a copy of that list. A shell variable becomes part of the list only when you **export** it (`export NAME`). Programs read environment variables to learn settings, such as where to find files. Because a child gets only a **copy**, a child can never change its parent's variables.

**Quoting.** A shell splits a line into words at spaces. A value such as `my file.txt` would become two words unless you quote it: `"my file.txt"` stays one word. Inside double quotes `"…"` the shell still replaces `${name}` by its value. Inside single quotes `'…'` nothing is replaced; the text is used exactly as written. Every variable in these scripts is written inside double quotes, so a value with a space in it cannot break the line.

**Command substitution.** `$(command)` runs the command and puts its printed output in place of the `$(…)`. For example `today="$(date +%H:%M:%S)"` stores the current time in `today`. The command inside runs in a **sub-shell**: a child copy of the shell. Things the child changes (such as the current folder) do not change the parent.

**Standard streams.** Every process starts with three channels open: **standard input** (channel 0, where it reads), **standard output** (channel 1, where it writes normal results) and **standard error** (channel 2, where it writes problems and messages). On screen the last two both look like text in the terminal, but they are separate. `>` sends standard output to a file instead of the screen. `2>` does the same for standard error. `>&2` means "send my standard output to wherever standard error goes". `>/dev/null` sends output to a special file called `/dev/null` that throws everything away. `2>&1` makes standard error go to the same place as standard output.

**A pipe.** `a | b` connects the standard output of `a` to the standard input of `b`. Both start at the same time; `b` reads what `a` writes. This is how small programs are chained: `grep error log.txt | head -3` finds lines with "error" and keeps the first three.

**A function.** A function is a named group of commands: `name() { commands; }`. You run it by writing its name like a command. Inside a function, `$1`, `$2` … are its arguments, `$#` is how many there are, `"$@"` is all of them (each kept as a separate word), and `"$*"` is all of them joined into one string. `shift 2` throws away the first two arguments so the rest move up. `local x` makes a variable that exists only inside the function.

**`source`.** `source file` (or `. file`) reads the lines of another file **into the current shell**, as if you had typed them here. After it, the other file's functions and variables exist. That is how one library, `lib.sh`, is shared by all the scripts. Running `./lib.sh` instead would start a child process whose functions disappear when it ends.

**A shebang.** The first line of a script, `#!/usr/bin/env bash`, tells the operating system which program should run the file. `env bash` means "find `bash` wherever it is installed".

**Safety switches.** By default Bash keeps going after a command fails. Almost every script here starts with the line `set -euo pipefail`, which turns on three protections:
- `-e` stop the script at the first command that fails (non-zero exit code);
- `-u` treat the use of a variable that was never set as an error (so a typing mistake in a name cannot silently become empty text);
- `-o pipefail` make a pipeline fail if **any** part of it fails (normally only the last part counts).


**The three lines every script starts with.**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
```
- `#!/usr/bin/env bash` is the shebang (see above): run this file with Bash.
- `set -euo pipefail` turns on the three safety switches (see above).
- `${BASH_SOURCE[0]}` is the path of the file being read. `dirname` keeps its folder. `source …/lib.sh` loads the helper functions, found by the script's own location, so the script works from any current folder. In scripts one folder deeper (`scripts/runbook/`), the path is `…/../lib.sh`: one folder up.


#### `scripts/lib.sh`: the shared library

```bash
#!/usr/bin/env bash
# Shared helpers for every script in this repository. Source it; do not run it.
# shellcheck shell=bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

# versions.env pins the tools and images; .env (copied from .env.example) holds local choices.
# shellcheck source=../versions.env
source "${ROOT}/versions.env"
if [ -f "${ROOT}/.env" ]; then
  # shellcheck source=/dev/null
  source "${ROOT}/.env"
fi

WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"
OUTAGE_SECONDS="${OUTAGE_SECONDS:-1800}"
HUB="fleet-hub"
# shellcheck disable=SC2034 # used by the scripts that source this file
STAGES=(dev staging production)
GIT_HOST_PORT=30438
GIT_HOST_URL="http://127.0.0.1:${GIT_HOST_PORT}/gitops-fleet.git"
WORK_DIR="${ROOT}/.work"
WORK_CLONE="${WORK_DIR}/gitops-fleet"
export WAIT_TIMEOUT OUTAGE_SECONDS HUB HUB_CONTEXT GIT_HOST_URL WORK_CLONE

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "error: $*"; exit 1; }

# shellcheck source=provider.sh
source "${ROOT}/scripts/provider.sh"
HUB_CONTEXT="$(provider_context "${HUB}")"
# The clusters of the fleet share one Docker network, so the hub reaches the others by the name of their node container.
FLEET_NETWORK="fleet-net"
export FLEET_NETWORK

require() {
  local tool
  for tool in "$@"; do
    command -v "${tool}" >/dev/null 2>&1 || die "${tool} is not installed (see the prerequisites in README.md)"
  done
}

# retry <attempts> <delay-seconds> <command...>: run until it succeeds, with a fixed delay.
retry() {
  local attempts="$1" delay="$2" attempt=1
  shift 2
  until "$@"; do
    if [ "${attempt}" -ge "${attempts}" ]; then return 1; fi
    attempt=$((attempt + 1))
    sleep "${delay}"
  done
}

# wait_for <description> <timeout-seconds> <command...>: poll once a second until the command succeeds.
wait_for() {
  local description="$1" timeout="$2" waited=0
  shift 2
  until "$@" >/dev/null 2>&1; do
    if [ "${waited}" -ge "${timeout}" ]; then
      die "timed out after ${timeout}s waiting for ${description}"
    fi
    sleep 1
    waited=$((waited + 1))
  done
  log "${description}: ok (${waited}s)"
}

# The cluster that runs a stage: fleet-dev, fleet-staging, fleet-production (and fleet-demo4 briefly).
cluster_of() { echo "fleet-$1"; }
# The host port that reaches the app of a cluster (a published port onto the Service's NodePort).
host_port_of() {
  case "$1" in
    dev) echo 18101 ;;
    staging) echo 18102 ;;
    production) echo 18103 ;;
    demo4) echo 18104 ;;
    *) die "unknown cluster: $1" ;;
  esac
}

# kc: kubectl on the hub. wk <name>: kubectl on a workload cluster (dev, staging, production, demo4).
kc() { kubectl --context "${HUB_CONTEXT}" "$@"; }
wk() {
  local name="$1"
  shift
  kubectl --context "$(provider_context "$(cluster_of "${name}")")" "$@"
}

# app_field <application> <jsonpath>: one field of an Application on the hub, empty when it is not there.
app_field() { kc -n argocd get application "$1" -o "jsonpath=$2" 2>/dev/null || true; }
app_sync() { app_field "web-$1" '{.status.sync.status}'; }
app_health() { app_field "web-$1" '{.status.health.status}'; }
app_revision() { app_field "web-$1" '{.status.sync.revision}'; }

# synced_healthy_at <stage> <revision>
synced_healthy_at() {
  [ "$(app_sync "$1")" = "Synced" ] && [ "$(app_health "$1")" = "Healthy" ] && [ "$(app_revision "$1")" = "$2" ]
}

# output_is <expected> <command...>: true when the command prints exactly <expected>; wait_for re-runs it at every poll.
output_is() {
  local expected="$1"
  shift
  [ "$("$@")" = "${expected}" ]
}

# synced_and_healthy <stage>
synced_and_healthy() { [ "$(app_sync "$1")" = Synced ] && [ "$(app_health "$1")" = Healthy ]; }

# Every git command of the runbook goes through here so it only ever touches the working clone.
work_git() { git -C "${WORK_CLONE}" "$@"; }
work_head() { work_git rev-parse HEAD; }

# commit_and_push <message>: commit everything in the working clone, push, print the new commit.
commit_and_push() {
  work_git add --all
  work_git commit --quiet -m "$1"
  work_git push --quiet origin main
  work_head
}

# stage_value <stage> <key>: a value from clusters/<stage>.yaml in the working clone.
stage_value() { grep -E "^$2:" "${WORK_CLONE}/clusters/$1.yaml" | head -1 | sed -E "s/^$2:[[:space:]]*//; s/[\"']//g"; }

# set_stage_value <stage> <key> <value>: change one scalar in clusters/<stage>.yaml (no commit).
set_stage_value() { perl -pi -e "s/^$2:.*/$2: $3/" "${WORK_CLONE}/clusters/$1.yaml"; }

# web_get <stage> <path>: GET the app through the host port (no controller and no API server in the path).
web_get() { curl -fsS --max-time 3 "http://127.0.0.1:$(host_port_of "$1")$2"; }

# applied_at <stage> <revision>: the last sync operation succeeded at that commit (or a descendant of it, for dev,
# which follows main) and the app is Healthy. "Synced" is not required: a protected object that a commit deleted
# from Git leaves the app OutOfSync on purpose, and the wave must still be able to judge its health.
applied_at() {
  local stage="$1" revision="$2" applied
  applied="$(app_field "web-${stage}" '{.status.operationState.syncResult.revision}')"
  [ -n "${applied}" ] || return 1
  [ "$(app_field "web-${stage}" '{.status.operationState.phase}')" = "Succeeded" ] || return 1
  [ "$(app_health "${stage}")" = "Healthy" ] || return 1
  [ "${applied}" = "${revision}" ] || work_git merge-base --is-ancestor "${revision}" "${applied}" 2>/dev/null
}

# operation_message <stage>: the message of the last sync operation (the admission policy's text, when it refuses).
operation_message() { app_field "web-$1" '{.status.operationState.message}'; }
operation_failed() { [[ "$(app_field "web-$1" '{.status.operationState.phase}')" =~ ^(Failed|Error)$ ]]; }
```

- Loaded by every script with `source`; it defines variables and functions. `ROOT` is the repository folder (`cd` in a sub-shell `$( … )`, so the caller's folder does not change). `versions.env` and the optional `.env` are loaded with `source` (`if [ -f file ]` tests that a file exists); the `# shellcheck source=` comments tell the ShellCheck tool which file is loaded.
- `WAIT_TIMEOUT` (seconds to wait for things, default 300), `OUTAGE_SECONDS` (how long the controller is stopped in step 6, default 1800 = the lesson's half hour), `HUB="fleet-hub"` (the name of the cluster that runs Argo CD), `STAGES=(dev staging production)` (an **array**, a list that scripts loop over with `"${STAGES[@]}"`; the comment above silences a ShellCheck warning). `${NAME:-default}` means "the variable if set and not empty, else the default". `GIT_HOST_PORT=30438` is the port on your computer (`127.0.0.1` = this computer) that leads to the Git server in the hub; `GIT_HOST_URL`, `WORK_DIR` and `WORK_CLONE` are the Git address and the hidden working folders.
- `log`, `die`, `require`, `retry`, `wait_for` are the usual helpers: `log` prints a time-stamped line to **standard error** (`>&2`); `die` logs and exits with 1; `require` stops with a message when a program is missing (`command -v`); `retry` runs a command up to N times with a pause; `wait_for "text" seconds command…` runs the command once a second until it succeeds or the time runs out (the command is re-run every time, so use a function, not a `$(…)` value).
- `HUB_CONTEXT="$(provider_context "${HUB}")"` stores the `kubectl` context name of the hub (after `provider.sh` is loaded). `FLEET_NETWORK="fleet-net"` is the Docker network all the clusters share, so the hub can reach the others by name.
- `cluster_of <stage>` prints the cluster name of a stage (`fleet-dev`). `host_port_of <stage>` prints the port on your computer that leads to that cluster's web application (`18101`, `18102`, `18103`; `18104` for the fourth cluster `demo4`): a `case` chooses by name.
- `kc` is `kubectl` on the **hub**; `wk <name> …` is `kubectl` on a **workload** cluster (`shift` drops the name from the arguments so `"$@"` is the command). Both always pass `--context`, so a command can never go to the wrong cluster.
- `app_field <application> <jsonpath>` reads one field of an Argo CD Application with `-o "jsonpath=…"` (a path into the object's data; `2>/dev/null || true` makes a missing object print nothing instead of stopping the script). `app_sync`, `app_health`, `app_revision` read the three fields of the Application `web-<stage>`.
- `synced_healthy_at <stage> <revision>` and `synced_and_healthy <stage>` are yes/no functions built with `[ a = b ] && [ c = d ]` (two tests joined by `&&`: both must be true). `output_is expected command…` succeeds when the command prints exactly the expected text; it exists because `wait_for` re-runs its command, so a check must be a command or function.
- `work_git` runs Git in the working clone only (`git -C folder`), `work_head` prints the newest commit hash, `commit_and_push "message"` stages all changes, commits, pushes `main` and prints the new hash.
- `stage_value <stage> <key>` reads one value from `clusters/<stage>.yaml` in the working clone: `grep -E "^key:"` finds the line, `head -1` keeps the first, `sed -E "s/^key:[[:space:]]*//; s/[\"']//g"` removes the key and any quotes (`[[:space:]]` is a character class for spaces). `set_stage_value <stage> <key> <value>` changes it in place with `perl -pi -e "s/^key:.*/key: value/"` (`-p` run for each line, `-i` write back, `-e` the code). **Promoting a stage is one line of one file.**
- `web_get <stage> <path>` fetches a page from the web application through its published port with `curl -fsS --max-time 3` (`-f` fail on an HTTP error, `-s` quiet, `-S` still show errors, `--max-time` limits the wait): no Argo CD and no Kubernetes API server in the path.
- `applied_at <stage> <revision>` answers "did this stage successfully apply that commit, and is it healthy?": it reads the commit of the last sync operation; returns 1 (false) if there is none, if the operation did not succeed or if the app is not healthy; and finally accepts an exact match or that the applied commit is a **descendant** of the wanted one (`git merge-base --is-ancestor A B` exits 0 when A is an ancestor of B), because dev follows `main` and may be ahead. The comment explains why `Synced` is not required: a protected object that a commit deleted from Git leaves the app `OutOfSync` on purpose.
- `operation_message` prints the message of the last sync (the admission policy's own text when it refuses); `operation_failed` is true when the last operation's phase is `Failed` or `Error`: `[[ text =~ ^(Failed|Error)$ ]]` is Bash's own pattern test (`=~` against a regular expression).

#### `scripts/provider.sh`: a local cluster, with k3d or kind

A **Kubernetes cluster** is a group of machines that run containers for you. For a lesson, one machine is enough, and it can itself be a container. **k3d** and **kind** are two tools that start such a one-container cluster on your laptop using Docker. k3d starts **k3s** (a small Kubernetes); kind starts standard Kubernetes with a tool called kubeadm. This file puts both behind the same function names, so the other scripts are the same whichever you use. It is loaded with `source`; it defines functions and one variable.

```bash
#!/usr/bin/env bash
# Local cluster providers: k3d (the default) and kind. Source it after versions.env; do not run it.
#   CLUSTER_PROVIDER=k3d   k3s in Docker; starts a control plane in seconds and needs little memory
#   CLUSTER_PROVIDER=kind  kubeadm in Docker; the conventional choice, but its control plane start has hard deadlines that a
#                          busy or memory-starved machine misses
# Both create a cluster with one control-plane node, publish the host ports given as <host>:<node-port> on 127.0.0.1, and
# need no registry: images are imported from the local Docker with provider_load_images.
# shellcheck shell=bash

CLUSTER_PROVIDER="${CLUSTER_PROVIDER:-k3d}"
```

- Line 1 is the shebang; lines 2-7 are comments that explain the two providers: k3d (the default) starts a control plane in seconds and needs little memory; kind is the conventional choice but its kubeadm start-up has hard deadlines that a busy machine misses. Both create a cluster with one node, publish chosen host ports on `127.0.0.1` only, and need no registry (a server that stores images): images are copied in from the local Docker. Line 8 tells ShellCheck the dialect.
- Line 10: `${CLUSTER_PROVIDER:-k3d}` uses the variable if set, otherwise `k3d`.

```bash
provider_context() { # <cluster>
  case "${CLUSTER_PROVIDER}" in
    k3d) echo "k3d-$1" ;;
    kind) echo "kind-$1" ;;
    *) die "CLUSTER_PROVIDER must be k3d or kind, not ${CLUSTER_PROVIDER}" ;;
  esac
}
```

- `provider_context` prints the name `kubectl` uses for the cluster: `k3d-<name>` or `kind-<name>`. `case value in pattern) commands ;; … esac` chooses a branch by matching text; `*)` matches anything else, so a wrong provider name stops with a clear error (`die`, from `lib.sh`). The comment after the function name shows the argument it expects (`$1`).

```bash
# The Docker container of the control-plane node.
provider_node() { # <cluster>
  case "${CLUSTER_PROVIDER}" in
    k3d) echo "k3d-$1-server-0" ;;
    kind) echo "$1-control-plane" ;;
    *) die "CLUSTER_PROVIDER must be k3d or kind, not ${CLUSTER_PROVIDER}" ;;
  esac
}
```

- `provider_node` prints the name of the Docker container that is the cluster's machine (`k3d-<name>-server-0` or `<name>-control-plane`). Scripts use it with `docker exec`.

```bash
# The name other clusters on the shared Docker network use to reach this cluster's API server on port 6443.
provider_api_host() { # <cluster>
  case "${CLUSTER_PROVIDER}" in
    k3d) echo "k3d-$1-serverlb" ;;
    kind) echo "$1-control-plane" ;;
    *) die "CLUSTER_PROVIDER must be k3d or kind, not ${CLUSTER_PROVIDER}" ;;
  esac
}
```

- `provider_api_host` prints the name other containers on the same Docker network would use to reach this cluster's **API server** (the front door of Kubernetes, port 6443): for k3d the load-balancer container `k3d-<name>-serverlb`, for kind the node itself.

```bash
provider_exists() { # <cluster>
  case "${CLUSTER_PROVIDER}" in
    k3d) k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx "$1" ;;
    kind) kind get clusters 2>/dev/null | grep -qx "$1" ;;
    *) die "CLUSTER_PROVIDER must be k3d or kind, not ${CLUSTER_PROVIDER}" ;;
  esac
}
```

- `provider_exists` answers by exit code whether the cluster exists. For k3d: `k3d cluster list --no-headers` prints one cluster per line; `awk '{print $1}'` keeps the first column (the name); `grep -qx "$1"` checks that a whole line equals the name (`-q` print nothing, `-x` whole line). For kind: `kind get clusters` prints the names. Errors are hidden with `2>/dev/null`.

```bash
provider_delete() { # <cluster>
  case "${CLUSTER_PROVIDER}" in
    k3d) k3d cluster delete "$1" ;;
    kind) kind delete cluster --name "$1" ;;
    *) die "CLUSTER_PROVIDER must be k3d or kind, not ${CLUSTER_PROVIDER}" ;;
  esac
}
```

- `provider_delete` deletes the cluster: `k3d cluster delete <name>` or `kind delete cluster --name <name>`.

```bash
# provider_create <cluster> [<host-port>:<node-port>...] [--network <docker-network>] [--registry-config <file>]
# k3d only: --network joins an existing Docker network (clusters that must reach each other share one).
provider_create() {
  local name="$1" mappings=() network="" registry_config=""
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --network) network="$2"; shift 2 ;;
      --registry-config) registry_config="$2"; shift 2 ;;
      *) mappings+=("$1"); shift ;;
    esac
  done
```

- `provider_create` makes a cluster. The comments show the usage: the name, then optional port mappings of the form `host-port:node-port`, and for k3d the options `--network` and `--registry-config`.
- `local name="$1" mappings=() network="" registry_config=""` declares local variables; `mappings=()` is an empty **array** (a list). `shift` removes the name from the arguments.
- The `while` loop is a small **option parser**: while arguments remain (`[ "$#" -gt 0 ]`, `$#` is how many are left), look at the first one. `--network` stores the next word and `shift 2` removes both; `--registry-config` likewise; anything else is a port mapping, added to the array with `mappings+=("$1")`.

```bash
  case "${CLUSTER_PROVIDER}" in
    k3d)
      local args=(cluster create "${name}" --servers 1 --agents 0 --image "${K3S_IMAGE}" --wait --timeout 1800s
        --k3s-arg "--disable=traefik@server:0" --k3s-arg "--disable=servicelb@server:0"
        --k3s-arg "--disable=metrics-server@server:0")
      local mapping
      for mapping in "${mappings[@]}"; do
        args+=(-p "127.0.0.1:${mapping%:*}:${mapping#*:}@loadbalancer")
      done
      [ -z "${network}" ] || args+=(--network "${network}")
      [ -z "${registry_config}" ] || args+=(--registry-config "${registry_config}")
      k3d "${args[@]}"
      ;;
```

- For k3d the function builds the command as an array `args` (so every argument stays whole): `cluster create <name>`, `--servers 1 --agents 0` (one machine that is both control plane and worker), `--image` the pinned k3s version, `--wait --timeout 1800s` (do not return until ready; allow 30 minutes for a slow machine). Three `--k3s-arg "--disable=…@server:0"` flags turn off k3s's bundled ingress controller, service load balancer and metrics server, which these lessons do not use, to save memory.
- The `for` loop adds `-p "127.0.0.1:HOST:NODE@loadbalancer"` for each mapping: `${mapping%:*}` removes the shortest piece matching `:*` from the **end** (leaving the part before the colon) and `${mapping#*:}` removes the shortest piece matching `*:` from the **start** (leaving the part after). `-p` publishes a port: connections to your computer's `127.0.0.1:HOST` are sent into the cluster. `127.0.0.1` is the address that always means "this computer", so the port is private to your machine.
- `[ -z "${network}" ] || args+=(…)` reads "unless the value is empty, add the flag" (`-z` tests for empty). Last, `k3d "${args[@]}"` runs the command.

```bash
    kind)
      local config
      config="$(mktemp)"
      {
        cat <<'CONFIG'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
# A busy laptop can miss kubeadm's default deadlines while the API server starts.
kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    timeouts:
      controlPlaneComponentHealthCheck: 10m0s
      kubernetesAPICall: 5m0s
      etcdAPICall: 5m0s
  - |
    kind: ClusterConfiguration
    apiServer:
      timeoutForControlPlane: 10m0s
    etcd:
      local:
        # etcd's data directory on the node's tmpfs: disk latency makes fsync the bottleneck of a start.
        dataDir: /tmp/etcd
nodes:
  - role: control-plane
CONFIG
```

- For kind the function writes a configuration **file** first. `mktemp` creates an empty temporary file and prints its name. The braces `{ … } > "${config}"` send everything printed inside to that file. `cat <<'CONFIG' … CONFIG` is a **here-document**: the lines up to the marker `CONFIG` are fed to `cat`; the quotes around the first marker switch off variable replacement, so the text is copied exactly.
- The text is **YAML** (see the YAML note). `kubeadmConfigPatches` raise kubeadm's waiting limits (health check of the control plane, calls to the API, calls to `etcd`) to five or ten minutes, because on a busy laptop the defaults ran out. `etcd` is the cluster's database; `dataDir: /tmp/etcd` puts its files on a memory-backed folder, which is much faster than disk. `nodes: - role: control-plane` asks for one node.

```bash
        if [ "${#mappings[@]}" -gt 0 ]; then
          echo "    extraPortMappings:"
          for mapping in "${mappings[@]}"; do
            printf '      - containerPort: %s\n        hostPort: %s\n        listenAddress: 127.0.0.1\n        protocol: TCP\n' "${mapping#*:}" "${mapping%:*}"
          done
        fi
      } > "${config}"
      kind create cluster --name "${name}" --image "${KIND_NODE_IMAGE}" --config "${config}" --wait 600s
      rm -f "${config}"
      ;;
    *) die "CLUSTER_PROVIDER must be k3d or kind, not ${CLUSTER_PROVIDER}" ;;
  esac
}
```

- If there are port mappings (`${#mappings[@]}` is the number of items in the array), the function adds an `extraPortMappings:` block with one entry per mapping, using `printf` (`%s` is a place for a value, `\n` a line break); `listenAddress: 127.0.0.1` keeps each port private to this machine. Then `kind create cluster --name … --image "${KIND_NODE_IMAGE}" --config … --wait 600s` creates the cluster and `rm -f` deletes the temporary file. The last branch of the `case` rejects any other provider name.

```bash
# Imports the images that are not on the node yet (importing is slow and the second `make up` need not repeat it).
provider_load_images() { # <cluster> <image>...
  local name="$1" missing=() image
  shift
  for image in "$@"; do
    docker exec "$(provider_node "${name}")" crictl inspecti "${image}" >/dev/null 2>&1 || missing+=("${image}")
  done
  [ "${#missing[@]}" -gt 0 ] || { log "the images are already on ${name}"; return 0; }
  set -- "${missing[@]}"
  case "${CLUSTER_PROVIDER}" in
    k3d) k3d image import --cluster "${name}" "$@" ;;
    kind) kind load docker-image --name "${name}" "$@" ;;
    *) die "CLUSTER_PROVIDER must be k3d or kind, not ${CLUSTER_PROVIDER}" ;;
  esac
}
```

- `provider_load_images` copies images into the cluster. The cluster's machine is a container with its own storage, so images built on your computer are not visible to it.
- For each image, `docker exec <node> crictl inspecti <image>` asks the node's container runtime whether it has the image (`docker exec` runs a command inside a running container); if not, the name is added to `missing`. If nothing is missing the function logs and returns (`return 0`), so a second `make up` does not repeat the slow copy.
- `set -- "${missing[@]}"` replaces the function's own arguments with the missing images, so `"$@"` can be passed on to `k3d image import --cluster <name> …` or `kind load docker-image --name <name> …`.

```bash
# with_cluster_lock <command...>: run one command while holding the machine-wide lock that keeps two clusters from
# starting at once (a busy laptop cannot start two control planes together). The lock is a directory holding the
# holder's PID; a lock whose holder is gone is removed.
with_cluster_lock() {
  local lock=/tmp/plainround-kind-create.lock waited=0 holder status
  until mkdir "${lock}" 2>/dev/null; do
    holder="$(cat "${lock}/pid" 2>/dev/null || true)"
    if [ -n "${holder}" ] && ! kill -0 "${holder}" 2>/dev/null; then rm -rf "${lock}"; continue; fi
    [ "${waited}" -lt 7200 ] || die "gave up waiting for another cluster to finish starting"
    [ $((waited % 60)) -ne 0 ] || log "another cluster is starting; waiting for ${lock}"
    sleep 5
    waited=$((waited + 5))
  done
  echo "$$" > "${lock}/pid"
  status=0
  "$@" || status=$?
  rm -rf "${lock}"
  return "${status}"
}
```

- `with_cluster_lock` makes cluster creations take turns. Starting a cluster is heavy; several at once on one laptop all time out. A **lock** lets processes agree that only one does something at a time. Here the lock is a **folder**: `mkdir` creates it or fails if it exists, and creating a folder is atomic (two processes cannot both succeed).
- While `mkdir` fails, the loop reads the holder's process number from `lock/pid` and checks whether that process is alive (`kill -0 pid` sends no signal; it only tests). If the holder is dead, the lock is stale: `rm -rf` removes it and `continue` restarts the loop. Otherwise it gives up after 7200 seconds (`[ condition ] || die …` means "unless true, stop"), logs once a minute (`$((waited % 60))` is the remainder after dividing by 60), sleeps five seconds and adds five to the counter.
- After taking the lock: `echo "$$" > "${lock}/pid"` records the number of the current process (`$$`); `status=0; "$@" || status=$?` runs the command given as arguments and saves its exit code (`$?`); the lock is always removed; the function returns the saved code.


#### Scripts that build the fleet (`make up`)

**`scripts/up.sh`**

```bash
#!/usr/bin/env bash
# Everything `make up` does, in order. Safe to run again.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require docker kubectl git curl kubeconform

"${ROOT}/scripts/cluster-up.sh" hub
"${ROOT}/scripts/build-images.sh"
"${ROOT}/scripts/install-git-server.sh"
"${ROOT}/scripts/install-argocd.sh"
for stage in "${STAGES[@]}"; do
  "${ROOT}/scripts/cluster-up.sh" "${stage}"
done
"${ROOT}/scripts/build-images.sh" "${STAGES[@]}"
"${ROOT}/scripts/seed-repo.sh"
"${ROOT}/scripts/bootstrap.sh"
for stage in "${STAGES[@]}"; do
  "${ROOT}/scripts/register-cluster.sh" "${stage}" "${stage}"
done
for stage in "${STAGES[@]}"; do
  wait_for "web-${stage} to be Synced and Healthy" "${WAIT_TIMEOUT}" synced_and_healthy "${stage}"
done
"${ROOT}/scripts/status.sh"
```

- Checks the tools. Creates the hub, builds the images, installs the Git server and Argo CD on the hub, then a loop creates the three workload clusters (`for stage in "${STAGES[@]}"`), builds and imports the web images into them (`build-images.sh dev staging production`), seeds the Git repository, applies the root Application, and registers each cluster with the hub. The last loop waits for each `web-<stage>` Application to be Synced and Healthy; `status.sh` prints a summary.

**`scripts/cluster-up.sh`**

```bash
#!/usr/bin/env bash
# Creates a cluster of the fleet if it does not exist yet (k3d by default, kind with CLUSTER_PROVIDER=kind). Safe to run again.
#   cluster-up.sh hub                       the hub: Argo CD and the Git server (Git published on the host)
#   cluster-up.sh dev|staging|production|demo4   a workload cluster (the app's NodePort published on a host port)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require "${CLUSTER_PROVIDER}" kubectl docker

target="${1:?usage: cluster-up.sh hub|dev|staging|production|demo4}"
if [ "${target}" = "hub" ]; then
  name="${HUB}"
  mapping="${GIT_HOST_PORT}:${GIT_HOST_PORT}"
else
  name="$(cluster_of "${target}")"
  mapping="$(host_port_of "${target}"):30080"
fi
context="$(provider_context "${name}")"

# A cluster whose creation was interrupted exists as a container but has no kubectl context; start it over. (A slow API
# server is not a reason to delete a cluster, so only the missing context counts.)
if provider_exists "${name}" && ! kubectl config get-contexts -o name | grep -qx "${context}"; then
  log "cluster ${name} is half-made; deleting it"
  provider_delete "${name}"
fi
if provider_exists "${name}"; then
  log "cluster ${name} already exists"
else
  log "creating cluster ${name} with ${CLUSTER_PROVIDER}"
  docker network inspect "${FLEET_NETWORK}" >/dev/null 2>&1 || docker network create "${FLEET_NETWORK}" >/dev/null
  create_cluster() {
    docker rm --force "$(provider_node "${name}")" >/dev/null 2>&1 || true
    # k3d joins the shared network; kind puts every cluster on its own shared network called "kind".
    provider_create "${name}" "${mapping}" --network "${FLEET_NETWORK}"
  }
  with_cluster_lock retry 6 10 create_cluster || die "cluster ${name} did not start after six attempts"
fi
kubectl --context "${context}" wait --for=condition=Ready node --all --timeout=180s
```

- The comment lists the usage: `cluster-up.sh hub` or `cluster-up.sh dev|staging|production|demo4`. `target="${1:?usage…}"` requires an argument (`${1:?message}` stops with the message if it is missing). For the hub, the name is `fleet-hub` and the port mapping publishes the Git server's port; for a workload cluster the name comes from `cluster_of` and the mapping publishes the application's node port `30080` on that stage's host port.
- A half-made cluster (it exists but `kubectl` has no context for it) is deleted. If the cluster exists, say so; otherwise: create the shared Docker network once (`docker network inspect "${FLEET_NETWORK}" >/dev/null 2>&1 || docker network create …` means "create it unless it exists"), define `create_cluster` (remove a left-over node container, then `provider_create` with the mapping and `--network fleet-net`), and run it under the machine-wide lock with up to six tries. Finally wait up to three minutes for the node to be Ready on that cluster's context.

**`scripts/build-images.sh`**

```bash
#!/usr/bin/env bash
# Builds the images and loads them where they run:
#   plainround/web:1.0.0 and :1.1.0   into every workload cluster given on the command line
#   plainround/git-server:1.0.0       into the hub
#   build-images.sh dev staging production       (or: demo4)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require docker

build() {
  local context="$1" tag="$2"
  shift 2
  docker image inspect "${tag}" >/dev/null 2>&1 && return 0
  log "building ${tag}"
  docker build --quiet --tag "${tag}" "$@" "${ROOT}/${context}" >/dev/null
}

build docker/web plainround/web:1.0.0 --build-arg "BASE_IMAGE=${WEB_BASE_IMAGE}" --build-arg APP_VERSION=1.0.0
build docker/web plainround/web:1.1.0 --build-arg "BASE_IMAGE=${WEB_BASE_IMAGE}" --build-arg APP_VERSION=1.1.0
build docker/git-server plainround/git-server:1.0.0 --build-arg "BASE_IMAGE=${GIT_SERVER_BASE_IMAGE}"

for target in "$@"; do
  log "loading the web images into $(cluster_of "${target}")"
  provider_load_images "$(cluster_of "${target}")" plainround/web:1.0.0 plainround/web:1.1.0
done
if [ "$#" -eq 0 ]; then
  log "loading the Git server image into ${HUB}"
  provider_load_images "${HUB}" plainround/git-server:1.0.0
fi
```

- `build <folder> <tag> [flags]` builds an image unless it already exists (`docker image inspect "${tag}" >/dev/null 2>&1 && return 0` leaves the function early if the image is there). Three images: the web application at 1.0.0 and 1.1.0 and the Git server.
- The arguments are the clusters to load the web images into: `for target in "$@"; do provider_load_images "$(cluster_of "${target}")" …; done`. With **no** arguments (`[ "$#" -eq 0 ]`, `$#` is the number of arguments) it loads the Git server image into the hub. So `build-images.sh` serves the hub and `build-images.sh dev staging production` the workload clusters; `demo4` is the fourth.

**`scripts/install-git-server.sh`**

```bash
#!/usr/bin/env bash
# Deploys the in-cluster Git server on the hub and waits until it answers on the host port.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl curl

kc apply --server-side -k "${ROOT}/platform/git-server" >/dev/null
kc -n git-server rollout status deployment/git-server --timeout="${WAIT_TIMEOUT}s"
wait_for "the Git server on ${GIT_HOST_URL}" 90 curl -fsS "${GIT_HOST_URL}/info/refs?service=git-upload-pack"
```

- Applies the Git server objects (`kc apply --server-side -k platform/git-server`: build with Kustomize and let the cluster merge), waits for the pod (`rollout status`), and polls the server's address with `curl` until it answers, up to 90 seconds.

**`scripts/install-argocd.sh`**

```bash
#!/usr/bin/env bash
# Installs Argo CD on the hub at the pinned version and waits for its components.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl

pinned="$(grep -oE 'argo-cd/v[0-9.]+/' "${ROOT}/platform/argocd/kustomization.yaml" | head -1 | tr -d '/' | sed 's/argo-cd//')"
[ "${pinned}" = "${ARGOCD_VERSION}" ] || die "platform/argocd pins ${pinned}, versions.env says ${ARGOCD_VERSION}"

log "installing Argo CD ${ARGOCD_VERSION} on the hub"
# Server-side apply: the ApplicationSet CRD is too large for the client-side last-applied annotation.
kc apply --server-side --force-conflicts -k "${ROOT}/platform/argocd" >/dev/null
kc -n argocd rollout status statefulset/argocd-application-controller --timeout="${WAIT_TIMEOUT}s"
for deployment in argocd-repo-server argocd-applicationset-controller argocd-redis; do
  kc -n argocd rollout status "deployment/${deployment}" --timeout="${WAIT_TIMEOUT}s"
done
```

- Compares the Argo CD version written in the Kustomize file with `versions.env`: `grep -oE 'argo-cd/v[0-9.]+/'` prints only the matching part, `head -1` keeps the first, `tr -d '/'` deletes slashes, `sed 's/argo-cd//'` deletes the text `argo-cd` (leaving `v3.5.6`). Then it applies Argo CD with `--server-side --force-conflicts` (the comment explains: the ApplicationSet definition is too large for the client-side method) and waits for the controller (a StatefulSet) and three Deployments.

**`scripts/seed-repo.sh`**

```bash
#!/usr/bin/env bash
# Creates the working clone of gitops-fleet from manifests/ and pushes it to the hub's Git server. The first commit
# pins staging and production to itself (dev follows main), so a later commit reaches them only through the waves.
#   seed-repo.sh            create the clone if it is missing
#   seed-repo.sh --reset    throw it away and start again
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require git curl

if [ "${1:-}" = "--reset" ]; then
  rm -rf "${WORK_CLONE}"
fi
if [ -d "${WORK_CLONE}/.git" ]; then
  log "working clone already exists at ${WORK_CLONE#"${ROOT}"/}"
  exit 0
fi

mkdir -p "${WORK_CLONE}"
cp -R "${ROOT}/manifests/." "${WORK_CLONE}/"
git -C "${WORK_CLONE}" init --quiet --initial-branch=main
git -C "${WORK_CLONE}" config user.name "Runbook"
git -C "${WORK_CLONE}" config user.email "runbook@example.invalid"
git -C "${WORK_CLONE}" config commit.gpgsign false
cat > "${WORK_CLONE}/.git/hooks/pre-push" <<HOOK
#!/usr/bin/env bash
exec "${ROOT}/scripts/validate.sh" "${WORK_CLONE}"
HOOK
chmod +x "${WORK_CLONE}/.git/hooks/pre-push"

work_git add --all
work_git commit --quiet -m "Initial fleet: web 1.0.0 in dev, staging and production, with admission policy"
first="$(work_head)"
set_stage_value staging revision "${first}"
set_stage_value production revision "${first}"
work_git add --all
work_git commit --quiet -m "Pin staging and production to the first commit"
work_git remote add origin "${GIT_HOST_URL}"
work_git push --quiet --force origin main
log "seeded gitops-fleet at $(work_head | cut -c1-7); staging and production pinned to ${first:0:7}"
```

- Creates the working clone of the fleet repository. With `--reset` the clone is deleted first; an existing clone ends the script (`exit 0`). It copies `manifests/` into the clone, runs `git init --initial-branch=main`, sets a fixed author and turns off commit signing, and writes the `pre-push` hook with a here-document (`cat > file <<HOOK … HOOK`; the unquoted marker lets `${ROOT}` be replaced). The hook runs `validate.sh` before every push (`exec` replaces the shell so the hook's exit code is the validator's) and `chmod +x` makes it executable.
- It makes **two commits**: the whole fleet first (`first="$(work_head)"` remembers its hash), then it changes two lines with `set_stage_value` so that staging and production are **pinned to the first commit** (dev stays on `main`), and commits again. Finally it adds the Git server as the remote `origin`, force-pushes `main` and logs the short hash. After this, a new commit on `main` reaches dev at once but staging and production only through `promote.sh`.

**`scripts/bootstrap.sh`**

```bash
#!/usr/bin/env bash
# The one object applied by hand: the root Application, which syncs hub/ (both ApplicationSets and the projects).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl

kc apply -f "${ROOT}/platform/root-application.yaml"
```

- The only object applied by hand on the hub: the root Application, which syncs the `hub/` folder (the ApplicationSets and the projects) from Git.

**`scripts/register-cluster.sh`**

```bash
#!/usr/bin/env bash
# Registers a workload cluster with the hub's Argo CD, the way `argocd cluster add` does: a service account and token
# in the target, a cluster Secret in the hub carrying the labels app=web and stage=<stage>.
#   register-cluster.sh <cluster> <stage>      e.g. dev dev, or demo4 dev
#   register-cluster.sh --remove <cluster>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl

if [ "${1:-}" = "--remove" ]; then
  kc -n argocd delete secret "cluster-${2:?usage: register-cluster.sh --remove <cluster>}" --ignore-not-found
  exit 0
fi

cluster="${1:?usage: register-cluster.sh <cluster> <stage>}"
stage="${2:?usage: register-cluster.sh <cluster> <stage>}"
context="$(provider_context "$(cluster_of "${cluster}")")"

kubectl --context "${context}" apply -f "${ROOT}/platform/cluster-access/argocd-manager.yaml" >/dev/null
read_token() { kubectl --context "${context}" -n kube-system get secret argocd-manager-token -o 'jsonpath={.data.token}' | base64 -d; }
wait_for "the service account token to be issued" 60 test -n "$(read_token)"
token="$(read_token)"
ca="$(kubectl --context "${context}" -n kube-system get secret argocd-manager-token -o 'jsonpath={.data.ca\.crt}')"
# The hub reaches the other clusters over the shared Docker network, by the node container's name.
server="https://$(provider_api_host "$(cluster_of "${cluster}")"):6443"

kc apply -f - >/dev/null <<SECRET
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${cluster}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    app: web
    stage: ${stage}
type: Opaque
stringData:
  name: ${cluster}
  server: ${server}
  config: |
    {"bearerToken": "${token}", "tlsClientConfig": {"insecure": false, "caData": "${ca}"}}
SECRET
log "registered ${cluster} (stage=${stage}, ${server})"
```

- Registers a workload cluster with the hub's Argo CD, as `argocd cluster add` would. With `--remove <cluster>` it deletes the cluster's Secret on the hub and stops. Otherwise: `cluster` and `stage` are required arguments; `context` is the workload cluster's `kubectl` context.
- It applies a service account, a role binding and a token Secret to the **workload** cluster (`platform/cluster-access/argocd-manager.yaml`), then waits until Kubernetes has filled in the token (`read_token` fetches it and `base64 -d` decodes it; Kubernetes stores Secret values in base64, a text encoding of binary data). `ca` is the cluster's certificate (`ca.crt`; the backslash escapes the dot in the key name) so the hub can verify it is talking to the right server. `server` is `https://<api-host>:6443`, the cluster's address on the shared Docker network.
- Finally it applies a Secret **on the hub** with a here-document: labels `argocd.argoproj.io/secret-type: cluster` (this is what makes it a registered cluster), `app: web` and `stage: <stage>` (what the ApplicationSet selects on); `name`, `server` and a JSON `config` with the bearer token and the certificate. The `kc apply -f - >/dev/null <<SECRET` form reads the YAML from the lines that follow.

**`scripts/status.sh`**

```bash
#!/usr/bin/env bash
# One screen of state: the Applications the hub generated, and what each cluster runs.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

kc -n argocd get applications -o 'custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision,PROJECT:.spec.project' |
  sed -E 's/([0-9a-f]{7})[0-9a-f]{33}/\1/'
for stage in "${STAGES[@]}"; do
  printf '%-11s image=%s replicas=%s\n' "${stage}" \
    "$(wk "${stage}" -n web get deploy web -o 'jsonpath={.spec.template.spec.containers[0].image}' 2>/dev/null)" \
    "$(wk "${stage}" -n web get deploy web -o 'jsonpath={.status.readyReplicas}/{.spec.replicas}' 2>/dev/null)"
done
```

- Prints the Applications of the hub with chosen columns (`custom-columns=NAME:…,SYNC:…`; `sed -E 's/([0-9a-f]{7})[0-9a-f]{33}/\1/'` shortens each 40-character commit hash to 7 characters), then for each stage the image and the ready/wanted replicas read from that workload cluster (`printf '%-11s …'` pads the first column to 11 characters).

**`scripts/down.sh`**

```bash
#!/usr/bin/env bash
# Deletes every cluster of the fleet (including a leftover demo4) and the working clone.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require "${CLUSTER_PROVIDER}"

for name in "${HUB}" "$(cluster_of dev)" "$(cluster_of staging)" "$(cluster_of production)" "$(cluster_of demo4)"; do
  if provider_exists "${name}"; then provider_delete "${name}"; fi
done
docker network rm "${FLEET_NETWORK}" >/dev/null 2>&1 || true
rm -rf "${WORK_DIR}" "${ROOT}/logs"
```

- Deletes every cluster of the fleet including a left-over `demo4` (`if provider_exists …; then provider_delete …; fi`), removes the shared Docker network (errors hidden) and the working folders.

#### Scripts that check things

**`scripts/validate.sh`**

```bash
#!/usr/bin/env bash
# Checks the desired-state tree. Exit status 0 means every check passed.
#   validate.sh [tree]       default: manifests/ of this project
# 1. apps/web/base renders with kustomize and passes kubeconform strictly.
# 2. hub/ and policy/ pass the Kubernetes and community CRD schemas.
# 3. clusters/*.yaml have the shape the ApplicationSet reads (scripts/check_clusters.py).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl kubeconform python3

tree="${1:-${ROOT}/manifests}"
cache="${XDG_CACHE_HOME:-${HOME}/.cache}/plainround-kubeconform"
mkdir -p "${cache}"
common=(-strict -summary -kubernetes-version "${KUBECONFORM_KUBERNETES_VERSION}" -cache "${cache}")
crds='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
python="${ROOT}/.venv/bin/python"
[ -x "${python}" ] || python="python3"

status=0
log "clusters/*.yaml"
"${python}" "${ROOT}/scripts/check_clusters.py" "${tree}" || status=1
log "kustomize build apps/web/base"
kubectl kustomize "${tree}/apps/web/base" | kubeconform "${common[@]}" - || status=1
log "hub/ and policy/"
kubeconform "${common[@]}" -schema-location default -schema-location "${crds}" "${tree}/hub" "${tree}/policy" || status=1
exit "${status}"
```

- Checks a desired-state tree (default `manifests/`). The options are kept in an **array** `common=(…)` reused twice: strict checking, a summary, the Kubernetes version, and a cache folder. `crds` is an address template for the rules of non-standard kinds (`{{.Group}}` and so on are filled in by `kubeconform`). It uses the project's Python if it exists (`[ -x file ]` tests that a file is executable).
- `status=0`; three checks, each with `|| status=1` so a failure is recorded without stopping: the stage files (`check_clusters.py`), the application base (built by `kubectl kustomize` and piped into `kubeconform … -`, where `-` means standard input), and the `hub/` and `policy/` folders against the standard plus community rules. `exit "${status}"` ends with the result.

**`scripts/ci-install-tools.sh`** (runs only on the automated-checks machine)

```bash
#!/usr/bin/env bash
# Installs the tools CI needs on an Ubuntu runner: kubeconform. Local machines use `brew install kubeconform`.
set -euo pipefail

version="v0.8.0"
curl -fsSL "https://github.com/yannh/kubeconform/releases/download/${version}/kubeconform-linux-amd64.tar.gz" | sudo tar -xz -C /usr/local/bin kubeconform
kubeconform -v
```

- Downloads kubeconform at an exact version and unpacks it into `/usr/local/bin`: `curl -fsSL URL | sudo tar -xz -C folder file` (`-L` follows redirects; the archive goes through a pipe into `tar`; `-x` extract, `-z` gzip-compressed, `-C` target folder; `sudo` for administrator rights). The last line prints the version as a check.

#### The wave scripts

**`scripts/best-case.sh`**

```bash
#!/usr/bin/env bash
# Step 1: how long a change takes to reach production at best, from the numbers in the repository.
#   best-case.sh            the configured numbers: clusters/*.yaml, the poll in platform/argocd, the requeue in hub/appset-web.yaml
#   best-case.sh --lesson   the lesson's observation windows (five and ten minutes) and its one-minute poll
# Best case = the hub notices the commit on dev (one poll) + dev observed + the pin of staging is seen by the
# ApplicationSet (one requeue) + staging observed + the pin of production is seen (one requeue). The wait for
# production's sync window is zero when the change lands inside the window.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

requeue="$(grep -oE 'requeueAfterSeconds: [0-9]+' "${ROOT}/manifests/hub/appset-web.yaml" | grep -oE '[0-9]+')"
if [ "${1:-}" = "--lesson" ]; then
  label="the lesson's windows"
  poll=60 dev_observe=300 staging_observe=600
else
  label="configured"
  poll="$(grep -oE 'timeout.reconciliation: [0-9]+s' "${ROOT}/platform/argocd/controller-settings.yaml" | grep -oE '[0-9]+')"
  dev_observe="$(grep -E '^observeSeconds:' "${ROOT}/manifests/clusters/dev.yaml" | grep -oE '[0-9]+')"
  staging_observe="$(grep -E '^observeSeconds:' "${ROOT}/manifests/clusters/staging.yaml" | grep -oE '[0-9]+')"
fi
total=$((poll + dev_observe + requeue + staging_observe + requeue))
printf '%s: poll %ss + dev observation %ss + requeue %ss + staging observation %ss + requeue %ss = %ss (%s min %s s)\n' \
  "${label}" "${poll}" "${dev_observe}" "${requeue}" "${staging_observe}" "${requeue}" "${total}" "$((total / 60))" "$((total % 60))"
echo "what stops it: a gate that closes (dev or staging not Healthy at the commit) halts the wave; production's sync window holds a healthy change until its window opens"
```

- Computes how long a change takes to reach production at best, **from the numbers in the repository**. `requeue` is read from `appset-web.yaml` (`grep -oE 'requeueAfterSeconds: [0-9]+' file | grep -oE '[0-9]+'`: the first grep finds the setting, the second keeps only the digits). With `--lesson` the lesson's numbers are used (a one-minute poll, 5- and 10-minute observation windows); otherwise the configured ones are read from `controller-settings.yaml` and the two stage files. `total=$((poll + dev_observe + requeue + staging_observe + requeue))` adds them (`$(( ))` is whole-number arithmetic) and `printf` prints the sum in seconds and as minutes and seconds (`/` and `%` are division and remainder). The last line says what stops a wave: a closed gate, or production's sync window.

**`scripts/gate.sh`**: the health gate between two waves

```bash
#!/usr/bin/env bash
# The health gate between two waves. Succeeds only when the stage applied <revision> and then stayed Healthy for
# the stage's observeSeconds (clusters/<stage>.yaml). Fails at once when the stage turns Degraded, or after the
# timeout when it never applies the revision.
#   gate.sh <stage> <revision>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

stage="${1:?usage: gate.sh <stage> <revision>}"
revision="${2:?usage: gate.sh <stage> <revision>}"
observe="$(stage_value "${stage}" observeSeconds)"

waited=0
until applied_at "${stage}" "${revision}"; do
  if [ "$(app_health "${stage}")" = "Degraded" ] && [ "$(app_field "web-${stage}" '{.status.sync.revision}')" != "" ] \
     && work_git merge-base --is-ancestor "${revision}" "$(app_revision "${stage}")" 2>/dev/null; then
    log "gate closed: ${stage} is Degraded at ${revision:0:7}"
    exit 1
  fi
  if operation_failed "${stage}" && work_git merge-base --is-ancestor "${revision}" "$(app_revision "${stage}")" 2>/dev/null; then
    log "gate closed: the sync of ${revision:0:7} failed in ${stage}: $(operation_message "${stage}" | cut -c1-160)"
    exit 1
  fi
  if [ "${waited}" -ge "${WAIT_TIMEOUT}" ]; then
    log "gate closed: ${stage} did not apply ${revision:0:7} within ${WAIT_TIMEOUT}s"
    exit 1
  fi
  sleep 2
  waited=$((waited + 2))
done

log "${stage} applied ${revision:0:7}; observing for ${observe}s"
elapsed=0
while [ "${elapsed}" -lt "${observe}" ]; do
  if [ "$(app_health "${stage}")" != "Healthy" ]; then
    log "gate closed: ${stage} stopped being Healthy after ${elapsed}s"
    exit 1
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done
log "gate open: ${stage} stayed Healthy for ${observe}s at ${revision:0:7}"
```

- `gate.sh <stage> <revision>` succeeds only if the stage applied the revision and then stayed Healthy for the stage's `observeSeconds`. First loop: `until applied_at …; do …; done` waits for the stage to apply the commit, but fails at once (`exit 1`) if the stage turns `Degraded` at that revision, or if its sync failed (both use `git merge-base --is-ancestor` to make sure the failure is about *this* commit or a later one), or when `WAIT_TIMEOUT` seconds pass. Second loop: `while [ "${elapsed}" -lt "${observe}" ]` checks every two seconds that the app is still Healthy for the observation time; any change closes the gate. When the loops end, the gate is open (exit 0).

**`scripts/promote.sh`**

```bash
#!/usr/bin/env bash
# Moves a change through the waves: dev (which follows main), then staging, then production. Each later stage is pinned
# to the commit by a commit of its own (clusters/<stage>.yaml), and only after the stage before it passed its gate.
#   promote.sh [--through staging|production] [<revision>]     default: production, the tip of main
# A closed gate stops the wave: the later stages are never pinned, so they never see the commit.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

through=production
if [ "${1:-}" = "--through" ]; then
  through="${2:?usage: promote.sh --through staging|production}"
  shift 2
fi
change="${1:-$(work_head)}"

if ! "${ROOT}/scripts/gate.sh" dev "${change}"; then
  log "wave stopped at dev: staging and production never receive ${change:0:7}"
  exit 1
fi

set_stage_value staging revision "${change}"
commit_and_push "Wave 2: pin staging to ${change:0:7}" >/dev/null
if ! "${ROOT}/scripts/gate.sh" staging "${change}"; then
  log "wave stopped at staging: production never receives ${change:0:7}"
  exit 1
fi
[ "${through}" = "staging" ] && exit 0

set_stage_value production revision "${change}"
commit_and_push "Wave 3: pin production to ${change:0:7}" >/dev/null
log "production is pinned to ${change:0:7}; it syncs when its window is open"
```

- Moves a change through the waves: dev, then staging, then production. `through=production`; with `--through staging` it stops after staging. `change="${1:-$(work_head)}"` is the commit to promote (default: the newest). `if ! gate.sh dev …; then log …; exit 1; fi`: if dev's gate closes the wave stops and **staging and production never get the commit**. Otherwise `set_stage_value staging revision <commit>` plus `commit_and_push` pins staging (one line, one commit), then the staging gate; then production is pinned the same way, and the script logs that production syncs when its window is open.

#### The runbook

**`scripts/run.sh`**

```bash
#!/usr/bin/env bash
# The whole lesson as one scripted run, printing what happens at each step. `make up` must have finished first.
# The controller outage uses OUTAGE_SECONDS (.env); run it with OUTAGE_SECONDS=1800 for the lesson's half hour.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

step() { printf '\n==== %s ====\n' "$*"; }
runbook() { "${ROOT}/scripts/runbook/$1" "${@:2}"; }

step "Step 1: the design's best case"
"${ROOT}/scripts/best-case.sh"
"${ROOT}/scripts/best-case.sh" --lesson
step "Step 2: one Application per cluster"
runbook 02-generate-apps.sh list
runbook 02-generate-apps.sh add
runbook 02-generate-apps.sh remove
step "Step 3: waves, a gate and a sync window"
runbook window.sh closed >/dev/null
runbook 03-waves.sh good
runbook 03-waves.sh open
runbook 03-waves.sh bad
runbook 03-waves.sh revert
step "Step 4: admission policy in every cluster"
runbook 04-policy.sh privileged
runbook 04-policy.sh revert
step "Step 5: a destructive commit"
runbook 05-destructive-commit.sh commit
runbook 05-destructive-commit.sh revert
step "Step 6: the controller is lost"
runbook 06-controller-outage.sh
step "Where it ended"
"${ROOT}/scripts/status.sh"
```

- The whole lesson as one run. `step` prints a banner; `runbook() { "${ROOT}/scripts/runbook/$1" "${@:2}"; }` runs a runbook script by name, passing the arguments after the first (`${@:2}` = all arguments from the second on). Then the steps in order, each script with its variants as arguments.

**`scripts/runbook/02-generate-apps.sh`**

```bash
#!/usr/bin/env bash
# Lesson step 2: one Application per registered cluster, with no per-cluster manifest. Registering a fourth cluster
# (demo4) adds a fourth Application; deregistering it removes the Application again.
#   02-generate-apps.sh list     the Applications that exist now
#   02-generate-apps.sh add      create and register demo4, wait for web-demo4 to appear and sync
#   02-generate-apps.sh remove   deregister demo4, wait for web-demo4 to disappear, delete the cluster
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

web_applications() { kc -n argocd get applications -l app=web -o 'custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,CLUSTER:.spec.destination.server'; }
application_exists() { kc -n argocd get application "web-demo4" >/dev/null 2>&1; }
application_gone() { ! application_exists; }

case "${1:-}" in
  list) web_applications ;;
  add)
    "${ROOT}/scripts/cluster-up.sh" demo4
    "${ROOT}/scripts/build-images.sh" demo4
    "${ROOT}/scripts/register-cluster.sh" demo4 dev
    wait_for "web-demo4 to be generated" 120 application_exists
    wait_for "web-demo4 to be Synced and Healthy" "${WAIT_TIMEOUT}" synced_and_healthy demo4
    web_applications
    echo "web-demo4 serves: $(web_get demo4 /)"
    ;;
  remove)
    "${ROOT}/scripts/register-cluster.sh" --remove demo4
    wait_for "web-demo4 to disappear" 120 application_gone
    provider_delete "$(cluster_of demo4)"
    web_applications
    ;;
  *) die "usage: 02-generate-apps.sh list|add|remove" ;;
esac
```

- `list` shows the generated Applications (`custom-columns`). `add` creates a fourth cluster `demo4`, loads the images into it, registers it as stage `dev`, waits for the Application `web-demo4` to **appear** (nobody wrote a manifest for it) and to be Synced and Healthy, lists the Applications and fetches the application's page (`web_get`). `remove` deregisters it, waits for the Application to disappear and deletes the cluster. `application_gone() { ! application_exists; }` reverses a function's result with `!`.

**`scripts/runbook/03-waves.sh`**

```bash
#!/usr/bin/env bash
# Lesson step 3: waves with a health gate, and a production sync window.
#   03-waves.sh good      a good change (web 1.1.0) goes dev, gate, staging, gate, and then waits for production's window
#   03-waves.sh open      open the window: production applies the pinned commit
#   03-waves.sh bad       a change whose readiness probe never passes: dev's gate closes, staging and production never get it
#   03-waves.sh revert    git revert the bad commit
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

marker="${WORK_DIR}/bad-commit"
live_image() { wk "$1" -n web get deploy web -o 'jsonpath={.spec.template.spec.containers[0].image}'; }
staged_revision() { stage_value "$1" revision; }

case "${1:-}" in
  good)
    perl -pi -e 's#plainround/web:1\.0\.0#plainround/web:1.1.0#' "${WORK_CLONE}/apps/web/base/deployment.yaml"
    change="$(commit_and_push "Ship web 1.1.0")"
    echo "${change}" > "${WORK_DIR}/good-commit"
    started=$SECONDS
    "${ROOT}/scripts/promote.sh" "${change}"
    echo "dev:        $(live_image dev)  sync=$(app_sync dev) health=$(app_health dev)"
    echo "staging:    $(live_image staging)  sync=$(app_sync staging) health=$(app_health staging)"
    echo "production: $(live_image production)  sync=$(app_sync production) (pinned to ${change:0:7}; the window decides)"
    echo "waves took $((SECONDS - started))s from push to the production pin"
    ;;
  open)
    "${ROOT}/scripts/runbook/window.sh" open >/dev/null
    change="$(cat "${WORK_DIR}/good-commit")"
    wait_for "production to apply ${change:0:7} once the window is open" "${WAIT_TIMEOUT}" applied_at production "${change}"
    echo "production: $(live_image production)  sync=$(app_sync production) health=$(app_health production)"
    ;;
  bad)
    perl -0pi -e 's#(readinessProbe:\s+httpGet:\s+path: )/healthz#$1/definitely-missing#' "${WORK_CLONE}/apps/web/base/deployment.yaml"
    change="$(commit_and_push "Ship a web whose readiness probe never passes")"
    echo "${change}" > "${marker}"
    if "${ROOT}/scripts/promote.sh" "${change}"; then die "the gate let a Degraded commit through"; fi
    echo "dev:     health=$(app_health dev)  (the readiness probe never passes)"
    echo "staging: pinned to $(staged_revision staging | cut -c1-7), not to ${change:0:7}; health=$(app_health staging)"
    echo "production: pinned to $(staged_revision production | cut -c1-7), not to ${change:0:7}"
    ;;
  revert)
    [ -f "${marker}" ] || die "no bad commit recorded; run 03-waves.sh bad first"
    work_git revert --no-edit "$(cat "${marker}")" >/dev/null
    work_git push --quiet origin main
    wait_for "dev Healthy again" "${WAIT_TIMEOUT}" output_is Healthy app_health dev
    ;;
  *) die "usage: 03-waves.sh good|open|bad|revert" ;;
esac
```

- Four variants. `good`: change the image tag from 1.0.0 to 1.1.0 with `perl -pi -e 's#old#new#'` (`#` as the delimiter so the slashes need no escaping), commit, remember the commit in a file, and run `promote.sh`; then print each stage's image and status and the elapsed time (`SECONDS` is Bash's count of seconds since the script started). `open`: open production's sync window (`window.sh open`) and wait until production applies the commit. `bad`: break the **readiness probe path** with `perl -0pi -e` (`-0` reads the whole file as one string so the pattern can span lines; `\s+` matches runs of spaces and line breaks), commit, and run `promote.sh`, which is **expected to fail** (`if promote.sh; then die …; fi`); it prints that staging and production are still pinned to the old commit. `revert`: `git revert --no-edit` of the saved bad commit (a new commit that undoes it) and wait for dev to be Healthy.

**`scripts/runbook/04-policy.sh`**

```bash
#!/usr/bin/env bash
# Lesson step 4: admission policy in every cluster, from the same repository. A commit with a privileged container
# (or an image from outside plainround/) is refused by every cluster's API server, with the policy's own message.
#   04-policy.sh privileged | foreign | revert
# The commit is pinned to all three stages at once, as a person with commit access could do, so the policy, not the
# waves, is what stops it. The production window must be open (03-waves.sh open) for production to try the sync.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

marker="${WORK_DIR}/policy-commit"
deployment="${WORK_CLONE}/apps/web/base/deployment.yaml"

pin_everywhere() {
  local sha="$1" stage
  for stage in staging production; do set_stage_value "${stage}" revision "${sha}"; done
  commit_and_push "Pin staging and production to ${sha:0:7} (policy test)" >/dev/null
}

case "${1:-}" in
  privileged|foreign)
    if [ "$1" = privileged ]; then
      # A privileged container needs allowPrivilegeEscalation too, or the API server's own validation refuses it first.
      perl -0pi -e 's#(          securityContext:\n)#$1            privileged: true\n#; s#allowPrivilegeEscalation: false#allowPrivilegeEscalation: true#' "${deployment}"
      expected="privileged containers are not allowed"
    else
      perl -pi -e 's#image: plainround/web:1\.\d\.\d#image: docker.io/library/nginx:1.27#' "${deployment}"
      expected="images must come from plainround/"
    fi
    sha="$(commit_and_push "Ship a manifest the fleet's policy must refuse (${1})")"
    echo "${sha}" > "${marker}"
    pin_everywhere "${sha}"
    for stage in "${STAGES[@]}"; do
      wait_for "${stage} to refuse the sync" "${WAIT_TIMEOUT}" operation_failed "${stage}"
      message="$(operation_message "${stage}")"
      case "${message}" in *"${expected}"*) ;; *) die "${stage} failed for another reason: ${message}" ;; esac
      echo "${stage}: ${expected} (operation $(app_field "web-${stage}" '{.status.operationState.phase}'))"
    done
    echo "--- the same rule, with no controller involved (kubectl run --privileged in each cluster):"
    for stage in "${STAGES[@]}"; do
      wk "${stage}" -n web run attacker --image=plainround/web:1.0.0 --privileged --restart=Never 2>&1 | grep -o "denied the request: .*" || die "${stage} created a privileged pod"
    done
    ;;
  revert)
    [ -f "${marker}" ] || die "no policy commit recorded; run 04-policy.sh privileged first"
    work_git revert --no-edit "$(cat "${marker}")" >/dev/null
    work_git push --quiet origin main
    reverted="$(work_head)"
    for stage in staging production; do set_stage_value "${stage}" revision "${reverted}"; done
    commit_and_push "Pin staging and production to the revert" >/dev/null
    for stage in "${STAGES[@]}"; do
      wait_for "${stage} Synced and Healthy again" "${WAIT_TIMEOUT}" synced_and_healthy "${stage}"
    done
    ;;
  *) die "usage: 04-policy.sh privileged|foreign|revert" ;;
esac
```

- Commits a manifest the policy must refuse and shows every cluster refusing it. `pin_everywhere` pins staging and production to the bad commit too, so only the policy (not the waves) can stop it. For `privileged`, a `perl -0pi` edit adds `privileged: true` to the container's security settings and sets `allowPrivilegeEscalation: true` (otherwise Kubernetes's own validation would refuse it first, with a different message); for `foreign`, it changes the image to `docker.io/library/nginx:1.27`. Then for each stage: `wait_for … operation_failed` and a `case "${message}" in *"${expected}"*) ;; *) die …; esac` check that the failure message **contains** the policy's text. Last, `kubectl run attacker --privileged` is tried in each cluster directly and `grep -o "denied the request: .*"` prints the API server's refusal: the policy also stops people, not only Argo CD. `revert` reverts the commit and re-pins staging and production to the revert.

**`scripts/runbook/05-destructive-commit.sh`**

```bash
#!/usr/bin/env bash
# Lesson step 5: a commit deletes the namespace's manifest. With the protections in place (prune off in production,
# Prune=false on the Namespace) nothing is deleted anywhere; the controller flags the difference and git revert clears it.
#   05-destructive-commit.sh commit | revert
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

marker="${WORK_DIR}/destructive-commit"
extra_namespace() { app_field "web-$1" '{range .status.resources[?(@.requiresPruning==true)]}{.kind}/{.name}{"\n"}{end}'; }
sync_is() { [ "$(app_sync "$1")" = "$2" ]; }

case "${1:-}" in
  commit)
    work_git rm --quiet apps/web/base/namespace.yaml
    perl -ni -e 'print unless /^  - namespace.yaml$/' "${WORK_CLONE}/apps/web/base/kustomization.yaml"
    change="$(commit_and_push "Delete the web namespace manifest")"
    echo "${change}" > "${marker}"
    "${ROOT}/scripts/promote.sh" "${change}"
    for stage in production dev; do
      wait_for "${stage} to flag the namespace as extra" "${WAIT_TIMEOUT}" sync_is "${stage}" OutOfSync
      echo "${stage}: sync=$(app_sync "${stage}") health=$(app_health "${stage}") requires pruning: $(extra_namespace "${stage}" | tr '\n' ' ')"
      echo "${stage}: namespace $(wk "${stage}" get namespace web -o 'jsonpath={.status.phase}') with $(wk "${stage}" -n web get pods --no-headers | wc -l | tr -d ' ') pods"
    done
    ;;
  revert)
    [ -f "${marker}" ] || die "no destructive commit recorded; run 05-destructive-commit.sh commit first"
    work_git revert --no-edit "$(cat "${marker}")" >/dev/null
    work_git push --quiet origin main
    reverted="$(work_head)"
    for stage in staging production; do set_stage_value "${stage}" revision "${reverted}"; done
    commit_and_push "Pin staging and production to the revert" >/dev/null
    for stage in "${STAGES[@]}"; do
      wait_for "${stage} Synced again" "${WAIT_TIMEOUT}" sync_is "${stage}" Synced
    done
    echo "every stage is Synced; the production namespace was never removed"
    ;;
  *) die "usage: 05-destructive-commit.sh commit|revert" ;;
esac
```

- `commit`: `git rm` removes `namespace.yaml` from Git, `perl -ni -e 'print unless /^  - namespace.yaml$/'` removes its line from the Kustomize list (`-n` = do not print automatically, so only lines that pass the `unless` test are printed), commits and promotes. For production and dev it waits until the Application is `OutOfSync` and prints what Argo CD says needs pruning (`extra_namespace`, a JSONPath filter `[?(@.requiresPruning==true)]`), the namespace's phase and the number of pods (`wc -l | tr -d ' '` counts lines and removes spaces): nothing was deleted. `revert` reverts, re-pins staging and production, and waits for every stage to be Synced.

**`scripts/runbook/06-controller-outage.sh`**

```bash
#!/usr/bin/env bash
# Lesson step 6: stop the controller (the hub's application-controller) for OUTAGE_SECONDS while a traffic loop hits the
# production app, drift production by hand mid-outage, then start the controller and watch the drift corrected.
#   06-controller-outage.sh [seconds]       default: OUTAGE_SECONDS (1800 = the lesson's thirty minutes)
# Prints one status code per second to logs/outage-traffic.log (200 each) and a summary.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

seconds="${1:-${OUTAGE_SECONDS}}"
log_file="${ROOT}/logs/outage-traffic.log"
mkdir -p "${ROOT}/logs"
: > "${log_file}"
production_replicas() { wk production -n web get deploy web -o 'jsonpath={.spec.replicas}'; }
controller_ready() { [ "$(kc -n argocd get statefulset argocd-application-controller -o 'jsonpath={.status.readyReplicas}')" = "1" ]; }
no_controller_pod() { [ -z "$(kc -n argocd get pods -l app.kubernetes.io/name=argocd-application-controller -o name)" ]; }

traffic() {
  while :; do
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 2 "http://127.0.0.1:$(host_port_of production)/healthz" >> "${log_file}" || echo 000 >> "${log_file}"
    sleep 1
  done
}

wait_for "production Synced before the outage" "${WAIT_TIMEOUT}" output_is Synced app_sync production
traffic &
traffic_pid=$!
trap 'kill "${traffic_pid}" 2>/dev/null || true' EXIT

kc -n argocd scale statefulset argocd-application-controller --replicas=0 >/dev/null
wait_for "the controller to stop" 120 no_controller_pod
log "controller down for ${seconds}s; traffic loop running"
sleep $((seconds / 2))
wk production -n web scale deploy web --replicas=4 >/dev/null
echo "mid-outage drift: replicas=$(production_replicas) (Git says 2)"
sleep $((seconds - seconds / 2))
echo "end of outage: replicas=$(production_replicas) (still 4: nothing reconciled)"

kc -n argocd scale statefulset argocd-application-controller --replicas=1 >/dev/null
wait_for "the controller to be back" 180 controller_ready
started=$SECONDS
reverted() { [ "$(production_replicas)" = "2" ]; }
wait_for "the drift to be corrected" 180 reverted
echo "drift corrected $((SECONDS - started))s after the controller returned: replicas=$(production_replicas)"

kill "${traffic_pid}" 2>/dev/null || true
trap - EXIT
total="$(wc -l < "${log_file}" | tr -d ' ')"
bad="$(grep -vc '^200$' "${log_file}" || true)"
echo "traffic: ${total} requests during and around the outage, ${bad} not 200"
```

- Stops the hub's controller for a number of seconds while a traffic loop calls the production app, drifts production by hand in the middle, then starts the controller and times the correction. `traffic() { while :; do curl -s -o /dev/null -w '%{http_code}\n' --max-time 2 URL >> "${log_file}" || echo 000 >> "${log_file}"; sleep 1; done; }` loops forever (`while :` — `:` is always true) writing one HTTP status code per second to a log (`-w` prints only the status code; a failed request writes `000`). `traffic &` runs it in the **background**; `traffic_pid=$!` saves its process number; `trap 'kill "${traffic_pid}" 2>/dev/null || true' EXIT` stops it however the script ends.
- `scale statefulset argocd-application-controller --replicas=0` stops the controller, `wait_for … no_controller_pod` confirms. `sleep $((seconds / 2))`, then `wk production -n web scale deploy web --replicas=4` drifts production; after the rest of the outage it prints that replicas are still 4 (nothing reconciled). `--replicas=1` restarts the controller; `wait_for … controller_ready`; then it waits for production to return to 2 replicas and prints how long that took. At the end `wc -l < file` counts the requests and `grep -vc '^200$'` counts those that were **not** `200`.

**`scripts/runbook/window.sh`**

```bash
#!/usr/bin/env bash
# Moves production's sync window by committing to Git (the AppProject lives in hub/projects.yaml, synced by the root
# Application). A one-hour window that starts at an hour boundary is either open now or not, so the tests choose:
#   window.sh open       the window of the current UTC hour: production may sync now
#   window.sh closed     the window twelve hours away: production must wait
#   window.sh default    22:00-23:00 UTC, the lesson's window
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

case "${1:-}" in
  open) start=$((10#$(date -u +%H))) ;;
  closed) start=$(((10#$(date -u +%H) + 12) % 24)) ;;
  default) start=22 ;;
  *) die "usage: window.sh open|closed|default" ;;
esac
end=$(((start + 1) % 24))

perl -pi -e "s/schedule: \"0 \d+ \* \* \*\"/schedule: \"0 ${start} * * *\"/" "${WORK_CLONE}/hub/projects.yaml"
perl -pi -e "s/^syncWindow:.*/syncWindow: \"$(printf '%02d:00-%02d:00' "${start}" "${end}") UTC\"/" "${WORK_CLONE}/clusters/production.yaml"
if work_git diff --quiet; then
  log "the window is already $1"
  exit 0
fi
sha="$(commit_and_push "Production sync window: $1 ($(printf '%02d:00-%02d:00' "${start}" "${end}") UTC)")"
window_in_cluster() { kc -n argocd get appproject production -o 'jsonpath={.spec.syncWindows[0].schedule}' | grep -qx "0 ${start} \* \* \*"; }
wait_for "the production project to carry the window 0 ${start} * * *" 120 window_in_cluster
echo "${sha}"
```

- Moves production's sync window by committing to Git. `open` uses the current UTC hour (`date -u +%H`; `10#…` forces base 10 because Bash would read `08` as an invalid octal number); `closed` uses the hour twelve hours away (`$(( … % 24 ))` wraps around midnight); `default` is 22. Two `perl -pi -e` commands change the cron hour in `hub/projects.yaml` and the documented window in `clusters/production.yaml`; `printf '%02d:00-%02d:00'` pads hours to two digits. If nothing changed (`work_git diff --quiet`) it says so. Otherwise it commits and waits until the AppProject in the cluster carries the new schedule (`window_in_cluster` reads it with JSONPath and `grep -qx`).

#### Configuration files

```bash
# Every version this project pins. Scripts and the Makefile source this file; change a version here only.
KIND_NODE_IMAGE=kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0
ARGOCD_VERSION=v3.5.6
WEB_BASE_IMAGE=nginxinc/nginx-unprivileged:1.31.7-alpine@sha256:b5047b9b76845eac124358373c6852377c52e4b05834a47647e955dd91cb8f1e
GIT_SERVER_BASE_IMAGE=alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a
KUBECONFORM_KUBERNETES_VERSION=1.35.0
K3S_IMAGE=rancher/k3s:v1.35.5-k3s1
```

- The pinned versions, one `NAME=value` per line, loaded with `source`: the kind node image, `ARGOCD_VERSION`, the base images of the web app and the Git server (written `name:tag@sha256:…`; a **digest** names exact bytes and cannot be re-pointed), the Kubernetes version of the manifest checker and the k3s image.

```
# Copied to .env by `make up`. Nothing here is a secret; every value has a default in scripts/lib.sh.
# How long the runbook and the tests wait for the controller, in seconds.
WAIT_TIMEOUT=300
# How long the controller-outage experiment keeps the controller down (the lesson says 1800, thirty minutes).
OUTAGE_SECONDS=1800
```

- The local choices copied to `.env` by `make up`: how long scripts wait and how long the controller outage lasts.
<!-- full-walkthrough:end -->

## 6. Try it yourself

1. `scripts/best-case.sh` : `configured: poll 20s + dev observation 30s + requeue 20s + staging observation 45s + requeue 20s = 135s (2 min 15 s)`.
2. `scripts/best-case.sh --lesson` : `1000s (16 min 40 s)`.
3. `bash -c 'source scripts/lib.sh; host_port_of production'` : `18103`.
4. `bash -c 'echo $((10#08 + 1))'` : `9` (and `echo $((08 + 1))` fails).
5. `shellcheck scripts/*.sh scripts/runbook/*.sh` : no output.

## 7. Mistakes people make

- **Unquoted variables.** `rm -rf $dir/` with an empty `dir` is a disaster; `"${dir}"` and `${var:?message}` stop it. Every variable here is quoted.
- **Forgetting that `$(...)` is evaluated once.** `wait_for "x" 60 test "$(cmd)" = ok` runs `cmd` one time, before the loop starts, and then checks a frozen string. This repository wraps checks in functions so they run again on every poll.
- **Ignoring failures.** Without `set -e` a script keeps going after an error. Every script here starts with `set -euo pipefail`.
- **`cd` in a script that later uses relative paths.** The scripts compute `ROOT` once and use absolute paths.
- **Using Bash features in `sh`.** A script with `#!/bin/sh` runs in a smaller shell; `[[ ]]`, arrays and `${var,,}` are Bash only.

## 8. Check yourself

1. What does a shebang line do?
   *Answer:* It tells the operating system which program should run the file.
2. What do `set -e`, `-u` and `-o pipefail` each protect against?
   *Answer:* `-e`: carrying on after a failing command. `-u`: using a variable that was never set. `pipefail`: hiding a failure in the first part of a pipe.
3. Why is `"${name}"` safer than `$name`?
   *Answer:* The quotes keep a value with spaces or special characters as one word, and the braces mark exactly where the name ends.
4. What is the difference between running `./lib.sh` and `source lib.sh`?
   *Answer:* Running starts a new process whose variables vanish at its end; `source` runs the lines in the current shell, so its functions stay available.
5. What exit code means success?
   *Answer:* 0.

## 9. Further reading

- Bash Reference Manual: <https://www.gnu.org/software/bash/manual/bash.html> (the shell's own manual).
- The Bash installed on macOS is old (3.2); the scripts here avoid features newer than Bash 3.2 where they can, and the CI runner uses Bash 5.
