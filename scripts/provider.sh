#!/usr/bin/env bash
# Local cluster providers: k3d (the default) and kind. Source it after versions.env; do not run it.
#   CLUSTER_PROVIDER=k3d   k3s in Docker; starts a control plane in seconds and needs little memory
#   CLUSTER_PROVIDER=kind  kubeadm in Docker; the conventional choice, but its control plane start has hard deadlines that a
#                          busy or memory-starved machine misses
# Both create a cluster with one control-plane node, publish the host ports given as <host>:<node-port> on 127.0.0.1, and
# need no registry: images are imported from the local Docker with provider_load_images.
# shellcheck shell=bash

CLUSTER_PROVIDER="${CLUSTER_PROVIDER:-k3d}"

provider_context() { # <cluster>
  case "${CLUSTER_PROVIDER}" in
    k3d) echo "k3d-$1" ;;
    kind) echo "kind-$1" ;;
    *) die "CLUSTER_PROVIDER must be k3d or kind, not ${CLUSTER_PROVIDER}" ;;
  esac
}

# The Docker container of the control-plane node.
provider_node() { # <cluster>
  case "${CLUSTER_PROVIDER}" in
    k3d) echo "k3d-$1-server-0" ;;
    kind) echo "$1-control-plane" ;;
    *) die "CLUSTER_PROVIDER must be k3d or kind, not ${CLUSTER_PROVIDER}" ;;
  esac
}

# The name other clusters on the shared Docker network use to reach this cluster's API server on port 6443.
provider_api_host() { # <cluster>
  case "${CLUSTER_PROVIDER}" in
    k3d) echo "k3d-$1-serverlb" ;;
    kind) echo "$1-control-plane" ;;
    *) die "CLUSTER_PROVIDER must be k3d or kind, not ${CLUSTER_PROVIDER}" ;;
  esac
}

provider_exists() { # <cluster>
  case "${CLUSTER_PROVIDER}" in
    k3d) k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx "$1" ;;
    kind) kind get clusters 2>/dev/null | grep -qx "$1" ;;
    *) die "CLUSTER_PROVIDER must be k3d or kind, not ${CLUSTER_PROVIDER}" ;;
  esac
}

provider_delete() { # <cluster>
  case "${CLUSTER_PROVIDER}" in
    k3d) k3d cluster delete "$1" ;;
    kind) kind delete cluster --name "$1" ;;
    *) die "CLUSTER_PROVIDER must be k3d or kind, not ${CLUSTER_PROVIDER}" ;;
  esac
}

# provider_create <cluster> [<host-port>:<node-port>...] [--network <docker-network>] [--registry-config <file>]
# k3d only: --network joins an existing Docker network (clusters that must reach each other share one).
provider_create() {
  local name="$1" mappings=() network="" registry_config=""
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --network) network="$2"; shift 2 ;;
      --registry-config) registry_config="$2"; shift 2 ;;
      *) mappings+=("$1"); shift ;;
    esac
  done
  case "${CLUSTER_PROVIDER}" in
    k3d)
      local args=(cluster create "${name}" --servers 1 --agents 0 --image "${K3S_IMAGE}" --wait --timeout 1800s
        --k3s-arg "--disable=traefik@server:0" --k3s-arg "--disable=servicelb@server:0"
        --k3s-arg "--disable=metrics-server@server:0")
      local mapping
      for mapping in "${mappings[@]}"; do
        args+=(-p "127.0.0.1:${mapping%:*}:${mapping#*:}@loadbalancer")
      done
      [ -z "${network}" ] || args+=(--network "${network}")
      [ -z "${registry_config}" ] || args+=(--registry-config "${registry_config}")
      k3d "${args[@]}"
      ;;
    kind)
      local config
      config="$(mktemp)"
      {
        cat <<'CONFIG'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
# A busy laptop can miss kubeadm's default deadlines while the API server starts.
kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    timeouts:
      controlPlaneComponentHealthCheck: 10m0s
      kubernetesAPICall: 5m0s
      etcdAPICall: 5m0s
  - |
    kind: ClusterConfiguration
    apiServer:
      timeoutForControlPlane: 10m0s
    etcd:
      local:
        # etcd's data directory on the node's tmpfs: disk latency makes fsync the bottleneck of a start.
        dataDir: /tmp/etcd
nodes:
  - role: control-plane
CONFIG
        if [ "${#mappings[@]}" -gt 0 ]; then
          echo "    extraPortMappings:"
          for mapping in "${mappings[@]}"; do
            printf '      - containerPort: %s\n        hostPort: %s\n        listenAddress: 127.0.0.1\n        protocol: TCP\n' "${mapping#*:}" "${mapping%:*}"
          done
        fi
      } > "${config}"
      kind create cluster --name "${name}" --image "${KIND_NODE_IMAGE}" --config "${config}" --wait 600s
      rm -f "${config}"
      ;;
    *) die "CLUSTER_PROVIDER must be k3d or kind, not ${CLUSTER_PROVIDER}" ;;
  esac
}

# Imports the images that are not on the node yet (importing is slow and the second `make up` need not repeat it).
provider_load_images() { # <cluster> <image>...
  local name="$1" missing=() image
  shift
  for image in "$@"; do
    docker exec "$(provider_node "${name}")" crictl inspecti "${image}" >/dev/null 2>&1 || missing+=("${image}")
  done
  [ "${#missing[@]}" -gt 0 ] || { log "the images are already on ${name}"; return 0; }
  set -- "${missing[@]}"
  case "${CLUSTER_PROVIDER}" in
    k3d) k3d image import --cluster "${name}" "$@" ;;
    kind) kind load docker-image --name "${name}" "$@" ;;
    *) die "CLUSTER_PROVIDER must be k3d or kind, not ${CLUSTER_PROVIDER}" ;;
  esac
}

# with_cluster_lock <command...>: run one command while holding the machine-wide lock that keeps two clusters from
# starting at once (a busy laptop cannot start two control planes together). The lock is a directory holding the
# holder's PID; a lock whose holder is gone is removed.
with_cluster_lock() {
  local lock=/tmp/plainround-kind-create.lock waited=0 holder status
  until mkdir "${lock}" 2>/dev/null; do
    holder="$(cat "${lock}/pid" 2>/dev/null || true)"
    if [ -n "${holder}" ] && ! kill -0 "${holder}" 2>/dev/null; then rm -rf "${lock}"; continue; fi
    [ "${waited}" -lt 7200 ] || die "gave up waiting for another cluster to finish starting"
    [ $((waited % 60)) -ne 0 ] || log "another cluster is starting; waiting for ${lock}"
    sleep 5
    waited=$((waited + 5))
  done
  echo "$$" > "${lock}/pid"
  status=0
  "$@" || status=$?
  rm -rf "${lock}"
  return "${status}"
}
