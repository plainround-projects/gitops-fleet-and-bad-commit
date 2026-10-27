#!/usr/bin/env bash
# Lesson step 2: one Application per registered cluster, with no per-cluster manifest. Registering a fourth cluster
# (demo4) adds a fourth Application; deregistering it removes the Application again.
#   02-generate-apps.sh list     the Applications that exist now
#   02-generate-apps.sh add      create and register demo4, wait for web-demo4 to appear and sync
#   02-generate-apps.sh remove   deregister demo4, wait for web-demo4 to disappear, delete the cluster
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

web_applications() { kc -n argocd get applications -l app=web -o 'custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,CLUSTER:.spec.destination.server'; }
application_exists() { kc -n argocd get application "web-demo4" >/dev/null 2>&1; }
application_gone() { ! application_exists; }

case "${1:-}" in
  list) web_applications ;;
  add)
    "${ROOT}/scripts/cluster-up.sh" demo4
    "${ROOT}/scripts/build-images.sh" demo4
    "${ROOT}/scripts/register-cluster.sh" demo4 dev
    wait_for "web-demo4 to be generated" 120 application_exists
    wait_for "web-demo4 to be Synced and Healthy" "${WAIT_TIMEOUT}" synced_and_healthy demo4
    web_applications
    echo "web-demo4 serves: $(web_get demo4 /)"
    ;;
  remove)
    "${ROOT}/scripts/register-cluster.sh" --remove demo4
    wait_for "web-demo4 to disappear" 120 application_gone
    kind delete cluster --name "$(cluster_of demo4)"
    web_applications
    ;;
  *) die "usage: 02-generate-apps.sh list|add|remove" ;;
esac
