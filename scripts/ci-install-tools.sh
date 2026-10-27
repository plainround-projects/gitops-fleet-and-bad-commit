#!/usr/bin/env bash
# Installs the tools CI needs on an Ubuntu runner: kubeconform. Local machines use `brew install kubeconform`.
set -euo pipefail

version="v0.8.0"
curl -fsSL "https://github.com/yannh/kubeconform/releases/download/${version}/kubeconform-linux-amd64.tar.gz" | sudo tar -xz -C /usr/local/bin kubeconform
kubeconform -v
