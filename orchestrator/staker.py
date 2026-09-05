#!/usr/bin/env python3
"""Salvium auto-staker orchestrator (v2, CLI-executor architecture).

WHY v2 (2026-07-10): on salvium v1.1.3c the wallet-rpc `transfer` method
cannot construct ANY transaction from this wallet's outputs (it routes through
the new Carrot input-selection engine, which rejects them with
carrot::not_enough_money "no input candidates provided"). `sweep_all` still
works via the legacy path, but its `tx_type` parameter is silently ignored
(verified on-chain: a tx_type=6 sweep confirmed as Tx Type TRANSFER). The
official CLI's `stake` command DOES construct and broadcast stakes (verified
on-chain: Tx Type STAKE). Therefore:

  * CONSOLIDATION stays in-process via the sweep_all RPC (works).
  * STAKING is delegated to a host-side executor (stake-executor.sh, run by
    cron) that briefly stops the wallet-rpc container and runs a one-shot
    `salvium-wallet-cli --command stake <amount>` against the same wallet
    file, honoring the one-active-spender rule.

The orchestrator and executor communicate through files on the shared /logs
volume:
  stake-request-<wallet>.json  written by the orchestrator (the decision)
  stake-result-<wallet>.json   written by the executor (the outcome)
  stake-output-<wallet>.log    raw CLI output captured by the executor

Decision logic per wallet, each cycle:
  0. If a stake RESULT file exists: consume it (audit + cooldown), delete
     both files. If a REQUEST is still pending (no result yet): skip cycle.
  1. Read-only snapshot (balances, unspent output list).
  2. Skip if in cooldown, an outgoing tx is pending, or nothing is unlocked.
  3. ACCUMULATE (idle) while no single unlocked output exceeds the stake gate
     AND the wallet is not over-fragmented.
  4. CONSOLIDATE (sweep_all to self) when unspent outputs exceed the
     fragmentation threshold. The swept lump unlocks ~10 blocks later and,
     being large, trips the stake gate on a following cycle. NOTE: sweeps
     produce PAIRED ~half-value outputs on Salvium One, so a consolidation
     lump arrives as two halves; the gate should be sized accordingly.
  5. STAKE-MAX: write a stake request for
     (unlocked - fee reserve - keep_liquid). The executor performs it within
     its next cron interval. No funds ever leave the wallet: the CLI stake
     locks to the wallet itself.

Gate semantics unchanged from v1: `stake_when_single_output_over_sal` gates
on the LARGEST SINGLE unlocked output (0 = stake immediately). Legacy key
`stake_when_unlocked_over_sal` still read with a deprecation warning.

`keep_liquid_sal` (per wallet, default 0 = DISABLED) holds back a spendable
reserve that is never staked. At 0 every code path below is a strict no-op:
the stake amount, the guards and the log lines are byte-for-byte what they
were without the feature. When set > 0 it is subtracted from the stakeable
amount, and a wallet whose whole unlocked balance IS the reserve idles
instead of churning fees on tiny stakes. It does NOT block consolidation:
sweeps are self-sends that keep the funds unlocked and spendable, so the
reserve survives them.

NOTE: keep `consolidate_when_outputs_over` x (average payout) comfortably
above 2x the gate (pair-splitting halves each lump), otherwise a swept half
could land under the gate and the wallet would sweep repeatedly without
staking.
"""

import json
import logging
import logging.handlers
import os
import re
import signal
import tempfile
import time
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

import requests
from requests.auth import HTTPDigestAuth
import yaml

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #
ATOMIC = Decimal(100_000_000)          # 1 SAL = 1e8 atomic units
DEFAULT_ASSET = "SAL1"
RPC_TIMEOUT = 120                      # seconds; sweeps of many inputs are slow
COOLDOWN_SECONDS = 25 * 60             # ~10 blocks (2-min blocks) + margin
FAILED_STAKE_COOLDOWN = 10 * 60        # back off after an executor failure
AMBIGUOUS_STAKE_COOLDOWN = 60 * 60     # avoid fee churn if CLI output is unclear
# Reserved headroom so the CLI can pay the stake fee out of the remaining
# balance (measured fees ~0.01-0.02 SAL; leftover accrues and is swept later).
DEFAULT_STAKE_FEE_RESERVE_SAL = Decimal("0.1")
# A request older than this with no result means the executor cron is not
# running or is failing before it can write a result file.
STALE_REQUEST_SECONDS = 60 * 60

LOG_DIR = Path(os.environ.get("LOG_DIR", "/logs"))
STATE_PATH = LOG_DIR / "state.json"
AUDIT_PATH = LOG_DIR / "audit.jsonl"
HEARTBEAT_PATH = LOG_DIR / "health.json"
SAFE_WALLET_NAME = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
SAFE_TX_HASH = re.compile(r"^[0-9a-f]{64}$")


def stake_request_path(name: str) -> Path:
    return LOG_DIR / f"stake-request-{name}.json"


def stake_result_path(name: str) -> Path:
    return LOG_DIR / f"stake-result-{name}.json"

log = logging.getLogger("staker")
_audit_logger = logging.getLogger("staker.audit")


def setup_logging() -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    fmt = logging.Formatter("%(asctime)s %(levelname)-7s %(message)s")

    stream = logging.StreamHandler()
    stream.setFormatter(fmt)

    fileh = logging.handlers.RotatingFileHandler(
        LOG_DIR / "staker.log", maxBytes=5_000_000, backupCount=10
    )
    fileh.setFormatter(fmt)

    log.setLevel(logging.INFO)
    log.addHandler(stream)
    log.addHandler(fileh)

    audit_handler = logging.handlers.RotatingFileHandler(
        AUDIT_PATH, maxBytes=5_000_000, backupCount=20
    )
    audit_handler.setFormatter(logging.Formatter("%(message)s"))
    _audit_logger.setLevel(logging.INFO)
    _audit_logger.addHandler(audit_handler)
    _audit_logger.propagate = False


def audit(event: str, wallet: str, **fields) -> None:
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "event": event,
        "wallet": wallet,
        **fields,
    }
    _audit_logger.info(json.dumps(record, separators=(",", ":")))


def atomic_write_json(path: Path, value: dict) -> None:
    """Write a private JSON file without following a pre-existing symlink."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp = Path(tmp_name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        tmp.replace(path)
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        tmp.unlink(missing_ok=True)
        raise


def write_heartbeat(status: str, failures: int = 0) -> None:
    atomic_write_json(
        HEARTBEAT_PATH,
        {
            "status": status,
            "failures": failures,
            "epoch": int(time.time()),
            "ts": datetime.now(timezone.utc).isoformat(),
        },
    )


# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #
def sal(atomic) -> str:
    return str((Decimal(str(atomic)) / ATOMIC).quantize(Decimal("0.00000001")))


def to_atomic(sal_amount) -> int:
    return int((Decimal(str(sal_amount)) * ATOMIC).to_integral_value())


class RPCError(Exception):
    def __init__(self, method, err):
        self.method = method
        self.err = err
        super().__init__(f"{method}: {err}")


class WalletRPC:
    def __init__(self, url: str, user: str, password: str):
        self.url = url
        self.auth = HTTPDigestAuth(user, password)

    def call(self, method: str, params: dict | None = None) -> dict:
        payload = {"jsonrpc": "2.0", "id": "0", "method": method}
        if params is not None:
            payload["params"] = params
        resp = requests.post(self.url, json=payload, auth=self.auth, timeout=RPC_TIMEOUT)
        resp.raise_for_status()
        data = resp.json()
        if data.get("error"):
            raise RPCError(method, data["error"])
        return data.get("result", {}) or {}


# --------------------------------------------------------------------------- #
# State (idempotency / cooldown)
# --------------------------------------------------------------------------- #
def load_state() -> dict:
    try:
        return json.loads(STATE_PATH.read_text())
    except Exception:
        return {}


def save_state(state: dict) -> None:
    atomic_write_json(STATE_PATH, state)


# --------------------------------------------------------------------------- #
# Core per-wallet logic
# --------------------------------------------------------------------------- #
def read_secret(path: str) -> str:
    return Path(path).read_text().strip()


def get_account(rpc: WalletRPC, idx: int) -> dict:
    """Return the account dict {base_address, balance, unlocked_balance} for idx."""
    res = rpc.call("get_accounts")
    for a in res.get("subaddress_accounts", []):
        if a.get("account_index") == idx:
            return a
    raise RPCError("get_accounts", f"account_index {idx} not found")


def has_pending_out(rpc: WalletRPC, idx: int) -> bool:
    res = rpc.call(
        "get_transfers",
        {"out": True, "pending": True, "pool": True, "account_index": idx},
    )
    return bool(res.get("pending") or res.get("pool"))


def get_available_outputs(rpc: WalletRPC, idx: int) -> list:
    """Unspent outputs for the account (locked and unlocked alike)."""
    res = rpc.call(
        "incoming_transfers", {"transfer_type": "available", "account_index": idx}
    )
    return res.get("transfers", []) or []


def max_unlocked_output(transfers: list) -> int:
    """Largest single spendable (unlocked, unspent) output, in atomic units.

    Wallet-rpc marks each entry with `unlocked`; if a build omits the field we
    assume True, which only makes the gate trip earlier -- the subsequent
    stake-max still only spends what is actually unlocked.
    """
    amounts = [
        int(t.get("amount", 0))
        for t in transfers
        if not t.get("spent", False) and t.get("unlocked", True)
    ]
    return max(amounts, default=0)


def consume_stake_result(name: str, ws: dict, now: float) -> None:
    """If the executor left a result file, record it and clean up.

    Success -> audit 'staked' + normal cooldown.
    Failure -> audit 'stake_failed_executor' + shorter cooldown (the gate will
    re-trip and a fresh request will be written after the cooldown).
    """
    res_path = stake_result_path(name)
    if not res_path.exists():
        return
    if res_path.is_symlink():
        log.error("[%s] refusing symlinked stake result file", name)
        audit("stake_result_rejected", name, reason="symlink")
        res_path.unlink(missing_ok=True)
        return
    try:
        result = json.loads(res_path.read_text())
        if not isinstance(result, dict):
            raise ValueError("result is not an object")
        if result.get("wallet") != name:
            raise ValueError("wallet name does not match result filename")
        if result.get("status") not in {"success", "failed", "ambiguous"}:
            raise ValueError("unknown result status")
        if result.get("status") == "success" and not SAFE_TX_HASH.fullmatch(
            str(result.get("tx_hash", ""))
        ):
            raise ValueError("success result has an invalid transaction hash")
    except Exception as e:
        log.error("[%s] unreadable stake result file (%s); removing", name, e)
        audit("stake_result_unreadable", name, error=str(e))
        result = {"status": "failed", "detail": f"unreadable result: {e}"}

    if result.get("status") == "success":
        log.info("[%s] STAKED %s via CLI executor  tx=%s  (~30 day lock)",
                 name, result.get("amount_sal"), result.get("tx_hash"))
        audit("staked", name, amount=result.get("amount_sal"),
              tx_hash=result.get("tx_hash"), via="cli_executor",
              executor_ts=result.get("ts"))
        ws["cooldown_until"] = now + COOLDOWN_SECONDS
        ws["last_action"] = "stake"
        ws["last_stake_tx"] = result.get("tx_hash")
    elif result.get("status") == "ambiguous":
        log.error("[%s] executor outcome is AMBIGUOUS: %s; pausing for 60m",
                  name, result.get("detail", "unknown"))
        audit("stake_ambiguous_executor", name,
              detail=result.get("detail", "unknown"),
              executor_ts=result.get("ts"))
        ws["cooldown_until"] = now + AMBIGUOUS_STAKE_COOLDOWN
        ws["last_action"] = "stake_ambiguous"
    else:
        log.warning("[%s] executor stake FAILED: %s (see stake-output-%s.log)",
                    name, result.get("detail", "unknown"), name)
        audit("stake_failed_executor", name,
              detail=result.get("detail", "unknown"),
              executor_ts=result.get("ts"))
        ws["cooldown_until"] = now + FAILED_STAKE_COOLDOWN
        ws["last_action"] = "stake_failed"

    for p in (stake_request_path(name), res_path):
        try:
            p.unlink()
        except FileNotFoundError:
            pass


def write_stake_request(name: str, amount_atomic: int, unlocked_atomic: int) -> None:
    """Atomically publish a stake request for the host-side executor."""
    req = {
        "wallet": name,
        "amount_sal": sal(amount_atomic),
        "unlocked_sal": sal(unlocked_atomic),
        "requested_at": datetime.now(timezone.utc).isoformat(),
    }
    atomic_write_json(stake_request_path(name), req)


def consolidate_to_self(rpc: WalletRPC, name: str, idx: int, addr: str, asset: str,
                        ws: dict, now: float, reason: str) -> None:
    """sweep_all to the wallet's OWN address, reducing output count."""
    log.info("[%s] %s -> consolidating to self", name, reason)
    res = rpc.call(
        "sweep_all",
        {
            "address": addr,          # OWN address only
            "account_index": idx,
            "asset_type": asset,
            "do_not_relay": False,
        },
    )
    hashes = res.get("tx_hash_list", []) or []
    amounts = [sal(a) for a in res.get("amount_list", []) or []]
    fees = [sal(f) for f in res.get("fee_list", []) or []]
    log.info("[%s] consolidation tx(s): %d  amounts=%s  fees=%s",
             name, len(hashes), amounts, fees)
    audit("consolidate", name, reason=reason,
          tx_count=len(hashes), tx_hashes=hashes, amounts=amounts, fees=fees)
    ws["cooldown_until"] = now + COOLDOWN_SECONDS
    ws["last_action"] = "consolidate"
    # Swept outputs need to unlock (~10 blocks) before staking; next cycle.


def resolve_stake_gate(w: dict, name: str) -> int:
    """Per-wallet single-output stake gate in atomic units (0 = no gate)."""
    if "stake_when_single_output_over_sal" in w:
        return to_atomic(w.get("stake_when_single_output_over_sal", 0))
    if "stake_when_unlocked_over_sal" in w:
        log.warning(
            "[%s] config key 'stake_when_unlocked_over_sal' is deprecated and is "
            "now interpreted as a SINGLE-OUTPUT gate; rename it to "
            "'stake_when_single_output_over_sal'", name,
        )
        return to_atomic(w.get("stake_when_unlocked_over_sal", 0))
    return 0


def process_wallet(
    w: dict,
    state: dict,
    enable_consolidation: bool,
    enable_staking: bool,
) -> None:
    name = w["name"]
    idx = int(w.get("account_index", 0))
    asset = w.get("asset", DEFAULT_ASSET)
    min_stake_atomic = to_atomic(w.get("min_stake_sal", 1))
    fee_reserve_atomic = to_atomic(
        w.get("stake_fee_reserve_sal", DEFAULT_STAKE_FEE_RESERVE_SAL))
    consolidate_over = int(w.get("consolidate_when_outputs_over", 20))
    # 0 (default) = no gate: stake whatever is available immediately (public wallet).
    stake_gate_atomic = resolve_stake_gate(w, name)
    # 0 (default) = DISABLED. Spendable reserve that is never staked.
    keep_liquid_atomic = to_atomic(w.get("keep_liquid_sal", 0))

    rpc = WalletRPC(
        w["rpc_url"], w.get("rpc_user", "sal_rpc"), read_secret(w["rpc_password_file"])
    )

    # --- read-only snapshot ------------------------------------------------- #
    height = rpc.call("get_height").get("height", 0)
    acct = get_account(rpc, idx)
    addr = acct["base_address"]
    total = int(acct.get("balance", 0))
    unlocked = int(acct.get("unlocked_balance", 0))
    locked = total - unlocked
    transfers = get_available_outputs(rpc, idx)
    outputs = len(transfers)
    max_out = max_unlocked_output(transfers)

    log.info("[%s] height=%s  max_output=%s", name, height, sal(max_out))
    log.info("[%s] %18s  %18s  %18s  %8s",
             name, "Balance", "Unlocked balance", "Locked balance", "Outputs")
    log.info("[%s] %18s  %18s  %18s  %8d",
             name, sal(total), sal(unlocked), sal(locked), outputs)
    audit("snapshot", name, height=height, balance=sal(total),
          unlocked=sal(unlocked), locked=sal(locked), outputs=outputs,
          max_output=sal(max_out))

    ws = state.setdefault(name, {})
    now = time.time()

    # --- executor handshake -------------------------------------------------- #
    # Consume a finished stake result first (sets cooldown on success/failure).
    consume_stake_result(name, ws, now)

    # A request without a result means the executor has not run yet -> wait.
    req_path = stake_request_path(name)
    if req_path.exists():
        age = now - req_path.stat().st_mtime
        if age > STALE_REQUEST_SECONDS:
            log.error("[%s] stake request pending for %dm with no result -- "
                      "is the stake-executor cron job running?", name, age // 60)
            audit("stake_request_stale", name, age_seconds=int(age))
        else:
            log.info("[%s] stake request pending executor (%ds old) -> skip",
                     name, int(age))
            audit("stake_request_pending", name, age_seconds=int(age))
        return

    # --- guards ------------------------------------------------------------- #
    if now < ws.get("cooldown_until", 0):
        mins = int((ws["cooldown_until"] - now) / 60)
        log.info("[%s] in cooldown (~%dm left) -> skip", name, mins)
        return

    if has_pending_out(rpc, idx):
        log.info("[%s] an outgoing tx is still pending/in-pool -> skip", name)
        audit("skip_pending", name)
        return

    if unlocked == 0:
        log.info("[%s] nothing unlocked (all staked or maturing) -> idle", name)
        audit("idle", name, reason="no_unlocked_balance")
        return

    # --- accumulation gate (single-output semantics) ------------------------ #
    # While the largest single unlocked output is below the gate, just wait.
    # Mining dust never trips this on its own; only a matured stake's returned
    # principal or a consolidation lump does. When it does trip, the stake-max
    # below sweeps ALL unlocked (dust included) into one stake transaction.
    if max_out < stake_gate_atomic and outputs <= consolidate_over:
        log.info("[%s] largest single output %s below stake gate %s "
                 "(total unlocked %s, %d outputs) -> accumulating (idle)",
                 name, sal(max_out), sal(stake_gate_atomic), sal(unlocked), outputs)
        audit("accumulating", name, max_output=sal(max_out),
              gate=sal(stake_gate_atomic), unlocked=sal(unlocked), outputs=outputs)
        return

    # --- too fragmented for a single stake tx -> consolidate first ---------- #
    # (Also the de-facto accumulation clock under the single-output gate: the
    # swept lump is what eventually trips the gate.) Swept outputs need ~10
    # blocks to unlock; staking happens on a later cycle.
    if outputs > consolidate_over:
        reason = f"{outputs} outputs exceeds threshold {consolidate_over}"
        if not enable_consolidation:
            log.warning("[%s] %s -> would consolidate, but consolidation is disabled",
                        name, reason)
            audit("would_consolidate", name, reason=reason)
            return
        consolidate_to_self(rpc, name, idx, addr, asset, ws, now, reason)
        return

    # --- stake-max via the CLI executor -------------------------------------- #
    # wallet-rpc `transfer` cannot build stakes on v1.1.3c (Carrot input
    # selection rejects the outputs), so the actual stake is performed by the
    # host-side stake-executor.sh; we publish the decision as a request file.
    # keep_liquid_atomic is 0 unless configured, in which case this is a no-op
    # and max_stake is exactly (unlocked - fee reserve), as before.
    max_stake = unlocked - fee_reserve_atomic - keep_liquid_atomic
    liquid_note = ""
    if keep_liquid_atomic > 0:
        liquid_note = f", keeping {sal(keep_liquid_atomic)} liquid"

    if max_stake < min_stake_atomic:
        log.info("[%s] stakeable %s below minimum %s (reserve %s%s) -> skip",
                 name, sal(max(max_stake, 0)), sal(min_stake_atomic),
                 sal(fee_reserve_atomic), liquid_note)
        audit("skip_below_min", name, stakeable=sal(max(max_stake, 0)),
              minimum=sal(min_stake_atomic), reserve=sal(fee_reserve_atomic),
              keep_liquid=sal(keep_liquid_atomic))
        return

    if not enable_staking:
        log.warning("[%s] would request CLI stake of %s, but staking is disabled "
                 "(unlocked %s minus reserve %s%s)",
                 name, sal(max_stake), sal(unlocked), sal(fee_reserve_atomic),
                 liquid_note)
        audit("would_request_stake", name, amount=sal(max_stake),
              unlocked=sal(unlocked), reserve=sal(fee_reserve_atomic),
              keep_liquid=sal(keep_liquid_atomic))
        return

    write_stake_request(name, max_stake, unlocked)
    log.info("[%s] stake request written: %s SAL (executor will run it within "
             "its cron interval; wallet-rpc will restart briefly)%s",
             name, sal(max_stake), liquid_note)
    audit("stake_requested", name, amount=sal(max_stake),
          unlocked=sal(unlocked), reserve=sal(fee_reserve_atomic),
          keep_liquid=sal(keep_liquid_atomic))


# --------------------------------------------------------------------------- #
# Main loop
# --------------------------------------------------------------------------- #
_running = True


def _stop(signum, _frame):
    global _running
    log.info("received signal %s -> shutting down after this cycle", signum)
    _running = False


def parse_bool(value, *, field: str) -> bool:
    if isinstance(value, bool):
        return value
    normalized = str(value).strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"{field} must be true or false")


def automation_flags(cfg: dict) -> tuple[bool, bool]:
    """Return explicit action flags, with compatibility for the old DRY_RUN knob."""
    env_dry = os.environ.get("DRY_RUN")
    legacy_enabled = not parse_bool(
        env_dry if env_dry is not None else cfg.get("dry_run", True),
        field="DRY_RUN/dry_run",
    )
    consolidation = parse_bool(
        os.environ.get(
            "ENABLE_CONSOLIDATION",
            cfg.get("enable_consolidation", legacy_enabled),
        ),
        field="ENABLE_CONSOLIDATION",
    )
    staking = parse_bool(
        os.environ.get("ENABLE_STAKING", cfg.get("enable_staking", legacy_enabled)),
        field="ENABLE_STAKING",
    )
    return consolidation, staking


def validate_config(cfg: dict) -> list[dict]:
    if not isinstance(cfg, dict):
        raise ValueError("configuration must be a YAML object")
    wallets = cfg.get("wallets")
    if not isinstance(wallets, list) or not wallets:
        raise ValueError("configuration must contain at least one wallet")
    if len(wallets) > 10:
        raise ValueError("at most 10 wallets are supported")

    seen: set[str] = set()
    for wallet in wallets:
        if not isinstance(wallet, dict):
            raise ValueError("each wallet entry must be an object")
        name = wallet.get("name")
        if not isinstance(name, str) or not SAFE_WALLET_NAME.fullmatch(name):
            raise ValueError(
                "wallet names must start with a lowercase letter and contain only "
                "lowercase letters, numbers, '_' or '-' (32 characters maximum)"
            )
        if name in seen:
            raise ValueError(f"duplicate wallet name: {name}")
        seen.add(name)

        url = wallet.get("rpc_url")
        if not isinstance(url, str) or not url.startswith("http://"):
            raise ValueError(f"{name}: rpc_url must use http:// on the private network")
        secret = Path(str(wallet.get("rpc_password_file", "")))
        if not secret.is_absolute() or secret.parent != Path("/run/secrets"):
            raise ValueError(f"{name}: rpc_password_file must be directly under /run/secrets")

        numeric_fields = {
            "account_index": (0, 1000),
            "min_stake_sal": (0, 100_000_000),
            "stake_fee_reserve_sal": (0, 1000),
            "keep_liquid_sal": (0, 100_000_000),
            "consolidate_when_outputs_over": (1, 100_000),
            "stake_when_single_output_over_sal": (0, 100_000_000),
        }
        for field, (minimum, maximum) in numeric_fields.items():
            if field not in wallet:
                continue
            value = Decimal(str(wallet[field]))
            if not value.is_finite() or value < minimum or value > maximum:
                raise ValueError(
                    f"{name}: {field} must be between {minimum} and {maximum}"
                )
    return wallets


def main() -> None:
    os.umask(0o077)
    setup_logging()
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    cfg_path = os.environ.get("CONFIG", "/config/wallets.yml")
    cfg = yaml.safe_load(Path(cfg_path).read_text())
    wallets = validate_config(cfg)
    interval = int(os.environ.get("POLL_INTERVAL_SECONDS",
                                  cfg.get("poll_interval_seconds", 3600)))
    if interval < 60 or interval > 86_400:
        raise ValueError("poll interval must be between 60 and 86400 seconds")
    enable_consolidation, enable_staking = automation_flags(cfg)

    log.info("=" * 70)
    log.info("Salvium auto-staker starting (v2: CLI stake executor)")
    log.info("  wallets       : %s", ", ".join(w["name"] for w in wallets))
    log.info("  poll interval : %ds", interval)
    log.info("  consolidation : %s", "ENABLED" if enable_consolidation else "disabled")
    log.info("  staking       : %s", "ENABLED" if enable_staking else "disabled")
    log.info("  staking       : delegated to stake-executor.sh (host cron); "
             "consolidation via sweep_all RPC")
    if not enable_consolidation and not enable_staking:
        log.info("  SAFE OBSERVE MODE: no transaction will be built or broadcast.")
    log.info("=" * 70)
    audit("startup", "-", enable_consolidation=enable_consolidation,
          enable_staking=enable_staking, interval=interval,
          wallets=[w["name"] for w in wallets])
    write_heartbeat("starting")

    while _running:
        state = load_state()
        failures = 0
        for w in wallets:
            if not _running:
                break
            try:
                process_wallet(w, state, enable_consolidation, enable_staking)
            except requests.RequestException as e:
                failures += 1
                log.warning("[%s] wallet-rpc unreachable this cycle: %s",
                            w.get("name", "?"), e)
                audit("rpc_unreachable", w.get("name", "?"), error=str(e))
            except RPCError as e:
                failures += 1
                log.error("[%s] RPC error: %s", w.get("name", "?"), e)
                audit("rpc_error", w.get("name", "?"), error=str(e))
            except Exception as e:  # never let one wallet kill the loop
                failures += 1
                log.exception("[%s] unexpected error: %s", w.get("name", "?"), e)
                audit("unexpected_error", w.get("name", "?"), error=str(e))
        save_state(state)
        write_heartbeat("ok" if failures == 0 else "degraded", failures)

        if not _running:
            break
        # Sleep in short slices so SIGTERM is responsive.
        slept = 0
        while _running and slept < interval:
            time.sleep(min(5, interval - slept))
            slept += 5

    log.info("staker stopped cleanly")


if __name__ == "__main__":
    main()
