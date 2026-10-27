# 0001. One hub cluster and three workload clusters

## Context

The lesson has three clusters (dev, staging, production), one repository and "a controller", and later stops "the controller in the production cluster" while the other clusters keep going. An `ApplicationSet` cluster generator needs one Argo CD that has the clusters registered.

## Decision

A fourth kind cluster, the hub, runs Argo CD and the Git server. The three stage clusters hold only the workload and the admission policy. They are registered with the hub as the lesson's `argocd cluster add` does: a service account and token in the target, a cluster Secret in the hub carrying the labels `app=web` and `stage=<stage>`.

## Alternatives

- **Argo CD inside the dev cluster.** Then "dev" is also the control plane, and stopping the controller affects the cluster that is supposed to be a stage.
- **Argo CD in every cluster.** One `ApplicationSet` per cluster is not "one generator that creates an app per cluster".

## Consequences

- Five kind clusters exist for a moment during the fourth-cluster experiment; the Docker memory budget is the hard limit (the README states it).
- Stopping the hub's application-controller pauses reconciliation for all three stages at once. The experiment therefore proves "paused" by drifting production during the outage and showing the drift survive it, instead of by comparing with a controller that kept running elsewhere.
- The controller reaches the other clusters over the shared Docker network by the node container's name, and its token is `cluster-admin` there (what `argocd cluster add` grants). A production setup would scope it.
