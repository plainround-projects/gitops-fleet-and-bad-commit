#!/bin/sh
# Creates the bare repositories named in REPOS (space separated, without .git), then serves them.
set -eu

for repo in ${REPOS:?set REPOS to the repository names to create}; do
  path="/srv/git/${repo}.git"
  if [ ! -d "${path}" ]; then
    git init --quiet --bare --initial-branch=main "${path}"
    git -C "${path}" config http.receivepack true
  fi
done

rm -f /tmp/fcgiwrap.sock
fcgiwrap -s unix:/tmp/fcgiwrap.sock &
exec nginx -g 'daemon off;'
