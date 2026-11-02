#!/usr/bin/env python3
"""Run the maintenance CLI without cluster access; guard removed backup commands."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MaintenanceContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.calls = self.directory / "calls"
        # Deliberately intercept all cluster calls. Removed commands must not call it.
        kubectl = self.directory / "kubectl"
        kubectl.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\n')
        kubectl.chmod(0o700)
        self.env = {
            "PATH": f"{self.directory}:{os.environ['PATH']}",
            "ENV_FILE": "/dev/null",
            "CALLS": str(self.calls),
            "HERMES_NAMESPACE": "hermes",
        }

    def run_cli(self, *args):
        return subprocess.run(
            ["bash", str(ROOT / "maintain.sh"), *args], env=self.env,
            text=True, capture_output=True, timeout=15,
        )

    def test_removed_commands_rejected_without_cluster_or_file_changes(self):
        archive = self.directory / "existing.age"
        archive.write_bytes(b"operator-owned archive")
        for command in ("backup", "restore", "extract"):
            for options in ([], ["--data-only"], ["--full", "--dry-run"], ["--password-stdin"]):
                with self.subTest(command=command, options=options):
                    result = self.run_cli(command, str(archive), *options)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"unknown command: {command}", result.stderr)
                    self.assertFalse(self.calls.exists())
                    self.assertEqual(archive.read_bytes(), b"operator-owned archive")

    def test_help_has_only_supported_commands(self):
        result = self.run_cli("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        for command in ("backup", "restore", "extract"):
            self.assertNotIn(f"./maintain.sh {command}", result.stdout)
        for option in ("--data-only", "--password-file", "--password-stdin", "--full", "--component"):
            self.assertNotIn(option, result.stdout)
        for command in ("status", "restart", "upgrade", "show-passwords", "rotate-passwords",
                        "rotate-browser-token", "reconcile-api-key", "reconcile-browser-token"):
            self.assertIn(f"./maintain.sh {command}", result.stdout)
        self.assertFalse(self.calls.exists())

    def test_status_restart_upgrade_preserve_namespace_and_enabled_set(self):
        self.env.update(HERMES_DASHBOARD_ENABLED="false", HERMES_WEBUI_ENABLED="false",
                        HERMES_BROWSER_ENABLED="false")
        for command in ("status", "restart", "upgrade"):
            result = self.run_cli(command)
            self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(calls, [
            "-n hermes get pods,svc,ingress,networkpolicy -o wide",
            "-n hermes rollout restart deploy/hermes-agent",
            "-n hermes rollout status deploy/hermes-agent --timeout=600s",
            "-n hermes rollout restart deploy/hermes-agent",
            "-n hermes rollout status deploy/hermes-agent --timeout=600s",
        ])


if __name__ == "__main__":
    unittest.main()
