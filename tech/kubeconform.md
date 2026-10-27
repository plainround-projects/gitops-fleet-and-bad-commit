# kubeconform

## 1. What it is

kubeconform checks Kubernetes YAML against the official JSON Schemas of each kind and version, without a cluster. It catches a wrong type, a misspelled field or a missing required field before the API server would.

## 2. Why this repository uses it

The ApplicationSets, projects and the admission policy are checked against schemas before they are pushed. The cluster-file checker covers the stage data files, which no Kubernetes schema describes.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `scripts/validate.sh` | stage-file check, then kustomize+kubeconform of the base, then the hub objects and the policy |
| `scripts/seed-repo.sh` | the pre-push hook |
| `scripts/ci-install-tools.sh` | v0.8.0 on the runner |
| `versions.env` | `KUBECONFORM_KUBERNETES_VERSION=1.35.0` |

## 4. How it works underneath

- Every Kubernetes kind has a published JSON Schema. kubeconform fetches the right one by `apiVersion` and `kind` and compares the object.
- `-strict` rejects fields the schema does not know and requires the full set. `-kubernetes-version 1.35.0` picks the schema release. `-summary` prints counts.
- Custom resources (Argo CD, Flux, sops-aware kinds) are not in the core schemas; `-schema-location` adds a community catalog, with a URL template that fills in group, kind and version.
- `-cache` stores downloaded schemas so later runs work faster.
- `-` as the file name reads from standard input, which is how `kubectl kustomize ... | kubeconform -` checks the built output.

## 5. Walkthrough of this repository's use

`validate.sh` runs three steps and keeps going after a failure so all are reported (`|| status=1`): (1) `check_clusters.py` on the tree (stage files, window equality); (2) `kubectl kustomize apps/web/base | kubeconform -strict -summary -kubernetes-version 1.35.0 -` (the application, built first); (3) `kubeconform` with `-schema-location default` plus the community CRD catalog over `hub/` (ApplicationSets and AppProjects have no core schema) and over `policy/` (the `admissionregistration.k8s.io/v1` kinds are in the core schemas). The URL template in `crds=` maps a group, kind and version to a JSON Schema file. See the first project's kubeconform note for each option.

## 6. Try it yourself

1. `scripts/validate.sh` : `Summary: ... Invalid: 0`.
2. Put `prune: "false"` in a copy of `clusters/production.yaml` and run `scripts/validate.sh <tree>` : the cluster-file check fails.
3. Misspell `matchLabels` in a copy of `hub/appset-web.yaml` : kubeconform refuses it.
4. `kubeconform -v` : `v0.8.0`.
5. `kubectl kustomize manifests/apps/web/base | kubeconform -strict -summary -kubernetes-version 1.35.0 -` : the base alone.

## 7. Mistakes people make

- Validating the source files instead of the built output; a Kustomize overlay is only complete after the build.
- Skipping unknown kinds silently. The scripts here name the schema locations so custom kinds are checked.

## 8. Check yourself

1. Does kubeconform need a cluster?
   *Answer:* No. It uses published schemas.
2. What does `-strict` do?
   *Answer:* Rejects unknown fields and requires the complete shape.
3. Why can core schemas not check an Argo CD Application?
   *Answer:* It is a custom resource; its schema comes from a separate catalog.
4. What does `-` mean as the input?
   *Answer:* Read the YAML from standard input.
5. Why pin `-kubernetes-version`?
   *Answer:* So the result does not change when a newer Kubernetes ships.

## 9. Further reading

- kubeconform: <https://github.com/yannh/kubeconform> (pinned v0.8.0 in CI). The CRD catalog it uses: <https://github.com/datreeio/CRDs-catalog>.
