#!/usr/bin/env bash
# Deletes every cluster of the fleet (including a leftover demo4) and the working clone.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kind

for name in "${HUB}" "$(cluster_of dev)" "$(cluster_of staging)" "$(cluster_of production)" "$(cluster_of demo4)"; do
  if kind get clusters 2>/dev/null | grep -qx "${name}"; then kind delete cluster --name "${name}"; fi
done
rm -rf "${WORK_DIR}" "${ROOT}/logs"
