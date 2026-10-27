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
