"""Exercise the installed starter's observable systemd contract without a desktop."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


STARTER = Path(__file__).resolve().parents[1] / "packaging/omastation/omastation-session-start"


class LoginStart(unittest.TestCase):
    def test_stopping_idle_listener_does_not_recover_another_servers_desktop(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker_dir = Path(tmp) / "omastation"
            marker_dir.mkdir()
            marker = marker_dir / "login-recover-other-invocation"
            marker.touch()
            env = dict(os.environ, XDG_RUNTIME_DIR=tmp, INVOCATION_ID="this-invocation", PATH="/no/commands")
            result = subprocess.run(["/bin/bash", str(STARTER.with_name("omastation-login-recover"))],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(marker.exists())

    def run_starter(self, scenario):
        with tempfile.TemporaryDirectory(prefix="omastation-login-") as tmp:
            root = Path(tmp)
            instances = [{"instance": "abc_123", "wl_socket": "wayland-1"}]
            (root / "existing").write_text(json.dumps(instances))
            for command, text in {
                "hyprctl": '''#!/bin/bash
if [[ $SCENARIO == ambiguous ]]; then echo '[{},{}]'
elif [[ $SCENARIO == existing || -f $TEST_ROOT/started && $SCENARIO == fresh ]]; then cat "$TEST_ROOT/existing"
elif [[ $SCENARIO == empty_bug ]]; then printf '\n]\n'
else echo '[]'; fi
''',
                "systemctl": '''#!/bin/bash
printf '%s\\n' "$*" >> "$TEST_ROOT/calls"
if [[ $* == *is-failed* ]]; then [[ $SCENARIO == failed ]]; exit; fi
touch "$TEST_ROOT/started"
[[ $SCENARIO != denied && $SCENARIO != empty_bug ]]
''',
            }.items():
                p = root / command
                p.write_text(text)
                p.chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                       SCENARIO=scenario, TEST_ROOT=str(root), XDG_RUNTIME_DIR=tmp)
            result = subprocess.run([str(STARTER)], env=env, capture_output=True,
                                    text=True, timeout=5)
            calls = (root / "calls").read_text() if (root / "calls").exists() else ""
            return result, calls

    def test_existing_session_does_not_start_another(self):
        result, calls = self.run_starter("existing")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "abc_123\nwayland-1\n")
        self.assertEqual(calls, "")

    def test_missing_session_starts_only_the_callers_fixed_unit(self):
        result, calls = self.run_starter("fresh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "abc_123\nwayland-1\n")
        user = subprocess.check_output(["id", "-un"], text=True).strip()
        self.assertEqual(calls, f"--no-ask-password --no-block start omastation-session@{user}.service\n")

    def test_denied_or_failed_start_is_not_success(self):
        for scenario in ("denied", "failed"):
            with self.subTest(scenario=scenario):
                result, _ = self.run_starter(scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_hyprctl_empty_array_bug_still_attempts_start(self):
        result, calls = self.run_starter("empty_bug")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("start omastation-session@", calls)
        self.assertNotIn("parse error", result.stderr)

    def test_multiple_sessions_are_refused_without_starting_anything(self):
        result, calls = self.run_starter("ambiguous")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(calls, "")


if __name__ == "__main__":
    unittest.main()
