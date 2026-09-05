import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]


class ExecutorPolicyTests(unittest.TestCase):
    def test_root_cron_installs_an_immutable_copy(self):
        installer = (ROOT / "scripts" / "install-executor.sh").read_text()
        self.assertIn("/mnt/sharedrive/apps/salvium/data/operations", installer)
        self.assertIn("-m 0750 -o root -g root", installer)

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
