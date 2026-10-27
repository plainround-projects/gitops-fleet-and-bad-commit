#!/usr/bin/env bash
# Creates a cluster of the fleet if it does not exist yet (k3d by default, kind with CLUSTER_PROVIDER=kind). Safe to run again.
#   cluster-up.sh hub                       the hub: Argo CD and the Git server (Git published on the host)
#   cluster-up.sh dev|staging|production|demo4   a workload cluster (the app's NodePort published on a host port)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require "${CLUSTER_PROVIDER}" kubectl docker

target="${1:?usage: cluster-up.sh hub|dev|staging|production|demo4}"
if [ "${target}" = "hub" ]; then
  name="${HUB}"
  mapping="${GIT_HOST_PORT}:${GIT_HOST_PORT}"
else
  name="$(cluster_of "${target}")"
  mapping="$(host_port_of "${target}"):30080"
fi
context="$(provider_context "${name}")"

# A cluster whose creation was interrupted exists as a container but has no kubectl context; start it over. (A slow API
# server is not a reason to delete a cluster, so only the missing context counts.)
if provider_exists "${name}" && ! kubectl config get-contexts -o name | grep -qx "${context}"; then
  log "cluster ${name} is half-made; deleting it"
  provider_delete "${name}"
fi
if provider_exists "${name}"; then
  log "cluster ${name} already exists"
else
  log "creating cluster ${name} with ${CLUSTER_PROVIDER}"
  docker network inspect "${FLEET_NETWORK}" >/dev/null 2>&1 || docker network create "${FLEET_NETWORK}" >/dev/null
  create_cluster() {
    docker rm --force "$(provider_node "${name}")" >/dev/null 2>&1 || true
    # k3d joins the shared network; kind puts every cluster on its own shared network called "kind".
    provider_create "${name}" "${mapping}" --network "${FLEET_NETWORK}"
  }
  with_cluster_lock retry 6 10 create_cluster || die "cluster ${name} did not start after six attempts"
fi
kubectl --context "${context}" wait --for=condition=Ready node --all --timeout=180s
