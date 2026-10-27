# Argo CD ApplicationSet

## 1. What it is

An **ApplicationSet** is an Argo CD object that creates many Applications from a **template** and **generators**. A generator produces a list of parameter sets; the template is rendered once for each. Add a cluster or a file and an Application appears; remove it and the Application is deleted.

## 2. Why this repository uses it

Registering a fourth cluster must add an Application with no new manifest. A matrix of two generators, "every cluster labelled `app=web`" times "the file for its stage", gives each cluster its own revision and prune setting from data files.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `manifests/hub/appset-web.yaml` | the `web-fleet` ApplicationSet (matrix of clusters x git files, with `templatePatch`) |
| `manifests/hub/appset-policy.yaml` | the `policy-fleet` ApplicationSet (clusters only) |
| `manifests/clusters/*.yaml` | the data the git generator reads |
| `scripts/check_clusters.py, tests/unit` | check the data files |

## 4. How it works underneath

- A **cluster generator** lists the registered clusters (the Secrets), optionally filtered by label, and offers `name`, `server` and the Secret's labels as parameters (`.metadata.labels.stage`).
- A **git file generator** reads files from a repository path and offers each file's keys as parameters. `requeueAfterSeconds` sets how often it re-reads Git (default three minutes).
- A **matrix generator** combines two generators: for every parameter set of the first and every one of the second, one result. Here the second generator's `path` is built from the first's parameters (`clusters/{{ .metadata.labels.stage }}.yaml`).
- `goTemplate: true` uses Go templates; `missingkey=error` makes a missing key an error instead of an empty string.
- A **templatePatch** is a text template merged over `template` after rendering, which lets a boolean such as `prune: {{ .prune }}` come out as a real YAML boolean.
- The set owns its Applications: they are created, updated and deleted to match.

## 5. Walkthrough of this repository's use

```yaml
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - matrix:
        generators:
          - clusters:
              selector:
                matchLabels:
                  app: web
          - git:
              repoURL: http://git-server.git-server.svc.cluster.local/gitops-fleet.git
              revision: main
              requeueAfterSeconds: 20
              files:
                - path: "clusters/{{ .metadata.labels.stage }}.yaml"
```
First generator: all clusters whose Secret has the label `app: web`. Second: read `clusters/<stage>.yaml` from `main`, re-reading every 20 seconds so a changed pin is noticed quickly. The matrix gives, for the dev cluster: `name`, `server`, `metadata.labels.stage=dev` plus the file's `stage`, `revision`, `prune`, `observeSeconds`.

```yaml
  template:
    metadata:
      name: "web-{{ .name }}"
      labels: { app: web, stage: "{{ .metadata.labels.stage }}" }
    spec:
      project: "{{ .metadata.labels.stage }}"
      source:
        repoURL: http://git-server.git-server.svc.cluster.local/gitops-fleet.git
        targetRevision: "{{ .revision }}"
        path: apps/web/base
      destination:
        server: "{{ .server }}"
        namespace: web
  templatePatch: |
    spec:
      syncPolicy:
        automated:
          selfHeal: true
          prune: {{ .prune }}
```
Each generated Application is named `web-<cluster>`, uses the project of its stage (so production gets the sync window), checks out `targetRevision` from the stage's file (`main` for dev, a commit hash for the others), and deploys `apps/web/base` to the cluster's API server. The patch turns on self-heal everywhere and sets `prune` from the file (false for production).

`appset-policy.yaml` uses only the cluster generator, so every cluster gets `policy/` from `main` with `prune` and `selfHeal` on, in project `fleet-policy`: **the policy cannot differ between clusters**.

The consequences the runbook shows: pinning staging is a one-line commit in `clusters/staging.yaml`; adding the fourth cluster with a `stage=dev` label creates `web-demo4` at once; deleting its Secret deletes the Application (and, with `resources-finalizer`, what it created is cleaned up per the Application's finalizers).

<!-- full-walkthrough:begin -->
### 5.A Full walkthrough: both ApplicationSets and the stage files

**Words you need first.** An **ApplicationSet** is an Argo CD object that creates many Applications from one **template** and **generators**. A generator produces parameter sets (a list of named values); the template is filled in once for each. **Go templates** use `{{ .name }}` to insert a value.

#### `manifests/clusters/dev.yaml`, `staging.yaml`, `production.yaml`: the data

These are plain YAML data files (no `kind`); the ApplicationSet's Git generator reads their keys as parameters.

```yaml
---
# Read by the ApplicationSet's Git generator for every cluster labelled stage=dev.
stage: dev
# dev follows the tip of main; the later stages are pinned to a commit the earlier stage has proven.
revision: main
prune: true
# How long dev must stay Healthy at a revision before the wave moves on (scripts/gate.sh).
observeSeconds: 30
```

```yaml
---
stage: staging
# scripts/seed-repo.sh pins this to the first commit; scripts/promote.sh moves it, one wave at a time.
revision: main
prune: true
observeSeconds: 45
```

```yaml
---
stage: production
revision: main
# Production never prunes: a deleted file is flagged, not deleted.
prune: false
observeSeconds: 0
# Documentation of the AppProject's sync window in hub/projects.yaml; a test keeps the two equal.
syncWindow: "22:00-23:00 UTC"
```

- `stage` names the stage. `revision` is what the stage follows: `main` for dev; staging's and production's `main` is replaced by a commit hash when the repository is seeded and moved by `promote.sh`. `prune` says whether Argo CD may delete objects that left Git (true for dev and staging, **false for production**: a deleted file is flagged, not deleted). `observeSeconds` is how long the stage must stay Healthy at a commit before the next wave starts (30, 45, 0). `syncWindow` (production only) documents the window in the AppProject; a test keeps the two equal.

#### `manifests/hub/appset-web.yaml`

```yaml
---
# One Application per registered cluster that carries the label app=web, built from the cluster's own labels and
# from clusters/<stage>.yaml. Registering a fourth cluster adds an Application with no new manifest.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: web-fleet
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - matrix:
        generators:
          - clusters:
              selector:
                matchLabels:
                  app: web
          - git:
              repoURL: http://git-server.git-server.svc.cluster.local/gitops-fleet.git
              revision: main
              # Re-read clusters/*.yaml every 20 seconds (the default is three minutes), so a pinned revision moves quickly.
              requeueAfterSeconds: 20
              files:
                - path: "clusters/{{ .metadata.labels.stage }}.yaml"
  template:
    metadata:
      name: "web-{{ .name }}"
      labels:
        app: web
        stage: "{{ .metadata.labels.stage }}"
    spec:
      project: "{{ .metadata.labels.stage }}"
      source:
        repoURL: http://git-server.git-server.svc.cluster.local/gitops-fleet.git
        targetRevision: "{{ .revision }}"
        path: apps/web/base
      destination:
        server: "{{ .server }}"
        namespace: web
  # selfHeal everywhere; prune per cluster from its file (production: false).
  templatePatch: |
    spec:
      syncPolicy:
        automated:
          selfHeal: true
          prune: {{ .prune }}
```

- `goTemplate: true` uses Go templates; `goTemplateOptions: ["missingkey=error"]` turns a missing key into an error instead of an empty text.
- `generators: - matrix: generators: […]` combines two generators: for every parameter set of the first and every one of the second, one result. The first is a **cluster generator** (`clusters: selector: matchLabels: app: web`): every registered cluster whose Secret has the label `app: web`; it provides `name`, `server` and the Secret's labels (`.metadata.labels.stage`). The second is a **Git generator**: it reads files from the repository (`repoURL`, `revision: main`), re-reading every 20 seconds (`requeueAfterSeconds: 20`; the default is three minutes), and its `files: - path: "clusters/{{ .metadata.labels.stage }}.yaml"` picks the file named for the cluster's stage; each file's keys become parameters.
- `template` is the Application to create. `metadata.name: "web-{{ .name }}"` and labels from the parameters. `spec.project: "{{ .metadata.labels.stage }}"` uses the stage's project (so production gets the sync window). `source`: the Git repository, `targetRevision: "{{ .revision }}"` (the stage's pin), `path: apps/web/base`. `destination.server: "{{ .server }}"` and `namespace: web`. The values are in quotes because `{` starts a map in YAML.
- `templatePatch: |` is a block of text (the `|` keeps line breaks) that is rendered and **merged over** the template: it sets `syncPolicy.automated.selfHeal: true` for every Application and `prune: {{ .prune }}` from the stage's file. It is a patch (and not part of `template`) because a template value inside a boolean field only becomes a real YAML boolean after rendering.

#### `manifests/hub/appset-policy.yaml`

```yaml
---
# The same pattern for the admission policy: every cluster gets the policy folder from main, so a cluster cannot
# drift from the fleet's policy without also drifting from everything else it runs.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: policy-fleet
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - clusters:
        selector:
          matchLabels:
            app: web
  template:
    metadata:
      name: "policy-{{ .name }}"
      labels:
        app: policy
    spec:
      project: fleet-policy
      source:
        repoURL: http://git-server.git-server.svc.cluster.local/gitops-fleet.git
        targetRevision: main
        path: policy
      destination:
        server: "{{ .server }}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

- The same pattern for the admission policy, with only the **cluster generator**: every cluster gets the `policy/` folder from `main` (`targetRevision: main`, `path: policy`), in the project `fleet-policy`, with prune and self-heal on. The Applications are called `policy-<cluster>`. Because every cluster's policy comes from one folder on `main`, **a cluster cannot have a different policy from the rest**.
<!-- full-walkthrough:end -->

## 6. Try it yourself

1. `kubectl --context k3d-fleet-hub -n argocd get applicationsets` : `web-fleet` and `policy-fleet`.
2. `kubectl --context k3d-fleet-hub -n argocd get application web-staging -o jsonpath='{.spec.source.targetRevision}'` : a commit hash (the pin).
3. `scripts/runbook/02-generate-apps.sh add` : `web-demo4` appears and serves `hello`.
4. `scripts/runbook/02-generate-apps.sh remove` : it disappears.
5. `kubectl --context k3d-fleet-hub -n argocd get applicationset web-fleet -o jsonpath='{.status.conditions[*].type}'` : the set's status conditions.

## 7. Mistakes people make

- A missing key rendered as an empty string, which produces a valid-looking but wrong Application. `missingkey=error` stops that.
- Writing `prune: {{ .prune }}` in `template` instead of `templatePatch`: a template value inside a YAML boolean field is rendered as text and can fail schema validation.
- A git generator with the default three-minute re-read: a pin would take minutes to be noticed.
- Forgetting that deleting a cluster Secret deletes that cluster's Application.

## 8. Check yourself

1. What does a matrix generator do?
   *Answer:* Combines two generators: one result for every pair of their parameter sets.
2. Why `templatePatch`?
   *Answer:* To render a boolean field (`prune`) as a real YAML boolean after templating.
3. What does `requeueAfterSeconds` control?
   *Answer:* How often the git generator re-reads the repository.
4. How is an Application added for a new cluster?
   *Answer:* Register the cluster with the right labels; the generator creates it.
5. Why must the policy ApplicationSet use only the cluster generator?
   *Answer:* Every cluster gets the same policy from `main`, with no per-stage pin.

## 9. Further reading

- ApplicationSet docs (v3.5): <https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/> (Matrix generator, Git generator, Cluster generator, Go templates, `templatePatch`). Not re-checked against the v3.5 site in this session; the features were taken from the working manifests and the Argo CD release.
