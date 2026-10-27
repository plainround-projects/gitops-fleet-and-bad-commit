#!/usr/bin/env bash
# The one object applied by hand: the root Application, which syncs hub/ (both ApplicationSets and the projects).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl

kc apply -f "${ROOT}/platform/root-application.yaml"
