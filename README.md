# Salvium auto-staker

This project runs two Salvium wallet-RPC services and automatically manages
staking for a public/reward wallet and a mining wallet. It was built from a
working TrueNAS installation, then hardened so the wallet services are not
published to the LAN or Internet and no container receives the Docker socket.

> **Important:** this is hot-wallet automation. The host can unlock the wallet
> files to stake. Start in observe mode, keep an offline copy of every seed,
> and never use this as your only wallet backup.

## What is special about this stack

- **Automatic staking:** stakes the safe maximum while retaining a configurable
  fee reserve and optional liquid balance.
- **Automatic output consolidation:** combines fragmented outputs back to the
  wallet's own address before staking.
- **Separate wallet rules:** the public and mining wallets can use different
  minimums, output limits, and staking gates.
- **Genuinely safe first start:** both financial actions are disabled by
  default. Observe mode reads balances and explains what it would do without
  constructing a transaction.
- **No exposed ports:** wallet RPC is available only on a private Docker
  network. No router change is needed.
- **No Docker socket in containers:** a narrow root-owned host executor is the
  only component allowed to start the one-shot official wallet CLI.
- **Fail-closed controls:** requests have wallet, ownership, permission, age,
  amount, rate-limit, and image checks. An unclear CLI outcome pauses retries.
- **Verified downloads:** official Salvium archives must match the published
  SHA-256 before an image can build.
- **Container containment:** non-root users, read-only root filesystems, dropped
  capabilities, resource limits, health checks, private networks, and bounded
  logs are enabled throughout.
- **Consistent backups:** the included script briefly stops the wallet services,
  creates a root-only archive, and verifies its checksum and compression.

## What runs on GitHub

Nothing operational. This repository holds source code and documentation; the
wallet services, node connection, consolidation, and staking run only on the
owner's private Docker host. The single GitHub Actions workflow lints, runs
unit tests, builds and scans the two images, and records SBOMs. It starts no
wallet, node, miner, or executor, holds no credentials, has no route to the
private host, and runs only on pushes, pull requests, and manual dispatch.
The "miner" wallet is a wallet that receives mining-pool payouts; this project
contains no mining software.

## What you need

1. A Linux Docker host such as TrueNAS SCALE with Docker Compose v2.
2. A synchronized Salvium node from
   [`mysalvium/salvium-node-p2pool`](https://github.com/mysalvium/salvium-node-p2pool).
   That stack creates the private `salvium_privileged_rpc` Docker network.
3. Two existing Salvium wallet files and their matching `.keys` files.
4. The password and offline seed for each wallet.

This guide uses these locations:

```text
/mnt/sharedrive/salvium-private/staker-repo   downloaded source code
/mnt/sharedrive/salvium-private/staker        private wallet data and settings
/mnt/sharedrive/salvium-private/operations    installed root-only executor
```

All three paths are inside a dedicated, non-shared dataset. The source and
private data are separate directories, and the scheduled root executor is an
installed copy outside the Git checkout.

## Easy installation

### 1. Create a private dataset

Do not place this stack inside an SMB share or a TrueNAS Apps dataset with its
default inherited ACL. Named NFSv4 entries can grant access even when `stat`
shows `0600`, and mutable wallet cache files can inherit broad permissions when
they are replaced.

In the TrueNAS UI, create `sharedrive/salvium-private` with the **Generic**
preset, POSIX ACL type, and no SMB or NFS share. Set its owner to `root:root`
and mode to `0700`. The equivalent TrueNAS API commands are:

```sh
midclt call pool.dataset.create \
  '{"name":"sharedrive/salvium-private","type":"FILESYSTEM","share_type":"GENERIC","acltype":"POSIX","aclmode":"DISCARD","casesensitivity":"SENSITIVE"}'
midclt call -j filesystem.setperm \
  '{"path":"/mnt/sharedrive/salvium-private","mode":"0700","uid":0,"gid":0,"options":{"stripacl":true}}'
```

Confirm the path is not covered by an SMB or NFS share before continuing.

### 2. Download the project

Open the TrueNAS shell, become root, and run:

```sh
cd /mnt/sharedrive/salvium-private
git clone https://github.com/mysalvium/salvium-staker.git staker-repo
cd staker-repo
```

### 3. Prepare private folders

```sh
STACK=/mnt/sharedrive/salvium-private/staker ./scripts/prepare-host.sh
```

The command creates the folders and random RPC passwords. It does not overwrite
an existing wallet, password, configuration, or `.env` file. It rejects
non-trivial NFSv4 or POSIX ACLs rather than trusting Unix mode bits alone.

### 4. Connect the wallets to your Salvium node

There are two different wallet-to-node connections. They deliberately use
different addresses:

| Wallet client | Node address | Where it is allowed |
|---|---|---|
| The two automated wallet-RPC containers in this project | `salviumd:19081` | Private Docker network only |
| A normal desktop wallet on your computer | `YOUR-SERVER-LAN-IP:19089` | Trusted LAN or VPN only |

#### Automated wallets in this project

If you installed
[`mysalvium/salvium-node-p2pool`](https://github.com/mysalvium/salvium-node-p2pool)
on the same Docker server, the connection is already configured. The staker
uses the node container name rather than a changing IP address.

Confirm the private node network contains `salviumd`:

```sh
docker network inspect salvium_privileged_rpc \
  --format '{{range .Containers}}{{println .Name}}{{end}}'
```

Then confirm these two lines in the private staker `.env`:

```sh
grep -E '^(PRIVILEGED_RPC_NETWORK|DAEMON_ADDRESS)=' \
  /mnt/sharedrive/salvium-private/staker/.env
```

The result should be:

```text
PRIVILEGED_RPC_NETWORK=salvium_privileged_rpc
DAEMON_ADDRESS=salviumd:19081
```

Do not replace this with the TrueNAS LAN address when using the companion node
stack. Port `19081` is the node's elevated RPC interface, so it must remain on
the private Docker network and must never be published or forwarded by the
router. If the network check does not show `salviumd`, finish starting the node
stack before continuing.

#### Desktop wallets on other computers

Desktop wallets do **not** use the private elevated port. In the Salvium GUI,
open **Settings**, find the **Node** settings, choose a remote or custom node,
and enter your Docker server's LAN address with port `19089`. If the wallet has
one address box, enter `YOUR-SERVER-LAN-IP:19089`.

For the command-line wallet, the equivalent is:

```sh
salvium-wallet-cli --daemon-address YOUR-SERVER-LAN-IP:19089
```

Port `19089` is the restricted wallet-facing RPC endpoint from the companion
node stack. Use it only from your trusted LAN or through a VPN. Never forward
`19089` to the public Internet. Changing DHCP addresses on the wallet computers
is fine when the node firewall trusts the whole intended LAN subnet.

### 5. Copy both wallets

Each wallet has two important files: the wallet cache and the matching `.keys`
file. Copy both while preserving the names shown below:

```text
/mnt/sharedrive/salvium-private/staker/wallets/public/Public Salvium Wallet
/mnt/sharedrive/salvium-private/staker/wallets/public/Public Salvium Wallet.keys
/mnt/sharedrive/salvium-private/staker/wallets/miner/Salvium Miner Wallet
/mnt/sharedrive/salvium-private/staker/wallets/miner/Salvium Miner Wallet.keys
```

Then protect them:

```sh
chown -R 1000:1000 /mnt/sharedrive/salvium-private/staker/wallets
find /mnt/sharedrive/salvium-private/staker/wallets -type d -exec chmod 700 {} \;
find /mnt/sharedrive/salvium-private/staker/wallets -type f -exec chmod 600 {} \;
```

Run `./scripts/install-executor.sh` later with `--check`, which also rejects
named or inherited ACLs. Never copy a seed phrase into this project or into Git.

### 6. Store the wallet passwords

Run the interactive helper. Your typing is hidden:

```sh
STACK=/mnt/sharedrive/salvium-private/staker ./scripts/set-wallet-passwords.sh
```

Passwords are private files under `secrets/`; they are **not** values in
`.env`. The `.env` file contains non-secret deployment settings and the two
on/off controls.

### 7. Review the staking rules

Open:

```text
/mnt/sharedrive/salvium-private/staker/config/wallets.yml
```

The supplied example waits until the miner wallet has more than 25 outputs,
consolidates them to itself, and stakes once a single output exceeds 15 SAL.
The public wallet stakes any eligible amount of at least 34 SAL. See
[`docs/operations.md`](docs/operations.md) before changing these values.

### 8. Build verified images

```sh
cd /mnt/sharedrive/salvium-private/staker-repo
./build-images.sh
```

The build stops immediately if the official archive does not match its trusted
checksum.

### 9. Install the protected stake executor

```sh
./scripts/install-executor.sh
```

In TrueNAS, create a scheduled task with:

| Setting | Value |
|---|---|
| User | `root` |
| Schedule | Every 5 minutes |
| Command | `/mnt/sharedrive/salvium-private/operations/host/salvium-stake-executor` |

Do not schedule the copy inside the Git folder. The installed copy is in the
persistent root-only Salvium operations directory and cannot be replaced by the
wallet containers. TrueNAS keeps its system filesystem read-only, so this data
pool location is intentional.

### 10. Start in observe mode

```sh
cd /mnt/sharedrive/salvium-private/staker-repo
docker compose \
  --env-file /mnt/sharedrive/salvium-private/staker/.env \
  up -d
./scripts/status.sh
```

Observe mode is the default. Leave it running for at least one full polling
cycle and confirm that both wallet services become `healthy`.

### 11. Enable automatic staking

When the balances, output counts, and proposed actions look correct:

```sh
STACK=/mnt/sharedrive/salvium-private/staker ./scripts/set-mode.sh live
docker compose \
  --env-file /mnt/sharedrive/salvium-private/staker/.env \
  up -d
```

The helper requires a typed confirmation before enabling live transactions.
Run `./scripts/status.sh` again after the first cycle.

## Back up now

```sh
./scripts/backup.sh
./scripts/verify-backup.sh /mnt/sharedrive/backups/salvium-staker/FILE.tar.zst
```

Replace `FILE.tar.zst` with the name printed by the backup command. The archive
contains wallets and passwords. It is root-only but not encrypted; copy it to
encrypted, offline, or otherwise protected storage. Full guidance is in
[`docs/backup-and-recovery.md`](docs/backup-and-recovery.md).

## Portainer

Portainer can deploy the Compose file after the two images are built on the
Docker endpoint. Set the same non-secret values shown in `.env.example`, use
`docker-compose.yml`, keep passwords as host files under `secrets/`, and keep
Portainer's stack working directory inside the private dataset rather than an
SMB-shared path.

The local `.portainer-token` file is intentionally ignored. It is an
administrator credential for Portainer, is not required by this stack, and
must never be committed, uploaded, pasted into an issue, or placed in `.env`.

## Updating safely

This financial automation does not silently replace its own transaction code.
Dependabot reports available updates monthly, and the workflow can be run by
hand at any time; an administrator reviews, rebuilds, scans, backs up, and
then deploys them:

```sh
git pull --ff-only
./build-images.sh
./scripts/security-scan.sh /mnt/sharedrive/salvium-private/staker/.env full
./scripts/backup.sh
docker compose --env-file /mnt/sharedrive/salvium-private/staker/.env up -d
./scripts/status.sh
```

## More documentation

- [`docs/architecture.md`](docs/architecture.md) — how the services work together
- [`docs/ports-and-networks.md`](docs/ports-and-networks.md) — every port and router rule
- [`docs/security-hardening.md`](docs/security-hardening.md) — protections and remaining risks
- [`docs/operations.md`](docs/operations.md) — modes, thresholds, updates, and troubleshooting
- [`docs/backup-and-recovery.md`](docs/backup-and-recovery.md) — backup and safe restore procedure
- [`docs/truenas-private-dataset-migration.md`](docs/truenas-private-dataset-migration.md) — safely move an existing TrueNAS install out of inherited ACLs
- [`docs/supply-chain.md`](docs/supply-chain.md) — downloads, scans, SBOMs, and update review

## Support and safety

This is community infrastructure, not the official Salvium wallet. Review a
small transaction workflow before entrusting significant funds, and verify
behavior against the official [Salvium documentation](https://docs.salvium.io/)
and [Salvium releases](https://github.com/salvium/salvium/releases).

See [`SECURITY.md`](SECURITY.md) for private vulnerability reporting guidance.
