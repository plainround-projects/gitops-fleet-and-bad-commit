#!/usr/bin/env bash
# Registers a workload cluster with the hub's Argo CD, the way `argocd cluster add` does: a service account and token
# in the target, a cluster Secret in the hub carrying the labels app=web and stage=<stage>.
#   register-cluster.sh <cluster> <stage>      e.g. dev dev, or demo4 dev
#   register-cluster.sh --remove <cluster>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl kind

if [ "${1:-}" = "--remove" ]; then
  kc -n argocd delete secret "cluster-${2:?usage: register-cluster.sh --remove <cluster>}" --ignore-not-found
  exit 0
fi

cluster="${1:?usage: register-cluster.sh <cluster> <stage>}"
stage="${2:?usage: register-cluster.sh <cluster> <stage>}"
context="kind-$(cluster_of "${cluster}")"

kubectl --context "${context}" apply -f "${ROOT}/platform/cluster-access/argocd-manager.yaml" >/dev/null
read_token() { kubectl --context "${context}" -n kube-system get secret argocd-manager-token -o 'jsonpath={.data.token}' | base64 -d; }
wait_for "the service account token to be issued" 60 test -n "$(read_token)"
token="$(read_token)"
ca="$(kubectl --context "${context}" -n kube-system get secret argocd-manager-token -o 'jsonpath={.data.ca\.crt}')"
# The hub reaches the other clusters over the shared Docker network, by the node container's name.
server="https://$(cluster_of "${cluster}")-control-plane:6443"

kc apply -f - >/dev/null <<SECRET
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${cluster}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    app: web
    stage: ${stage}
type: Opaque
stringData:
  name: ${cluster}
  server: ${server}
  config: |
    {"bearerToken": "${token}", "tlsClientConfig": {"insecure": false, "caData": "${ca}"}}
SECRET
log "registered ${cluster} (stage=${stage}, ${server})"
