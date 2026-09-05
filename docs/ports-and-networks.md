# Ports and network boundaries

## Staker ports

The staker publishes **no host ports**. It requires no new router rule.

| Port | Where it exists | Purpose | Exposure policy |
|---|---|---|---|
| `18082/tcp` | Inside each wallet-RPC container | Wallet JSON-RPC, including methods capable of moving or locking funds | Internal staker network only; Digest authentication required |
| `19081/tcp` | `salviumd` on `salvium_privileged_rpc` | Unrestricted/elevated daemon RPC used by the wallet services | Private Docker network only; never publish or forward |

Wallet RPC is high impact. Anyone who can authenticate to it may be able to
query private wallet information or request financial operations. Port `19081`
is also elevated: unrestricted daemon RPC includes administrative/mining and
other node-control methods. Neither belongs on the LAN or Internet.

`salvium-staker_internal` is an internal Docker network shared by the
orchestrator and both wallet services. `salvium_privileged_rpc` is an internal,
externally managed Docker network shared only by `salviumd` and the two wallet
services. Docker marks both networks internal, so they have no ordinary Internet
gateway.

## Router rules for the companion node stack

The staker does not change the router guidance for
`mysalvium/salvium-node-p2pool`:

| Host port | Purpose | Internet forwarding |
|---|---|---|
| `19080/tcp` | Salvium node peer-to-peer | Optional |
| `38889/tcp` | Public P2Pool peer-to-peer | Optional while public mode is used |
| `38888/tcp` | Private/custom P2Pool peer-to-peer | Do not expose publicly; approved peers or VPN only |
| `19081/tcp` | Unrestricted daemon RPC | Never |
| `19089/tcp` | Restricted wallet-facing daemon RPC | Never; trusted LAN/VPN only |
| `3333/tcp` | Miner Stratum | Never; trusted LAN/VPN only |
| `3000/tcp` | Statistics page | Never; trusted LAN/VPN only |

Use TCP-only forwarding. The staker itself adds no rule to this table. For the
full firewall and DHCP-aware LAN policy, follow the companion node repository's
`docs/ports-and-networks.md`.

## How to verify

On the Docker host:

```sh
docker ps --filter name=salvium-staker --format '{{.Names}}  {{.Ports}}'
docker network inspect salvium-staker_internal salvium_privileged_rpc
```

The staker `Ports` column should be empty. Network inspection should show the
orchestrator only on the internal network and wallet-RPC on both private
networks.
