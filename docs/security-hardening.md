# Security hardening

## Protections implemented

- No host ports and no router exposure
- Internal network isolation and a separate privileged-node-RPC network
- Digest authentication for both wallet-RPC services
- One secret file per password; no password values in Compose or `.env`
- No Docker socket in any container
- Root-owned, fixed-command host executor instead of general Docker access
- Non-root containers, read-only root filesystems, all capabilities dropped,
  and `no-new-privileges`
- CPU, memory, PID, temporary-filesystem, shutdown, and log-size limits
- Authenticated functional wallet health checks and an orchestrator heartbeat
- Safe observe defaults with staking and consolidation independently controlled
- Atomic private state/request/result files and strict configuration validation
- Amount, request-age, ownership, mode, symlink, image, and rate-limit checks
- Fail-closed one-shot execution with guaranteed wallet restart handling
- Immutable base-image digests, exact Python versions, and verified official
  Salvium release checksums
- Source/config/secret/image scans and SPDX SBOM output
- Consistent, checksum-verified, root-only backups

## Host permissions

The source checkout is not a root trust boundary. A root scheduled task must run
only `/mnt/sharedrive/apps/salvium/data/operations/host/salvium-stake-executor`.
That file, its adjacent configuration, and the dedicated operations/state
directories must be root-owned and not group/world writable. The executor
refuses unsafe file ownership or modes.

The private runtime root should be root-owned. Only these data directories need
UID 1000 write access:

```text
logs  wallets/public  wallets/miner
```

The `config`, `secrets`, and `wallets` parent directories stay root-owned.
Secret files should be UID/GID 1000 with mode `0400`; wallet files should be
`0600`. `config/wallets.yml` should be root:1000 and `0640`. Writable data
directories should be `0700`.

## Remaining risks

Hardening reduces risk; it does not make unattended hot-wallet staking safe
against every failure.

- Root or Docker-administrator compromise can read or replace wallet data.
- Each wallet-RPC process must receive its RPC password through the upstream
  command-line interface; a Docker administrator can inspect that running
  process. The service is therefore isolated and never published.
- The official CLI has an interactive confirmation flow. Unexpected prompts can
  make the outcome unclear. The executor records an `ambiguous` result, delays
  retries for an hour, and requires private-log review rather than immediately
  paying another fee.
- Consolidation and staking pay network fees. Incorrect thresholds can cause
  unnecessary fee churn even though destinations are restricted to the wallet
  itself.
- Release checksums are published in the same upstream release channel as the
  archives. Independent signed provenance would be stronger.
- Local backup archives contain wallet and password material and are not
  encrypted by the included script.
- A clean vulnerability scan and SBOM are useful evidence, not proof of absence
  of vulnerabilities.

Keep seed phrases offline, protect the Docker host, use encrypted off-host
backups, review logs, and test changes in observe mode.
