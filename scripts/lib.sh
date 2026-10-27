#!/usr/bin/env bash
# Shared helpers for every script in this repository. Source it; do not run it.
# shellcheck shell=bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

# versions.env pins the tools and images; .env (copied from .env.example) holds local choices.
# shellcheck source=../versions.env
source "${ROOT}/versions.env"
if [ -f "${ROOT}/.env" ]; then
  # shellcheck source=/dev/null
  source "${ROOT}/.env"
fi

WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"
OUTAGE_SECONDS="${OUTAGE_SECONDS:-1800}"
HUB="fleet-hub"
# shellcheck disable=SC2034 # used by the scripts that source this file
STAGES=(dev staging production)
GIT_HOST_PORT=30438
GIT_HOST_URL="http://127.0.0.1:${GIT_HOST_PORT}/gitops-fleet.git"
WORK_DIR="${ROOT}/.work"
WORK_CLONE="${WORK_DIR}/gitops-fleet"
HUB_CONTEXT="kind-${HUB}"
export WAIT_TIMEOUT OUTAGE_SECONDS HUB HUB_CONTEXT GIT_HOST_URL WORK_CLONE

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "error: $*"; exit 1; }

require() {
  local tool
  for tool in "$@"; do
    command -v "${tool}" >/dev/null 2>&1 || die "${tool} is not installed (see the prerequisites in README.md)"
  done
}

# retry <attempts> <delay-seconds> <command...>: run until it succeeds, with a fixed delay.
retry() {
  local attempts="$1" delay="$2" attempt=1
  shift 2
  until "$@"; do
    if [ "${attempt}" -ge "${attempts}" ]; then return 1; fi
    attempt=$((attempt + 1))
    sleep "${delay}"
  done
}

# wait_for <description> <timeout-seconds> <command...>: poll once a second until the command succeeds.
wait_for() {
  local description="$1" timeout="$2" waited=0
  shift 2
  until "$@" >/dev/null 2>&1; do
    if [ "${waited}" -ge "${timeout}" ]; then
      die "timed out after ${timeout}s waiting for ${description}"
    fi
    sleep 1
    waited=$((waited + 1))
  done
  log "${description}: ok (${waited}s)"
}

# The kind cluster that runs a stage: fleet-dev, fleet-staging, fleet-production (and fleet-demo4 briefly).
cluster_of() { echo "fleet-$1"; }
# The host port that reaches the app of a cluster (a kind port mapping onto the Service's NodePort).
host_port_of() {
  case "$1" in
    dev) echo 18101 ;;
    staging) echo 18102 ;;
    production) echo 18103 ;;
    demo4) echo 18104 ;;
    *) die "unknown cluster: $1" ;;
  esac
}

# kc: kubectl on the hub. wk <name>: kubectl on a workload cluster (dev, staging, production, demo4).
kc() { kubectl --context "${HUB_CONTEXT}" "$@"; }
wk() {
  local name="$1"
  shift
  kubectl --context "kind-$(cluster_of "${name}")" "$@"
}

# app_field <application> <jsonpath>: one field of an Application on the hub, empty when it is not there.
app_field() { kc -n argocd get application "$1" -o "jsonpath=$2" 2>/dev/null || true; }
app_sync() { app_field "web-$1" '{.status.sync.status}'; }
app_health() { app_field "web-$1" '{.status.health.status}'; }
app_revision() { app_field "web-$1" '{.status.sync.revision}'; }

# synced_healthy_at <stage> <revision>
synced_healthy_at() {
  [ "$(app_sync "$1")" = "Synced" ] && [ "$(app_health "$1")" = "Healthy" ] && [ "$(app_revision "$1")" = "$2" ]
}

# output_is <expected> <command...>: true when the command prints exactly <expected>; wait_for re-runs it at every poll.
output_is() {
  local expected="$1"
  shift
  [ "$("$@")" = "${expected}" ]
}

# synced_and_healthy <stage>
synced_and_healthy() { [ "$(app_sync "$1")" = Synced ] && [ "$(app_health "$1")" = Healthy ]; }

# Every git command of the runbook goes through here so it only ever touches the working clone.
work_git() { git -C "${WORK_CLONE}" "$@"; }
work_head() { work_git rev-parse HEAD; }

# commit_and_push <message>: commit everything in the working clone, push, print the new commit.
commit_and_push() {
  work_git add --all
  work_git commit --quiet -m "$1"
  work_git push --quiet origin main
  work_head
}

# stage_value <stage> <key>: a value from clusters/<stage>.yaml in the working clone.
stage_value() { grep -E "^$2:" "${WORK_CLONE}/clusters/$1.yaml" | head -1 | sed -E "s/^$2:[[:space:]]*//; s/[\"']//g"; }

# set_stage_value <stage> <key> <value>: change one scalar in clusters/<stage>.yaml (no commit).
set_stage_value() { perl -pi -e "s/^$2:.*/$2: $3/" "${WORK_CLONE}/clusters/$1.yaml"; }

# web_get <stage> <path>: GET the app through the host port (no controller and no API server in the path).
web_get() { curl -fsS --max-time 3 "http://127.0.0.1:$(host_port_of "$1")$2"; }

# applied_at <stage> <revision>: the last sync operation succeeded at that commit (or a descendant of it, for dev,
# which follows main) and the app is Healthy. "Synced" is not required: a protected object that a commit deleted
# from Git leaves the app OutOfSync on purpose, and the wave must still be able to judge its health.
applied_at() {
  local stage="$1" revision="$2" applied
  applied="$(app_field "web-${stage}" '{.status.operationState.syncResult.revision}')"
  [ -n "${applied}" ] || return 1
  [ "$(app_field "web-${stage}" '{.status.operationState.phase}')" = "Succeeded" ] || return 1
  [ "$(app_health "${stage}")" = "Healthy" ] || return 1
  [ "${applied}" = "${revision}" ] || work_git merge-base --is-ancestor "${revision}" "${applied}" 2>/dev/null
}

# operation_message <stage>: the message of the last sync operation (the admission policy's text, when it refuses).
operation_message() { app_field "web-$1" '{.status.operationState.message}'; }
operation_failed() { [[ "$(app_field "web-$1" '{.status.operationState.phase}')" =~ ^(Failed|Error)$ ]]; }

# with_kind_lock <command...>: run one command while holding the machine-wide lock that keeps two `kind create cluster`
# from starting at once (a busy laptop cannot start two control planes together). The lock is a directory holding the
# holder's PID; a lock whose holder is gone is removed.
with_kind_lock() {
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
