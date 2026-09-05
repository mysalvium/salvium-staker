# Operations

## Modes

| Mode | Consolidation | Staking | Intended use |
|---|---:|---:|---|
| `observe` | No | No | First start and validation; reads only |
| `consolidate` | Yes | No | Controlled output cleanup test; pays fees |
| `live` | Yes | Yes | Normal automatic operation; pays fees |

Change mode with:

```sh
STACK=/mnt/sharedrive/apps/salvium/staker ./scripts/set-mode.sh observe
STACK=/mnt/sharedrive/apps/salvium/staker ./scripts/set-mode.sh consolidate
STACK=/mnt/sharedrive/apps/salvium/staker ./scripts/set-mode.sh live
```

Redeploy after a change:

```sh
docker compose --env-file /mnt/sharedrive/apps/salvium/staker/.env up -d
```

`live` requires an interactive typed confirmation. The old `DRY_RUN` setting is
accepted only for migration compatibility; new installs should use the two
explicit flags.

## Understanding the wallet rules

- `min_stake_sal`: do nothing when the safe stakeable amount is lower.
- `stake_fee_reserve_sal`: amount left unlocked so the CLI can pay its fee.
- `keep_liquid_sal`: additional amount deliberately left spendable.
- `consolidate_when_outputs_over`: output count that triggers a self-sweep.
- `stake_when_single_output_over_sal`: wait until one unlocked output reaches
  this value. Zero disables this gate.

Salvium consolidation can create paired outputs. Choose the output-count and
single-output gate together; a gate that is too high can cause repeated
consolidations without a stake. Change one value at a time and observe a full
cycle before going live.

## Routine checks

```sh
./scripts/status.sh
docker compose --env-file /mnt/sharedrive/apps/salvium/staker/.env ps
/mnt/sharedrive/apps/salvium/data/operations/host/salvium-stake-executor --check
```

Expected state:

- both wallet-RPC containers are `healthy`;
- orchestrator is `healthy` after its first full cycle;
- no staker service shows a published host port;
- the executor trust check passes;
- a request is consumed by the scheduled task within five minutes;
- wallet-RPC returns healthy after the brief CLI staking window.

Logs and transaction metadata are private:

```text
/mnt/sharedrive/apps/salvium/staker/logs/staker.log
/mnt/sharedrive/apps/salvium/staker/logs/audit.jsonl
/mnt/sharedrive/apps/salvium/data/operations/staker-state/stake-executor.log
/mnt/sharedrive/apps/salvium/data/operations/staker-state/stake-output-*.log
```

Do not paste these files publicly without redacting balances, addresses, hashes,
and wallet names.

## Common conditions

**Many outputs and a high unlocked balance:** this is normally the condition
that should trigger consolidation. Confirm `ENABLE_CONSOLIDATION=true`, check
the cooldown, and verify no outgoing transaction is pending.

**A stake request remains pending:** confirm the TrueNAS scheduled task is
enabled, runs as root every five minutes, and uses the installed executor path.
Run the executor `--check` command. Do not delete a request until you establish
whether the CLI may already have submitted a transaction.

**Ambiguous result:** inspect the private CLI output and wallet transaction
history. The one-hour cooldown is deliberate. Confirm on-chain/wallet status
before deleting files or forcing another attempt.

**Wallet is unhealthy after a stake:** check the wallet password file, ownership
of the wallet files, node health, and wallet log. The executor always attempts a
restart, but it cannot repair an invalid password or corrupt cache.

**Orchestrator is unhealthy:** inspect `logs/health.json` and the orchestrator
log. A degraded heartbeat means at least one wallet RPC failed during the last
cycle.

## Updating and rollback

1. Keep live mode running while reviewing the update; do not edit in place.
2. Pull with `git pull --ff-only`.
3. Run the policy tests, builds, scan, and backup.
4. Record the old image IDs and Compose file checksum.
5. Redeploy and watch one full cycle.
6. If health or decisions are wrong, set observe mode, redeploy the previous
   Compose/images, and investigate before re-enabling actions.

Never automatically deploy an unreviewed Dependabot proposal to a wallet host.
