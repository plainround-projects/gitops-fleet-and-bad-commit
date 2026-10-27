# kubectl

## 1. What it is

`kubectl` is the command-line program that sends requests to a Kubernetes API server: read objects, create them, change them, delete them, run a command inside a Pod. Almost every script in this repository calls it.

## 2. Why this repository uses it

Every script talks to four clusters through two small wrappers, `kc` (the hub) and `wk <stage>` (a workload cluster), so a command can never go to the wrong cluster.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `scripts/lib.sh (`kc`, `wk`, `app_field`)` | the wrappers |
| `scripts/register-cluster.sh` | reads the token and CA, applies the cluster Secret |
| `scripts/runbook/*.sh` | scale, exec, run, get, jsonpath, custom-columns |
| `tests/support/kube.py` | the same calls from Python |

## 4. How it works underneath

- `kubectl` reads a **kubeconfig** file (`~/.kube/config`) that lists clusters, users and **contexts** (a pairing of a cluster and a user). `--context <name>` picks one.
- `get`, `describe`, `apply`, `delete`, `patch`, `scale`, `exec`, `rollout status`, `wait` and `diff` are the verbs used here.
- `-n <namespace>` selects a namespace. `-o json` or `-o jsonpath='{...}'` prints parts of an object so a script can read one field.
- `apply` sends the file and lets the server merge it. **Server-side apply** (`--server-side`) lets the API server track which tool owns which field, and avoids the size limit of the client-side annotation.
- `kubectl diff -f -` shows what an apply would change; its exit code is 1 when there is a difference.

## 5. Walkthrough of this repository's use

```bash
kc() { kubectl --context "${HUB_CONTEXT}" "$@"; }
wk() { local name="$1"; shift; kubectl --context "$(provider_context "$(cluster_of "${name}")")" "$@"; }
app_field() { kc -n argocd get application "$1" -o "jsonpath=$2" 2>/dev/null || true; }
```
`kc` and `wk` pin the context. `app_field <application> <jsonpath>` reads a field of an Application on the hub.

Commands worth knowing:
* `kc -n argocd get applications -l app=web -o 'custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,CLUSTER:.spec.destination.server'` : a custom table; `-l app=web` selects by label.
* `kc -n argocd scale statefulset argocd-application-controller --replicas=0` : stop the controller (the outage); `--replicas=1` starts it.
* `wk production -n web scale deploy web --replicas=4` : drift production by hand during the outage.
* `wk dev -n web run attacker --image=plainround/web:1.0.0 --privileged --restart=Never` : try to create a privileged Pod; the API server answers with the policy's message, which the script extracts with `grep -o "denied the request: .*"`.
* `kubectl --context ... -n kube-system get secret argocd-manager-token -o 'jsonpath={.data.ca\.crt}'` : the backslash escapes the dot in the key `ca.crt`.
* `kc apply -f - <<SECRET ... SECRET` : apply YAML written inline.
* `[?(@.requiresPruning==true)]` in JSONPath selects resources the controller wants to prune but may not.

## 6. Try it yourself

1. `kubectl --context k3d-fleet-hub -n argocd get applications` : `web-dev`, `web-staging`, `web-production`, `policy-*`, `fleet-hub`.
2. `scripts/status.sh` : one screen of the fleet.
3. `kubectl --context k3d-fleet-hub -n argocd get secret -l argocd.argoproj.io/secret-type=cluster` : the three registered clusters.
4. `kubectl --context k3d-fleet-dev -n web run attacker --image=plainround/web:1.0.0 --privileged --restart=Never` : refused by the policy.
5. `kubectl --context k3d-fleet-hub -n argocd get statefulset` : the application controller.

## 7. Mistakes people make

- Running against the wrong cluster because the current context was something else. All scripts here pass `--context` explicitly.
- Reading output with `grep` instead of `-o jsonpath`, which breaks when the layout changes.
- Using `--force` or `delete` as a first step; a reconciling controller will undo them anyway.

## 8. Check yourself

1. What is a context?
   *Answer:* A kubeconfig entry that pairs a cluster with a user.
2. How do you print one field of an object?
   *Answer:* `kubectl get <kind> <name> -o jsonpath='{.path.to.field}'`.
3. What does `--server-side` change about `apply`?
   *Answer:* The API server merges and records field ownership, instead of the client.
4. Why does every script pass `--context`?
   *Answer:* So it can never act on whichever cluster happens to be current.
5. What does `kubectl diff` return when there is a difference?
   *Answer:* Exit code 1, with the differences printed.

## 9. Further reading

- kubectl reference: <https://kubernetes.io/docs/reference/kubectl/> (client 1.35).
