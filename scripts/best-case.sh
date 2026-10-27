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
