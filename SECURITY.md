# Security policy

## Reporting a vulnerability

Do not post wallet data, passwords, seed phrases, private keys, RPC credentials,
Portainer tokens, transaction metadata, or an exploitable report in a public
issue. Use GitHub's private vulnerability reporting feature for this repository.

Include the affected commit, component, expected behavior, observed behavior,
and a minimal reproduction with all sensitive values removed.

## Supported version

Only the current `main` branch is supported. Before deploying a security update,
back up the wallets, review the change, build the pinned images, run the security
gate, and test in observe mode.

## Secrets that must never enter Git

- Seed phrases and private spend/view keys
- Wallet cache and `.keys` files
- Wallet and RPC passwords
- `.env`, local Compose overrides, and populated wallet configuration
- `.portainer-token` and any GitHub/Portainer access token
- Logs, transaction result files, backups, and security reports

The repository ignore policy is defense in depth, not permission to keep
secrets in the source tree. Store them only in the private runtime directory.
