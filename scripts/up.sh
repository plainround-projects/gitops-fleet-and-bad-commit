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
