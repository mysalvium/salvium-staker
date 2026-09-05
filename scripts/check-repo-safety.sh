#!/usr/bin/env bash
# Fast fail-closed checks for files and credential formats that must not be Git-tracked.
set -euo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$repo"

for forbidden in .env .portainer-token config/wallets.yml; do
  if git ls-files --error-unmatch "$forbidden" >/dev/null 2>&1; then
    echo "FAIL: sensitive local file is tracked: $forbidden" >&2
    exit 1
  fi
done

if git ls-files | grep -Eq '(^|/)(secrets|wallets|logs|backups)/'; then
  echo "FAIL: a runtime secret, wallet, log, or backup directory is tracked" >&2
  exit 1
fi

if git grep -nEI \
  '(-----BEGIN (OPENSSH|RSA|EC|DSA|PGP) PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{40,}|gh[pousr]_[A-Za-z0-9]{36,})' \
  -- . ':(exclude)scripts/check-repo-safety.sh'; then
  echo "FAIL: a private-key or access-token pattern was found" >&2
  exit 1
fi

for ignored in .env .portainer-token secrets/example wallets/example logs/example; do
  git check-ignore -q "$ignored" || {
    echo "FAIL: ignore policy does not cover $ignored" >&2
    exit 1
  }
done

echo "PASS: repository safety checks"
