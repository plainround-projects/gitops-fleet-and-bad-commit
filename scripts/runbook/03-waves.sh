#!/usr/bin/env bash
# Lesson step 3: waves with a health gate, and a production sync window.
#   03-waves.sh good      a good change (web 1.1.0) goes dev, gate, staging, gate, and then waits for production's window
#   03-waves.sh open      open the window: production applies the pinned commit
#   03-waves.sh bad       a change whose readiness probe never passes: dev's gate closes, staging and production never get it
#   03-waves.sh revert    git revert the bad commit
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

marker="${WORK_DIR}/bad-commit"
live_image() { wk "$1" -n web get deploy web -o 'jsonpath={.spec.template.spec.containers[0].image}'; }
staged_revision() { stage_value "$1" revision; }

case "${1:-}" in
  good)
    perl -pi -e 's#plainround/web:1\.0\.0#plainround/web:1.1.0#' "${WORK_CLONE}/apps/web/base/deployment.yaml"
    change="$(commit_and_push "Ship web 1.1.0")"
    echo "${change}" > "${WORK_DIR}/good-commit"
    started=$SECONDS
    "${ROOT}/scripts/promote.sh" "${change}"
    echo "dev:        $(live_image dev)  sync=$(app_sync dev) health=$(app_health dev)"
    echo "staging:    $(live_image staging)  sync=$(app_sync staging) health=$(app_health staging)"
    echo "production: $(live_image production)  sync=$(app_sync production) (pinned to ${change:0:7}; the window decides)"
    echo "waves took $((SECONDS - started))s from push to the production pin"
    ;;
  open)
    "${ROOT}/scripts/runbook/window.sh" open >/dev/null
    change="$(cat "${WORK_DIR}/good-commit")"
    wait_for "production to apply ${change:0:7} once the window is open" "${WAIT_TIMEOUT}" applied_at production "${change}"
    echo "production: $(live_image production)  sync=$(app_sync production) health=$(app_health production)"
    ;;
  bad)
    perl -0pi -e 's#(readinessProbe:\s+httpGet:\s+path: )/healthz#$1/definitely-missing#' "${WORK_CLONE}/apps/web/base/deployment.yaml"
    change="$(commit_and_push "Ship a web whose readiness probe never passes")"
    echo "${change}" > "${marker}"
    if "${ROOT}/scripts/promote.sh" "${change}"; then die "the gate let a Degraded commit through"; fi
    echo "dev:     health=$(app_health dev)  (the readiness probe never passes)"
    echo "staging: pinned to $(staged_revision staging | cut -c1-7), not to ${change:0:7}; health=$(app_health staging)"
    echo "production: pinned to $(staged_revision production | cut -c1-7), not to ${change:0:7}"
    ;;
  revert)
    [ -f "${marker}" ] || die "no bad commit recorded; run 03-waves.sh bad first"
    work_git revert --no-edit "$(cat "${marker}")" >/dev/null
    work_git push --quiet origin main
    wait_for "dev Healthy again" "${WAIT_TIMEOUT}" output_is Healthy app_health dev
    ;;
  *) die "usage: 03-waves.sh good|open|bad|revert" ;;
esac
