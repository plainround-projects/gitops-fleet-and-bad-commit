# k3d and kind (local clusters)

## 1. What it is

k3d and kind each create a whole Kubernetes cluster inside Docker containers on your laptop, so you can test cluster software without a cloud account. **k3d** runs **k3s**, a small Kubernetes distribution; **kind** runs the standard `kubeadm` way. This repository uses k3d by default and can use kind with `CLUSTER_PROVIDER=kind`.

## 2. Why this repository uses it

A fleet needs several clusters. k3d starts a control plane in seconds with little memory, so a hub and three workload clusters (plus a short-lived fourth) are practical on a laptop.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `scripts/provider.sh` | identical to the first project's; adds `provider_api_host` (the name other clusters use to reach this cluster's API server) |
| `scripts/cluster-up.sh` | creates the hub or a workload cluster on the shared Docker network `fleet-net` |
| `scripts/register-cluster.sh` | uses `provider_api_host` to build the cluster's address |
| `scripts/runbook/02-generate-apps.sh` | creates and deletes a fourth cluster |
| `scripts/down.sh` | deletes every cluster and the network |
| `versions.env` | `K3S_IMAGE`, `KIND_NODE_IMAGE` |

## 4. How it works underneath

- The "node" is one Docker container (`k3d-<name>-server-0`) that runs the control plane and the workloads. A second container (`...-serverlb`) is a small load balancer that publishes ports to the host.
- `k3d cluster create <name>` pulls the node image, starts the container, waits for the API server and writes a kubeconfig context named `k3d-<name>`. kind's context is `kind-<name>`.
- A port written `-p "127.0.0.1:30418:30418@loadbalancer"` publishes the node port on your loopback address only, so nothing outside your machine can reach it.
- Images built with `docker build` live in your Docker, not in the node. `k3d image import` copies them in. Pods then use `imagePullPolicy: IfNotPresent` so they never try to pull them from the internet.
- `k3d cluster delete <name>` removes the containers, network and kubeconfig entry.
- k3s disables bundled extras on request (`--disable=traefik` and others) to save memory.

## 5. Walkthrough of this repository's use

`provider.sh` is the same as in the first project (see its note for k3d arguments, the kind config file, image import and the lock). What matters for a fleet:

```bash
provider_create "${name}" "${mapping}" --network "${FLEET_NETWORK}"
```
`--network fleet-net` puts every cluster on one Docker network so containers can reach each other by name. For k3d, `provider_api_host <cluster>` returns `k3d-<cluster>-serverlb`: the **load balancer** container in front of the API server, listening on port 6443 inside the network. `register-cluster.sh` builds `server="https://$(provider_api_host fleet-dev):6443"`. (For kind it returns `<cluster>-control-plane`.)

Each cluster publishes only the ports it needs on `127.0.0.1`: the hub publishes the Git server's NodePort; each workload cluster publishes its app's NodePort 30080 on `18101`, `18102`, `18103` (and `18104` for the fourth). The lock `/tmp/plainround-kind-create.lock` serializes cluster creation because four control planes starting together overload a laptop.

`02-generate-apps.sh remove` deletes the fourth cluster with `provider_delete`.

## 6. Try it yourself

1. `k3d cluster list` : `fleet-hub`, `fleet-dev`, `fleet-staging`, `fleet-production`.
2. `docker network inspect fleet-net --format '{{range .Containers}}{{.Name}} {{end}}'` : all the node and load-balancer containers.
3. `docker exec k3d-fleet-hub-server-0 sh -c 'wget -qO- --no-check-certificate https://k3d-fleet-dev-serverlb:6443/version'` : the workload API answers over the network (an authentication error is also proof it is reachable).
4. `kubectl config get-contexts` : four `k3d-fleet-*` contexts.
5. `scripts/runbook/02-generate-apps.sh add` : a fourth cluster appears and gets an Application.

## 7. Mistakes people make

- Creating several clusters at once on a small machine: the control planes miss their start-up deadlines. This repository takes a machine-wide lock first.
- Forgetting to delete the cluster afterwards; it keeps using memory.
- Expecting `docker build` images to be visible in the cluster without importing them.

## 8. Check yourself

1. What is the cluster's node here?
   *Answer:* A Docker container.
2. Why bind a published port to `127.0.0.1`?
   *Answer:* So only the local machine can reach it.
3. How does a locally built image reach a pod?
   *Answer:* It is imported into the node, and the pod uses `IfNotPresent`.
4. How do k3d and kind differ?
   *Answer:* k3d runs k3s (small, quick); kind runs standard kubeadm Kubernetes.
5. What removes a cluster completely?
   *Answer:* `k3d cluster delete <name>` (or `kind delete cluster --name <name>`).

## 9. Further reading

- k3d: <https://k3d.io/> (5.9.0 used). k3s: <https://docs.k3s.io/>. kind: <https://kind.sigs.k8s.io/>.
