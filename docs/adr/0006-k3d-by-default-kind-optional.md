# 0006. k3d by default, kind optional

## Context

The lesson asks for a local cluster (kind or minikube). The scripts must work on a developer's laptop, including a laptop that is short of CPU or memory.

## Decision

`scripts/provider.sh` hides the provider behind five functions (create, exists, delete, load images, context name). The default is k3d (k3s in Docker); `CLUSTER_PROVIDER=kind` uses kind with a generated configuration. The CI workflow runs the cluster job with kind, where the runner is idle.

## Alternatives

- **kind only.** kind's kubeadm has fixed deadlines for the API server to answer while it bootstraps its admin role. On the machine this project was built on, with swap exhausted and a dozen other clusters starting, the control plane missed them in about fifteen attempts in a row; k3d's control plane started every time.
- **minikube.** Heavier, and no better at images or ports.

## Consequences

- Images are imported with `k3d image import` (or `kind load docker-image`); there is no registry to run.
- The kubectl context is `k3d-<cluster>` or `kind-<cluster>`; scripts and tests derive it from the provider.
- The kind path is exercised by the CI workflow and by the configuration generated in `provider.sh`, not by the local verification of this repository, which ran on k3d.

## Notes for the fleet

- The four clusters share one Docker network (`fleet-net`), created by `scripts/cluster-up.sh`, so the hub reaches the others by the name of their API endpoint (`k3d-fleet-dev-serverlb`, or `fleet-dev-control-plane` with kind).
