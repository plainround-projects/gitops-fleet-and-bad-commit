#!/usr/bin/env bash
# Lesson step 6: stop the controller (the hub's application-controller) for OUTAGE_SECONDS while a traffic loop hits the
# production app, drift production by hand mid-outage, then start the controller and watch the drift corrected.
#   06-controller-outage.sh [seconds]       default: OUTAGE_SECONDS (1800 = the lesson's thirty minutes)
# Prints one status code per second to logs/outage-traffic.log (200 each) and a summary.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

seconds="${1:-${OUTAGE_SECONDS}}"
log_file="${ROOT}/logs/outage-traffic.log"
mkdir -p "${ROOT}/logs"
: > "${log_file}"
production_replicas() { wk production -n web get deploy web -o 'jsonpath={.spec.replicas}'; }
controller_ready() { [ "$(kc -n argocd get statefulset argocd-application-controller -o 'jsonpath={.status.readyReplicas}')" = "1" ]; }
no_controller_pod() { [ -z "$(kc -n argocd get pods -l app.kubernetes.io/name=argocd-application-controller -o name)" ]; }

traffic() {
  while :; do
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 2 "http://127.0.0.1:$(host_port_of production)/healthz" >> "${log_file}" || echo 000 >> "${log_file}"
    sleep 1
  done
}

wait_for "production Synced before the outage" "${WAIT_TIMEOUT}" output_is Synced app_sync production
traffic &
traffic_pid=$!
trap 'kill "${traffic_pid}" 2>/dev/null || true' EXIT

kc -n argocd scale statefulset argocd-application-controller --replicas=0 >/dev/null
wait_for "the controller to stop" 120 no_controller_pod
log "controller down for ${seconds}s; traffic loop running"
sleep $((seconds / 2))
wk production -n web scale deploy web --replicas=4 >/dev/null
echo "mid-outage drift: replicas=$(production_replicas) (Git says 2)"
sleep $((seconds - seconds / 2))
echo "end of outage: replicas=$(production_replicas) (still 4: nothing reconciled)"

kc -n argocd scale statefulset argocd-application-controller --replicas=1 >/dev/null
wait_for "the controller to be back" 180 controller_ready
started=$SECONDS
reverted() { [ "$(production_replicas)" = "2" ]; }
wait_for "the drift to be corrected" 180 reverted
echo "drift corrected $((SECONDS - started))s after the controller returned: replicas=$(production_replicas)"

kill "${traffic_pid}" 2>/dev/null || true
trap - EXIT
total="$(wc -l < "${log_file}" | tr -d ' ')"
bad="$(grep -vc '^200$' "${log_file}" || true)"
echo "traffic: ${total} requests during and around the outage, ${bad} not 200"
