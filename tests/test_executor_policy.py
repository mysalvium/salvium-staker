import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]


class ExecutorPolicyTests(unittest.TestCase):
    def test_root_cron_installs_an_immutable_copy(self):
        installer = (ROOT / "scripts" / "install-executor.sh").read_text()
        self.assertIn("/mnt/sharedrive/salvium-private/operations", installer)
        self.assertIn("-m 0750 -o root -g root", installer)
        self.assertIn("require_trivial_acl", installer)

    def test_executor_rejects_nontrivial_acls(self):
        executor = (ROOT / "stake-executor.sh").read_text()
        self.assertIn("nfs4xdr_getfacl", executor)
        self.assertIn("# trivial_acl: true", executor)
        self.assertIn("path_has_trivial_acl", executor)
        self.assertLess(
            executor.index('if ! path_has_trivial_acl "$EXECUTOR_CONFIG"'),
            executor.index('. "$EXECUTOR_CONFIG"'),
        )

    def test_private_runtime_is_outside_the_shared_apps_tree(self):
        environment = (ROOT / ".env.example").read_text()
        self.assertIn("STACK_DIR=/mnt/sharedrive/salvium-private/staker", environment)
        self.assertNotIn("STACK_DIR=/mnt/sharedrive/apps/", environment)

    def test_backup_rejects_unsafe_acl_boundaries(self):
        backup = (ROOT / "scripts" / "backup.sh").read_text()
        self.assertIn('require_trivial_acl "$STACK"', backup)
        self.assertIn('require_trivial_acl "$DESTINATION"', backup)
        self.assertIn('stat -c \'%u:%g:%a\'', backup)
        self.assertIn('require_trivial_acl "$backup_file"', backup)

    def test_one_shot_container_is_constrained(self):
        executor = (ROOT / "stake-executor.sh").read_text()
        for required in (
            "--user 1000:1000",
            "--read-only",
            "--cap-drop ALL",
            "--security-opt no-new-privileges:true",
            "--pids-limit 128",
            "--memory 1g",
        ):
            self.assertIn(required, executor)

    def test_compose_has_no_docker_socket(self):
        compose = (ROOT / "docker-compose.yml").read_text()
        self.assertNotIn("/var/run/docker.sock", compose)


if __name__ == "__main__":
    unittest.main()
