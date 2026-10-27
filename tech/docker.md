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

<!-- full-walkthrough:begin -->
### 5.A Full walkthrough: both Dockerfiles

#### `docker/web/Dockerfile`: the demo application image

A **Dockerfile** is the recipe for a container image: one instruction per line, run top to bottom, each creating a **layer** Docker can reuse.

```dockerfile
# The demo application: answers GET / with the GREETING it was started with, GET /version with the image
# version and GET /healthz with ok. Built twice by scripts/build-images.sh (1.0.0 and 1.1.0) so there is
# an old and a new image to roll between.
ARG BASE_IMAGE=nginxinc/nginx-unprivileged:1.31.7-alpine
FROM ${BASE_IMAGE}

ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}

# The base image's entrypoint renders every *.template file in this folder with envsubst at start-up.
COPY default.conf.template /etc/nginx/templates/default.conf.template

EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
```

- The comment lines say what the image is: a tiny web application that answers `GET /` with the greeting it was started with, `GET /version` with the image version and `GET /healthz` with `ok`. It is built **twice** (1.0.0 and 1.1.0) so the lesson has an old and a new image to move between.
- `ARG BASE_IMAGE=nginxinc/nginx-unprivileged:1.31.7-alpine` declares a build-time setting with a default; the build script passes the same image pinned by checksum. `FROM ${BASE_IMAGE}` starts from it: the nginx web server in a variant that runs as an ordinary user (not root) and listens on port 8080, on the small Alpine Linux.
- `ARG APP_VERSION=dev` is the version passed at build time; `ENV APP_VERSION=${APP_VERSION}` turns it into an environment variable inside the container, so the page `/version` can show it.
- `COPY default.conf.template /etc/nginx/templates/default.conf.template` copies the web server's configuration **template**. The comment above explains: the base image's start-up script replaces `${NAME}` placeholders in every `*.template` file of that folder with environment variables (a program called `envsubst` does it) and writes the result as the real configuration.
- `EXPOSE 8080` documents the port. `HEALTHCHECK --interval=10s --timeout=3s CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1` makes Docker run that command every ten seconds: `wget` fetches the health page quietly (`-q`) and throws the body away (`-O /dev/null`), and the whole container is reported unhealthy if it fails (`|| exit 1`).


#### `docker/git-server/Dockerfile`

A **Dockerfile** is the recipe for a container image (see the Docker note): one instruction per line, run top to bottom, each creating a **layer** that Docker can reuse.

```dockerfile
# A minimal smart-HTTP Git server (nginx + git-http-backend) so the cluster has a repository to watch
# without a GitHub account. Local use only: no authentication, bound to the loopback interface by kind.
ARG BASE_IMAGE=alpine:3.24.3
FROM ${BASE_IMAGE}

RUN apk add --no-cache git git-daemon nginx fcgiwrap tini \
 && adduser -D -u 10001 git \
 && mkdir -p /srv/git && chown git:git /srv/git

COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

USER 10001
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
```

- `ARG BASE_IMAGE=alpine:3.24.3` declares a build-time setting with a default; the build script overrides it with the same version pinned by checksum. `FROM ${BASE_IMAGE}` starts from that image: Alpine Linux, a very small Linux.
- `RUN apk add --no-cache git git-daemon nginx fcgiwrap tini \ && adduser -D -u 10001 git \ && mkdir -p /srv/git && chown git:git /srv/git` runs three commands in one layer, joined by `&&` (each runs only if the one before succeeded); a backslash at the end of a line continues the command. `apk` is Alpine's package manager; `--no-cache` keeps its download index out of the image. The packages are Git itself, the Git server helper, the web server nginx, `fcgiwrap` (lets nginx run programs) and `tini` (a tiny first process). `adduser -D -u 10001 git` creates an ordinary user without a password and with a fixed number, so the Kubernetes manifest can run the container as that user. `mkdir -p /srv/git` creates the folder for the repositories and `chown git:git` gives it to that user.
- `COPY nginx.conf /etc/nginx/nginx.conf` and `COPY entrypoint.sh /usr/local/bin/entrypoint.sh` copy the two files from the build folder into the image.
- `USER 10001` makes everything after, and the running program, use that user, not the all-powerful root.
- `EXPOSE 8080` documents the port. `HEALTHCHECK --interval=10s --timeout=3s CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1` makes Docker run that command every ten seconds: `wget` fetches the page quietly and discards it, and exits with 1 if it fails.
- `ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]` is the program the container runs. `tini` is a tiny **init** process: it is the container's first process, passes stop signals on and cleans up finished child processes. The `--` ends tini's options; the script follows.

#### `docker/git-server/entrypoint.sh`

This file uses `#!/bin/sh`, the smaller standard shell, because the image has no Bash.

```bash
#!/bin/sh
# Creates the bare repositories named in REPOS (space separated, without .git), then serves them.
set -eu

for repo in ${REPOS:?set REPOS to the repository names to create}; do
  path="/srv/git/${repo}.git"
  if [ ! -d "${path}" ]; then
    git init --quiet --bare --initial-branch=main "${path}"
    git -C "${path}" config http.receivepack true
  fi
done

rm -f /tmp/fcgiwrap.sock
fcgiwrap -s unix:/tmp/fcgiwrap.sock &
exec nginx -g 'daemon off;'
```

- `set -eu`: stop at the first error and on use of an unset variable.
- `for repo in ${REPOS:?set REPOS to the repository names to create}; do`: `${REPOS:?message}` reads the variable `REPOS` and **stops with the message** if it is unset or empty. Written without quotes, a list such as `a b c` is split into words, so the loop runs once for each repository name.
- `path="/srv/git/${repo}.git"` builds the folder name. `if [ ! -d "${path}" ]; then` is true when the folder does not exist yet (`-d` tests for a directory, `!` negates).
- `git init --quiet --bare --initial-branch=main "${path}"` creates a **bare** repository (only the history, no checked-out files: what a server holds) whose first branch is `main`. `git -C "${path}" config http.receivepack true` allows pushes over HTTP.
- `rm -f /tmp/fcgiwrap.sock` removes an old socket file (a special file two programs on the same machine use to talk). `fcgiwrap -s unix:/tmp/fcgiwrap.sock &` starts the helper in the **background** (the `&`). `exec nginx -g 'daemon off;'` replaces the shell with nginx in the foreground; a container ends when its main process ends, and a main process receives the stop signal directly.

#### `docker/git-server/nginx.conf`

**Words you need first.** A **web server** is a program that listens on a port and answers requests. nginx reads a configuration of **blocks** (`name { … }`) and **directives** (`name value;`, each ending with a semicolon).

```nginx
worker_processes 1;
pid /tmp/nginx.pid;
error_log /dev/stderr info;

events { worker_connections 64; }

http {
  access_log /dev/stdout;
  client_body_temp_path /tmp/nginx-body;
  proxy_temp_path /tmp/nginx-proxy;
  fastcgi_temp_path /tmp/nginx-fastcgi;
  uwsgi_temp_path /tmp/nginx-uwsgi;
  scgi_temp_path /tmp/nginx-scgi;

  server {
    listen 8080;
    client_max_body_size 50m;

    location = /healthz {
      default_type text/plain;
      return 200 "ok\n";
    }

    location ~ ^/.+\.git/(HEAD|info/refs|objects/info/.*|git-(upload|receive)-pack)$ {
      include /etc/nginx/fastcgi_params;
      fastcgi_pass unix:/tmp/fcgiwrap.sock;
      fastcgi_param SCRIPT_FILENAME /usr/libexec/git-core/git-http-backend;
      fastcgi_param GIT_PROJECT_ROOT /srv/git;
      fastcgi_param GIT_HTTP_EXPORT_ALL "";
      fastcgi_param PATH_INFO $uri;
      fastcgi_param REMOTE_USER local;
    }
  }
}
```

- `worker_processes 1;` one worker is enough. `pid /tmp/nginx.pid;` and `error_log /dev/stderr info;` use `/tmp` and the error stream because the container's own files are read-only and the program runs as an ordinary user. `events { worker_connections 64; }` allows 64 simultaneous connections.
- In `http { … }`: `access_log /dev/stdout;` writes one line per request to standard output (so `kubectl logs` shows it). The five `*_temp_path` lines move nginx's temporary folders to `/tmp`. In `server { … }`: `listen 8080;` the port; `client_max_body_size 50m;` allows pushes up to 50 megabytes; `location = /healthz { … }` answers exactly that path with status 200 and the text `ok` (`return 200 "ok\n";`) for the health checks.
- The long `location ~ ^/.+\.git/(HEAD|info/refs|objects/info/.*|git-(upload|receive)-pack)$ { … }`: the `~` makes the path a **regular expression** (a text pattern). It matches only the paths Git uses over HTTP on a repository whose name ends in `.git`. For those requests nginx does not know Git; it hands them over with the FastCGI protocol (`fastcgi_pass unix:/tmp/fcgiwrap.sock;`) to `fcgiwrap`, which runs the program named in `SCRIPT_FILENAME` (`git-http-backend`). `GIT_PROJECT_ROOT /srv/git` says where the repositories are, `GIT_HTTP_EXPORT_ALL ""` serves all of them, `PATH_INFO $uri` passes the request path and `REMOTE_USER local` names a user (Git refuses pushes without one).
<!-- full-walkthrough:end -->

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
