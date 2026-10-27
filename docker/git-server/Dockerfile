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
