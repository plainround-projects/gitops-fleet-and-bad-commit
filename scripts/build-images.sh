#!/usr/bin/env bash
# Builds the images and loads them where they run:
#   plainround/web:1.0.0 and :1.1.0   into every workload cluster given on the command line
#   plainround/git-server:1.0.0       into the hub
#   build-images.sh dev staging production       (or: demo4)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require docker kind

build() {
  local context="$1" tag="$2"
  shift 2
  docker image inspect "${tag}" >/dev/null 2>&1 && return 0
  log "building ${tag}"
  docker build --quiet --tag "${tag}" "$@" "${ROOT}/${context}" >/dev/null
}

build docker/web plainround/web:1.0.0 --build-arg "BASE_IMAGE=${WEB_BASE_IMAGE}" --build-arg APP_VERSION=1.0.0
build docker/web plainround/web:1.1.0 --build-arg "BASE_IMAGE=${WEB_BASE_IMAGE}" --build-arg APP_VERSION=1.1.0
build docker/git-server plainround/git-server:1.0.0 --build-arg "BASE_IMAGE=${GIT_SERVER_BASE_IMAGE}"

for target in "$@"; do
  log "loading the web images into $(cluster_of "${target}")"
  kind load docker-image --name "$(cluster_of "${target}")" plainround/web:1.0.0 plainround/web:1.1.0
done
if [ "$#" -eq 0 ]; then
  log "loading the Git server image into ${HUB}"
  kind load docker-image --name "${HUB}" plainround/git-server:1.0.0
fi
