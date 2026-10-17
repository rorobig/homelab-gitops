# homelab-gitops

Everything in the homelab, as git: the clusters themselves and what runs on them. Argo CD on the **mgmt** cluster
watches this repo and makes reality match it. Edit a file, push to `main`, and it follows within a few minutes.
mgmt itself is built by [homelab-proxmox](https://github.com/rorobig/homelab-proxmox), which also explains the
architecture and network.

## URLs

Point your PC's DNS at `192.168.1.71` (router as backup). In PowerShell as admin:

```powershell
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 192.168.1.71,192.168.1.1
```

| URL | Cluster | Login |
|---|---|---|
| http://argocd.home.arpa | mgmt | `admin` + `kubectl --context mgmt -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| http://grafana.home.arpa | talos | `admin` / `prom-operator` |

## Layout

```
bootstrap/root.yaml           the root app (applied once by mgmt/up.sh): one Application per file in apps/
apps/mgmt/                    Applications that deploy to the mgmt cluster
apps/talos/                   Applications that deploy to the talos cluster (destination: name: talos)
clusters/                     Cluster API clusters: one file = one cluster. Delete the file, delete the cluster.
platform/cluster-registration/  CronJob that adds every Cluster API cluster to Argo CD
platform/networking/          per cluster: MetalLB pool, Gateway, HTTPRoutes
platform/observability/       Prometheus scrape config + Grafana dashboard for agentgateway
```

## What's deployed

`sync-wave` is the install order (low first). Apps for talos retry until the cluster exists, so they also
come back on their own after a rebuild.

| Wave | mgmt | talos |
|---|---|---|
| 0 | `gateway-api-crds` | `gateway-api-crds` |
| 1 | `agentgateway-crds`, `metallb` | `agentgateway-crds`, `metallb`, `local-path-provisioner`, `kube-prometheus-stack` |
| 2 | `agentgateway`, `metallb-config` (.71) | `agentgateway`, `metallb-config` (.70) |
| 3 | `gateway`, `dns` | `gateway`, `agentgateway-monitoring` |
| 4 | `routes` (Argo CD) | `routes` (Grafana) |
| 5 | `clusters`, `cluster-registration` | |

## Common changes

- **New app on talos:** add a file in `apps/talos/` with `destination: name: talos`. Copy an existing one.
- **New URL:** copy `platform/networking/routes/talos/grafana/httproute.yaml`, change hostname and service.
  DNS already answers every `*.home.arpa` with the talos gateway (`.70`).
- **Change a cluster:** edit `clusters/talos.yaml`. See the practice list in homelab-proxmox.

## Gotchas

- **Manual changes get reverted** (Argo CD self-heal), including `kubectl edit` on Cluster API objects. Change git.
- **Talos enforces `baseline` pod security.** Namespaces whose pods need host access (MetalLB, node-exporter,
  local-path) get `pod-security.kubernetes.io/enforce: privileged` via `managedNamespaceMetadata`.
- **PVCs live on one node.** `local-path` data is gone when Cluster API replaces that node.
- **The agentgateway dashboard and PodMonitor are our own** (`platform/observability/agentgateway/`). The chart's
  versions need a newer Grafana than ours.
