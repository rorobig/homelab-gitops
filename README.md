# homelab-gitops

Argo CD source of truth for cluster apps.

## Layout

- `apps/00-platform` first-wave platform apps
- `apps/10-observability` observability apps
- `platform/networking` shared Gateway API resources
- `bootstrap/` helper manifests/scripts

## Bootstrap from local machine

```bash
cd bootstrap
./apply-monitoring-app.sh
```

By default this applies `all-apps-of-apps.yaml` (full rollout).

To apply only observability:

```bash
APP_MANIFEST=./monitoring-app-of-apps.yaml ./apply-monitoring-app.sh
```
