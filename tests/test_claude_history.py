import contextlib
import io
import json
import os
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

import mcpbar

SESSION = "d4eb8e64-a4ad-4a70-a98f-1b9eda3808b5"
PROMPT = "private user prompt"


def message(kind, cwd="/tmp/control-bar", branch="main", entrypoint="cli", **extra):
    record = {"type": kind, "cwd": cwd, "gitBranch": branch, "entrypoint": entrypoint,
              "sessionId": SESSION, "isSidechain": False}
    if kind == "user":
        record["message"] = {"role": "user", "content": PROMPT}
    record.update(extra)
    return record


class ClaudeHistory(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        claude = os.path.join(temp.name, ".claude")
        self.projects = os.path.join(claude, "projects")
        root = os.path.join(claude, "control-bar")
        self.path = os.path.join(root, "history.json")
        for patch in (mock.patch.object(mcpbar, "CLAUDE", claude), mock.patch.object(mcpbar, "ROOT", root)):
            self.addCleanup(patch.stop)
            patch.start()
        self.clock = 1_700_000_000

    def transcript(self, records, session=SESSION, project="-tmp-control-bar", padding=0):
        folder = os.path.join(self.projects, project)
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, session + ".jsonl")
        lines = [json.dumps(r) for r in records[:1]]
        # Filler between the head and the tail, the way a long conversation pushes its first and
        # last lines more than one read window apart.
        lines += [json.dumps({"type": "attachment", "attachment": "x" * 1000})] * padding
        lines += [json.dumps(r) for r in records[1:]]
        with open(path, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        self.clock += 10
        os.utime(path, (self.clock, self.clock))
        return path

    def history(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(mcpbar.main(["claude-history"]), 0)
        self.assertEqual(output.getvalue(), "")
        return mcpbar.read_json(self.path)

    def test_records_metadata_without_prompt_text(self):
        self.transcript([
            {"type": "queue-operation", "operation": "enqueue", "content": PROMPT, "sessionId": SESSION},
            message("user", branch="main"),
            message("assistant", branch="feature/history"),
            {"type": "custom-title", "customTitle": "  Fix\nlimits  ", "sessionId": SESSION},
            {"type": "last-prompt", "lastPrompt": PROMPT, "sessionId": SESSION},
        ])
        history = self.history()
        self.assertEqual(history, {"threads": [{
            "id": SESSION, "name": "Fix limits", "cwd": "/tmp/control-bar",
            "updatedAt": self.clock, "branch": "feature/history", "source": "cli",
        }], "hasMore": False})
        with open(self.path) as fh:
            self.assertNotIn(PROMPT, fh.read())
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)

    def test_title_follows_claude_code_resume_order(self):
        cases = [
            ([{"type": "summary", "summary": "Summary"}], "Summary"),
            ([{"type": "summary", "summary": "Summary"}, {"type": "ai-title", "aiTitle": "AI"}], "AI"),
            ([{"type": "ai-title", "aiTitle": "AI"}, {"type": "custom-title", "customTitle": "Mine"}], "Mine"),
            ([{"type": "custom-title", "customTitle": "Mine"}, {"type": "agent-name", "agentName": "Agent"}], "Agent"),
            ([{"type": "custom-title", "customTitle": "Old"}, {"type": "custom-title", "customTitle": "New"}], "New"),
            ([], ""),
        ]
        for index, (titles, expected) in enumerate(cases):
            self.transcript([message("user")] + titles, session=f"00000000-0000-4000-8000-{index:012d}")
        names = {row["id"]: row["name"] for row in self.history()["threads"]}
        self.assertEqual([names[f"00000000-0000-4000-8000-{i:012d}"] for i in range(len(cases))],
                         [expected for _, expected in cases])

    def test_long_transcript_reads_head_and_tail_only(self):
        path = self.transcript([
            message("user", cwd="/tmp/start", branch="main"),
            message("assistant", cwd="/tmp/start/sub", branch="later"),
            {"type": "custom-title", "customTitle": "Tail title", "sessionId": SESSION},
        ], padding=400)
        self.assertGreater(os.path.getsize(path), 4 * mcpbar.CLAUDE_HISTORY_WINDOW)
        row = self.history()["threads"][0]
        self.assertEqual((row["name"], row["cwd"], row["branch"]), ("Tail title", "/tmp/start", "later"))

    def test_conversation_whose_messages_sit_between_the_windows_is_kept(self):
        filler = {"type": "attachment", "attachment": "x" * 1000, "cwd": "/tmp/early", "entrypoint": "cli"}
        path = self.transcript([filler] * 80 + [message("user", cwd="/tmp/late", branch="mid")]
                               + [{"type": "queue-operation", "operation": "x" * 1000}] * 80
                               + [{"type": "custom-title", "customTitle": "Middle", "sessionId": SESSION}])
        self.assertGreater(os.path.getsize(path), 2 * mcpbar.CLAUDE_HISTORY_WINDOW)
        row = self.history()["threads"][0]
        self.assertEqual((row["name"], row["cwd"], row["branch"]), ("Middle", "/tmp/early", "mid"))

    def test_record_starting_exactly_at_the_tail_window_is_read(self):
        path = self.transcript([message("user")], padding=200)
        title = json.dumps({"type": "custom-title", "customTitle": "Edge", "sessionId": SESSION}) + "\n"
        with open(path, "a") as fh:
            fh.write(title)
            fh.write("y" * (mcpbar.CLAUDE_HISTORY_WINDOW - len(title) - 1) + "\n")
        self.assertEqual(self.history()["threads"][0]["name"], "Edge")

    def test_a_session_copied_into_two_folders_is_listed_once(self):
        self.transcript([message("user"), {"type": "custom-title", "customTitle": "Old copy"}], project="-tmp-a")
        self.transcript([message("user"), {"type": "custom-title", "customTitle": "New copy"}], project="-tmp-b")
        self.assertEqual([row["name"] for row in self.history()["threads"]], ["New copy"])

    def test_files_that_are_not_sessions_do_not_use_up_the_scan(self):
        self.transcript([message("user")])
        for index in range(mcpbar.CLAUDE_HISTORY_SCAN + 1):
            self.transcript([message("user")], session=f"agent-{index}")
        history = self.history()
        self.assertEqual([row["id"] for row in history["threads"]], [SESSION])
        self.assertFalse(history["hasMore"])

    @unittest.skipIf(os.geteuid() == 0, "root reads any folder")
    def test_unreadable_projects_folder_fails_and_keeps_the_previous_snapshot(self):
        mcpbar.write_json(self.path, {"threads": [{"id": "kept"}], "hasMore": False})
        os.makedirs(self.projects)
        os.chmod(self.projects, 0)
        self.addCleanup(os.chmod, self.projects, 0o700)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(mcpbar.main(["claude-history"]), 1)
        self.assertEqual(mcpbar.read_json(self.path)["threads"], [{"id": "kept"}])

    def test_relocated_project_wins_over_the_first_directory(self):
        self.transcript([message("user", cwd="/tmp/old"),
                         {"type": "relocated", "relocatedCwd": "/tmp/new", "sessionId": SESSION}])
        self.assertEqual(self.history()["threads"][0]["cwd"], "/tmp/new")

    def test_client_comes_from_the_entrypoint(self):
        for index, entrypoint in enumerate(("cli", "claude-desktop", "t3-code", "claude-vscode", "future")):
            self.transcript([message("user", entrypoint=entrypoint)],
                            session=f"00000000-0000-4000-8000-{index:012d}")
        self.assertEqual([row["source"] for row in reversed(self.history()["threads"])],
                         ["cli", "app", "t3", "ide", ""])

    def test_skips_automation_bookkeeping_subagents_and_foreign_folders(self):
        keep = "00000000-0000-4000-8000-000000000001"
        self.transcript([message("user")], session=keep)
        self.transcript([message("user", entrypoint="sdk-ts")], session="00000000-0000-4000-8000-000000000002")
        self.transcript([{"type": "custom-title", "customTitle": "Only bookkeeping", "sessionId": SESSION}],
                        session="00000000-0000-4000-8000-000000000003")
        self.transcript([message("user")], session="00000000-0000-4000-8000-000000000004",
                        project="codex-migration-legacy-worktrees-20261113")
        self.transcript([message("user")], session="agent-not-a-session")
        self.transcript([message("user")], session="00000000-0000-4000-8000-000000000005",
                        project=os.path.join("-tmp-control-bar", keep, "subagents"))
        self.assertEqual([row["id"] for row in self.history()["threads"]], [keep])

    def test_page_is_bounded_and_marks_more(self):
        for index in range(mcpbar.CLAUDE_HISTORY_LIMIT + 1):
            self.transcript([message("user")], session=f"00000000-0000-4000-8000-{index:012d}")
        history = self.history()
        self.assertEqual(len(history["threads"]), mcpbar.CLAUDE_HISTORY_LIMIT)
        self.assertEqual(history["threads"][0]["id"], f"00000000-0000-4000-8000-{mcpbar.CLAUDE_HISTORY_LIMIT:012d}")
        self.assertTrue(history["hasMore"])

    def test_missing_projects_folder_is_an_empty_history(self):
        self.assertEqual(self.history(), {"threads": [], "hasMore": False})

    def test_write_failure_is_a_nonzero_exit(self):
        with mock.patch.object(mcpbar, "write_json", side_effect=OSError("private path")), \
                contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(mcpbar.main(["claude-history"]), 1)
        self.assertEqual(stderr.getvalue(), "Could not refresh Claude history\n")


if __name__ == "__main__":
    unittest.main()
