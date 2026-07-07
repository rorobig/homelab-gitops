#!/usr/bin/env bash
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-/home/roro/dev/homelab-proxmox/kubeconfig.yaml}"

kubectl --kubeconfig="$KUBECONFIG" apply -f "$(dirname "$0")/monitoring-app-of-apps.yaml"
