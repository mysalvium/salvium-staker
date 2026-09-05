#!/bin/sh
# salvium-wallet-rpc launcher.
#
# The WALLET password is passed via --password-file (never on the command line).
# The RPC login is assembled from a mounted secret at runtime, so it stays out
# of docker-compose.yml and `docker inspect`.
set -eu
umask 077

: "${WALLET_FILE:?WALLET_FILE env is required}"
: "${DAEMON_ADDRESS:?DAEMON_ADDRESS env is required}"
case "$WALLET_FILE" in
  ''|*/*|.|..) echo "WALLET_FILE must be a filename, not a path" >&2; exit 1 ;;
esac
RPC_USER="${RPC_USER:-sal_rpc}"
RPC_PORT="${RPC_PORT:-18082}"
LOG_LVL="${LOG_LEVEL:-1}"

[ -f /run/secrets/wallet_password ] && [ ! -L /run/secrets/wallet_password ] || {
  echo "wallet password secret is missing or unsafe" >&2
  exit 1
}
[ -f /run/secrets/rpc_password ] && [ ! -L /run/secrets/rpc_password ] || {
  echo "RPC password secret is missing or unsafe" >&2
  exit 1
}
RPC_PASS="$(tr -d '\r\n' < /run/secrets/rpc_password)"
[ -n "$RPC_PASS" ] || { echo "RPC password secret is empty" >&2; exit 1; }

# /wallet is a writable bind mount; wallet-rpc needs a place for its log + cache.
[ -f "/wallet/${WALLET_FILE}" ] && [ ! -L "/wallet/${WALLET_FILE}" ] || {
  echo "wallet cache file is missing or unsafe" >&2
  exit 1
}
[ -f "/wallet/${WALLET_FILE}.keys" ] && [ ! -L "/wallet/${WALLET_FILE}.keys" ] || {
  echo "wallet keys file is missing or unsafe" >&2
  exit 1
}
if [ -e /wallet/logs ] && { [ -L /wallet/logs ] || [ ! -d /wallet/logs ]; }; then
  echo "wallet log path is unsafe" >&2
  exit 1
fi
mkdir -p /wallet/logs
chmod 0700 /wallet/logs

RPC_PASSWORD_FILE=/run/secrets/rpc_password
export RPC_PASSWORD_FILE
/usr/local/bin/balance-logger.sh &
exec salvium-wallet-rpc \
  --wallet-file="/wallet/${WALLET_FILE}" \
  --password-file=/run/secrets/wallet_password \
  --rpc-bind-ip=0.0.0.0 \
  --rpc-bind-port="${RPC_PORT}" \
  --confirm-external-bind \
  --rpc-login="${RPC_USER}:${RPC_PASS}" \
  --daemon-address="${DAEMON_ADDRESS}" \
  --trusted-daemon \
  --non-interactive \
  --log-file="/wallet/logs/wallet-rpc.log" \
  --log-level="${LOG_LVL}"
