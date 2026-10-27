#!/usr/bin/env bash
# Lesson step 4: admission policy in every cluster, from the same repository. A commit with a privileged container
# (or an image from outside plainround/) is refused by every cluster's API server, with the policy's own message.
#   04-policy.sh privileged | foreign | revert
# The commit is pinned to all three stages at once, as a person with commit access could do, so the policy, not the
# waves, is what stops it. The production window must be open (03-waves.sh open) for production to try the sync.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

marker="${WORK_DIR}/policy-commit"
deployment="${WORK_CLONE}/apps/web/base/deployment.yaml"

pin_everywhere() {
  local sha="$1" stage
  for stage in staging production; do set_stage_value "${stage}" revision "${sha}"; done
  commit_and_push "Pin staging and production to ${sha:0:7} (policy test)" >/dev/null
}

case "${1:-}" in
  privileged|foreign)
    if [ "$1" = privileged ]; then
      # A privileged container needs allowPrivilegeEscalation too, or the API server's own validation refuses it first.
      perl -0pi -e 's#(          securityContext:\n)#$1            privileged: true\n#; s#allowPrivilegeEscalation: false#allowPrivilegeEscalation: true#' "${deployment}"
      expected="privileged containers are not allowed"
    else
      perl -pi -e 's#image: plainround/web:1\.\d\.\d#image: docker.io/library/nginx:1.27#' "${deployment}"
      expected="images must come from plainround/"
    fi
    sha="$(commit_and_push "Ship a manifest the fleet's policy must refuse (${1})")"
    echo "${sha}" > "${marker}"
    pin_everywhere "${sha}"
    for stage in "${STAGES[@]}"; do
      wait_for "${stage} to refuse the sync" "${WAIT_TIMEOUT}" operation_failed "${stage}"
      message="$(operation_message "${stage}")"
      case "${message}" in *"${expected}"*) ;; *) die "${stage} failed for another reason: ${message}" ;; esac
      echo "${stage}: ${expected} (operation $(app_field "web-${stage}" '{.status.operationState.phase}'))"
    done
    echo "--- the same rule, with no controller involved (kubectl run --privileged in each cluster):"
    for stage in "${STAGES[@]}"; do
      wk "${stage}" -n web run attacker --image=plainround/web:1.0.0 --privileged --restart=Never 2>&1 | grep -o "denied the request: .*" || die "${stage} created a privileged pod"
    done
    ;;
  revert)
    [ -f "${marker}" ] || die "no policy commit recorded; run 04-policy.sh privileged first"
    work_git revert --no-edit "$(cat "${marker}")" >/dev/null
    work_git push --quiet origin main
    reverted="$(work_head)"
    for stage in staging production; do set_stage_value "${stage}" revision "${reverted}"; done
    commit_and_push "Pin staging and production to the revert" >/dev/null
    for stage in "${STAGES[@]}"; do
      wait_for "${stage} Synced and Healthy again" "${WAIT_TIMEOUT}" synced_and_healthy "${stage}"
    done
    ;;
  *) die "usage: 04-policy.sh privileged|foreign|revert" ;;
esac
