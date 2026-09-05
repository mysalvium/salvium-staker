# Architecture

## Data flow

```text
salviumd:19081 (private Docker network only)
             |
       +-----+-----+
       |           |
wallet-rpc     wallet-rpc
  public          miner
       |           |
       +-----+-----+
             |
       orchestrator
       (read/decide)
             |
    private request/result files
             |
 root-owned host executor -> one-shot official wallet CLI
```

The two wallet-RPC containers connect to the node's unrestricted RPC only over
the external `salvium_privileged_rpc` network. The orchestrator does not join
that network; it can reach only the two authenticated wallet services on the
stack's private internal network.

## Why staking uses a host executor

The working Salvium v1.1.3c deployment can consolidate with wallet-RPC
`sweep_all`, but its wallet-RPC transaction path does not reliably construct a
STAKE transaction for these wallets. The official CLI `stake` command does.

Only one process should write a wallet at a time. When the orchestrator makes a
validated decision, it creates a private request. The scheduled executor stops
that wallet's RPC container, runs the official CLI once against the same wallet,
and restarts wallet-RPC even if the CLI fails or times out.

## Docker control boundary

No container mounts `/var/run/docker.sock`. The executor source in the Git
checkout is never run by root. `scripts/install-executor.sh` copies it to the
persistent root-only path
`/mnt/sharedrive/apps/salvium/data/operations/host/salvium-stake-executor` with
mode `0750`. Its configuration and rate-limit state also live below the
root-only Salvium operations directory. This avoids TrueNAS's read-only system
filesystem.

Before acting, the installed executor checks:

- its own and its configuration file's ownership and write permissions;
- a fixed allowlist of wallet and container names;
- request ownership, mode, age, wallet field, decimal precision, and amount;
- the secret and wallet paths, including symlink and permission checks;
- the running container's exact configured image tag;
- a root-only rate limit;
- wallet restart and health after the one-shot CLI exits.

The one-shot container is non-root, read-only except for its wallet bind mount,
capability-free, unable to gain privileges, and constrained by CPU, memory, PID,
and temporary-filesystem limits.

## Storage

| Host path | Container use | Sensitivity |
|---|---|---|
| `config/wallets.yml` | Orchestrator, read-only | Private settings |
| `wallets/public` | Public wallet-RPC and one-shot CLI | Critical wallet data |
| `wallets/miner` | Miner wallet-RPC and one-shot CLI | Critical wallet data |
| `secrets/*` | Individual read-only secret mounts | Critical credentials |
| `logs` | Orchestrator request/result/audit state | Private financial metadata |
| `data/operations/staker-state` | Host executor rate-limit/lock state | Root-only control data |

Raw CLI output and executor logs stay in the root-only state directory, not in
the orchestrator-writable request directory. This prevents a compromised
orchestrator from redirecting a root log write through a symlink.

Wallet directories are never mounted into the orchestrator. Wallet password
files are never mounted into it either; it receives only the two RPC passwords.
