# homelab-gitops

Everything that runs on the homelab cluster: a Talos cluster on Proxmox, managed by Cluster API. The cluster itself
(VMs, Talos, Argo CD) is built from [homelab-proxmox](https://github.com/rorobig/homelab-proxmox).

**How it works:** Argo CD watches this repo and makes the cluster match it. You don't `kubectl apply` things by
hand. Edit a file, push to `main`, and the cluster follows.

What's here:
- **agentgateway**: the front door. Every `*.home.arpa` URL goes through it.
- **Prometheus + Grafana**: metrics and dashboards.
- **Kargo**: promotes the demo app **podinfo** through dev → staging → prod.

## URLs

Point your PC's DNS at `192.168.1.70` first (see [DNS](#dns) below).

| URL | What | Login |
|---|---|---|
| http://argocd.home.arpa | Argo CD | `admin` + `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| http://kargo.home.arpa | Kargo | `admin` + the password you set (see [Kargo password](#kargo-password)) |
| http://grafana.home.arpa | Grafana | `admin` / `prom-operator` |
| http://podinfo-dev.home.arpa | podinfo, dev | none |
| http://podinfo-staging.home.arpa | podinfo, staging | none |
| http://podinfo-prod.home.arpa | podinfo, prod | none |

## Layout

```
bootstrap/all-apps-of-apps.yaml   the root app: creates one Argo CD Application per file in apps/
apps/                             one Argo CD Application per file
platform/networking/              the Gateway (port 80), MetalLB's IP pool, routes for Argo CD, Grafana, Kargo
platform/observability/           Prometheus scrape config + Grafana dashboard for agentgateway
platform/delivery/podinfo/        Kargo pipeline for podinfo: Project, Warehouse, Stages
workloads/podinfo/                podinfo's source: base/ + overlays/{dev,staging,prod}
```

## What's deployed

The `sync-wave` on each Application is its install order (low first).

| Wave | App | What |
|---|---|---|
| 0 | `gateway-api-crds` | The `Gateway` / `HTTPRoute` resource types |
| 1 | `agentgateway-crds` | agentgateway's resource types |
| 1 | `kube-prometheus-stack` | Prometheus + Grafana |
| 1 | `metallb` | Gives LoadBalancer Services a LAN IP |
| 1 | `local-path-provisioner` | Default StorageClass `local-path` |
| 2 | `metallb-config` | MetalLB's pool: `192.168.1.70` |
| 2 | `agentgateway` | The gateway controller |
| 3 | `gateway` | The Gateway itself, on port 80 |
| 3 | `agentgateway-monitoring` | Gateway metrics + Grafana dashboard |
| 4 | `routes` | URLs for Argo CD, Grafana, Kargo |
| 5 | `cert-manager` | Certificates (Kargo needs it) |
| 6 | `k8s-gateway` | DNS server for `*.home.arpa` |
| 7 | `kargo` | Kargo |
| 8 | `kargo-delivery` | The podinfo pipeline (`platform/delivery/`) |
| 20 | `podinfo-dev/staging/prod` | podinfo, deployed from the hydrated repo |

## Kargo: promoting podinfo

Two repos:

- **This repo** holds podinfo's *source* (`workloads/podinfo/`). You edit it by hand.
- **[homelab-gitops-hydrated](https://github.com/rorobig/homelab-gitops-hydrated)** holds the *rendered* YAML,
  one branch per environment (`stage/dev`, `stage/staging`, `stage/prod`). Only Kargo writes to it. Argo CD
  deploys from it.

```
Warehouse: checks ghcr.io/stefanprodan/podinfo every 5 min; each new tag = new "Freight"
    │
    ▼
  dev ──(automatic)──▶ staging ──(you click Promote)──▶ prod
```

Each promotion: render the overlay with the new image tag, commit it to that stage's branch, and tell that stage's
Argo CD app to deploy it.

**Promote in the UI:** open the `podinfo` project, then click **Promote** on the target stage box (staging or prod)
and pick the Freight. A stage only accepts Freight that has passed the stage before it.

**Changing podinfo's config** (replicas, env vars, ...): edit `workloads/podinfo/`, push. The change is picked up
on the next promotion of each stage.

### Kargo setup (already done, not in git)

Two Secrets exist in the cluster that are not in this repo, on purpose:

- `kargo/kargo-bootstrap-secrets`: the admin password hash + token signing key.
- `podinfo/github-hydrated`: a GitHub token (fine-grained, Contents: read/write on the hydrated repo) that lets
  Kargo push.

### Kargo password

Only the hash is stored, so a lost password can't be recovered, only reset:

```bash
pass='new-password'
hash=$(docker run --rm httpd:2.4-alpine htpasswd -bnBC 10 "" "$pass" | tr -d ':\n')
kubectl -n kargo patch secret kargo-bootstrap-secrets -p "{\"stringData\":{\"ADMIN_ACCOUNT_PASSWORD_HASH\":\"$hash\"}}"
kubectl -n kargo rollout restart deploy kargo-api
```

## Common changes

- **New URL for a service:** copy `platform/networking/routes/grafana/httproute.yaml`, change the hostname and
  service, push. The DNS name appears on its own.
- **New app:** copy a file in `apps/`, point it at a Helm chart or a folder, push.

## DNS

The cluster runs its own DNS for `*.home.arpa` on `192.168.1.70` (same IP as the gateway). Point your PC at it,
with the router as backup.
In PowerShell as admin:

```powershell
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 192.168.1.70,192.168.1.1
ipconfig /flushdns
nslookup argocd.home.arpa   # check
```

## Gotchas

- **Manual changes in the cluster get reverted** within seconds (Argo CD self-heal). Change the file in git.
- **Talos enforces the `baseline` pod security level.** Namespaces whose pods need host access (MetalLB's speaker,
  node-exporter) get `pod-security.kubernetes.io/enforce: privileged` via the Application's `managedNamespaceMetadata`.
- **PVCs live on one node.** `local-path` stores data in a directory on the node, so it's gone when CAPI replaces
  that node (upgrades, scaling). Fine for caches, not for data you care about.
- **The agentgateway dashboard and PodMonitor are our own** (`platform/observability/agentgateway/`). The chart's
  versions need a newer Grafana than ours.

## Rebuild from scratch

Follow [homelab-proxmox](https://github.com/rorobig/homelab-proxmox): Cluster API builds the
Talos cluster, `bootstrap-argocd.sh` installs Argo CD and the root app, and Argo CD installs everything in this repo.
