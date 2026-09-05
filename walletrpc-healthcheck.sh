#!/bin/sh
# Authenticate and verify that wallet-rpc returns a valid chain height.
set -eu

RPC_URL="http://127.0.0.1:${RPC_PORT:-18082}/json_rpc"
RPC_USER="${RPC_USER:-sal_rpc}"
RPC_PASS="$(tr -d '\r\n' < /run/secrets/rpc_password)"
[ -n "$RPC_PASS" ]

response=$(curl --silent --show-error --fail --max-time 15 --digest \
  --user "${RPC_USER}:${RPC_PASS}" \
  --header 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":"health","method":"get_height"}' \
  "$RPC_URL")

printf '%s' "$response" | jq -e '
  (.error == null) and
  (.result.height | type == "number") and
  (.result.height > 0)
' >/dev/null
