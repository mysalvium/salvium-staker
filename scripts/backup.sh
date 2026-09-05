#!/bin/sh
# Create a consistent root-only backup containing wallets and secrets.
set -eu

STACK="${STACK:-/mnt/sharedrive/apps/salvium/staker}"
DESTINATION="${DESTINATION:-/mnt/sharedrive/backups/salvium-staker}"
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
FINAL="$DESTINATION/salvium-staker-$STAMP.tar.zst"
TEMP="$FINAL.tmp"
STOPPED=""

[ "$(id -u)" -eq 0 ] || { echo "Run this script as root." >&2; exit 1; }
install -d -m 0700 -o root -g root "$DESTINATION"

restart_containers() {
  for container in $STOPPED; do
    docker start "$container" >/dev/null 2>&1 || true
  done
  rm -f "$TEMP"
}
trap restart_containers EXIT INT TERM HUP

for container in salvium-staker-orchestrator \
                 salvium-staker-wallet-rpc-public \
                 salvium-staker-wallet-rpc-miner; do
  if [ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)" = true ]; then
    docker stop --timeout 60 "$container" >/dev/null
    STOPPED="$container $STOPPED"
  fi
done

tar --zstd --numeric-owner -C "$STACK" -cf "$TEMP" \
  docker-compose.yml .env config wallets secrets
chmod 0600 "$TEMP"
tar --zstd -tf "$TEMP" >/dev/null
mv "$TEMP" "$FINAL"
sha256sum "$FINAL" > "$FINAL.sha256"
chmod 0600 "$FINAL" "$FINAL.sha256"

restart_containers
STOPPED=""
trap - EXIT INT TERM HUP
echo "Backup created: $FINAL"
echo "It contains wallet and password material. Keep it private and preferably encrypted off-host."
