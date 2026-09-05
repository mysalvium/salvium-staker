import importlib.util
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SOURCE = Path(__file__).parents[1] / "orchestrator" / "staker.py"
SPEC = importlib.util.spec_from_file_location("staker", SOURCE)
staker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(staker)


def valid_config():
    return {
        "poll_interval_seconds": 600,
        "wallets": [
            {
                "name": "miner",
                "rpc_url": "http://wallet-rpc-miner:18082/json_rpc",
                "rpc_password_file": "/run/secrets/miner_rpc_password",
                "account_index": 0,
                "min_stake_sal": 1,
                "stake_fee_reserve_sal": 0.1,
                "consolidate_when_outputs_over": 25,
                "stake_when_single_output_over_sal": 15,
            }
        ],
    }


class FakeRPC:
    instances = []

    def __init__(self, *_args, **_kwargs):
        self.calls = []
        self.__class__.instances.append(self)

    def call(self, method, params=None):
        self.calls.append((method, params))
        if method == "get_height":
            return {"height": 500_000}
        if method == "get_accounts":
            return {
                "subaddress_accounts": [
                    {
                        "account_index": 0,
                        "base_address": "own-address",
                        "balance": 2_000_000_000,
                        "unlocked_balance": 2_000_000_000,
                    }
                ]
            }
        if method == "get_transfers":
            return {}
        if method == "incoming_transfers":
            return {
                "transfers": [
                    {"amount": 100_000_000, "spent": False, "unlocked": True}
                    for _ in range(26)
                ]
            }
        if method == "sweep_all":
            return {"tx_hash_list": [], "amount_list": [], "fee_list": []}
        raise AssertionError(f"unexpected RPC call: {method}")


class StakerTests(unittest.TestCase):
    def setUp(self):
        FakeRPC.instances.clear()

    def test_public_defaults_are_observe_only(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(staker.automation_flags(valid_config()), (False, False))

    def test_legacy_dry_run_false_keeps_existing_live_behavior(self):
        with patch.dict(os.environ, {"DRY_RUN": "false"}, clear=True):
            self.assertEqual(staker.automation_flags(valid_config()), (True, True))

    def test_explicit_flags_override_legacy_setting(self):
        env = {
            "DRY_RUN": "false",
            "ENABLE_CONSOLIDATION": "false",
            "ENABLE_STAKING": "true",
        }
        with patch.dict(os.environ, env, clear=True):
            self.assertEqual(staker.automation_flags(valid_config()), (False, True))

    def test_config_rejects_path_traversal_name(self):
        config = valid_config()
        config["wallets"][0]["name"] = "../miner"
        with self.assertRaises(ValueError):
            staker.validate_config(config)

    def test_config_rejects_secret_outside_secret_mount(self):
        config = valid_config()
        config["wallets"][0]["rpc_password_file"] = "/logs/not-a-secret"
        with self.assertRaises(ValueError):
            staker.validate_config(config)

    def test_disabled_consolidation_never_calls_sweep(self):
        state = {}
        with patch.object(staker, "WalletRPC", FakeRPC), patch.object(
            staker, "read_secret", return_value="test"
        ):
            staker.process_wallet(valid_config()["wallets"][0], state, False, False)
        methods = [method for method, _ in FakeRPC.instances[0].calls]
        self.assertNotIn("sweep_all", methods)

    def test_enabled_consolidation_sweeps_only_to_own_address(self):
        state = {}
        with patch.object(staker, "WalletRPC", FakeRPC), patch.object(
            staker, "read_secret", return_value="test"
        ):
            staker.process_wallet(valid_config()["wallets"][0], state, True, False)
        sweep = [params for method, params in FakeRPC.instances[0].calls if method == "sweep_all"]
        self.assertEqual(len(sweep), 1)
        self.assertEqual(sweep[0]["address"], "own-address")
        self.assertFalse(sweep[0]["do_not_relay"])

    def test_stake_request_is_atomic_and_private(self):
        with tempfile.TemporaryDirectory() as directory:
            old_log_dir = staker.LOG_DIR
            try:
                staker.LOG_DIR = Path(directory)
                staker.write_stake_request("miner", 123_000_000, 124_000_000)
                request = Path(directory) / "stake-request-miner.json"
                self.assertTrue(request.is_file())
                if os.name != "nt":
                    self.assertEqual(stat.S_IMODE(request.stat().st_mode), 0o600)
            finally:
                staker.LOG_DIR = old_log_dir


if __name__ == "__main__":
    unittest.main()
