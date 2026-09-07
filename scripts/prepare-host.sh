#!/bin/sh
# Prepare private runtime directories without overwriting existing data.
set -eu

STACK="${STACK:-/mnt/sharedrive/salvium-private/staker}"
SOURCE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

# shellcheck source=scripts/acl-safety.sh
. "$SOURCE/scripts/acl-safety.sh"

[ "$(id -u)" -eq 0 ] || { echo "Run this script as root on the Docker host." >&2; exit 1; }

install -d -m 0750 -o root -g root "$STACK"
install -d -m 0750 -o root -g root "$STACK/config" "$STACK/wallets"
install -d -m 0700 -o root -g root "$STACK/secrets"
install -d -m 0700 -o 1000 -g 1000 \
  "$STACK/logs" "$STACK/wallets/public" "$STACK/wallets/miner"

for private_path in \
  "$STACK" "$STACK/config" "$STACK/wallets" "$STACK/secrets" \
  "$STACK/logs" "$STACK/wallets/public" "$STACK/wallets/miner"; do
  require_trivial_acl "$private_path" "private runtime path"
done

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

if [ "$(stat -c %u "$STACK/.env")" -ne 0 ] \
  || [ "$(stat -c %a "$STACK/.env")" != 600 ]; then
  echo "Existing .env must be root-owned with mode 0600." >&2
  exit 1
fi
if [ "$(stat -c %u "$STACK/config/wallets.yml")" -ne 0 ] \
  || [ "$(stat -c %a "$STACK/config/wallets.yml")" != 640 ]; then
  echo "Existing wallets.yml must be root-owned with mode 0640." >&2
  exit 1
fi
require_trivial_acl "$STACK/.env" "private environment file"
require_trivial_acl "$STACK/config/wallets.yml" "wallet configuration"

for name in public_rpc_password miner_rpc_password; do
  path="$STACK/secrets/$name"
  if [ "$(stat -c %u "$path")" -ne 1000 ] \
    || [ "$(stat -c %a "$path")" != 400 ]; then
    echo "$name must be UID 1000 with mode 0400." >&2
    exit 1
  fi
  require_trivial_acl "$path" "$name"
done

echo "Host directories are ready. Existing files were not overwritten."
echo "Next: place wallet files under $STACK/wallets and run set-wallet-passwords.sh."
