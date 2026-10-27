# Kubernetes

## 1. What it is

Kubernetes is a system that runs containers across one or more machines and keeps them running as you described. You do not tell it *what to do*; you give it **objects** that say *what should exist* (for example "two copies of this container"), and its **controllers** keep comparing that wish with reality and fix the difference. This idea is called **declarative** configuration and the comparing loop is called **reconciliation**.

## 2. Why this repository uses it

The lesson runs **four** Kubernetes clusters at once: a hub (which runs the controller) and three workload clusters. It shows Kubernetes' own protections working alongside the controller's: an admission policy that refuses bad manifests, a Namespace that the controller will not prune, and a Deployment that keeps old Pods while a new version never becomes ready.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `manifests/apps/web/base/*.yaml` | Namespace (with `Prune=false`), ConfigMap, Deployment, NodePort Service |
| `manifests/policy/no-privileged.yaml` | a ValidatingAdmissionPolicy and its binding |
| `platform/cluster-access/argocd-manager.yaml` | ServiceAccount, ClusterRoleBinding and a token Secret in each workload cluster |
| `platform/git-server/git-server.yaml` | the Git server on the hub |

## 4. How it works underneath

- The **API server** is the front door. Every `kubectl` command and every controller talks to it over HTTPS and stores objects in a database called **etcd**.
- The main objects used here: **Namespace** (a named folder of objects), **Pod** (one or more containers that run together), **Deployment** (keeps N identical Pods and replaces them in a rolling update), **ReplicaSet** (created by a Deployment, one per version of the Pod template), **Service** (a stable name and address in front of Pods chosen by labels), **ConfigMap** (named key-value settings).
- A **label** is a key-value tag on an object. A **selector** picks objects by label; a Service finds its Pods this way.
- **Probes** let Kubernetes ask a container whether it is alive (liveness) and ready for traffic (readiness). A Pod that is not ready receives no Service traffic.
- A **rolling update** starts new Pods and stops old ones in steps. With `maxUnavailable: 0` an old Pod stays until a new one is ready.
- **Custom resources** (CRDs) extend the API with new kinds, such as Argo CD's `Application`. The API server validates objects against their schema and refuses wrong types.
- A **node** is a machine that runs Pods. Here the cluster has one node, itself a container.

## 5. Walkthrough of this repository's use

### The application
The Deployment is the one from the first project (read its Kubernetes note): two replicas, `maxUnavailable: 0`, `progressDeadlineSeconds: 60`, restricted Pod Security, probes on `/healthz`, a read-only root file system. Two things are different here:

* The Service is a **NodePort** with a fixed `nodePort: 30080`, and each cluster publishes that node port on a host port (`18101`...). A test can then call the app from the host with `curl` **without** going through Argo CD or the Kubernetes API server, so the outage test measures the application itself.
* The Namespace carries an annotation `argocd.argoproj.io/sync-options: Prune=false` (explained in the Argo CD note): even if a commit deletes the namespace manifest, the controller will not delete the live namespace.

### Cluster access
```yaml
kind: ServiceAccount     # argocd-manager in kube-system
kind: ClusterRoleBinding # binds it to the built-in cluster-admin role
kind: Secret             # type kubernetes.io/service-account-token, annotated with the service account's name
```
This is what `argocd cluster add` creates. The hub's controller authenticates to a workload cluster as `argocd-manager`. A Secret of type `kubernetes.io/service-account-token` with the annotation `kubernetes.io/service-account.name` makes Kubernetes fill in a long-lived token and the cluster's CA certificate. `cluster-admin` is broad on purpose for a teaching fleet; production would narrow it.

### Many clusters, one network
Each cluster is its own Kubernetes API server on its own port. The hub reaches a workload API at `https://k3d-fleet-<stage>-serverlb:6443` over the shared Docker network.

### Admission
When a manifest reaches a cluster, the API server runs **admission**: authentication, authorization, then admission controllers, then validation, and only then stores it. A `ValidatingAdmissionPolicy` is a rule evaluated *inside* the API server (see the admission-policy note).

## 6. Try it yourself

1. `kubectl --context k3d-fleet-hub get ns` : `argocd`, `git-server` and the system namespaces.
2. `kubectl --context k3d-fleet-dev -n web get all` : the app on the dev cluster.
3. `curl -s http://127.0.0.1:18101/` : `hello`; ports `18102` and `18103` are staging and production.
4. `kubectl --context k3d-fleet-dev get clusterrolebinding argocd-manager` : the access the hub uses.
5. `kubectl --context k3d-fleet-dev get validatingadmissionpolicy` : the policy installed by the hub.

## 7. Mistakes people make

- Editing the live object by hand. A controller that reconciles from Git will revert it; that is the point of the lesson.
- Selectors that do not match the Pod labels, so a Service has no endpoints.
- Setting no resource requests and limits, so one Pod can starve the node. Every container here sets both.
- Expecting an environment variable from a ConfigMap to change in a running Pod. It is read once at container start, so the Pod template must change as well.

## 8. Check yourself

1. What does 'declarative' mean in Kubernetes?
   *Answer:* You describe the state you want and controllers work to make reality match it.
2. What does a Deployment create to keep Pods running?
   *Answer:* A ReplicaSet, which creates the Pods.
3. How does a Service know which Pods to send traffic to?
   *Answer:* Its selector matches the Pods' labels.
4. What is the difference between a liveness and a readiness probe?
   *Answer:* Liveness failing restarts the container; readiness failing only removes the Pod from the Service.
5. Why does a ConfigMap change not reach a running Pod's environment variables?
   *Answer:* Environment variables are fixed when the container starts.

## 9. Further reading

- Kubernetes documentation: <https://kubernetes.io/docs/concepts/>. Version used here: Kubernetes 1.35 (k3s v1.35.5 inside the cluster).
