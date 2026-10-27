#!/usr/bin/env bash
# Installs Argo CD on the hub at the pinned version and waits for its components.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl

pinned="$(grep -oE 'argo-cd/v[0-9.]+/' "${ROOT}/platform/argocd/kustomization.yaml" | head -1 | tr -d '/' | sed 's/argo-cd//')"
[ "${pinned}" = "${ARGOCD_VERSION}" ] || die "platform/argocd pins ${pinned}, versions.env says ${ARGOCD_VERSION}"

log "installing Argo CD ${ARGOCD_VERSION} on the hub"
# Server-side apply: the ApplicationSet CRD is too large for the client-side last-applied annotation.
kc apply --server-side --force-conflicts -k "${ROOT}/platform/argocd" >/dev/null
kc -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
for deployment in argocd-repo-server argocd-applicationset-controller argocd-redis; do
  kc -n argocd rollout status "deployment/${deployment}" --timeout=300s
done
