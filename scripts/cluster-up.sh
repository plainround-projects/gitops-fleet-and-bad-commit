#!/usr/bin/env bash
# Creates a kind cluster of the fleet if it does not exist yet. Safe to run again.
#   cluster-up.sh hub                       the hub: Argo CD and the Git server (Git published on the host)
#   cluster-up.sh dev|staging|production|demo4   a workload cluster (the app's NodePort published on a host port)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kind kubectl docker

target="${1:?usage: cluster-up.sh hub|dev|staging|production|demo4}"
if [ "${target}" = "hub" ]; then
  name="${HUB}"
  mapping="${GIT_HOST_PORT}:${GIT_HOST_PORT}"
else
  name="$(cluster_of "${target}")"
  mapping="$(host_port_of "${target}"):30080"
fi

# Under CPU contention a control plane can miss kubeadm's fixed deadlines, so the node gets a larger share of the CPU
# than the default as soon as its container exists. Harmless on an idle machine.
prioritize_node() {
  local container="$1" waited=0
  until docker update --cpu-shares 8192 "${container}" >/dev/null 2>&1; do
    waited=$((waited + 1))
    [ "${waited}" -lt 120 ] || return 0
    sleep 1
  done
}

# A cluster whose creation was interrupted exists as a container but has no working context; start it over.
if kind get clusters 2>/dev/null | grep -qx "${name}" && ! kubectl --context "kind-${name}" get nodes >/dev/null 2>&1; then
  log "cluster ${name} is half-made; deleting it"
  kind delete cluster --name "${name}"
fi
if kind get clusters 2>/dev/null | grep -qx "${name}"; then
  log "cluster ${name} already exists"
else
  config="$(mktemp)"
  cat > "${config}" <<CONFIG
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
# A busy laptop can take longer than kubeadm's default four minutes to start the API server.
kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      timeoutForControlPlane: 10m0s
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: ${mapping#*:}
        hostPort: ${mapping%:*}
        listenAddress: 127.0.0.1
        protocol: TCP
CONFIG
  log "creating cluster ${name} (${KIND_NODE_IMAGE%%@*})"
  # Remove the leftover of an interrupted attempt first (kind would stop on the name conflict).
  create_cluster() {
    docker rm --force "${name}-control-plane" >/dev/null 2>&1 || true
    prioritize_node "${name}-control-plane" &
    kind create cluster --name "${name}" --image "${KIND_NODE_IMAGE}" --config "${config}" --wait 600s
  }
  # Starting a control plane on a busy machine sometimes fails; kind removes the half-made cluster, so try again.
  with_kind_lock retry 6 10 create_cluster || die "cluster ${name} did not start after six attempts"
  rm -f "${config}"
fi
kubectl --context "kind-${name}" wait --for=condition=Ready node --all --timeout=180s
