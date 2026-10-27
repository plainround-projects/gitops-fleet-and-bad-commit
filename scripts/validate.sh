#!/usr/bin/env bash
# Checks the desired-state tree. Exit status 0 means every check passed.
#   validate.sh [tree]       default: manifests/ of this project
# 1. apps/web/base renders with kustomize and passes kubeconform strictly.
# 2. hub/ and policy/ pass the Kubernetes and community CRD schemas.
# 3. clusters/*.yaml have the shape the ApplicationSet reads (scripts/check_clusters.py).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl kubeconform python3

tree="${1:-${ROOT}/manifests}"
cache="${XDG_CACHE_HOME:-${HOME}/.cache}/plainround-kubeconform"
mkdir -p "${cache}"
common=(-strict -summary -kubernetes-version "${KUBECONFORM_KUBERNETES_VERSION}" -cache "${cache}")
crds='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
python="${ROOT}/.venv/bin/python"
[ -x "${python}" ] || python="python3"

status=0
log "clusters/*.yaml"
"${python}" "${ROOT}/scripts/check_clusters.py" "${tree}" || status=1
log "kustomize build apps/web/base"
kubectl kustomize "${tree}/apps/web/base" | kubeconform "${common[@]}" - || status=1
log "hub/ and policy/"
kubeconform "${common[@]}" -schema-location default -schema-location "${crds}" "${tree}/hub" "${tree}/policy" || status=1
exit "${status}"
