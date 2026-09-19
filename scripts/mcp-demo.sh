#!/usr/bin/env bash
# Talk MCP to the demo tool server THROUGH agentgateway (http://mcp.home.arpa/mcp), like an AI app would.
#   ./scripts/mcp-demo.sh tools                      list the tools the server offers
#   ./scripts/mcp-demo.sh call roll_dice '{"sides":20}'   run one tool with JSON arguments
#   ./scripts/mcp-demo.sh call cowsay '{"text":"hi","color":"cyan"}'   colours: red green yellow blue magenta cyan rainbow
#   ./scripts/mcp-demo.sh demo                       list, then call a few tools
# Each run: open a session -> (list | call) -> done. Same steps an AI app or agent does under the hood.
# Override the address with MCP_URL=http://<node-ip>/mcp and MCP_HOST=mcp.home.arpa if DNS isn't set up.
set -euo pipefail
URL="${MCP_URL:-http://mcp.home.arpa/mcp}"
HOST="${MCP_HOST:-mcp.home.arpa}"
HDR=(-H "Host: $HOST" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')

# The server answers as an event stream ("data: {json}"); this pulls the JSON out of it.
json() { sed -n 's/^data: //p' | head -1; }

open_session() {  # step 1: "hello" -> the gateway gives us a session id
  SID=$(curl -s -m 30 -D - -o /dev/null "${HDR[@]}" "$URL" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"mcp-demo.sh","version":"1"}}}' \
    | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' | tr -d '\r')
  [ -n "$SID" ] || { echo "could not open an MCP session at $URL" >&2; exit 1; }
  curl -s -m 30 -o /dev/null "${HDR[@]}" -H "Mcp-Session-Id: $SID" "$URL" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
}
rpc() {  # $1 = JSON-RPC body
  curl -s -m 60 "${HDR[@]}" -H "Mcp-Session-Id: $SID" "$URL" -d "$1" | json
}
list_tools() { rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | jq -r '.result.tools[] | "  \(.name)\t\(.description)"' | column -t -s$'\t'; }
call_tool() {  # $1 = tool name, $2 = JSON arguments
  rpc "$(jq -nc --arg n "$1" --argjson a "${2:-{\}}" '{jsonrpc:"2.0",id:3,method:"tools/call",params:{name:$n,arguments:$a}}')" \
    | jq -r '.result.content[]?.text // .error.message'
}

case "${1:-tools}" in
  tools) open_session; echo "Tools offered by the server (via the gateway):"; list_tools ;;
  call)  open_session; call_tool "${2:?tool name required}" "${3:-{\}}" ;;
  demo)  open_session
         echo "Tools offered:"; list_tools; echo
         for c in 'roll_dice {"sides":20}' 'add {"a":40,"b":2}' 'cowsay {"text":"moo, hello gateway!","color":"rainbow"}' 'time_now {}' 'homelab_fact {}'; do
           name=${c%% *}; args=${c#* }; printf '%-12s %-26s -> ' "$name" "${args:0:26}"; [ "$name" = cowsay ] && echo; call_tool "$name" "$args"
         done ;;
  *) echo "usage: $0 {tools|call <tool> [json-args]|demo}"; exit 1 ;;
esac
