#!/usr/bin/env bash
# Poke the LLM behind agentgateway and watch it in Grafana ("Agentgateway" dashboard) or the proxy logs.
#   ./scripts/llm-demo.sh chat "your question"   one chat, prints the reply + token usage
#   ./scripts/llm-demo.sh blocked                a prompt with a credit card -> rejected by the gateway (403)
#   ./scripts/llm-demo.sh load [N]               N mixed requests (default 15) to fill the dashboard
#   ./scripts/llm-demo.sh failover               ask failover.home.arpa once and show WHICH model answered
#   ./scripts/llm-demo.sh failover-demo          the whole story: healthy -> outage -> fallback -> recovery (needs kubectl)
# Needs llm.home.arpa to resolve (see README). Override with LLM_URL=http://<node-ip> LLM_HOST=llm.home.arpa.
# failover-demo runs kubectl; set KUBECTL="ssh root@<node-ip> kubectl" if your local kubeconfig isn't set up.
set -euo pipefail
URL="${LLM_URL:-http://llm.home.arpa}"
HOST="${LLM_HOST:-llm.home.arpa}"

ask() { # $1 = prompt
  curl -s -m 120 "$URL/v1/chat/completions" -H "Host: $HOST" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg p "$1" '{model:"any-model-name", messages:[{role:"user",content:$p}]}')"
}

case "${1:-chat}" in
  chat)
    ask "${2:-Explain what an API gateway does in one sentence.}" | jq '{model, reply: .choices[0].message.content, usage}' ;;
  blocked)
    curl -s -i -m 30 "$URL/v1/chat/completions" -H "Host: $HOST" -H 'Content-Type: application/json' \
      -d '{"model":"x","messages":[{"role":"user","content":"Remember my card 4111 1111 1111 1111"}]}' | sed -n '1p;$p' ;;
  load)
    prompts=("Tell me a joke about Kubernetes." "What is a service mesh?" "Write a haiku about DNS." "Why is the sky blue?"
             "Give me 3 tips for learning Go." "What does GitOps mean?" "Explain tokens in LLMs briefly.")
    for i in $(seq 1 "${2:-15}"); do
      if (( i % 5 == 0 )); then
        printf '%2d blocked  ' "$i"; curl -s -o /dev/null -w '%{http_code}\n' -m 30 "$URL/v1/chat/completions" -H "Host: $HOST" \
          -H 'Content-Type: application/json' -d '{"model":"x","messages":[{"role":"user","content":"card 4111111111111111"}]}'
      else
        p="${prompts[$((RANDOM % ${#prompts[@]}))]}"; printf '%2d chat     ' "$i"
        ask "$p" | jq -r '"\(.usage.prompt_tokens) in / \(.usage.completion_tokens) out tokens"'
      fi
    done ;;
  failover)
    HOST=failover.home.arpa
    ask "${2:-In five words, what is Kubernetes?}" | jq -r '"answered by: \(.model)   reply: \(.choices[0].message.content)"' ;;
  failover-demo)
    HOST=failover.home.arpa; KC=${KUBECTL:-kubectl}
    who() { local t0=$SECONDS; ask "In five words, what is Kubernetes?" | jq -r --arg t "$((SECONDS - t0))" '"  answered by \(.model)  (\($t)s)  \(.choices[0].message.content | .[0:60])"'; }
    echo "1. Both models healthy: the smart one (1.5B) should answer"; who; who
    echo; echo "2. OUTAGE: stopping the smart model (kubectl scale ... --replicas=0)"
    $KC -n ai scale deploy/ollama-big --replicas=0 >/dev/null
    $KC -n ai wait --for=delete pod -l app=ollama-big --timeout=90s >/dev/null 2>&1 || true
    echo "   requests keep working, now answered by the tiny fallback (the first one retries, so it is a bit slower):"
    who; who; who
    echo; echo "3. RECOVERY: starting the smart model again"
    $KC -n ai scale deploy/ollama-big --replicas=1 >/dev/null
    $KC -n ai rollout status deploy/ollama-big --timeout=240s >/dev/null
    echo "   the gateway keeps the failed provider out for 30 s, then traffic returns:"
    for i in $(seq 1 12); do out=$(who); echo "$out"; case "$out" in *1.5b*) break ;; esac; sleep 5; done ;;
  *) echo "usage: $0 {chat [prompt]|blocked|load [N]|failover [prompt]|failover-demo}"; exit 1 ;;
esac
