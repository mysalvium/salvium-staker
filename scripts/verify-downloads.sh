#!/bin/sh
# Download official Salvium release archive(s) and verify published SHA-256.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION="${SALVIUM_VERSION:-v1.1.3c}"
CHECKSUMS="$ROOT/checksums/salvium-${VERSION}.sha256"
BASE_URL="https://github.com/salvium/salvium/releases/download/${VERSION}"
VERIFY_ALL=false
[ "${1:-}" = "--all" ] && VERIFY_ALL=true

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required" >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "unzip is required" >&2; exit 1; }
[ -f "$CHECKSUMS" ] || { echo "missing checksum file: $CHECKSUMS" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM HUP

if [ "$VERIFY_ALL" = true ]; then
  archives="x86_64 aarch64"
else
  case "$(uname -m)" in
    x86_64|amd64) archives=x86_64 ;;
    aarch64|arm64) archives=aarch64 ;;
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
fi

for arch in $archives; do
  file="salvium-${VERSION}-ubuntu22.04-linux-${arch}.zip"
  expected=$(awk -v file="$file" '$2 == file {print $1}' "$CHECKSUMS")
  [ -n "$expected" ] || { echo "no trusted checksum for $file" >&2; exit 1; }
  echo ">> downloading $file from the official salvium/salvium release"
  curl --fail --show-error --location --proto '=https' --tlsv1.2 \
    --retry 5 --retry-all-errors --output "$tmp/$file" "$BASE_URL/$file"
  printf '%s  %s\n' "$expected" "$tmp/$file" | sha256sum -c -
  unzip -tq "$tmp/$file" >/dev/null
done

echo ">> official download verification passed"
