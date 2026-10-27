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

<!-- full-walkthrough:begin -->
### 5.A Full walkthrough: every Kubernetes file

**Words you need first.** A **container** is a program started in an isolated space with its own files and network. A **pod** is the smallest thing Kubernetes runs: one or more containers started together. A **node** is a machine that runs pods; here it is a Docker container too. A **namespace** is a named folder inside a cluster; objects in different namespaces do not collide. An **object** is a record you give Kubernetes that says what you want (for example "two copies of this container"). Kubernetes has **controllers** that compare what exists with what you asked for and fix the difference. This idea is called **reconciliation**. Every object is written in **YAML**: lines of `key: value`, where indentation shows what is inside what, and a line starting with `- ` is one item of a list (see the YAML note). Every object starts with `apiVersion` (which version of the API describes it), `kind` (what sort of object), `metadata` (its name and labels) and `spec` (what you want). A **label** is a name/value tag on an object; other objects find it by labels.


#### `manifests/apps/web/base/namespace.yaml`

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: web
  labels:
    app.kubernetes.io/part-of: gitops-fleet
    pod-security.kubernetes.io/enforce: restricted
  annotations:
    # A commit that deletes this file must not delete the live namespace and everything in it: the controller
    # flags the namespace as extra instead (OutOfSync) and a person decides.
    argocd.argoproj.io/sync-options: Prune=false
```

- A **Namespace** called `web` with the label that makes Kubernetes enforce the `restricted` Pod Security level (no root user, no extra privileges, a safe system-call filter) on every pod in it.
- The annotation `argocd.argoproj.io/sync-options: Prune=false` is a note that Argo CD reads. The comment explains why: a commit that deletes this file must not delete the live namespace and everything in it. Argo CD flags the namespace as "extra" (the application becomes `OutOfSync`) and a person decides.

#### `manifests/apps/web/base/configmap.yaml`

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-config
  namespace: web
  labels:
    app.kubernetes.io/name: web
    app.kubernetes.io/part-of: gitops-fleet
data:
  GREETING: hello
```

- A **ConfigMap** holds named settings as text. `namespace: web` puts it in the `web` namespace. `labels` mark what it belongs to. `data:` holds the settings; here a single one, `GREETING: hello`. Changing this value is the lesson's first change.

#### `manifests/apps/web/base/deployment.yaml`

A **Deployment** keeps a number of identical pods running and replaces them in an orderly way when you change them. It does this through an inner object called a **ReplicaSet** (one per version of the pod description).

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: web
  labels:
    app.kubernetes.io/name: web
    app.kubernetes.io/part-of: gitops-fleet
spec:
  replicas: 2
```

- The usual four starting keys. `name: web` and `namespace: web` identify the object. The two labels name the application and the group (`part-of`) it belongs to.
- `spec.replicas: 2`: keep two pods.

```yaml
  # A rollout that cannot become ready is reported as failed after a minute, so the controller shows
  # "Degraded" instead of "Progressing" for the ten-minute Kubernetes default.
  progressDeadlineSeconds: 60
  selector:
    matchLabels:
      app: web
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
```

- `progressDeadlineSeconds: 60`: if a rollout makes no progress for one minute, Kubernetes marks it as failed. Without this the wait is ten minutes, and Argo CD would show "Progressing" for that long instead of "Degraded".
- `selector.matchLabels.app: web`: this Deployment owns pods carrying the label `app: web`.
- `strategy.type: RollingUpdate` replaces pods gradually. `maxUnavailable: 0` means "never have fewer ready pods than wanted"; `maxSurge: 1` means "you may start one extra pod during the change". Together: start a new pod, wait until it is ready, then stop an old one. This is why, in the bad-commit step, the old pods keep serving.

```yaml
  template:
    metadata:
      labels:
        app: web
        app.kubernetes.io/name: web
      annotations:
        # Environment variables are read when a container starts, so a ConfigMap change only reaches
        # the pods when the pod template changes too. Bump this value in the same commit as the change.
        plainround.dev/config-revision: "1"
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        # The image runs as nginx (uid 101); fsGroup makes the emptyDir volumes below writable by it.
        fsGroup: 101
        seccompProfile:
          type: RuntimeDefault
```

- `template` describes the pods to create. Its `metadata.labels` must include `app: web` (the selector above). The annotation `plainround.dev/config-revision: "1"` is a plain note; it is quoted because annotation values must be text. **Why it exists:** an environment variable is read only when a container starts, so changing the ConfigMap does not reach running pods. Changing this note changes the pod description, and that makes Kubernetes start new pods. The runbook changes it in the same commit as the greeting.
- `spec.automountServiceAccountToken: false`: do not put a Kubernetes access token inside the pod; this program never talks to the cluster.
- `securityContext` (pod level): `runAsNonRoot: true` refuses a container that would run as the all-powerful root user; `fsGroup: 101` makes mounted folders writable by group 101, which is the group the nginx program runs as; `seccompProfile.type: RuntimeDefault` applies the container runtime's default filter of dangerous system calls.

```yaml
      containers:
        - name: web
          image: plainround/web:1.0.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          envFrom:
            - configMapRef:
                name: web-config
```

- `containers` is a list; each item starts with `- `. The container is called `web` and runs the image `plainround/web:1.0.0` (an image is the packed program; see the Docker note). `imagePullPolicy: IfNotPresent` means "do not download if the node already has it". The images are copied into the node by `make up`, so nothing is downloaded.
- `ports`: the container listens on port 8080 and the port is **named** `http`, so other settings can say `http` instead of a number.
- `envFrom`: every key of the ConfigMap `web-config` becomes an environment variable of the container. So `GREETING` reaches the program.

```yaml
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 3
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
```

- A **probe** is a check Kubernetes runs on a container. The **readiness probe** decides whether a pod may receive traffic: Kubernetes asks `GET /healthz` on port `http` every 3 seconds and treats 3 failures in a row as "not ready". The **liveness probe** decides whether a container must be restarted; it asks every 10 seconds. The bad-commit step changes only the readiness path.

```yaml
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
```

- `resources.requests` is what the scheduler reserves for the pod: 25 millicores of CPU (`25m` is 25 thousandths of one CPU core) and 32 mebibytes of memory (`32Mi`). `limits` are the hard ceilings: 100m CPU and 64Mi memory. A container over its memory limit is killed.

```yaml
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

- Container-level safety: `allowPrivilegeEscalation: false` (a process cannot gain more rights than it started with); `readOnlyRootFilesystem: true` (the container's own files cannot be changed); `capabilities.drop: ["ALL"]` (remove every special Linux power; `["ALL"]` is a one-line list).

```yaml
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: conf
              mountPath: /etc/nginx/conf.d
      volumes:
        - name: tmp
          emptyDir: {}
        - name: conf
          emptyDir: {}
```

- Because the root file system is read-only, the program needs a few writable places. `volumes` declares two **`emptyDir`** volumes: empty folders that exist as long as the pod does (`{}` is an empty setting block). `volumeMounts` attach them inside the container: one at `/tmp`, one at `/etc/nginx/conf.d`, where the start-up script of the nginx image writes the configuration it generates from the template.


#### `manifests/apps/web/base/service.yaml`

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: web
  labels:
    app.kubernetes.io/name: web
    app.kubernetes.io/part-of: gitops-fleet
spec:
  # A NodePort so the traffic test can reach the app from the host without going through any controller or the
  # Kubernetes API server (kind publishes it on a host port).
  type: NodePort
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: http
      nodePort: 30080
```

- A **Service** gives pods one stable name. `type: NodePort` also opens a fixed port on the node (`nodePort: 30080`); the comment explains that this lets the traffic test reach the application from the host **without** going through any controller or the Kubernetes API server (each cluster publishes that node port on a port of your computer). `selector.app: web` picks the pods by label; the Service listens on port 80 and forwards to the container port named `http`.

#### `platform/cluster-access/argocd-manager.yaml`: what lets the hub deploy to a workload cluster

```yaml
---
# What `argocd cluster add` creates in a target cluster: a service account the hub's controller authenticates as,
# and a long-lived token for it. Applied by scripts/register-cluster.sh to each workload cluster.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
```

- This is what `argocd cluster add` creates in a target cluster. A **ServiceAccount** is an identity for a program: `argocd-manager` in the `kube-system` namespace. A **ClusterRoleBinding** gives an identity a **role** across the whole cluster: the built-in `cluster-admin` role (all rights) is bound (`roleRef`) to the account named in `subjects`. (This is broad on purpose for a teaching fleet; production would narrow it.) A **Secret** of type `kubernetes.io/service-account-token` with the annotation `kubernetes.io/service-account.name: argocd-manager` makes Kubernetes fill in a long-lived access token for that account and the cluster's certificate; `register-cluster.sh` reads them and gives them to the hub.

#### `platform/git-server/git-server.yaml`: the Git server

It contains five objects separated by lines of three dashes (`---`).

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: git-server
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
```

- A namespace for the Git server, also restricted.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: git-server
  namespace: git-server
  labels:
    app.kubernetes.io/name: git-server
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: git-server
  template:
    metadata:
      labels:
        app: git-server
        app.kubernetes.io/name: git-server
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
```

- A Deployment with **one** replica. `strategy.type: Recreate` stops the old pod before starting the new one (the repositories live in an `emptyDir`, so two pods at once would not share them). `runAsUser: 10001` runs the container as that user id; the image has a user with the same id. The other keys are explained under the web Deployment.

```yaml
      containers:
        - name: git-server
          image: plainround/git-server:1.0.0
          imagePullPolicy: IfNotPresent
          env:
            - name: REPOS
              value: gitops-fleet
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 3
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
```

- The container `git-server` runs `plainround/git-server:1.0.0`. `env` sets one environment variable directly (`name`/`value` pair): `REPOS`, the list of repositories the start-up script creates (the demo repository's name). Same ports and probes pattern as the web app: `/healthz` on `http`.

```yaml
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              cpu: 250m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: repos
              mountPath: /srv/git
            - name: tmp
              mountPath: /tmp
      volumes:
        # Repositories live as long as the pod; `make up` seeds them again after a restart.
        - name: repos
          emptyDir: {}
        - name: tmp
          emptyDir: {}
```

- Resources (a bit more CPU and memory than the web app because Git does work); container security as before; two `emptyDir` volumes mounted at `/srv/git` (the repositories) and `/tmp` (temporary files of the web server). The comment explains that the repositories last as long as the pod; `make up` creates them again after a restart.

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: git-server
  namespace: git-server
  labels:
    app.kubernetes.io/name: git-server
spec:
  selector:
    app: git-server
  ports:
    - name: http
      port: 80
      targetPort: http
```

- `git-server`: a Service inside the cluster. Argo CD and Flux use it to clone: `http://git-server.git-server.svc.cluster.local/<repository>.git`.

```yaml
---
# Reaches the server from the host (the runbook pushes through this port).
apiVersion: v1
kind: Service
metadata:
  name: git-server-host
  namespace: git-server
  labels:
    app.kubernetes.io/name: git-server
spec:
  type: NodePort
  selector:
    app: git-server
  ports:
    - name: http
      port: 80
      targetPort: http
      nodePort: 30438
```

- `git-server-host`: a second Service of `type: NodePort`. A NodePort opens a fixed port (the fixed `nodePort`) on the node. The cluster is created with that port published on your computer's `127.0.0.1`, so the runbook, running on your computer, can push to the server.
<!-- full-walkthrough:end -->

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
