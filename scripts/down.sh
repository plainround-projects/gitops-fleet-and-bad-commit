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
