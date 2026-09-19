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
| **MCP** | "Model Context Protocol": a standard way for AI apps to discover and call *tools* ("roll a die", "look up a ticket"). Agents and AI assistants speak it. |
| **Agent** | An AI model that keeps deciding "which tool do I call next?" until it can answer. A loop of think, act, think. |
| **kagent** | An open-source (Apache 2.0) framework for running agents on Kubernetes. You describe an agent in YAML; it runs it. |
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

### 5. Failover: the AI survives an outage
```bash
./scripts/llm-demo.sh failover-demo      # the whole story in one go (needs kubectl; see the script header)
./scripts/llm-demo.sh failover           # or just ask once and see WHICH model answered
```
**You see:** three phases. (1) The smart model (`qwen2.5:1.5b`) answers. (2) The script switches it off; requests keep
working but now the tiny `qwen2.5:0.5b` answers; the first one is slightly slower because it retries. (3) It is switched
back on and, after about 30 seconds, the smart model answers again. The `model` in each reply tells you who answered.
**Why:** `workloads/llm/failover.yaml` lists two models in priority order behind one URL. Listing two is *not* enough
(we tested: a dead primary just gave `503`). It also needs a **health policy** (after one failure, stop using that model
for 30 s) and a **retry policy** (redo the failed request, which now lands on the fallback). All three are in that file,
with comments. **Try:** change `duration: 30s`, or look for `retry.attempt=2` in the proxy log during the outage.

### 6. MCP: tools through the gateway
```bash
./scripts/mcp-demo.sh demo               # list the tools, then call each one
./scripts/mcp-demo.sh call roll_dice '{"sides":20}'
```
**You see:** a list of five silly tools (one of them draws a colourful cow, try `./scripts/mcp-demo.sh call cowsay '{"text":"moo","color":"cyan"}'`) (`roll_dice`, `add`, `cowsay`, `time_now`, `homelab_fact`) and their results.
**Why:** `workloads/mcp/server.yaml` is a tiny tool server (a few lines of Python in a ConfigMap). `workloads/mcp/gateway.yaml`
puts it behind the gateway at `http://mcp.home.arpa/mcp`. The script talks to the gateway exactly like an AI app or
agent would: open a session, ask "what tools do you have?", then call one. The gateway sits in the middle, so it logs
every call (`mcp.method.name=tools/call`, tool name, duration) and counts them: open Grafana and the **MCP** row (expand it)
fills with per-method and per-tool counts. You can also point a real MCP client (for example
`npx @modelcontextprotocol/inspector`) at `http://mcp.home.arpa/mcp`.
**Try:** add a tool in `server.yaml` (a Python function with `@mcp.tool()`), bump `code-version` in the Deployment (the pod only reads the code when it starts), push, and list the tools again.

### 7. An AI agent (kagent)
Open **http://kagent.home.arpa**, skip the first-run wizard, and pick an agent:

| Agent | Try asking | What it uses |
|---|---|---|
| `cluster-agent` | "How many nodes does the cluster have?" / "List the pods in the ai namespace" | kagent's built-in **read-only** Kubernetes tool |
| `fun-agent` | "Roll a 20-sided die" / "Make the cow say hello in cyan" | our demo tools from demo 6 |

**What is an agent?** A loop. The model is given a question and a list of tools. It replies either with an answer or with
"call tool X with these arguments"; the agent runs the tool, hands the result back, and asks the model again, until it can
answer. Nothing here is magic: it is demo 6 (tools) plus demo 1 (the model), driven by a loop that kagent runs for you.

**Where the gateway is in this.** Everything the agent does passes through agentgateway, in two directions:
- its *thinking* goes to `/v1` (the LLM route: the smart model, with the tiny fallback), and
- its *actions* go to `/mcp` (one endpoint that combines our demo tools and kagent's Kubernetes tools).
So the proxy log and Grafana show the agent's token usage and every tool it called. Try:
`kubectl -n agentgateway-system logs deploy/agentgateway-proxy -f` while you chat.

**Files:** `apps/30-agents/` installs kagent (trimmed down, see below); `workloads/kagent/` holds our setup, each file
commented: `agent.yaml` (model, tools, the two agents), `gateway.yaml` (how agents reach the gateway), `rbac.yaml`,
`route.yaml`.

**Honest limits.** The model is small (1.5B). It is reliable when an agent has ONE job, one or two tools, and a worked
example in its instructions (see `agent.yaml`); with all the tools at once it picked the wrong one. Its wording is
sometimes clumsy even when the facts are right. Change `modelConfig` to a stronger model and it gets much better.

**Failover and agents.** If the big model is down, the gateway still fails over (demo 5), but the tiny 0.5B fallback is
too weak to run an agent: expect empty or wrong answers until the big model is back. The failover route is still a
good safety net for plain chat.

**Safety.** An agent lets an AI decide what to run against your cluster, so: the Kubernetes tool server is set to
read-only (both its permissions and the server itself), limited to `get`-style tools, and each agent only sees the few
tools it needs. Don't loosen that casually.

## Where to click

| URL | What | Login |
|---|---|---|
| http://argocd.home.arpa | Argo CD: see every app and whether it's in sync | `admin` + `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| http://grafana.home.arpa | Dashboards | `admin` / `prom-operator` |
| http://llm.home.arpa | the AI (OpenAI-style API at `/v1/chat/completions`) | none |
| http://pirate.home.arpa | the same AI with the pirate instruction | none |
| http://failover.home.arpa | smart model with an automatic fallback | none |
| http://mcp.home.arpa/mcp | the MCP tool server (use `scripts/mcp-demo.sh`) | none |
| http://kagent.home.arpa | kagent: chat with the AI agents | none |
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
| 20 | `llm` | Two Ollamas (small + big) and the AI routes: guard, pirate, failover (`workloads/llm/`) |
| 20 | `mcp` | The demo MCP tool server and its gateway route (`workloads/mcp/`) |
| 21 | `kagent-crds` | Teaches Kubernetes what an `Agent` / `ModelConfig` is |
| 22 | `kagent` | kagent itself: controller, UI, small database, read-only Kubernetes tool server |
| 25 | `kagent-config` | Our agents, their model + tools, and how they reach the gateway (`workloads/kagent/`) |

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
apps/                             one Argo CD Application per file (00-platform, 10-observability, 20-workloads, 30-agents)
platform/networking/              the Gateway and the plain routes
platform/observability/           Prometheus scrape config + Grafana dashboard for agentgateway
workloads/llm/                    the AI demos: ollama (+big), backend, route, guard, pirate, failover
workloads/mcp/                    the MCP demo: tool server + gateway route
workloads/kagent/                 the AI agents: model, tools, agents, gateway wiring, UI route
workloads/podinfo/                the demo app: base + dev/staging/prod overlays
scripts/llm-demo.sh               helper to poke the AI (chat, blocked, load, failover-demo)
scripts/mcp-demo.sh               helper to list and call MCP tools through the gateway
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
- **kagent is installed with most of it switched off** (`apps/30-agents/kagent.yaml`). By default it starts ten
  ready-made agents (Kubernetes, Istio, Cilium...), each its own pod, which is far too much for 4 GB nodes.
  Only the controller, UI, a small database and the Kubernetes tool server remain.
- **`kagent-controller` may restart once or twice on first install.** It starts before its database is ready, fails
  its migration, and retries. It settles by itself.
- **The big model server is kept off the control-plane node** (`workloads/llm/ollama-big.yaml`): that node also runs k3s
  and ran out of memory headroom (87%) with the model on it.
- **Agents call the gateway by its Kubernetes Service name**, not by a `*.home.arpa` name (those only exist for your PC),
  so `workloads/kagent/gateway.yaml` has a route for that name.
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

A token budget per route (return `429` when used up), tracing of AI calls (Jaeger), an A/B split between two models,
a stronger model for the agents (a hosted one is just one more `AgentgatewayBackend` with an API key in a Secret),
more tools for the agents (each behind the gateway, where you can log and limit them), agents that call other agents,
API keys at the gateway, a real chat UI pointed at `llm.home.arpa`.
