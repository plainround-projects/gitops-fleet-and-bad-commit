# Kustomize

## 1. What it is

Kustomize builds Kubernetes YAML from other YAML without templates. A **base** holds the plain manifests; an **overlay** points at a base and changes a few things (an image tag, a name prefix, a patch). `kubectl kustomize <dir>` prints the result and `kubectl apply -k <dir>` applies it. It is built into `kubectl`.

## 2. Why this repository uses it

The application (`apps/web/base`) is a plain Kustomize base that every cluster's Application points at; Argo CD runs Kustomize on it. Kustomize also trims Argo CD's install file.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `manifests/apps/web/base/kustomization.yaml` | lists namespace, configmap, deployment, service |
| `platform/argocd/kustomization.yaml` | pulls the pinned install file, deletes Dex and notifications, merges the poll setting |
| `platform/git-server/kustomization.yaml` | lists the Git server file |
| `scripts/validate.sh` | builds the base with `kubectl kustomize` before checking it |
| `scripts/runbook/05-destructive-commit.sh` | removes a file from Git *and* its `resources` line |

## 4. How it works underneath

- A directory becomes a Kustomize unit when it holds a file named `kustomization.yaml`. Its `resources:` list names files or other directories to include.
- `images:` rewrites an image's name or tag everywhere it appears, so an overlay changes only one line to ship a new version.
- `patches:` apply a small YAML edit to a matching object, including `$patch: delete` to remove one.
- `namespace:` sets the namespace of every object it builds.
- The output is ordinary YAML. Nothing runs inside the cluster; the cluster (or Argo CD, which runs the same build) just receives the result.

## 5. Walkthrough of this repository's use

The base lists four files under `resources:`. Argo CD's Application sets `path: apps/web/base` and renders it with Kustomize. Because there is **no overlay** here (every cluster gets the same manifests; what differs per stage is the *commit* and the prune setting, not the content), the base is used directly.

The destructive-commit step shows why `resources:` matters:
```bash
work_git rm --quiet apps/web/base/namespace.yaml
perl -ni -e 'print unless /^  - namespace.yaml$/' "${WORK_CLONE}/apps/web/base/kustomization.yaml"
```
Removing the file alone would break the build (Kustomize reports a missing resource), so the line that lists it is removed too.

`platform/argocd/kustomization.yaml` is identical in structure to the first project's: remote `install.yaml` at v3.5.6, `namespace: argocd`, a strategic-merge patch `controller-settings.yaml` that sets `timeout.reconciliation: 20s` and jitter `0s`, and two `$patch: delete` targets (Dex, notifications). See that repository's Kustomize note for each key.

## 6. Try it yourself

1. `kubectl kustomize manifests/apps/web/base | grep -c '^kind:'` : 4.
2. `kubectl kustomize platform/argocd | grep -A2 'timeout.reconciliation'` : 20s.
3. Remove `- namespace.yaml` from a copy of the base and build : the Namespace is missing from the output.
4. Delete `namespace.yaml` but keep its line, then build : an error about the missing file.
5. `scripts/validate.sh` : builds and validates the base.

## 7. Mistakes people make

- Editing the built output instead of the source files.
- Forgetting to list a new file under `resources:`: it is silently ignored. (This repository's runbook deletes a ConfigMap by removing the file *and* its `resources` line.)
- Using a remote base without a pinned version, so the content moves.

## 8. Check yourself

1. What makes a directory a Kustomize unit?
   *Answer:* A `kustomization.yaml` file in it.
2. What does an overlay do?
   *Answer:* It includes a base and changes small parts of it.
3. How does `images:` help a release?
   *Answer:* One line changes the tag of every matching container image.
4. What command prints the built result?
   *Answer:* `kubectl kustomize <directory>`.
5. What happens to a file not listed in `resources:`?
   *Answer:* It is ignored.

## 9. Further reading

- Kustomize: <https://kubectl.docs.kubernetes.io/references/kustomize/> and <https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/>. The version is the one built into your `kubectl` (`kubectl version --client`).
