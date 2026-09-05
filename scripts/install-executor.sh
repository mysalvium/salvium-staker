#!/bin/sh
# Install the narrow Docker-using executor behind a persistent root-owned boundary.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ "$(id -u)" -eq 0 ] || { echo "Run this script as root on the Docker host." >&2; exit 1; }

OPERATIONS_ROOT="${OPERATIONS_ROOT:-/mnt/sharedrive/apps/salvium/data/operations}"
INSTALL_PATH="$OPERATIONS_ROOT/host/salvium-stake-executor"
CONFIG_PATH="$OPERATIONS_ROOT/host/salvium-staker-executor.conf"
STATE_PATH="$OPERATIONS_ROOT/staker-state"

install -d -m 0700 -o root -g root "$OPERATIONS_ROOT" "$OPERATIONS_ROOT/host" "$STATE_PATH"
install -m 0750 -o root -g root "$ROOT/stake-executor.sh" \
  "$INSTALL_PATH"
if [ ! -f "$CONFIG_PATH" ]; then
  install -m 0600 -o root -g root "$ROOT/config/executor.conf.example" \
    "$CONFIG_PATH"
else
  chown root:root "$CONFIG_PATH"
  chmod 0600 "$CONFIG_PATH"
fi

"$INSTALL_PATH" --check
echo "Executor installed at $INSTALL_PATH"
echo "Use that exact path in the root scheduled task; never run the Git copy as root."
