# homelab-gitops

What runs on the **talos** cluster, as git. Argo CD (on the same cluster) watches this repo and makes the
cluster match it. Edit a file, push to `main`, and it follows within a few minutes.
The cluster itself is built by [homelab-proxmox](https://github.com/rorobig/homelab-proxmox) (Terraform), which
also explains Talos and the network.

## URLs

Point your PC's DNS at `192.168.1.71` (router as backup). In PowerShell as admin:

```powershell
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 192.168.1.71,192.168.1.1
```

| URL | Login |
|---|---|
| http://argocd.home.arpa | none (everyone on the LAN is admin) |
| http://grafana.home.arpa | `admin` / `prom-operator` |

## Layout

```
bootstrap/root.yaml           the root app (applied once by Terraform): one Application per file in apps/
apps/                         one file = one Argo CD Application
platform/networking/          MetalLB pool, Gateway, HTTPRoutes
platform/observability/       Prometheus scrape config + Grafana dashboard for agentgateway
```

## What's deployed

`sync-wave` is the install order (low first).

| Wave | Apps |
|---|---|
| 0 | `gateway-api-crds` |
| 1 | `agentgateway-crds`, `metallb`, `local-path-provisioner`, `kube-prometheus-stack`, `crossplane` |
| 2 | `agentgateway`, `metallb-config` (.70-.71) |
| 3 | `gateway` (.70), `dns` (.71), `agentgateway-monitoring` |
| 4 | `routes` (Argo CD, Grafana) |

## Common changes

- **New app:** add a file in `apps/`. Copy an existing one.
- **New URL:** copy `platform/networking/routes/grafana/httproute.yaml`, change hostname and service.
  DNS already answers every `*.home.arpa` with the gateway (`.70`).

## Gotchas

- **Manual changes get reverted** (Argo CD self-heal). Change git.
- **Talos enforces `baseline` pod security.** Namespaces whose pods need host access (MetalLB, node-exporter,
  local-path) get `pod-security.kubernetes.io/enforce: privileged` via `managedNamespaceMetadata`.
- **PVCs live on one node.** `local-path` data is gone when that node is rebuilt.
- **The agentgateway dashboard and PodMonitor are our own** (`platform/observability/agentgateway/`). The chart's
  versions need a newer Grafana than ours.
