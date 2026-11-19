import contextlib
import io
import os
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

import mcpbar


class CodexHistory(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = os.path.join(temp.name, "control-bar")
        codex_root = os.path.join(root, "codex")
        self.path = os.path.join(codex_root, "history.json")
        self.enter_patch(mock.patch.object(mcpbar, "ROOT", root))
        self.enter_patch(mock.patch.object(mcpbar.codex, "CODEX_ROOT", codex_root))
        self.rpc = self.enter_patch(mock.patch.object(mcpbar.codex, "codex_rpc"))

    def enter_patch(self, patch):
        self.addCleanup(patch.stop)
        return patch.start()

    def test_command_requests_read_only_metadata_and_hides_prompt(self):
        self.rpc.return_value = ({"data": [{
            "id": "d4eb8e64-a4ad-4a70-a98f-1b9eda3808b5", "name": None,
            "preview": "private user prompt", "cwd": "/tmp/control-bar",
            "updatedAt": 1700000000, "gitInfo": {"branch": "history"}, "source": "cli",
            "modelProvider": "deepseek",
        }], "nextCursor": "next"}, None)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(mcpbar.main(["codex-history"]), 0)
        args, options = self.rpc.call_args
        self.assertEqual(args[0], "thread/list")
        self.assertTrue(options["read_only"])
        self.assertEqual(args[1]["limit"], 50)
        self.assertEqual(args[1]["sortKey"], "updated_at")
        self.assertEqual(args[1]["modelProviders"], [])
        self.assertTrue(args[1]["currentAccountOnly"])
        self.assertTrue(args[1]["useStateDbOnly"])
        self.assertEqual(options["min_version"], (0, 168, 0))
        history = mcpbar.read_json(self.path)
        self.assertEqual(history["threads"], [{
            "id": "d4eb8e64-a4ad-4a70-a98f-1b9eda3808b5", "name": "",
            "cwd": "/tmp/control-bar", "updatedAt": 1700000000,
            "branch": "history", "source": "cli", "modelService": "deepseek",
        }])
        self.assertTrue(history["hasMore"])
        home = os.environ.get("CODEX_HOME") or mcpbar.codex.CODEX
        self.assertEqual(history["codexHome"], os.path.realpath(os.path.expanduser(home)))
        self.assertNotIn("private user prompt", output.getvalue())
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)

    def test_failed_refresh_replaces_previous_snapshot(self):
        mcpbar.write_json(self.path, {"threads": [{"id": "stale"}], "hasMore": True})
        self.rpc.return_value = (None, "timeout")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(mcpbar.main(["codex-history"]), 0)
        self.assertEqual(mcpbar.read_json(self.path), {"threads": [], "hasMore": False, "error": "timeout"})

    def test_write_failure_is_a_nonzero_exit(self):
        self.rpc.return_value = ({"data": []}, None)
        with mock.patch.object(mcpbar, "write_json", side_effect=OSError("private path")), \
                contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(mcpbar.main(["codex-history"]), 1)
        self.assertEqual(stderr.getvalue(), "Could not save Codex history\n")

    def test_source_uses_the_client_identity_when_codex_reports_generic_vscode(self):
        self.rpc.return_value = ({"data": [
            {"id": str(i), "updatedAt": 1700000000, "source": "vscode", "originator": originator}
            for i, originator in enumerate(("T3 Code", "Codex Desktop", "codex-tui", "codex_vscode", "unknown"))
        ]}, None)
        self.assertEqual(mcpbar.main(["codex-history"]), 0)
        self.assertEqual([row["source"] for row in mcpbar.read_json(self.path)["threads"]],
                         ["t3", "app", "cli", "ide", "vscode"])

    def test_parent_link_hides_subagents_while_manual_forks_stay_visible(self):
        info = {"source": "vscode", "updatedAt": 1700000000}
        self.rpc.return_value = ({"data": [
            dict(info, id="worker", parentThreadId="main"),
            dict(info, id="analytics-worker", threadSource="subagent"),
            dict(info, id="fork", forkedFromId="main"),
        ]}, None)
        self.assertEqual(mcpbar.main(["codex-history"]), 0)
        self.assertEqual([row["id"] for row in mcpbar.read_json(self.path)["threads"]], ["fork"])

    def test_model_provider_mapping_uses_exact_provider_ids(self):
        self.rpc.return_value = ({"data": [
            {"id": str(i), "updatedAt": 1700000000, "source": "cli", "modelProvider": provider}
            for i, provider in enumerate(("openai", "ZAI", "openrouter", "deepseek-proxy", None))
        ]}, None)
        self.assertEqual(mcpbar.main(["codex-history"]), 0)
        self.assertEqual([row["modelService"] for row in mcpbar.read_json(self.path)["threads"]],
                         ["openai", "zai", "openrouter", "custom", "openai"])


class CodexHistoryCompatibility(unittest.TestCase):
    def test_old_app_server_refuses_the_request_before_listing_history(self):
        with tempfile.TemporaryDirectory() as temp:
            binary = os.path.join(temp, "codex")
            with open(binary, "w") as fh:
                fh.write('''#!/usr/bin/python3
import json, sys
sys.stdin.readline()
print(json.dumps({"id": 1, "result": {"userAgent": "claude-control-bar/0.167.0 (Mac OS)"}}), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    if request.get("method") == "thread/list":
        print(json.dumps({"id": 2, "result": {"data": []}}), flush=True)
''')
            os.chmod(binary, 0o700)
            with mock.patch.object(mcpbar.codex, "find_codex", return_value=binary):
                self.assertEqual(mcpbar.codex.codex_rpc("thread/list", timeout=1, read_only=True,
                                                       min_version=(0, 168, 0)), (None, "upgrade_required"))
