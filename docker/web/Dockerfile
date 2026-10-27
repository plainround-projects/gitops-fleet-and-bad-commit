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
