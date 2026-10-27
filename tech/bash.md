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
