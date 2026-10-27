# gitops-fleet-and-bad-commit

Three local clusters (dev, staging, production) managed from one repository by Argo CD on a hub cluster. One `ApplicationSet` generates an app per cluster, changes roll out in waves behind a health gate and a production sync window, an admission policy applies in every cluster, and the fleet is tested against the failures that matter: a commit that deletes a production namespace, a policy violation, and a controller that goes down.

| | |
| --- | --- |
| **Lesson** | `/prep/gitops/project-fleet-and-bad-commit`, "A fleet in waves with a health gate" (`data-structure-explainer/src/content/tracks/gitops/15-project-fleet-and-bad-commit.md` in the Plainround app) |
| **Planned hours** | 14 |
| **Level** | Advanced |
| **Architecture** | [ARCHITECTURE.md](ARCHITECTURE.md), decisions in [docs/adr](docs/adr) |

## Prerequisites

| Tool | Version | Used for |
| --- | --- | --- |
| Docker | 24 or newer (tested with 24.0.6), **8 GB or more for its VM** | four cluster nodes at once (a fifth for a few minutes in step 2) |
| k3d | 5.9 or newer (tested with 5.9.0, k3s v1.35.5) | the local cluster, the default (`brew install k3d`); the k3s image is pinned in `versions.env` |
| kind | 0.33 or newer (tested with 0.33.0) | optional: `CLUSTER_PROVIDER=kind make up` uses kind (`kindest/node:v1.35.8`, pinned by digest in `versions.env`) |
| kubectl | 1.35 (includes Kustomize) | every script |
| kubeconform | 0.8 | the schema check in the pre-push hook and `make lint` (`brew install kubeconform`) |
| shellcheck, yamllint | any recent | `make lint` |
| git, curl, GNU Make | any recent | scripts |
| Python | 3.12 or 3.13 (tested with 3.13) | the tests and the cluster-file check; `make` installs `pytest`, `ruff`, `mypy` and `pyyaml` into `.venv/` from a hash-pinned lock file |
| Argo CD | v3.5.6, installed on the hub by `make up` from the pinned manifests | the controller and the ApplicationSet controller |
| Network | for the first `make up` | Argo CD's manifests, kubeconform's schemas, base images |

No cloud account, no secrets, no Git hosting account. Host ports 30438 (Git) and 18101 to 18104 (the app in each cluster) on `127.0.0.1` must be free.

## Setup, run, test, stop

```bash
make up              # hub + dev + staging + production, Argo CD, the Git server, the seeded repository, registration (about 15 minutes)
make best-case       # step 1: how long a change takes to reach production at best, from the repository's numbers
make run             # the whole lesson as one scripted run; the outage lasts OUTAGE_SECONDS (default 1800, thirty minutes)
make test            # offline tests with coverage, then the cluster tests (the outage test uses 90 seconds unless OUTAGE_SECONDS is set)
make lint            # yamllint, kubeconform, shellcheck, ruff, mypy
make status          # every Application and what each cluster runs
make down            # delete all clusters (including a leftover demo4) and the working clone
```

`make help` lists every target. The working clone of the fleet repository is `.work/gitops-fleet`; its `git log` is the order of everything that happened to the fleet.

## Step 1: the design

The design lives in the repository, not in a drawing: [ARCHITECTURE.md](ARCHITECTURE.md) has the diagram (hub, three clusters, the generators, the gates) and `make best-case` computes the time from the files:

```text
configured: poll 20s + dev observation 30s + requeue 20s + staging observation 45s + requeue 20s = 135s (2 min 15 s)
the lesson's windows: poll 60s + dev observation 300s + requeue 20s + staging observation 600s + requeue 20s = 1000s (16 min 40 s)
```

The lesson's solution says 16 minutes (one poll, five minutes, ten minutes) because its gate script calls `argocd app sync` directly. Here each wave is a commit that pins the next stage, so each later wave also waits for the ApplicationSet to re-read `clusters/` (20 seconds), which is the extra 40 seconds. What stops a change: a gate that closes (dev or staging not Healthy at the commit) halts the wave; production's sync window holds a healthy change until it opens. `tests/unit/test_best_case.py` checks the arithmetic against the files.

## Done when: the lesson's checklist and the proof for each line

| # | Done when (from the lesson) | Command | What proves it |
| --- | --- | --- | --- |
| 1 | The design states how long a change takes to reach production at best, and what stops it. | `make best-case` | The output above and the [architecture document](ARCHITECTURE.md#one-wave-step-by-step-scriptsrunbook03-wavessh-good); `tests/unit/test_best_case.py`. |
| 2 | Adding a label to a fourth cluster would deploy the app there with no new manifest, which you show by registering a fourth cluster briefly. | `scripts/runbook/02-generate-apps.sh add`, then `remove` | `tests/cluster/test_01_generator.py`: `web-dev`, `web-staging` and `web-production` are owned by the `ApplicationSet` and were never written by hand; registering `fleet-demo4` with `app=web,stage=dev` produces `web-demo4` and it becomes `Synced` and `Healthy`; deregistering removes the Application, and the cluster is deleted. |
| 3 | A change that fails health in dev never reaches staging, and a good change outside the window waits for it. | `scripts/runbook/03-waves.sh good`, `open`, `bad`, `revert` | `tests/cluster/test_02_waves.py`: a good change (web 1.1.0) goes through dev and staging gates and production is pinned but `OutOfSync` and still on 1.0.0 while the window is closed; opening the window (a commit) applies it; a change with a failing readiness probe makes dev `Degraded`, `promote.sh` stops, and staging's and production's pins are unchanged. |
| 4 | A commit with a privileged pod syncs to no cluster, and the controller reports the rejection with the policy's message. | `scripts/runbook/04-policy.sh privileged`, `foreign`, `revert` | `tests/cluster/test_03_policy.py`: the policy exists in all three clusters (installed by the second `ApplicationSet`); a privileged container and a foreign image are each pinned to all three stages, and each Application's last operation `Failed`/`Error` carries `ValidatingAdmissionPolicy ... privileged containers are not allowed` (or `images must come from plainround/`); no cluster ever ran the refused manifest; `kubectl run --privileged` is refused in each cluster with no controller involved. |
| 5 | The production namespace and its workloads still run after the commit syncs, the controller flags the difference, and a `git revert` clears it. | `scripts/runbook/05-destructive-commit.sh commit`, `revert` | `tests/cluster/test_04_destructive_commit.py`: after the manifest-deletion commit reaches production and dev, the namespace is `Active` with no deletion timestamp, two pods are ready, the Application is `OutOfSync` with `Namespace/web` listed as needing pruning; after `git revert` every stage is `Synced` and `Healthy`. |
| 6 | The app serves throughout with no errors, drift during the outage is corrected when the controller returns, and the README explains why a pull model degrades this way. | `scripts/runbook/06-controller-outage.sh` | `tests/cluster/test_05_controller_outage.py`: the hub's application-controller is scaled to zero; a loop requests `127.0.0.1:18103/healthz` every second (a host port, no controller and no API server in the path) and every response is 200; production is scaled to 4 mid-outage and is still 4 at the end (nothing reconciled: the controller really was down); after it returns production is back to 2 and `Synced`. Why, in one sentence: [below](#why-a-pull-model-degrades-this-way). |

### Why a pull model degrades this way

The controller is not in the request path of the workload: it reconciles toward Git, it does not carry traffic. Losing it pauses new rollouts and the correction of drift, and nothing else; the pods that are running go on serving. A push-based deploy tool that is down mid-deploy leaves the pipeline stuck and the cluster half-changed; a pull controller that is down leaves the cluster exactly as it was.

### How long the outage lasts

`OUTAGE_SECONDS` in `.env` is 1800 (the lesson's thirty minutes) for `make run`. The automated test uses 90 seconds so the suite finishes in a reasonable time; run `OUTAGE_SECONDS=1800 make test-cluster` for the full half hour.

## Stretch goals

| Stretch (from the lesson) | Built? |
| --- | --- |
| Add a progressive rollout within production with automated analysis between steps. | No. [ARCHITECTURE.md](ARCHITECTURE.md#how-to-extend-it) says how (an Argo Rollouts `Rollout` with an analysis template). |
| Sign commits and make the controller verify signatures before syncing. | No. |
| Give each cluster a different configuration value through generator parameters, without copying manifests. | Partly. `revision` and `prune` already come from each stage's file through the generator; a per-cluster configuration value would be one more key there. |

## What is simplified for teaching

Only what the lesson scopes out, plus where this build differs from the lesson's text:

- Four clusters (k3d, or kind) on one machine: the hub is a separate cluster so the controller can be stopped without touching a stage ([ADR 0001](docs/adr/0001-one-hub-and-three-workload-clusters.md)). "Stop the controller in the production cluster" becomes "stop the hub's controller", and the experiment proves it was stopped by drifting production and showing the drift survive.
- Admission policy is the Kubernetes API server's own `ValidatingAdmissionPolicy`, not Kyverno or Gatekeeper ([ADR 0003](docs/adr/0003-native-admission-policy.md)); the rejection text is the API server's, not Kyverno's.
- Waves are pinned revisions rather than a polling script that calls `argocd app sync` ([ADR 0002](docs/adr/0002-waves-by-pinned-revisions.md)); all three Applications keep self-heal.
- Observation windows are 30 and 45 seconds, not 5 and 10 minutes; the poll is 20 seconds.
- The production window is `22:00-23:00 UTC` by default and is moved by commits to the current hour or twelve hours away so the tests need not wait for 22:00; `window.sh default` restores it. Outside the window, production shows `OutOfSync`; Argo CD does not put a "sync blocked" message in the Application's status, so the test asserts the state and that the live image did not change.
- The Argo CD CLI is not used; `kubectl` reads the Application's status. Cluster registration is a Secret with a service-account token, as `argocd cluster add` creates, and the token is `cluster-admin`.
- The Git server has no authentication and listens on the loopback interface only.

## Project structure

```text
manifests/                   the content of the repository the hub watches ("gitops-fleet")
  clusters/dev|staging|production.yaml   per-stage settings the ApplicationSet reads: revision, prune, observation time, window
  apps/web/base/             the app: Namespace (Prune=false), ConfigMap, Deployment, Service
  hub/                       the two ApplicationSets and the four AppProjects (one has the sync window)
  policy/                    the admission policy and its binding
platform/                    what the hub needs besides the repository
  argocd/                    Argo CD v3.5.6 from pinned manifests, trimmed, 20-second poll
  git-server/                the in-cluster Git server
  cluster-access/            the service account the hub uses in each workload cluster
  root-application.yaml      the one object applied by hand
docker/                      web (the demo app) and git-server images
scripts/                     up, down, provider (k3d or kind), cluster-up, register-cluster, seed-repo, gate, promote, best-case, validate ...
scripts/runbook/             one script per lesson step; the tests call these
scripts/check_clusters.py    checks the shape of clusters/*.yaml and that the window matches the project
tests/support/               typed helpers: command runner, polling with an injected clock, a kubectl view of the Applications
tests/unit/                  file shape, generators, projects, policy, best-case arithmetic; no cluster
tests/cluster/               one module per lesson step, run against the fleet
docs/adr/                    decision records
versions.env                 every pinned version
```

Dependency rule: tests depend on the scripts and `tests/support`; scripts depend on `scripts/lib.sh`; `manifests/` depends on nothing. `platform/` is never read by the watched repository.

## Troubleshooting

- **Docker runs out of memory:** four clusters plus Argo CD need about 6 GB. `docker stats` shows who is using it; close other clusters.
- **`make up` is slow or a cluster does not start:** the machine is short of CPU or memory (several clusters starting at once is enough). `scripts/cluster-up.sh` takes a machine-wide lock so only one cluster is created at a time and retries up to six times. k3d starts a control plane in seconds; kind's kubeadm has hard deadlines that a starved machine can miss, which is why k3d is the default.
- **An Application is `Unknown` with a comparison error about the cluster:** `kubectl --context k3d-fleet-hub -n argocd get secret cluster-dev -o yaml` shows the server URL (`https://k3d-fleet-dev-server-0:6443`); the hub reaches the clusters over the shared Docker network `fleet-net`.
- **Production never applies a pinned commit:** the window is closed. `scripts/runbook/window.sh open` opens the current hour.
- **A test left the fleet in a strange state:** `scripts/runbook/window.sh closed`, then `git revert` the last runbook commit in `.work/gitops-fleet`, or `make down && make up`.

## Author and license

Written by Sumit Srivastava. Released under the MIT License, see [LICENSE](LICENSE). Changes are in [CHANGELOG.md](CHANGELOG.md).
