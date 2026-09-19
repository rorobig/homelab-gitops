# homelab-gitops

Everything that runs **on** the k3s cluster, managed by Argo CD. The cluster itself (VMs, k3s, Argo CD install)
is built by [homelab-proxmox](https://github.com/rorobig/homelab-proxmox). Push to `main` and the cluster follows.

This repo is a playground for: **agentgateway** (an AI/HTTP gateway), a **local LLM**, **Grafana visibility** of
AI traffic, and getting ready for **Kargo** (promoting apps dev → staging → prod).

## The big picture

```
 your PC ──DNS──▶ k8s-gateway (asks "where is llm.home.arpa?" → node IPs)
    │
    └──HTTP :80──▶ ServiceLB (k3s built-in load balancer, listens on every node)
                      │
                      ▼
               agentgateway proxy  ◀── Gateway "agentgateway-proxy" (the front door for everything)
                 │  reads HTTPRoutes, applies policies, logs + counts tokens
                 ├─▶ argocd.home.arpa      → Argo CD UI
                 ├─▶ grafana.home.arpa     → Grafana (dashboards)
                 ├─▶ podinfo-{dev,staging,prod}.home.arpa → demo app in 3 environments
                 ├─▶ llm.home.arpa         → local LLM (Ollama), prompts screened for credit cards
                 └─▶ pirate.home.arpa      → same LLM, but the gateway injects a "pirate" system prompt
```

Three ideas to hold on to:

1. **One front door.** Every URL goes through the agentgateway proxy on port 80. A URL exists because an
   `HTTPRoute` says "this hostname → that service". Add a route, get a URL.
2. **DNS is automatic.** `k8s-gateway` watches the HTTPRoutes and answers DNS for every `*.home.arpa` hostname.
   No hosts-file edits. Set your PC's DNS to a node IP (e.g. `192.168.1.208`) with the router as secondary.
3. **Git is the source of truth.** Argo CD watches this repo. Edit → commit → push → cluster changes.

## What is deployed (and why)

Apps are Argo CD `Application`s in `apps/`. The `sync-wave` annotation is the boot order (low numbers first).

| Wave | App | What it is |
|---|---|---|
| 0 | `gateway-api-crds` | The Kubernetes Gateway API definitions (`Gateway`, `HTTPRoute`, ...) |
| 1 | `kube-prometheus-stack` | Prometheus + Grafana. First, because other apps ship dashboards/monitors for it |
| 1 | `agentgateway-crds` | agentgateway's own resource types (`AgentgatewayBackend`, `AgentgatewayPolicy`) |
| 2 | `agentgateway` | The controller. Creates the `agentgateway` GatewayClass and runs a proxy per Gateway |
| 3 | `gateway` | Our one `Gateway` (`platform/networking/gateway/`), HTTP on port 80 |
| 4 | `routes` | Plain HTTPRoutes: Argo CD and Grafana (`platform/networking/routes/`) |
| 5 | `cert-manager` | Certificates. Not used yet; **Kargo needs it** |
| 6 | `k8s-gateway` | The DNS server for `*.home.arpa` |
| 20 | `podinfo-*` | Tiny demo app x3 environments (an `ApplicationSet`), the Kargo playground |
| 20 | `llm` | Ollama (local model) + agentgateway backends/policies/routes (`workloads/llm/`) |

## See the AI features (the fun part)

The local model is `qwen2.5:0.5b` (tiny, so answers are silly, but the plumbing is real). Use the helper script:

```bash
./scripts/llm-demo.sh chat "What is a pod?"   # normal chat, prints reply + token usage
./scripts/llm-demo.sh blocked                 # a prompt with a credit card -> 403 from the gateway
./scripts/llm-demo.sh load 30                 # a burst of mixed traffic
```

What to look at while you do that:

- **Grafana** → `http://grafana.home.arpa` → dashboard **Agentgateway** (login `admin` / `prom-operator`).
  Token usage by model, request rates, latency.
- **Access log** of every request, with tokens, model and duration:
  `kubectl -n agentgateway-system logs deploy/agentgateway-proxy -f`
- **Raw metrics**: `agentgateway_gen_ai_client_token_usage` (labels: token type, model, route).

The "magic" so far, all done by the gateway with **no change to the caller**:

| Try | What happens | Where |
|---|---|---|
| `llm.home.arpa` with any model name | Gateway rewrites the model to the real one | `workloads/llm/backend.yaml` |
| Prompt containing `4111 1111 1111 1111` | Rejected at the gateway with 403, never reaches the model | `workloads/llm/guard.yaml` |
| Same question to `pirate.home.arpa` | Gateway prepends a system prompt: pirate answers | `workloads/llm/pirate.yaml` |

## How to add things

- **A new URL for an existing service:** add an `HTTPRoute` with a `*.home.arpa` hostname pointing at the
  `agentgateway-proxy` Gateway (copy `platform/networking/routes/grafana/httproute.yaml`). DNS appears by itself.
- **A new app:** add an `Application` in `apps/` (copy any file there) and push.
- **A new LLM/provider:** an `AgentgatewayBackend` (which provider) + an `HTTPRoute` (which hostname);
  optional `AgentgatewayPolicy` (guardrails, prompt rewriting, rate limits) targeting the backend.

## Layout

```
bootstrap/all-apps-of-apps.yaml   the root Application: syncs everything under apps/ (applied by Ansible)
apps/00-platform/                 gateway, DNS, cert-manager, routes...
apps/10-observability/            kube-prometheus-stack
apps/20-workloads/                podinfo (x3 envs) and the LLM demo
platform/                         manifests the platform apps point at (gateway, routes)
workloads/                        manifests for the sample apps (podinfo kustomize overlays, llm)
scripts/llm-demo.sh               helper to poke the LLM
```

## Bootstrap

The Ansible `argocd-bootstrap` role in homelab-proxmox installs Argo CD and applies the root app.
To (re)apply it by hand: `kubectl apply -f bootstrap/all-apps-of-apps.yaml`.

## Kargo prep

`podinfo` runs as `podinfo-dev`, `-staging` and `-prod` (Kustomize base + overlays in `workloads/podinfo/`).
All three start on image tag `6.14.0`; newer tags exist, so Kargo will have something to discover and promote.
The image tag lives in each overlay's `kustomization.yaml`, which is the file a promotion edits.
Still to do: install Kargo itself, give it a GitHub token that can push to this repo, and add the
`kargo.akuity.io/authorized-stage` annotation to the podinfo Applications.

## Things that bit us (so they don't bite twice)

- **Port 53 + ServiceLB hijacks the node's own DNS.** k3s ServiceLB opens `:53` on every node for `k8s-gateway`,
  which also captured each node's lookups to its local resolver (`127.0.0.53`). If the DNS pod was down, nodes
  couldn't pull images, so it could never start. Fix: nodes resolve straight against the router
  (`/etc/resolv.conf` → `/run/systemd/resolve/resolv.conf`, done by the Ansible `k3s-bootstrap` role).
- **Wave order matters.** Prometheus's CRDs must exist before anything creates a `PodMonitor`, so
  `kube-prometheus-stack` is wave 1 and Prometheus is set to scrape every PodMonitor.
- **Node IPs come from DHCP** and can change. A stable single address would need MetalLB (not set up).

## Ideas for next time

Token-based rate limits per route, failover between two local models, OpenTelemetry tracing of LLM calls,
federating MCP servers through the gateway, `kagent` (agents that run on the cluster and use this gateway as
their LLM), and pointing a real chat UI at `llm.home.arpa`. Hosted models (Claude, OpenAI) are just another
`AgentgatewayBackend` with an API key in a Secret, if you ever want one.
