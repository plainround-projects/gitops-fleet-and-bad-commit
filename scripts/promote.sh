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
