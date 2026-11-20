#!/usr/bin/env python3
"""Соседние файлы опроса лимитов: account.json (Claude) и codex/account.json.

В них лежит то, чего limits.json вместить не может: тариф, e-mail, окна отдельных моделей,
месячный расход и накопленные сбросы. Сеть — настоящие локальные серверы, Codex — подставной
исполняемый файл; настоящие эндпоинты и настоящий Keychain здесь не участвуют.
"""

import calendar
import contextlib
import http.server
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

import mcpbar  # noqa: E402
import mcpbar_codex  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Момент из тестов T3 (claudeResetCredits.test.ts): векторы ниже перенесены оттуда.
NOW = calendar.timegm((2026, 9, 22, 12, 0, 0))


def epoch(*moment):
    return calendar.timegm(moment)


def grant(**overrides):
    return dict({"id": "grant_a", "resets_left": 1, "usable_now": True}, **overrides)


def seam(source, name):
    """Файл настоящего писателя — образцом для Swift-проверки шва."""
    os.makedirs(os.path.join(REPO, "build", "seam"), exist_ok=True)
    shutil.copyfile(source, os.path.join(REPO, "build", "seam", name))


class FutureTimestamp(unittest.TestCase):
    """Срок сброса принимается только полной датой с зоной и только будущий: по нему решается,
    предлагать ли человеку потратить сброс."""

    def test_complete_future_timestamps_become_epoch_seconds(self):
        for value, expected in (
                ("2026-10-01T00:00:00Z", epoch(2026, 10, 1, 0, 0, 0)),
                ("2026-10-01T02:30:00+02:30", epoch(2026, 10, 1, 0, 0, 0)),
                ("2026-09-30T19:00:00-05:00", epoch(2026, 10, 1, 0, 0, 0)),
                ("2026-10-01T00:00:00.987654321Z", epoch(2026, 10, 1, 0, 0, 0))):
            with self.subTest(value=value):
                self.assertEqual(mcpbar.future_epoch(value, NOW), expected)

    def test_past_partial_and_impossible_values_are_refused(self):
        for value in ("2026-09-01T00:00:00Z",       # уже прошло
                      "2026-09-22T12:00:00Z",       # ровно сейчас — не будущее
                      "2026-10-01",                 # только дата
                      "2026-10-01T00:00:00",        # без зоны
                      "2026-10-01T00:00Z",          # без секунд
                      "2026-10-01 00:00:00Z",       # пробел вместо T
                      "2027-02-30T00:00:00Z",       # такого дня нет
                      "2027-13-01T00:00:00Z",
                      "2027-00-10T00:00:00Z",
                      "2027-01-01T24:00:00Z",
                      "2027-01-01T00:00:00Z\n",
                      "not a date", "", None, 1_800_000_000, True):
            with self.subTest(value=value):
                self.assertIsNone(mcpbar.future_epoch(value, NOW))


class ClaudeResetCredits(unittest.TestCase):
    """Блок cedar_ember → resetCredits. Правила — T3 (claudeResetCredits.ts), векторы — его тесты."""

    def test_counts_live_grants_and_pins_the_next_usable_one(self):
        credits = mcpbar.claude_reset_credits({
            "eligible": True, "next_grant_id": "grant_a",
            "grants": [
                grant(resets_left=2, ends_at="2026-10-01T00:00:00Z"),
                grant(id="paused", paused=True),
                grant(id="expired", ends_at="2026-09-01T00:00:00Z"),
                grant(id="garbled", ends_at="not a date"),
                grant(id="date_only", ends_at="2026-10-01"),
                grant(id="impossible", ends_at="2027-02-30T00:00:00Z"),
                grant(id="empty", ends_at=""),
                grant(id="Not Valid"),
                grant(id="grant_b", resets_left=3, usable_now=False),
            ]}, NOW)
        self.assertEqual(credits, {
            "eligible": True, "availableCount": 2, "nextCreditId": "grant_a",
            "nextExpiresAt": epoch(2026, 10, 1, 0, 0, 0),
            "options": [{"creditId": "grant_a", "kind": "full", "availableCount": 2,
                         "expiresAt": epoch(2026, 10, 1, 0, 0, 0)}]})

    def test_offers_each_kind_of_reset_by_its_own_grant(self):
        credits = mcpbar.claude_reset_credits({
            "eligible": True, "next_grant_id": "weekly_a",
            "grants": [
                # Потраченный грант стоит первым в своём виде, но сброс предлагает следующий за ним.
                grant(id="spent", clears=["seven_day"], resets_left=0),
                grant(id="weekly_a", clears=["seven_day"], ends_at="2026-12-10T22:00:00Z"),
                grant(id="fable_a", clears=["seven_day_overage_included"], gives_back_weekly=True,
                      ends_at="2027-03-09T07:59:00Z"),
                # gives_back_weekly сильнее объявленного type.
                grant(id="fable_b", gives_back_weekly=True, type="weekly"),
                grant(id="session_a", type="session"),
                # Вид, в котором остался один потраченный грант, не предлагается вовсе.
                grant(id="spent_full", resets_left=0),
            ]}, NOW)
        self.assertEqual(credits, {
            "eligible": True, "availableCount": 4, "nextCreditId": "weekly_a",
            "nextExpiresAt": epoch(2026, 12, 10, 22, 0, 0),
            "options": [
                {"creditId": "session_a", "kind": "session", "availableCount": 1},
                {"creditId": "weekly_a", "kind": "weekly", "availableCount": 1,
                 "expiresAt": epoch(2026, 12, 10, 22, 0, 0)},
                {"creditId": "fable_a", "kind": "fable", "availableCount": 2,
                 "expiresAt": epoch(2027, 3, 9, 7, 59, 0)},
            ]})

    def test_kind_falls_back_to_what_the_grant_clears(self):
        cases = (({"clears": ["five_hour"]}, "session"),
                 ({"clears": ["seven_day", "seven_day_overage_included"]}, "weekly"),
                 ({"clears": ["five_hour", "seven_day"]}, "full"),
                 ({"clears": []}, "full"),
                 ({}, "full"),
                 ({"type": "full", "clears": ["five_hour"]}, "full"),
                 ({"type": "monthly", "clears": ["five_hour"]}, "session"))
        for fields, kind in cases:
            with self.subTest(fields=fields):
                credits = mcpbar.claude_reset_credits(
                    {"eligible": True, "next_grant_id": "grant_a", "grants": [grant(**fields)]}, NOW)
                self.assertEqual([option["kind"] for option in credits["options"]], [kind])

    def test_nothing_to_redeem_without_a_usable_next_grant(self):
        for block in ({"eligible": True, "next_grant_id": "grant_a", "grants": [grant(usable_now=False)]},
                      {"eligible": True, "grants": [grant()]},
                      {"eligible": True, "next_grant_id": None, "grants": [grant()]},
                      {"eligible": True}):
            with self.subTest(block=block):
                self.assertEqual(mcpbar.claude_reset_credits(block, NOW),
                                 {"eligible": True, "availableCount": 0})

    def test_ineligible_account_is_a_known_zero_not_missing_information(self):
        self.assertEqual(mcpbar.claude_reset_credits({"eligible": False, "grants": [grant()]}, NOW),
                         {"eligible": False, "availableCount": 0})

    def test_undecodable_block_carries_no_information(self):
        for block in (None, [], "x", {}, {"eligible": "yes"}, {"eligible": 1},
                      {"eligible": True, "grants": {}}, {"eligible": True, "grants": None},
                      {"eligible": True, "next_grant_id": 7}):
            with self.subTest(block=block):
                self.assertIsNone(mcpbar.claude_reset_credits(block, NOW))

    def test_malformed_grants_are_dropped_one_by_one(self):
        credits = mcpbar.claude_reset_credits({
            "eligible": True, "next_grant_id": "good",
            "grants": [
                "garbage", None, 7,
                grant(id=""), grant(id="x" * 41), grant(id=12),
                grant(id="neg", resets_left=-1), grant(id="half", resets_left=1.5),
                grant(id="text", resets_left="2"), grant(id="flag", resets_left=True),
                grant(id="inf", resets_left=float("inf")),
                # json.loads пропускает целое любой длины, а во float оно не помещается.
                grant(id="huge", resets_left=10 ** 400),
                grant(id="bad_end", ends_at=1_800_000_000),
                grant(id="bad_pause", paused="no"), grant(id="bad_usable", usable_now=1),
                grant(id="bad_clears", clears="five_hour"),
                grant(id="bad_fable", gives_back_weekly="yes"),
                # Без usable_now грант не живой: поле обязано быть истинным, а не отсутствовать.
                {"id": "silent", "resets_left": 5},
                grant(id="good", resets_left=2.0, type="weekly"),
            ]}, NOW)
        self.assertEqual(credits, {"eligible": True, "availableCount": 2, "nextCreditId": "good",
                                   "options": [{"creditId": "good", "kind": "weekly", "availableCount": 2}]})


class ClaudeExtraRows(unittest.TestCase):
    """Окна моделей кроме Fable и месячный расход — то, чего limits.json не вмещает."""

    def test_scoped_weekly_windows_other_than_fable(self):
        windows = mcpbar.claude_extra_windows([
            {"kind": "weekly_all", "percent": 60},
            {"kind": "weekly_scoped", "percent": 73, "scope": {"model": {"display_name": "Fable"}}},
            {"kind": "weekly_scoped", "percent": 9, "scope": {"model": {"display_name": " fable "}}},
            {"kind": "weekly_scoped", "percent": 12.5, "resets_at": "2026-11-24T07:00:00Z",
             "scope": {"model": {"display_name": "Orbit", "id": "orbit-1"}, "surface": None}},
            {"kind": "weekly_scoped", "percent": 150, "scope": {"model": {"display_name": "Sonnet 4.5"}}},
            {"kind": "weekly_scoped", "percent": -3, "resets_at": "garbage",
             "scope": {"model": {"display_name": "Low"}}},
            # Окно без процента строки не даёт (у T3 — «Ghost»).
            {"kind": "weekly_scoped", "percent": None, "scope": {"model": {"display_name": "Ghost"}}},
            {"kind": "weekly_scoped", "percent": True, "scope": {"model": {"display_name": "Flag"}}},
            {"kind": "weekly_scoped", "percent": float("inf"), "scope": {"model": {"display_name": "Inf"}}},
            {"kind": "weekly_scoped", "percent": 5, "scope": {"model": {"display_name": 7}}},
            {"kind": "weekly_scoped", "percent": 5, "scope": {"model": None}},
            {"kind": "weekly_scoped", "percent": 5, "scope": None},
            {"kind": "weekly_scoped", "percent": 5},
            "garbage", None,
        ])
        self.assertEqual(windows, [
            {"id": "seven_day_orbit", "kind": "weekly", "name": "Orbit", "usedPercent": 12.5,
             "windowMinutes": 10080, "resetsAt": epoch(2026, 11, 24, 7, 0, 0)},
            {"id": "seven_day_sonnet_4_5", "kind": "weekly", "name": "Sonnet 4.5", "usedPercent": 100.0,
             "windowMinutes": 10080},
            {"id": "seven_day_low", "kind": "weekly", "name": "Low", "usedPercent": 0.0,
             "windowMinutes": 10080},
        ])
        for drifted in (None, {}, "limits", 5):
            self.assertEqual(mcpbar.claude_extra_windows(drifted), [])

    def test_spend_percent_prefers_minor_units_then_extra_usage(self):
        money = lambda amount, currency="USD", exponent=2: {  # noqa: E731
            "amount_minor": amount, "currency": currency, "exponent": exponent}
        extra = {"is_enabled": True, "monthly_limit": 5000, "used_credits": 2000, "utilization": 41.0}
        cases = (
            # Точное отношение сумм сильнее округлённого spend.percent и extra_usage.
            ({"spend": {"enabled": True, "percent": 13, "used": money(250), "limit": money(1000)},
              "extra_usage": extra}, {"enabled": True, "usedPercent": 25.0, "zeroCap": False}),
            # Разные валюты или масштабы суммами не делятся — остаётся extra_usage.
            ({"spend": {"enabled": True, "used": money(250, "EUR"), "limit": money(1000)},
              "extra_usage": extra}, {"enabled": True, "usedPercent": 40.0, "zeroCap": False}),
            ({"spend": {"enabled": True, "used": money(250, exponent=3), "limit": money(1000)},
              "extra_usage": extra}, {"enabled": True, "usedPercent": 40.0, "zeroCap": False}),
            ({"spend": {"enabled": True, "used": money(250, " "), "limit": money(1000, " ")},
              "extra_usage": extra}, {"enabled": True, "usedPercent": 40.0, "zeroCap": False}),
            # Живой ответ 19.11.2026: в spend только enabled и percent.
            ({"spend": {"enabled": True, "percent": 40}, "extra_usage": extra},
             {"enabled": True, "usedPercent": 40.0, "zeroCap": False}),
            ({"extra_usage": {"is_enabled": True, "monthly_limit": None, "used_credits": None,
                              "utilization": 41.5}}, {"enabled": True, "usedPercent": 41.5, "zeroCap": False}),
            ({"extra_usage": {"is_enabled": True, "monthly_limit": 100, "used_credits": 900}},
             {"enabled": True, "usedPercent": 100.0, "zeroCap": False}),
            # Нулевой потолок процента не имеет.
            ({"extra_usage": {"is_enabled": True, "monthly_limit": 0, "used_credits": 0,
                              "utilization": None}}, {"enabled": True, "zeroCap": True}),
            ({"spend": {"enabled": True, "percent": 40}}, {"enabled": True, "zeroCap": False}),
            ({"extra_usage": {"is_enabled": False, "monthly_limit": 0, "used_credits": 5,
                              "utilization": 50}}, {"enabled": False, "zeroCap": False}),
            ({"spend": {"enabled": False, "used": money(250), "limit": money(1000)}},
             {"enabled": False, "zeroCap": False}),
            ({"spend": {"enabled": True, "used": money(-1), "limit": money(1000)}},
             {"enabled": True, "zeroCap": False}),
            ({"spend": {"enabled": True, "used": money(1), "limit": money(0)}},
             {"enabled": True, "zeroCap": False}),
        )
        for payload, expected in cases:
            with self.subTest(payload=payload):
                self.assertEqual(mcpbar.claude_spend(payload), expected)
        for payload in ({}, {"spend": None, "extra_usage": None}, {"spend": "x", "extra_usage": []}):
            with self.subTest(payload=payload):
                self.assertIsNone(mcpbar.claude_spend(payload))


class UsageServer(http.server.BaseHTTPRequestHandler):
    """Подставной api/oauth/usage: блок cedar_ember отдаёт только на запрос с cedar_ember=1."""

    def do_GET(self):
        self.server.requests.append({"path": self.path, "headers": dict(self.headers.items())})
        payload = dict(self.server.payload)
        if "cedar_ember=1" not in self.path:
            payload.pop("cedar_ember", None)
        body = json.dumps(payload).encode("utf-8")
        self.send_response(self.server.status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


RICH_PAYLOAD = {
    "five_hour": None,
    "seven_day": {"utilization": 18.4, "resets_at": "2026-09-27T07:00:00Z"},
    "seven_day_opus": {"utilization": 50, "resets_at": None},
    "limits": [
        {"group": "weekly", "is_active": True, "kind": "weekly_all", "percent": 18.4,
         "resets_at": "2026-09-27T07:00:00Z", "scope": None, "severity": "ok"},
        {"group": "weekly", "is_active": True, "kind": "weekly_scoped", "percent": 73,
         "resets_at": "2026-09-27T07:00:00Z",
         "scope": {"model": {"display_name": "Fable", "id": "fable-1"}, "surface": None}},
        {"group": "weekly", "is_active": False, "kind": "weekly_scoped", "percent": 12.5,
         "resets_at": "2026-09-27T07:00:00Z",
         "scope": {"model": {"display_name": "Orbit", "id": "orbit-1"}, "surface": None}},
    ],
    "extra_usage": {"is_enabled": True, "monthly_limit": 5000, "used_credits": 2000, "utilization": 41.0},
    "spend": {"enabled": True, "percent": 40},
    "cedar_ember": {
        "at_limit": False, "cooldown_until": None, "eligible": True, "event_props": {},
        "exhausted": [], "ineligible_reason": None, "next_grant_id": "weekly_a",
        "weekly_resets_at": "2026-09-27T07:00:00Z",
        "grants": [
            grant(id="weekly_a", clears=["seven_day"], ends_at="2026-12-10T22:00:00Z"),
            grant(id="fable_a", gives_back_weekly=True, resets_left=2),
            grant(id="session_a", type="session"),
            grant(id="paused_a", paused=True),
            grant(id="expired_a", ends_at="2026-09-01T00:00:00Z"),
        ]},
}

KEYCHAIN = {"claudeAiOauth": {
    "accessToken": "SECRET-ACCESS", "refreshToken": "SECRET-REFRESH",
    "expiresAt": (NOW + 3600) * 1000, "refreshTokenExpiresAt": (NOW + 86400) * 1000,
    "scopes": ["user:inference"], "subscriptionType": "max",
    "rateLimitTier": "default_claude_max_20x", "subscriptionTypeSource": "oauth"}}


class ClaudeAccountPoll(unittest.TestCase):
    """Команда `limits` одним запросом пишет и limits.json, и account.json.

    Токен читается настоящим oauth_token() из подставного ответа `security`: так видно и то,
    что тариф берётся из той же записи без второго обращения к Keychain, и то, что сам токен
    дальше заголовка Authorization не уходит.
    """

    def setUp(self):
        self.server = http.server.HTTPServer(("127.0.0.1", 0), UsageServer)
        self.server.payload, self.server.status, self.server.requests = RICH_PAYLOAD, 200, []
        threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.02},
                         daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = os.path.join(temp.name, "control-bar")
        self.account = os.path.join(self.root, "account.json")
        self.config = os.path.join(temp.name, "claude.json")
        with open(self.config, "w") as fh:
            json.dump({"oauthAccount": {"emailAddress": "user@example.com", "organizationUuid": "ORG-UUID",
                                        "accountUuid": "ACCOUNT-UUID", "displayName": "User"}}, fh)
        # Запрос уходит с тем самым query, что и настоящий: его несёт сама константа USAGE_URL.
        query = mcpbar.USAGE_URL.partition("?")[2]
        url = "http://127.0.0.1:%d/api/oauth/usage?%s" % (self.server.server_address[1], query)
        self.keychain, self.security_calls = json.dumps(KEYCHAIN), []
        for name, value in (("USAGE_URL", url), ("ROOT", self.root), ("CONFIG", self.config),
                            ("LIMITS", os.path.join(self.root, "limits.json")),
                            ("LIMITS_STATUS", os.path.join(self.root, "limits-status.json")),
                            ("CREDENTIALS_FILE", os.path.join(temp.name, "no-credentials.json"))):
            patch = mock.patch.object(mcpbar, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        for patch in (mock.patch.object(subprocess, "run", self.security),
                      mock.patch.object(mcpbar.time, "time", return_value=NOW)):
            patch.start()
            self.addCleanup(patch.stop)
        self.addCleanup(mcpbar.OAUTH_FACTS.clear)

    def security(self, argv, **options):
        """Вместо /usr/bin/security: настоящий Keychain тестам не нужен и не положен."""
        self.assertEqual(argv[:2], ["/usr/bin/security", "find-generic-password"])
        self.security_calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, stdout=self.keychain, stderr="")

    def poll(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            self.assertEqual(mcpbar.main(["limits"]), 0)
        return output.getvalue()

    def test_one_request_writes_limits_and_account_side_by_side(self):
        printed = self.poll()
        self.assertEqual(len(self.server.requests), 1, "на опрос положен ровно один запрос")
        self.assertEqual(self.server.requests[0]["path"], "/api/oauth/usage?cedar_ember=1")
        self.assertEqual(self.server.requests[0]["headers"]["Authorization"], "Bearer SECRET-ACCESS")
        self.assertEqual(self.server.requests[0]["headers"]["User-Agent"],
                         "claude-control-bar (statusline companion)")
        self.assertEqual(len(self.security_calls), 1, "тариф взят из той же записи Keychain")
        self.assertEqual(mcpbar.read_json(self.account), {
            "ts": NOW, "provider": "claude",
            "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x",
            "email": "user@example.com",
            "extraWindows": [{"id": "seven_day_orbit", "kind": "weekly", "name": "Orbit",
                              "usedPercent": 12.5, "windowMinutes": 10080,
                              "resetsAt": epoch(2026, 9, 27, 7, 0, 0)}],
            "spend": {"enabled": True, "usedPercent": 40.0, "zeroCap": False},
            "resetCredits": {
                "eligible": True, "availableCount": 4, "nextCreditId": "weekly_a",
                "nextExpiresAt": epoch(2026, 12, 10, 22, 0, 0),
                "options": [
                    {"creditId": "session_a", "kind": "session", "availableCount": 1},
                    {"creditId": "weekly_a", "kind": "weekly", "availableCount": 1,
                     "expiresAt": epoch(2026, 12, 10, 22, 0, 0)},
                    {"creditId": "fable_a", "kind": "fable", "availableCount": 2}]}})
        self.assertEqual(stat.S_IMODE(os.stat(self.account).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(self.root).st_mode), 0o700)
        self.assertEqual(mcpbar.read_json(mcpbar.LIMITS_STATUS)["state"], "ok")
        # Токены и то, что читается только в момент погашения, на диск и в вывод не попадают.
        stored = "".join(open(os.path.join(self.root, name)).read() for name in os.listdir(self.root))
        for secret in ("SECRET-ACCESS", "SECRET-REFRESH", "ORG-UUID", "ACCOUNT-UUID"):
            self.assertNotIn(secret, stored + printed)
        seam(self.account, "account.json")

    def test_limits_json_keeps_its_exact_shape(self):
        """Файл с двумя писателями: новые блоки ответа в него не протекают, порядок ключей прежний."""
        self.poll()
        with open(mcpbar.LIMITS) as fh:
            raw = fh.read()
        expected = {"ts": NOW, "source": "oauth",
                    "seven_day": {"used_percentage": 18, "resets_at": epoch(2026, 9, 27, 7, 0, 0)},
                    "seven_day_opus": {"used_percentage": 50, "resets_at": None},
                    "extra_usage": {"used_percentage": 41, "resets_at": None},
                    "seven_day_fable": {"used_percentage": 73, "resets_at": epoch(2026, 9, 27, 7, 0, 0)}}
        self.assertEqual(raw, json.dumps(expected, ensure_ascii=False))

    def test_ineligible_account_without_extras(self):
        self.server.payload = {"five_hour": {"utilization": 5, "resets_at": None},
                               "cedar_ember": {"eligible": False, "grants": [], "next_grant_id": None}}
        self.poll()
        self.assertEqual(mcpbar.read_json(self.account), {
            "ts": NOW, "provider": "claude", "subscriptionType": "max",
            "rateLimitTier": "default_claude_max_20x", "email": "user@example.com",
            "extraWindows": [], "resetCredits": {"eligible": False, "availableCount": 0}})

    def test_missing_pieces_are_omitted_not_errors(self):
        self.server.payload = {"five_hour": {"utilization": 5, "resets_at": None}}
        self.keychain = json.dumps({"claudeAiOauth": {"accessToken": "SECRET-ACCESS",
                                                       "subscriptionType": 7, "rateLimitTier": " "}})
        for config in ('{"oauthAccount": {"emailAddress": 5}}', '{"oauthAccount": []}', "[1]", "not json"):
            with self.subTest(config=config):
                with open(self.config, "w") as fh:
                    fh.write(config)
                self.poll()
                self.assertEqual(mcpbar.read_json(self.account),
                                 {"ts": NOW, "provider": "claude", "extraWindows": []})
        os.unlink(self.config)
        self.poll()
        self.assertEqual(mcpbar.read_json(self.account), {"ts": NOW, "provider": "claude", "extraWindows": []})

    def test_failed_or_empty_poll_keeps_the_previous_sidecar(self):
        self.poll()
        before = mcpbar.read_json(self.account)
        for status, payload in ((500, RICH_PAYLOAD), (200, {"cedar_ember": RICH_PAYLOAD["cedar_ember"]})):
            with self.subTest(status=status):
                self.server.status, self.server.payload = status, payload
                with mock.patch.object(mcpbar.time, "time", return_value=NOW + 300):
                    self.poll()
                self.assertEqual(mcpbar.read_json(self.account), before)

    def test_sidecar_failure_never_breaks_the_limits_poll(self):
        real = mcpbar.write_json

        def broken(path, *args, **kwargs):
            if path == self.account:
                raise OSError("disk full: SECRET-ACCESS")
            return real(path, *args, **kwargs)

        with mock.patch.object(mcpbar, "write_json", broken):
            self.poll()
        self.assertEqual(mcpbar.read_json(mcpbar.LIMITS)["seven_day"]["used_percentage"], 18)
        self.assertEqual(mcpbar.read_json(mcpbar.LIMITS_STATUS)["state"], "ok")
        self.assertFalse(os.path.exists(self.account))
        # Причина остаётся в problems.log — именем исключения, без его текста.
        log = os.path.join(self.root, "problems.log")
        with open(log) as fh:
            self.assertEqual(fh.read(), "could not write account.json: OSError\n")
        self.assertEqual(stat.S_IMODE(os.stat(log).st_mode), 0o600)

    def test_unreadable_login_is_told_apart_from_a_missing_one(self):
        """Погашению сброса нужна причина отсутствия токена: «не вошёл» и «запись не читается» —
        разные ответы человеку."""
        for raw, unreadable in (("not json", True), ("[1, 2]", True), ('{"claudeAiOauth": "x"}', True),
                                ("", False), ("{}", False),
                                (json.dumps({"claudeAiOauth": {"accessToken": "SECRET-ACCESS",
                                                               "expiresAt": (NOW - 5) * 1000}}), False)):
            with self.subTest(raw=raw):
                self.keychain = raw
                self.assertIsNone(mcpbar.oauth_token())
                self.assertEqual(mcpbar.OAUTH_FACTS, {"unreadable": True} if unreadable else {})
        self.keychain = json.dumps(KEYCHAIN)
        self.assertEqual(mcpbar.oauth_token(), "SECRET-ACCESS")
        self.assertEqual(mcpbar.OAUTH_FACTS, {"subscriptionType": "max",
                                              "rateLimitTier": "default_claude_max_20x"})

    # ── Векторы из тестов T3 Code (коммит 803f21f): тот же ответ через настоящую команду.

    def test_t3_cliproxy_343_fable_stays_in_limits_json_and_is_not_an_extra_row(self):
        # cliproxyApi.test.ts:343-374 → [five_hour 10, seven_day 50, seven_day_fable 80]
        self.server.payload = {
            "five_hour": {"utilization": 10, "resets_at": None},
            "seven_day": {"utilization": 50, "resets_at": "2099-01-01T00:00:00Z"},
            "limits": [{"kind": "weekly_scoped", "percent": 80, "resets_at": None,
                        "scope": {"model": {"display_name": "Fable"}}}]}
        self.poll()
        limits = mcpbar.read_json(mcpbar.LIMITS)
        self.assertEqual({key: value for key, value in limits.items() if isinstance(value, dict)}, {
            "five_hour": {"used_percentage": 10, "resets_at": None},
            "seven_day": {"used_percentage": 50, "resets_at": epoch(2099, 1, 1, 0, 0, 0)},
            "seven_day_fable": {"used_percentage": 80, "resets_at": None}})
        account = mcpbar.read_json(self.account)
        self.assertEqual(account["extraWindows"], [])
        self.assertNotIn("spend", account)

    def test_t3_cliproxy_376_monthly_spend_beside_rolling_windows(self):
        # cliproxyApi.test.ts:376-414 — и бюджет spend, и extra_usage дают 9.262 % рядом с окном.
        budgets = (
            {"spend": {"enabled": True, "used": {"amount_minor": 4_631, "currency": "USD", "exponent": 2},
                       "limit": {"amount_minor": 50_000, "currency": "USD", "exponent": 2}}},
            {"extra_usage": {"is_enabled": True, "used_credits": 4_631, "monthly_limit": 50_000,
                             "utilization": 9}})
        for budget in budgets:
            with self.subTest(budget=list(budget)):
                self.server.payload = dict({"five_hour": {"utilization": 10, "resets_at": None}}, **budget)
                self.poll()
                self.assertEqual(mcpbar.read_json(mcpbar.LIMITS)["five_hour"]["used_percentage"], 10)
                spend = mcpbar.read_json(self.account)["spend"]
                self.assertAlmostEqual(spend.pop("usedPercent"), 9.262, places=10)
                self.assertEqual(spend, {"enabled": True, "zeroCap": False})

    def test_t3_cliproxy_417_disabled_budgets_do_not_cost_the_rolling_window(self):
        # cliproxyApi.test.ts:417-440
        self.server.payload = {
            "five_hour": {"utilization": 10, "resets_at": None},
            "spend": {"enabled": False, "used": None, "limit": None},
            "extra_usage": {"is_enabled": False, "used_credits": None, "monthly_limit": None,
                            "utilization": None}}
        self.poll()
        limits = mcpbar.read_json(mcpbar.LIMITS)
        self.assertEqual([key for key, value in limits.items() if isinstance(value, dict)], ["five_hour"])
        self.assertEqual(mcpbar.read_json(self.account)["spend"], {"enabled": False, "zeroCap": False})


def write_fake_codex(directory, replies):
    """Подставной `codex app-server`: отвечает по методу и записывает, как его запустили.

    `replies` — {метод: [ответ, …]}; ответы расходуются по одному на запуск, последний остаётся.
    """
    binary = os.path.join(directory, "codex")
    with open(os.path.join(directory, "replies.json"), "w") as fh:
        json.dump(replies, fh)
    with open(binary, "w") as fh:
        fh.write('''#!/usr/bin/python3
import json, os, sys, time
here = os.path.dirname(os.path.abspath(__file__))
initialize = json.loads(sys.stdin.readline())
print(json.dumps({"id": 1, "result": {"userAgent": "codex_cli_rs/0.169.0 (Mac OS)"}}), flush=True)
json.loads(sys.stdin.readline())
request = json.loads(sys.stdin.readline())
with open(os.path.join(here, "calls.jsonl"), "a") as fh:
    fh.write(json.dumps({"argv": sys.argv[1:], "method": request["method"],
                         "params": request.get("params"), "initialize": initialize["params"]}) + "\\n")
with open(os.path.join(here, "calls.jsonl")) as fh:
    served = sum(1 for line in fh if json.loads(line)["method"] == request["method"])
with open(os.path.join(here, "replies.json")) as fh:
    queue = json.load(fh).get(request["method"]) or [{"error": {"code": -32601, "message": "unknown"}}]
reply = queue[min(served, len(queue)) - 1]
if reply.get("hang"):
    time.sleep(30)
elif not reply.get("exit"):
    print(json.dumps(dict(reply, id=2)), flush=True)
''')
    os.chmod(binary, 0o700)
    return binary


def fake_codex_calls(directory):
    try:
        with open(os.path.join(directory, "calls.jsonl")) as fh:
            return [json.loads(line) for line in fh]
    except FileNotFoundError:
        return []


READ_ONLY_ARGV = ["-c", 'approval_policy="never"', "-c", "features.plugins=false",
                  "-s", "read-only", "-a", "never", "app-server"]

CODEX_LIMITS_REPLY = {"result": {
    "accountId": "ACCOUNT-ID",
    "rateLimitResetCredits": {"availableCount": 2, "credits": [
        {"id": "credit-late", "status": "available", "resetType": "codexRateLimits",
         "grantedAt": NOW - 86400, "expiresAt": NOW + 900_000},
        {"id": "credit-soon", "status": "available", "resetType": "codexRateLimits",
         "grantedAt": NOW - 86400, "expiresAt": NOW + 500_000},
        {"id": "credit-used", "status": "redeemed", "resetType": "codexRateLimits",
         "grantedAt": NOW - 86400, "expiresAt": NOW + 100},
        {"id": "credit-forever", "status": "available", "resetType": "codexRateLimits",
         "grantedAt": NOW - 86400, "expiresAt": None}]},
    "rateLimits": {"limitId": "codex_bengalfox", "planType": "promax",
                   "primary": {"usedPercent": 99},
                   "individualLimit": {"limit": "10", "remainingPercent": 5, "resetsAt": NOW + 1, "used": "9"}},
    "rateLimitsByLimitId": {"codex": {
        "limitId": "codex", "planType": "promax",
        "credits": {"balance": "12", "hasCredits": True, "unlimited": False},
        "individualLimit": {"limit": "100", "remainingPercent": 70, "resetsAt": NOW + 2_000_000, "used": "30"},
        "primary": {"usedPercent": 24, "windowDurationMins": 10080, "resetsAt": NOW + 400_000},
        "secondary": None}}}}
CODEX_ACCOUNT_REPLY = {"result": {"account": {"email": "user@example.com", "planType": "promax",
                                              "type": "chatgpt", "workspaceName": "WORKSPACE"},
                                  "requiresOpenaiAuth": True}}


class CodexAccountPoll(unittest.TestCase):
    """`codex-limits` пишет codex/account.json из того же ответа account/rateLimits/read.

    E-mail — второй запуск app-server (account/read), поэтому не чаще раза в сутки.
    """

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.bin = os.path.join(temp.name, "bin")
        os.makedirs(self.bin)
        self.root = os.path.join(temp.name, "control-bar")
        self.codex_root = os.path.join(self.root, "codex")
        self.account = os.path.join(self.codex_root, "account.json")
        codex_home = os.path.join(temp.name, ".codex")
        os.makedirs(codex_home)
        self.replies = {"account/rateLimits/read": [CODEX_LIMITS_REPLY], "account/read": [CODEX_ACCOUNT_REPLY]}
        self.now = NOW
        for target, name, value in (
                (mcpbar, "ROOT", self.root), (mcpbar_codex, "CODEX", codex_home),
                (mcpbar_codex, "CODEX_ROOT", self.codex_root),
                (mcpbar_codex, "CODEX_LIMITS", os.path.join(self.codex_root, "limits.json")),
                (mcpbar_codex, "CODEX_ROLLOUTS",
                 os.path.join(codex_home, "sessions", "*", "*", "*", "rollout-*.jsonl")),
                (mcpbar_codex, "find_codex", lambda: os.path.join(self.bin, "codex"))):
            patch = mock.patch.object(target, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        patch = mock.patch.object(mcpbar_codex.time, "time", side_effect=lambda: self.now)
        patch.start()
        self.addCleanup(patch.stop)

    def poll(self):
        write_fake_codex(self.bin, self.replies)
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            self.assertEqual(mcpbar.main(["codex-limits"]), 0)
        return output.getvalue()

    def methods(self):
        return [call["method"] for call in fake_codex_calls(self.bin)]

    def test_extras_come_from_the_same_answer_and_email_from_account_read(self):
        printed = self.poll()
        calls = fake_codex_calls(self.bin)
        self.assertEqual([call["method"] for call in calls], ["account/rateLimits/read", "account/read"])
        # Оба чтения аккаунта — через read-only app-server и без capabilities.
        for call in calls:
            self.assertEqual(call["argv"], READ_ONLY_ARGV)
            self.assertNotIn("capabilities", call["initialize"])
        self.assertEqual(mcpbar.read_json(self.account), {
            "ts": NOW, "provider": "codex", "planType": "promax", "email": "user@example.com",
            "emailCheckedAt": NOW,
            # Строка — из пула codex, не из чужого лимита в rateLimits; длительности у неё нет.
            "extraWindows": [{"id": "individual", "kind": "monthly", "name": "Monthly credit limit",
                              "usedPercent": 30.0, "resetsAt": NOW + 2_000_000}],
            "resetCredits": {"availableCount": 2, "nextExpiresAt": NOW + 500_000}})
        self.assertEqual(stat.S_IMODE(os.stat(self.account).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(self.codex_root).st_mode), 0o700)
        self.assertEqual(mcpbar.read_json(mcpbar_codex.CODEX_LIMITS)["windows"][0]["used_percentage"], 24)
        stored = "".join(open(os.path.join(self.codex_root, name)).read()
                         for name in os.listdir(self.codex_root))
        for private in ("ACCOUNT-ID", "WORKSPACE", "credit-soon"):
            self.assertNotIn(private, stored + printed)
        seam(self.account, "codex-account.json")

    def test_email_is_asked_at_most_once_per_24_hours(self):
        self.poll()
        self.replies["account/read"] = [{"result": {"account": {"type": "chatgpt", "email": "new@example.com"}}}]
        self.now = NOW + 24 * 3600 - 1
        self.poll()
        self.assertEqual(self.methods().count("account/read"), 1)
        record = mcpbar.read_json(self.account)
        self.assertEqual((record["ts"], record["email"], record["emailCheckedAt"]),
                         (self.now, "user@example.com", NOW))
        self.now = NOW + 24 * 3600
        self.poll()
        self.assertEqual(self.methods().count("account/read"), 2)
        record = mcpbar.read_json(self.account)
        self.assertEqual((record["email"], record["emailCheckedAt"]), ("new@example.com", self.now))

    def test_failed_email_read_keeps_the_stored_one_and_still_waits_a_day(self):
        self.poll()
        self.replies["account/read"] = [{"error": {"code": -32000, "message": "private server text"}}]
        self.now = NOW + 24 * 3600
        self.poll()
        record = mcpbar.read_json(self.account)
        self.assertEqual((record["email"], record["emailCheckedAt"]), ("user@example.com", self.now))
        self.assertNotIn("private server text", json.dumps(record))
        self.now += 300
        self.poll()
        self.assertEqual(self.methods().count("account/read"), 2)

    def test_only_a_chatgpt_login_has_an_email(self):
        for account in ({"type": "apiKey"}, {"type": "chatgpt", "email": None},
                        {"type": "amazonBedrock", "email": "wrong@example.com"}, None, "x"):
            with self.subTest(account=account):
                if os.path.exists(self.account):
                    os.unlink(self.account)
                self.replies["account/read"] = [{"result": {"account": account}}]
                self.poll()
                self.assertNotIn("email", mcpbar.read_json(self.account))

    def test_missing_extras_are_omitted(self):
        self.replies["account/rateLimits/read"] = [{"result": {"rateLimits": {
            "primary": {"usedPercent": 12, "windowDurationMins": 300, "resetsAt": NOW + 100}}}}]
        self.replies["account/read"] = [{"result": {"account": None}}]
        self.poll()
        self.assertEqual(mcpbar.read_json(self.account), {
            "ts": NOW, "provider": "codex", "emailCheckedAt": NOW, "extraWindows": []})

    def test_account_record_reads_drifted_shapes_as_unknown(self):
        record = mcpbar_codex.codex_account_record
        self.assertEqual(record({"rateLimitResetCredits": {"availableCount": -3, "credits": None}}, 5),
                         {"ts": 5, "provider": "codex", "extraWindows": [], "resetCredits": {"availableCount": 0}})
        for summary in (None, [], {"availableCount": "2"}, {"availableCount": True}, {}):
            with self.subTest(summary=summary):
                self.assertNotIn("resetCredits", record({"rateLimitResetCredits": summary}, 5))
        self.assertEqual(record({"rateLimitResetCredits": {"availableCount": 1, "credits": [
            "x", {"status": "available", "expiresAt": "soon"}, {"status": "available", "expiresAt": True},
            {"status": "available", "expiresAt": 0}]}}, 5)["resetCredits"], {"availableCount": 1})
        for limit in (None, "x", {"remainingPercent": None}, {"remainingPercent": True},
                      {"remainingPercent": float("nan")}):
            with self.subTest(limit=limit):
                self.assertEqual(record({"rateLimits": {"individualLimit": limit}}, 5)["extraWindows"], [])
        # Лимит другой модели в устаревшем одиночном ответе строкой обычного пула не становится.
        self.assertEqual(record({"rateLimits": {"limitId": "codex_bengalfox", "individualLimit": {
            "remainingPercent": 5}}}, 5)["extraWindows"], [])
        self.assertEqual(record({"rateLimits": {"planType": " plus ", "individualLimit": {
            "remainingPercent": 130, "resetsAt": -1}}}, 5), {
            "ts": 5, "provider": "codex", "planType": "plus",
            "extraWindows": [{"id": "individual", "kind": "monthly", "name": "Monthly credit limit",
                              "usedPercent": 0.0}]})

    def test_rollout_fallback_writes_no_extras_and_keeps_the_previous_sidecar(self):
        self.poll()
        before = mcpbar.read_json(self.account)
        # app-server не отвечает, свежий замер есть только в журнале сессии.
        self.replies["account/rateLimits/read"] = [{"exit": True}]
        rollout = os.path.join(mcpbar_codex.CODEX, "sessions", "2026", "09", "23", "rollout-a.jsonl")
        os.makedirs(os.path.dirname(rollout))
        with open(rollout, "w") as fh:
            fh.write(json.dumps({"timestamp": "2026-09-23T12:00:00Z", "type": "event_msg", "payload": {
                "type": "token_count", "rate_limits": {"primary": {"used_percent": 96}}}}) + "\n")
        self.now = NOW + 2 * 24 * 3600
        self.poll()
        status = mcpbar.read_json(os.path.join(self.codex_root, "limits-status.json"))
        self.assertEqual((status["state"], status["detail"]), ("failed", "connection_closed"))
        self.assertEqual(mcpbar.read_json(self.account), before)
        self.assertEqual(self.methods().count("account/read"), 1, "без ответа app-server e-mail не спрашиваем")

    def test_sidecar_failure_never_breaks_the_limits_poll(self):
        real = mcpbar_codex.write_json

        def broken(path, *args, **kwargs):
            if path == self.account:
                raise OSError("disk full")
            return real(path, *args, **kwargs)

        with mock.patch.object(mcpbar_codex, "write_json", broken):
            self.poll()
        self.assertEqual(mcpbar.read_json(os.path.join(self.codex_root, "limits-status.json"))["state"], "ok")
        self.assertFalse(os.path.exists(self.account))
        with open(os.path.join(self.codex_root, "problems.log")) as fh:
            self.assertEqual(fh.read(), "could not write account.json: OSError\n")

    # ── Векторы из тестов T3 Code (коммит 803f21f): тот же ответ через настоящую команду.

    def test_t3_19_answer_without_plan_windows_still_publishes_the_credit_row(self):
        # codexUsageLimits.test.ts:19-45
        self.replies["account/rateLimits/read"] = [{"result": {
            "rateLimits": {"limitId": "spark"},
            "rateLimitResetCredits": {"availableCount": 1, "credits": None},
            "rateLimitsByLimitId": {"codex": {
                "limitId": "codex", "planType": "enterprise_cbp_usage_based", "primary": None,
                "secondary": None, "individualLimit": {"remainingPercent": 99, "resetsAt": 1_784_500_000}}}}}]
        self.poll()
        status = mcpbar.read_json(os.path.join(self.codex_root, "limits-status.json"))
        self.assertEqual((status["state"], status["detail"]), ("empty", "no_windows"))
        self.assertEqual(mcpbar.read_json(self.account), {
            "ts": NOW, "provider": "codex", "planType": "enterprise_cbp_usage_based",
            "email": "user@example.com", "emailCheckedAt": NOW,
            "extraWindows": [{"id": "individual", "kind": "monthly", "name": "Monthly credit limit",
                              "usedPercent": 1.0, "resetsAt": 1_784_500_000}],
            "resetCredits": {"availableCount": 1}})


# ── Векторы из собственных тестов и исходников T3 Code (коммит 803f21f), которых выше нет.
# Имя теста или комментарий называет файл и строки T3: окно «Usage» обязано показывать то же.

class T3ClaudeSpendVectors(unittest.TestCase):
    """claudeUsageLimits.test.ts: месячный бюджет Enterprise, снятый с настоящего ответа."""

    SPEND = {"enabled": True, "percent": 9,
             "used": {"amount_minor": 4_631, "currency": "USD", "exponent": 2},
             "limit": {"amount_minor": 50_000, "currency": "USD", "exponent": 2}}
    EXTRA = {"is_enabled": True, "used_credits": 4_631, "monthly_limit": 50_000,
             "utilization": 9.261999999999999, "currency": "USD", "decimal_places": 2}

    def percent(self, spend, extra):
        return mcpbar.claude_spend({"five_hour": None, "seven_day": None, "spend": spend, "extra_usage": extra})

    def test_t3_138_exact_spend_wins_over_rounded_percent_and_extra_usage(self):
        # claudeUsageLimits.test.ts:138-166 — 4631 из 50000 это 9.262 %, а не округлённые 9.
        record = self.percent(self.SPEND, self.EXTRA)
        self.assertAlmostEqual(record.pop("usedPercent"), 9.262, places=10)
        self.assertEqual(record, {"enabled": True, "zeroCap": False})
        # Рядом лежит extra_usage с другими цифрами (60 %): точные суммы spend всё равно сильнее.
        busy = dict(self.EXTRA, used_credits=30_000, utilization=60)
        self.assertAlmostEqual(self.percent(self.SPEND, busy)["usedPercent"], 9.262, places=10)

    def test_t3_169_falls_back_to_extra_usage_amounts_then_utilization(self):
        # claudeUsageLimits.test.ts:169-184 — spend выключен: суммы extra_usage, а не его округлённые 9.
        off = dict(self.SPEND, enabled=False, used={"amount_minor": 30_000, "currency": "USD", "exponent": 2})
        record = self.percent(off, dict(self.EXTRA, utilization=9))
        self.assertAlmostEqual(record.pop("usedPercent"), 9.262, places=10)
        self.assertEqual(record, {"enabled": True, "zeroCap": False})
        # :185-200 — сумм нет нигде: остаётся utilization.
        bare = {"enabled": True, "used": None, "limit": None, "percent": 9}
        record = self.percent(bare, dict(self.EXTRA, used_credits=None, monthly_limit=None))
        self.assertAlmostEqual(record["usedPercent"], 9.262, places=10)

    def test_t3_202_zero_cap_is_a_flag_not_a_percentage(self):
        # claudeUsageLimits.test.ts:202-216
        self.assertEqual(
            self.percent(None, {"is_enabled": True, "used_credits": 0, "monthly_limit": 0, "utilization": None}),
            {"enabled": True, "zeroCap": True})

    def test_t3_218_disabled_budgets_and_invalid_money_give_no_percentage(self):
        # claudeUsageLimits.test.ts:218-240 — без включённого запасного источника процента нет.
        extra_off = dict(self.EXTRA, is_enabled=False)
        self.assertEqual(self.percent(dict(self.SPEND, enabled=False), extra_off),
                         {"enabled": False, "zeroCap": False})
        euro = dict(self.SPEND, limit=dict(self.SPEND["limit"], currency="EUR"))
        self.assertEqual(self.percent(euro, extra_off), {"enabled": True, "zeroCap": False})
        zero = dict(self.SPEND, limit=dict(self.SPEND["limit"], amount_minor=0))
        self.assertEqual(self.percent(zero, extra_off), {"enabled": True, "zeroCap": False})


class T3CodexAccountVectors(unittest.TestCase):
    """codexUsageLimits.test.ts и codexUsageLimits.ts: строка месячного кредитного лимита и
    накопленные сбросы из ответа account/rateLimits/read."""

    def test_t3_19_enterprise_credit_allowance_has_no_duration(self):
        # codexUsageLimits.test.ts:19-45 — 99 % осталось это 1 % израсходовано; длительности нет.
        answer = {"rateLimits": {"limitId": "spark"}, "rateLimitsByLimitId": {"codex": {
            "limitId": "codex", "planType": "enterprise_cbp_usage_based", "primary": None, "secondary": None,
            "individualLimit": {"remainingPercent": 99, "resetsAt": 1_784_500_000}}}}
        self.assertEqual(mcpbar_codex.codex_account_record(answer, 7), {
            "ts": 7, "provider": "codex", "planType": "enterprise_cbp_usage_based",
            "extraWindows": [{"id": "individual", "kind": "monthly", "name": "Monthly credit limit",
                              "usedPercent": 1.0, "resetsAt": 1_784_500_000}]})
        self.assertEqual(calendar.timegm((2026, 7, 19, 22, 26, 40)), 1_784_500_000,
                         "тот же момент, что T3 печатает как 2026-07-19T22:26:40.000Z")

    def test_t3_47_seat_based_workspace_with_a_zero_credit_cap(self):
        # codexUsageLimits.test.ts:47-79 — исчерпанный кредитный лимит рядом с окнами плана.
        answer = {"rateLimits": {
            "limitId": "codex", "planType": "team", "rateLimitReachedType": None,
            "primary": {"usedPercent": 0, "resetsAt": 1_784_000_000, "windowDurationMins": 300},
            "secondary": {"usedPercent": 14, "resetsAt": 1_784_500_000, "windowDurationMins": 10080},
            "individualLimit": {"remainingPercent": 0, "resetsAt": 1_796_083_200}}}
        self.assertEqual(mcpbar_codex.codex_account_record(answer, 7)["extraWindows"], [
            {"id": "individual", "kind": "monthly", "name": "Monthly credit limit",
             "usedPercent": 100.0, "resetsAt": 1_796_083_200}])

    def test_t3_131_spark_allowance_never_becomes_the_main_row(self):
        # codexUsageLimits.test.ts:131-155 — в rateLimits лежит Spark со своим кредитным лимитом.
        spark = {"limitId": "codex_bengalfox",
                 "individualLimit": {"remainingPercent": 99, "resetsAt": 1_784_500_000},
                 "primary": {"usedPercent": 0, "windowDurationMins": 300},
                 "secondary": {"usedPercent": 90, "windowDurationMins": 10080}}
        answer = {"rateLimits": spark, "rateLimitsByLimitId": {
            "codex_bengalfox": spark, "codex": {"secondary": {"usedPercent": 42, "windowDurationMins": 10080}}}}
        self.assertEqual(mcpbar_codex.codex_account_record(answer, 7),
                         {"ts": 7, "provider": "codex", "extraWindows": []})

    def test_t3_157_legacy_reads_without_a_bucket_map(self):
        # codexUsageLimits.test.ts:157-166 — undefined, null и {} читаются одинаково.
        snapshot = {"planType": "plus", "individualLimit": {"remainingPercent": 40, "resetsAt": 1_784_500_000}}
        expected = mcpbar_codex.codex_account_record({"rateLimits": snapshot}, 7)
        self.assertEqual(expected["extraWindows"][0]["usedPercent"], 60.0)
        for bucket_map in (None, {}):
            with self.subTest(bucket_map=bucket_map):
                self.assertEqual(mcpbar_codex.codex_account_record(
                    {"rateLimits": snapshot, "rateLimitsByLimitId": bucket_map}, 7), expected)

    def test_t3_source_100_only_available_credits_set_the_next_expiry(self):
        # codexUsageLimits.ts:100-114 и schema.gen.ts:30060-30077: список может быть короче счётчика.
        credit = lambda status, expires: {"id": "c", "status": status, "resetType": "codexRateLimits",  # noqa: E731
                                          "grantedAt": 1, "expiresAt": expires}
        record = mcpbar_codex.codex_account_record
        self.assertEqual(record({"rateLimitResetCredits": {"availableCount": 5, "credits": [
            credit("redeeming", 100), credit("redeemed", 200), credit("unknown", 300),
            credit("available", 900), credit("available", None), credit("available", 700)]}}, 7)["resetCredits"],
            {"availableCount": 5, "nextExpiresAt": 700})
        # Пустой список — «подробности запрошены, доступных нет», счётчик при этом остаётся.
        self.assertEqual(record({"rateLimitResetCredits": {"availableCount": 3, "credits": []}}, 7)["resetCredits"],
                         {"availableCount": 3})


if __name__ == "__main__":
    unittest.main()
