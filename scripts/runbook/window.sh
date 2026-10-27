#!/usr/bin/env bash
# Moves production's sync window by committing to Git (the AppProject lives in hub/projects.yaml, synced by the root
# Application). A one-hour window that starts at an hour boundary is either open now or not, so the tests choose:
#   window.sh open       the window of the current UTC hour: production may sync now
#   window.sh closed     the window twelve hours away: production must wait
#   window.sh default    22:00-23:00 UTC, the lesson's window
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

case "${1:-}" in
  open) start=$((10#$(date -u +%H))) ;;
  closed) start=$(((10#$(date -u +%H) + 12) % 24)) ;;
  default) start=22 ;;
  *) die "usage: window.sh open|closed|default" ;;
esac
end=$(((start + 1) % 24))

perl -pi -e "s/schedule: \"0 \d+ \* \* \*\"/schedule: \"0 ${start} * * *\"/" "${WORK_CLONE}/hub/projects.yaml"
perl -pi -e "s/^syncWindow:.*/syncWindow: \"$(printf '%02d:00-%02d:00' "${start}" "${end}") UTC\"/" "${WORK_CLONE}/clusters/production.yaml"
if work_git diff --quiet; then
  log "the window is already $1"
  exit 0
fi
sha="$(commit_and_push "Production sync window: $1 ($(printf '%02d:00-%02d:00' "${start}" "${end}") UTC)")"
window_in_cluster() { kc -n argocd get appproject production -o 'jsonpath={.spec.syncWindows[0].schedule}' | grep -qx "0 ${start} \* \* \*"; }
wait_for "the production project to carry the window 0 ${start} * * *" 120 window_in_cluster
echo "${sha}"
