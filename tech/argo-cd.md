# Argo CD

## 1. What it is

Argo CD is a Kubernetes controller that keeps clusters equal to a Git repository. A **hub** Argo CD can manage many **workload clusters**: it holds a credential for each, watches Git once, and applies to each cluster the manifests that cluster should have.

## 2. Why this repository uses it

The lesson is about running this at fleet scale: one controller, three clusters, health-gated waves, sync windows and safe defaults. Argo CD v3.5.6 is pinned.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `platform/argocd/` | install (remote file at v3.5.6, trimmed) and the 20 s poll |
| `platform/root-application.yaml` | the one object applied by hand: syncs `hub/` |
| `manifests/hub/projects.yaml` | four AppProjects (dev, staging, production with a sync window, fleet-policy) |
| `manifests/hub/appset-web.yaml, appset-policy.yaml` | the two ApplicationSets |
| `scripts/register-cluster.sh` | registers a workload cluster by creating a cluster Secret |
| `scripts/install-argocd.sh` | install, version-pin check |
| `scripts/lib.sh` | Application readers (`app_sync`, `app_health`, `app_revision`, `operation_failed`) |

## 4. How it works underneath

- The hub runs Argo CD's repo-server (renders Kustomize), application-controller (compares and syncs; a StatefulSet), server, redis and applicationset-controller.
- A workload cluster is **registered** by a Secret in the `argocd` namespace labelled `argocd.argoproj.io/secret-type: cluster`; it holds the API address and a bearer token. Extra labels on that Secret (`app=web`, `stage=dev`) are what generators select on.
- An **Application** has a source (repo, revision, path), a destination (cluster, namespace) and a sync policy. An **AppProject** limits which repositories, clusters, namespaces and object kinds its Applications may use, and carries **sync windows**.
- **Sync options** can be set per object by annotation: `argocd.argoproj.io/sync-options: Prune=false` tells the controller never to delete that object even when automated prune is on; it is reported as needing pruning instead.
- A **sync window** is a cron schedule plus duration (`allow` or `deny`). Outside an allow window a change waits as OutOfSync.
- If the hub's controller is down, nothing is reconciled, but the workloads keep running; when it returns it corrects the drift that happened meanwhile.

## 5. Walkthrough of this repository's use

### Install and bootstrap
`platform/argocd` is the same trimmed install as in the first project (remote `install.yaml` at `v3.5.6`, Dex and notifications deleted, `timeout.reconciliation: 20s`). `install-argocd.sh` checks that the tag matches `ARGOCD_VERSION`, applies with `--server-side --force-conflicts` and waits for the components.

```yaml
# platform/root-application.yaml
kind: Application
metadata: { name: fleet-hub, namespace: argocd }
spec:
  project: default
  source: { repoURL: http://git-server.git-server.svc.cluster.local/gitops-fleet.git, targetRevision: main, path: hub }
  destination: { server: https://kubernetes.default.svc, namespace: argocd }
  syncPolicy: { automated: { prune: true, selfHeal: true } }
```
The **root Application** (the "app of apps") is the only object applied by hand. It syncs `hub/` from Git into the `argocd` namespace of the hub: the two ApplicationSets and the four projects. Everything else about the fleet is declared in the repository.

### Projects (`hub/projects.yaml`)
Each stage has a project that allows one source repository, any destination server (`"*"`) but only the namespace `web`, and one cluster-scoped kind (`Namespace`). The `fleet-policy` project may create the two admission-policy kinds in any namespace. The production project adds:
```yaml
syncWindows:
  - kind: allow
    schedule: "0 22 * * *"
    duration: 1h
    timeZone: UTC
    applications: ["*"]
```
`schedule` is a **cron expression**: minute 0, hour 22, every day. Production may sync from 22:00 for one hour (UTC). Outside the window a change is held as OutOfSync. `scripts/check_clusters.py` keeps this equal to the `syncWindow` text in `clusters/production.yaml`.

### Registration
`register-cluster.sh` creates `argocd-manager` in the target cluster (see the Kubernetes note), then in the hub:
```yaml
kind: Secret
metadata: { name: cluster-dev, namespace: argocd, labels: { argocd.argoproj.io/secret-type: cluster, app: web, stage: dev } }
stringData:
  name: dev
  server: https://k3d-fleet-dev-serverlb:6443
  config: '{"bearerToken": "...", "tlsClientConfig": {"insecure": false, "caData": "..."}}'
```
`name` is the cluster's name inside Argo CD (it becomes `{{ .name }}` in templates), `server` its address, `config` the credential. Deleting the Secret deregisters the cluster; the generated Application disappears.

### The sync-protection options
* In the destructive-commit step the Namespace has `Prune=false`, production has `prune: false`, and dev has prune on. A commit that deletes `namespace.yaml` therefore deletes **nothing** anywhere; each Application becomes `OutOfSync` and lists `Namespace/web` under `requiresPruning`. `git revert` clears it.
* `applied_at` in `lib.sh` reads `status.operationState.syncResult.revision` and `phase` to judge whether a stage applied a commit.

### Reading state
`app_field web-dev '{.status.health.status}'` and friends read the hub's Applications by name `web-<stage>`.

<!-- full-walkthrough:begin -->
### 5.A Full walkthrough: every Argo CD file

**Words you need first.** A **custom resource** is a kind of Kubernetes object added by a program; Argo CD adds `Application`, `AppProject` and `ApplicationSet`. A **namespace** is a named folder of objects; a **ConfigMap** holds named settings.

#### `platform/argocd/namespace.yaml`

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
```

- Creates the namespace `argocd`, where all of Argo CD's parts run. It has no label because Argo CD's own pods are not restricted.

#### `platform/argocd/controller-settings.yaml`

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
data:
  # Poll Git every 20 seconds with no random delay (the default is three minutes plus up to a minute).
  timeout.reconciliation: 20s
  timeout.reconciliation.jitter: 0s
```

- A ConfigMap named `argocd-cm`: Argo CD reads its settings from the object with exactly this name. It has no namespace here because the Kustomize file below sets the namespace of everything to `argocd`.
- `timeout.reconciliation: 20s`: how often Argo CD asks Git whether anything changed. The default is three minutes, too slow to watch in a lesson. `timeout.reconciliation.jitter: 0s` removes the random extra delay Argo CD normally adds to spread load (the default is up to a minute).
- Kustomize merges this into the real `argocd-cm` that comes with Argo CD's install file. See the Kustomize note.

#### `platform/argocd/kustomization.yaml`

```yaml
---
# Argo CD at the version in versions.env (the tag below must match ARGOCD_VERSION), trimmed for a laptop:
# no Dex (no single sign-on), no notifications, and a short poll interval so the runbook does not wait
# three minutes for every change.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: argocd
resources:
  - namespace.yaml
  - https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.6/manifests/install.yaml
patches:
  - path: controller-settings.yaml
  - target: { kind: Deployment, name: argocd-dex-server }
    patch: |-
      $patch: delete
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: argocd-dex-server
  - target: { kind: Deployment, name: argocd-notifications-controller }
    patch: |-
      $patch: delete
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: argocd-notifications-controller
```

- (See the Kustomize note for the keys.) What matters here: the install file is downloaded from the exact release `v3.5.6` of Argo CD; the namespace of every object is set to `argocd`; the file `controller-settings.yaml` is merged in as a patch; and two parts the lesson does not need, Dex (single sign-on) and the notifications controller, are deleted with `$patch: delete`.


#### `platform/root-application.yaml`: the one object applied by hand

```yaml
---
# The one object applied by hand on the hub: it syncs hub/ (the ApplicationSets and the projects) from Git, so
# everything else about the fleet is declared in the repository.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: fleet-hub
  namespace: argocd
spec:
  project: default
  source:
    repoURL: http://git-server.git-server.svc.cluster.local/gitops-fleet.git
    targetRevision: main
    path: hub
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- An **Application** says "keep this part of Git deployed to this place". This one is the "root" (also called an *app of apps*): it syncs the folder `hub/` of the fleet repository into the `argocd` namespace of the hub, which contains the two ApplicationSets and the four projects. So everything else about the fleet is declared in Git, and this is the only object created by hand.
- `project: default` uses Argo CD's built-in project. `source` is the Git server, branch `main`, path `hub`. `destination.server: https://kubernetes.default.svc` is the cluster Argo CD itself runs in. `syncPolicy.automated` with `prune: true` and `selfHeal: true`: apply changes automatically, delete what leaves Git and undo changes made by hand.

#### `manifests/hub/projects.yaml`: four projects (fences)

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: dev
  namespace: argocd
spec:
  description: The dev cluster (and any cluster registered with stage=dev)
  sourceRepos: ["http://git-server.git-server.svc.cluster.local/gitops-fleet.git"]
  destinations:
    - { server: "*", namespace: web }
  clusterResourceWhitelist:
    - { group: "", kind: Namespace }
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: staging
  namespace: argocd
spec:
  description: The staging cluster
  sourceRepos: ["http://git-server.git-server.svc.cluster.local/gitops-fleet.git"]
  destinations:
    - { server: "*", namespace: web }
  clusterResourceWhitelist:
    - { group: "", kind: Namespace }
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: production
  namespace: argocd
spec:
  description: The production cluster; syncs only inside the window
  sourceRepos: ["http://git-server.git-server.svc.cluster.local/gitops-fleet.git"]
  destinations:
    - { server: "*", namespace: web }
  clusterResourceWhitelist:
    - { group: "", kind: Namespace }
  syncWindows:
    # Production may sync from 22:00 for one hour, UTC. Outside it, a change waits as OutOfSync.
    - kind: allow
      schedule: "0 22 * * *"
      duration: 1h
      timeZone: UTC
      applications: ["*"]
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: fleet-policy
  namespace: argocd
spec:
  description: The admission policy, identical in every cluster
  sourceRepos: ["http://git-server.git-server.svc.cluster.local/gitops-fleet.git"]
  destinations:
    - { server: "*", namespace: "*" }
  clusterResourceWhitelist:
    - { group: admissionregistration.k8s.io, kind: ValidatingAdmissionPolicy }
    - { group: admissionregistration.k8s.io, kind: ValidatingAdmissionPolicyBinding }
```

- An **AppProject** limits what the Applications in it may do. There is one per stage plus one for the policy; the three stage projects are the same, and `production` adds a **sync window**.
- `description` is text. `sourceRepos` is the list of Git addresses allowed (only the fleet repository). `destinations`: `{ server: "*", namespace: web }` allows deploying to any registered cluster but only into the namespace `web`. `clusterResourceWhitelist`: the only cluster-wide kind allowed is `Namespace` (`group: ""` is the core API group).
- `syncWindows` (production only): `kind: allow` makes this an allow window; `schedule: "0 22 * * *"` is a **cron expression** — five fields: minute `0`, hour `22`, any day of month, any month, any weekday — so it opens at 22:00 every day; `duration: 1h`; `timeZone: UTC`; `applications: ["*"]` applies to every Application of the project. Outside the window a change waits as `OutOfSync`.
- `fleet-policy` allows the policy objects (`ValidatingAdmissionPolicy` and its binding, in the group `admissionregistration.k8s.io`) in any namespace of any cluster.

#### `platform/argocd/*`: see above

The install files (`namespace.yaml`, `controller-settings.yaml`, `kustomization.yaml`) are explained at the top of this section and in the Kustomize note. `controller-settings.yaml` sets the poll to 20 seconds, which the best-case calculation reads.

#### The cluster registration Secret (created by `register-cluster.sh`)

A workload cluster is registered by a Secret in the hub's `argocd` namespace. The labels `argocd.argoproj.io/secret-type: cluster` (makes it a registered cluster), `app: web` and `stage: <stage>` (what the ApplicationSet selects on), and the keys `name`, `server` and `config` (a JSON text with the access token and the cluster's certificate) are written by the script's here-document (see the Bash note). Deleting the Secret deregisters the cluster and the generated Application disappears.
<!-- full-walkthrough:end -->

## 6. Try it yourself

1. `kubectl --context k3d-fleet-hub -n argocd get applications` : seven Applications after `make up`.
2. `kubectl --context k3d-fleet-hub -n argocd get appproject production -o yaml | grep -A6 syncWindows` : the window.
3. `scripts/runbook/window.sh closed` then `03-waves.sh good` : production waits (`OutOfSync`).
4. `scripts/runbook/05-destructive-commit.sh commit` : `requires pruning: Namespace/web ` and the namespace still `Active`.
5. `kubectl --context k3d-fleet-hub -n argocd get secret cluster-dev -o jsonpath='{.metadata.labels}'` : `app` and `stage` labels.

## 7. Mistakes people make

- Giving every cluster the same revision, so there are no waves.
- A sync window in local time: windows here use `timeZone: UTC`.
- Trusting `prune: true` everywhere: a deleted manifest deletes live objects. Production does not prune; the Namespace has `Prune=false`.
- Forgetting that a stopped controller still leaves workloads running, then reading 'no change' as 'healthy'.

## 8. Check yourself

1. How is a workload cluster registered?
   *Answer:* A Secret in the hub's `argocd` namespace, labelled as a cluster, holding its address and a token.
2. What does a sync window do?
   *Answer:* Allows (or denies) syncs on a schedule; outside the window a change waits OutOfSync.
3. What does `Prune=false` on an object do?
   *Answer:* The controller never deletes it automatically; it is reported as needing pruning.
4. What is the root Application for?
   *Answer:* It syncs the `hub/` folder, so the ApplicationSets and projects are also in Git.
5. What happens to workloads when the hub's controller is down?
   *Answer:* They keep running; drift is corrected when the controller returns.

## 9. Further reading

- Argo CD v3.5 docs: <https://argo-cd.readthedocs.io/en/stable/> (Projects, sync windows, 'Sync Options', declarative cluster setup under 'Declarative Setup'). Not re-checked against the v3.5 site in this session.
