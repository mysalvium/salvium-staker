#!/bin/sh
# Build immutable, checksum-verified local images for the Compose stack.
set -eu

DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$DIR"

SALVIUM_VERSION="${SALVIUM_VERSION:-v1.1.3c}"
STACK_RELEASE="${STACK_RELEASE:-2.2.0}"
export DOCKER_BUILDKIT=1

printf '%s\n' ">> verifying the published Salvium archive checksum"
sh ./scripts/verify-downloads.sh

printf '%s\n' ">> building wallet-rpc ${SALVIUM_VERSION}-hardened1"
docker build --pull \
  --build-arg "SALVIUM_VERSION=$SALVIUM_VERSION" \
  --tag "salvium-staker/wallet-rpc:${SALVIUM_VERSION}-hardened1" \
  --file Dockerfile.walletrpc .

printf '%s\n' ">> building orchestrator $STACK_RELEASE"
docker build --pull \
  --tag "salvium-staker/orchestrator:$STACK_RELEASE" \
  orchestrator

docker image inspect \
  "salvium-staker/wallet-rpc:${SALVIUM_VERSION}-hardened1" \
  "salvium-staker/orchestrator:$STACK_RELEASE" \
  --format '{{.RepoTags}}  {{.Id}}'
