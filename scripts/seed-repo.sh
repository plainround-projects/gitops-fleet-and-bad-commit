#!/usr/bin/env bash
# Creates the working clone of gitops-fleet from manifests/ and pushes it to the hub's Git server. The first commit
# pins staging and production to itself (dev follows main), so a later commit reaches them only through the waves.
#   seed-repo.sh            create the clone if it is missing
#   seed-repo.sh --reset    throw it away and start again
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require git curl

if [ "${1:-}" = "--reset" ]; then
  rm -rf "${WORK_CLONE}"
fi
if [ -d "${WORK_CLONE}/.git" ]; then
  log "working clone already exists at ${WORK_CLONE#"${ROOT}"/}"
  # A new fleet has an empty Git server even when an old clone is left over: put the clone's history on it.
  work_git push --quiet --force origin main
  exit 0
fi

mkdir -p "${WORK_CLONE}"
cp -R "${ROOT}/manifests/." "${WORK_CLONE}/"
git -C "${WORK_CLONE}" init --quiet --initial-branch=main
git -C "${WORK_CLONE}" config user.name "Runbook"
git -C "${WORK_CLONE}" config user.email "runbook@example.invalid"
git -C "${WORK_CLONE}" config commit.gpgsign false
cat > "${WORK_CLONE}/.git/hooks/pre-push" <<HOOK
#!/usr/bin/env bash
exec "${ROOT}/scripts/validate.sh" "${WORK_CLONE}"
HOOK
chmod +x "${WORK_CLONE}/.git/hooks/pre-push"

work_git add --all
work_git commit --quiet -m "Initial fleet: web 1.0.0 in dev, staging and production, with admission policy"
first="$(work_head)"
set_stage_value staging revision "${first}"
set_stage_value production revision "${first}"
work_git add --all
work_git commit --quiet -m "Pin staging and production to the first commit"
work_git remote add origin "${GIT_HOST_URL}"
work_git push --quiet --force origin main
log "seeded gitops-fleet at $(work_head | cut -c1-7); staging and production pinned to ${first:0:7}"
