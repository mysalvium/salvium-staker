# Backup and recovery

## What the backup contains

`scripts/backup.sh` includes the Compose file, private `.env`, wallet
configuration, wallet databases/keys, and all secret files. It deliberately
excludes ordinary logs and image layers.

The script stops the orchestrator and both wallet-RPC services before archiving
so the wallet files are consistent, then restarts every service that had been
running. It verifies the compressed archive before publishing it and writes a
SHA-256 sidecar.

## Create and verify

```sh
cd /mnt/sharedrive/apps/salvium/staker-repo
./scripts/backup.sh
./scripts/verify-backup.sh /mnt/sharedrive/backups/salvium-staker/FILE.tar.zst
```

The archive and checksum are root-only (`0600`). They are not encrypted. Store
another copy on encrypted/offline media, and keep independent offline records of
both wallet seeds. Test verification regularly; an untested backup is only a
hope.

## Safe restore drill

Do not extract a backup over the live stack as a test.

1. Copy the archive and checksum to a protected recovery system.
2. Run `verify-backup.sh`.
3. Create a new empty root-only directory on a non-production system.
4. List the archive and confirm it contains only expected relative paths.
5. Extract into that empty directory.
6. Confirm both `.keys` files, wallet caches, four password files,
   `config/wallets.yml`, `.env`, and the Compose file are present.
7. Keep the restored copy offline, or start it only against an isolated test
   environment in observe mode.

Before a real recovery, verify on-chain wallet state and ensure the original
wallet-RPC processes are stopped. Never run two writable instances of the same
wallet simultaneously.

## Scheduling on TrueNAS

Create a root scheduled task for a quiet period, for example once per week:

```text
/mnt/sharedrive/apps/salvium/staker-repo/scripts/backup.sh
```

Monitor task failures and free space. Retention is intentionally not automatic;
deleting wallet backups should be a deliberate storage-policy decision.
