#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-.env.example}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"

command -v docker >/dev/null
command -v jq >/dev/null

config=$(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --format json)

check() {
  local description=$1 expression=$2
  if ! printf '%s' "$config" | jq -e "$expression" >/dev/null; then
    echo "FAIL: $description" >&2
    exit 1
  fi
  echo "PASS: $description"
}

check "no service publishes a host port" \
  '[.services[] | (.ports // []) | length] | all(. == 0)'
check "no service mounts the Docker socket" \
  '[.services[] | (.volumes // [])[]?] | all(.source != "/var/run/docker.sock")'
check "all services run non-root with read-only root filesystems" \
  '[.services[]] | all(.user == "1000:1000" and .read_only == true)'
check "all services drop capabilities and block privilege escalation" \
  '[.services[]] | all((.cap_drop | index("ALL") != null) and ([.security_opt[] | startswith("no-new-privileges")] | any))'
check "all services have PID, memory, and CPU limits" \
  '[.services[]] | all(.pids_limit > 0 and .mem_limit > 0 and .cpus > 0)'
check "all services have health checks" \
  '[.services[]] | all(.healthcheck.test | length > 0)'
check "all services use an init process and bounded Docker logs" \
  '[.services[]] | all(.init == true and .logging.driver == "json-file" and .logging.options["max-size"] == "10m")'
check "privileged node RPC network is externally managed" \
  '.networks.privileged_rpc.external == true'
check "only wallet RPC services join privileged node RPC" \
  '([.services | to_entries[] | select(.value.networks | has("privileged_rpc")) | .key] | sort) == ["wallet-rpc-miner", "wallet-rpc-public"]'
check "orchestrator is isolated from privileged node RPC" \
  '(.services.orchestrator.networks | has("privileged_rpc")) == false'
check "all secret-file mounts are read-only" \
  '[.services[] | (.volumes // [])[]? | select(.target | startswith("/run/secrets/"))] | all(.read_only == true)'
check "public defaults disable both financial actions" \
  '.services.orchestrator.environment.ENABLE_CONSOLIDATION == "false" and .services.orchestrator.environment.ENABLE_STAKING == "false"'
check "wallet health checks use the authenticated helper" \
  '[.services["wallet-rpc-public"], .services["wallet-rpc-miner"]] | all(.healthcheck.test == ["CMD", "/usr/local/bin/walletrpc-healthcheck.sh"])'

grep -Fq -- '--read-only' stake-executor.sh
grep -Fq -- '--cap-drop ALL' stake-executor.sh
grep -Fq -- '--security-opt no-new-privileges:true' stake-executor.sh
grep -Fq -- '--pids-limit 128' stake-executor.sh
if grep -Fq '/var/run/docker.sock' docker-compose.yml; then
  echo "FAIL: Compose must not mention the Docker socket" >&2
  exit 1
fi
echo "PASS: one-shot executor container is constrained and no socket is mounted"

echo "All hardening policy checks passed."
