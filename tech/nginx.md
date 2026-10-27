# nginx

## 1. What it is

nginx is a fast web server. It listens on a port, matches the path of each request against `location` rules and answers. Here it is used twice: as the tiny demo application, and as the front of the Git server.

## 2. Why this repository uses it

Two places use nginx: the demo web application (the thing the waves deploy) and the front of the in-cluster Git server the hub's Argo CD watches.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `docker/web/default.conf.template` | the demo application: `/healthz`, `/version`, `/` |
| `docker/git-server/nginx.conf` | the Git server's front (smart HTTP over FastCGI) |
| `manifests/apps/web/base/deployment.yaml` | `emptyDir` at `/etc/nginx/conf.d` for the rendered config |
| `platform/git-server/git-server.yaml` | the Git server Deployment |

## 4. How it works underneath

- A `server { listen 8080; ... }` block defines a virtual server. `location = /path` matches exactly that path; `location ~ regex` matches a regular expression.
- `return 200 "text";` answers directly. `default_type text/plain` sets the content type.
- `${NAME}` in a **template** file is replaced at container start by `envsubst`, because the `nginx-unprivileged` image's start-up script renders `/etc/nginx/templates/*.template` to `/etc/nginx/conf.d/`.
- For Git, nginx does not know Git. It hands the request over **FastCGI** to `fcgiwrap`, which runs the program `git-http-backend`.

## 5. Walkthrough of this repository's use

### The demo app
```nginx
server {
  listen 8080;
  server_name _;
  location = /healthz { default_type text/plain; return 200 "ok\n"; }
  location = /version { default_type text/plain; return 200 "${APP_VERSION}\n"; }
  location = /        { default_type text/plain; return 200 "${GREETING}\n"; }
}
```
Port 8080 (an unprivileged user cannot bind port 80). `server_name _` is a catch-all. Three exact paths: `/healthz` for the probes, `/version` shows which image runs, `/` prints the greeting from the ConfigMap. Changing the ConfigMap changes the page only after a Pod restart, which is why the Deployment's config-revision annotation exists.

### The Git server's nginx.conf
```nginx
worker_processes 1;
pid /tmp/nginx.pid;
error_log /dev/stderr info;
events { worker_connections 64; }
```
One worker is enough. The pid file and logs go to `/tmp` and the standard streams, because the process is not root and the root file system is not writable. The `*_temp_path` lines move nginx's temporary files to `/tmp` for the same reason.

```nginx
location ~ ^/.+\.git/(HEAD|info/refs|objects/info/.*|git-(upload|receive)-pack)$ {
  include /etc/nginx/fastcgi_params;
  fastcgi_pass unix:/tmp/fcgiwrap.sock;
  fastcgi_param SCRIPT_FILENAME /usr/libexec/git-core/git-http-backend;
  fastcgi_param GIT_PROJECT_ROOT /srv/git;
  fastcgi_param GIT_HTTP_EXPORT_ALL "";
  fastcgi_param PATH_INFO $uri;
  fastcgi_param REMOTE_USER local;
}
```
The regular expression matches only the Git protocol paths of a repository named `*.git`. The block passes them over a Unix socket to `fcgiwrap`, telling it which program to run (`SCRIPT_FILENAME`), where the repositories are (`GIT_PROJECT_ROOT`), that every repository may be served (`GIT_HTTP_EXPORT_ALL` empty means "yes"), and the request path (`PATH_INFO`). `REMOTE_USER local` marks pushes as coming from a user, which `git-http-backend` needs to allow `receive-pack`. `client_max_body_size 50m` allows larger pushes. There is **no authentication**: this server is for local use and is only reachable on `127.0.0.1`.

<!-- full-walkthrough:begin -->
### 5.A Full walkthrough: both nginx files

**Words you need first.** A **web server** is a program that listens on a port and answers web requests. nginx reads a configuration of **blocks** (`name { … }`) and **directives** (`name value;`, each ending with a semicolon).

#### `docker/web/default.conf.template`: the demo application

```nginx
server {
  listen 8080;
  server_name _;

  location = /healthz {
    default_type text/plain;
    return 200 "ok\n";
  }

  location = /version {
    default_type text/plain;
    return 200 "${APP_VERSION}\n";
  }

  location = / {
    default_type text/plain;
    return 200 "${GREETING}\n";
  }
}
```

- `server { … }` describes one site. `listen 8080;` listens on port 8080. `server_name _;` matches any host name.
- `location = /healthz { … }` handles requests for exactly that path: `default_type text/plain;` sets the type of the answer, `return 200 "ok\n";` answers status 200 (success) with the text `ok` and a line break.
- `/version` returns `${APP_VERSION}` and `/` returns `${GREETING}`. A **template** has `${NAME}` placeholders. The nginx image used here replaces them with the container's environment variables when the container starts (a program called `envsubst` does it) and writes the result to `/etc/nginx/conf.d/default.conf`. So `GREETING` (from the ConfigMap) and `APP_VERSION` (set when the image was built) appear in the page.


The Git server's `nginx.conf` is walked through under the Docker note (it sits with the Git server's Dockerfile and entrypoint).
<!-- full-walkthrough:end -->

## 6. Try it yourself

1. `docker run --rm -p 18080:8080 -e GREETING=hello -e APP_VERSION=x plainround/web:1.0.0` then `curl -s localhost:18080/healthz` : `ok`.
2. `curl -s http://127.0.0.1:30438/gitops-fleet.git/info/refs?service=git-upload-pack | head -c 200` (cluster up) : Git's ref advertisement.
3. `kubectl --context k3d-fleet-hub -n web exec deploy/web -- cat /etc/nginx/conf.d/default.conf` : the rendered file with the greeting in place.
4. `kubectl --context k3d-fleet-hub -n git-server logs deploy/git-server | tail` : one access-log line per poll from Argo CD.
5. `git ls-remote http://127.0.0.1:30438/gitops-fleet.git` : the branches on the server.

## 7. Mistakes people make

- Listening on port 80 as a non-root user.
- Letting nginx write to a read-only file system; its temp and pid paths are redirected to `/tmp`.
- Assuming an environment variable change reaches nginx without a restart.

## 8. Check yourself

1. What does `location = /healthz` match?
   *Answer:* Exactly that path and no other.
2. How does `${GREETING}` get its value?
   *Answer:* `envsubst` renders the template at container start using the environment.
3. How does nginx serve Git?
   *Answer:* It forwards Git protocol paths over FastCGI to `fcgiwrap`, which runs `git-http-backend`.
4. Why are pid and temp paths under `/tmp`?
   *Answer:* The container runs as a non-root user with a read-only root file system.
5. Why does a ConfigMap change need a Pod restart here?
   *Answer:* The template is rendered once, at start.

## 9. Further reading

- nginx documentation: <https://nginx.org/en/docs/> (image `nginx-unprivileged:1.31.7`). `git-http-backend`: <https://git-scm.com/docs/git-http-backend>. Template handling of the Docker image: <https://hub.docker.com/_/nginx> (section on environment variables in configuration).
