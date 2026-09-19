# homelab-gitops

Argo CD source of truth for the k3s cluster built by [homelab-proxmox](https://github.com/rorobig/homelab-proxmox).

## Layout

- `bootstrap/all-apps-of-apps.yaml` — root Application; syncs everything under `apps/`
- `apps/00-platform` — Gateway API CRDs, agentgateway (CRDs + controller), the Gateway, routes
- `apps/10-observability` — kube-prometheus-stack
- `platform/` — manifests, charts and values that the apps above point at

Ordering between apps is controlled by `argocd.argoproj.io/sync-wave` annotations.

## Bootstrap

The Ansible `argocd-bootstrap` role in homelab-proxmox installs Argo CD and applies the root app.
To (re)apply it by hand:

```bash
kubectl apply -f bootstrap/all-apps-of-apps.yaml
```
