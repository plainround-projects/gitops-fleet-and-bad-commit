# Changelog

All notable changes to this project are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-10-27

### Added

- A fleet of four kind clusters (`make up`): a hub running Argo CD v3.5.6 and a Git server, and three workload clusters (dev, staging, production) registered with stage labels.
- One `ApplicationSet` that builds an `Application` per labelled cluster from the cluster's labels and from `clusters/<stage>.yaml`, and a second one that installs the same admission policy in every cluster.
- Waves with a health gate (`scripts/gate.sh`, `scripts/promote.sh`): dev follows main, staging and production are pinned by commits of their own, and a closed gate stops the wave.
- A production sync window in the production `AppProject`, moved by commits (`window.sh`).
- A `ValidatingAdmissionPolicy` that refuses privileged containers and images from outside `plainround/`, evaluated by the API server in every cluster.
- Protection against a destructive commit: no pruning in production, `Prune=false` on the Namespace.
- A controller-outage experiment with a traffic loop through a host port, and a fourth-cluster experiment that shows an Application appear and disappear with no new manifest.
- Offline and cluster tests, and a CI workflow.
