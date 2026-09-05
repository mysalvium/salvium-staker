#!/bin/sh
# Show service health and recent controller activity without printing credentials.
set -eu

echo "Salvium staker containers"
docker ps --filter name=salvium-staker \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
echo
echo "Recent orchestrator activity (transaction hashes redacted)"
docker logs --tail 80 salvium-staker-orchestrator 2>&1 \
  | sed -E 's/[0-9a-f]{64}/[transaction-redacted]/g'
echo
if /mnt/sharedrive/apps/salvium/data/operations/host/salvium-stake-executor --check >/dev/null 2>&1; then
  echo "Executor trust check: PASS"
else
  echo "Executor trust check: FAIL"
  exit 1
fi
