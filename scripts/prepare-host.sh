#!/bin/sh
# Prepare private runtime directories without overwriting existing data.
set -eu

STACK="${STACK:-/mnt/sharedrive/apps/salvium/staker}"
SOURCE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

[ "$(id -u)" -eq 0 ] || { echo "Run this script as root on the Docker host." >&2; exit 1; }

install -d -m 0750 -o root -g root "$STACK"
install -d -m 0750 -o root -g root "$STACK/config" "$STACK/wallets"
install -d -m 0700 -o root -g root "$STACK/secrets"
install -d -m 0700 -o 1000 -g 1000 \
  "$STACK/logs" "$STACK/wallets/public" "$STACK/wallets/miner"

if [ ! -f "$STACK/config/wallets.yml" ]; then
  install -m 0640 -o root -g 1000 "$SOURCE/config/wallets.example.yml" \
    "$STACK/config/wallets.yml"
fi
if [ ! -f "$STACK/.env" ]; then
  install -m 0600 -o root -g root "$SOURCE/.env.example" "$STACK/.env"
fi

for name in public_rpc_password miner_rpc_password; do
  path="$STACK/secrets/$name"
  if [ ! -e "$path" ]; then
    umask 077
    openssl rand -hex 32 > "$path"
    chown 1000:1000 "$path"
    chmod 0400 "$path"
  fi
done

echo "Host directories are ready. Existing files were not overwritten."
echo "Next: place wallet files under $STACK/wallets and run set-wallet-passwords.sh."
