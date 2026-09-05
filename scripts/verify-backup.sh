#!/bin/sh
# Verify a backup checksum and reject unsafe archive paths without extracting it.
set -eu

[ "$#" -eq 1 ] || { echo "Usage: $0 /path/to/salvium-staker-....tar.zst" >&2; exit 2; }
archive="$1"
if [ ! -f "$archive" ] || [ -L "$archive" ]; then
  echo "Backup is missing or unsafe." >&2
  exit 1
fi
[ -f "$archive.sha256" ] || { echo "Missing checksum sidecar: $archive.sha256" >&2; exit 1; }

(cd "$(dirname "$archive")" && sha256sum -c "$(basename "$archive").sha256")
tar --zstd -tf "$archive" | awk '
  /^\// || /(^|\/)\.\.($|\/)/ { bad=1 }
  END { exit bad }
'
tar --zstd -tf "$archive" >/dev/null
echo "Backup checksum, compression, and paths are valid. No files were restored."
