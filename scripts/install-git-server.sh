#!/usr/bin/env bash
# Deploys the in-cluster Git server on the hub and waits until it answers on the host port.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl curl

kc apply --server-side -k "${ROOT}/platform/git-server" >/dev/null
kc -n git-server rollout status deployment/git-server --timeout="${WAIT_TIMEOUT}s"
wait_for "the Git server on ${GIT_HOST_URL}" 90 curl -fsS "${GIT_HOST_URL}/info/refs?service=git-upload-pack"
