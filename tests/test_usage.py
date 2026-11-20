#!/usr/bin/env python3
"""Тесты разбора истории расхода: строки транскриптов, чтение с возобновлением, свод копий,
окна и цены. Векторы перенесены из тестов T3 Code (claudeUsage, codexUsage,
usageTranscriptReader, usageAggregation, usagePricing).

Запуск: /usr/bin/python3 -m unittest discover -s tests -v
"""

import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

import mcpbar_usage as usage  # noqa: E402
from mcpbar_usage import (CACHED, CACHE_WRITE, CACHE_WRITE_1H, COST, KEY, MODEL, OUTPUT, REASONING,  # noqa: E402
                          SESSION, SPEED, TS, UNCACHED)


def T(text):
    return usage.parse_timestamp_ms(text)


def totals(record):
    return [record[i] for i in (UNCACHED, CACHED, CACHE_WRITE, OUTPUT, REASONING)]


def total_tokens(record):
    return record[UNCACHED] + record[CACHED] + record[CACHE_WRITE] + record[OUTPUT]


def claude_line(message_id, output, timestamp="2026-08-01T10:00:00Z", model="claude-fable-5",
                session="session-1", **extra):
    usage_block = {"input_tokens": 10, "output_tokens": output}
    usage_block.update(extra)
    return json.dumps({"type": "assistant", "timestamp": timestamp, "sessionId": session,
                       "requestId": "req_" + message_id,
                       "message": {"id": message_id, "model": model, "usage": usage_block}},
                      ensure_ascii=False) + "\n"


def counters(given, produced):
    return {"input_tokens": given, "output_tokens": produced, "total_tokens": given + produced}


def meta(session, timestamp="2026-08-01T05:00:00.000Z", **extra):
    return {"type": "session_meta", "timestamp": timestamp, "payload": dict({"type": "session_meta", "id": session}, **extra)}


def turn(model, timestamp="2026-08-01T05:00:00.000Z"):
    return {"type": "turn_context", "timestamp": timestamp, "payload": {"type": "turn_context", "model": model}}


def snapshot(timestamp, last, total=None, **info):
    body = dict({"last_token_usage": last}, **info)
    if total is not None:
        body["total_token_usage"] = total
    return {"type": "event_msg", "timestamp": timestamp, "payload": {"type": "token_count", "info": body}}


def request(timestamp, usage_block, response_id=None):
    payload = {"usage": usage_block}
    if response_id is not None:
        payload["response_id"] = response_id
    return {"type": "token_usage_record", "timestamp": timestamp, "payload": payload}


def tier(value, timestamp="2026-08-01T05:00:00.000Z"):
    return {"type": "event_msg", "timestamp": timestamp,
            "payload": {"type": "thread_settings_applied", "thread_settings": {"service_tier": value}}}


def billed(lines):
    """Сколько токенов оплачено каждой строкой (0 — записи нет) и итоговое состояние."""
    state = usage.initial_codex_state()
    return [sum(total_tokens(record) for record in usage.parse_codex_record(line, state)) for line in lines], state


def codex_records(lines):
    state = usage.initial_codex_state()
    return [record for line in lines for record in usage.parse_codex_record(line, state)], state


class ClaudeRecords(unittest.TestCase):
    def test_обычный_ответ(self):
        line = {"type": "assistant", "timestamp": "2026-08-07T04:05:13.944Z",
                "sessionId": "5a128faa-8253-489e-b935-6c08e8e670c0", "cwd": "/home/theo/project",
                "message": {"id": "msg_1", "role": "assistant", "model": "claude-fable-5",
                            "content": [{"type": "text"}],
                            "usage": {"input_tokens": 2, "cache_creation_input_tokens": 66818,
                                      "cache_read_input_tokens": 1000, "output_tokens": 286}}}
        self.assertEqual(usage.parse_claude_record(line), [
            [1786075513944, "claude-fable-5", "5a128faa-8253-489e-b935-6c08e8e670c0",
             2, 1000, 66818, 286, 0, "msg_1:", None, "standard", 0]])

    def test_ключ_из_id_сообщения_и_запроса(self):
        def key(message_id=None, request_id=None):
            line = {"type": "assistant", "timestamp": "2026-08-07T04:05:13.944Z",
                    "message": {"model": "claude-fable-5", "usage": {"input_tokens": 1, "output_tokens": 1}}}
            if message_id:
                line["message"]["id"] = message_id
            if request_id:
                line["requestId"] = request_id
            return usage.parse_claude_record(line)[0][KEY]

        self.assertEqual(key("msg_1", "req_1"), "msg_1:req_1")
        self.assertEqual(key("msg_1"), "msg_1:")
        self.assertEqual(key(None, "req_1"), ":req_1")
        self.assertIsNone(key())

    def test_нулевой_расход_остаётся_а_synthetic_нет(self):
        line = {"type": "assistant", "timestamp": "2026-08-07T04:05:13.944Z",
                "message": {"model": "claude-fable-5", "usage": {"input_tokens": 0, "output_tokens": 0}}}
        (record,) = usage.parse_claude_record(line)
        self.assertEqual(totals(record), [0, 0, 0, 0, 0])
        self.assertEqual((record[SESSION], record[KEY]), ("", None))
        line["message"]["model"] = "<synthetic>"
        self.assertEqual(usage.parse_claude_record(line), [])

    def test_строки_без_расхода_не_дают_записей(self):
        good = {"type": "assistant", "timestamp": "2026-08-07T04:05:13.944Z",
                "message": {"model": "claude-fable-5", "usage": {"input_tokens": 1, "output_tokens": 1}}}
        for change in ({"type": "user"}, {"timestamp": 1786075513944}, {"timestamp": "вчера"},
                       {"message": "текст"}, {"message": {"model": "claude-fable-5", "usage": [1]}},
                       {"message": {"model": "", "usage": {}}}, {"message": {"usage": {}}}):
            self.assertEqual(usage.parse_claude_record(dict(good, **change)), [], change)
        self.assertEqual(usage.parse_claude_record([good]), [])

    def test_advisor_даёт_отдельную_запись_под_своей_моделью(self):
        line = {"type": "assistant", "timestamp": "2026-10-22T01:31:11.984Z",
                "sessionId": "5a128faa-8253-489e-b935-6c08e8e670c0", "requestId": "req_1",
                "message": {"id": "msg_1", "model": "claude-opus-5-5", "usage": {
                    "input_tokens": 4, "cache_read_input_tokens": 118320, "cache_creation_input_tokens": 2676,
                    "output_tokens": 4506, "speed": "standard", "iterations": [
                        {"type": "message", "input_tokens": 2, "cache_read_input_tokens": 58352,
                         "cache_creation_input_tokens": 1616, "output_tokens": 141},
                        {"type": "advisor_message", "model": "claude-fable-5-1", "input_tokens": 54204,
                         "cache_read_input_tokens": 0, "cache_creation_input_tokens": 500,
                         "cache_creation": {"ephemeral_5m_input_tokens": 200, "ephemeral_1h_input_tokens": 300},
                         "output_tokens": 4229},
                        {"type": "message", "input_tokens": 2, "cache_read_input_tokens": 59968,
                         "cache_creation_input_tokens": 1060, "output_tokens": 4365},
                        None, "текст", {"type": "advisor_message"}, {"type": "advisor_message", "model": ""},
                        {"type": "advisor_message", "model": "<synthetic>", "output_tokens": 9}]}}}
        executor, advisor = usage.parse_claude_record(line)
        self.assertEqual((executor[MODEL], totals(executor), executor[KEY]),
                         ("claude-opus-5-5", [4, 118320, 2676, 4506, 0], "msg_1:req_1"))
        self.assertEqual((advisor[MODEL], totals(advisor), advisor[CACHE_WRITE_1H], advisor[COST], advisor[KEY]),
                         ("claude-fable-5-1", [54204, 0, 500, 4229, 0], 300, None, "msg_1:req_1:advisor:1"))
        self.assertEqual(advisor[TS], executor[TS])

    def test_быстрый_режим_и_цена_от_провайдера(self):
        line = {"type": "assistant", "timestamp": "2026-08-01T10:00:00Z", "sessionId": "s1", "requestId": "r-m1",
                "costUSD": 0.25,
                "message": {"content": [{"type": "tool_use", "input": {"text": "…"}}], "id": "m1",
                            "model": "claude-fable-5",
                            "usage": {"input_tokens": 100, "output_tokens": 99, "cache_read_input_tokens": 20,
                                      "cache_creation_input_tokens": 5, "speed": "fast"}}}
        (record,) = usage.parse_claude_record(line)
        self.assertEqual(record, [1785578400000, "claude-fable-5", "s1", 100, 20, 5, 99, 0, "m1:r-m1", 0.25, "fast", 0])
        for cost in (True, "0.25", float("inf"), None):
            self.assertIsNone(usage.parse_claude_record(dict(line, costUSD=cost))[0][COST], cost)

    def test_запись_в_кэш_на_час_читается_отдельно(self):
        line = {"type": "assistant", "timestamp": "2026-08-07T04:05:13.944Z", "sessionId": "s",
                "message": {"id": "msg_ttl", "model": "claude-opus-4-5-20251101", "usage": {
                    "input_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 1000000,
                    "cache_creation": {"ephemeral_5m_input_tokens": 400000, "ephemeral_1h_input_tokens": 600000},
                    "output_tokens": 0}}}
        (record,) = usage.parse_claude_record(line)
        self.assertEqual((record[CACHE_WRITE], record[CACHE_WRITE_1H]), (1000000, 600000))

    def test_мягкий_счётчик(self):
        for value, expected in ((12.9, 12), (-3, 0), ("7", 0), (None, 0), (True, 0), (float("nan"), 0),
                                (float("inf"), 0), (0, 0)):
            self.assertEqual(usage.token_count(value), expected, value)

    def test_время_только_строкой_и_с_миллисекундами(self):
        self.assertEqual(T("2026-08-01T10:00:00Z"), 1785578400000)
        self.assertEqual(T("2026-08-07T04:05:13.944Z"), 1786075513944)
        self.assertEqual(T("2026-08-07T06:05:13.944123+02:00"), 1786075513944)
        self.assertIsNone(T(1786075513944))
        self.assertIsNone(T("2026-13-40T00:00:00Z"))


class CodexRecords(unittest.TestCase):
    def test_модель_и_сессия_берутся_из_соседних_строк(self):
        lines = [
            {"type": "session_meta", "timestamp": "2026-08-01T05:17:41.289Z",
             "payload": {"type": "session_meta", "id": "019fbbc1-b12c-7360-a685-28c181f0025f"}},
            {"type": "turn_context", "timestamp": "2026-08-01T05:17:42.694Z",
             "payload": {"type": "turn_context", "model": "gpt-5.6-sol"}},
            snapshot("2026-08-01T05:17:49.919Z", {"input_tokens": 19239, "cached_input_tokens": 11008,
                                                  "cache_write_input_tokens": 0, "output_tokens": 299,
                                                  "reasoning_output_tokens": 116}),
        ]
        records, _state = codex_records(lines + [lines[2]])
        self.assertEqual(records, [[T("2026-08-01T05:17:49.919Z"), "gpt-5.6-sol",
                                    "019fbbc1-b12c-7360-a685-28c181f0025f", 8231, 11008, 0, 299, 116,
                                    None, None, "standard", 0]])

    def test_расход_до_модели_ждёт_повтора(self):
        last = {"input_tokens": 19239, "cached_input_tokens": 11008, "output_tokens": 299}
        count = snapshot("2026-08-01T05:17:49.919Z", last)
        state = usage.initial_codex_state()
        self.assertEqual(usage.parse_codex_record(count, state), [])
        self.assertEqual(state, usage.initial_codex_state())
        usage.parse_codex_record(turn("gpt-5.6-sol"), state)
        self.assertEqual(len(usage.parse_codex_record(count, state)), 1)

    def test_итог_проверяет_запрос_а_тариф_берётся_из_настроек_потока(self):
        req = counters(100, 20)
        lines = [turn("gpt-5.6-sol"),
                 snapshot("2026-08-01T05:00:01.000Z", req, req),
                 snapshot("2026-08-01T05:00:02.000Z", counters(20, 5), req),
                 snapshot("2026-08-01T05:00:03.000Z", {"input_tokens": 0, "output_tokens": 0, "total_tokens": 20330},
                          req, model_context_window=258400),
                 snapshot("2026-08-01T05:00:04.000Z", req, counters(200, 40)),
                 turn("gpt-6-astra"), tier("priority"),
                 snapshot("2026-08-01T05:00:05.000Z", req, counters(300, 60)),
                 tier("ultrafast"),
                 snapshot("2026-08-01T05:00:06.000Z", req, counters(400, 80))]
        records, state = codex_records(lines)
        self.assertEqual([(r[MODEL], r[SPEED], r[UNCACHED], r[OUTPUT]) for r in records], [
            ("gpt-5.6-sol", "standard", 100, 20), ("gpt-5.6-sol", "standard", 100, 20),
            ("gpt-6-astra", "fast", 100, 20), ("gpt-6-astra", "ultrafast", 100, 20)])
        self.assertEqual(state["malformedRecords"], 0)

    def test_тариф_потока(self):
        for value, speed in (("priority", "fast"), ("fast", "fast"), ("ultrafast", "ultrafast"),
                             ("default", "standard"), ("", "standard"), (None, "standard")):
            self.assertEqual(usage.codex_speed(value), speed, value)

    def test_прерванный_ход_восстанавливается_по_безымянным_запросам(self):
        lines = [
            meta("session-a", "2026-11-01T23:59:50.000Z", model_provider="openai"),
            turn("gpt-6-sol", "2026-11-01T23:59:50.000Z"),
            request("2026-11-01T23:59:51.000Z", counters(100, 20)),
            snapshot("2026-11-01T23:59:52.000Z", counters(100, 20), counters(100, 20)),
            request("2026-11-01T23:59:59.000Z", counters(150, 10)),
            request("2026-11-02T00:00:01.000Z", counters(50, 5)),
            tier("priority", "2026-11-02T00:00:02.000Z"),
            turn("gpt-6-astra", "2026-11-02T00:00:02.000Z"),
            request("2026-11-02T00:00:03.000Z", counters(50, 5)),
            request("2026-11-02T00:00:04.000Z", counters(30, 5)),
            tier("default", "2026-11-02T00:00:05.000Z"),
            turn("gpt-6-sol", "2026-11-02T00:00:05.000Z"),
            request("2026-11-02T00:00:06.000Z", counters(200, 30)),
            snapshot("2026-11-02T00:00:07.000Z", counters(200, 30), counters(580, 75)),
        ]
        records, state = codex_records(lines)
        self.assertEqual([(total_tokens(r), r[MODEL], r[SPEED], r[TS], r[SESSION]) for r in records], [
            (120, "gpt-6-sol", "standard", T("2026-11-01T23:59:52.000Z"), "session-a"),
            (160, "gpt-6-sol", "standard", T("2026-11-01T23:59:59.000Z"), "session-a"),
            (55, "gpt-6-sol", "standard", T("2026-11-02T00:00:01.000Z"), "session-a"),
            (55, "gpt-6-astra", "fast", T("2026-11-02T00:00:03.000Z"), "session-a"),
            (35, "gpt-6-astra", "fast", T("2026-11-02T00:00:04.000Z"), "session-a"),
            (230, "gpt-6-sol", "standard", T("2026-11-02T00:00:07.000Z"), "session-a")])
        self.assertEqual(state["malformedRecords"], 0)
        # Четыре средних запроса появляются только с последним снимком, который их подтверждает.
        self.assertEqual(len(codex_records(lines[:-1])[0]), 1)

    def test_названные_запросы_главнее_снимков(self):
        session = "019fbbc1-b12c-7360-a685-28c181f0025f"
        full = {"input_tokens": 80, "cached_input_tokens": 0, "cache_write_input_tokens": 0,
                "output_tokens": 10, "reasoning_output_tokens": 0, "total_tokens": 90}
        lines = [meta(session), turn("gpt-5.6-sol"),
                 snapshot("2026-08-01T05:17:44.000Z", counters(100, 20), counters(1000, 200)),
                 request("2026-08-01T05:17:45.000Z", full, "response-1"),
                 snapshot("2026-08-01T05:17:46.000Z", counters(80, 10), counters(580, 110)),
                 snapshot("2026-08-01T05:17:47.000Z", counters(80, 10), counters(580, 110)),
                 request("2026-08-01T05:17:48.000Z", counters(90, 15), "compaction"),
                 request("2026-08-01T05:17:49.000Z", counters(15, 3)),
                 turn("gpt-5.6-sol"),
                 request("2026-08-01T05:17:50.000Z", counters(25, 5), "upgraded")]
        records, _state = codex_records(lines)
        self.assertEqual([r[OUTPUT] for r in records], [20, 10, 15, 3, 5])
        self.assertEqual([r[KEY] for r in records], [
            None, '["codex","%s","response-1"]' % session, '["codex","%s","compaction"]' % session,
            None, '["codex","%s","upgraded"]' % session])

    def test_отметка_сжатия_и_перезапуск_счётчиков(self):
        marker = {"input_tokens": 0, "output_tokens": 0, "total_tokens": 26387}
        bills, state = billed([turn("gpt-5.6-sol"),
                               snapshot("2026-08-01T05:00:01.000Z", marker, counters(0, 0), model_context_window=475000),
                               snapshot("2026-08-01T05:00:02.000Z", counters(30, 5), counters(30, 5))])
        self.assertEqual((bills, state["malformedRecords"]), ([0, 0, 35], 0))
        bills, state = billed([turn("gpt-5.6-sol"),
                               snapshot("2026-08-01T05:00:01.000Z", counters(100, 20), counters(100, 20)),
                               snapshot("2026-08-01T05:00:02.000Z", counters(30, 5), counters(30, 5)),
                               snapshot("2026-08-01T05:00:03.000Z", counters(10, 2), counters(40, 7))])
        self.assertEqual((bills, state["malformedRecords"]), ([0, 120, 35, 12], 0))

    def test_откаты_и_повторы(self):
        def at(clock):
            return "2026-08-01T%sZ" % clock

        start = [turn("gpt-5.6-sol"),
                 snapshot(at("10:00:00"), counters(100, 20), counters(100, 20)),
                 snapshot(at("10:00:01"), counters(10, 2), counters(110, 22)),
                 snapshot(at("10:00:02"), counters(30, 5), counters(140, 27))]
        cases = [
            (start + [snapshot(at("12:00:02"), counters(20, 4), counters(130, 26)),
                      snapshot(at("12:00:03"), counters(5, 1), counters(135, 27))], [120, 12, 35, 24, 6], 0),
            (start + [snapshot(at("10:00:02"), counters(10, 2), counters(110, 22))], [120, 12, 35, 0], 1),
            ([turn("gpt-5.6-sol"),
              snapshot(at("10:00:00"), counters(100, 20), counters(100, 20)),
              snapshot(at("10:00:05"), counters(20, 4)),
              snapshot(at("10:00:10"), counters(30, 6)),
              snapshot(at("10:00:05"), counters(20, 4), counters(120, 24))], [120, 24, 36, 0], 1),
            ([turn("gpt-5.6-sol"),
              snapshot(at("10:00:00"), counters(100, 20)),
              snapshot(at("10:00:10"), counters(20, 4), counters(60, 12))], [120, 24], 0),
            ([turn("gpt-5.6-sol"),
              snapshot(at("10:00:00"), counters(100, 20), counters(100, 20)),
              request(at("10:00:03"), counters(40, 8)),
              request(at("10:00:05"), counters(20, 4)),
              snapshot(at("10:00:07"), counters(20, 4), counters(60, 12)),
              snapshot(at("10:00:08"), counters(10, 2), counters(70, 14))], [120, 0, 0, 24, 12], 1),
        ]
        for lines, expected, malformed in cases:
            bills, state = billed(lines)
            self.assertEqual((bills[1:], state["malformedRecords"]), (expected, malformed))

    def test_пачка_скопированной_истории_форка_не_считается(self):
        for child in (meta("child", forked_from_id="parent"),
                      meta("child", source={"subagent": {"thread_spawn": {"parent_thread_id": "parent"}}})):
            lines = [child, meta("parent"), turn("gpt-5.6-sol"),
                     snapshot("2026-08-01T05:00:00.001Z", counters(100, 10), counters(100, 10)),
                     snapshot("2026-08-01T05:00:00.002Z", counters(200, 20), counters(300, 30)),
                     snapshot("2026-08-01T05:00:06.000Z", counters(200, 20), counters(500, 50)),
                     snapshot("2026-08-01T05:00:06.100Z", counters(400, 40), counters(900, 90))]
            records, state = codex_records(lines)
            self.assertEqual([(r[SESSION], r[OUTPUT]) for r in records], [("child", 20), ("child", 40)])
            self.assertEqual(state["malformedRecords"], 0)

    def test_расход_codex_проверяется_строго(self):
        self.assertEqual(usage.read_codex_usage({"input_tokens": 100, "output_tokens": 20}), (100, 0, 0, 20, 0, 120))
        for broken in ({"input_tokens": 100, "output_tokens": 20, "cached_input_tokens": None},
                       {"input_tokens": "40", "output_tokens": 20},
                       {"input_tokens": 100, "output_tokens": 20, "reasoning_output_tokens": -1},
                       {"input_tokens": 100, "output_tokens": 20, "cached_input_tokens": 101},
                       {"input_tokens": 100, "output_tokens": 20, "reasoning_output_tokens": 21},
                       {"input_tokens": 100, "output_tokens": 20, "total_tokens": 119},
                       {"input_tokens": 1.5, "output_tokens": 20}, {"output_tokens": 20}, [100, 20]):
            self.assertIsNone(usage.read_codex_usage(broken), broken)
        bills, state = billed([turn("gpt-5.6-sol"),
                               snapshot("2026-08-01T05:00:01.000Z", {"input_tokens": "40", "output_tokens": 2})])
        self.assertEqual((bills, state["malformedRecords"]), ([0, 0], 1))

    def test_снимок_только_с_лимитами_пропускается(self):
        line = {"type": "event_msg", "timestamp": "2026-08-01T05:00:01.000Z",
                "payload": {"type": "token_count", "info": None, "rate_limits": {"primary": {"used_percent": 4}}}}
        bills, state = billed([turn("gpt-5.6-sol"), line])
        self.assertEqual((bills, state["malformedRecords"]), ([0, 0], 0))


class Reader(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.path = os.path.join(self._dir.name, "session.jsonl")

    def write(self, text, mode="w"):
        with open(self.path, mode + "b") as handle:
            handle.write(text.encode("utf-8") if isinstance(text, str) else text)

    def read(self, provider="claude", resume=None):
        return usage.read_transcript(self.path, provider, resume)

    def test_контрольные_значения_fnv(self):
        self.assertEqual(usage.fnv1a(b""), 2166136261)
        self.assertEqual(usage.fnv1a(b"a"), 0xE40C292C)
        self.assertEqual(usage.fnv1a(b"foobar"), 0xBF9CF968)

    def test_при_возобновлении_читается_только_дописанное(self):
        self.write(claude_line("1", 5) + claude_line("2", 7))
        first = self.read()
        self.assertEqual(([r[OUTPUT] for r in first["records"]], first["resumed"]), ([5, 7], False))
        self.assertEqual(first["position"]["resumeOffset"], os.path.getsize(self.path))
        self.write(claude_line("3", 11), "a")
        second = self.read(resume=json.loads(json.dumps(first["position"])))
        self.assertEqual(([r[OUTPUT] for r in second["records"]], second["resumed"]), ([11], True))

    def test_строка_без_перевода_идёт_в_хвост_и_дочитывается_позже(self):
        self.write(claude_line("1", 5) + claude_line("2", 7).rstrip("\n"))
        first = self.read()
        self.assertEqual(([r[OUTPUT] for r in first["records"]], [r[OUTPUT] for r in first["tailRecords"]]),
                         ([5], [7]))
        self.write("\n" + claude_line("3", 11), "a")
        second = self.read(resume=first["position"])
        self.assertEqual((second["resumed"], [r[OUTPUT] for r in second["records"]], second["tailRecords"]),
                         (True, [7, 11], []))

    def test_переписанный_файл_читается_целиком(self):
        self.write(claude_line("1", 5) + claude_line("2", 7))
        position = self.read()["position"]
        for rewritten in (claude_line("9", 13) + claude_line("8", 17) + claude_line("7", 19), claude_line("9", 13)):
            self.write(rewritten)
            again = self.read(resume=position)
            self.assertFalse(again["resumed"])
            self.assertEqual(again["records"][0][OUTPUT], 13)

    def test_обрыв_посреди_символа_или_объекта_не_даёт_записи(self):
        whole = claude_line("1", 5, session="сессия")
        raw = whole.encode("utf-8")
        cut = raw.index("сессия".encode("utf-8")) + 1
        for part in (raw[:cut], raw[:-10]):
            self.write(part)
            first = self.read()
            self.assertEqual((first["records"], first["tailRecords"]), ([], []))
            self.write(raw)
            self.assertEqual([r[OUTPUT] for r in self.read(resume=first["position"])["records"]], [5])

    def test_crlf(self):
        text = claude_line("1", 5).replace("\n", "\r\n") + claude_line("2", 7).replace("\n", "\r\n")
        self.write(text)
        parsed = self.read()
        self.assertEqual([r[OUTPUT] for r in parsed["records"]], [5, 7])
        self.assertEqual(parsed["position"]["resumeOffset"], len(text.encode("utf-8")))

    def test_маркер_внутри_чужого_текста_не_даёт_записи(self):
        inner = claude_line("1", 5)
        lines = [json.dumps({"type": "user", "toolOutput": inner}),
                 json.dumps({"type": "assistant", "timestamp": "2026-08-01T10:00:00Z",
                             "message": {"model": "claude-fable-5", "content": inner}}),
                 json.dumps({"type": "assistant", "timestamp": "2026-08-01T10:00:00Z",
                             "message": {"model": "claude-fable-5", "content": [json.loads(inner)]}}),
                 '{"type":"assistant","message":{"usage":{"input_tokens":NaN}}}', "не JSON, но \"usage\" и \"assistant\""]
        self.write("\n".join(lines) + "\n")
        self.assertEqual(self.read()["records"], [])

    def test_границы_кусков_не_меняют_результат(self):
        filler = json.dumps({"type": "user", "text": "x" * 300}) + "\n"
        text = "".join(filler + claude_line(str(i), i + 1, session="сессия") for i in range(40)) + claude_line("t", 99).rstrip("\n")
        self.write(text)
        whole = self.read()
        self.assertEqual(len(whole["records"]), 40)
        for chunk in (1, 7, 64, 333):
            with mock.patch.object(usage, "READ_CHUNK", chunk):
                self.assertEqual(self.read(), whole, chunk)

    def test_состояние_codex_переживает_возобновление_через_json(self):
        lines = [meta("s"), turn("gpt-5.6-sol"),
                 snapshot("2026-08-01T05:00:01.000Z", counters(100, 20), counters(100, 20)),
                 request("2026-08-01T05:00:02.000Z", counters(40, 8)),
                 request("2026-08-01T05:00:03.000Z", counters(20, 4)),
                 snapshot("2026-08-01T05:00:04.000Z", counters(20, 4), counters(160, 32)),
                 snapshot("2026-08-01T05:00:04.000Z", counters(20, 4), counters(160, 32)),
                 snapshot("2026-08-01T05:00:05.000Z", counters(10, 2), counters(170, 34))]
        text = [json.dumps(line) + "\n" for line in lines]
        self.write("".join(text))
        whole = self.read("codex")
        self.assertEqual([total_tokens(r) for r in whole["records"]], [120, 48, 24, 12])
        for cut in range(1, len(text)):
            self.write("".join(text[:cut]))
            first = self.read("codex")
            self.write("".join(text[cut:]), "a")
            second = self.read("codex", json.loads(json.dumps(first["position"])))
            self.assertTrue(second["resumed"], cut)
            self.assertEqual(first["records"] + second["records"], whole["records"], cut)
            self.assertEqual(second["malformedRecords"], whole["malformedRecords"])

    def test_хвост_codex_не_портит_сохранённое_состояние(self):
        lines = [json.dumps(line) for line in (
            meta("s"), turn("gpt-5.6-sol"),
            snapshot("2026-08-01T05:00:01.000Z", counters(100, 20), counters(100, 20)),
            snapshot("2026-08-01T05:00:02.000Z", {"input_tokens": "40", "output_tokens": 2}),
            snapshot("2026-08-01T05:00:03.000Z", counters(10, 2), counters(110, 22)))]
        self.write("\n".join(lines[:3]) + "\n" + lines[3])
        first = self.read("codex")
        self.assertEqual((len(first["records"]), first["tailRecords"], first["malformedRecords"]), (1, [], 1))
        self.assertEqual(first["position"]["state"]["malformedRecords"], 0)
        self.write("\n" + lines[4], "a")
        second = self.read("codex", json.loads(json.dumps(first["position"])))
        # Хвост учтён в диагностике, но не в состоянии: дочитанная строка считается один раз.
        self.assertEqual((second["records"], [total_tokens(r) for r in second["tailRecords"]],
                          second["malformedRecords"]), ([], [12], 1))
        self.write("\n", "a")
        third = self.read("codex", json.loads(json.dumps(second["position"])))
        self.assertEqual(([total_tokens(r) for r in third["records"]], third["tailRecords"]), ([12], []))

    def test_непригодное_состояние_codex_запрещает_возобновление(self):
        self.write("".join(json.dumps(line) + "\n" for line in (
            meta("s"), turn("gpt-5.6-sol"), snapshot("2026-08-01T05:00:01.000Z", counters(100, 20), counters(100, 20)))))
        position = self.read("codex")["position"]
        self.write(json.dumps(snapshot("2026-08-01T05:00:02.000Z", counters(10, 2), counters(110, 22))) + "\n", "a")
        for state in (None, {"model": "gpt"}, dict(position["state"], lastCumulativeUsage=[1, 2]),
                      dict(position["state"], speed="warp"), dict(position["state"], unreportedRequests=[{}])):
            again = self.read("codex", dict(position, state=state))
            self.assertFalse(again["resumed"])
            self.assertEqual(len(again["records"]), 2)

    def test_непрочитанный_файл_это_none_а_не_пусто(self):
        self.assertIsNone(usage.read_transcript(os.path.join(self._dir.name, "нет.jsonl"), "claude"))
        self.assertIsNone(usage.read_transcript(os.path.join(self._dir.name, "a.jsonl.zst"), "codex", None, None))


def ledger_buckets(files, window, time_zone="UTC", table=None, overrides=None, aliases=None):
    """files: [(провайдер, [записи])] в порядке счёта → (корзины, сессии по провайдерам, свод)."""
    ledger = usage.Ledger(table or {}, overrides or {}, aliases or {})
    for provider, records in files:
        ledger.add_file(provider, records)
    buckets, sessions = usage.aggregate(ledger.finish(), window, time_zone)
    return buckets, sessions, ledger


def day_window(since, until=None):
    return {"resolution": "day", "sinceDay": since, "untilDay": until or since}


def row(model="claude-fable-5", output=50, timestamp="2026-08-07T04:05:13.944Z", key=None, session="session-a",
        uncached=100, cached=1000, written=10, reasoning=0, cost=None, speed="standard", one_hour=0):
    return [T(timestamp), model, session, uncached, cached, written, output, reasoning, key, cost, speed, one_hour]


FABLE = {"claude-fable-5": {"input_cost_per_token": 1e-5, "output_cost_per_token": 5e-5,
                            "cache_read_input_token_cost": 1e-6, "cache_creation_input_token_cost": 1.25e-5,
                            "provider_specific_entry": {"fast": 2}}}


class Dedupe(unittest.TestCase):
    def test_два_блока_одного_сообщения_это_один_запрос(self):
        lines = [json.loads(claude_line("msg_2", 286)) for _ in range(2)]
        lines[1]["message"]["content"] = [{"type": "tool_use"}]
        records = [record for line in lines for record in usage.parse_claude_record(line)]
        self.assertEqual(len(records), 2)
        (kept,) = usage.dedupe_within_file(records)
        self.assertEqual(kept[OUTPUT], 286)
        buckets, _sessions, ledger = ledger_buckets([("claude", records)], day_window("2026-08-01"))
        self.assertEqual((buckets[0]["records"], buckets[0]["totals"]["outputTokens"], ledger.duplicates), (1, 286, 1))

    def test_начало_ответа_и_его_конец_сливаются_по_максимуму(self):
        first = row(output=3, uncached=2, cached=67934, written=1097, key="msg_1:req_1", timestamp="2026-08-01T10:00:00Z")
        final = row(output=264, uncached=2, cached=67934, written=1097, key="msg_1:req_1", timestamp="2026-08-01T10:00:00Z")
        (kept,) = usage.dedupe_within_file([first, final])
        self.assertEqual(totals(kept), [2, 67934, 1097, 264, 0])
        # Хвост без перевода строки внутри файла не сливается — это делает общий свод.
        buckets, _s, _l = ledger_buckets([("claude", [first, final])], day_window("2026-08-01"),
                                         table=usage.parse_rate_table(FABLE))
        self.assertEqual(buckets[0]["records"], 1)
        self.assertAlmostEqual(buckets[0]["costUsd"], 2 * 1e-5 + 67934 * 1e-6 + 1097 * 1.25e-5 + 264 * 5e-5, places=12)

    def test_записи_без_ключа_остаются_все(self):
        records = [row(output=1), row(output=1), row(output=1, key="k"), row(output=4, key="k")]
        self.assertEqual([r[OUTPUT] for r in usage.dedupe_within_file(records)], [1, 1, 4])

    def test_слияние_берёт_максимум_каналов_и_цены_а_остальное_от_первой(self):
        held = row(output=3, uncached=100, cached=1200, written=10, reasoning=5, cost=1, key="k", one_hour=2)
        other = row(model="claude-fable-5[1m]", output=264, uncached=2, cached=1000, written=40, reasoning=135,
                    cost=2, key="k", session="session-fork", speed="fast", timestamp="2026-08-08T12:00:00Z", one_hour=7)
        merged = usage.merge_usage_copies(held, other)
        self.assertEqual(merged, [held[TS], "claude-fable-5", "session-a", 100, 1200, 40, 264, 135, "k", 2, "standard", 7])
        self.assertIs(usage.merge_usage_copies(merged, held), merged)
        self.assertEqual(usage.merge_usage_copies(row(cost=None, key="k"), row(cost=0.5, key="k"))[COST], 0.5)
        self.assertEqual(usage.merge_usage_copies(row(cost=0.5, key="k"), row(cost=None, key="k"))[COST], 0.5)

    def test_копии_в_разных_файлах_считаются_в_ячейке_первой(self):
        zero = row(output=0, uncached=0, cached=0, written=0, key="msg_1:", speed="fast")
        partial = row(output=3, uncached=100, cached=1200, written=10, reasoning=5, cost=1, key="msg_1:")
        complete = row(model="claude-fable-5[1m]", output=264, uncached=2, cached=1000, written=40, reasoning=135,
                       cost=2, key="msg_1:", session="session-fork", timestamp="2026-08-08T12:00:00Z")
        window = day_window("2026-08-07", "2026-08-08")
        for order, day, model in (([zero, partial, complete, complete], "2026-08-07", "claude-fable-5"),
                                  ([complete, partial, zero, zero], "2026-08-08", "claude-fable-5[1m]")):
            buckets, sessions, ledger = ledger_buckets([("claude", [copy]) for copy in order], window)
            self.assertEqual(ledger.duplicates, 3)
            (bucket,) = buckets
            self.assertEqual((bucket["day"], bucket["model"], bucket["records"], bucket["costUsd"]), (day, model, 1, 2))
            self.assertEqual(bucket["totals"], {"uncachedInputTokens": 100, "cachedInputTokens": 1200,
                                                "cacheCreationTokens": 40, "outputTokens": 264, "reasoningTokens": 135})
            self.assertEqual(len(sessions["claude"]), 1)

    def test_первая_копия_вне_окна_уводит_из_окна_и_поздние(self):
        outside = row(output=5, key="k", timestamp="2026-08-01T10:00:00Z")
        inside = row(output=9, key="k", timestamp="2026-08-07T10:00:00Z")
        buckets, sessions, _ledger = ledger_buckets([("claude", [outside]), ("claude", [inside])], day_window("2026-08-07"))
        self.assertEqual((buckets, sessions), ([], {}))

    def test_переехавший_rollout_codex_не_удваивается(self):
        events = [row("gpt-5.6-sol", output, "2026-08-01T10:00:00Z", session="codex-account-session", uncached=10,
                      cached=0, written=0) for output in (11, 12, 11)]
        ledger = usage.Ledger({}, {}, {})
        for _copy in range(2):
            ledger.add_file("codex", events, {"codex-account-session"})
        buckets, _sessions = usage.aggregate(ledger.finish(), day_window("2026-08-01"), "UTC")
        self.assertEqual((buckets[0]["totals"]["outputTokens"], buckets[0]["records"]), (34, 3))
        # Без общей сессии одинаковые события разных файлов — разные запросы.
        buckets, _s, _l = ledger_buckets([("codex", events), ("codex", events)], day_window("2026-08-01"))
        self.assertEqual(buckets[0]["totals"]["outputTokens"], 68)


class Windows(unittest.TestCase):
    def test_сутки_это_24_часа_от_целой_минуты(self):
        window = usage.make_window(1, T("2026-08-11T12:37:42.123Z"), "UTC")
        self.assertEqual((usage.iso_ms(window["sinceMs"]), usage.iso_ms(window["untilMs"])),
                         ("2026-08-10T12:37:00.000Z", "2026-08-11T12:37:00.000Z"))
        self.assertEqual((window["resolution"], window["sinceDay"], window["untilDay"]),
                         ("hour", "2026-08-10", "2026-08-11"))

    def test_дни_считаются_по_календарю_пояса_включая_сегодня(self):
        now = T("2026-11-19T23:30:00Z")
        self.assertEqual(usage.make_window(7, now, "UTC"),
                         {"resolution": "day", "sinceDay": "2026-11-13", "untilDay": "2026-11-19"})
        berlin = usage.make_window(30, now, "Europe/Berlin")
        self.assertEqual((berlin["sinceDay"], berlin["untilDay"]), ("2026-10-22", "2026-11-20"))
        self.assertEqual(usage.make_window(90, now, "America/Los_Angeles")["sinceDay"], "2026-08-22")
        # Через перевод часов: вычитание миллисекунд дало бы 2026-03-28.
        self.assertEqual(usage.make_window(2, T("2026-03-29T22:30:00Z"), "Europe/Berlin")["sinceDay"], "2026-03-29")
        self.assertEqual(usage.make_window(7, now, "Нет/Такого")["untilDay"], "2026-11-19")

    def test_порог_mtime_окна(self):
        self.assertEqual(usage.window_start_ms(day_window("2026-08-03")), T("2026-08-01T12:00:00Z"))
        hour = usage.make_window(1, T("2026-08-11T12:37:42.123Z"), "UTC")
        self.assertEqual(usage.window_start_ms(hour), T("2026-08-09T00:37:00Z"))

    def test_день_записи_зависит_от_пояса(self):
        record = row(timestamp="2026-08-07T04:05:13.944Z")
        for zone, day in (("UTC", "2026-08-07"), ("America/Los_Angeles", "2026-08-06")):
            buckets, _s, _l = ledger_buckets([("claude", [record])], day_window("2026-08-01", "2026-08-31"), zone)
            self.assertEqual(buckets[0]["day"], day)
        edge = [row(timestamp="2026-08-01T18:14:59.999Z", output=1), row(timestamp="2026-08-01T18:15:00.000Z", output=2)]
        buckets, _s, _l = ledger_buckets([("claude", edge)], day_window("2026-08-01", "2026-08-02"), "Asia/Kathmandu")
        self.assertEqual([(b["day"], b["totals"]["outputTokens"]) for b in buckets], [("2026-08-01", 1), ("2026-08-02", 2)])
        buckets, _s, _l = ledger_buckets([("claude", [row(timestamp="2026-08-01T23:59:30Z")])],
                                         day_window("2026-08-01", "2026-08-02"), "+00:01")
        self.assertEqual(buckets[0]["day"], "2026-08-02")

    def test_границы_дневного_окна_включены(self):
        records = [row(timestamp="2026-08-0%dT12:00:00Z" % day, output=day) for day in (1, 2, 3, 4)]
        buckets, _s, _l = ledger_buckets([("claude", records)], day_window("2026-08-02", "2026-08-03"))
        self.assertEqual([b["totals"]["outputTokens"] for b in buckets], [2, 3])

    def test_часовые_корзины_отсчитываются_от_начала_окна(self):
        window = {"resolution": "hour", "sinceDay": "2026-08-05", "untilDay": "2026-08-06",
                  "sinceMs": T("2026-08-06T04:37:00Z"), "untilMs": T("2026-08-07T04:37:00Z")}
        records = [row(timestamp=stamp, output=index + 1) for index, stamp in enumerate((
            "2026-08-07T02:40:13.944Z", "2026-08-07T03:40:13.944Z", "2026-08-06T04:36:59.999Z",
            "2026-08-07T04:37:00.000Z", "2026-08-06T04:37:00.000Z"))]
        buckets, sessions, _l = ledger_buckets([("claude", records)], window, "America/Los_Angeles")
        self.assertEqual([(b["day"], b["hourStart"], b["totals"]["outputTokens"]) for b in buckets], [
            ("2026-08-05", "2026-08-06T04:37:00.000Z", 5),
            ("2026-08-06", "2026-08-07T02:37:00.000Z", 1),
            ("2026-08-06", "2026-08-07T03:37:00.000Z", 2)])
        self.assertEqual(len(sessions["claude"]), 1)

    def test_корзины_упорядочены_по_дню_провайдеру_и_модели(self):
        files = [("codex", [row("gpt-b", timestamp="2026-08-02T10:00:00Z"), row("gpt-a", timestamp="2026-08-02T10:00:00Z")]),
                 ("claude", [row("claude-z", timestamp="2026-08-02T10:00:00Z"), row("claude-z", timestamp="2026-08-01T10:00:00Z")])]
        buckets, _s, _l = ledger_buckets(files, day_window("2026-08-01", "2026-08-02"))
        self.assertEqual([(b["day"], b["provider"], b["model"]) for b in buckets], [
            ("2026-08-01", "claude", "claude-z"), ("2026-08-02", "claude", "claude-z"),
            ("2026-08-02", "codex", "gpt-a"), ("2026-08-02", "codex", "gpt-b")])
        self.assertNotIn("hourStart", buckets[0])


M = 1000000


def rate(given, cache_read=None, **extra):
    entry = {"input_cost_per_token": given, "output_cost_per_token": 5 * given}
    if cache_read is not None:
        entry["cache_read_input_token_cost"] = cache_read
    entry.update(extra)
    return entry


def million(model, speed="standard", cost=None):
    return row(model, output=M, uncached=M, cached=M, written=M, reasoning=M // 2, cost=cost, speed=speed)


def priced(table, record, overrides=None):
    found, is_override = usage.resolve_rate(table, overrides or {}, record[MODEL])
    return usage.price_usage(found, is_override, record)


class Pricing(unittest.TestCase):
    def test_своя_цена_главнее_таблицы_и_цены_провайдера(self):
        overrides = usage.parse_price_overrides({"example-model": {
            "inputCostPerMillionTokens": 2, "outputCostPerMillionTokens": 8,
            "cacheReadCostPerMillionTokens": 0.5, "cacheWriteCostPerMillionTokens": 3}})
        table = usage.parse_rate_table({"example-model": rate(1e-5)})
        for reported in (None, 99):
            cost, source, _parts, premium, savings = priced(table, million("example-model", cost=reported), overrides)
            self.assertAlmostEqual(cost, 13.5, places=9)
            self.assertEqual((source, premium), ("modelPriced", 0))
            self.assertAlmostEqual(savings, 1.5, places=9)

    def test_пустая_кэш_цена_равна_цене_входа(self):
        overrides = usage.parse_price_overrides({"example-model": {"inputCostPerMillionTokens": 2,
                                                                   "outputCostPerMillionTokens": 8}})
        cost, source, _parts, _premium, savings = priced({}, million("example-model"), overrides)
        self.assertAlmostEqual(cost, 14, places=9)
        self.assertEqual((source, savings), ("modelPriced", 0))

    def test_ноль_значит_бесплатно_и_совпадение_только_точное(self):
        overrides = usage.parse_price_overrides({" vendor/example-model[1m] ": {"inputCostPerMillionTokens": 0,
                                                                              "outputCostPerMillionTokens": 0}})
        self.assertEqual(priced({}, million("vendor/example-model[1m]", cost=99), overrides)[:2], (0, "modelPriced"))
        for model in ("example-model[1m]", "vendor/example-model", "vendor/Example-model[1m]", "other/example-model[1m]"):
            self.assertEqual(priced({}, million(model), overrides), (0.0, "unpriced", None, 0.0, 0.0))
            self.assertEqual(priced({}, million(model, cost=99), overrides), (99, "providerReported", None, 0.0, 0.0))

    def test_множитель_быстрого_режима_anthropic(self):
        table = usage.parse_rate_table({
            "claude-opus-5-5": rate(4e-6, 2e-7, provider_specific_entry={"fast": 2, "us": 1.1}),
            "claude-plain": rate(4e-6, 2e-7, provider_specific_entry={"us": 1.1})})
        standard, fast = priced(table, million("claude-opus-5-5")), priced(table, million("claude-opus-5-5", "fast"))
        self.assertAlmostEqual(standard[0], 28.2, places=9)
        self.assertAlmostEqual(fast[0], 56.4, places=9)
        self.assertAlmostEqual(standard[4], 3.8, places=9)
        self.assertAlmostEqual(fast[4], 7.6, places=9)
        self.assertAlmostEqual(priced(table, million("claude-plain", "fast"))[0], 28.2, places=9)
        overrides = usage.parse_price_overrides({"claude-opus-5-5": {"inputCostPerMillionTokens": 2,
                                                                     "outputCostPerMillionTokens": 8}})
        self.assertEqual(priced(table, million("claude-opus-5-5", "fast"), overrides)[0],
                         priced(table, million("claude-opus-5-5"), overrides)[0])

    def test_разбивка_по_категориям_и_надбавка(self):
        table = usage.parse_rate_table({"claude-opus-5-5": rate(4e-6, 4e-7, cache_creation_input_token_cost=5e-6,
                                                                 provider_specific_entry={"fast": 2})})
        cost, source, parts, premium, _savings = priced(table, million("claude-opus-5-5", "fast"))
        for got, expected in zip(parts + (cost, premium), (8, 0.8, 10, 40, 58.8, 29.4)):
            self.assertAlmostEqual(got, expected, places=9)
        self.assertEqual(source, "modelPriced")
        cost, source, parts, premium, _savings = priced(table, million("claude-opus-5-5", "fast", cost=29.4))
        for got, expected in zip(parts + (cost, premium), (4, 0.4, 5, 20, 29.4, 14.7)):
            self.assertAlmostEqual(got, expected, places=9)
        self.assertEqual(source, "providerReported")
        self.assertEqual(priced(table, million("unknown-model", "fast", cost=29.4)),
                         (29.4, "providerReported", None, 0.0, 0.0))
        # Запись без токенов: цену провайдера не на что раскладывать, она остаётся целой.
        self.assertEqual(priced(table, row("claude-opus-5-5", output=0, uncached=0, cached=0, written=0, cost=0.5)),
                         (0.5, "providerReported", None, 0.0, 0.0))

    def test_тарифы_priority_и_ultrafast_openai(self):
        table = usage.parse_rate_table({
            "gpt-6-astra": rate(1e-5, 1e-6, input_cost_per_token_priority=2e-5, output_cost_per_token_priority=1e-4,
                                cache_read_input_token_cost_priority=2e-6, input_cost_per_token_ultrafast=6e-5,
                                output_cost_per_token_ultrafast=3e-4),
            "gpt-6-sol": rate(1e-5, 1e-6)})
        for speed, expected in (("standard", 71), ("fast", 142), ("ultrafast", 426)):
            self.assertAlmostEqual(priced(table, million("gpt-6-astra", speed))[0], expected, places=9)
        self.assertAlmostEqual(priced(table, million("gpt-6-astra", "ultrafast"))[4], 54, places=9)
        self.assertAlmostEqual(priced(table, million("gpt-6-sol", "ultrafast"))[0], 71, places=9)
        self.assertEqual(priced(table, million("gpt-6-sol", "ultrafast"))[3], 0)

    def test_длинный_контекст_оценивает_весь_запрос_по_своему_тарифу(self):
        table = usage.parse_rate_table({"claude-haiku-5-5": {
            "input_cost_per_token": 1e-6, "output_cost_per_token": 5e-6, "cache_read_input_token_cost": 1e-7,
            "cache_creation_input_token_cost": 1.25e-6, "input_cost_per_token_above_100k_tokens": 2e-6,
            "output_cost_per_token_above_100k_tokens": 7.5e-6, "cache_read_input_token_cost_above_100k_tokens": 2e-7,
            "cache_creation_input_token_cost_above_100k_tokens": 2.5e-6}})
        record = row("claude-haiku-5-5", output=1000, uncached=10000, cached=100000, written=10000)
        self.assertAlmostEqual(priced(table, record)[0], 0.0725, places=12)

    def test_порог_контекста_только_у_priority(self):
        table = usage.parse_rate_table({"gpt-6-sol": rate(
            2e-6, 2e-7, input_cost_per_token_priority=4e-6, output_cost_per_token_priority=2e-5,
            cache_read_input_token_cost_priority=4e-7, input_cost_per_token_above_272k_tokens_priority=8e-6,
            output_cost_per_token_above_272k_tokens_priority=3e-5,
            cache_read_input_token_cost_above_272k_tokens_priority=8e-7)})
        record = row("gpt-6-sol", output=1000, uncached=20000, cached=280000, written=0, speed="fast")
        self.assertAlmostEqual(priced(table, record)[0], 0.414, places=12)

    def test_порог_строгий_а_недостающие_поля_наследуются(self):
        table = usage.parse_rate_table({"gpt-6-sol": {
            "input_cost_per_token": 2e-6, "output_cost_per_token": 1e-5, "cache_read_input_token_cost": 2e-7,
            "input_cost_per_token_priority": 4e-6, "output_cost_per_token_priority": 2e-5,
            "input_cost_per_token_above_272k_tokens": 4e-6}})

        def cost(uncached, speed="standard"):
            return priced(table, row("gpt-6-sol", output=1000, uncached=uncached, cached=200000, written=0, speed=speed))[0]

        self.assertAlmostEqual(cost(72000), 0.194, places=12)
        self.assertAlmostEqual(cost(72001), 0.378004, places=12)
        self.assertAlmostEqual(cost(72001, "fast"), 0.388004, places=12)

    def test_запись_в_кэш_на_час_дороже_пятиминутной(self):
        table = usage.parse_rate_table({"claude-opus-4-5-20251101": {
            "input_cost_per_token": 5e-6, "output_cost_per_token": 25e-6, "cache_read_input_token_cost": 5e-7,
            "cache_creation_input_token_cost": 6.25e-6, "cache_creation_input_token_cost_above_1hr": 1e-5}})
        record = row("claude-opus-4-5-20251101", output=0, uncached=0, cached=0, written=M, one_hour=600000)
        self.assertAlmostEqual(priced(table, record)[0], 8.5, places=9)
        # Часовая часть не может превышать всю запись в кэш.
        self.assertAlmostEqual(priced(table, row("claude-opus-4-5-20251101", output=0, uncached=0, cached=0,
                                                 written=100, one_hour=600000))[0], 100 * 1e-5, places=12)

    def test_корзина_обычный_и_быстрый_запрос(self):
        records = [row(), row(speed="fast")]
        buckets, _s, _l = ledger_buckets([("claude", records)], day_window("2026-08-07"),
                                         table=usage.parse_rate_table(FABLE))
        (bucket,) = buckets
        # Числа спецификации 08: литералы теста T3 (0.016875 / 0.01125 / 0.005625) проходят
        # только из-за допуска в два знака и отвечают 2000 токенов чтения, а не 1000.
        self.assertAlmostEqual(bucket["costUsd"], 0.013875, places=12)
        self.assertEqual(bucket["categoryCostUsd"], {"input": 0.003, "cacheRead": 0.003, "cacheWrite": 0.000375,
                                                     "output": 0.0075})
        self.assertEqual((bucket["fastCostUsd"], bucket["speedPremiumUsd"]), (0.00925, 0.004625))
        self.assertNotIn("ultrafastCostUsd", bucket)
        self.assertEqual((bucket["costSource"], bucket["records"], bucket["unpricedRecords"], bucket["unpricedTokens"],
                          bucket["sessions"]), ("modelPriced", 2, 0, 0, 1))
        self.assertAlmostEqual(bucket["cacheSavingsUsd"], 1000 * 9e-6 + 1000 * 18e-6, places=12)

    def test_map_to_складывает_модель_в_цель(self):
        records = [row(), row("example-preview")]
        buckets, _s, _l = ledger_buckets([("claude", records)], day_window("2026-08-07"),
                                         table=usage.parse_rate_table(FABLE), aliases={"example-preview": "claude-fable-5"})
        (bucket,) = buckets
        self.assertEqual((bucket["model"], bucket["records"], bucket["unpricedRecords"]), ("claude-fable-5", 2, 0))
        self.assertAlmostEqual(bucket["costUsd"], 0.00925, places=9)

    def test_своя_цена_после_map_to_ищется_по_цели(self):
        overrides = usage.parse_price_overrides({
            "target": {"inputCostPerMillionTokens": 1, "outputCostPerMillionTokens": 1},
            "source": {"inputCostPerMillionTokens": 9, "outputCostPerMillionTokens": 9}})
        buckets, _s, _l = ledger_buckets([("claude", [row("source", output=M, uncached=0, cached=0, written=0)])],
                                         day_window("2026-08-07"), overrides=overrides, aliases={"source": "target"})
        self.assertEqual((buckets[0]["model"], buckets[0]["costUsd"]), ("target", 1.0))

    def test_неизвестная_модель_без_цены_но_с_токенами(self):
        buckets, _s, _l = ledger_buckets([("claude", [row("kimi-k3")])], day_window("2026-08-07"),
                                         table=usage.parse_rate_table(FABLE))
        (bucket,) = buckets
        self.assertEqual((bucket["costUsd"], bucket["costSource"], bucket["unpricedRecords"], bucket["unpricedTokens"],
                          bucket["totals"]["outputTokens"]), (0, "unpriced", 1, 1160, 50))
        self.assertNotIn("categoryCostUsd", bucket)

    def test_цена_провайдера_главнее_таблицы(self):
        buckets, _s, _l = ledger_buckets([("claude", [row(cost=1.25)])], day_window("2026-08-07"),
                                         table=usage.parse_rate_table(FABLE))
        self.assertEqual((buckets[0]["costUsd"], buckets[0]["costSource"]), (1.25, "providerReported"))

    def test_смешанная_модель_считает_токены_без_цены(self):
        records = [row("mixed", output=40, uncached=60, cached=0, written=0, cost=1),
                   row("mixed", output=900, uncached=9000, cached=0, written=0)]
        buckets, _s, _l = ledger_buckets([("claude", records)], day_window("2026-08-07"))
        (bucket,) = buckets
        self.assertEqual((bucket["costUsd"], bucket["unpricedTokens"], bucket["unpricedRecords"], bucket["costSource"]),
                         (1, 9900, 1, "modelPriced"))

    def test_map_to_и_сессии_по_моделям(self):
        table = usage.parse_rate_table({
            "orbit-1": {"input_cost_per_token": 1e-6, "output_cost_per_token": 1e-5},
            "orbit-2": {"input_cost_per_token": 2e-6, "output_cost_per_token": 2e-5}})
        records = [row(model, output, session=session, uncached=10, cached=0, written=0, key=key)
                   for key, output, model, session in (("msg_1", 3, "orbit-1", "mixed"), ("msg_2", 5, "orbit-2", "mixed"),
                                                       ("msg_3", 7, "drift-9", "mixed"),
                                                       ("msg_4", 11, "drift-9", "excluded-only"))]
        buckets, sessions, _l = ledger_buckets([("claude", records)], day_window("2026-08-07"), table=table,
                                               aliases={"drift-9": "orbit-1"})
        first, second = buckets
        self.assertEqual((first["model"], first["totals"]["outputTokens"], first["records"], first["sessions"]),
                         ("orbit-1", 21, 3, 2))
        self.assertAlmostEqual(first["costUsd"], 0.00024, places=12)
        self.assertEqual((second["model"], second["records"], second["sessions"]), ("orbit-2", 1, 1))
        self.assertAlmostEqual(second["costUsd"], 0.00012, places=12)
        self.assertEqual(len(sessions["claude"]), 2)

    def test_поиск_в_таблице_точный(self):
        table = usage.parse_rate_table({"claude-fable-5-1": rate(1e-6), "Vendor/Model-X": rate(2e-6),
                                        "opus": rate(1e-6), "not-a-model": "текст", "no-output": {"input_cost_per_token": 1},
                                        "  ": rate(1e-6), "string-rate": {"input_cost_per_token": "1e-6",
                                                                         "output_cost_per_token": 1e-6}})
        self.assertIsNotNone(usage.lookup_rate(table, " Claude-Fable-5-1[1m] "))
        self.assertIsNone(usage.lookup_rate(table, "anthropic/Claude-Fable-5-1[1m]"))
        self.assertIsNone(usage.lookup_rate(table, "claude-fable-5-1-20261101"))
        self.assertIsNotNone(usage.lookup_rate(table, "vendor/model-x"))
        self.assertIsNotNone(usage.lookup_rate(table, "model-x"))
        for model in ("opus", "anthropic/opus", "<synthetic>", "", "vendor/", "no-output", "string-rate", "not-a-model"):
            self.assertIsNone(usage.lookup_rate(table, model), model)
        self.assertTrue(usage.is_unlisted_model(table, "claude-new-9"))
        for model in ("claude-fable-5-1[1m]", "opus", "<synthetic>", ""):
            self.assertFalse(usage.is_unlisted_model(table, model), model)

    def test_голое_имя_только_когда_оно_однозначно(self):
        def bare(document, name="example-model"):
            for ordered in (document, dict(reversed(list(document.items())))):
                found = usage.lookup_rate(usage.parse_rate_table(ordered), name)
                yield None if found is None else found[0][0]

        self.assertEqual(set(bare({"provider-a/example-model": rate(1e-6), "provider-b/example-model": rate(1e-6)})), {1e-6})
        document = {"provider-a/example-model": rate(1e-6), "provider-b/example-model": rate(3e-6)}
        self.assertEqual(set(bare(document)), {None})
        self.assertIsNotNone(usage.lookup_rate(usage.parse_rate_table(document), "provider-b/example-model"))
        self.assertEqual(set(bare({"kyma/gemini-4-argon": rate(5.4e-6), "gemini/gemini-4-argon": rate(2e-6)},
                                  "gemini-4-argon")), {2e-6})
        self.assertEqual(set(bare({"openai/example-model": rate(1e-6), "xai/example-model": rate(3e-6)})), {None})
        self.assertEqual(set(bare({"example-model": rate(7e-6), "openai/example-model": rate(1e-6)})), {7e-6})
        bedrock = {"anthropic.claude-mythos-5-2": rate(8e-6, 2e-7, cache_creation_input_token_cost=1e-5),
                   "us.anthropic.claude-mythos-5-2": rate(8.8e-6), "us-gov.anthropic.claude-mythos-5-2": rate(9.6e-6)}
        self.assertEqual(usage.lookup_rate(usage.parse_rate_table(bedrock), "claude-mythos-5-2")[0],
                         (8e-6, 5 * 8e-6, 2e-7, 1e-5, 1e-5))
        # Перепродавец без быстрых тарифов не спорит с тем, у кого они есть.
        merged = usage.lookup_rate(usage.parse_rate_table({
            "provider-a/example-model": rate(1e-6), "provider-b/example-model": rate(
                1e-6, input_cost_per_token_priority=2e-6, output_cost_per_token_priority=1e-5)}), "example-model")
        self.assertEqual(merged[1][0], 2e-6)

    def test_цена_из_таблицы_вне_разумных_границ_считается_отсутствующей(self):
        # Таблица — чужой файл из сети. 1e308 за токен дало бы бесконечную стоимость и сорвало весь
        # просмотр, отрицательная цена — отрицательный расход. Годна цена от 0 до 100 долларов за токен.
        good = {"input_cost_per_token": 1e-6, "output_cost_per_token": 5e-6}
        table = usage.parse_rate_table({
            "huge-input": dict(good, input_cost_per_token=1e308),
            "huge-output": dict(good, output_cost_per_token=1e308),
            "negative-input": dict(good, input_cost_per_token=-1e-6),
            "negative-output": dict(good, output_cost_per_token=-5e-6),
            "above-the-ceiling": dict(good, output_cost_per_token=100.0000001),
            "edges": {"input_cost_per_token": 0, "output_cost_per_token": 100},
            "bad-cache": dict(good, cache_read_input_token_cost=1e308, cache_creation_input_token_cost=-1,
                              cache_creation_input_token_cost_above_1hr=200),
            "bad-variants": dict(good, input_cost_per_token_priority=1e308, output_cost_per_token_priority=1e-5,
                                 input_cost_per_token_ultrafast=1e-5, output_cost_per_token_ultrafast=-1,
                                 input_cost_per_token_above_200k_tokens=1e308,
                                 output_cost_per_token_above_200k_tokens=-1),
            # Вариант без своей кэш-цены держит отношение стандартного тарифа; почти нулевой вход
            # делает это отношение бесконечным.
            "tiny-input": {"input_cost_per_token": 5e-324, "output_cost_per_token": 5e-6,
                           "cache_read_input_token_cost": 1, "input_cost_per_token_priority": 0.5,
                           "output_cost_per_token_priority": 0.5}})
        self.assertEqual(sorted(table), ["bad-cache", "bad-variants", "edges", "tiny-input"])
        self.assertEqual(table["edges"][0], (0, 100, 0, 0, 0))
        # Негодная кэш-цена — как пропущенная: чтение и запись идут по цене входа.
        self.assertEqual(table["bad-cache"][0], (1e-6, 5e-6, 1e-6, 1e-6, 1e-6))
        standard = (1e-6, 5e-6, 1e-6, 1e-6, 1e-6)
        self.assertEqual(table["bad-variants"], (standard, None, None, [(200000, (standard, None, None))]))
        self.assertEqual(table["tiny-input"][1], (0.5, 0.5, 0.5, 0.5, 0.5))
        for model in table:
            cost, _source, _parts, premium, savings = priced(table, million(model, "fast"))
            for value in (cost, premium, savings):
                self.assertTrue(0 <= abs(value) < 1e9, (model, value))
            self.assertGreaterEqual(cost, 0, model)

    def test_множитель_быстрого_режима_вне_границ_не_применяется(self):
        for multiple, applied in ((100, True), (0.5, True), (100.5, False), (1e308, False), (0, False), (-2, False)):
            table = usage.parse_rate_table({"claude-opus-5-5": rate(4e-6, provider_specific_entry={"fast": multiple})})
            fast = table["claude-opus-5-5"][1]
            self.assertEqual(fast and fast[0], 4e-6 * multiple if applied else None, multiple)

    def test_округление_половины_вверх_до_микродоллара(self):
        self.assertEqual(usage._round_usd(0.0000005), 0.000001)
        self.assertEqual(usage._round_usd(0.0000015), 0.000002)
        self.assertEqual(usage._round_usd(0.00000049), 0.0)
        buckets, _s, _l = ledger_buckets([("claude", [row(output=0, uncached=0, cached=0, written=0, speed="fast")])],
                                         day_window("2026-08-07"), table=usage.parse_rate_table(FABLE))
        self.assertNotIn("fastCostUsd", buckets[0])
        self.assertNotIn("speedPremiumUsd", buckets[0])


class PriceSettings(unittest.TestCase):
    def test_негодные_цены_пропускаются_поодиночке(self):
        good = {"inputCostPerMillionTokens": 2, "outputCostPerMillionTokens": 8, "cacheReadCostPerMillionTokens": 0}
        overrides = usage.parse_price_overrides({
            " glm-5.3 ": good, " ": good, "no-output": {"inputCostPerMillionTokens": 2},
            "negative": dict(good, inputCostPerMillionTokens=-1), "text": dict(good, outputCostPerMillionTokens="8"),
            "bool": dict(good, inputCostPerMillionTokens=True), "nan": dict(good, cacheWriteCostPerMillionTokens=float("nan")),
            "null-cache": dict(good, cacheReadCostPerMillionTokens=None), "list": [2, 8],
            "huge": dict(good, cacheWriteCostPerMillionTokens=100_000_000.000001),
            "overflow": dict(good, inputCostPerMillionTokens=10 ** 400)})
        self.assertEqual(list(overrides), ["glm-5.3"])
        self.assertEqual(overrides["glm-5.3"], ((2e-6, 8e-6, 0.0, 2e-6, 2e-6), None, None, []))
        for broken in (None, [], "текст", 5):
            self.assertEqual(usage.parse_price_overrides(broken), {})

    def test_потолок_своей_цены_тот_же_что_у_таблицы(self):
        # Своя цена — за миллион токенов, потолок таблицы — MAX_TOKEN_RATE долларов за токен.
        ceiling = usage.MAX_TOKEN_RATE * 1e6
        overrides = usage.parse_price_overrides({"example-model": {"inputCostPerMillionTokens": ceiling,
                                                                   "outputCostPerMillionTokens": ceiling}})
        self.assertEqual(overrides["example-model"][0][:2], (usage.MAX_TOKEN_RATE, usage.MAX_TOKEN_RATE))

    def test_цепочки_сводятся_а_циклы_отбрасываются(self):
        resolved = usage.parse_aliases({
            "preview[1m]": "preview", "preview": "example-model", "shared": "preview", "intoLoop": "loop",
            "loop": "back", "back": "loop", "laterIntoLoop": "back", "deepIntoLoop": "intoLoop", "self": "self",
            "validAfterLoops": "shared"})
        self.assertEqual(resolved, {"preview[1m]": "example-model", "preview": "example-model",
                                    "shared": "example-model", "validAfterLoops": "example-model"})

    def test_имена_обрезаются_а_мусор_пропускается(self):
        self.assertEqual(usage.parse_aliases({" a ": " b ", "c": "", " ": "d", "e": 5, "constructor": "toString"}),
                         {"a": "b", "constructor": "toString"})
        for broken in (None, [], "текст"):
            self.assertEqual(usage.parse_aliases(broken), {})


if __name__ == "__main__":
    unittest.main()
