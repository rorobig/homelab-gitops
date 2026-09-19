# homelab-gitops

A small Kubernetes cluster at home, set up as a **playground for AI gateways**. It runs a tiny AI model, puts
**agentgateway** in front of it, and shows what a gateway can do with AI traffic: watch it, filter it, rewrite it.
It also has a demo app in three environments, ready for **Kargo** (promoting a version dev → staging → prod).

The cluster itself (VMs, k3s, Argo CD) is built by [homelab-proxmox](https://github.com/rorobig/homelab-proxmox).
**This repo is everything that runs on it. You never `kubectl apply` things by hand: you edit a file here, push
to `main`, and the cluster changes to match.**

## Words you'll see

| Word | Meaning here |
|---|---|
| **Argo CD** | Watches this repo and makes the cluster match it. That is "GitOps". |
| **Application** | One Argo CD unit: "deploy *this folder / this Helm chart* into *that namespace*". The files in `apps/`. |
| **Gateway** | The front door: "accept HTTP on port 80". |
| **HTTPRoute** | One rule on the door: "requests for *this hostname* go to *that service*". |
| **agentgateway** | The software behind the door. Like any proxy, but it understands AI: tokens, prompts, models. |
| **AgentgatewayBackend** | "This destination is an AI model, and it speaks the OpenAI API." |
| **AgentgatewayPolicy** | Extra rules attached to a backend (block things, rewrite prompts...). |
| **LLM / model** | The AI. Here a small one (`qwen2.5:0.5b`) run by **Ollama**. |
| **Token** | The unit AI is measured in (roughly ¾ of a word). Gateways count them to track usage and cost. |
| **DNS** | The phone book that turns `llm.home.arpa` into an IP address. We run our own inside the cluster. |

## The picture

```
 your PC ── "where is llm.home.arpa?" ──▶ DNS (k8s-gateway, in the cluster) ── answers: the node IPs
    │
    └── HTTP request to a node, port 80
            │   (k3s's built-in load balancer forwards it)
            ▼
     ┌───────────────────── agentgateway proxy  (the Gateway: platform/networking/gateway) ────────────────────┐
     │  looks at the hostname, finds the matching HTTPRoute, applies policies, logs and counts tokens          │
     └──┬──────────────┬─────────────────┬─────────────────────────┬─────────────────────────────┬────────────┘
        ▼              ▼                 ▼                         ▼                             ▼
  argocd.home.arpa  grafana.home.arpa  podinfo-{dev,staging,prod}   llm.home.arpa                 pirate.home.arpa
  (Argo CD UI)      (dashboards)       .home.arpa (demo app x3)     (the AI, with a guard)        (same AI + a hidden
                                                                                                    "pirate" instruction)
```

Every URL goes through the same front door. A URL exists because an HTTPRoute says so. Add a route, get a URL.

## Follow one request: `llm.home.arpa`

1. Your PC asks DNS for `llm.home.arpa`. The DNS server (`k8s-gateway`) reads all HTTPRoutes, sees this hostname, and
   answers with the node IPs. *(No hosts-file needed.)*
2. Your PC sends HTTP to a node on port 80. k3s's load balancer hands it to the agentgateway proxy.
3. The proxy looks at the hostname, finds the HTTPRoute called `llm` (`workloads/llm/route.yaml`), which points at the
   backend `ollama` (`backend.yaml`).
4. Because it's an AI backend, the proxy reads the **prompt**. The policy `llm-guard` (`guard.yaml`) checks it:
   credit card number? → stop here, answer `403`, the model never sees it.
5. The backend settings apply: whatever model name you sent is replaced by `qwen2.5:0.5b`.
6. The proxy forwards it to Ollama (`ollama.yaml`), the model writes an answer.
7. On the way back the proxy notes how many tokens went in and out, writes one line to its log, and bumps its metrics.
8. Prometheus collects those metrics every 15 s; Grafana draws them.

## Before you start: point your PC at the cluster's DNS

Set Windows DNS to a node IP (e.g. `192.168.1.208`) with the router (`192.168.1.1`) as the second server.
PowerShell as admin: `Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 192.168.1.208,192.168.1.1`, then
`ipconfig /flushdns`. Check: `nslookup argocd.home.arpa`. If you'd rather not, the demo script also works with
`LLM_URL=http://<node-ip> ./scripts/llm-demo.sh ...` (it sends the right hostname itself).

## The demos, one by one

All of them use `./scripts/llm-demo.sh`. The model is tiny, so its answers are often silly. That's fine: the point is
what the *gateway* does around it.

### 1. Chat through the gateway
```bash
./scripts/llm-demo.sh chat "What is a Kubernetes pod?"
```
**You see:** a reply plus `usage` (tokens in / tokens out) and `"model": "qwen2.5:0.5b"`.
**Why:** the request went client → gateway → Ollama. The script sends the model name `any-model-name`; the gateway
replaced it (`openai.model` in `workloads/llm/backend.yaml`). The token counts come from the gateway reading the reply.

### 2. The guard blocks a credit card
```bash
./scripts/llm-demo.sh blocked
```
**You see:** `HTTP/1.1 403 Forbidden` and `Blocked by agentgateway: prompt contains a credit card number.`
**Why:** `workloads/llm/guard.yaml` is a **prompt guard**: a rule at the gateway that reads every prompt before the
model does. This one looks for credit card numbers (a ready-made pattern) and rejects. The model was never called.
The file is heavily commented; start there. **Try:** change `action: Reject` to `Mask`, push, wait ~20 s, run it
again. The request now goes through, with the card number hidden from the model.

### 3. The gateway rewrites your request
```bash
LLM_HOST=pirate.home.arpa ./scripts/llm-demo.sh chat "What is a Kubernetes pod?"
./scripts/llm-demo.sh chat "What is a Kubernetes pod?"        # same question, normal route
```
**You see:** the same model answering in pirate speak on `pirate.home.arpa`.
**Why:** `workloads/llm/pirate.yaml` prepends a hidden *system* instruction to every conversation before forwarding it.
The caller changed nothing. **Try:** edit the `content:` line to another persona, push, wait, retry.

### 4. Watch it: logs and Grafana
```bash
./scripts/llm-demo.sh load 30          # 30 mixed requests (every 5th contains a card and gets blocked)
kubectl -n agentgateway-system logs deploy/agentgateway-proxy -f     # in another terminal
```
- **Log line per request** with model, `input_tokens`, `output_tokens`, duration, status. Blocked ones show
  `agw.ai.guardrails=[... "action": "reject"]`.
- **Grafana** (`http://grafana.home.arpa`, login `admin` / `prom-operator`) → dashboard **Agentgateway**:
  tokens by model, request rate, latency. Time Range "Last 15 minutes" works best.
- **Streaming:** add `"stream": true` to a request and the *Time To First Token* panel starts filling in.
- Panels for MCP calls, tool calls and cost stay empty: that's traffic we haven't generated (yet).

## Where to click

| URL | What | Login |
|---|---|---|
| http://argocd.home.arpa | Argo CD: see every app and whether it's in sync | `admin` + `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| http://grafana.home.arpa | Dashboards | `admin` / `prom-operator` |
| http://llm.home.arpa | the AI (OpenAI-style API at `/v1/chat/completions`) | none |
| http://pirate.home.arpa | the same AI with the pirate instruction | none |
| http://podinfo-dev.home.arpa (`-staging`, `-prod`) | demo web app, three copies | none |

## What is deployed

Each file in `apps/` is one Argo CD Application. The `sync-wave` number is the boot order (low first): things that
define new resource types must exist before things that use them.

| Wave | App | What it does |
|---|---|---|
| 0 | `gateway-api-crds` | Teaches Kubernetes what `Gateway` / `HTTPRoute` are |
| 1 | `kube-prometheus-stack` | Prometheus (metrics) + Grafana (dashboards) |
| 1 | `agentgateway-crds` | Teaches Kubernetes what `AgentgatewayBackend` / `AgentgatewayPolicy` are |
| 2 | `agentgateway` | The controller: runs a proxy for each Gateway |
| 3 | `gateway` | The one Gateway: port 80 |
| 3 | `agentgateway-monitoring` | Lets Prometheus scrape the proxy + the Grafana dashboard |
| 4 | `routes` | HTTPRoutes for Argo CD and Grafana |
| 5 | `cert-manager` | Certificates. **Unused for now**, Kargo needs it |
| 6 | `k8s-gateway` | The DNS server for `*.home.arpa` |
| 20 | `podinfo-*` | A tiny web app x 3 environments (one ApplicationSet), the Kargo playground |
| 20 | `llm` | Ollama + the backend, guard, pirate policy and routes (`workloads/llm/`) |

## Change things

- **New URL for an existing service:** copy `platform/networking/routes/grafana/httproute.yaml`, change the hostname
  and service. Push. The URL and its DNS name appear on their own.
- **New app:** copy any file in `apps/`, point it at a chart or a folder, push.
- **New AI model or provider:** an `AgentgatewayBackend` (where/which API) + an `HTTPRoute` (which hostname), plus
  optionally an `AgentgatewayPolicy` (guard, rewrite, ...). `workloads/llm/` is the template.
- After changing a *policy*, the proxy needs 10–20 s to notice.

## Layout

```
bootstrap/all-apps-of-apps.yaml   the root: creates one Application per file in apps/ (the only thing applied by hand)
apps/                             one Argo CD Application per file (00-platform, 10-observability, 20-workloads)
platform/networking/              the Gateway and the plain routes
platform/observability/           Prometheus scrape config + Grafana dashboard for agentgateway
workloads/llm/                    the AI demo: ollama, backend, route, guard, pirate
workloads/podinfo/                the demo app: base + dev/staging/prod overlays
scripts/llm-demo.sh               helper to poke the AI
```

## Why some things look odd

- **The Ansible `k3s-bootstrap` role rewires `/etc/resolv.conf`.** k3s's load balancer opens port 53 on every node
  for the DNS pod, which also caught each node's *own* lookups. With the DNS pod down, nodes couldn't pull images,
  so it could never start. Nodes now ask the router directly.
- **`platform/observability/agentgateway/` has its own dashboard + PodMonitor** instead of the chart's, because the
  chart's are written for a newer Grafana than this one (11.1):
  - Its dashboard says `$datasource not found`, and its dropdown variables (namespace / gateway / pod) are never
    substituted into the queries, so every panel showed "No data". Ours pins the data source and drops those
    dropdowns (there is one gateway, so nothing is lost).
  - Its PodMonitor doesn't add the label the dashboard filters on. Ours does.
  If you upgrade Grafana or the chart, try the built-in ones again and delete ours.
- **A dashboard that's managed by Argo can't be edited in place.** Changes made by hand in the cluster are reverted
  within seconds (self-heal). Change the file in git.
- **Node IPs come from DHCP** (the router) and can change; DNS and kubeconfig point at them. A fixed address for
  everything would need MetalLB or static IPs in Terraform.

## Kargo prep

`podinfo` runs as `podinfo-dev`, `-staging` and `-prod` (Kustomize base + overlays in `workloads/podinfo/`). All three
start on image `6.14.0`; newer versions exist, so Kargo will have something to discover and promote. The version lives in
each overlay's `kustomization.yaml`, which is the file a promotion edits. Still to do: install Kargo, give it a GitHub
token that can push here, and annotate the podinfo Applications (`kargo.akuity.io/authorized-stage`).

## Rebuild from scratch

Run the steps in the [homelab-proxmox README](https://github.com/rorobig/homelab-proxmox): Terraform (VMs) →
Ansible (k3s + Argo CD + the root app). Argo then installs everything in this repo by itself.

## Ideas for next time

A token budget per route (return `429` when used up), failover between two local models, tracing of AI calls,
putting an MCP server behind the gateway (fills the empty Grafana panels), `kagent` (agents on the cluster using this
gateway), a real chat UI pointed at `llm.home.arpa`. A hosted model (Claude, OpenAI) is just one more
`AgentgatewayBackend` with an API key in a Secret, if you ever want one.
