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
  if operation_failed "${stage}" && work_git merge-base --is-ancestor "${revision}" "$(operation_revision "${stage}")" 2>/dev/null; then
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
