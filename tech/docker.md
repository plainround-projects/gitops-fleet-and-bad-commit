# Docker and the Dockerfile

## 1. What it is

Docker runs programs in **containers**: isolated processes that see their own file system, their own network and their own process list, but share the host's kernel. An **image** is the read-only bundle (files plus start command) a container starts from. A **Dockerfile** is the recipe that builds an image, one instruction per line.

## 2. Why this repository uses it

Two small images are built locally and imported into every cluster that needs them: the demo web app (1.0.0 and 1.1.0, so the waves have a change to ship) and the Git server. Four clusters means the images are imported four times.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `docker/web/Dockerfile, default.conf.template` | the demo application (unprivileged nginx with a template) |
| `docker/git-server/Dockerfile, entrypoint.sh, nginx.conf` | the Git server image |
| `scripts/build-images.sh` | builds and imports; with arguments it imports into specific clusters only |
| `versions.env` | base images pinned by tag and digest |

## 4. How it works underneath

- `docker build` reads the Dockerfile top to bottom. Each instruction (`FROM`, `RUN`, `COPY`...) produces a **layer**, a set of file changes stored by its content hash. Docker re-uses a layer when the instruction and everything before it are unchanged, so put the slow, rarely-changing steps first.
- `FROM` picks the starting image. A **digest** (`image@sha256:...`) pins the exact bytes; a tag such as `1.31.7-alpine` can be re-pushed to point somewhere else.
- `ARG` is a build-time variable; `ENV` is a variable inside the running container.
- `ENTRYPOINT` is the program the container runs; `CMD` gives its default arguments. `USER` sets who runs it. `EXPOSE` only documents a port. `HEALTHCHECK` runs a command periodically and marks the container healthy or not.
- A container is a normal process on the host, started in new Linux **namespaces** (own view of files, network, processes) and limited by **cgroups** (CPU and memory caps).
- Images live in the local Docker store. A cluster node is itself a container, with its own store, so a locally built image must be **imported** into the node before a pod can use it (there is no registry here).

## 5. Walkthrough of this repository's use

Both Dockerfiles are the ones from the first project (read its Docker note for every instruction: `ARG BASE_IMAGE`, `FROM`, `ENV APP_VERSION`, `COPY` of the template, `HEALTHCHECK` with `wget`, and for the Git server `apk add`, `adduser`, `USER 10001`, `ENTRYPOINT ["/sbin/tini", "--", ...]`).

What is different is how many clusters need the images. `build-images.sh` takes cluster names as arguments: with none it loads into the hub, with `dev staging production` it loads into those workload clusters, and `02-generate-apps.sh add` calls it with `demo4`. Importing is skipped for images the node already has (`crictl inspecti`). Because the policy admits only images that start with `plainround/`, the image names `plainround/web:1.0.0`, `plainround/web:1.1.0` and `plainround/git-server:1.0.0` are not arbitrary: the "foreign image" test replaces the web image with `docker.io/library/nginx:1.27` and the policy refuses it.

## 6. Try it yourself

1. `docker image ls 'plainround/*'` : three images.
2. `docker exec k3d-fleet-dev-server-0 crictl images | grep plainround` : the web images inside the dev cluster node.
3. `docker run --rm -d -p 18080:8080 -e GREETING=hi plainround/web:1.1.0` then `curl localhost:18080/version` : `1.1.0`.
4. `docker network inspect fleet-net --format '{{range .Containers}}{{.Name}} {{end}}'` : the node containers sharing the network.
5. `docker history plainround/web:1.0.0` : the layers.

## 7. Mistakes people make

- **Running as root inside the container.** The images here switch to an unprivileged user and the pods drop all capabilities.
- **A tag that moves.** `latest` can change under you; this repository pins versions and, for base images, digests.
- **Copying secrets into a layer.** A deleted file still exists in an earlier layer. No secret is ever copied into an image here.
- **Forgetting that `RUN` lines each add a layer**, so `apk add` and the clean-up belong in one `RUN` joined with `&&`.
- **Assuming the node can see your local images.** It cannot until they are imported.

## 8. Check yourself

1. What is the difference between an image and a container?
   *Answer:* An image is the read-only package; a container is a running process started from it.
2. Why pin a base image by digest?
   *Answer:* A digest names exact bytes and cannot be re-pointed, unlike a tag.
3. What is the difference between `ENTRYPOINT` and `CMD`?
   *Answer:* `ENTRYPOINT` is the program; `CMD` is its default arguments, which a caller can replace.
4. Why put `COPY` of a changing file after `RUN apk add`?
   *Answer:* A changed file invalidates its layer and every layer after it; the slow install stays cached.
5. How does a locally built image reach a cluster node?
   *Answer:* It is imported into the node's own image store (`k3d image import` or `kind load docker-image`).

## 9. Further reading

- Dockerfile reference: <https://docs.docker.com/reference/dockerfile/>. Engine used while building this repository: Docker 24.0.6 (`docker version`).
