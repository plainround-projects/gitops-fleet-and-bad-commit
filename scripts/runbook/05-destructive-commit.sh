#!/usr/bin/env bash
# Lesson step 5: a commit deletes the namespace's manifest. With the protections in place (prune off in production,
# Prune=false on the Namespace) nothing is deleted anywhere; the controller flags the difference and git revert clears it.
#   05-destructive-commit.sh commit | revert
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

marker="${WORK_DIR}/destructive-commit"
extra_namespace() { app_field "web-$1" '{range .status.resources[?(@.requiresPruning==true)]}{.kind}/{.name}{"\n"}{end}'; }
sync_is() { [ "$(app_sync "$1")" = "$2" ]; }

case "${1:-}" in
  commit)
    work_git rm --quiet apps/web/base/namespace.yaml
    perl -ni -e 'print unless /^  - namespace.yaml$/' "${WORK_CLONE}/apps/web/base/kustomization.yaml"
    change="$(commit_and_push "Delete the web namespace manifest")"
    echo "${change}" > "${marker}"
    "${ROOT}/scripts/promote.sh" "${change}"
    for stage in production dev; do
      wait_for "${stage} to flag the namespace as extra" "${WAIT_TIMEOUT}" sync_is "${stage}" OutOfSync
      echo "${stage}: sync=$(app_sync "${stage}") health=$(app_health "${stage}") requires pruning: $(extra_namespace "${stage}" | tr '\n' ' ')"
      echo "${stage}: namespace $(wk "${stage}" get namespace web -o 'jsonpath={.status.phase}') with $(wk "${stage}" -n web get pods --no-headers | wc -l | tr -d ' ') pods"
    done
    ;;
  revert)
    [ -f "${marker}" ] || die "no destructive commit recorded; run 05-destructive-commit.sh commit first"
    work_git revert --no-edit "$(cat "${marker}")" >/dev/null
    work_git push --quiet origin main
    reverted="$(work_head)"
    for stage in staging production; do set_stage_value "${stage}" revision "${reverted}"; done
    commit_and_push "Pin staging and production to the revert" >/dev/null
    for stage in "${STAGES[@]}"; do
      wait_for "${stage} Synced again" "${WAIT_TIMEOUT}" sync_is "${stage}" Synced
    done
    echo "every stage is Synced; the production namespace was never removed"
    ;;
  *) die "usage: 05-destructive-commit.sh commit|revert" ;;
esac
