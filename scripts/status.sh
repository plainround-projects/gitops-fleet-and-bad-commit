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
