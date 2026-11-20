#!/usr/bin/env python3
"""Тесты команды `mcpbar.py usage`: загрузка цен, кэш просмотра, сжатые rollout и сводка на диске.

Сети и настоящих транскриптов здесь нет: LiteLLM изображает местный HTTP-сервер, история лежит
во временных каталогах, распаковщик — подставной исполняемый файл.

Запуск: /usr/bin/python3 -m unittest discover -s tests -v
"""

import contextlib
import fcntl
import http.server
import io
import json
import os
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

import mcpbar  # noqa: E402
import mcpbar_usage as usage  # noqa: E402


def T(text):
    return usage.parse_timestamp_ms(text)


def iso(ms):
    return usage.iso_ms(ms)


NOW = T("2026-11-19T12:37:42.123Z")
HOUR, DAY = usage.HOUR_MS, usage.DAY_MS

RATES = {
    "claude-fable-5": {"input_cost_per_token": 1e-5, "output_cost_per_token": 5e-5,
                       "cache_read_input_token_cost": 1e-6, "cache_creation_input_token_cost": 1.25e-5,
                       "provider_specific_entry": {"fast": 2}},
    "gpt-5.6-sol": {"input_cost_per_token": 2e-6, "output_cost_per_token": 1e-5,
                    "cache_read_input_token_cost": 2e-7, "input_cost_per_token_priority": 4e-6,
                    "output_cost_per_token_priority": 2e-5},
}


def claude_line(message_id, output, at, model="claude-fable-5", session="session-1", cost=None, **extra):
    body = {"type": "assistant", "timestamp": iso(at), "sessionId": session, "requestId": "req_" + message_id,
            "message": {"id": message_id, "model": model,
                        "usage": dict({"input_tokens": 10, "output_tokens": output}, **extra)}}
    if cost is not None:
        body["costUSD"] = cost
    return json.dumps(body) + "\n"


def codex_rollout(session, at, outputs, model="gpt-5.6-sol", service_tier=None):
    lines = [{"type": "session_meta", "timestamp": iso(at), "payload": {"type": "session_meta", "id": session}},
             {"type": "turn_context", "timestamp": iso(at), "payload": {"type": "turn_context", "model": model}}]
    if service_tier:
        lines.append({"type": "event_msg", "timestamp": iso(at),
                      "payload": {"type": "thread_settings_applied", "thread_settings": {"service_tier": service_tier}}})
    for index, output in enumerate(outputs):
        lines.append({"type": "event_msg", "timestamp": iso(at + index * 1000), "payload": {
            "type": "token_count", "info": {"last_token_usage": {
                "input_tokens": 100, "cached_input_tokens": 40, "output_tokens": output}}}})
    return "".join(json.dumps(line) + "\n" for line in lines)


class UsageCase(unittest.TestCase):
    """Временные корень состояния и каталоги транскриптов, неподвижные часы, сеть закрыта."""

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.tmp = os.path.realpath(self._dir.name)
        self.now = NOW
        saved_root = mcpbar.ROOT
        mcpbar.ROOT = os.path.join(self.tmp, "control-bar")
        self.addCleanup(setattr, mcpbar, "ROOT", saved_root)
        self.empty_bin = os.path.join(self.tmp, "empty-bin")
        os.makedirs(self.empty_bin)
        for patch in (
                mock.patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": os.path.join(self.tmp, "claude"),
                                             "CODEX_HOME": os.path.join(self.tmp, "codex")}),
                mock.patch.object(usage, "now_ms", lambda: self.now),
                mock.patch.object(usage, "system_time_zone", lambda: "UTC"),
                # Порт 9 закрыт: тест, который забыл про цены, получает отказ сразу, а не ходит в сеть.
                mock.patch.object(usage, "LITELLM_RATES_URL", "http://127.0.0.1:9/raw"),
                mock.patch.object(usage, "LITELLM_RATES_API_URL", "http://127.0.0.1:9/api")):
            patch.start()
            self.addCleanup(patch.stop)
        self.seed_rates(RATES)

    def state(self, name):
        return os.path.join(mcpbar.ROOT, "usage", name)

    def seed_rates(self, document, fetched_at=None):
        mcpbar.write_json(self.state("model-rates.json"),
                          {"fetchedAtMs": self.now if fetched_at is None else fetched_at, "document": document})

    def put(self, relative, text, age=0):
        """Файл транскрипта с mtime на `age` миллисекунд раньше «сейчас»."""
        path = os.path.join(self.tmp, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(text.encode("utf-8") if isinstance(text, str) else text)
        self.touch(path, age)
        return path

    def touch(self, path, age=0):
        moment = (self.now - age) * 1000000
        os.utime(path, ns=(moment, moment))

    def run_usage(self, *argv, expect=0):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = usage.command(list(argv))
        self.assertEqual(code, expect, err.getvalue())
        # Команда не печатает ничего из транскриптов: при успехе — ничего вообще.
        self.assertEqual(out.getvalue(), "")
        if expect == 0:
            self.assertEqual(err.getvalue(), "")
        return err.getvalue()

    def summary(self):
        with open(self.state("summary.json")) as handle:
            return json.load(handle)

    def status(self):
        with open(self.state("status.json")) as handle:
            return json.load(handle)

    def period(self, days=90):
        return self.summary()["periods"][str(days)]

    def source(self, provider, days=90):
        return next(source for source in self.period(days)["sources"] if source["provider"] == provider)

    def output(self, provider, days=90):
        return sum(bucket["totals"]["outputTokens"] for bucket in self.period(days)["buckets"]
                   if bucket["provider"] == provider)

    def cached_paths(self):
        with contextlib.closing(sqlite3.connect(self.state("scan-cache.sqlite3"))) as db:
            return sorted(os.path.relpath(row[0], self.tmp) for row in db.execute("SELECT path FROM files"))

    def fake_zstd(self):
        """Подставной распаковщик: «сжатый» файл теста — обычный текст, а «zstd» его просто печатает."""
        path = os.path.join(self.tmp, "fake-zstd")
        with open(path, "w") as handle:
            handle.write('#!/bin/sh\nfor last; do :; done\nexec /bin/cat "$last"\n')
        os.chmod(path, 0o755)
        return path

    def no_decompressor(self):
        for patch in (mock.patch.object(usage, "ZSTD_PATHS", ()), mock.patch.object(usage, "NODE_PATHS", ()),
                      mock.patch.dict(os.environ, {"PATH": self.empty_bin})):
            patch.start()
            self.addCleanup(patch.stop)


class Summary(UsageCase):
    def test_сводка_четыре_периода_и_статус(self):
        self.put("claude/projects/app/s1.jsonl", claude_line("m1", 5, NOW - HOUR), age=HOUR)
        self.put("codex/sessions/2026/11/16/rollout-a.jsonl", codex_rollout("codex-a", NOW - 3 * DAY, [7, 9]), age=3 * DAY)
        self.run_usage()
        summary = self.summary()
        self.assertEqual({key: summary[key] for key in ("version", "readAt", "timeZone")},
                         {"version": 1, "readAt": NOW // 1000, "timeZone": "UTC"})
        self.assertEqual(summary["pricing"], {"status": "cached", "source": "litellm", "fetchedAt": NOW // 1000,
                                              "knownModels": 2})
        self.assertIsInstance(summary["scanDurationMs"], int)
        self.assertEqual(list(summary["periods"]), ["1", "7", "30", "90"])
        day = summary["periods"]["1"]
        self.assertEqual({key: day[key] for key in ("resolution", "sinceDay", "untilDay", "sinceTime", "untilTime")}, {
            "resolution": "hour", "sinceDay": "2026-11-18", "untilDay": "2026-11-19",
            "sinceTime": "2026-11-18T12:37:00.000Z", "untilTime": "2026-11-19T12:37:00.000Z"})
        (bucket,) = day["buckets"]
        self.assertEqual(bucket, {
            "day": "2026-11-19", "hourStart": "2026-11-19T11:37:00.000Z", "provider": "claude", "model": "claude-fable-5",
            "totals": {"uncachedInputTokens": 10, "cachedInputTokens": 0, "cacheCreationTokens": 0, "outputTokens": 5,
                       "reasoningTokens": 0},
            "costUsd": bucket["costUsd"], "cacheSavingsUsd": 0.0,
            "categoryCostUsd": {"input": 0.0001, "cacheRead": 0.0, "cacheWrite": 0.0, "output": 0.00025},
            "costSource": "modelPriced", "records": 1, "unpricedRecords": 0, "unpricedTokens": 0, "sessions": 1})
        self.assertAlmostEqual(bucket["costUsd"], 0.00035, places=12)
        week = summary["periods"]["7"]
        self.assertEqual({key: week[key] for key in week if key not in ("buckets", "sources")},
                         {"resolution": "day", "sinceDay": "2026-11-13", "untilDay": "2026-11-19"})
        self.assertEqual((summary["periods"]["30"]["sinceDay"], summary["periods"]["90"]["sinceDay"]),
                         ("2026-10-21", "2026-08-22"))
        self.assertEqual([(b["day"], b["provider"], b["totals"]["outputTokens"]) for b in week["buckets"]],
                         [("2026-11-16", "codex", 16), ("2026-11-19", "claude", 5)])
        codex = week["buckets"][0]
        self.assertEqual(codex["totals"], {"uncachedInputTokens": 120, "cachedInputTokens": 80, "cacheCreationTokens": 0,
                                           "outputTokens": 16, "reasoningTokens": 0})
        self.assertAlmostEqual(codex["costUsd"], 120 * 2e-6 + 80 * 2e-7 + 16 * 1e-5, places=12)
        self.assertEqual(week["sources"], [
            {"provider": "claude", "status": "ok", "scannedFiles": 1, "skippedFiles": 0, "malformedRecords": 0,
             "distinctSessions": 1, "message": None},
            {"provider": "codex", "status": "ok", "scannedFiles": 1, "skippedFiles": 0, "malformedRecords": 0,
             "distinctSessions": 1, "message": None}])
        self.assertEqual(self.source("codex", 1), {
            "provider": "codex", "status": "ok", "scannedFiles": 0, "skippedFiles": 0, "malformedRecords": 0,
            "distinctSessions": 0, "message": None})
        status = self.status()
        self.assertEqual({key: status[key] for key in ("state", "detail", "done", "total")},
                         {"state": "ok", "detail": "", "done": 0, "total": 0})

    def test_файлы_состояния_закрыты_для_чужих(self):
        self.put("claude/projects/app/s1.jsonl", claude_line("m1", 5, NOW - HOUR), age=HOUR)
        self.run_usage()
        directory = os.path.join(mcpbar.ROOT, "usage")
        self.assertEqual(stat.S_IMODE(os.stat(directory).st_mode), 0o700)
        for name in os.listdir(directory):
            self.assertEqual(stat.S_IMODE(os.stat(os.path.join(directory, name)).st_mode), 0o600, name)
        self.assertEqual(sorted(os.listdir(directory)),
                         ["model-rates.json", "scan-cache.sqlite3", "scan.lock", "status.json", "summary.json"])

    def test_сводка_пишется_раньше_статуса_ok_а_ход_виден(self):
        for index in range(3):
            self.put("claude/projects/app/s%d.jsonl" % index, claude_line("m%d" % index, 5, NOW - HOUR), age=HOUR)
        events, real = [], mcpbar.write_json

        def spy(path, data, *args, **kwargs):
            name = os.path.basename(path)
            events.append((name, data.get("state"), data.get("done"), data.get("total")) if name == "status.json" else (name,))
            return real(path, data, *args, **kwargs)

        with mock.patch.object(mcpbar, "write_json", spy), mock.patch.object(usage, "STATUS_INTERVAL", 0):
            self.run_usage()
        events = [event for event in events if event[0] in ("status.json", "summary.json")]
        self.assertEqual(events[0], ("status.json", "scanning", 0, 0))
        self.assertEqual(events[1:5], [("status.json", "scanning", done, 3) for done in range(4)])
        self.assertEqual(events[-2:], [("summary.json",), ("status.json", "ok", 0, 0)])

    def test_нет_каталогов_истории(self):
        self.run_usage()
        for days in (1, 7, 30, 90):
            self.assertEqual(self.period(days)["buckets"], [])
            self.assertEqual(self.period(days)["sources"], [
                {"provider": provider, "status": "missing", "scannedFiles": 0, "skippedFiles": 0,
                 "malformedRecords": 0, "distinctSessions": 0, "message": "no_history"}
                for provider in ("claude", "codex")])

    def test_период_видит_только_свои_файлы_и_сессии(self):
        self.put("claude/projects/app/old.jsonl", claude_line("m1", 5, NOW - 10 * DAY, session="old"), age=10 * DAY)
        self.put("claude/projects/app/new.jsonl", claude_line("m2", 7, NOW - HOUR, session="new")
                 + claude_line("m3", 1, NOW - 2 * HOUR, session="other"), age=HOUR)
        self.put("claude/projects/app/empty.jsonl", '{"type":"user"}\n', age=HOUR)
        self.run_usage()
        self.assertEqual([(days, self.source("claude", days)["scannedFiles"], self.source("claude", days)["skippedFiles"],
                           self.source("claude", days)["distinctSessions"], self.output("claude", days))
                          for days in (1, 7, 30, 90)],
                         [(1, 1, 1, 2, 8), (7, 1, 1, 2, 8), (30, 2, 1, 3, 13), (90, 2, 1, 3, 13)])

    def test_файл_старше_окна_не_открывается(self):
        self.put("claude/projects/app/ancient.jsonl", claude_line("m1", 5, NOW - 100 * DAY), age=100 * DAY)
        with mock.patch.object(usage, "read_transcript", side_effect=AssertionError("открыт")):
            self.run_usage()
        self.assertEqual(self.source("claude")["scannedFiles"], 0)

    def test_при_общем_ключе_ячейку_решает_первый_по_имени_файл(self):
        shared = dict(at=NOW - HOUR)
        self.put("claude/projects/b.jsonl", claude_line("m1", 5, model="model-b", **shared), age=HOUR)
        self.put("claude/projects/a/x.jsonl", claude_line("m1", 9, model="model-a", **shared), age=HOUR)
        self.put("claude/projects/abc.jsonl", claude_line("m2", 5, model="model-file", **shared), age=HOUR)
        self.put("claude/projects/abc/sub.jsonl", claude_line("m2", 5, model="model-dir", **shared), age=HOUR)
        self.run_usage()
        self.assertEqual([(b["model"], b["records"], b["totals"]["outputTokens"]) for b in self.period(7)["buckets"]],
                         [("model-a", 1, 9), ("model-dir", 1, 5)])

    def test_пояс_машины_определяет_дни(self):
        self.put("claude/projects/app/s1.jsonl", claude_line("m1", 5, T("2026-11-18T23:30:00Z")), age=13 * HOUR)
        with mock.patch.object(usage, "system_time_zone", lambda: "Europe/Berlin"):
            self.run_usage()
        self.assertEqual((self.summary()["timeZone"], self.period(7)["buckets"][0]["day"]), ("Europe/Berlin", "2026-11-19"))

    def test_имя_пояса_машины(self):
        with mock.patch.dict(os.environ, {"TZ": "Asia/Kathmandu"}):
            self.assertEqual(REAL_ZONE(), "Asia/Kathmandu")
        with mock.patch.dict(os.environ, {"TZ": "Нет/Такого"}), \
                mock.patch.object(os.path, "realpath", lambda path: "/var/db/timezone/zoneinfo/Europe/Berlin"):
            self.assertEqual(REAL_ZONE(), "Europe/Berlin")
        with mock.patch.dict(os.environ, {"TZ": ""}), mock.patch.object(os.path, "realpath", lambda path: "/nowhere"):
            self.assertEqual(REAL_ZONE(), "UTC")


REAL_ZONE = usage.system_time_zone


class Cache(UsageCase):
    def test_неизменённые_файлы_второй_раз_не_читаются(self):
        self.put("claude/projects/app/s1.jsonl", claude_line("m1", 5, NOW - HOUR), age=HOUR)
        self.put("codex/sessions/rollout-a.jsonl", codex_rollout("codex-a", NOW - HOUR, [7]), age=HOUR)
        self.run_usage()
        first = self.summary()["periods"]
        with mock.patch.object(usage, "read_transcript", side_effect=AssertionError("открыт")):
            self.run_usage()
        self.assertEqual(self.summary()["periods"], first)

    def test_выросший_файл_дочитывается_с_места_остановки(self):
        early, final = (claude_line("m1", output, NOW - HOUR, cache_read_input_tokens=67934,
                                    cache_creation_input_tokens=1097) for output in (3, 264))
        path = self.put("claude/projects/app/s1.jsonl", early, age=HOUR)
        rollout = self.put("codex/sessions/rollout-a.jsonl", codex_rollout("codex-a", NOW - HOUR, [7]), age=HOUR)
        self.run_usage()
        self.assertEqual((self.output("claude"), self.output("codex")), (3, 7))
        with open(path, "a") as handle:
            handle.write(final + claude_line("m2", 11, NOW - HOUR))
        self.touch(path, 60000)
        with open(rollout, "a") as handle:
            handle.write(codex_rollout("codex-a", NOW - HOUR + 5000, [8]).split("\n", 2)[2])
        self.touch(rollout, 60000)
        calls, real = [], usage.read_transcript

        def spy(path, provider, resume_from=None, decompress=None):
            parsed = real(path, provider, resume_from, decompress)
            calls.append((provider, resume_from is not None, parsed["resumed"], len(parsed["records"])))
            return parsed

        with mock.patch.object(usage, "read_transcript", spy):
            self.run_usage()
        self.assertEqual(sorted(calls), [("claude", True, True, 2), ("codex", True, True, 1)])
        # Поздняя копия m1 слилась с сохранённой первой: запрос один, расход — максимальный.
        (bucket,) = [b for b in self.period(7)["buckets"] if b["provider"] == "claude"]
        self.assertEqual((bucket["records"], bucket["totals"]["outputTokens"], bucket["totals"]["cachedInputTokens"]),
                         (2, 275, 67934))
        self.assertEqual(self.output("codex"), 15)

    def test_хвост_без_перевода_строки_сливается_с_началом_ответа(self):
        early, final = (claude_line("msg_1", output, NOW - HOUR, input_tokens=2, cache_read_input_tokens=67934,
                                    cache_creation_input_tokens=1097) for output in (3, 264))
        path = self.put("claude/projects/app/s1.jsonl", early + final.rstrip("\n"), age=HOUR)
        expected = 2 * 1e-5 + 67934 * 1e-6 + 1097 * 1.25e-5 + 264 * 5e-5
        for _attempt in range(2):
            self.run_usage()
            (bucket,) = self.period(7)["buckets"]
            self.assertEqual((bucket["records"], bucket["totals"]["outputTokens"]), (1, 264))
            self.assertAlmostEqual(bucket["costUsd"], expected, places=12)
            with open(path, "a") as handle:
                handle.write("\n")
            self.touch(path, 60000)

    def test_тот_же_размер_с_новым_mtime_читается_заново(self):
        long = dict(cache_read_input_tokens=1000, cache_creation_input_tokens=1000)
        before = claude_line("m1", 5, NOW - HOUR, model="claude-fable-5", **long)
        after = claude_line("m1", 5, NOW - HOUR, model="claude-other-5", **long)
        # Правка лежит раньше последних 64 байт: сверка хвоста её не видит, выручает только правило
        # «тот же размер с новым mtime — файл переписан».
        self.assertEqual((len(before), before[-64:]), (len(after), after[-64:]))
        self.put("claude/projects/app/s1.jsonl", before, age=HOUR)
        self.run_usage()
        self.put("claude/projects/app/s1.jsonl", after, age=60000)
        self.run_usage()
        self.assertEqual([b["model"] for b in self.period(7)["buckets"]], ["claude-other-5"])

    def test_тот_же_mtime_с_новым_размером_читается_заново(self):
        first = claude_line("m1", 5, NOW - HOUR)
        self.put("claude/projects/app/s1.jsonl", first, age=HOUR)
        self.run_usage()
        self.put("claude/projects/app/s1.jsonl", first + claude_line("m2", 7, NOW - HOUR), age=HOUR)
        self.run_usage()
        self.assertEqual(self.output("claude"), 12)

    def test_удалённый_транскрипт_продолжает_считаться(self):
        path = self.put("claude/projects/app/s1.jsonl", claude_line("m1", 5, NOW - HOUR), age=HOUR)
        self.run_usage()
        first = self.summary()["periods"]
        os.remove(path)
        for _attempt in range(2):
            self.run_usage()
            self.assertEqual(self.summary()["periods"], first)

    def test_история_старше_92_дней_вычищается(self):
        kept = self.put("claude/projects/app/kept.jsonl", claude_line("m1", 1, NOW - 70 * DAY), age=70 * DAY)
        gone = self.put("claude/projects/app/gone.jsonl", claude_line("m2", 2, NOW - 80 * DAY), age=80 * DAY)
        self.run_usage()
        self.assertEqual((self.output("claude"), len(self.cached_paths())), (3, 2))
        os.remove(kept)
        os.remove(gone)
        self.now = NOW + 13 * DAY  # сохранённым записям теперь 83 и 93 дня
        self.run_usage()
        self.assertEqual(self.cached_paths(), ["claude/projects/app/kept.jsonl"])
        self.assertEqual(self.output("claude"), 1)
        self.now = NOW  # возврат часов не возвращает вычищенное
        self.run_usage()
        self.assertEqual(self.output("claude"), 1)

    def test_переехавший_rollout_codex_считается_один_раз(self):
        lines = ['{"type":"session_meta","payload":{"id":"codex-account-session"}}',
                 '{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}']
        lines += ['{"type":"event_msg","timestamp":"%s","payload":{"type":"token_count","info":{"last_token_usage":'
                  '{"input_tokens":10,"output_tokens":%d}}}}' % (iso(NOW - HOUR), output) for output in (11, 12, 11)]
        path = self.put("codex/sessions/rollout.jsonl", "\n".join(lines) + "\n", age=HOUR)
        self.run_usage()
        self.assertEqual((self.output("codex"), self.period()["buckets"][0]["records"]), (34, 3))
        os.rename(path, os.path.join(os.path.dirname(path), "moved.jsonl"))
        self.run_usage()
        self.assertEqual(self.cached_paths(), ["codex/sessions/moved.jsonl", "codex/sessions/rollout.jsonl"])
        self.assertEqual((self.output("codex"), self.period()["buckets"][0]["records"]), (34, 3))
        self.assertEqual(self.source("codex")["distinctSessions"], 1)
        shutil.rmtree(os.path.join(self.tmp, "codex", "sessions"))
        self.run_usage()
        self.assertEqual(self.output("codex"), 34)
        self.assertEqual((self.source("codex")["status"], self.source("codex")["message"]), ("ok", "no_history"))

    def test_несогласованные_записи_codex_делают_источник_неполным(self):
        lines = codex_rollout("codex-a", NOW - HOUR, [7]) + json.dumps({
            "type": "event_msg", "timestamp": iso(NOW - HOUR + 9000),
            "payload": {"type": "token_count", "info": {"last_token_usage": {"input_tokens": "40", "output_tokens": 2}}}}) + "\n"
        self.put("codex/sessions/rollout-a.jsonl", lines, age=HOUR)
        self.run_usage()
        source = self.source("codex")
        self.assertEqual((source["status"], source["malformedRecords"], source["message"], self.output("codex")),
                         ("partial", 1, None, 7))

    @unittest.skipIf(os.geteuid() == 0, "root читает и закрытые файлы")
    def test_непрочитанный_файл_оставляет_старые_записи_и_статус_partial(self):
        path = self.put("claude/projects/app/s1.jsonl", claude_line("m1", 5, NOW - HOUR), age=HOUR)
        locked = os.path.join(self.tmp, "claude/projects/locked")
        self.put("claude/projects/locked/s2.jsonl", claude_line("m2", 9, NOW - HOUR), age=HOUR)
        self.run_usage()
        with open(path, "a") as handle:
            handle.write(claude_line("m3", 100, NOW - HOUR))
        self.touch(path, 60000)
        os.chmod(path, 0)
        os.chmod(locked, 0)
        self.addCleanup(os.chmod, locked, 0o700)
        self.run_usage()
        source = self.source("claude")
        # s2 лежит в закрытом каталоге и считается по сохранённым записям, как удалённый.
        self.assertEqual((source["status"], source["message"], source["scannedFiles"], self.output("claude")),
                         ("partial", "read_failed", 2, 14))
        os.chmod(path, 0o600)
        os.chmod(locked, 0o700)
        self.run_usage()
        self.assertEqual((self.source("claude")["status"], self.output("claude")), ("ok", 114))

    def test_испорченный_кэш_удаляется_и_собирается_заново(self):
        self.put("claude/projects/app/s1.jsonl", claude_line("m1", 5, NOW - HOUR), age=HOUR)
        self.run_usage()
        with open(self.state("scan-cache.sqlite3"), "wb") as handle:
            handle.write(b"this is not a database" * 100)
        self.assertEqual(self.run_usage(expect=1), "usage: cache_failed\n")
        self.assertEqual((self.status()["state"], self.status()["detail"]), ("failed", "cache_failed"))
        self.assertFalse(os.path.exists(self.state("scan-cache.sqlite3")))
        self.run_usage()
        self.assertEqual((self.status()["state"], self.output("claude")), ("ok", 5))

    def damage(self, statement, path):
        with contextlib.closing(sqlite3.connect(self.state("scan-cache.sqlite3"))) as db:
            self.assertEqual(db.execute(statement + " WHERE path = ?", (path,)).rowcount, 1)
            db.commit()

    def test_битая_строка_кэша_стоит_пересмотра_одного_файла(self):
        # В кэше единственная копия расхода из транскриптов, которых на диске уже нет: из-за одной
        # нечитаемой строки другого файла терять её нельзя.
        gone = self.put("claude/projects/app/gone.jsonl", claude_line("m1", 5, NOW - HOUR), age=HOUR)
        kept = self.put("claude/projects/app/kept.jsonl", claude_line("m2", 7, NOW - HOUR), age=HOUR)
        whole = self.put("claude/projects/app/whole.jsonl", claude_line("m3", 9, NOW - HOUR), age=HOUR)
        self.run_usage()
        os.remove(gone)
        read, real = [], usage.read_transcript

        def reading(path, *args, **kwargs):
            read.append(os.path.basename(path))
            return real(path, *args, **kwargs)

        for statement in ("UPDATE records SET records = '[[1, '", "UPDATE records SET tail = '[[1, '",
                          "UPDATE files SET sessions = '['", "UPDATE files SET models = '['"):
            with self.subTest(statement=statement):
                self.damage(statement, kept)
                del read[:]
                with mock.patch.object(usage, "read_transcript", reading):
                    self.run_usage()
                self.assertEqual((self.status()["state"], self.output("claude")), ("ok", 21))
                self.assertEqual(read, ["kept.jsonl"])
                self.assertEqual(len(self.cached_paths()), 3)

    def test_битая_строка_выросшего_файла_перечитывает_его_целиком(self):
        path = self.put("codex/sessions/rollout-a.jsonl", codex_rollout("codex-a", NOW - HOUR, [7]), age=HOUR)
        for statement in ("UPDATE records SET records = '[[1, '", "UPDATE records SET state = '{'"):
            with self.subTest(statement=statement):
                self.put("codex/sessions/rollout-a.jsonl", codex_rollout("codex-a", NOW - HOUR, [7]), age=HOUR)
                self.run_usage()
                self.damage(statement, path)
                self.put("codex/sessions/rollout-a.jsonl", codex_rollout("codex-a", NOW - HOUR, [7, 100]), age=60000)
                self.run_usage()
                self.assertEqual((self.status()["state"], self.output("codex")), ("ok", 107))

    def test_строка_удалённого_транскрипта_теряется_одна(self):
        gone = self.put("claude/projects/app/gone.jsonl", claude_line("m1", 5, NOW - HOUR), age=HOUR)
        other = self.put("claude/projects/app/other.jsonl", claude_line("m2", 7, NOW - HOUR), age=HOUR)
        self.run_usage()
        os.remove(gone)
        os.remove(other)
        self.damage("UPDATE records SET records = '[[1, '", gone)
        self.run_usage()
        self.assertEqual((self.output("claude"), self.cached_paths()), (7, ["claude/projects/app/other.jsonl"]))

    def test_много_битых_строк_это_порча_всей_базы(self):
        for name in ("a", "b", "c"):
            self.put("claude/projects/app/%s.jsonl" % name, claude_line("m-" + name, 5, NOW - HOUR), age=HOUR)
        self.run_usage()
        with contextlib.closing(sqlite3.connect(self.state("scan-cache.sqlite3"))) as db:
            db.execute("UPDATE records SET records = '[[1, '")
            db.commit()
        with mock.patch.object(usage, "BROKEN_ROWS_LIMIT", 2):
            self.assertEqual(self.run_usage(expect=1), "usage: cache_failed\n")
        self.assertFalse(os.path.exists(self.state("scan-cache.sqlite3")))
        self.run_usage()
        self.assertEqual(self.output("claude"), 15)

    def test_сбой_запроса_к_кэшу_файл_не_удаляет(self):
        gone = self.put("claude/projects/app/gone.jsonl", claude_line("m1", 5, NOW - HOUR), age=HOUR)
        self.run_usage()
        os.remove(gone)
        for error in (sqlite3.IntegrityError("x"), sqlite3.ProgrammingError("x"), sqlite3.DataError("x"),
                      sqlite3.OperationalError("database is locked")):
            with self.subTest(error=error), mock.patch.object(usage, "scan", side_effect=error):
                self.assertEqual(self.run_usage(expect=1), "usage: cache_failed\n")
                self.assertTrue(os.path.exists(self.state("scan-cache.sqlite3")))
        self.run_usage()
        self.assertEqual(self.output("claude"), 5)


class Failures(UsageCase):
    def test_сбой_пишет_категорию_и_не_выходит_наружу(self):
        self.put("claude/projects/app/s1.jsonl", claude_line("m1", 5, NOW - HOUR), age=HOUR)
        with mock.patch.object(usage, "scan", side_effect=RuntimeError("текст из транскрипта")):
            self.assertEqual(self.run_usage(expect=1), "usage: scan_failed\n")
        status = self.status()
        self.assertEqual((status["state"], status["detail"]), ("failed", "scan_failed"))
        self.assertFalse(os.path.exists(self.state("summary.json")))

    def test_сбой_не_затирает_прошлую_сводку(self):
        self.put("claude/projects/app/s1.jsonl", claude_line("m1", 5, NOW - HOUR), age=HOUR)
        self.run_usage()
        before = self.summary()
        with mock.patch.object(usage, "aggregate", side_effect=RuntimeError("сбой")):
            self.run_usage(expect=1)
        self.assertEqual(self.summary(), before)

    def test_нечисло_в_сводке_это_сбой_а_не_битый_файл(self):
        self.put("claude/projects/app/s1.jsonl", claude_line("m1", 5, NOW - HOUR), age=HOUR)
        real = usage.aggregate

        def aggregate(*args):
            buckets, sessions = real(*args)
            buckets[0]["cacheSavingsUsd"] = float("inf")
            return buckets, sessions

        with mock.patch.object(usage, "aggregate", aggregate):
            self.assertEqual(self.run_usage(expect=1), "usage: scan_failed\n")
        self.assertFalse(os.path.exists(self.state("summary.json")))

    def test_безумная_цена_из_таблицы_не_срывает_просмотр(self):
        # Сохранённая таблица — тот же чужой файл из сети: 10 × (1e308 − 0) дало бы бесконечную
        # экономию кэша и сбой всей команды, отрицательная цена — отрицательный расход.
        self.put("claude/projects/app/s1.jsonl",
                 claude_line("m1", 0, NOW - HOUR, input_tokens=0, cache_read_input_tokens=10)
                 + claude_line("m2", 5, NOW - HOUR, model="claude-other-5"), age=HOUR)
        self.seed_rates({"claude-fable-5": {"input_cost_per_token": 1e308, "output_cost_per_token": 0,
                                            "cache_read_input_token_cost": 0},
                         "claude-other-5": {"input_cost_per_token": 1e-5, "output_cost_per_token": -5e-5}})
        self.run_usage()
        self.assertEqual(self.summary()["pricing"]["knownModels"], 0)
        self.assertEqual([(b["costUsd"], b["cacheSavingsUsd"], b["costSource"]) for b in self.period(7)["buckets"]],
                         [(0, 0, "unpriced")] * 2)

    def test_второй_просмотр_не_мешает_идущему(self):
        os.makedirs(os.path.dirname(self.state("scan.lock")), exist_ok=True)
        mcpbar.write_json(self.state("status.json"), {"state": "scanning", "done": 5, "total": 9})
        with open(self.state("scan.lock"), "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.assertEqual(self.run_usage(expect=1), "usage: busy\n")
        self.assertEqual(self.status(), {"state": "scanning", "done": 5, "total": 9})
        self.run_usage()

    def test_даже_сбой_записи_статуса_не_выходит_наружу(self):
        with mock.patch.object(mcpbar, "write_json", side_effect=OSError("диск полон")):
            self.assertEqual(self.run_usage(expect=1), "usage: scan_failed\n")


class Compressed(UsageCase):
    def setUp(self):
        super().setUp()
        self.rollout = codex_rollout("codex-z", NOW - HOUR, [7, 9])

    def test_сжатый_rollout_читается_через_внешний_распаковщик_и_кэшируется(self):
        self.put("codex/sessions/2026/11/19/rollout-z.jsonl.zst", self.rollout, age=HOUR)
        with mock.patch.object(usage, "ZSTD_PATHS", (self.fake_zstd(),)):
            self.run_usage()
        self.assertEqual((self.output("codex"), self.source("codex")["status"]), (16, "ok"))
        # Архив неизменен: второй раз распаковщик не нужен вовсе.
        with mock.patch.object(usage, "find_decompressor", side_effect=AssertionError("искали")):
            self.run_usage()
        self.assertEqual(self.output("codex"), 16)

    def test_без_распаковщика_источник_неполный_и_архив_не_кэшируется(self):
        self.put("codex/sessions/rollout-z.jsonl.zst", self.rollout, age=HOUR)
        self.put("codex/sessions/rollout-a.jsonl", codex_rollout("codex-a", NOW - HOUR, [3]), age=HOUR)
        self.no_decompressor()
        self.run_usage()
        self.assertEqual(self.source("codex"), {
            "provider": "codex", "status": "partial", "scannedFiles": 1, "skippedFiles": 1, "malformedRecords": 0,
            "distinctSessions": 1, "message": "zstd_unavailable"})
        self.assertEqual((self.output("codex"), self.cached_paths()), (3, ["codex/sessions/rollout-a.jsonl"]))
        with mock.patch.object(usage, "ZSTD_PATHS", (self.fake_zstd(),)):
            self.run_usage()
        self.assertEqual((self.output("codex"), self.source("codex")["status"]), (19, "ok"))

    def test_распаковщик_ищется_в_path(self):
        self.no_decompressor()
        shutil.copy(self.fake_zstd(), os.path.join(self.empty_bin, "zstd"))
        self.assertEqual(usage.find_decompressor(), [os.path.join(self.empty_bin, "zstd"), "-dcq", "--"])

    def test_сбой_распаковки_это_непрочитанный_файл(self):
        self.put("codex/sessions/rollout-z.jsonl.zst", self.rollout, age=HOUR)
        broken = os.path.join(self.tmp, "broken-zstd")
        with open(broken, "w") as handle:
            handle.write('#!/bin/sh\nfor last; do :; done\n/bin/cat "$last"\nexit 1\n')
        os.chmod(broken, 0o755)
        with mock.patch.object(usage, "ZSTD_PATHS", (broken,)):
            self.run_usage()
        source = self.source("codex")
        self.assertEqual((source["status"], source["message"], self.output("codex"), self.cached_paths()),
                         ("partial", "read_failed", 0, []))

    def test_архив_заменяет_сохранённые_записи_оригинала(self):
        plain = self.put("codex/sessions/rollout-z.jsonl", self.rollout, age=HOUR)
        self.run_usage()
        os.rename(plain, plain + ".zst")
        with mock.patch.object(usage, "ZSTD_PATHS", (self.fake_zstd(),)):
            self.run_usage()
        self.assertEqual(self.cached_paths(), ["codex/sessions/rollout-z.jsonl.zst"])
        self.assertEqual((self.output("codex"), self.period()["buckets"][0]["records"]), (16, 2))

    @unittest.skipUnless(shutil.which("zstd") or os.path.exists("/opt/homebrew/bin/zstd"), "нет бинарника zstd")
    def test_настоящий_zstd(self):
        binary = shutil.which("zstd") or "/opt/homebrew/bin/zstd"
        plain = self.put("codex/sessions/rollout-z.jsonl", self.rollout)
        subprocess.run([binary, "-q", "--rm", plain], check=True)
        self.touch(plain + ".zst", HOUR)
        damaged = self.put("codex/sessions/rollout-y.jsonl.zst", b"\x28\xb5\x2f\xfd" + b"\x00" * 40, age=HOUR)
        with mock.patch.object(usage, "ZSTD_PATHS", (binary,)):
            self.run_usage()
        self.assertEqual((self.output("codex"), self.source("codex")["message"]), (16, "read_failed"))
        os.remove(damaged)
        self.run_usage()
        self.assertEqual(self.source("codex")["status"], "ok")

    def test_node_с_zstd_как_запасной_распаковщик(self):
        node = shutil.which("node")
        if not node or subprocess.run([node, "-e", usage.NODE_ZSTD_PROBE]).returncode != 0:
            self.skipTest("нет node с zstd в node:zlib")
        plain = self.put("codex/sessions/rollout-z.jsonl", self.rollout)
        subprocess.run([node, "-e", "const fs=require('node:fs');fs.writeFileSync(process.argv[1]+'.zst',"
                        "require('node:zlib').zstdCompressSync(fs.readFileSync(process.argv[1])))", plain], check=True)
        os.remove(plain)
        self.touch(plain + ".zst", HOUR)
        self.no_decompressor()
        with mock.patch.object(usage, "NODE_PATHS", (node,)):
            self.assertEqual(usage.find_decompressor()[:2], [node, "-e"])
            self.run_usage()
        self.assertEqual((self.output("codex"), self.source("codex")["status"]), (16, "ok"))


class Pool(UsageCase):
    def history(self):
        for index in range(6):
            self.put("claude/projects/app/s%d.jsonl" % index,
                     claude_line("m%d" % index, index + 1, NOW - HOUR) + claude_line("shared", 50, NOW - HOUR), age=HOUR)
            self.put("codex/sessions/rollout-%d.jsonl" % index, codex_rollout("codex-%d" % index, NOW - HOUR, [index + 1]),
                     age=HOUR)

    def test_пул_процессов_даёт_тот_же_ответ_что_один_процесс(self):
        self.history()
        self.run_usage()
        serial = self.summary()["periods"]
        self.assertEqual((self.output("claude"), self.output("codex")), (71, 21))
        shutil.rmtree(os.path.join(mcpbar.ROOT, "usage"))
        self.seed_rates(RATES)
        created = []
        real = usage.concurrent.futures.ProcessPoolExecutor

        def executor(*args, **kwargs):
            created.append(args)
            return real(*args, **kwargs)

        with mock.patch.object(usage, "POOL_MIN_BYTES", 0), mock.patch.object(usage, "WORKERS", 2), \
                mock.patch.object(usage.concurrent.futures, "ProcessPoolExecutor", executor):
            self.run_usage()
        self.assertEqual(created, [(2,)])
        self.assertEqual(self.summary()["periods"], serial)

    def test_если_пул_не_поднялся_файлы_читаются_в_этом_процессе(self):
        self.history()
        with mock.patch.object(usage, "POOL_MIN_BYTES", 0), \
                mock.patch.object(usage.concurrent.futures.ProcessPoolExecutor, "submit", side_effect=OSError("нет процессов")):
            self.run_usage()
        self.assertEqual((self.output("claude"), self.output("codex")), (71, 21))


class PriceFile(UsageCase):
    def prices(self, **settings):
        mcpbar.write_json(self.state("prices.json"), settings)

    def test_своя_цена_переоценивает_всю_историю(self):
        self.put("claude/projects/app/s1.jsonl", claude_line("m1", 5, NOW - HOUR, model="example-model"), age=HOUR)
        self.run_usage()
        original = self.period(7)["buckets"]
        self.assertEqual((original[0]["costUsd"], original[0]["costSource"], original[0]["unpricedRecords"]),
                         (0, "unpriced", 1))
        for given, produced, expected in ((2, 8, 0.00006), (4, 16, 0.00012)):
            self.prices(usagePriceOverrides={"example-model": {"inputCostPerMillionTokens": given,
                                                               "outputCostPerMillionTokens": produced}})
            self.run_usage()
            (bucket,) = self.period(7)["buckets"]
            self.assertAlmostEqual(bucket["costUsd"], expected, places=12)
            self.assertEqual((bucket["costSource"], bucket["unpricedRecords"], bucket["totals"]),
                             ("modelPriced", 0, original[0]["totals"]))
        os.remove(self.state("prices.json"))
        self.run_usage()
        self.assertEqual(self.period(7)["buckets"], original)

    def test_map_to_и_негодные_записи_файла(self):
        self.put("claude/projects/app/s1.jsonl", claude_line("m1", 5, NOW - HOUR, model="example-preview")
                 + claude_line("m2", 7, NOW - HOUR), age=HOUR)
        self.prices(usageModelAliases={"example-preview": "claude-fable-5", "loop": "loop", "bad": 5},
                    usagePriceOverrides={"claude-fable-5": {"inputCostPerMillionTokens": -1,
                                                            "outputCostPerMillionTokens": 8}})
        self.run_usage()
        (bucket,) = self.period(7)["buckets"]
        self.assertEqual((bucket["model"], bucket["records"], bucket["totals"]["outputTokens"]), ("claude-fable-5", 2, 12))
        self.assertAlmostEqual(bucket["costUsd"], 20 * 1e-5 + 12 * 5e-5, places=12)

    def test_файл_не_той_формы_значит_без_своих_цен(self):
        self.put("claude/projects/app/s1.jsonl", claude_line("m1", 5, NOW - HOUR), age=HOUR)
        for content in ("[1, 2]", "{не json", '{"usagePriceOverrides": [], "usageModelAliases": "x"}'):
            with open(self.state("prices.json"), "w") as handle:
                handle.write(content)
            self.run_usage()
            self.assertAlmostEqual(self.period(7)["buckets"][0]["costUsd"], 0.00035, places=12)


class FakeLiteLLM:
    """Местный сервер вместо GitHub: отдаёт заданные ответы и запоминает запросы."""

    def __init__(self, case):
        self.routes, self.requests = {}, []
        fake = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                fake.requests.append((self.path, self.headers.get("accept")))
                code, body = fake.routes.get(self.path, (404, b"{}"))
                self.send_response(code)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        case.addCleanup(self.server.server_close)
        case.addCleanup(self.server.shutdown)
        self.base = "http://127.0.0.1:%d" % self.server.server_address[1]

    def serve(self, path, document, code=200):
        self.routes[path] = (code, document if isinstance(document, bytes) else json.dumps(document).encode())


class RatesFetch(UsageCase):
    def setUp(self):
        super().setUp()
        os.remove(self.state("model-rates.json"))
        self.net = FakeLiteLLM(self)
        self.net.serve("/raw", RATES)
        for name, path in (("LITELLM_RATES_URL", "/raw"), ("LITELLM_RATES_API_URL", "/api")):
            patch = mock.patch.object(usage, name, self.net.base + path)
            patch.start()
            self.addCleanup(patch.stop)

    def rates(self, force=False):
        rates = usage.Rates()
        rates.ensure(force)
        return rates

    def close_primary(self):
        patch = mock.patch.object(usage, "LITELLM_RATES_URL", "http://127.0.0.1:9/raw")
        patch.start()
        self.addCleanup(patch.stop)

    def test_первая_загрузка_сохраняет_документ_целиком(self):
        rates = self.rates()
        self.assertEqual(self.net.requests, [("/raw", "application/json")])
        self.assertEqual(rates.describe(), {"status": "fresh", "source": "litellm", "fetchedAt": NOW // 1000,
                                            "knownModels": 2})
        with open(self.state("model-rates.json")) as handle:
            self.assertEqual(json.load(handle), {"fetchedAtMs": NOW, "document": RATES})
        self.assertEqual(stat.S_IMODE(os.stat(self.state("model-rates.json")).st_mode), 0o600)

    def test_раз_в_сутки_а_по_кнопке_не_чаще_раза_в_минуту(self):
        self.rates()
        for step, force, requests in ((30 * 1000, True, 1), (61 * 1000, False, 1), (61 * 1000, True, 2),
                                      (61 * 1000 + DAY - 1, False, 2), (61 * 1000 + DAY, False, 3)):
            self.now = NOW + step
            rates = self.rates(force)
            self.assertEqual(len(self.net.requests), requests, step)
        self.assertEqual(rates.describe()["status"], "fresh")
        self.assertEqual(self.rates().describe(), {"status": "cached", "source": "litellm",
                                                   "fetchedAt": (NOW + 61 * 1000 + DAY) // 1000, "knownModels": 2})

    def test_запасной_адрес_при_любом_провале_основного(self):
        self.net.serve("/api", RATES)
        cases = {"http": lambda: self.net.serve("/raw", RATES, 500),
                 "invalidJson": lambda: self.net.serve("/raw", "{не json".encode()),
                 "empty": lambda: self.net.serve("/raw", {"model": {"mode": "chat"}}),
                 "network": self.close_primary}
        for name, arrange in cases.items():
            arrange()
            del self.net.requests[:]
            os.path.exists(self.state("model-rates.json")) and os.remove(self.state("model-rates.json"))
            rates = self.rates()
            self.assertEqual(self.net.requests[-1], ("/api", "application/vnd.github.raw+json"), name)
            self.assertEqual((rates.status, len(rates.table)), ("fresh", 2), name)

    def test_без_сети_и_без_кэша_всё_без_цены(self):
        self.net.routes.clear()
        self.put("claude/projects/app/s1.jsonl", claude_line("m1", 5, NOW - HOUR), age=HOUR)
        self.run_usage()
        self.assertEqual(self.summary()["pricing"], {"status": "unavailable", "source": "litellm", "fetchedAt": None,
                                                     "knownModels": 0})
        (bucket,) = self.period(7)["buckets"]
        self.assertEqual((bucket["costUsd"], bucket["costSource"], bucket["unpricedTokens"]), (0, "unpriced", 15))
        self.assertFalse(os.path.exists(self.state("model-rates.json")))

    def test_после_провала_минуту_не_пробуем_а_старая_таблица_служит(self):
        self.rates()
        self.net.routes.clear()
        self.now = NOW + DAY
        self.assertEqual(self.rates().describe(), {"status": "cached", "source": "litellm", "fetchedAt": NOW // 1000,
                                                   "knownModels": 2})
        self.assertEqual(len(self.net.requests), 3)
        self.now += 59 * 1000
        self.rates(True)
        self.assertEqual(len(self.net.requests), 3)
        self.now += 2 * 1000
        self.net.serve("/raw", RATES)
        self.assertEqual(self.rates().describe()["status"], "fresh")
        self.assertEqual(len(self.net.requests), 4)

    def test_незнакомая_модель_перечитывает_таблицу_раньше_срока_но_один_раз(self):
        self.put("claude/projects/app/s1.jsonl", claude_line("m1", 5, NOW - HOUR, model="claude-new-9")
                 + claude_line("m2", 5, NOW - HOUR, model="<synthetic-like>/opus"), age=HOUR)
        self.run_usage()
        self.assertEqual(len(self.net.requests), 1)  # таблице меньше минуты: вторая загрузка не нужна
        self.now = NOW + 2 * HOUR
        self.run_usage()
        self.assertEqual(len(self.net.requests), 1)  # модель уже сверена со свежей таблицей
        os.remove(self.state("rates-state.json"))
        self.net.serve("/raw", dict(RATES, **{"claude-new-9": RATES["claude-fable-5"]}))
        self.run_usage()
        self.assertEqual(len(self.net.requests), 2)
        self.assertEqual(self.summary()["pricing"]["status"], "fresh")
        priced = {b["model"]: b["costSource"] for b in self.period(7)["buckets"]}
        self.assertEqual(priced, {"claude-new-9": "modelPriced", "<synthetic-like>/opus": "unpriced"})

    def test_неудачная_сверка_незнакомой_модели_повторяется(self):
        self.put("claude/projects/app/s1.jsonl", claude_line("m1", 5, NOW - HOUR, model="claude-new-9"), age=HOUR)
        self.seed_rates(RATES, NOW - 2 * HOUR)
        self.net.routes.clear()
        self.run_usage()
        self.assertEqual(len(self.net.requests), 2)
        self.now = NOW + 61 * 1000
        self.run_usage()
        self.assertEqual(len(self.net.requests), 4)

    def test_своя_цена_снимает_модель_с_ранней_сверки(self):
        self.put("claude/projects/app/s1.jsonl", claude_line("m1", 5, NOW - HOUR, model="glm-5.3"), age=HOUR)
        self.seed_rates(RATES, NOW - 2 * HOUR)
        mcpbar.write_json(self.state("prices.json"), {"usagePriceOverrides": {
            "glm-5.3": {"inputCostPerMillionTokens": 2, "outputCostPerMillionTokens": 8}}})
        self.run_usage()
        self.assertEqual(self.net.requests, [])

    def test_map_to_на_известную_модель_снимает_её_с_ранней_сверки(self):
        self.put("claude/projects/app/s1.jsonl", claude_line("m1", 5, NOW - HOUR, model="example-preview"), age=HOUR)
        self.seed_rates(RATES, NOW - 2 * HOUR)
        mcpbar.write_json(self.state("prices.json"), {"usageModelAliases": {"example-preview": "claude-fable-5"}})
        self.run_usage()
        self.assertEqual(self.net.requests, [])

    def trickle(self, pause):
        """Сервер, отдающий таблицу по кусочку с паузами: каждое чтение укладывается в таймаут сокета."""
        body = json.dumps(RATES).encode()

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                try:
                    for start in range(0, len(body), 8):
                        self.wfile.write(body[start:start + 8])
                        self.wfile.flush()
                        time.sleep(pause)
                except OSError:
                    pass

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return "http://127.0.0.1:%d/raw" % server.server_address[1]

    def test_таблица_пришедшая_по_кусочку_собирается_целиком(self):
        document, table = usage._fetch_rates(self.trickle(0), "application/json")
        self.assertEqual((document, len(table)), (RATES, 2))

    def test_сервер_цедящий_по_байту_не_держит_просмотр(self):
        # Таймаут сокета отсчитывается на каждое чтение заново: без общего срока такая загрузка
        # шла бы, пока сервер не устанет.
        self.assertEqual(usage.RATES_DEADLINE, 30)
        self.rates()
        slow = self.trickle(0.1)  # таблица целиком шла бы около пяти секунд
        self.now = NOW + DAY
        started = time.monotonic()
        with mock.patch.object(usage, "RATES_DEADLINE", 0.3), mock.patch.object(usage, "LITELLM_RATES_URL", slow), \
                mock.patch.object(usage, "LITELLM_RATES_API_URL", slow):
            rates = self.rates()
        self.assertLess(time.monotonic() - started, 2.5)
        # Просрочка — обычный провал загрузки: служит старая таблица, минуту новых попыток нет.
        self.assertEqual(rates.describe(), {"status": "cached", "source": "litellm", "fetchedAt": NOW // 1000,
                                            "knownModels": 2})
        self.assertEqual(rates.state["lastFailedAtMs"], NOW + DAY)

    def test_кнопка_обновления_разрешает_загрузку_раньше_суток(self):
        self.put("claude/projects/app/s1.jsonl", claude_line("m1", 5, NOW - HOUR), age=HOUR)
        self.run_usage()
        self.assertEqual((len(self.net.requests), self.summary()["pricing"]["status"]), (1, "fresh"))
        self.assertAlmostEqual(self.period(7)["buckets"][0]["costUsd"], 0.00035, places=12)
        self.now = NOW + 30 * 1000
        self.run_usage("--refresh")
        self.assertEqual((len(self.net.requests), self.summary()["pricing"]["status"]), (1, "cached"))
        self.now = NOW + 61 * 1000
        self.run_usage()
        self.assertEqual(len(self.net.requests), 1)
        self.run_usage("--refresh")
        self.assertEqual((len(self.net.requests), self.summary()["pricing"]["status"]), (2, "fresh"))


class Seam(UsageCase):
    def test_шов_для_swift(self):
        """Файлы, которые написал настоящий писатель, уезжают в build/seam — их читает model-проверка Swift."""
        claude = (
            claude_line("m1", 286, NOW - 2 * HOUR, cache_read_input_tokens=1000, cache_creation_input_tokens=66818,
                        cache_creation={"ephemeral_1h_input_tokens": 60000})
            + claude_line("m2", 99, NOW - 3 * HOUR, speed="fast", cache_read_input_tokens=20)
            + claude_line("m3", 40, NOW - 2 * DAY, session="session-2", cost=0.25)
            + claude_line("m4", 900, NOW - 20 * DAY, model="claude-future-9", session="session-3"))
        self.put("claude/projects/app/s1.jsonl", claude, age=2 * HOUR)
        self.put("codex/sessions/2026/11/19/rollout-a.jsonl",
                 codex_rollout("codex-a", NOW - HOUR, [299, 120], service_tier="priority"), age=HOUR)
        self.put("codex/sessions/2026/11/10/rollout-b.jsonl", codex_rollout("codex-b", NOW - 9 * DAY, [50]), age=9 * DAY)
        self.put("codex/sessions/2026/11/10/rollout-c.jsonl.zst", b"compressed", age=9 * DAY)
        self.no_decompressor()
        with mock.patch.object(usage, "system_time_zone", lambda: "Europe/Berlin"):
            self.run_usage()
        summary = self.summary()
        self.assertEqual(summary["timeZone"], "Europe/Berlin")
        self.assertEqual([len(summary["periods"][key]["buckets"]) for key in ("1", "7", "30", "90")], [3, 3, 5, 5])
        fast = next(b for b in summary["periods"]["1"]["buckets"] if "fastCostUsd" in b and b["provider"] == "claude")
        self.assertEqual((fast["hourStart"], fast["day"]), ("2026-11-19T09:37:00.000Z", "2026-11-19"))
        self.assertEqual(self.source("codex", 30)["message"], "zstd_unavailable")
        self.assertEqual(self.source("codex", 1)["status"], "ok")
        seam = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build", "seam")
        os.makedirs(seam, exist_ok=True)
        shutil.copyfile(self.state("summary.json"), os.path.join(seam, "usage-summary.json"))
        shutil.copyfile(self.state("status.json"), os.path.join(seam, "usage-status.json"))


if __name__ == "__main__":
    unittest.main()
