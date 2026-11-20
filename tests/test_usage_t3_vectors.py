#!/usr/bin/env python3
"""Векторы из собственных тестов T3 Code (коммит 803f21f), которых не было в test_usage.py и
test_usage_command.py, и проверки устойчивости к записям, которые JavaScript читает иначе.

У каждого теста в имени или в первой строке стоит файл и строка T3, откуда взят вектор.

Запуск: /usr/bin/python3 -m unittest discover -s tests -v
"""

import contextlib
import json
import os
import sqlite3
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

import mcpbar  # noqa: E402
import mcpbar_usage as usage  # noqa: E402
import test_usage_command as base  # noqa: E402
from mcpbar_usage import (CACHED, CACHE_WRITE, MODEL, OUTPUT, REASONING, SESSION, SPEED, UNCACHED)  # noqa: E402


def T(text):
    return usage.parse_timestamp_ms(text)


def compact(value):
    """JSON.stringify: без пробелов и без \\u-экранирования — от этого зависят байтовые смещения."""
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def tokens(record):
    return record[UNCACHED] + record[CACHED] + record[CACHE_WRITE] + record[OUTPUT]


# ──────────────────────────────────────────────────────────── codexUsage.test.ts

STAMP = "2026-08-01T05:17:49.919Z"
TURN = {"type": "turn_context", "timestamp": "2026-08-01T05:17:42.694Z",
        "payload": {"type": "turn_context", "model": "gpt-5.6-sol"}}


def counters(given, produced, **extra):
    """codexUsage.test.ts:45-52."""
    return dict({"input_tokens": given, "cached_input_tokens": 0, "cache_write_input_tokens": 0,
                 "output_tokens": produced, "reasoning_output_tokens": 0, "total_tokens": given + produced}, **extra)


def counted(last, total=None, timestamp=STAMP, **extra):
    """codexUsage.test.ts:53-61: без total ключа total_token_usage в строке нет вовсе."""
    info = {"last_token_usage": last}
    if total is not None:
        info["total_token_usage"] = total
    info.update(extra)
    return {"type": "event_msg", "timestamp": timestamp, "payload": {"type": "token_count", "info": info}}


def legacy_count(given, cached, produced, reasoning, timestamp=STAMP):
    """codexUsage.test.ts:28-44."""
    return counted({"input_tokens": given, "cached_input_tokens": cached, "cache_write_input_tokens": 0,
                    "output_tokens": produced, "reasoning_output_tokens": reasoning}, timestamp=timestamp)


def ledger_request(timestamp, usage_block):
    return {"type": "token_usage_record", "timestamp": timestamp, "payload": {"usage": usage_block}}


def fork_meta(session, timestamp, forked_from=None, spawn_parent=None):
    """codexUsage.test.ts:857-880."""
    payload = {"type": "session_meta", "id": session}
    if forked_from is not None:
        payload["forked_from_id"] = forked_from
    if spawn_parent is not None:
        payload["source"] = {"subagent": {"thread_spawn": {"parent_thread_id": spawn_parent}}}
    return {"type": "session_meta", "timestamp": timestamp, "payload": payload}


def stamped(timestamp, line):
    return dict(line, timestamp=timestamp)


class Codex(unittest.TestCase):
    def setUp(self):
        self.state = usage.initial_codex_state()

    def feed(self, line):
        return usage.parse_codex_record(line, self.state)

    def one(self, line):
        """Как помощник тестов T3: одна запись или None."""
        records = self.feed(line)
        self.assertLessEqual(len(records), 1)
        return records[0] if records else None

    def billed(self, line):
        return sum(tokens(record) for record in self.feed(line))

    def malformed(self):
        return self.state["malformedRecords"]

    def test_повтор_token_count_не_считается_дважды(self):
        # codexUsage.test.ts:77-85
        self.feed(TURN)
        self.assertIsNotNone(self.one(legacy_count(100, 0, 10, 0)))
        self.assertIsNone(self.one(legacy_count(100, 0, 10, 0)))

    def test_счётчики_не_тратятся_пока_нет_модели_и_времени(self):
        # codexUsage.test.ts:87-102
        line = counted(counters(100, 20), counters(100, 20))
        self.assertIsNone(self.one(line))
        self.feed(TURN)
        self.assertIsNone(self.one(stamped("invalid", line)))
        self.assertEqual(self.one(line)[OUTPUT], 20)
        self.assertEqual(self.malformed(), 0)

    def test_старые_запросы_не_оплачиваются_заново_а_следующая_разница_не_теряется(self):
        # codexUsage.test.ts:147-165, оба варианта первого снимка
        for initial_cumulative in (False, True):
            with self.subTest(initial_cumulative=initial_cumulative):
                self.state = usage.initial_codex_state()
                self.feed(TURN)
                first = counters(100, 20)
                self.assertEqual(self.one(counted(first, first if initial_cumulative else None))[OUTPUT], 20)
                self.assertIsNone(self.one(counted(first)))
                self.assertEqual(self.one(counted(counters(20, 5)))[OUTPUT], 5)
                self.assertIsNone(self.one(counted(counters(20, 5), counters(120, 25))))
                self.assertEqual(self.one(counted(counters(10, 2), counters(130, 27)))[OUTPUT], 2)
                self.assertEqual(self.malformed(), 0)

    def test_сверяется_каждый_счётчик_итога_а_несогласованная_пара_даёт_новую_базу(self):
        # codexUsage.test.ts:167-195
        request = counters(100, 20, cached_input_tokens=30, cache_write_input_tokens=10, reasoning_output_tokens=5)
        for field in request:
            with self.subTest(field=field):
                self.state = usage.initial_codex_state()
                self.feed(TURN)
                first = self.one(counted(request, request))
                self.assertEqual([first[i] for i in (UNCACHED, CACHED, CACHE_WRITE, OUTPUT, REASONING)],
                                 [60, 30, 10, 20, 5])
                total = {key: value * 2 for key, value in request.items()}
                total[field] += 1
                if field in ("input_tokens", "output_tokens"):
                    total["total_tokens"] += 1
                self.assertIsNone(self.one(counted(request, dict(total))))
                self.assertEqual(self.malformed(), 1)
                for key in request:
                    total[key] += request[key]
                self.assertEqual(self.one(counted(request, dict(total)))[OUTPUT], 20)
                self.assertEqual(self.malformed(), 1)

    def test_без_начальной_базы_оплачивается_только_последний_запрос(self):
        # codexUsage.test.ts:197-255: продолжение, форк и субагент
        request = counters(100, 20, cached_input_tokens=30, cache_write_input_tokens=10, reasoning_output_tokens=5)
        cumulative = counters(500, 60, cached_input_tokens=200, cache_write_input_tokens=20, reasoning_output_tokens=15)
        for source in ("continuation", "fork", "subagent"):
            with self.subTest(source=source):
                self.state = usage.initial_codex_state()
                payload = {"id": "child", "model_provider": "openai", "source": "vscode"}
                if source == "fork":
                    payload["forked_from_id"] = "parent"
                if source == "subagent":
                    payload["source"] = {"subagent": {"thread_spawn": {"parent_thread_id": "parent"}}}
                self.feed({"type": "session_meta", "timestamp": "2026-08-01T05:17:41.000Z", "payload": payload})
                self.feed(TURN)
                first = counted(request, cumulative)
                record = self.one(first)
                self.assertEqual((record[SESSION], [record[i] for i in (UNCACHED, CACHED, CACHE_WRITE, OUTPUT, REASONING)]),
                                 ("child", [60, 30, 10, 20, 5]))
                self.assertIsNone(self.one(first))
                self.assertIsNone(self.one(counted(counters(10, 2), cumulative)))
                grown = dict(cumulative, input_tokens=510, output_tokens=62, total_tokens=572)
                self.assertEqual(self.one(counted(counters(10, 2), grown))[OUTPUT], 2)
                self.assertEqual(self.malformed(), 0)

    def test_первый_снимок_с_невозможной_унаследованной_базой_отвергается(self):
        # codexUsage.test.ts:257-312
        request = counters(100, 20, cached_input_tokens=30, cache_write_input_tokens=10, reasoning_output_tokens=5)
        impossible = [
            counters(90, 40, cached_input_tokens=60, cache_write_input_tokens=20, reasoning_output_tokens=10),
            counters(200, 10, cached_input_tokens=60, cache_write_input_tokens=20, reasoning_output_tokens=5),
            counters(200, 40, cached_input_tokens=20, cache_write_input_tokens=20, reasoning_output_tokens=10),
            counters(200, 40, cached_input_tokens=60, cache_write_input_tokens=5, reasoning_output_tokens=10),
            counters(200, 40, cached_input_tokens=60, cache_write_input_tokens=20, reasoning_output_tokens=3),
            counters(110, 40, cached_input_tokens=60, cache_write_input_tokens=20, reasoning_output_tokens=10),
            counters(200, 30, cached_input_tokens=60, cache_write_input_tokens=20, reasoning_output_tokens=20),
        ]
        for cumulative in impossible:
            with self.subTest(cumulative=cumulative):
                self.state = usage.initial_codex_state()
                self.feed(TURN)
                self.assertIsNone(self.one(counted(request, cumulative)))
                self.assertEqual(self.malformed(), 1)
                self.assertEqual(self.state["lastCumulativeUsage"], tuple(cumulative.values()))

    def test_испорченные_счётчики_пропускаются_и_счёт_восстанавливается(self):
        # codexUsage.test.ts:314-338
        request = counters(100, 20)
        for malformed in ("request", "cumulative"):
            with self.subTest(malformed=malformed):
                self.state = usage.initial_codex_state()
                self.feed(TURN)
                self.feed(counted(request, request))
                broken = counted(dict(request, cached_input_tokens=-1) if malformed == "request" else request,
                                 dict(counters(200, 40), output_tokens="40") if malformed == "cumulative"
                                 else counters(200, 40))
                self.assertIsNone(self.one(broken))
                self.assertEqual(self.malformed(), 1)
                following = counted(request, counters(300, 60) if malformed == "request" else counters(200, 40))
                self.assertEqual(self.one(following)[OUTPUT], 20)
                self.assertEqual(self.malformed(), 1)

    def test_запросы_между_сходящимися_снимками_не_оплачиваются_отдельно(self):
        # codexUsage.test.ts:340-360
        self.feed(TURN)
        self.feed(counted(counters(100, 20), counters(100, 20)))
        for block in (counters(40, 5), counters(60, 15), counters(30, 3)):
            self.assertEqual(self.feed(ledger_request("2026-08-01T05:17:45.000Z", block)), [])
        self.assertEqual(self.one(counted(counters(100, 20), counters(200, 40)))[OUTPUT], 20)
        # Запросы, уже объяснённые прошлым снимком, не закрывают следующий разрыв.
        self.feed(ledger_request("2026-08-01T05:17:45.000Z", counters(10, 2)))
        self.assertIsNone(self.one(counted(counters(10, 2), counters(340, 65))))
        self.assertEqual(self.malformed(), 1)

    def test_оценка_размера_контекста_не_оплачивается_и_не_теряет_следующий_запрос(self):
        # codexUsage.test.ts:508-524
        self.feed(TURN)
        self.feed(counted(counters(100, 20), counters(100, 20)))
        estimate = counters(0, 0, total_tokens=1000)
        self.assertIsNone(self.one(counted(dict(estimate, total_tokens=880), estimate, model_context_window=1000)))
        self.assertEqual(self.one(counted(counters(10, 2), counters(10, 2, total_tokens=1012)))[OUTPUT], 2)
        self.assertEqual(self.malformed(), 0)

    def test_повтор_первого_запроса_последовательности_не_откатывает_базу(self):
        # codexUsage.test.ts:684-702
        self.feed(TURN)
        request = counters(100, 20)
        processed = [self.billed(line) for line in (
            counted(request, request), counted(request, counters(200, 40)),
            counted(request, request), counted(request, counters(300, 60)))]
        self.assertEqual((processed, self.malformed()), ([120, 120, 0, 120], 0))

    def test_настоящий_перезапуск_с_теми_же_счётчиками_в_новое_время_оплачивается(self):
        # codexUsage.test.ts:704-722
        self.feed(TURN)
        request = counters(100, 20)
        processed = [self.billed(line) for line in (
            counted(request, request), counted(request, counters(200, 40)),
            counted(request, request, timestamp="2026-08-01T05:18:49.919Z"),
            counted(counters(30, 5), counters(130, 25)))]
        self.assertEqual((processed, self.malformed()), ([120, 120, 120, 35], 0))

    def test_запрос_равный_старому_началу_оплачивается_только_после_сброса_счётчиков(self):
        # codexUsage.test.ts:724-762
        request = counters(100, 20)
        for marker_total, next_total, expected in (
                (counters(0, 0), counters(130, 25), [120, 120, 0, 120, 35]),
                (counters(200, 40), counters(230, 45), [120, 120, 0, 0, 35])):
            with self.subTest(marker_total=marker_total):
                self.state = usage.initial_codex_state()
                self.feed(TURN)
                marker = counted(counters(0, 0, total_tokens=26387), marker_total, model_context_window=475000)
                processed = [self.billed(line) for line in (
                    counted(request, request), counted(request, counters(200, 40)), marker,
                    counted(request, request), counted(counters(30, 5), next_total))]
                self.assertEqual((processed, self.malformed()), (expected, 0))

    def test_несогласованная_пара_обнулившая_базу_забывает_старое_начало(self):
        # codexUsage.test.ts:764-782
        self.feed(TURN)
        request = counters(100, 20)
        processed = [self.billed(line) for line in (
            counted(request, request), counted(counters(30, 5), counters(0, 0)),
            counted(request, request), counted(counters(30, 5), counters(130, 25)))]
        self.assertEqual((processed, self.malformed()), ([120, 0, 120, 35], 1))

    def test_субагент_без_forked_from_id_тоже_форк(self):
        # codexUsage.test.ts:923-934
        spawn = "2026-08-01T05:00:00.000Z"
        self.feed(fork_meta("child", spawn, spawn_parent="parent"))
        self.feed(stamped(spawn, TURN))
        self.assertIsNone(self.one(legacy_count(100, 0, 10, 0, timestamp="2026-08-01T05:00:00.001Z")))

    def test_в_обычном_rollout_ничего_не_подавляется(self):
        # codexUsage.test.ts:936-945
        self.feed(fork_meta("root", "2026-08-01T05:00:00.000Z"))
        self.feed(stamped("2026-08-01T05:00:00.100Z", TURN))
        self.assertIsNotNone(self.one(legacy_count(100, 0, 10, 0, timestamp="2026-08-01T05:00:00.200Z")))

    def test_скопированная_нулевая_база_форка_забывает_старое_начало(self):
        # codexUsage.test.ts:947-973
        request = counters(100, 20)
        self.feed(stamped("2026-08-01T04:59:00.000Z", TURN))
        first = self.billed(counted(request, request, timestamp="2026-08-01T04:59:01.000Z"))
        self.feed(fork_meta("child", "2026-08-01T05:00:00.000Z", forked_from="parent"))
        copied = self.billed(counted(counters(0, 0, total_tokens=26387), counters(0, 0),
                                     timestamp="2026-08-01T05:00:00.001Z"))
        after_burst = self.billed(counted(request, request, timestamp="2026-08-01T05:00:06.000Z"))
        following = self.billed(counted(counters(30, 5), counters(130, 25), timestamp="2026-08-01T05:00:06.100Z"))
        self.assertEqual(([first, copied, after_burst, following], self.malformed()), ([120, 0, 120, 35], 0))

    def test_первый_запрос_ребёнка_оплачивается_когда_ход_прерван_до_снимка(self):
        # codexUsage.test.ts:975-1000
        fork = "2026-08-01T05:00:00.000Z"
        lines = [fork_meta("child", fork, forked_from="parent"), stamped(fork, TURN),
                 ledger_request("2026-08-01T05:00:00.001Z", counters(100, 20)),
                 counted(counters(100, 20), counters(100, 20), timestamp="2026-08-01T05:00:00.001Z"),
                 ledger_request("2026-08-01T05:00:06.000Z", counters(150, 10)),
                 ledger_request("2026-08-01T05:00:10.000Z", counters(200, 30)),
                 counted(counters(200, 30), counters(450, 60), timestamp="2026-08-01T05:00:10.000Z")]
        processed = [tokens(record) for line in lines for record in self.feed(line)]
        self.assertEqual((processed, self.malformed()), ([160, 230], 0))


# ──────────────────────────────────────────────────────────── usageTranscriptReader.test.ts

def claude_line(number, output):
    """usageTranscriptReader.test.ts:32-45."""
    return compact({"type": "assistant", "timestamp": "2026-08-01T10:00:00Z", "requestId": "req_%d" % number,
                    "sessionId": "session-1",
                    "message": {"id": "msg_%d" % number, "model": "claude-fable-5",
                                "usage": {"input_tokens": 10, "output_tokens": output}}}) + "\n"


def codex_meta_line():
    return compact({"type": "session_meta", "timestamp": "2026-08-01T10:00:00Z",
                    "payload": {"type": "session_meta", "id": "codex-session-1"}}) + "\n"


def codex_model_line(model):
    return compact({"type": "turn_context", "timestamp": "2026-08-01T10:00:01Z",
                    "payload": {"type": "turn_context", "model": model}}) + "\n"


def codex_tier_line(service_tier):
    return compact({"type": "event_msg", "timestamp": "2026-08-01T10:00:01Z",
                    "payload": {"type": "thread_settings_applied",
                                "thread_settings": {"service_tier": service_tier}}}) + "\n"


def codex_usage_event(output, seconds):
    return {"type": "event_msg", "timestamp": "2026-08-01T10:00:%02dZ" % seconds,
            "payload": {"type": "token_count",
                        "info": {"last_token_usage": {"input_tokens": 100, "output_tokens": output}}}}


def codex_usage_line(output, seconds):
    """usageTranscriptReader.test.ts:70-79."""
    return compact(codex_usage_event(output, seconds)) + "\n"


def through_json(position):
    """Точка возобновления переживает запись в кэш: кортежи возвращаются списками."""
    return json.loads(json.dumps(position))


class Reader(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.dir = self._dir.name
        # Кусок чтения T3 — 256 КиБ; с ним длинные строки теста действительно пересекают границы.
        patch = mock.patch.object(usage, "READ_CHUNK", 256 * 1024)
        patch.start()
        self.addCleanup(patch.stop)

    def write(self, name, text, mode="w"):
        path = os.path.join(self.dir, name)
        with open(path, mode + "b") as handle:
            handle.write(text.encode("utf-8") if isinstance(text, str) else text)
        return path

    def test_сжатый_файл_читается_как_обычный_через_длинные_строки_и_хвост(self):
        # usageTranscriptReader.test.ts:128-171
        large = compact(dict({"padding": "日本語 é" * (128 * 1024)}, **codex_usage_event(9, 5))) + "\n"
        broken = compact(codex_usage_event("invalid", 6)) + "\n"
        content = (codex_meta_line() + codex_model_line("gpt-6-astra") + codex_tier_line("ultrafast") + large
                   + broken + codex_usage_line(21, 8).rstrip())
        plain = self.write("rollout.jsonl", content)
        compressed = self.write("rollout.jsonl.zst", content)  # «распаковщик» теста — cat
        expected = usage.read_transcript(plain, "codex")
        actual = usage.read_transcript(compressed, "codex", None, ["/bin/cat"])
        self.assertEqual((len(expected["records"]), len(expected["tailRecords"])), (1, 1))
        self.assertEqual((actual["records"], actual["tailRecords"]), (expected["records"], expected["tailRecords"]))
        self.assertEqual((expected["malformedRecords"], actual["malformedRecords"]), (1, 1))
        self.assertEqual(actual["records"][0][SPEED], "ultrafast")
        self.assertFalse(actual["resumed"])
        self.assertEqual(actual["position"]["resumeOffset"], 0)

    def test_сжатый_rollout_игнорирует_точку_возобновления_и_читается_с_начала(self):
        # usageTranscriptReader.test.ts:173-193
        content = codex_meta_line() + codex_model_line("gpt-6-astra") + codex_usage_line(9, 5)
        first = usage.read_transcript(self.write("rollout.jsonl", content), "codex")
        compressed = self.write("rollout.jsonl.zst", content + codex_usage_line(21, 8))
        actual = usage.read_transcript(compressed, "codex", through_json(first["position"]), ["/bin/cat"])
        self.assertFalse(actual["resumed"])
        self.assertEqual([record[OUTPUT] for record in actual["records"]], [9, 21])
        repeated = usage.read_transcript(compressed, "codex", through_json(actual["position"]), ["/bin/cat"])
        self.assertFalse(repeated["resumed"])
        self.assertEqual(repeated["records"], actual["records"])

    def test_ошибка_распаковщика_это_none_а_не_пустой_разбор(self):
        # usageTranscriptReader.test.ts:195-199
        path = self.write("corrupt.jsonl.zst", "not a zstd frame")
        self.assertIsNone(usage.read_transcript(path, "claude", None, ["/usr/bin/false"]))
        real = usage.find_decompressor()
        if real is None:
            self.skipTest("на машине нет ни zstd, ни node с zstd")
        self.assertIsNone(usage.read_transcript(path, "claude", None, real))

    def test_состояние_codex_переходит_через_точку_возобновления(self):
        # usageTranscriptReader.test.ts:289-307
        path = self.write("rollout.jsonl", codex_meta_line() + codex_model_line("gpt-5.2-codex")
                          + codex_tier_line("ultrafast"))
        first = usage.read_transcript(path, "codex")
        self.assertEqual(first["records"], [])
        self.write("rollout.jsonl", codex_usage_line(9, 5), mode="a")
        second = usage.read_transcript(path, "codex", through_json(first["position"]))
        self.assertTrue(second["resumed"])
        (record,) = second["records"]
        self.assertEqual((record[MODEL], record[SPEED], record[SESSION]),
                         ("gpt-5.2-codex", "ultrafast", "codex-session-1"))

    def test_повтор_события_codex_по_обе_стороны_точки_возобновления_не_считается(self):
        # usageTranscriptReader.test.ts:309-328
        path = self.write("rollout.jsonl", codex_meta_line() + codex_model_line("gpt-5.2-codex")
                          + codex_usage_line(9, 5))
        first = usage.read_transcript(path, "codex")
        self.assertEqual(len(first["records"]), 1)
        self.write("rollout.jsonl", codex_usage_line(9, 5) + codex_usage_line(21, 8), mode="a")
        second = usage.read_transcript(path, "codex", through_json(first["position"]))
        self.assertTrue(second["resumed"])
        self.assertEqual([record[OUTPUT] for record in second["records"]], [21])

    def test_хвост_с_унаследованным_итогом_после_возобновления_не_оплачивается_дважды(self):
        # usageTranscriptReader.test.ts:351-408
        def event(last, cumulative):
            return compact({"type": "event_msg", "timestamp": "2026-08-01T10:00:05Z",
                            "payload": {"type": "token_count",
                                        "info": {"last_token_usage": last, "total_token_usage": cumulative}}})

        def block(given, produced):
            return {"input_tokens": given, "output_tokens": produced}

        first_line = event(block(100, 20), block(500, 60))
        path = self.write("continuation.jsonl", codex_meta_line() + codex_model_line("gpt-6-astra")
                          + codex_tier_line("ultrafast") + first_line)
        first = usage.read_transcript(path, "codex")
        self.assertEqual(first["records"], [])
        self.assertEqual([(r[OUTPUT], r[SPEED]) for r in first["tailRecords"]], [(20, "ultrafast")])
        self.assertEqual(first["malformedRecords"], 0)
        self.write("continuation.jsonl", "\n%s\n%s\n" % (first_line, event(block(10, 2), block(510, 62))), mode="a")
        resumed = usage.read_transcript(path, "codex", through_json(first["position"]))
        full = usage.read_transcript(path, "codex")
        self.assertTrue(resumed["resumed"])
        self.assertEqual(resumed["records"], full["records"])
        self.assertEqual([(r[OUTPUT], r[SPEED]) for r in resumed["records"]], [(20, "ultrafast"), (2, "ultrafast")])
        self.assertEqual((resumed["tailRecords"], resumed["malformedRecords"]), ([], 0))
        self.assertEqual(resumed["position"], full["position"])

    def test_запрос_прерванного_хода_оплачивается_без_своего_token_count(self):
        # usageTranscriptReader.test.ts:410-484: строки длиннее куска чтения
        def block(given, produced):
            return counters(given, produced)

        def context(number):
            return {"type": "turn_context", "timestamp": "2026-11-02T10:00:0%d.000Z" % (number * 4 - 4),
                    "payload": {"turn_id": "turn-%d" % number, "model": "gpt-6-sol"}}

        def named(number, response, timestamp, last):
            return {"type": "token_usage_record", "timestamp": timestamp,
                    "payload": {"turn_id": "turn-%d" % number, "response_id": "resp_%d" % response, "usage": last}}

        lines = [
            {"type": "session_meta", "timestamp": "2026-11-02T10:00:00.000Z",
             "payload": {"id": "aborted-turn-repro", "model_provider": "openai"}},
            context(1),
            named(1, 1, "2026-11-02T10:00:01.000Z", block(100, 20)),
            counted(block(100, 20), block(100, 20), timestamp="2026-11-02T10:00:01.001Z"),
            # Ход прерван сразу после этого запроса: token_count о нём нет.
            named(1, 2, "2026-11-02T10:00:02.000Z", block(150, 10)),
            {"type": "event_msg", "timestamp": "2026-11-02T10:00:03.000Z",
             "payload": {"type": "turn_aborted", "turn_id": "turn-1", "reason": "interrupted"}},
            context(2),
            named(2, 3, "2026-11-02T10:00:05.000Z", block(200, 30)),
            counted(block(200, 30), block(450, 60), timestamp="2026-11-02T10:00:05.001Z"),
        ]
        padding = "x" * (256 * 1024)
        path = self.write("rollout.jsonl", "".join(compact(dict({"padding": padding}, **line)) + "\n" for line in lines))
        result = usage.read_transcript(path, "codex")
        requests = sorted(tokens(record) for record in result["records"] + result["tailRecords"])
        self.assertEqual((sum(requests), requests, result["malformedRecords"]), (510, [120, 160, 230], 0))

    def test_файл_короче_точки_возобновления_читается_с_начала(self):
        # usageTranscriptReader.test.ts:502-516
        path = self.write("claude.jsonl", claude_line(1, 5) + claude_line(2, 7))
        first = usage.read_transcript(path, "claude")
        self.write("claude.jsonl", claude_line(3, 11))
        second = usage.read_transcript(path, "claude", first["position"])
        self.assertFalse(second["resumed"])
        self.assertEqual([record[OUTPUT] for record in second["records"]], [11])

    def test_строка_длиннее_куска_чтения(self):
        # usageTranscriptReader.test.ts:518-540
        big = compact({"type": "assistant", "timestamp": "2026-08-01T10:00:00Z", "requestId": "req_big",
                       "sessionId": "session-1", "padding": "x" * (512 * 1024),
                       "message": {"id": "msg_big", "model": "claude-fable-5",
                                   "usage": {"input_tokens": 10, "output_tokens": 42}}}) + "\n"
        parsed = usage.read_transcript(self.write("claude.jsonl", big + claude_line(2, 7)), "claude")
        self.assertEqual([record[OUTPUT] for record in parsed["records"]], [42, 7])

    def test_crlf_строка_codex_с_маркером_на_границе_куска(self):
        # usageTranscriptReader.test.ts:542-561
        def crlf(line):
            return line.replace("\n", "\r\n")

        model_line = crlf(codex_model_line("gpt-5.2-codex"))
        head = crlf(codex_meta_line())
        filler_bytes = 256 * 1024 - len(head.encode()) - model_line.index("turn_context") - 4
        envelope = crlf(compact({"type": "response_item", "output": ""}) + "\n")
        padding = "é" * ((filler_bytes - len(envelope.encode())) // 2)
        filler = crlf(compact({"type": "response_item", "output": padding}) + "\n")
        content = head + filler + model_line + crlf(codex_usage_line(40, 2))
        # Граница куска обязана резать именно маркер, иначе тест ничего не проверяет.
        boundary = content.encode()[256 * 1024 - 8:256 * 1024 + 8]
        self.assertIn(b"turn", boundary)
        result = usage.read_transcript(self.write("rollout.jsonl", content), "codex")
        (record,) = result["records"]
        self.assertEqual((record[MODEL], record[SESSION]), ("gpt-5.2-codex", "codex-session-1"))
        self.assertEqual(result["position"]["resumeOffset"], len(content.encode()))


# ──────────────────────────────────────────────────────────── usageTranscriptStreaming.test.ts

STREAM_CONTENT = '工具 output \\" usage token_count ' * 40000


def stream_claude(message_id="m1", output=99):
    """usageTranscriptStreaming.test.ts:32-51."""
    return {"type": "assistant", "timestamp": "2026-08-01T10:00:00Z", "sessionId": "s1",
            "requestId": "r-%s" % message_id, "costUSD": 0.25,
            "message": {"content": [{"type": "tool_use", "input": {"text": STREAM_CONTENT}}], "id": message_id,
                        "model": "claude-fable-5",
                        "usage": {"input_tokens": 100, "output_tokens": output, "cache_read_input_tokens": 20,
                                  "cache_creation_input_tokens": 5, "speed": "fast"}}}


class Streaming(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.path = os.path.join(self._dir.name, "history.jsonl")
        patch = mock.patch.object(usage, "READ_CHUNK", 256 * 1024)
        patch.start()
        self.addCleanup(patch.stop)

    def write(self, data, mode="w"):
        with open(self.path, mode + "b") as handle:
            handle.write(data.encode("utf-8") if isinstance(data, str) else data)

    def test_оборванные_utf8_и_json_дочитываются_а_смещения_crlf_точные(self):
        # usageTranscriptStreaming.test.ts:274-297
        first = compact(stream_claude("first", 5)) + "\r\n"
        second = compact(stream_claude("second", 7)).encode()
        split = second.rfind("工具".encode()) + 1  # посреди трёхбайтного символа
        self.write(first.encode() + second[:split])
        partial = usage.read_transcript(self.path, "claude")
        self.assertEqual([record[OUTPUT] for record in partial["records"]], [5])
        self.assertEqual(partial["tailRecords"], [])
        self.assertEqual(partial["position"]["resumeOffset"], len(first.encode()))
        self.write(second[split:], mode="a")
        complete = usage.read_transcript(self.path, "claude", partial["position"])
        self.assertTrue(complete["resumed"])
        self.assertEqual(complete["records"], [])
        self.assertEqual([record[OUTPUT] for record in complete["tailRecords"]], [7])
        self.assertEqual(complete["position"]["resumeOffset"], len(first.encode()))
        self.write("\r\n" + compact(stream_claude("third", 11)) + "\n", mode="a")
        appended = usage.read_transcript(self.path, "claude", complete["position"])
        self.assertEqual([record[OUTPUT] for record in appended["records"]], [7, 11])
        self.assertEqual(appended["tailRecords"], [])
        self.assertEqual(appended["position"]["resumeOffset"], os.path.getsize(self.path))
        full = usage.read_transcript(self.path, "claude")
        self.assertEqual(partial["records"] + appended["records"], full["records"])

    def test_расход_после_глубоко_вложенного_вывода_инструмента(self):
        # usageTranscriptStreaming.test.ts:404-411
        record = compact(stream_claude())
        nested = "[" * 300 + "0" + "]" * 300
        self.write('{"toolOutput":' + nested + "," + record[1:] + "\n")
        self.assertEqual(usage.read_transcript(self.path, "claude")["records"][0][OUTPUT], 99)

    def test_бесконечная_цена_читается_как_отсутствующая(self):
        # usageTranscriptStreaming.test.ts:413-420
        self.write(compact(stream_claude()).replace('"costUSD":0.25', '"costUSD":1e400') + "\n")
        (record,) = usage.read_transcript(self.path, "claude")["records"]
        self.assertIsNone(record[usage.COST])
        self.assertEqual(record[OUTPUT], 99)

    def test_число_длиннее_double_читается_как_в_javascript(self):
        """JSON.parse даёт Infinity для целого длиннее double: tokenCount → 0, costUSD → null
        (provider-core/src/server/usage.ts:47-49, claudeUsage.ts:81), а строгий счётчик Codex
        отвергает расход целиком (codexUsage.ts:17). Python читает такое число точным целым."""
        huge = "1" + "0" * 400
        line = compact(stream_claude()).replace('"input_tokens":100', '"input_tokens":' + huge) \
            .replace('"costUSD":0.25', '"costUSD":' + huge)
        self.write(line + "\n")
        (record,) = usage.read_transcript(self.path, "claude")["records"]
        self.assertEqual((record[UNCACHED], record[usage.COST], record[OUTPUT]), (0, None, 99))
        self.write(codex_meta_line() + codex_model_line("gpt-6-astra")
                   + codex_usage_line(7, 5).replace('"input_tokens":100', '"input_tokens":' + huge)
                   + codex_usage_line(9, 6))
        parsed = usage.read_transcript(self.path, "codex")
        self.assertEqual(([record[OUTPUT] for record in parsed["records"]], parsed["malformedRecords"]), ([9], 1))


# ──────────────────────────────────────────────────────────── usageAggregation.test.ts

def row(timestamp, model="claude-fable-5"):
    """usageAggregation.test.ts:28-46."""
    return [T(timestamp), model, "session-a", 100, 1000, 10, 50, 0, None, None, "standard", 0]


def aggregate(records, time_zone="UTC", hourly=False):
    """usageAggregation.test.ts:48-71: август целиком, а для часов — окно от 04:37."""
    window = {"resolution": "day", "sinceDay": "2026-08-01", "untilDay": "2026-08-31"}
    if hourly:
        window = {"resolution": "hour", "sinceDay": "2026-08-06", "untilDay": "2026-08-07",
                  "sinceMs": T("2026-08-06T04:37:00.000Z"), "untilMs": T("2026-08-07T04:37:00.000Z")}
    ledger = usage.Ledger({}, {}, {})
    ledger.add_file("claude", records)
    return usage.aggregate(ledger.finish(), window, time_zone)[0]


class Aggregation(unittest.TestCase):
    def test_полночь_пояса_с_четвертью_часа_среди_перемешанных_корзин(self):
        # usageAggregation.test.ts:189-205
        buckets = aggregate([row("2026-08-01T18:14:59.999Z"), row("2026-08-01T18:15:00.000Z"),
                             row("2026-08-01T18:15:00.000Z", "claude-opus-5"), row("2026-08-01T18:16:00.000Z")],
                            "Asia/Kathmandu")
        self.assertEqual([(b["day"], b["model"], b["records"]) for b in buckets], [
            ("2026-08-01", "claude-fable-5", 1), ("2026-08-02", "claude-fable-5", 2),
            ("2026-08-02", "claude-opus-5", 1)])

    def test_полночь_фиксированного_смещения_между_четвертями_часа(self):
        # usageAggregation.test.ts:207-220
        buckets = aggregate([row("2026-08-01T23:58:59.999Z"), row("2026-08-01T23:59:00.000Z")], "+00:01")
        self.assertEqual([(b["day"], b["records"]) for b in buckets], [("2026-08-01", 1), ("2026-08-02", 1)])

    def test_часовой_запрос_делится_от_точного_начала_окна(self):
        # usageAggregation.test.ts:222-236
        buckets = aggregate([row("2026-08-07T02:40:13.944Z"), row("2026-08-07T03:40:13.944Z")],
                            "America/Los_Angeles", hourly=True)
        self.assertEqual([(b["day"], b["hourStart"]) for b in buckets], [
            ("2026-08-06", "2026-08-07T02:37:00.000Z"), ("2026-08-06", "2026-08-07T03:37:00.000Z")])

    def test_скользящее_окно_включает_начало_и_исключает_конец(self):
        # usageAggregation.test.ts:238-255
        buckets = aggregate([row("2026-08-06T04:36:59.999Z"), row("2026-08-06T04:37:00.000Z"),
                             row("2026-08-07T04:36:59.999Z"), row("2026-08-07T04:37:00.000Z")], "UTC", hourly=True)
        self.assertEqual([(b["hourStart"], b["records"]) for b in buckets], [
            ("2026-08-06T04:37:00.000Z", 1), ("2026-08-07T03:37:00.000Z", 1)])

    def test_время_вне_календаря_питона_не_роняет_свод(self):
        """Date.parse принимает годы 0001 и 9999 (provider-core/src/server/usage.ts:51-55), а день
        такой записи в поясе со смещением выходит за календарь datetime. В окно она не попадает."""
        for zone in ("Europe/Berlin", "America/Los_Angeles", "+14:00", "-12:00"):
            with self.subTest(zone=zone):
                buckets = aggregate([row("9999-12-31T23:59:59.999Z"), row("0001-01-01T00:00:00Z"),
                                     row("2026-08-07T04:05:13.944Z")], zone)
                self.assertEqual([b["records"] for b in buckets], [1])


# ──────────────────────────────────────────────────────────── usagePricing.test.ts

def rate(given, cache_read=None, **extra):
    """usagePricing.test.ts:13-17."""
    entry = {"input_cost_per_token": given, "output_cost_per_token": given * 5}
    if cache_read is not None:
        entry["cache_read_input_token_cost"] = cache_read
    entry.update(extra)
    return entry


def both_orders(document):
    items = list(document.items())
    return (dict(items), dict(reversed(items)))


class BareNames(unittest.TestCase):
    def test_канонический_тариф_не_смешивается_с_deepinfra_в_любом_порядке(self):
        # usagePricing.test.ts:304-320
        for document in both_orders({"claude-fable-5": rate(1e-5, 1e-6),
                                     "deepinfra/anthropic/claude-fable-5": rate(1e-5)}):
            table = usage.parse_rate_table(document)
            self.assertEqual(usage.lookup_rate(table, "claude-fable-5")[0][usage.R_CACHE_READ], 1e-6)
            self.assertEqual(usage.lookup_rate(table, "deepinfra/anthropic/claude-fable-5")[0][usage.R_CACHE_READ], 1e-5)
            self.assertIsNone(usage.lookup_rate(table, "other/claude-fable-5"))

    def test_вариант_в_скобках_оценивается_как_базовая_модель(self):
        # usagePricing.test.ts:322-329
        table = usage.parse_rate_table({"claude-fable-5-1": rate(1e-5, 2.5e-7)})
        self.assertEqual(usage.lookup_rate(table, "claude-fable-5-1[1m]"), usage.lookup_rate(table, "claude-fable-5-1"))
        self.assertIsNotNone(usage.lookup_rate(table, "claude-fable-5-1[1m]"))
        self.assertIsNone(usage.lookup_rate(table, "anthropic/Claude-Fable-5-1[1m]"))

    def test_голое_имя_остаётся_когда_перепродавец_опускает_быстрый_тариф(self):
        # usagePricing.test.ts:342-359: полная запись, запись без priority и запись без порога
        table = usage.parse_rate_table({
            "provider-a/example-model": rate(1, input_cost_per_token_priority=2, output_cost_per_token_priority=10,
                                             input_cost_per_token_above_272k_tokens=2,
                                             input_cost_per_token_above_272k_tokens_priority=4,
                                             output_cost_per_token_above_272k_tokens_priority=20),
            "provider-b/example-model": rate(1, input_cost_per_token_above_272k_tokens=2),
            "provider-c/example-model": rate(1)})
        full = usage.lookup_rate(table, "provider-a/example-model")
        self.assertIsNotNone(full[1])
        self.assertEqual(full[3][0][0], 272000)
        self.assertEqual(usage.lookup_rate(table, "example-model"), full)

    def test_голое_имя_берёт_цену_создателя_модели_а_не_наценку_перепродавца(self):
        # usagePricing.test.ts:372-388: vertex_ai в список создателей не входит
        reseller = {"kyma/gemini-4-argon": rate(5.4e-6)}
        makers = {"gemini/gemini-4-argon": rate(2e-6, 1e-7), "vertex_ai/gemini-4-argon": rate(2e-6, 1e-7)}
        for document in (dict(reseller, **makers), dict(makers, **reseller)):
            table = usage.parse_rate_table(document)
            self.assertEqual(usage.lookup_rate(table, "gemini-4-argon"), usage.lookup_rate(table, "gemini/gemini-4-argon"))
            self.assertEqual(usage.lookup_rate(table, "gemini-4-argon")[0][usage.R_INPUT], 2e-6)

    def test_имя_только_из_bedrock_получает_базовый_тариф_anthropic(self):
        # usagePricing.test.ts:390-419
        def bedrock(given, produced, cache_read, cache_creation):
            return {"input_cost_per_token": given, "output_cost_per_token": produced,
                    "cache_read_input_token_cost": cache_read, "cache_creation_input_token_cost": cache_creation}

        base_rate = bedrock(8e-6, 4e-5, 2e-7, 1e-5)
        regional = bedrock(8.8e-6, 4.4e-5, 2.2e-7, 1.1e-5)
        gov_cloud = bedrock(9.6e-6, 4.8e-5, 2.4e-7, 1.2e-5)
        rows = {"anthropic.claude-mythos-5-2": base_rate, "global.anthropic.claude-mythos-5-2": base_rate,
                "us.anthropic.claude-mythos-5-2": regional, "eu.anthropic.claude-mythos-5-2": regional,
                "us-gov.anthropic.claude-mythos-5-2": gov_cloud,
                "bedrock/us-gov-east-1/anthropic.claude-mythos-5-2": gov_cloud,
                "bedrock/us-gov-west-1/anthropic.claude-mythos-5-2": gov_cloud}
        for document in both_orders(rows):
            found = usage.lookup_rate(usage.parse_rate_table(document), "claude-mythos-5-2")
            self.assertEqual(found[0][:4], (8e-6, 4e-5, 2e-7, 1e-5))

    def test_голое_имя_без_цены_когда_создатели_расходятся(self):
        # usagePricing.test.ts:421-429
        table = usage.parse_rate_table({"openai/example-model": rate(1), "xai/example-model": rate(3),
                                        "kyma/example-model": rate(1)})
        self.assertIsNone(usage.lookup_rate(table, "example-model"))


# ──────────────────────────────────────────────────────────── UsageService.test.ts

NOW, HOUR, DAY = base.NOW, base.HOUR, base.DAY


def service_rollout(session, output, at):
    """UsageService.test.ts:610-619: session_meta и turn_context без времени."""
    lines = [{"type": "session_meta", "payload": {"id": session}},
             {"type": "turn_context", "payload": {"model": "gpt-6-astra"}}]
    return "".join(compact(line) + "\n" for line in lines) + service_usage(output, at)


def service_usage(output, at):
    return compact({"type": "event_msg", "timestamp": usage.iso_ms(at), "payload": {
        "type": "token_count", "info": {"last_token_usage": {"input_tokens": 10, "output_tokens": output}}}}) + "\n"


class Service(base.UsageCase):
    def test_сжатые_rollout_codex_через_обновления_перезаписи_и_перезапуски(self):
        # UsageService.test.ts:596-707
        patch = mock.patch.object(usage, "ZSTD_PATHS", (self.fake_zstd(),))
        patch.start()
        self.addCleanup(patch.stop)
        at = NOW - 2 * HOUR
        compressed = service_rollout("compressed-session", 23, at)
        self.put("codex/sessions/plain.jsonl", service_rollout("plain-session", 17, at), age=HOUR)
        archive = self.put("codex/sessions/compressed.jsonl.zst", compressed, age=HOUR)
        self.run_usage()
        first = self.period()["buckets"]
        self.assertEqual((self.output("codex"), self.source("codex")["distinctSessions"]), (40, 2))
        self.run_usage()
        self.assertEqual(self.period()["buckets"], first)
        # Тот же rollout ещё лежит обычным файлом, пока сжатие не закончилось.
        self.put("codex/sessions/copy.jsonl", compressed, age=HOUR)
        self.run_usage()
        self.assertEqual(self.output("codex"), 40)
        self.put("codex/sessions/compressed.jsonl.zst", compressed + service_usage(31, at + 5000), age=HOUR // 2)
        self.run_usage()
        rewritten = self.period()["buckets"]
        self.assertEqual(self.output("codex"), 71)
        self.run_usage()
        self.assertEqual(self.period()["buckets"], rewritten)
        # В кэше осталась запись оригинала с пропущенными строками; архив её заменяет,
        # даже когда сам берётся из кэша без чтения.
        original = archive[:-4]
        with contextlib.closing(sqlite3.connect(self.state("scan-cache.sqlite3"))) as db:
            row_ = db.execute("SELECT provider, size, mtime_ns FROM files WHERE path = ?", (archive,)).fetchone()
            db.execute("INSERT INTO files VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                       (original,) + row_ + (1, 0, 0, 0, 0, "[]", "[]"))
            db.execute("INSERT INTO records VALUES (?,?,?,?)", (original, "[]", "[]", None))
            db.commit()
        with mock.patch.object(usage, "read_transcript", wraps=usage.read_transcript) as reads:
            self.run_usage()
        self.assertEqual(reads.call_count, 0)
        self.assertEqual(self.period()["buckets"], rewritten)
        self.assertEqual(self.source("codex")["malformedRecords"], 0)
        self.assertNotIn(os.path.relpath(original, self.tmp), self.cached_paths())
        os.remove(archive)
        self.run_usage()
        self.assertEqual(self.period()["buckets"], rewritten)
        self.assertEqual(self.source("codex")["malformedRecords"], 0)

    def test_сохранённый_расход_удалённого_каталога_виден_только_окнам_до_которых_дотягивается(self):
        # UsageService.test.ts:3970-4003
        self.now = T("2026-08-15T00:00:00Z")
        written = T("2026-08-01T10:00:00Z")
        path = self.put("claude/projects/app/s1.jsonl", base.claude_line("msg_1", 5, written))
        os.utime(path, ns=(written * 1000000, written * 1000000))
        self.run_usage()
        first = self.period(30)["buckets"]
        self.assertEqual([bucket["totals"]["outputTokens"] for bucket in first], [5])
        base.shutil.rmtree(os.path.join(self.tmp, "claude", "projects"))
        self.run_usage()
        self.assertEqual(self.period(30)["buckets"], first)
        self.assertEqual(self.source("claude", 30)["status"], "ok")
        self.assertEqual(self.period(7)["buckets"], [])
        later = self.source("claude", 7)
        self.assertEqual((later["status"], later["scannedFiles"]), ("missing", 0))


class FirstRun(base.UsageCase):
    def test_первая_команда_на_свежей_машине_создаёт_закрытый_корень(self):
        """BRIEF §2: каталоги 0700. `usage` может оказаться первой командой, и её корень состояния —
        промежуточный каталог для usage/: mode у os.makedirs на такие не действует."""
        base.shutil.rmtree(mcpbar.ROOT)
        old = os.umask(0o022)
        try:
            self.run_usage()
        finally:
            os.umask(old)
        self.assertEqual(stat.S_IMODE(os.stat(mcpbar.ROOT).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(mcpbar.ROOT, "usage")).st_mode), 0o700)


if __name__ == "__main__":
    unittest.main()
