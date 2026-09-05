#!/bin/sh
# Atomically change the two financial-action flags in the private .env file.
set -eu

STACK="${STACK:-/mnt/sharedrive/apps/salvium/staker}"
ENV_FILE="${ENV_FILE:-$STACK/.env}"
mode="${1:-}"

case "$mode" in
  observe) consolidation=false; staking=false ;;
  consolidate) consolidation=true; staking=false ;;
  live)
    [ -t 0 ] || { echo "Live mode requires an interactive confirmation." >&2; exit 1; }
    echo "Live mode can broadcast consolidation and stake transactions and pay network fees."
    printf 'Type ENABLE LIVE STAKING to continue: '
    IFS= read -r confirmation
    [ "$confirmation" = "ENABLE LIVE STAKING" ] || { echo "Cancelled."; exit 1; }
    consolidation=true
    staking=true
    ;;
  *) echo "Usage: $0 observe|consolidate|live" >&2; exit 2 ;;
esac

[ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] || { echo "Unsafe or missing .env: $ENV_FILE" >&2; exit 1; }
tmp=$(mktemp "${ENV_FILE}.XXXXXX")
trap 'rm -f "$tmp"' EXIT INT TERM HUP
awk -v consolidation="$consolidation" -v staking="$staking" '
  BEGIN { saw_c=0; saw_s=0 }
  /^ENABLE_CONSOLIDATION=/ { print "ENABLE_CONSOLIDATION=" consolidation; saw_c=1; next }
  /^ENABLE_STAKING=/ { print "ENABLE_STAKING=" staking; saw_s=1; next }
  { print }
  END {
    if (!saw_c) print "ENABLE_CONSOLIDATION=" consolidation
    if (!saw_s) print "ENABLE_STAKING=" staking
  }
' "$ENV_FILE" > "$tmp"
chmod --reference="$ENV_FILE" "$tmp"
chown --reference="$ENV_FILE" "$tmp"
mv -f "$tmp" "$ENV_FILE"
trap - EXIT INT TERM HUP
echo "Mode set to $mode in $ENV_FILE. Redeploy Compose to apply it."
