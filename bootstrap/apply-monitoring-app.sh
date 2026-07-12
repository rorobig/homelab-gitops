#!/usr/bin/env bash
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-/home/roro/dev/homelab-proxmox/kubeconfig.yaml}"
APP_MANIFEST="${APP_MANIFEST:-$(dirname "$0")/all-apps-of-apps.yaml}"

kubectl --kubeconfig="$KUBECONFIG" apply -f "$APP_MANIFEST"
