# TrueNAS private-dataset migration

Use this procedure when an existing stack is stored below an SMB share or a
TrueNAS Apps dataset with inherited NFSv4 ACL entries. Do not make the executor
pass with only `chmod`: named ACL entries can remain effective and replacement
wallet cache files can inherit them again.

## 1. Contain and preserve

Disable the root stake-executor scheduled task and confirm no executor process
or lock is active. Leave any pending request/result files in place until their
status is understood.

Take a ZFS snapshot of the source dataset immediately before migration. A
snapshot is a rollback point for files and ACL metadata; it does not correct the
exposure and is not a substitute for an offline wallet backup.

## 2. Create the private dataset

Create a dedicated, non-shared Generic/POSIX dataset. The example layout is:

```text
/mnt/sharedrive/salvium-private/staker-repo
/mnt/sharedrive/salvium-private/staker
/mnt/sharedrive/salvium-private/operations
```

Set the dataset root to `root:root` mode `0700`. Confirm that no SMB or NFS share
covers the new path.

## 3. Copy a consistent wallet state

Stop the orchestrator first and then both wallet-RPC containers, allowing each
wallet its normal shutdown grace period. Copy—do not move—the runtime into the
new dataset without preserving the source NFSv4 ACL or extended attributes.
Keep the original source untouched until the migration is fully verified.

Normalize the new runtime to the ownership and modes in
`security-hardening.md`. In particular, cache and `.keys` files must be
UID/GID 1000 and mode `0600`; wallet/log directories must be `0700`.

Compare every source and destination wallet, key, password, configuration, and
environment file byte-for-byte before changing the deployment paths.

## 4. Switch the deployment

Update `STACK_DIR` in the private `.env`, install the executor below the new
operations root, and point the root scheduled task at that installed copy.
Redeploy Compose from the private checkout so every bind mount resolves below
the new dataset.

Keep `ENABLE_STAKING=false` and `ENABLE_CONSOLIDATION=false` for the first
health/read-only cycle.

## 5. Verify the boundary

Run:

```sh
/mnt/sharedrive/salvium-private/operations/host/salvium-stake-executor --check
stat -c '%n %u:%g %a' PRIVATE_PATHS...
getfacl -cp PRIVATE_PATHS...
nfs4xdr_getfacl PRIVATE_PATHS...  # should be unsupported on POSIX, or trivial
```

Use `runuser` with the TrueNAS `apps` account and at least one unrelated local
user to verify that wallet keys, passwords, executor configuration, and the
installed executor are neither readable nor writable. These negative tests must
fail. Confirm both wallet-RPC containers and the orchestrator become healthy.

## 6. Resume and retire the old copy

Enable live mode only after the checks pass. Observe a complete request,
executor, wallet restart, and confirmed stake cycle.

Retain the old source and snapshot during the observation period. Removing the
old exposed copy and expiring the snapshot are separate destructive operations;
do them only after current backups and the new deployment have been verified.
