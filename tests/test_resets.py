#!/usr/bin/env python3
"""Погашение накопленных сбросов лимитов: `claude-reset-credit <id>` и `codex-reset-credit`.

Погашение тратит сброс на настоящем аккаунте, поэтому здесь нет ни одного настоящего адреса:
Anthropic изображает локальный HTTP-сервер, Codex — подставной исполняемый файл. Каждый случай —
защита, без которой повтор, двойной запуск или сбой сети стоил бы человеку второго сброса.
"""

import contextlib
import fcntl
import http.server
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import threading
import time
import types
import unittest
import uuid
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

import mcpbar  # noqa: E402
import mcpbar_codex  # noqa: E402
import mcpbar_resets  # noqa: E402
from test_account import (CODEX_ACCOUNT_REPLY, CODEX_LIMITS_REPLY, READ_ONLY_ARGV,  # noqa: E402
                          fake_codex_calls, write_fake_codex)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOKEN = "SECRET-TOKEN"
USAGE = {
    "five_hour": {"utilization": 100, "resets_at": None},
    "cedar_ember": {"eligible": True, "next_grant_id": "weekly_a", "grants": [
        {"id": "weekly_a", "resets_left": 1, "usable_now": True, "clears": ["seven_day"]},
        {"id": "session_a", "resets_left": 1, "usable_now": True, "type": "session"}]},
}
CLAIM_PATH = "/api/organizations/{organization}/reset_rate_limits"


class Anthropic(http.server.BaseHTTPRequestHandler):
    """Подставной api.anthropic.com: GET — опрос лимитов, POST — погашение сброса."""

    def answer(self, status, body):
        raw = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self.server.gets.append(self.path)
        self.answer(*self.server.usage)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.server.posts.append({"path": self.path, "body": json.loads(body),
                                  "headers": {key.lower(): value for key, value in self.headers.items()}})
        if self.server.claim == "drop":
            self.close_connection = True
        elif self.server.claim == "hang":
            self.server.release.wait(10)
            self.close_connection = True
        else:
            self.answer(*self.server.claim)

    def log_message(self, *args):
        pass


class ClaudeResetCredit(unittest.TestCase):
    def setUp(self):
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Anthropic)
        self.server.daemon_threads = True
        self.server.usage, self.server.claim = (200, USAGE), (200, {"result": "reset"})
        self.server.gets, self.server.posts, self.server.release = [], [], threading.Event()
        # Частый опрос остановки: со стандартным каждый тест ждал бы shutdown() полсекунды.
        threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.02},
                         daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.addCleanup(self.server.release.set)
        self.base = "http://127.0.0.1:%d" % self.server.server_address[1]

        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = os.path.join(temp.name, "control-bar")
        self.config = os.path.join(temp.name, "claude.json")
        self.set_config({"oauthAccount": {"organizationUuid": "org-uuid-1", "emailAddress": "user@example.com"}})
        self.claude = os.path.join(temp.name, "claude")
        self.set_claude("echo '2.1.328 (Claude Code)'")
        self.token = lambda: TOKEN
        for target, name, value in (
                (mcpbar, "ROOT", self.root), (mcpbar, "CONFIG", self.config),
                (mcpbar, "LIMITS", os.path.join(self.root, "limits.json")),
                (mcpbar, "LIMITS_STATUS", os.path.join(self.root, "limits-status.json")),
                (mcpbar, "USAGE_URL", self.base + "/api/oauth/usage?cedar_ember=1"),
                (mcpbar, "oauth_token", lambda: self.token()),
                (mcpbar, "find_claude", lambda: self.claude),
                (mcpbar_resets, "RESET_URL", self.base + CLAIM_PATH)):
            patch = mock.patch.object(target, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        mcpbar.OAUTH_FACTS.clear()
        self.addCleanup(mcpbar.OAUTH_FACTS.clear)
        self.printed = ""
        # Что бы тест ни делал, токен не должен остаться ни в одном файле и ни в одной строке вывода.
        self.addCleanup(self.assert_token_stayed_in_the_header)
        # Варианты сбросов публикует настоящий опрос — по его файлу команда и сверяет запрошенный id.
        self.run_command(["limits"])
        self.server.gets.clear()

    def set_config(self, value):
        with open(self.config, "w") as fh:
            fh.write(value if isinstance(value, str) else json.dumps(value))

    def set_claude(self, line):
        with open(self.claude, "w") as fh:
            fh.write("#!/bin/sh\n" + line + "\n")
        os.chmod(self.claude, 0o700)

    def run_command(self, argv):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            code = mcpbar.main(argv)
        self.printed += output.getvalue()
        return code

    def redeem(self, credit="weekly_a"):
        return self.run_command(["claude-reset-credit", credit])

    def path(self, name):
        return os.path.join(self.root, name)

    def result(self):
        return mcpbar.read_json(self.path("reset-credit-result.json"))

    def pending(self):
        return mcpbar.read_json(self.path("reset-credit-pending.json"))

    def forget(self):
        """Чистый лист между случаями одной таблицы."""
        for name in ("reset-credit-result.json", "reset-credit-pending.json"):
            if os.path.exists(self.path(name)):
                os.unlink(self.path(name))
        del self.server.gets[:], self.server.posts[:]

    def assert_token_stayed_in_the_header(self):
        stored = ""
        for directory, _, names in os.walk(self.root):
            for name in names:
                with open(os.path.join(directory, name)) as fh:
                    stored += fh.read()
        self.assertNotIn(TOKEN, stored + self.printed)

    def assert_nothing_was_sent(self):
        self.assertEqual((self.server.posts, self.server.gets), ([], []))

    def test_reset_sends_the_claim_exactly_as_t3_does(self):
        started = int(time.time())
        self.assertEqual(self.redeem(), 0)
        self.assertEqual(len(self.server.posts), 1)
        post = self.server.posts[0]
        self.assertEqual(post["path"], "/api/organizations/org-uuid-1/reset_rate_limits")
        self.assertEqual(post["headers"]["authorization"], "Bearer " + TOKEN)
        self.assertEqual(post["headers"]["anthropic-beta"], "oauth-2025-04-20")
        self.assertEqual(post["headers"]["user-agent"], "claude-cli/2.1.328 (external, cli)")
        self.assertEqual(post["headers"]["content-type"], "application/json")
        self.assertEqual(set(post["body"]), {"program", "grant_id", "request_id"})
        self.assertEqual((post["body"]["program"], post["body"]["grant_id"]), ("cedar_ember", "weekly_a"))
        self.assertEqual(uuid.UUID(post["body"]["request_id"]).version, 4)
        result = self.result()
        self.assertGreaterEqual(result.pop("ts"), started)
        self.assertEqual(result, {"provider": "claude", "creditId": "weekly_a", "outcome": "reset",
                                  "error": None, "confirmed": True})
        self.assertEqual(self.server.gets, ["/api/oauth/usage?cedar_ember=1"], "ровно один повторный опрос")
        self.assertIsNone(self.pending(), "определённый ответ освобождает ключ")
        for name in ("reset-credit-result.json", "reset-credit.lock", "account.json"):
            self.assertEqual(stat.S_IMODE(os.stat(self.path(name)).st_mode), 0o600, name)
        self.assertEqual(stat.S_IMODE(os.stat(self.root).st_mode), 0o700)
        os.makedirs(os.path.join(REPO, "build", "seam"), exist_ok=True)
        shutil.copyfile(self.path("reset-credit-result.json"),
                        os.path.join(REPO, "build", "seam", "reset-credit-result.json"))

    def test_every_answer_becomes_an_outcome_or_a_fixed_category(self):
        # (ответ сервера) → (исход, категория ошибки, остался ли ключ)
        cases = (
            ((200, {"result": "reset"}), "reset", None, False),
            ((200, {"result": "not_limited"}), "nothingToReset", None, False),
            ((200, {"result": "already_used"}), "alreadyRedeemed", None, False),
            ((200, {"result": "ineligible"}), "noCredit", None, False),
            # Остывание и лимит запросов — тоже ответ: заявка точно не принята.
            ((200, {"result": "cooldown"}), None, "coolingDown", False),
            ((429, {"error": "slow down"}), None, "rateLimited", False),
            ((401, {}), None, "signedOut", False),
            ((403, {}), None, "signedOut", False),
            # Всё, после чего неизвестно, дошла ли заявка, оставляет ключ для повтора.
            ((200, {"result": "unavailable"}), None, "unconfirmed", True),
            ((200, {"result": "surprise"}), None, "requestFailed", True),
            ((200, [1]), None, "requestFailed", True),
            ((200, b"not json"), None, "requestFailed", True),
            ((204, b""), None, "requestFailed", True),
            ((500, {"result": "reset"}), None, "requestFailed", True),
            ("drop", None, "requestFailed", True),
        )
        for claim, outcome, error, kept in cases:
            with self.subTest(claim=claim):
                self.forget()
                self.server.claim = claim
                self.assertEqual(self.redeem(), 0 if outcome else 1)
                result = self.result()
                self.assertEqual((result["outcome"], result["error"], result["confirmed"]),
                                 (outcome, error, outcome is not None))
                self.assertEqual(len(self.server.posts), 1)
                self.assertEqual(len(self.server.gets), 1 if outcome else 0,
                                 "лимиты перечитываются только после полученного исхода")
                self.assertEqual(self.pending() is not None, kept)
                if kept:
                    self.assertEqual(self.pending()["key"], self.server.posts[0]["body"]["request_id"])
                    self.assertEqual(stat.S_IMODE(os.stat(self.path("reset-credit-pending.json")).st_mode), 0o600)

    def test_wait_is_bounded_and_a_timeout_keeps_the_key(self):
        self.assertEqual(mcpbar_resets.CLAIM_TIMEOUT, 25)
        self.server.claim = "hang"
        started = time.monotonic()
        with mock.patch.object(mcpbar_resets, "CLAIM_TIMEOUT", 0.4):
            self.assertEqual(self.redeem(), 1)
        self.assertLess(time.monotonic() - started, 5)
        self.assertEqual((self.result()["outcome"], self.result()["error"]), (None, "requestFailed"))
        self.assertEqual(self.pending()["key"], self.server.posts[0]["body"]["request_id"])

    def test_key_is_written_before_sending_and_reused_until_a_definite_answer(self):
        seen = []
        real = mcpbar.no_redirect_opener

        def opener():
            # К моменту отправки ключ уже на диске: процесс, убитый посреди запроса, его не теряет.
            seen.append(self.pending())
            return real()

        self.server.claim = (200, {"result": "unavailable"})
        with mock.patch.object(mcpbar, "no_redirect_opener", opener):
            self.assertEqual(self.redeem(), 1)
        first = self.server.posts[0]["body"]["request_id"]
        self.assertEqual(seen[0]["key"], first)
        self.assertEqual(seen[0]["creditId"], "weekly_a")
        self.assertEqual(self.redeem(), 1)
        self.server.claim = (200, {"result": "already_used"})
        self.assertEqual(self.redeem(), 0)
        self.assertEqual([post["body"]["request_id"] for post in self.server.posts], [first] * 3)
        self.assertIsNone(self.pending())
        self.assertEqual(self.redeem(), 0)
        self.assertNotEqual(self.server.posts[3]["body"]["request_id"], first, "новая попытка — новый ключ")

    def test_stored_key_expires_after_24_hours(self):
        self.server.claim = (200, {"result": "unavailable"})
        now = time.time()
        for created, reused in ((now - 24 * 3600 + 60, True), (now - 24 * 3600 - 60, False),
                                (now + 3600, False), ("yesterday", False), (None, False)):
            with self.subTest(created=created):
                self.forget()
                mcpbar.write_json(self.path("reset-credit-pending.json"),
                                  {"key": "stored-key", "creditId": "weekly_a", "createdAt": created})
                self.redeem()
                sent = self.server.posts[0]["body"]["request_id"]
                self.assertEqual(sent == "stored-key", reused)
                self.assertEqual(self.pending()["key"], sent)
        for garbage in ({"key": "not a key!", "creditId": "weekly_a", "createdAt": now}, [1], "text"):
            with self.subTest(garbage=garbage):
                self.forget()
                mcpbar.write_json(self.path("reset-credit-pending.json"), garbage)
                self.redeem()
                self.assertEqual(uuid.UUID(self.server.posts[0]["body"]["request_id"]).version, 4)

    def test_key_of_one_grant_is_never_sent_with_another(self):
        self.server.claim = (200, {"result": "unavailable"})
        self.redeem("weekly_a")
        self.redeem("session_a")
        first, second = (post["body"] for post in self.server.posts)
        self.assertEqual((first["grant_id"], second["grant_id"]), ("weekly_a", "session_a"))
        self.assertNotEqual(first["request_id"], second["request_id"])
        self.assertEqual(self.pending()["creditId"], "session_a")

    def test_unpublished_credit_is_refused_without_any_request(self):
        for credit in ("grant_unknown", "", "weekly_a "):
            with self.subTest(credit=credit):
                self.forget()
                self.assertEqual(self.redeem(credit), 0)
                result = self.result()
                self.assertEqual((result["outcome"], result["error"]), ("noCredit", None))
                self.assert_nothing_was_sent()
                self.assertIsNone(self.pending())
        # Без опубликованных вариантов сверять не с чем — значит, и тратить нечего.
        for account in (None, "[]", '{"resetCredits": {"options": "weekly_a"}}',
                        '{"resetCredits": {"eligible": true, "availableCount": 0}}'):
            with self.subTest(account=account):
                self.forget()
                if account is None:
                    os.unlink(self.path("account.json"))
                else:
                    with open(self.path("account.json"), "w") as fh:
                        fh.write(account)
                self.assertEqual(self.redeem(), 0)
                self.assertEqual(self.result()["outcome"], "noCredit")
                self.assert_nothing_was_sent()

    def test_missing_argument_is_a_refusal_not_a_crash(self):
        self.assertEqual(self.run_command(["claude-reset-credit"]), 0)
        self.assertEqual((self.result()["outcome"], self.result()["creditId"]), ("noCredit", None))
        self.assert_nothing_was_sent()

    def test_malformed_credit_id_is_never_sent_even_when_published(self):
        mcpbar.write_json(self.path("account.json"), {"resetCredits": {"options": [
            {"creditId": "Bad Id!"}, {"creditId": "x" * 41}]}})
        for credit in ("Bad Id!", "x" * 41):
            with self.subTest(credit=credit):
                self.assertEqual(self.redeem(credit), 1)
                result = self.result()
                self.assertEqual((result["outcome"], result["error"], result["creditId"]),
                                 (None, "malformedCredit", None))
                self.assert_nothing_was_sent()
                self.assertIsNone(self.pending())

    def test_without_a_cli_version_nothing_is_sent(self):
        # Заявка не уходила — о сбросах ничего не известно. «Сброса нет» здесь было бы выдумкой:
        # это сбой, и ключ прошлой попытки он не трогает.
        stored = {"key": "stored-key", "creditId": "weekly_a", "createdAt": int(time.time())}
        for line in ("exit 3", "echo 'no version here'", "echo '2.1.328'; exit 1", None):
            with self.subTest(line=line):
                self.forget()
                mcpbar.write_json(self.path("reset-credit-pending.json"), stored)
                if line is None:
                    self.claude = None
                else:
                    self.set_claude(line)
                self.assertEqual(self.redeem(), 1)
                result = self.result()
                self.assertEqual((result["outcome"], result["error"], result["confirmed"]),
                                 (None, "cliUnavailable", False))
                self.assert_nothing_was_sent()
                self.assertEqual(self.pending(), stored)
        self.assertIn("claude-reset-credit: cliUnavailable", self.printed)

    def test_cli_that_hangs_on_version_is_a_failure_too(self):
        import subprocess

        with mock.patch.object(subprocess, "run", side_effect=subprocess.TimeoutExpired("claude", 10)):
            self.assertEqual(self.redeem(), 1)
        self.assertEqual((self.result()["outcome"], self.result()["error"]), (None, "cliUnavailable"))
        self.assert_nothing_was_sent()

    def test_version_is_read_the_way_t3_reads_it(self):
        for line, version in (("echo 'v3.4.5-beta (Claude Code)'", "3.4.5"),
                              ("echo 'warning' >&2; echo 'claude 10.20.30'", "10.20.30"),
                              ("echo '2.1.328 (Claude Code)' >&2", "2.1.328")):
            with self.subTest(line=line):
                self.forget()
                self.set_claude(line)
                self.redeem()
                self.assertEqual(self.server.posts[0]["headers"]["user-agent"],
                                 "claude-cli/%s (external, cli)" % version)

    def test_signed_out_sends_nothing_and_keeps_a_key_that_may_have_landed(self):
        stored = {"key": "stored-key", "creditId": "weekly_a", "createdAt": int(time.time())}
        cases = (("no token", lambda: self.__setattr__("token", lambda: None)),
                 ("no organization", lambda: self.set_config({"oauthAccount": {"organizationUuid": "  "}})),
                 ("no account block", lambda: self.set_config({})),
                 ("no account file", lambda: os.unlink(self.config)))
        signed_in = {"oauthAccount": {"organizationUuid": "org-uuid-1"}}
        for name, arrange in cases:
            with self.subTest(name=name):
                self.forget()
                self.token = lambda: TOKEN
                self.set_config(signed_in)
                mcpbar.write_json(self.path("reset-credit-pending.json"), stored)
                arrange()
                self.assertEqual(self.redeem(), 1)
                result = self.result()
                self.assertEqual((result["outcome"], result["error"], result["confirmed"]),
                                 (None, "signedOut", False))
                self.assert_nothing_was_sent()
                self.assertEqual(self.pending(), stored)

    def test_run_that_sends_nothing_does_not_erase_an_attempt_left_open(self):
        # Обрыв связи оставил заявку открытой. Её запись — единственное, по чему приложение не даёт
        # нажать другой сброс, пока первая могла дойти; запуск, ничего не отправивший, её не стирает.
        self.server.claim = "drop"
        self.assertEqual(self.redeem(), 1)
        left, key = self.result(), self.pending()
        self.assertEqual((left["error"], key["creditId"]), ("requestFailed", "weekly_a"))
        for category in ("cliUnavailable", "signedOut", "busy"):
            with self.subTest(category=category), contextlib.ExitStack() as held:
                self.set_claude("exit 3" if category == "cliUnavailable" else "echo '2.1.328 (Claude Code)'")
                self.token = (lambda: None) if category == "signedOut" else (lambda: TOKEN)
                if category == "busy":
                    fcntl.flock(held.enter_context(open(self.path("reset-credit.lock"), "w")), fcntl.LOCK_EX)
                self.assertEqual(self.redeem(), 1)
                self.assertIn("claude-reset-credit: " + category, self.printed)
                self.assertEqual((self.result(), self.pending()), (left, key))
        self.assertEqual(len(self.server.posts), 1)
        # Повтор, дошедший до сервиса, называет ту же заявку и закрывает её своим ответом.
        self.server.claim = (200, {"result": "already_used"})
        self.assertEqual(self.redeem(), 0)
        self.assertEqual(self.result()["outcome"], "alreadyRedeemed")
        self.assertEqual(self.server.posts[1]["body"]["request_id"], key["key"])

    def test_unreadable_login_and_account_have_their_own_categories(self):
        def unreadable_login():
            mcpbar.OAUTH_FACTS["unreadable"] = True

        self.token = unreadable_login
        self.assertEqual(self.redeem(), 1)
        self.assertEqual(self.result()["error"], "loginUnreadable")
        self.token = lambda: TOKEN
        mcpbar.OAUTH_FACTS.clear()
        for config in ("not json", "[1]", '{"oauthAccount": []}', '{"oauthAccount": null}',
                       '{"oauthAccount": {"organizationUuid": 5}}'):
            with self.subTest(config=config):
                self.set_config(config)
                self.assertEqual(self.redeem(), 1)
                self.assertEqual(self.result()["error"], "accountUnreadable")
        self.assert_nothing_was_sent()
        self.assertIsNone(self.pending())

    def test_organization_is_trimmed_and_encoded_into_the_path(self):
        self.set_config({"oauthAccount": {"organizationUuid": " a/b c?d "}})
        self.assertEqual(self.redeem(), 0)
        self.assertEqual(self.server.posts[0]["path"], "/api/organizations/a%2Fb%20c%3Fd/reset_rate_limits")

    def test_second_process_is_refused_as_busy(self):
        os.makedirs(self.root, exist_ok=True)
        with open(self.path("reset-credit.lock"), "w") as holder:
            fcntl.flock(holder, fcntl.LOCK_EX)
            self.assertEqual(self.redeem(), 1)
            result = self.result()
            self.assertEqual((result["outcome"], result["error"], result["confirmed"]), (None, "busy", False))
            self.assert_nothing_was_sent()
            self.assertIsNone(self.pending())
        self.assertEqual(self.redeem(), 0)
        self.assertEqual(self.result()["outcome"], "reset")

    def test_redirect_never_carries_the_token_to_another_host(self):
        target = self.base + CLAIM_PATH.format(organization="org-uuid-1")

        class Bouncer(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers.get("Content-Length") or 0))
                self.send_response(self.server.status)
                self.send_header("Location", target)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *args):
                pass

        bouncer = http.server.HTTPServer(("127.0.0.1", 0), Bouncer)
        threading.Thread(target=bouncer.serve_forever, daemon=True).start()
        self.addCleanup(bouncer.server_close)
        self.addCleanup(bouncer.shutdown)
        url = "http://127.0.0.1:%d%s" % (bouncer.server_address[1], CLAIM_PATH)
        for status in (301, 302, 303, 307, 308):
            with self.subTest(status=status), mock.patch.object(mcpbar_resets, "RESET_URL", url):
                self.forget()
                bouncer.status = status
                self.assertEqual(self.redeem(), 1)
                self.assertEqual(self.result()["error"], "requestFailed")
                self.assert_nothing_was_sent()
                self.assertIsNotNone(self.pending())

    def test_reset_without_a_fresh_reading_is_honestly_unconfirmed(self):
        self.server.usage = (500, {})
        self.assertEqual(self.redeem(), 0, "сброс потрачен — это исход, а не сбой команды")
        result = self.result()
        self.assertEqual((result["outcome"], result["error"], result["confirmed"]), ("reset", None, False))
        self.assertEqual(len(self.server.gets), 1, "у Claude повторный опрос ровно один")
        self.assertIsNone(self.pending())

    def test_outcome_is_on_disk_before_the_limits_are_reread(self):
        seen = []
        real = mcpbar.fetch_limits

        def poll():
            seen.append(self.result())
            return real()

        with mock.patch.object(mcpbar, "fetch_limits", poll):
            self.assertEqual(self.redeem(), 0)
        self.assertEqual((seen[0]["outcome"], seen[0]["confirmed"]), ("reset", False))
        self.assertEqual(self.result()["confirmed"], True)

    def test_crashed_reread_does_not_turn_a_spent_credit_into_a_failure(self):
        with mock.patch.object(mcpbar, "fetch_limits", side_effect=OSError("disk full")):
            self.assertEqual(self.redeem(), 0)
        self.assertEqual((self.result()["outcome"], self.result()["confirmed"]), ("reset", False))

    def test_key_that_cannot_be_removed_does_not_turn_a_spent_credit_into_a_failure(self):
        real = os.unlink

        def unlink(path, *args, **kwargs):
            if os.path.basename(path) == "reset-credit-pending.json":
                raise PermissionError(1, "Operation not permitted")
            return real(path, *args, **kwargs)

        with mock.patch.object(os, "unlink", unlink):
            self.assertEqual(self.redeem(), 0)
        result = self.result()
        self.assertEqual((result["outcome"], result["error"], result["confirmed"]), ("reset", None, True))
        # Уцелевший ключ безопасен: повтор с ним получит «уже погашен», а не потратит второй сброс.
        self.server.claim = (200, {"result": "already_used"})
        self.assertEqual(self.redeem(), 0)
        first, second = (post["body"]["request_id"] for post in self.server.posts)
        self.assertEqual(first, second)

    # ── Векторы из собственных тестов и исходников T3 Code (коммит 803f21f).

    def test_t3_coordinator_37_settled_failure_starts_a_fresh_attempt(self):
        # resetCreditCoordinator.test.ts:37-54 — остывание это ответ: следующая заявка уже другая.
        self.server.claim = (200, {"result": "cooldown"})
        self.assertEqual(self.redeem(), 1)
        self.assertEqual(self.redeem(), 1)
        first, second = (post["body"]["request_id"] for post in self.server.posts)
        self.assertNotEqual(first, second)

    def test_t3_registry_771_usage_is_refreshed_after_a_reset(self):
        # ProviderInstanceRegistry.test.ts:771-780 — до заявки окно на 100 %, после неё 0 %.
        self.assertEqual(mcpbar.read_json(mcpbar.LIMITS)["five_hour"]["used_percentage"], 100)
        real = mcpbar_resets.claude_claim

        def claim(*args):
            answer = real(*args)
            self.server.usage = (200, {"five_hour": {"utilization": 0, "resets_at": None},
                                       "cedar_ember": {"eligible": True, "next_grant_id": None, "grants": []}})
            return answer

        with mock.patch.object(mcpbar_resets, "claude_claim", claim):
            self.assertEqual(self.redeem(), 0)
        self.assertEqual(mcpbar.read_json(mcpbar.LIMITS)["five_hour"]["used_percentage"], 0)
        # Потраченный сброс больше не предлагается: варианты перечитаны тем же опросом.
        self.assertEqual(mcpbar.read_json(self.path("account.json"))["resetCredits"],
                         {"eligible": True, "availableCount": 0})
        self.assertEqual((self.result()["outcome"], self.result()["confirmed"]), ("reset", True))

    def test_t3_registry_782_answer_survives_a_failed_reprobe(self):
        # ProviderInstanceRegistry.test.ts:782-790 — заявка ничего не изменила, опрос после неё упал.
        self.server.claim, self.server.usage = (200, {"result": "already_used"}), (500, {})
        self.assertEqual(self.redeem(), 0)
        result = self.result()
        self.assertEqual((result["outcome"], result["error"], result["confirmed"]), ("alreadyRedeemed", None, True))
        self.assertEqual(len(self.server.gets), 1)

    def test_t3_source_307_any_2xx_answer_is_read(self):
        # claudeResetCredits.ts:307 — filterStatusOk пропускает весь диапазон 2xx, не только 200.
        self.server.claim = (201, {"result": "reset"})
        self.assertEqual(self.redeem(), 0)
        self.assertEqual(self.result()["outcome"], "reset")
        self.assertIsNone(self.pending())

    def test_t3_driver_349_the_next_grant_is_not_redeemable_unless_it_is_an_option(self):
        # ClaudeDriver.ts:349-358 — названный id сверяется только с options, не с nextCreditId.
        mcpbar.write_json(self.path("account.json"), {"resetCredits": {
            "eligible": True, "availableCount": 2, "nextCreditId": "weekly_a",
            "options": [{"creditId": "session_a", "kind": "session", "availableCount": 1}]}})
        self.assertEqual(self.redeem("weekly_a"), 0)
        self.assertEqual(self.result()["outcome"], "noCredit")
        self.assert_nothing_was_sent()

    def test_t3_snapshot_probe_102_cli_version_vectors(self):
        # snapshotProbe.test.ts:102-113
        for printed, version in (("opencode v2.0.3", "2.0.3"), ("v22.19.0", "22.19.0"),
                                 ("codex-cli 0.53.0 (build abc)", "0.53.0"), ("build2.0.3artifact", None)):
            with self.subTest(printed=printed):
                self.set_claude("echo '%s'" % printed)
                self.assertEqual(mcpbar_resets.claude_version(), version)


class CodexResetCredit(unittest.TestCase):
    CONSUME = "account/rateLimitResetCredit/consume"

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.bin = os.path.join(temp.name, "bin")
        os.makedirs(self.bin)
        self.root = os.path.join(temp.name, "control-bar")
        self.codex_root = os.path.join(self.root, "codex")
        self.codex_home = os.path.join(temp.name, ".codex")
        os.makedirs(self.codex_home)
        self.binary = os.path.join(self.bin, "codex")
        self.replies = {self.CONSUME: [{"result": {"outcome": "reset"}}],
                        "account/rateLimits/read": [CODEX_LIMITS_REPLY], "account/read": [CODEX_ACCOUNT_REPLY]}
        self.sleeps = []
        for target, name, value in (
                (mcpbar, "ROOT", self.root), (mcpbar_codex, "CODEX", self.codex_home),
                (mcpbar_codex, "CODEX_ROOT", self.codex_root),
                (mcpbar_codex, "CODEX_LIMITS", os.path.join(self.codex_root, "limits.json")),
                (mcpbar_codex, "CODEX_ROLLOUTS",
                 os.path.join(self.codex_home, "sessions", "*", "*", "*", "rollout-*.jsonl")),
                (mcpbar_codex, "find_codex", lambda: self.binary),
                # Только имя `time` внутри модуля: глобальный sleep нужен самому subprocess.
                (mcpbar_resets, "time", types.SimpleNamespace(time=time.time, sleep=self.sleeps.append))):
            patch = mock.patch.object(target, name, value)
            patch.start()
            self.addCleanup(patch.stop)

    def redeem(self, rewrite=True):
        if rewrite:
            write_fake_codex(self.bin, self.replies)
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            code = mcpbar.main(["codex-reset-credit"])
        self.printed = output.getvalue()
        return code

    def path(self, name):
        return os.path.join(self.codex_root, name)

    def result(self):
        return mcpbar.read_json(self.path("reset-credit-result.json"))

    def pending(self):
        return mcpbar.read_json(self.path("reset-credit-pending.json"))

    def calls(self, method=None):
        return [call for call in fake_codex_calls(self.bin) if method in (None, call["method"])]

    def forget(self):
        for path in (self.path("reset-credit-result.json"), self.path("reset-credit-pending.json"),
                     os.path.join(self.bin, "calls.jsonl")):
            if os.path.exists(path):
                os.unlink(path)
        del self.sleeps[:]

    def test_consume_goes_through_a_plain_app_server_with_an_idempotency_key(self):
        started = int(time.time())
        with mock.patch.object(mcpbar_codex, "codex_rpc", wraps=mcpbar_codex.codex_rpc) as rpc:
            self.assertEqual(self.redeem(), 0)
        consume = self.calls(self.CONSUME)
        self.assertEqual(len(consume), 1)
        key = consume[0]["params"]["idempotencyKey"]
        self.assertEqual(consume[0]["params"], {"idempotencyKey": key}, "creditId не передаётся: выбирает Codex")
        self.assertEqual(uuid.UUID(key).version, 4)
        # Погашение — запись: обычный app-server, не read-only; чтение лимитов после него — read-only.
        self.assertEqual(consume[0]["argv"], ["app-server"])
        self.assertEqual(consume[0]["initialize"]["capabilities"], {"experimentalApi": True})
        self.assertEqual(rpc.call_args_list[0], mock.call(
            self.CONSUME, {"idempotencyKey": key}, timeout=20, categories=True,
            capabilities={"experimentalApi": True}))
        self.assertEqual([call["argv"] for call in self.calls("account/rateLimits/read")], [READ_ONLY_ARGV])
        result = self.result()
        self.assertGreaterEqual(result.pop("ts"), started)
        self.assertEqual(result, {"provider": "codex", "creditId": None, "outcome": "reset",
                                  "error": None, "confirmed": True})
        self.assertIsNone(self.pending())
        for name in ("reset-credit-result.json", "reset-credit.lock"):
            self.assertEqual(stat.S_IMODE(os.stat(self.path(name)).st_mode), 0o600, name)
        for directory in (self.root, self.codex_root):
            self.assertEqual(stat.S_IMODE(os.stat(directory).st_mode), 0o700)

    def test_every_outcome_is_passed_through_and_followed_by_a_reread(self):
        for outcome in ("reset", "nothingToReset", "noCredit", "alreadyRedeemed"):
            with self.subTest(outcome=outcome):
                self.forget()
                self.replies[self.CONSUME] = [{"result": {"outcome": outcome}}]
                self.assertEqual(self.redeem(), 0)
                result = self.result()
                self.assertEqual((result["outcome"], result["error"], result["confirmed"]), (outcome, None, True))
                self.assertEqual(len(self.calls("account/rateLimits/read")), 1)
                self.assertEqual(self.sleeps, [])
                self.assertIsNone(self.pending())

    def test_every_failure_is_a_fixed_category_and_keeps_the_key(self):
        cases = (({"exit": True}, "connection_closed"),
                 ({"error": {"code": -32000, "message": "private server text"}}, "rpc_error"),
                 ({"result": {"outcome": "surprise"}}, "invalid_reply"),
                 ({"result": {"outcome": ["reset"]}}, "invalid_reply"),
                 ({"result": {}}, "invalid_reply"),
                 ({"result": ["reset"]}, "invalid_reply"),
                 ({"hang": True}, "timeout"))
        keys = set()
        for reply, category in cases:
            with self.subTest(category=category, reply=reply):
                self.replies[self.CONSUME] = [reply]
                with mock.patch.object(mcpbar_resets, "CONSUME_TIMEOUT", 1 if "hang" in reply else 20):
                    self.assertEqual(self.redeem(), 1)
                result = self.result()
                self.assertEqual((result["outcome"], result["error"], result["confirmed"]), (None, category, False))
                self.assertEqual(self.calls(self.CONSUME)[-1]["params"]["idempotencyKey"], self.pending()["key"])
                keys.add(self.pending()["key"])
                self.assertEqual(stat.S_IMODE(os.stat(self.path("reset-credit-pending.json")).st_mode), 0o600)
        self.assertEqual(len(keys), 1, "каждый повтор шлёт тот же ключ")
        self.assertEqual(self.calls("account/rateLimits/read"), [], "без исхода лимиты не перечитываются")
        stored = "".join(open(self.path(name)).read() for name in os.listdir(self.codex_root))
        self.assertNotIn("private server text", stored + self.printed)

    def test_codex_that_cannot_be_started(self):
        self.assertEqual(mcpbar_resets.CONSUME_TIMEOUT, 20)
        write_fake_codex(self.bin, self.replies)
        os.chmod(self.binary, 0o600)
        self.assertEqual(self.redeem(rewrite=False), 1)
        self.assertEqual(self.result()["error"], "connection_unavailable")
        self.binary = ""
        self.assertEqual(self.redeem(), 1)
        self.assertEqual(self.result()["error"], "not_installed")
        # Нет ~/.codex — нет и Codex: погашение не должно завести его домашний каталог.
        self.forget()
        self.binary = os.path.join(self.bin, "codex")
        os.rmdir(self.codex_home)
        self.assertEqual(self.redeem(), 1)
        self.assertEqual(self.result()["error"], "not_installed")
        self.assertEqual(self.calls(), [])
        self.assertIsNone(self.pending())

    def test_key_survives_failures_and_is_dropped_by_an_outcome(self):
        self.replies[self.CONSUME] = [{"exit": True}, {"result": {"outcome": "alreadyRedeemed"}},
                                      {"result": {"outcome": "noCredit"}}]
        self.assertEqual(self.redeem(), 1)
        self.assertEqual(self.redeem(), 0)
        self.assertIsNone(self.pending())
        self.assertEqual(self.redeem(), 0)
        first, second, third = (call["params"]["idempotencyKey"] for call in self.calls(self.CONSUME))
        self.assertEqual(first, second)
        self.assertNotEqual(second, third)

    def test_stored_key_expires_after_24_hours(self):
        self.replies[self.CONSUME] = [{"exit": True}]
        now = time.time()
        for created, reused in ((now - 24 * 3600 + 60, True), (now - 24 * 3600 - 60, False)):
            with self.subTest(reused=reused):
                self.forget()
                mcpbar_codex.secure_codex_root()
                mcpbar.write_json(self.path("reset-credit-pending.json"),
                                  {"key": "stored-key", "creditId": None, "createdAt": created})
                self.redeem()
                sent = self.calls(self.CONSUME)[0]["params"]["idempotencyKey"]
                self.assertEqual(sent == "stored-key", reused)
                self.assertEqual(self.pending()["key"], sent)

    def test_second_process_is_refused_as_busy(self):
        mcpbar_codex.secure_codex_root()
        with open(self.path("reset-credit.lock"), "w") as holder:
            fcntl.flock(holder, fcntl.LOCK_EX)
            self.assertEqual(self.redeem(), 1)
            result = self.result()
            self.assertEqual((result["outcome"], result["error"], result["confirmed"]), (None, "busy", False))
            self.assertEqual(self.calls(), [])
            self.assertIsNone(self.pending())

    def test_reset_is_confirmed_by_up_to_four_probes(self):
        closed = {"exit": True}
        for replies, probes, waits, confirmed in (
                ([CODEX_LIMITS_REPLY], 1, [], True),
                ([closed, closed, CODEX_LIMITS_REPLY], 3, [1, 2], True),
                ([closed], 4, [1, 2, 4], False),
                # Ответ без окон — тоже не свежие лимиты.
                ([{"result": {"rateLimitsByLimitId": {}}}], 4, [1, 2, 4], False)):
            with self.subTest(probes=probes, confirmed=confirmed):
                self.forget()
                self.replies["account/rateLimits/read"] = replies
                self.assertEqual(self.redeem(), 0, "сброс потрачен — это исход, а не сбой команды")
                result = self.result()
                self.assertEqual((result["outcome"], result["error"], result["confirmed"]), ("reset", None, confirmed))
                self.assertEqual(len(self.calls("account/rateLimits/read")), probes)
                self.assertEqual(self.sleeps, waits)

    def test_other_outcomes_need_one_probe_even_if_it_fails(self):
        self.replies[self.CONSUME] = [{"result": {"outcome": "nothingToReset"}}]
        self.replies["account/rateLimits/read"] = [{"exit": True}]
        self.assertEqual(self.redeem(), 0)
        self.assertEqual((self.result()["outcome"], self.result()["confirmed"]), ("nothingToReset", True))
        self.assertEqual(len(self.calls("account/rateLimits/read")), 1)
        self.assertEqual(self.sleeps, [])

    # ── Векторы из собственных тестов и исходников T3 Code (коммит 803f21f).

    def test_t3_coordinator_82_a_busy_claude_account_does_not_block_codex(self):
        # resetCreditCoordinator.test.ts:82-103 — у каждого аккаунта свой замок и свой ключ.
        os.makedirs(self.root, mode=0o700)
        claude_pending = {"key": "claude-key", "creditId": "weekly_a", "createdAt": int(time.time())}
        mcpbar.write_json(os.path.join(self.root, "reset-credit-pending.json"), claude_pending)
        with open(os.path.join(self.root, "reset-credit.lock"), "w") as holder:
            fcntl.flock(holder, fcntl.LOCK_EX)
            self.assertEqual(self.redeem(), 0)
        self.assertEqual(self.result()["outcome"], "reset")
        self.assertNotEqual(self.calls(self.CONSUME)[0]["params"]["idempotencyKey"], "claude-key")
        self.assertEqual(mcpbar.read_json(os.path.join(self.root, "reset-credit-pending.json")), claude_pending)
        self.assertFalse(os.path.exists(os.path.join(self.root, "reset-credit-result.json")))


if __name__ == "__main__":
    unittest.main()
