#!/bin/bash
# Sidecar balance logger for salvium-wallet-rpc containers.
# Periodically queries the local wallet-rpc and prints a CLI-style balance
# table to stdout so it appears interleaved in `docker logs`.
# Launched in the background by the entrypoint; never exits, never fails hard.
set -u
umask 077

INTERVAL="${BALANCE_LOG_INTERVAL:-600}"
RPC_URL="http://127.0.0.1:${RPC_PORT:-18082}/json_rpc"
RPC_USER="${RPC_USER:-sal_rpc}"
PW_FILE="${RPC_PASSWORD_FILE:-/run/secrets/rpc_password}"

ts() { date '+%Y-%m-%d %H:%M:%S.%3N'; }

rpc() {
  local rpc_password
  rpc_password="$(tr -d '\r\n' < "$PW_FILE")"
  curl --silent --show-error --max-time 30 --digest -u "${RPC_USER}:${rpc_password}" \
    "$RPC_URL" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"$1\",\"params\":$2}"
}

# Give the wallet time to open before the first poll.
sleep "${BALANCE_LOG_STARTUP_DELAY:-45}"

while true; do
  ACC=$(rpc get_accounts '{}' 2>/dev/null)
  BAL=$(echo "$ACC" | jq -r '.result.subaddress_accounts[0].balance // empty' 2>/dev/null)
  UNL=$(echo "$ACC" | jq -r '.result.subaddress_accounts[0].unlocked_balance // empty' 2>/dev/null)
  if [ -n "$BAL" ] && [ -n "$UNL" ]; then
    TR=$(rpc incoming_transfers '{"transfer_type":"available","account_index":0}' 2>/dev/null)
    OUTS=$(echo "$TR" | jq -r '[.result.transfers[]? | select(.spent==false)] | length' 2>/dev/null)
    [ -n "$OUTS" ] || OUTS=0
    awk -v b="$BAL" -v u="$UNL" -v o="$OUTS" -v t1="$(ts)" 'BEGIN {
      printf "%s B %18s  %18s  %18s  %8s\n", t1, "Balance", "Unlocked balance", "Locked balance", "Outputs";
      printf "%s B %18.8f  %18.8f  %18.8f  %8d\n", t1, b/1e8, u/1e8, (b-u)/1e8, o;
    }'
  else
    echo "$(ts) B balance-logger: wallet-rpc not ready yet"
  fi
  sleep "$INTERVAL"
done
