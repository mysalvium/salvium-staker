#!/bin/sh
# Root-owned, host-side bridge for Salvium CLI staking.
#
# Install this file with scripts/install-executor.sh. Do not point a root cron
# job at a writable Git checkout. The orchestrator may request only the two
# wallets listed at the bottom of this file; every amount and path is validated
# again here before the wallet CLI is allowed to run.

set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

EXECUTOR_CONFIG="${EXECUTOR_CONFIG:-/mnt/sharedrive/apps/salvium/data/operations/host/salvium-staker-executor.conf}"
if [ -e "$EXECUTOR_CONFIG" ]; then
    [ -f "$EXECUTOR_CONFIG" ] && [ ! -L "$EXECUTOR_CONFIG" ] || {
        echo "executor config is not a safe regular file" >&2
        exit 1
    }
    config_owner=$(stat -c %u "$EXECUTOR_CONFIG")
    config_mode=$(stat -c %a "$EXECUTOR_CONFIG")
    [ "$config_owner" -eq 0 ] && [ $((0$config_mode & 0022)) -eq 0 ] || {
        echo "executor config must be root-owned and not group/world writable" >&2
        exit 1
    }
    # The installer makes this file root-owned and non-writable by other users.
    # shellcheck disable=SC1090
    . "$EXECUTOR_CONFIG"
fi

STACK="${STACK:-/mnt/sharedrive/apps/salvium/staker}"
IMAGE="${IMAGE:-salvium-staker/wallet-rpc:v1.1.3c-hardened1}"
NETWORK="${NETWORK:-salvium_privileged_rpc}"
DAEMON="${DAEMON:-salviumd:19081}"
CLI_TIMEOUT="${CLI_TIMEOUT:-900}"
MAX_REQUEST_AGE="${MAX_REQUEST_AGE:-3600}"
MIN_SECONDS_BETWEEN_ATTEMPTS="${MIN_SECONDS_BETWEEN_ATTEMPTS:-1200}"
EXPECTED_REQUEST_UID="${EXPECTED_REQUEST_UID:-1000}"
EXPECTED_REQUEST_GID="${EXPECTED_REQUEST_GID:-1000}"
STATE_DIR="${STATE_DIR:-/mnt/sharedrive/apps/salvium/data/operations/staker-state}"
EXEC_LOG="$STATE_DIR/stake-executor.log"
LOCKDIR="$STATE_DIR/executor.lock"
STOPPED_CONTAINER=""

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$EXEC_LOG"
}

fail_closed() {
    log "SECURITY: $*"
    exit 1
}

check_root_trust() {
    [ "$(id -u)" -eq 0 ] || fail_closed "executor must run as root"
    self_path=$(readlink -f "$0")
    for trusted_dir in "$(dirname "$self_path")" "$(dirname "$EXECUTOR_CONFIG")" "$STATE_DIR"; do
        [ ! -L "$trusted_dir" ] || fail_closed "trusted directory is a symlink: $trusted_dir"
        [ "$(stat -c %u "$trusted_dir")" -eq 0 ] || fail_closed "trusted directory is not root-owned: $trusted_dir"
        trusted_mode=$(stat -c %a "$trusted_dir")
        [ $((0$trusted_mode & 0022)) -eq 0 ] || fail_closed "trusted directory is group/world writable: $trusted_dir"
    done
    [ "$(stat -c %u "$self_path")" -eq 0 ] || fail_closed "executor is not owned by root"
    self_mode=$(stat -c %a "$self_path")
    [ $((0$self_mode & 0022)) -eq 0 ] || fail_closed "executor is group/world writable"
    if [ -e "$EXECUTOR_CONFIG" ]; then
        [ ! -L "$EXECUTOR_CONFIG" ] || fail_closed "executor config is a symlink"
        [ "$(stat -c %u "$EXECUTOR_CONFIG")" -eq 0 ] || fail_closed "executor config is not root-owned"
        config_mode=$(stat -c %a "$EXECUTOR_CONFIG")
        [ $((0$config_mode & 0022)) -eq 0 ] || fail_closed "executor config is group/world writable"
    fi
}

restart_wallet() {
    [ -n "$STOPPED_CONTAINER" ] || return 0
    container="$STOPPED_CONTAINER"
    if docker start "$container" >> "$EXEC_LOG" 2>&1; then
        log "$container restarted"
    else
        log "CRITICAL: failed to restart $container"
        return 1
    fi
    STOPPED_CONTAINER=""
    return 0
}

cleanup() {
    restart_wallet || true
    rmdir "$LOCKDIR" 2>/dev/null || true
}

write_result() {
    status="$1"
    wallet="$2"
    amount="$3"
    detail="$4"
    tx_hash="${5:-}"
    result_path="$STACK/logs/stake-result-$wallet.json"
    tmp_path="$result_path.tmp.$$"

    python3 - "$tmp_path" "$status" "$wallet" "$amount" "$detail" "$tx_hash" \
        "$EXPECTED_REQUEST_UID" "$EXPECTED_REQUEST_GID" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, status, wallet, amount, detail, tx_hash, owner_uid, owner_gid = sys.argv[1:]
record = {
    "status": status,
    "wallet": wallet,
    "amount_sal": amount,
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
if detail:
    record["detail"] = detail
if tx_hash:
    record["tx_hash"] = tx_hash
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(record, handle, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.chown(path, int(owner_uid), int(owner_gid))
PY
    chmod 0600 "$tmp_path"
    chown "$EXPECTED_REQUEST_UID:$EXPECTED_REQUEST_GID" "$tmp_path"
    mv -f "$tmp_path" "$result_path"
}

validated_amount() {
    request_path="$1"
    expected_wallet="$2"
    minimum="$3"
    maximum="$4"
    python3 - "$request_path" "$expected_wallet" "$minimum" "$maximum" \
        "$EXPECTED_REQUEST_UID" <<'PY'
import json
import os
import stat
import sys
from decimal import Decimal, InvalidOperation

path, expected_wallet, minimum, maximum, expected_uid = sys.argv[1:]
try:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError("request is not a regular file")
    if metadata.st_uid != int(expected_uid) or stat.S_IMODE(metadata.st_mode) != 0o600:
        raise ValueError("request ownership or mode is invalid")
    with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
        request = json.load(handle)
    if not isinstance(request, dict) or request.get("wallet") != expected_wallet:
        raise ValueError("wallet field mismatch")
    raw = str(request["amount_sal"])
    amount = Decimal(raw)
    if not amount.is_finite() or amount < Decimal(minimum) or amount > Decimal(maximum):
        raise ValueError("amount outside executor limits")
    if amount.as_tuple().exponent < -8:
        raise ValueError("amount has more than 8 decimal places")
    print(format(amount, "f"))
except (KeyError, ValueError, InvalidOperation, json.JSONDecodeError, OSError):
    sys.exit(2)
PY
}

wallet_paths_are_safe() {
    wallet_dir="$1"
    wallet_file="$2"
    [ -d "$wallet_dir" ] && [ ! -L "$wallet_dir" ] || return 1
    [ "$(stat -c %u "$wallet_dir")" -eq "$EXPECTED_REQUEST_UID" ] || return 1
    for path in "$wallet_dir/$wallet_file" "$wallet_dir/$wallet_file.keys"; do
        [ -f "$path" ] && [ ! -L "$path" ] || return 1
        [ "$(stat -c %u "$path")" -eq "$EXPECTED_REQUEST_UID" ] || return 1
        path_mode=$(stat -c %a "$path")
        [ $((0$path_mode & 0077)) -eq 0 ] || return 1
    done
    [ -d "$wallet_dir/logs" ] && [ ! -L "$wallet_dir/logs" ] || return 1
    [ "$(stat -c %u "$wallet_dir/logs")" -eq "$EXPECTED_REQUEST_UID" ] || return 1
    cli_log="$wallet_dir/logs/cli-stake.log"
    [ ! -e "$cli_log" ] || { [ -f "$cli_log" ] && [ ! -L "$cli_log" ]; } || return 1
    return 0
}

wait_for_wallet() {
    container="$1"
    remaining=180
    while [ "$remaining" -gt 0 ]; do
        running=$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)
        health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)
        if [ "$running" = "true" ] && { [ "$health" = "healthy" ] || [ "$health" = "none" ]; }; then
            return 0
        fi
        sleep 5
        remaining=$((remaining - 5))
    done
    return 1
}

handle_wallet() {
    name="$1"
    container="$2"
    wallet_file="$3"
    secret_name="$4"
    minimum="$5"
    maximum="$6"

    request="$STACK/logs/stake-request-$name.json"
    result="$STACK/logs/stake-result-$name.json"
    output="$STATE_DIR/stake-output-$name.log"
    wallet_dir="$STACK/wallets/$name"
    secret_file="$STACK/secrets/$secret_name"
    attempt_file="$STATE_DIR/last-attempt-$name"

    [ -e "$request" ] || return 0
    if [ -L "$request" ] || [ ! -f "$request" ]; then
        log "$name: rejected unsafe request path"
        return 0
    fi
    [ ! -L "$result" ] || { log "$name: rejected symlinked result path"; return 0; }
    if [ -f "$result" ] && [ "$result" -nt "$request" ]; then
        return 0
    fi

    request_uid=$(stat -c %u "$request")
    request_mode=$(stat -c %a "$request")
    if [ "$request_uid" -ne "$EXPECTED_REQUEST_UID" ] || [ "$request_mode" != "600" ]; then
        log "$name: rejected request with uid=$request_uid mode=$request_mode"
        return 0
    fi
    now=$(date +%s)
    request_age=$((now - $(stat -c %Y "$request")))
    if [ "$request_age" -lt 0 ] || [ "$request_age" -gt "$MAX_REQUEST_AGE" ]; then
        write_result "failed" "$name" "0" "request is stale or has an invalid timestamp"
        log "$name: rejected stale request"
        return 0
    fi
    if [ -f "$attempt_file" ]; then
        last_attempt=$(cat "$attempt_file" 2>/dev/null || printf '0')
        case "$last_attempt" in *[!0-9]*|'') last_attempt=0 ;; esac
        if [ $((now - last_attempt)) -lt "$MIN_SECONDS_BETWEEN_ATTEMPTS" ]; then
            log "$name: request held by executor rate limit"
            return 0
        fi
    fi

    amount=$(validated_amount "$request" "$name" "$minimum" "$maximum" 2>/dev/null || true)
    if [ -z "$amount" ]; then
        write_result "failed" "$name" "0" "invalid amount or wallet name in request"
        log "$name: rejected invalid request content"
        return 0
    fi

    wallet_paths_are_safe "$wallet_dir" "$wallet_file" || {
        write_result "failed" "$name" "$amount" "wallet directory is missing or unsafe"
        return 0
    }
    [ -f "$secret_file" ] && [ ! -L "$secret_file" ] || {
        write_result "failed" "$name" "$amount" "wallet password file is missing or unsafe"
        return 0
    }
    secret_mode=$(stat -c %a "$secret_file")
    secret_owner=$(stat -c %u "$secret_file")
    [ "$secret_owner" -eq "$EXPECTED_REQUEST_UID" ] && [ $((0$secret_mode & 0077)) -eq 0 ] || {
        write_result "failed" "$name" "$amount" "wallet password file permissions are too broad"
        log "$name: rejected secret file owner=$secret_owner mode=$secret_mode"
        return 0
    }

    actual_image=$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null || true)
    [ "$actual_image" = "$IMAGE" ] || {
        write_result "failed" "$name" "$amount" "wallet container image does not match executor image"
        log "$name: image mismatch; expected $IMAGE"
        return 0
    }
    running=$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)
    [ "$running" = "true" ] || {
        write_result "failed" "$name" "$amount" "wallet RPC container is not running"
        return 0
    }

    printf '%s\n' "$now" > "$attempt_file"
    chmod 0600 "$attempt_file"
    log "$name: validated stake request for $amount SAL; stopping $container"
    if ! docker stop --timeout 60 "$container" >> "$EXEC_LOG" 2>&1; then
        write_result "failed" "$name" "$amount" "could not stop wallet RPC container"
        return 0
    fi
    STOPPED_CONTAINER="$container"

    # Validate writable wallet paths again after stopping the only expected
    # process that can change them, closing the pre-stop race window.
    if ! wallet_paths_are_safe "$wallet_dir" "$wallet_file"; then
        write_result "failed" "$name" "$amount" "wallet paths changed or became unsafe during stop"
        restart_wallet || true
        return 0
    fi

    set +e
    { tr -d '\r\n' < "$secret_file"; printf '\ny\n'; } | timeout "$CLI_TIMEOUT" docker run --rm -i \
        --name "salvium-staker-cli-$name-$$" \
        --network "$NETWORK" \
        --user 1000:1000 \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges:true \
        --pids-limit 128 \
        --memory 1g \
        --cpus 2.0 \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
        --env HOME=/tmp \
        --volume "$wallet_dir:/wallet:rw" \
        --volume "$secret_file:/pw:ro" \
        --entrypoint /usr/local/bin/salvium-wallet-cli \
        "$IMAGE" \
        --wallet-file "/wallet/$wallet_file" \
        --password-file /pw \
        --daemon-address "$DAEMON" \
        --trusted-daemon \
        --log-file /wallet/logs/cli-stake.log \
        stake "$amount" > "$output" 2>&1
    cli_rc=$?
    set -e
    chmod 0600 "$output"

    if ! restart_wallet || ! wait_for_wallet "$container"; then
        log "CRITICAL: $container did not return healthy after the CLI attempt"
    fi

    tx_hash=$(grep -oE 'successfully submitted, transaction <[0-9a-f]{64}>' "$output" 2>/dev/null \
        | head -1 | grep -oE '[0-9a-f]{64}' || true)
    if [ -n "$tx_hash" ]; then
        write_result "success" "$name" "$amount" "" "$tx_hash"
        log "$name: stake submitted successfully (transaction hash stored in private result file)"
    else
        write_result "ambiguous" "$name" "$amount" "no confirmed transaction hash in CLI output (rc=$cli_rc); inspect the root-only executor output log before retrying"
        log "$name: stake outcome ambiguous (cli rc=$cli_rc); automatic retry delayed"
    fi
}

mkdir -p "$STATE_DIR"
mkdir -p "$STACK/logs"
check_root_trust
if [ "${1:-}" = "--check" ]; then
    echo "Executor ownership and configuration checks passed."
    exit 0
fi
mkdir "$LOCKDIR" 2>/dev/null || exit 0
trap cleanup EXIT INT TERM HUP

handle_wallet "miner"  "salvium-staker-wallet-rpc-miner"  "${MINER_WALLET_FILE:-Salvium Miner Wallet}"  "miner_wallet_password"  "${MINER_MIN_STAKE_SAL:-1}"  "${MINER_MAX_STAKE_SAL:-10000000}"
handle_wallet "public" "salvium-staker-wallet-rpc-public" "${PUBLIC_WALLET_FILE:-Public Salvium Wallet}" "public_wallet_password" "${PUBLIC_MIN_STAKE_SAL:-1}" "${PUBLIC_MAX_STAKE_SAL:-10000000}"

exit 0
