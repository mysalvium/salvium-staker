#!/bin/sh
# Securely create password files that match the two existing wallet files.
set -eu

STACK="${STACK:-/mnt/sharedrive/salvium-private/staker}"
[ -t 0 ] || { echo "Run this script from an interactive terminal." >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Run this script as root on the Docker host." >&2; exit 1; }

set_password() {
  label="$1"
  destination="$2"
  printf 'Enter the password for %s: ' "$label" >&2
  stty -echo
  IFS= read -r first
  stty echo
  printf '\nEnter it again: ' >&2
  stty -echo
  IFS= read -r second
  stty echo
  printf '\n' >&2
  [ -n "$first" ] || { echo "Password cannot be empty." >&2; exit 1; }
  [ "$first" = "$second" ] || { echo "Passwords did not match." >&2; exit 1; }
  umask 077
  printf '%s' "$first" > "$destination"
  chown 1000:1000 "$destination"
  chmod 0400 "$destination"
  first=
  second=
}

trap 'stty echo 2>/dev/null || true' EXIT INT TERM HUP
install -d -m 0700 -o root -g root "$STACK/secrets"
set_password "Public Salvium Wallet" "$STACK/secrets/public_wallet_password"
set_password "Salvium Miner Wallet" "$STACK/secrets/miner_wallet_password"
echo "Wallet password files were created with private permissions."
