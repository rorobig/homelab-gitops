# homelab-gitops

Argo CD source of truth for the k3s cluster built by [homelab-proxmox](https://github.com/rorobig/homelab-proxmox).

## Layout

- `bootstrap/all-apps-of-apps.yaml` — root Application; syncs everything under `apps/`
- `apps/00-platform` — Gateway API CRDs, agentgateway (CRDs + controller), the Gateway, cert-manager, DNS (k8s-gateway), routes
- `apps/10-observability` — kube-prometheus-stack
- `apps/20-workloads` — sample apps; `podinfo` is an ApplicationSet with dev/staging/prod (the Kargo playground)
- `workloads/` — Kustomize base + per-environment overlays for those apps (image tag lives in each overlay)
- `platform/` — manifests, charts and values that the apps above point at

Ordering between apps is controlled by `argocd.argoproj.io/sync-wave` annotations.

## Bootstrap

The Ansible `argocd-bootstrap` role in homelab-proxmox installs Argo CD and applies the root app.
To (re)apply it by hand:

```bash
kubectl apply -f bootstrap/all-apps-of-apps.yaml
```

## URLs and DNS

The `k8s-gateway` app is a DNS server for `*.home.arpa`: any HTTPRoute hostname (argocd, grafana, podinfo-*, ...)
resolves automatically to the node IPs, and everything else is forwarded upstream. It listens on :53 of every node.

Set your PC's DNS to a node IP (preferred) with the router as the secondary, then no hosts-file entries are needed:

```
dig @<node-ip> argocd.home.arpa     # sanity check
```

To add a new app URL, just add an HTTPRoute with a `*.home.arpa` hostname.
