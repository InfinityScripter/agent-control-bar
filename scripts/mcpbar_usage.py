#!/usr/bin/env python3
"""Usage-половина mcpbar.py: история расхода токенов Claude Code и Codex, цены и сводка.

Отдельный модуль, а не отдельный скрипт: команда приходит через `mcpbar.py usage [--refresh]`,
запись файлов берётся из mcpbar. `ROOT` читается как `core.ROOT` в момент вызова: тесты
подменяют корень на модуле mcpbar.

Что делает команда: обходит транскрипты, разбирает только изменившиеся файлы (кэш в
`usage/scan-cache.sqlite3` хранит разобранные записи, поэтому расход переживает удаление
транскрипта), один раз сводит копии одного запроса, оценивает по таблице LiteLLM и пишет
`usage/summary.json` с четырьмя периодами. Алгоритмы разбора, слияния копий и цен перенесены
из T3 Code (MIT, коммит 803f21f): claudeUsage.ts, codexUsage.ts, usageTranscriptReader.ts,
usageAggregation.ts, usagePricing.ts, UsageService.ts.

Осознанные отличия от T3:
- Копии сводятся один раз по самому широкому набору файлов (90 дней), а не отдельно для
  каждого периода: четыре периода из одной команды иначе стоили бы четыре прохода по всем
  записям. Итог расходится с T3 только когда копии одного запроса несут разное время и лежат
  в файлах по разные стороны mtime-порога узкого периода.
- Записи сворачиваются в минутные ячейки: границы и суток, и скользящих часов кратны минуте.
- Элементы каталога сортируются по имени на каждом уровне: порядок readdir не определён.
- Строка Claude разбирается, только если в её байтах есть и "usage", и "assistant" (у T3 — только
  "usage"): запись всё равно даёт лишь строка с type "assistant", а JSON разбирается вдвое реже.
- Тариф ранних запросов Codex (unresolvedServiceTierTurnId) T3 чинит по своей базе; здесь
  её нет, скорость остаётся такой, как прочитана.
"""

import collections
import concurrent.futures
import copy
import fcntl
import json
import math
import multiprocessing
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import mcpbar as core


PERIODS = (1, 7, 30, 90)
SUMMARY_VERSION = 1
RETENTION_DAYS = 92

MINUTE_MS = 60 * 1000
HOUR_MS = 60 * MINUTE_MS
DAY_MS = 24 * HOUR_MS
# Запас по mtime: запись перед самой местной полуночью первого дня окна лежит в файле,
# который правили ещё «вчера» по UTC.
MTIME_SLACK_MS = 36 * HOUR_MS

LITELLM_RATES_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
LITELLM_RATES_API_URL = ("https://api.github.com/repos/BerriAI/litellm/contents/"
                         "model_prices_and_context_window.json?ref=main")
RATES_TTL_MS = 24 * HOUR_MS
RATES_REFRESH_FLOOR_MS = 60 * 1000
RATES_TIMEOUT = 10
RATES_DEADLINE = 30
RATES_MAX_BYTES = 64 * 1024 * 1024

ZSTD_PATHS = ("/opt/homebrew/bin/zstd", "/usr/local/bin/zstd")
NODE_PATHS = ("/opt/homebrew/bin/node", "/usr/local/bin/node")
NODE_ZSTD_PROBE = "process.exit(typeof require('node:zlib').createZstdDecompress==='function'?0:1)"
NODE_ZSTD_STREAM = ("require('node:stream').pipeline(require('node:fs').createReadStream(process.argv.at(-1)),"
                    "require('node:zlib').createZstdDecompress(),process.stdout,"
                    "(error)=>{process.exitCode=error?1:0})")

CACHE_VERSION = 1
BROKEN_ROWS_LIMIT = 16
READ_CHUNK = 4 * 1024 * 1024
GUARD_LENGTH = 64
# Меньше этого объёма разбор в одном процессе быстрее, чем запуск рабочих.
POOL_MIN_BYTES = 256 * 1024 * 1024
# Сжатый rollout раскрывается примерно на порядок; вес нужен только для решения о пуле.
ZSTD_WEIGHT = 8
WORKERS = 8
STATUS_INTERVAL = 2.0


class UsageFailure(Exception):
    """Сбой с готовой категорией для status.json: наружу идёт слово, не текст ошибки."""


def usage_path(name):
    return os.path.join(core.ROOT, "usage", name)


def now_ms():
    return int(time.time() * 1000)


# ──────────────────────────────────────────────────────────── запись расхода

# Одна запись — один оплаченный запрос к модели. Плоский список, а не словарь: записей сотни
# тысяч, они целиком лежат в кэше и в памяти, и именно этот вид без преобразований уходит в JSON.
TS, MODEL, SESSION, UNCACHED, CACHED, CACHE_WRITE, OUTPUT, REASONING, KEY, COST, SPEED, CACHE_WRITE_1H = range(12)
TOKEN_CHANNELS = (UNCACHED, CACHED, CACHE_WRITE, OUTPUT, REASONING, CACHE_WRITE_1H)

_TIMESTAMP = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?(Z|[+-]\d{2}:?\d{2})?$")


def parse_timestamp_ms(value):
    """ISO-время в миллисекунды эпохи; None для всего, что не строка со временем.

    datetime.fromisoformat в 3.9 не понимает «Z» и дроби произвольной длины. Время без пояса
    читается как UTC (JS прочёл бы его как местное); настоящие транскрипты всегда пишут «Z».
    """
    if not isinstance(value, str):
        return None
    match = _TIMESTAMP.match(value.strip())
    if not match:
        return None
    year, month, day, hour, minute = (int(match.group(i)) for i in range(1, 6))
    second = int(match.group(6) or 0)
    millis = int((match.group(7) or "0")[:3].ljust(3, "0"))
    offset = match.group(8)
    try:
        if offset is None or offset == "Z":
            zone = timezone.utc
        else:
            digits = offset[1:].replace(":", "")
            delta = timedelta(hours=int(digits[:2]), minutes=int(digits[2:]))
            zone = timezone(delta if offset[0] == "+" else -delta)
        moment = datetime(year, month, day, hour, minute, second, tzinfo=zone)
    except ValueError:
        return None
    return int(moment.timestamp()) * 1000 + millis


def token_count(value):
    """Мягкий счётчик Claude: всё, что не положительное конечное число, — ноль."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0
    if isinstance(value, float) and not math.isfinite(value):
        return 0
    return int(value) if value > 0 else 0


def merge_usage_copies(held, other):
    """Копии одного запроса: максимум по каждому каналу и по цене, остальное — от первой.

    Claude Code пишет начало ответа и его конец под одним ключом, и только последняя копия
    несёт полный расход. Время, модель, сессия и скорость первой копии держат запрос в его ячейке.
    """
    held_cost, other_cost = held[COST], other[COST]
    if held_cost is None or other_cost is None:
        cost = held_cost if held_cost is not None else other_cost
    else:
        cost = max(held_cost, other_cost)
    if cost == held_cost and all(other[i] <= held[i] for i in TOKEN_CHANNELS):
        return held
    merged = list(held)
    for i in TOKEN_CHANNELS:
        if other[i] > merged[i]:
            merged[i] = other[i]
    merged[COST] = cost
    return merged


def dedupe_within_file(records):
    """Поздние копии ключа вливаются в место первой; записи без ключа остаются все."""
    kept, first = [], {}
    for record in records:
        key = record[KEY]
        if key is not None:
            index = first.get(key)
            if index is not None:
                kept[index] = merge_usage_copies(kept[index], record)
                continue
            first[key] = len(kept)
        kept.append(record)
    return kept


# ──────────────────────────────────────────────────────────── Claude Code

CLAUDE_SYNTHETIC_MODEL = "<synthetic>"


def _claude_row(timestamp, model, session, usage, cost, speed, key):
    split = usage.get("cache_creation")
    one_hour = token_count(split.get("ephemeral_1h_input_tokens")) if isinstance(split, dict) else 0
    return [timestamp, model, session,
            token_count(usage.get("input_tokens")),
            token_count(usage.get("cache_read_input_tokens")),
            token_count(usage.get("cache_creation_input_tokens")),
            token_count(usage.get("output_tokens")),
            0,  # размышления Anthropic уже считает внутри output
            key, cost, speed, one_hour]


def parse_claude_record(record, _state=None):
    """Строка транскрипта Claude Code → записи: сам ответ и по одной на консультацию advisor."""
    if not isinstance(record, dict) or record.get("type") != "assistant":
        return []
    message = record.get("message")
    if not isinstance(message, dict):
        return []
    usage = message.get("usage")
    if not isinstance(usage, dict):
        return []
    timestamp = parse_timestamp_ms(record.get("timestamp"))
    if timestamp is None:
        return []
    model = message.get("model")
    # «<synthetic>» — местная заглушка Claude Code, до API такой ответ не доходил.
    if not isinstance(model, str) or not model or model == CLAUDE_SYNTHETIC_MODEL:
        return []
    message_id = message.get("id") if isinstance(message.get("id"), str) else None
    request_id = record.get("requestId") if isinstance(record.get("requestId"), str) else None
    key = None if message_id is None and request_id is None else "%s:%s" % (message_id or "", request_id or "")
    cost = record.get("costUSD")
    if isinstance(cost, bool) or not isinstance(cost, (int, float)) or not math.isfinite(cost):
        cost = None
    session = record.get("sessionId") if isinstance(record.get("sessionId"), str) else ""
    speed = "fast" if usage.get("speed") == "fast" else "standard"
    rows = [_claude_row(timestamp, model, session, usage, cost, speed, key)]
    iterations = usage.get("iterations")
    for index, iteration in enumerate(iterations if isinstance(iterations, list) else ()):
        if not isinstance(iteration, dict) or iteration.get("type") != "advisor_message":
            continue
        advisor = iteration.get("model")
        if not isinstance(advisor, str) or not advisor or advisor == CLAUDE_SYNTHETIC_MODEL:
            continue
        rows.append(_claude_row(timestamp, advisor, session, iteration, None, speed,
                                None if key is None else "%s:advisor:%d" % (key, index)))
    return rows


# ──────────────────────────────────────────────────────────── Codex

# Порядок счётчиков в кортеже расхода Codex.
INPUT_T, CACHED_T, WRITE_T, OUTPUT_T, REASONING_T, TOTAL_T = range(6)
FORK_COPY_MAX_GAP_MS = 1000
_MISSING = object()


def _counter(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value >= 0 else None
    if isinstance(value, float) and math.isfinite(value) and value.is_integer() and value >= 0:
        return int(value)
    return None


def read_codex_usage(value):
    """Строгий разбор расхода Codex: кортеж из шести счётчиков или None для несогласованного."""
    if not isinstance(value, dict):
        return None
    given, produced = value.get("input_tokens"), value.get("output_tokens")
    if isinstance(given, bool) or isinstance(produced, bool) \
            or not isinstance(given, (int, float)) or not isinstance(produced, (int, float)):
        return None
    raw = [given, value.get("cached_input_tokens", 0), value.get("cache_write_input_tokens", 0),
           produced, value.get("reasoning_output_tokens", 0), value.get("total_tokens", _MISSING)]
    if raw[TOTAL_T] is _MISSING:
        raw[TOTAL_T] = given + produced
    return _valid_usage([_counter(item) for item in raw])


def _valid_usage(counters):
    if len(counters) != 6 or any(item is None for item in counters):
        return None
    if counters[CACHED_T] + counters[WRITE_T] > counters[INPUT_T] \
            or counters[REASONING_T] > counters[OUTPUT_T] \
            or counters[TOTAL_T] < counters[INPUT_T] + counters[OUTPUT_T]:
        return None
    return tuple(counters)


def _usage_minus(left, right):
    return _valid_usage([_counter(a - b) for a, b in zip(left, right)])


def _usage_plus(base, added):
    return tuple(a + b for a, b in zip(base or (0,) * 6, added))


def _signature(usage):
    return json.dumps(list(usage))


def initial_codex_state():
    # Необязательные ключи: latestCumulativeAtMs, sequenceStartSignature, unreportedRequests,
    # requestLedgerActive.
    return {"model": "", "speed": "standard", "sessionId": "", "lastUsageSignature": None,
            "lastCumulativeUsage": None, "malformedRecords": 0, "sawSessionMeta": False,
            "suppressingForkCopies": False, "forkCopyAnchorMs": 0}


def restore_codex_state(saved):
    """Сохранённое состояние → живое. None значит «возобновлять нельзя, читать файл целиком».

    После JSON счётчики возвращаются списками, а редуктор сравнивает их через ==, поэтому
    им снова нужно стать кортежами.
    """
    try:
        if not isinstance(saved, dict):
            return None
        state = copy.deepcopy(saved)
        for name, kind in (("model", str), ("speed", str), ("sessionId", str), ("sawSessionMeta", bool),
                           ("suppressingForkCopies", bool), ("malformedRecords", int),
                           ("forkCopyAnchorMs", int)):
            if not isinstance(state.get(name), kind):
                return None
        if state["speed"] not in ("standard", "fast", "ultrafast"):
            return None
        if state.get("lastCumulativeUsage") is not None:
            state["lastCumulativeUsage"] = _valid_usage([_counter(item) for item in state["lastCumulativeUsage"]])
            if state["lastCumulativeUsage"] is None:
                return None
        for request in state.get("unreportedRequests") or ():
            request["usage"] = _valid_usage([_counter(item) for item in request["usage"]])
            if request["usage"] is None or not isinstance(request["model"], str) \
                    or not isinstance(request["speed"], str) or not isinstance(request["timestampMs"], int):
                return None
        return state
    except (TypeError, KeyError, AttributeError):
        return None


def _date_baseline(state, timestamp):
    latest = state.get("latestCumulativeAtMs")
    state["latestCumulativeAtMs"] = timestamp if latest is None else max(latest, timestamp)


def _rebase(state, cumulative, timestamp):
    state["lastCumulativeUsage"] = cumulative
    _date_baseline(state, timestamp)
    state.pop("unreportedRequests", None)
    if cumulative[INPUT_T] + cumulative[OUTPUT_T] == 0:
        state.pop("sequenceStartSignature", None)


def _is_forked_meta(payload):
    if isinstance(payload.get("forked_from_id"), str):
        return True
    current = payload
    for name in ("source", "subagent", "thread_spawn"):
        current = current.get(name)
        if not isinstance(current, dict):
            return False
    return isinstance(current.get("parent_thread_id"), str)


def _is_fork_copy(state, timestamp):
    """Форк переписывает историю родителя пачкой с промежутками в миллисекунды; свой расход
    ребёнка идёт после настоящего хода модели. Первая строка за пачкой снимает подавление."""
    if not state["suppressingForkCopies"]:
        return False
    if timestamp - state["forkCopyAnchorMs"] < FORK_COPY_MAX_GAP_MS:
        state["forkCopyAnchorMs"] = timestamp
        return True
    state["suppressingForkCopies"] = False
    state["lastUsageSignature"] = None
    return False


def codex_speed(tier):
    if tier in ("priority", "fast"):
        return "fast"
    return "ultrafast" if tier == "ultrafast" else "standard"


def _attribution(state, timestamp):
    return {"timestampMs": timestamp, "model": state["model"], "speed": state["speed"]}


def _codex_row(state, usage, attribution, key=None):
    # input_tokens у Codex включает и прочитанное из кэша, и записанное в него.
    return [attribution["timestampMs"], attribution["model"], state["sessionId"],
            usage[INPUT_T] - usage[CACHED_T] - usage[WRITE_T], usage[CACHED_T], usage[WRITE_T],
            usage[OUTPUT_T], usage[REASONING_T], key, None, attribution["speed"], 0]


def _bridged_requests(previous, cumulative, last, pending):
    """Анонимные запросы прерванного хода, которые снимок итога подтверждает суммой."""
    if previous is None or not pending:
        return None
    for index in range(6):
        if cumulative[index] - previous[index] != sum(request["usage"][index] for request in pending):
            return None
    remainder = _usage_minus(pending[-1]["usage"], last)
    if remainder is None:
        return None
    bridged = pending[:-1] + [dict(pending[-1], usage=remainder)]
    return [request for request in bridged if request["usage"][INPUT_T] + request["usage"][OUTPUT_T] > 0]


def _discarded_requests(pending, last):
    if not pending:
        return 0
    return len(pending) - (1 if pending[-1]["usage"] == last else 0)


def _codex_ledger_record(payload, state, timestamp):
    """token_usage_record: названный запрос оплачивается сразу, безымянный ждёт подтверждения."""
    usage = read_codex_usage(payload.get("usage"))
    if timestamp is None or usage is None or not state["model"]:
        return []
    if _is_fork_copy(state, timestamp):
        return []
    response_id = payload.get("response_id")
    if not isinstance(response_id, str) or not response_id:
        state["requestLedgerActive"] = False
        state.setdefault("unreportedRequests", []).append(dict(_attribution(state, timestamp), usage=usage))
        return []
    pending = state.get("unreportedRequests") or []
    state["requestLedgerActive"] = True
    for request in pending:
        state["lastCumulativeUsage"] = _usage_plus(state["lastCumulativeUsage"], request["usage"])
    state["lastCumulativeUsage"] = _usage_plus(state["lastCumulativeUsage"], usage)
    _date_baseline(state, timestamp)
    state.pop("unreportedRequests", None)
    key = json.dumps(["codex", state["sessionId"], response_id], separators=(",", ":"), ensure_ascii=False)
    return [_codex_row(state, request["usage"], request) for request in pending] \
        + [_codex_row(state, usage, _attribution(state, timestamp), key)]


def _codex_token_count(info, state, timestamp):
    """token_count: счёт идёт по last_token_usage, итог нужен только для проверки и повторов."""
    if timestamp is None or not state["model"]:
        return []
    last = read_codex_usage(info.get("last_token_usage"))
    raw_cumulative = info.get("total_token_usage")
    has_cumulative = raw_cumulative is not None
    cumulative = read_codex_usage(raw_cumulative) if has_cumulative else None
    if _is_fork_copy(state, timestamp):
        signature = None if last is None else _signature(last)
        if cumulative is not None:
            _rebase(state, cumulative, timestamp)
        elif not has_cumulative and last is not None and signature != state["lastUsageSignature"]:
            state["lastCumulativeUsage"] = _usage_plus(state["lastCumulativeUsage"], last)
            _date_baseline(state, timestamp)
        state["lastUsageSignature"] = signature
        return []
    if state.get("requestLedgerActive"):
        # Снимки контекста откатываются при возобновлении; названные запросы надёжнее.
        if cumulative is not None:
            _rebase(state, cumulative, timestamp)
        return []
    previous = state["lastCumulativeUsage"]
    latest_at = state.get("latestCumulativeAtMs")
    pending = state.get("unreportedRequests")
    if cumulative is not None:
        _rebase(state, cumulative, timestamp)
    if last is None or (has_cumulative and cumulative is None):
        state["malformedRecords"] += 1
        return []
    if last[INPUT_T] + last[OUTPUT_T] == 0:
        # Отметка размера контекста (в том числе после сжатия), а не запрос.
        state["lastUsageSignature"] = None
        return []
    if cumulative is not None and cumulative == previous:
        return []
    if last[TOTAL_T] != last[INPUT_T] + last[OUTPUT_T]:
        state["malformedRecords"] += 1
        return []
    signature = _signature(last)
    bridged = []
    if cumulative is not None:
        restarted = cumulative == last
        sequence_start = json.dumps([timestamp, list(last)])
        if restarted and sequence_start == state.get("sequenceStartSignature"):
            state["lastCumulativeUsage"] = previous
            if latest_at is None:
                state.pop("latestCumulativeAtMs", None)
            return []
        lowered = previous is not None and any(cumulative[i] < previous[i] for i in range(6))
        rewound = lowered and latest_at is not None and timestamp > latest_at
        if previous is None or rewound:
            reconciled = _usage_minus(cumulative, last) is not None
        else:
            reconciled = all(cumulative[i] - previous[i] == last[i] for i in range(6))
        if not restarted and not reconciled:
            bridged = _bridged_requests(previous, cumulative, last, pending)
            if bridged is None:
                replayed = latest_at is not None and (
                    timestamp < latest_at
                    or (timestamp == latest_at and lowered and cumulative[INPUT_T] + cumulative[OUTPUT_T] > 0))
                if replayed:
                    state["lastCumulativeUsage"] = previous
                    if pending is not None:
                        state["unreportedRequests"] = pending
                state["malformedRecords"] += 1
                return []
        elif not restarted and rewound:
            state["malformedRecords"] += _discarded_requests(pending, last)
        if restarted:
            state["sequenceStartSignature"] = sequence_start
    else:
        if signature == state["lastUsageSignature"]:
            return []
        state["lastCumulativeUsage"] = _usage_plus(previous, last)
        _date_baseline(state, timestamp)
    state["lastUsageSignature"] = signature
    return [_codex_row(state, request["usage"], request) for request in bridged] \
        + [_codex_row(state, last, _attribution(state, timestamp))]


def parse_codex_record(record, state):
    """Строка rollout Codex → записи. Модель, тариф и сессию несут соседние строки, поэтому
    состояние файла идёт от строки к строке и сохраняется в точке возобновления."""
    if not isinstance(record, dict):
        return []
    payload = record.get("payload")
    if isinstance(payload, list):
        payload = {}  # в JS массив проходит проверку «объект» и просто не даёт полей
    if not isinstance(payload, dict):
        return []
    kind = record.get("type")
    if kind == "session_meta":
        # Только первая: форк копирует meta предков, и те приписали бы расход чужой сессии.
        if state["sawSessionMeta"]:
            return []
        state["sawSessionMeta"] = True
        session = payload.get("id")
        if session is None:
            session = payload.get("session_id")
        if isinstance(session, str):
            state["sessionId"] = session
        timestamp = parse_timestamp_ms(record.get("timestamp"))
        if timestamp is not None and _is_forked_meta(payload):
            state["suppressingForkCopies"] = True
            state["forkCopyAnchorMs"] = timestamp
        return []
    if kind == "turn_context":
        state["requestLedgerActive"] = False
        if isinstance(payload.get("model"), str):
            state["model"] = payload["model"]
        return []
    if kind == "token_usage_record":
        return _codex_ledger_record(payload, state, parse_timestamp_ms(record.get("timestamp")))
    if payload.get("type") == "thread_settings_applied":
        settings = payload.get("thread_settings")
        if isinstance(settings, dict):
            state["speed"] = codex_speed(settings.get("service_tier"))
        return []
    if payload.get("type") != "token_count" or not isinstance(payload.get("info"), dict):
        return []
    return _codex_token_count(payload["info"], state, parse_timestamp_ms(record.get("timestamp")))


# ──────────────────────────────────────────────────────────── чтение транскрипта

Format = collections.namedtuple("Format", "markers require parse initial restore")

# Строка разбирается как JSON, только если в её байтах есть маркер: подавляющая часть
# транскрипта — вывод инструментов и текст. `require` — та же идея для Claude: запись даёт
# только строка с "type":"assistant", а "usage" встречается и в чужих строках.
FORMATS = {
    "claude": Format((b'"usage"',), b'"assistant"', parse_claude_record, None, None),
    "codex": Format((b'"token_count"', b'"token_usage_record"', b'"turn_context"',
                     b'"thread_settings_applied"', b'"session_meta"'),
                    None, parse_codex_record, initial_codex_state, restore_codex_state),
}


def fnv1a(data):
    value = 0x811C9DC5
    for byte in data:
        value = ((value ^ byte) * 0x01000193) & 0xFFFFFFFF
    return value


def _reject_constant(name):
    raise ValueError(name)


def _parse_int(text):
    # JSON.parse читает любое число как double, и целое длиннее его диапазона — это Infinity:
    # нулевой счётчик Claude, отвергнутый расход Codex. Python вернул бы точное целое, на
    # котором позже падают math.isfinite и умножение на цену.
    return int(text) if len(text) < 300 else float(text)


# JSON.parse не принимает NaN и Infinity, json.loads принимает.
_DECODER = json.JSONDecoder(parse_constant=_reject_constant, parse_int=_parse_int)


def _parse_line(raw, fmt, state, out):
    if fmt.require is not None and fmt.require not in raw:
        return
    if raw.endswith(b"\r"):
        raw = raw[:-1]
    try:
        parsed = _DECODER.decode(raw.decode("utf-8", "replace"))
    except (ValueError, RecursionError):
        return
    out.extend(fmt.parse(parsed, state))


def _scan_region(data, end, fmt, state, out):
    """Разбирает строки с маркером в data[:end]; end стоит сразу за переводом строки.

    Строки не режутся по одной: поиск маркера идёт по всему куску на скорости memmem, а
    границы строки ищутся только вокруг находки.
    """
    markers = fmt.markers
    found = [data.find(marker, 0, end) for marker in markers]
    position = 0
    while True:
        hit = min((at for at in found if at >= 0), default=-1)
        if hit < 0:
            return
        newline = data.rfind(b"\n", position, hit)
        line_end = data.find(b"\n", hit, end)
        _parse_line(data[position if newline < 0 else newline + 1:line_end], fmt, state, out)
        position = line_end + 1
        for index, at in enumerate(found):
            if 0 <= at < position:
                found[index] = data.find(markers[index], position, end)


def _consume(read, fmt, state, out):
    """Читает поток до конца. → (байт до последнего перевода строки, незавершённый хвост)."""
    consumed, pending = 0, b""
    while True:
        chunk = read(READ_CHUNK)
        if not chunk:
            return consumed, pending
        newline = chunk.rfind(b"\n")
        data = pending + chunk if pending else chunk
        if newline < 0:
            pending = data
            continue
        end = len(data) - len(chunk) + newline + 1
        _scan_region(data, end, fmt, state, out)
        consumed += end
        pending = data[end:]


def _finish_read(fmt, state, records, pending, position, resumed):
    """Хвост без перевода строки разбирается на копии состояния: строка ещё может дорасти."""
    tail, tail_state = [], state
    if pending and any(marker in pending for marker in fmt.markers):
        tail_state = copy.deepcopy(state)
        _parse_line(pending, fmt, tail_state, tail)
    position["state"] = state
    return {"records": records, "tailRecords": tail, "position": position, "resumed": resumed,
            "malformedRecords": tail_state["malformedRecords"] if fmt.initial else 0}


def read_transcript(path, provider, resume_from=None, decompress=None):
    """Записи файла. None — файл не прочитан; это не «пусто», кэшировать такое нельзя."""
    fmt = FORMATS[provider]
    try:
        if path.endswith(".zst"):
            return _read_compressed(path, fmt, decompress)
        with open(path, "rb") as stream:
            return _read_plain(stream, fmt, resume_from)
    except (OSError, subprocess.SubprocessError):
        return None


def _read_plain(stream, fmt, resume_from):
    state = fmt.initial() if fmt.initial else None
    start, resumed = 0, False
    saved = fmt.restore(resume_from.get("state")) if fmt.initial and resume_from else None
    if resume_from and resume_from["resumeOffset"] > 0 and (fmt.initial is None or saved is not None):
        length = resume_from["guardLength"]
        if 0 < length <= GUARD_LENGTH and length <= resume_from["resumeOffset"]:
            stream.seek(resume_from["resumeOffset"] - length)
            window = stream.read(length)
            # Последние байты до точки возобновления те же — значит, файл только дорос.
            if len(window) == length and fnv1a(window) == resume_from["guardHash"]:
                start, resumed = resume_from["resumeOffset"], True
                state = saved if fmt.initial else None
    records = []
    stream.seek(start)
    consumed, pending = _consume(stream.read, fmt, state, records)
    offset = start + consumed
    length = min(GUARD_LENGTH, offset)
    stream.seek(offset - length)
    position = {"resumeOffset": offset, "guardLength": length, "guardHash": fnv1a(stream.read(length))}
    return _finish_read(fmt, state, records, pending, position, resumed)


def _read_compressed(path, fmt, decompress):
    """Сжатый rollout читается потоком из внешней программы и с начала: возобновить его нельзя."""
    if not decompress:
        return None
    state = fmt.initial() if fmt.initial else None
    records = []
    with subprocess.Popen(decompress + [path], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL) as process:
        try:
            _consumed, pending = _consume(process.stdout.read, fmt, state, records)
        except BaseException:
            process.kill()
            raise
    # Оборванный или битый архив — это непрочитанный файл, а не короткий.
    if process.returncode != 0:
        return None
    position = {"resumeOffset": 0, "guardLength": 0, "guardHash": 0}
    return _finish_read(fmt, state, records, pending, position, False)


def find_decompressor():
    """Начало командной строки, которая пишет распакованный файл в stdout, или None.

    В системном Python 3.9 zstd нет, библиотеки в macOS тоже. Сначала бинарник zstd, потом
    node, у которого node:zlib умеет zstd.
    """
    for path in ZSTD_PATHS + (shutil.which("zstd") or "",):
        if os.path.isabs(path) and os.access(path, os.X_OK):
            return [path, "-dcq", "--"]
    for path in (shutil.which("node") or "",) + NODE_PATHS:
        if not os.path.isabs(path) or not os.access(path, os.X_OK):
            continue
        try:
            probe = subprocess.run([path, "-e", NODE_ZSTD_PROBE], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        except (OSError, subprocess.SubprocessError):
            continue
        if probe.returncode == 0:
            return [path, "-e", NODE_ZSTD_STREAM]
    return None


def read_task(task):
    """Одна работа пула: файл → разобранный результат с уже слитыми внутри файла копиями."""
    path, provider, resume_from, decompress = task
    try:
        parsed = read_transcript(path, provider, resume_from, decompress)
        if parsed is not None:
            parsed["records"] = dedupe_within_file(parsed["records"])
        return parsed
    except Exception:
        # Один странный файл не должен ронять весь просмотр: он считается непрочитанным.
        return None


def run_read_tasks(tasks):
    """Выдаёт (номер, результат) по мере готовности: в процессе, а для большого объёма — в пуле."""
    weight = sum(size * (ZSTD_WEIGHT if task[0].endswith(".zst") else 1) for task, size in tasks)
    remaining = dict(enumerate(task for task, _size in tasks))
    if len(tasks) > 1 and weight >= POOL_MIN_BYTES:
        workers = min(WORKERS, os.cpu_count() or 1, len(tasks))
        # Большие файлы первыми: иначе последний рабочий доедает самый длинный в одиночку.
        order = sorted(remaining, key=lambda index: -tasks[index][1])
        # spawn, а не fork: рядом в потоке качаются цены, а fork из многопоточного процесса
        # (urllib на macOS ещё и трогает системные фреймворки) небезопасен.
        pool = concurrent.futures.ProcessPoolExecutor(workers, mp_context=multiprocessing.get_context("spawn"))
        try:
            futures = {pool.submit(read_task, remaining[index]): index for index in order}
            for future in concurrent.futures.as_completed(futures):
                index = futures[future]
                result = future.result()
                del remaining[index]
                yield index, result
        except (OSError, concurrent.futures.process.BrokenProcessPool):
            pass  # пул не поднялся или рабочий убит — остаток дочитывается здесь же
        finally:
            pool.shutdown(wait=True, cancel_futures=True)
    for index in sorted(remaining):
        yield index, read_task(remaining[index])


# ──────────────────────────────────────────────────────────── кэш разобранных файлов

Entry = collections.namedtuple(
    "Entry", "provider size mtime_ns malformed count resume_offset guard_length guard_hash sessions models")

_SCHEMA = (
    # Лёгкая таблица читается целиком на каждом запуске; записи лежат отдельно, чтобы запуск
    # без изменений не тащил их с диска ради сверки размеров и времени.
    "CREATE TABLE files (path TEXT PRIMARY KEY, provider TEXT NOT NULL, size INTEGER NOT NULL,"
    " mtime_ns INTEGER NOT NULL, malformed INTEGER NOT NULL, count INTEGER NOT NULL,"
    " resume_offset INTEGER NOT NULL, guard_length INTEGER NOT NULL, guard_hash INTEGER NOT NULL,"
    " sessions TEXT NOT NULL, models TEXT NOT NULL)",
    "CREATE TABLE records (path TEXT PRIMARY KEY, records TEXT NOT NULL, tail TEXT NOT NULL, state TEXT)",
)


class ScanCache:
    """Разобранные записи по файлам. Ключ свежести — путь, размер, mtime и провайдер."""

    def __init__(self, path):
        if not os.path.exists(path):
            os.close(os.open(path, os.O_WRONLY | os.O_CREAT, core.SECURE_FILE))
        self.db = sqlite3.connect(path, timeout=30)
        try:
            if self.db.execute("PRAGMA user_version").fetchone()[0] != CACHE_VERSION:
                for table in ("files", "records"):
                    self.db.execute("DROP TABLE IF EXISTS %s" % table)
                for statement in _SCHEMA:
                    self.db.execute(statement)
                self.db.execute("PRAGMA user_version = %d" % CACHE_VERSION)
                self.db.commit()
        except sqlite3.Error:
            # Испорченный файл открывается, а падает первый же запрос: вызывающему закрывать нечего,
            # и соединение держало бы файл, который он сейчас удалит.
            self.db.close()
            raise

    def index(self):
        return {row[0]: Entry(*row[1:9], _load(row[9], row[0]), _load(row[10], row[0]))
                for row in self.db.execute(
                    "SELECT path, provider, size, mtime_ns, malformed, count, resume_offset, guard_length,"
                    " guard_hash, sessions, models FROM files")}

    def position(self, path, entry):
        row = self.db.execute("SELECT state FROM records WHERE path = ?", (path,)).fetchone()
        return {"resumeOffset": entry.resume_offset, "guardLength": entry.guard_length,
                "guardHash": entry.guard_hash, "state": _load(row[0], path) if row and row[0] else None}

    def records(self, path):
        row = self.db.execute("SELECT records FROM records WHERE path = ?", (path,)).fetchone()
        return _load(row[0], path) if row else []

    def all_records(self):
        """path → (записи, хвост) строками JSON: разбирает их тот, кому они нужны по порядку."""
        return {path: (records, tail)
                for path, records, tail in self.db.execute("SELECT path, records, tail FROM records")}

    def put(self, path, provider, size, mtime_ns, records, parsed):
        tail, position = parsed["tailRecords"], parsed["position"]
        rows = records + tail
        entry = Entry(provider, size, mtime_ns, parsed["malformedRecords"], len(rows),
                      position["resumeOffset"], position["guardLength"], position["guardHash"],
                      sorted({row[SESSION] for row in rows if row[SESSION]}),
                      sorted({row[MODEL] for row in rows}))
        self.db.execute("INSERT OR REPLACE INTO files VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                        (path,) + entry[:8] + (_dump(entry.sessions), _dump(entry.models)))
        self.db.execute("INSERT OR REPLACE INTO records VALUES (?,?,?,?)",
                        (path, _dump(records), _dump(tail),
                         None if position["state"] is None else _dump(position["state"])))
        return entry

    def delete(self, paths):
        for table in ("files", "records"):
            self.db.executemany("DELETE FROM %s WHERE path = ?" % table, [(path,) for path in paths])

    def commit(self):
        self.db.commit()

    def close(self):
        self.db.close()


def _dump(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


class BrokenRow(sqlite3.DataError):
    """Строка кэша не разбирается как JSON. `path` — чей это файл."""

    def __init__(self, path):
        super().__init__("cache row is not JSON")
        self.path = path


def _load(text, path):
    try:
        return json.loads(text)
    except ValueError:
        raise BrokenRow(path) from None


# ──────────────────────────────────────────────────────────── обход и просмотр

def transcript_roots():
    """Каталоги транскриптов в порядке провайдеров: при равных ключах первой считается копия Claude."""
    claude = (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip() or os.path.join(core.HOME, ".claude")
    codex = (os.environ.get("CODEX_HOME") or "").strip() or os.path.join(core.HOME, ".codex")
    return [("claude", os.path.realpath(os.path.join(claude, "projects"))),
            ("codex", os.path.realpath(os.path.join(codex, "sessions")))]


def list_transcripts(root, since_ms):
    """→ ([(путь, размер, mtime_ns)] в порядке обхода, число непрочитанных путей).

    Элементы сортируются по имени на каждом уровне: когда один запрос лежит в двух файлах, его
    ячейку (день, модель, сессия) решает первый файл, и порядок обязан быть воспроизводимым.
    """
    files, failed = [], 0
    since_ns = since_ms * 1000000

    def walk(directory):
        nonlocal failed
        try:
            with os.scandir(directory) as listing:
                entries = sorted(listing, key=lambda entry: entry.name)
        except OSError:
            failed += 1
            return
        for entry in entries:
            # Каталог-симлинк не раскрывается; файл-симлинк читается через ссылку.
            if entry.is_dir(follow_symlinks=False):
                walk(entry.path)
            elif entry.name.endswith((".jsonl", ".jsonl.zst")):
                try:
                    status = os.stat(entry.path)
                except FileNotFoundError:
                    continue
                except OSError:
                    failed += 1
                    continue
                if status.st_mtime_ns >= since_ns:
                    files.append((entry.path, status.st_size, status.st_mtime_ns))

    walk(root)
    return files, failed


def _walk_key(path):
    return path.split(os.sep)


def scan(cache, roots, since_ms, cutoff_ms, on_progress):
    """Доводит кэш до состояния диска и возвращает по источнику на провайдера.

    Источник: {"provider", "exists", "files": [(путь, mtime_ns)] по порядку счёта,
    "unread": [mtime_ns | None], "compressed": [mtime_ns]}. В `files` — и живые файлы, и
    сохранённые записи удалённых: расход не должен пропадать вместе с транскриптом.
    """
    index = cache.index()
    sources, tasks = [], []
    decompress = None
    for provider, root in roots:
        source = {"provider": provider, "root": root, "exists": os.path.isdir(root), "live": [],
                  "unread": [], "compressed": []}
        sources.append(source)
        if not source["exists"]:
            continue
        source["live"], failed = list_transcripts(root, since_ms)
        source["unread"] = [None] * failed
        for path, size, mtime_ns in source["live"]:
            hit = index.get(path)
            same = hit is not None and hit.provider == provider
            if same and hit.size == size and hit.mtime_ns == mtime_ns:
                continue
            compressed = path.endswith(".zst")
            if compressed and decompress is None:
                decompress = find_decompressor() or []
            if compressed and not decompress:
                source["compressed"].append(mtime_ns)
                continue
            # Возобновлять можно только строго выросший файл: тот же размер с новым mtime или
            # меньший размер значат переписанное содержимое.
            resume = cache.position(path, hit) if same and size > hit.size and not compressed else None
            tasks.append(((path, provider, resume, decompress), size, mtime_ns, source))
    total = sum(len(source["live"]) for source in sources)
    done = total - len(tasks)
    on_progress(done, total)
    unreadable = set()
    for number, parsed in run_read_tasks([(task, size) for task, size, _mtime, _source in tasks]):
        (path, provider, _resume, _decompress), size, mtime_ns, source = tasks[number]
        done += 1
        if parsed is None:
            # Старые записи файла остаются в кэше как есть: пустой ответ спрятал бы расход
            # до следующей правки файла.
            source["unread"].append(mtime_ns)
            unreadable.add(path)
        else:
            records = parsed["records"]
            if parsed["resumed"]:
                records = dedupe_within_file(cache.records(path) + records)
            index[path] = cache.put(path, provider, size, mtime_ns, records, parsed)
        if on_progress(done, total):
            cache.commit()  # прерванный первый просмотр продолжится с этого места
    stale = set()
    for source in sources:
        live = {path for path, _size, _mtime in source["live"]}
        for path in live:
            # Архив заменяет сохранённые записи оригинала: иначе rollout посчитался бы дважды.
            if path.endswith(".jsonl.zst") and path in index and path not in unreadable \
                    and path[:-4] in index and path[:-4] not in live:
                stale.add(path[:-4])
    stale.update(path for path, entry in index.items() if entry.mtime_ns < cutoff_ms * 1000000)
    cache.delete(stale)
    cache.commit()
    for path in stale:
        del index[path]
    for source in sources:
        _order_source_files(source, index, since_ms)
    return sources, index


def _order_source_files(source, index, since_ms):
    """Порядок счёта: живые файлы в порядке обхода, за ними удалённые в том же порядке имён."""
    provider, root = source["provider"], source["root"]
    live = {path: mtime_ns for path, _size, mtime_ns in source.pop("live")}
    files = [(path, mtime_ns) for path, mtime_ns in live.items()
             if path in index and index[path].provider == provider]
    prefix = root.rstrip(os.sep) + os.sep
    saved = [path for path, entry in index.items()
             if entry.provider == provider and path not in live and path.startswith(prefix)
             and entry.mtime_ns >= since_ms * 1000000]
    saved.sort(key=_walk_key)
    source["files"] = files + [(path, index[path].mtime_ns) for path in saved]


# ──────────────────────────────────────────────────────────── цены: таблица LiteLLM

# Тарифы — кортеж (вход, выход, чтение кэша, запись кэша на 5 минут, запись на час), доллары
# за токен. Модель — (базовые, fast | None, ultrafast | None, [(порог, (базовые, fast, ultrafast))]).
R_INPUT, R_OUTPUT, R_CACHE_READ, R_CACHE_WRITE, R_CACHE_WRITE_1H = range(5)
FIRST_PARTY_PROVIDERS = frozenset(("anthropic", "deepseek", "gemini", "meta", "mistral", "openai", "xai"))
# Синтетические сообщения бесплатны, а голое имя семейства не говорит, какое поколение считать.
UNPRICEABLE_MODELS = frozenset(("<synthetic>", "synthetic", "opus", "sonnet", "haiku", "fable"))
# Потолки разумного для чужой таблицы. Настоящие цены в сотни тысяч раз меньше 100 долларов за
# токен; ниже потолок не ставится, потому что собственные тесты T3 считают на игрушечных ценах до 20.
MAX_TOKEN_RATE = 100
MAX_FAST_MULTIPLE = 100
_CONTEXT_TIER_KEY = re.compile(r"^input_cost_per_token_above_(\d{1,7})k_tokens(?:_priority|_ultrafast)?$")


def _finite(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return None
    return value


def _token_rate(value):
    # Таблица — чужой файл из сети, и одной конечности числа мало: 1e308 за токен даёт бесконечную
    # стоимость и срывает весь просмотр, отрицательная цена — отрицательный расход. Цена вне
    # границ — как пропущенное поле.
    value = _finite(value)
    return value if value is not None and 0 <= value <= MAX_TOKEN_RATE else None


def _token_rates(entry, suffix, standard=None, output_fallback=None):
    given = _token_rate(entry.get("input_cost_per_token" + suffix))
    produced = _token_rate(entry.get("output_cost_per_token" + suffix))
    if produced is None:
        produced = output_fallback
    if given is None or produced is None:
        return None

    def cache_rate(name, index, fallback):
        value = _token_rate(entry.get(name + suffix))
        if value is not None:
            return value
        # Вариант без своей кэш-цены держит отношение стандартного тарифа ко входу. Почти
        # нулевой вход делает отношение бесконечным, поэтому и оно проходит те же границы.
        if standard is not None and standard[R_INPUT] > 0:
            value = _token_rate(standard[index] / standard[R_INPUT] * given)
            if value is not None:
                return value
        return fallback

    read = cache_rate("cache_read_input_token_cost", R_CACHE_READ, given)
    write = cache_rate("cache_creation_input_token_cost", R_CACHE_WRITE, given)
    return (given, produced, read, write,
            cache_rate("cache_creation_input_token_cost_above_1hr", R_CACHE_WRITE_1H, write))


def _speed_rates(entry, standard, suffix=""):
    specific = entry.get("provider_specific_entry")
    multiple = _finite(specific.get("fast")) if isinstance(specific, dict) else None
    if multiple is not None and 0 < multiple <= MAX_FAST_MULTIPLE:
        fast = tuple(rate * multiple for rate in standard)  # Anthropic: множитель на весь тариф
    else:
        fast = _token_rates(entry, suffix + "_priority", standard)  # OpenAI: свои поля priority
    return (standard, fast, _token_rates(entry, suffix + "_ultrafast", standard))


def _context_tiers(entry, base):
    thresholds = []
    for name in entry:
        match = _CONTEXT_TIER_KEY.match(name) if isinstance(name, str) else None
        if match and match.group(1) not in thresholds:
            thresholds.append(match.group(1))
    tiers = []
    for threshold in thresholds:
        suffix = "_above_%sk_tokens" % threshold
        standard = _token_rates(entry, suffix, base, base[R_OUTPUT]) or base
        tiers.append((int(threshold) * 1000, _speed_rates(entry, standard, suffix)))
    tiers.sort(key=lambda tier: -tier[0])
    return tiers


def _merge_speed_rates(left, right):
    """Перепродавцы часто опускают быстрые тарифы: пропуск берётся у второй записи, а не спорит."""
    fast = left[1] if left[1] is not None else right[1]
    ultrafast = left[2] if left[2] is not None else right[2]
    if left[0] != right[0] or fast != (right[1] if right[1] is not None else fast) \
            or ultrafast != (right[2] if right[2] is not None else ultrafast):
        return None
    return (left[0], fast, ultrafast)


def _merge_alias_rate(left, right):
    speeds = _merge_speed_rates(left, right)
    if speeds is None:
        return None
    if not left[3] or not right[3]:
        return speeds + (left[3] or right[3],)
    if len(left[3]) != len(right[3]):
        return None
    tiers = []
    for (threshold, rates), (other_threshold, other_rates) in zip(left[3], right[3]):
        merged = _merge_speed_rates(rates, other_rates)
        if threshold != other_threshold or merged is None:
            return None
        tiers.append((threshold, merged))
    return speeds + (tiers,)


def parse_rate_table(document):
    """Документ LiteLLM → {ключ: тариф}. Модель без цены входа или выхода выбрасывается:
    половинчатая цена занизила бы стоимость молча."""
    table = {}
    if not isinstance(document, dict):
        return table
    for name, entry in document.items():
        if not isinstance(entry, dict):
            continue
        standard = _token_rates(entry, "")
        key = name.strip().lower()
        if standard is None or not key:
            continue
        table[key] = _speed_rates(entry, standard) + (_context_tiers(entry, standard),)
    # Голое имя для записей с префиксом провайдера — только когда оно однозначно.
    candidates = {}
    for key, rate in table.items():
        slash = key.find("/")
        if slash < 0:
            # Региональные идентификаторы Bedrock несут наценку и голого имени не дают.
            alias = key[len("anthropic."):] if key.startswith("anthropic.") else key
        else:
            alias = key[key.rfind("/") + 1:]
        if not alias or alias == key or alias in table:
            continue
        first_party = slash >= 0 and key[:slash] in FIRST_PARTY_PROVIDERS
        held = candidates.get(alias)
        if held is None or (first_party and not held[1]):
            candidates[alias] = (rate, first_party)
        elif held[0] is not None and first_party == held[1]:
            candidates[alias] = (_merge_alias_rate(held[0], rate), first_party)
    for alias, (rate, _first_party) in candidates.items():
        if rate is not None:
            table[alias] = rate
    return table


def _rate_key(model):
    key = model.strip().lower()
    bracket = key.find("[")  # claude-x[1m] оценивается как claude-x, надбавку даёт порог контекста
    return key if bracket < 0 else key[:bracket]


def lookup_rate(table, model):
    """Точное совпадение после trim, нижнего регистра и отрезания «[…]». Нечёткого поиска нет."""
    key = _rate_key(model)
    bare = key[key.rfind("/") + 1:]
    if not bare or bare in UNPRICEABLE_MODELS:
        return None
    return table.get(key)


def resolve_rate(table, overrides, model):
    """→ (тариф | None, своя ли это цена). Своя цена ищется по точному имени, без нижнего регистра."""
    override = overrides.get(model.strip())
    return (override, True) if override is not None else (lookup_rate(table, model), False)


def is_unlisted_model(table, model):
    """Модель, которой можно назначить цену, но таблица её не знает: свежая таблица может знать."""
    key = _rate_key(model)
    bare = key[key.rfind("/") + 1:]
    return bool(bare) and bare not in UNPRICEABLE_MODELS and table.get(key) is None


def price_usage(rate, is_override, record):
    """→ (стоимость, источник, (вход, чтение, запись, выход) | None, надбавка за скорость, экономия кэша).

    Порядок: своя цена пользователя, затем цена, которую сообщил провайдер, затем таблица.
    """
    reported = None if is_override else record[COST]
    if rate is None:
        return (0.0, "unpriced", None, 0.0, 0.0) if reported is None \
            else (reported, "providerReported", None, 0.0, 0.0)
    uncached, cached, written, produced = record[UNCACHED], record[CACHED], record[CACHE_WRITE], record[OUTPUT]
    prompt = uncached + cached + written
    # Запрос длиннее порога целиком идёт по тарифу длинного контекста, не только превышение.
    tier = next((rates for threshold, rates in rate[3] if prompt > threshold), None)
    standard = (tier or rate)[0]
    speed = record[SPEED]
    if speed == "standard":
        rates = standard
    else:
        index = 1 if speed == "fast" else 2
        rates = (tier[index] if tier else None) or rate[index] or standard
    one_hour = min(record[CACHE_WRITE_1H], written)

    def split(at):
        return (uncached * at[R_INPUT], cached * at[R_CACHE_READ],
                (written - one_hour) * at[R_CACHE_WRITE] + one_hour * at[R_CACHE_WRITE_1H],
                produced * at[R_OUTPUT])

    parts = split(rates)
    list_cost = parts[0] + parts[1] + parts[2] + parts[3]
    savings = cached * (rates[R_INPUT] - rates[R_CACHE_READ])
    if reported is not None and list_cost <= 0:
        return (reported, "providerReported", None, 0.0, savings)
    premium = 0.0
    if speed != "standard":
        at_standard = split(standard)
        premium = list_cost - (at_standard[0] + at_standard[1] + at_standard[2] + at_standard[3])
    if reported is None:
        return (list_cost, "modelPriced", parts, premium, savings)
    scale = reported / list_cost
    return (reported, "providerReported", tuple(part * scale for part in parts), premium * scale, savings)


class Rates:
    """Таблица LiteLLM с диска и из сети по расписанию T3: раз в сутки, не чаще раза в минуту."""

    def __init__(self):
        self.table, self.fetched_at_ms, self.status = {}, None, "unavailable"
        saved = core.read_json(usage_path("model-rates.json"), {})
        fetched_at = _finite(saved.get("fetchedAtMs"))
        table = parse_rate_table(saved.get("document"))
        if table and fetched_at is not None:
            self.table, self.fetched_at_ms, self.status = table, fetched_at, "cached"
        # У T3 это память процесса; здесь каждый запуск — новый процесс, и без файла провал
        # сети повторялся бы на каждом открытии окна.
        self.state = core.read_json(usage_path("rates-state.json"), {})

    def ensure(self, force):
        now = now_ms()
        max_age = RATES_REFRESH_FLOOR_MS if force else RATES_TTL_MS
        if self.fetched_at_ms is not None and now - self.fetched_at_ms < max_age:
            return
        failed_at = _finite(self.state.get("lastFailedAtMs"))
        if failed_at is not None and now - failed_at < RATES_REFRESH_FLOOR_MS:
            return
        fetched = _fetch_rates(LITELLM_RATES_URL, "application/json") \
            or _fetch_rates(LITELLM_RATES_API_URL, "application/vnd.github.raw+json")
        if fetched is None:
            self.state["lastFailedAtMs"] = now_ms()
            if self.table:
                self.status = "cached"
        else:
            document, self.table = fetched
            self.fetched_at_ms, self.status = now, "fresh"
            self.state.pop("lastFailedAtMs", None)
            _write_quietly("model-rates.json", {"fetchedAtMs": now, "document": document})
        _write_quietly("rates-state.json", self.state)

    def refresh_for_unlisted(self, models):
        """Модель вышла после загрузки таблицы — таблица перечитывается раньше срока, по разу на модель."""
        checked = self.state.get("checkedUnlisted")
        checked = set(checked) if isinstance(checked, list) else set()
        unlisted = [model for model in models if model not in checked and is_unlisted_model(self.table, model)]
        if not unlisted:
            return
        self.ensure(True)
        # Неудачная загрузка оставляет модели непроверенными: следующий запуск попробует снова.
        if self.fetched_at_ms is None or now_ms() - self.fetched_at_ms >= RATES_REFRESH_FLOOR_MS:
            return
        self.state["checkedUnlisted"] = sorted(checked.union(unlisted))
        _write_quietly("rates-state.json", self.state)

    def describe(self):
        return {"status": self.status, "source": "litellm", "knownModels": len(self.table),
                "fetchedAt": None if self.fetched_at_ms is None else int(self.fetched_at_ms // 1000)}


def _fetch_rates(url, accept):
    """(документ, таблица) или None: сеть, статус, срок, не JSON и пустая таблица — одинаково провал."""
    try:
        request = urllib.request.Request(url, headers={"accept": accept})
        deadline = time.monotonic() + RATES_DEADLINE
        body = bytearray()
        with urllib.request.urlopen(request, timeout=RATES_TIMEOUT) as response:
            # Таймаут сокета отсчитывается на каждое чтение заново: сервер, цедящий по байту,
            # держал бы просмотр минутами. read1 отдаёт уже пришедшее, не дожидаясь полного куска,
            # поэтому общий срок сверяется после каждого чтения.
            while True:
                chunk = response.read1(READ_CHUNK)
                if not chunk:
                    break
                body += chunk
                if len(body) > RATES_MAX_BYTES or time.monotonic() > deadline:
                    return None
        document = json.loads(body.decode("utf-8"))
    except urllib.error.HTTPError as error:
        # Ответ с ошибкой — открытый файл: незакрытый, он уходит сборщику мусора с ResourceWarning.
        error.close()
        return None
    except Exception:
        return None
    table = parse_rate_table(document)
    return (document, table) if table else None


def _write_quietly(name, data):
    # Кэш цен — удобство: без него таблица просто загрузится ещё раз.
    try:
        core.write_json(usage_path(name), data, mode=core.SECURE_FILE)
    except OSError:
        pass


# ──────────────────────────────────────────────────────────── цены и «Map to» пользователя

def _price(prices, name, required):
    """Цена за миллион токенов: конечное число не меньше нуля. → (значение | None, годна ли запись)."""
    if name not in prices:
        return None, not required
    value = _finite(prices[name])
    return value, value is not None and value >= 0


def read_price_settings():
    """usage/prices.json пишет Swift. → ({модель: тариф}, {модель: цель}); негодные записи пропускаются."""
    raw = core.read_json(usage_path("prices.json"), {})
    return parse_price_overrides(raw.get("usagePriceOverrides")), parse_aliases(raw.get("usageModelAliases"))


def parse_price_overrides(prices_by_model):
    overrides = {}
    for model, prices in (prices_by_model.items() if isinstance(prices_by_model, dict) else ()):
        if not model.strip() or not isinstance(prices, dict):
            continue
        values = [_price(prices, name, required) for name, required in (
            ("inputCostPerMillionTokens", True), ("outputCostPerMillionTokens", True),
            ("cacheReadCostPerMillionTokens", False), ("cacheWriteCostPerMillionTokens", False))]
        if not all(valid for _value, valid in values):
            continue
        given, produced, read, write = (value for value, _valid in values)
        # Пустая кэш-цена равна цене входа; явный ноль — бесплатно.
        write = (given if write is None else write) / 1e6
        # У своей цены нет ни быстрых тарифов, ни порогов длинного контекста.
        overrides[model.strip()] = ((given / 1e6, produced / 1e6, (given if read is None else read) / 1e6,
                                     write, write), None, None, [])
    return overrides


def parse_aliases(aliases):
    if not isinstance(aliases, dict):
        return {}
    return resolve_aliases({source.strip(): target.strip() for source, target in aliases.items()
                            if isinstance(target, str) and source.strip() and target.strip()})


def resolve_aliases(aliases):
    """Цепочки сводятся к конечной модели; всё, что уходит в цикл, остаётся само собой."""
    memo = {}
    for model in aliases:
        if model in memo:
            continue
        path, target = [], model
        while target in aliases and target not in memo:
            path.append(target)
            memo[target] = None  # None — путь в работе или путь в цикл
            target = aliases[target]
        terminal = memo.get(target) if target in aliases else target
        for alias in path:
            memo[alias] = terminal
    return {model: target for model, target in memo.items() if target is not None}


# ──────────────────────────────────────────────────────────── свод копий и минутные ячейки

# Поля ячейки и корзины по порядку; за ними одним элементом идёт множество сессий.
(C_UNCACHED, C_CACHED, C_CACHE_WRITE, C_OUTPUT, C_REASONING, C_COST, C_SAVINGS, C_INPUT_COST,
 C_CACHE_READ_COST, C_CACHE_WRITE_COST, C_OUTPUT_COST, C_SPLIT, C_FAST, C_ULTRAFAST, C_PREMIUM,
 C_RECORDS, C_UNPRICED, C_UNPRICED_TOKENS, C_REPORTED, C_SESSIONS) = range(20)


class Ledger:
    """Сводит копии запроса по всем файлам, оценивает и складывает в ячейки (минута, провайдер, модель).

    Запись с ключом оценивается только в finish(): до этого её копии ещё сливаются по
    максимуму каналов, а цена зависит от итоговых чисел.
    """

    def __init__(self, table, overrides, aliases):
        self.table, self.overrides, self.aliases = table, overrides, aliases
        self.cells, self.seen, self.rates = {}, {}, {}
        self.duplicates = 0

    def add(self, provider, record, key):
        target = self.aliases.get(record[MODEL])
        if target is not None:
            record = list(record)
            record[MODEL] = target
        if key is None:
            self._account(provider, record)
            return
        held = self.seen.get(key)
        if held is None:
            self.seen[key] = (provider, record)
        else:
            self.duplicates += 1
            merged = merge_usage_copies(held[1], record)
            if merged is not held[1]:
                self.seen[key] = (held[0], merged)

    def add_file(self, provider, records, shared_sessions=()):
        """Записи одного файла. Сессии Codex, живущей в нескольких файлах (rollout переехал),
        ключ даётся по содержимому и порядковому номеру одинаковых событий внутри файла."""
        occurrences = {}
        for record in records:
            key = record[KEY]
            if record[SESSION] in shared_sessions:
                event = (provider, record[SESSION]) + tuple(record[i] for i in (TS, MODEL) + TOKEN_CHANNELS[:5])
                occurrences[event] = occurrences.get(event, 0) + 1
                key = event + (occurrences[event],)
            self.add(provider, record, key)

    def _account(self, provider, record):
        model = record[MODEL]
        rate = self.rates.get(model)
        if rate is None:
            rate = self.rates[model] = resolve_rate(self.table, self.overrides, model)
        cost, source, parts, premium, savings = price_usage(rate[0], rate[1], record)
        cell_key = (record[TS] // MINUTE_MS, provider, model)
        cell = self.cells.get(cell_key)
        if cell is None:
            cell = self.cells[cell_key] = [0] * C_SESSIONS + [set()]
        cell[C_UNCACHED] += record[UNCACHED]
        cell[C_CACHED] += record[CACHED]
        cell[C_CACHE_WRITE] += record[CACHE_WRITE]
        cell[C_OUTPUT] += record[OUTPUT]
        cell[C_REASONING] += record[REASONING]
        cell[C_COST] += cost
        cell[C_SAVINGS] += savings
        if parts is not None:
            cell[C_INPUT_COST] += parts[0]
            cell[C_CACHE_READ_COST] += parts[1]
            cell[C_CACHE_WRITE_COST] += parts[2]
            cell[C_OUTPUT_COST] += parts[3]
            cell[C_SPLIT] += 1
        speed = record[SPEED]
        if speed == "fast":
            cell[C_FAST] += cost  # вся стоимость быстрых запросов, не надбавка
        elif speed == "ultrafast":
            cell[C_ULTRAFAST] += cost
        cell[C_PREMIUM] += premium
        cell[C_RECORDS] += 1
        if source == "unpriced":
            cell[C_UNPRICED] += 1
            cell[C_UNPRICED_TOKENS] += record[UNCACHED] + record[CACHED] + record[CACHE_WRITE] + record[OUTPUT]
        elif source == "providerReported":
            cell[C_REPORTED] += 1
        if record[SESSION]:
            cell[C_SESSIONS].add(record[SESSION])

    def finish(self):
        for provider, record in self.seen.values():
            self._account(provider, record)
        self.seen = {}
        return self.cells


# ──────────────────────────────────────────────────────────── окна и корзины

_OFFSET_ZONE = re.compile(r"^([+-])(\d{2}):?(\d{2})$")


def _zone(name):
    match = _OFFSET_ZONE.match(name)
    if match:
        delta = timedelta(hours=int(match.group(2)), minutes=int(match.group(3)))
        return timezone(delta if match.group(1) == "+" else -delta)
    try:
        return ZoneInfo(name)
    except Exception:
        return timezone.utc


def system_time_zone():
    """IANA-имя пояса машины: TZ, иначе ссылка /etc/localtime, иначе UTC."""
    candidates = [(os.environ.get("TZ") or "").lstrip(":")]
    try:
        target = os.path.realpath("/etc/localtime")
        candidates.append(target.split("/zoneinfo/", 1)[1] if "/zoneinfo/" in target else "")
    except OSError:
        pass
    for name in candidates:
        try:
            if name and ZoneInfo(name):
                return name
        except Exception:
            continue
    return "UTC"


def iso_ms(ms):
    """Как toISOString() в JavaScript: по этим строкам окно сопоставляет точки графика с корзинами."""
    return datetime.fromtimestamp(ms // 1000, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S") + ".%03dZ" % (ms % 1000)


def _day(ms, zone):
    return datetime.fromtimestamp(ms / 1000, zone).strftime("%Y-%m-%d")


def make_window(days, now, time_zone):
    """Окно периода, как makeWindow в T3: сутки — скользящие 24 часа от целой минуты, остальное —
    календарные дни в поясе машины, считая сегодняшний."""
    zone = _zone(time_zone)
    until_day = _day(now, zone)
    if days == 1:
        until = now // MINUTE_MS * MINUTE_MS
        since = until - DAY_MS
        return {"resolution": "hour", "sinceDay": _day(since, zone), "untilDay": _day(until, zone),
                "sinceMs": since, "untilMs": until}
    # Арифметика по календарю: вычитание миллисекунд съезжает на сутках перевода часов.
    start = datetime.strptime(until_day, "%Y-%m-%d") - timedelta(days=days - 1)
    return {"resolution": "day", "sinceDay": start.strftime("%Y-%m-%d"), "untilDay": until_day}


def window_start_ms(window):
    """Самый ранний mtime файла, который окно ещё открывает."""
    if window["resolution"] == "hour":
        return window["sinceMs"] - MTIME_SLACK_MS
    midnight = datetime.strptime(window["sinceDay"], "%Y-%m-%d").replace(tzinfo=timezone.utc)
    return int(midnight.timestamp()) * 1000 - MTIME_SLACK_MS


def _round_usd(value):
    # Math.round в JS округляет половину вверх; встроенный round — к чётному.
    return math.floor(value * 1e6 + 0.5) / 1e6


def aggregate(cells, window, time_zone, days=None):
    """Ячейки → (корзины окна, {провайдер: множество сессий в окне}).

    `days` — общая память «минута → день» для нескольких окон одного пояса.
    """
    zone = _zone(time_zone)
    days = {} if days is None else days
    hourly = window["resolution"] == "hour"
    since_day, until_day = window["sinceDay"], window["untilDay"]
    buckets, sessions = {}, {}
    for (minute, provider, model), cell in cells.items():
        ms = minute * MINUTE_MS
        hour_start = ""
        if hourly:
            if ms < window["sinceMs"] or ms >= window["untilMs"]:
                continue
            # Часы отсчитываются от начала окна, а не от границ циферблата.
            hour_start = window["sinceMs"] + (ms - window["sinceMs"]) // HOUR_MS * HOUR_MS
        day = days.get(minute)
        if day is None:
            try:
                day = days[minute] = _day(ms, zone)
            except (OverflowError, ValueError, OSError):
                # Date.parse принимает и год 0001, и год 9999, а местный день такого мига выходит
                # за календарь datetime. В окно последних 90 дней такая запись не попадает.
                continue
        if not hourly and (day < since_day or day > until_day):
            continue
        key = (day, hour_start, provider, model)
        bucket = buckets.get(key)
        if bucket is None:
            buckets[key] = cell[:C_SESSIONS] + [set(cell[C_SESSIONS])]
        else:
            for index in range(C_SESSIONS):
                bucket[index] += cell[index]
            bucket[C_SESSIONS] |= cell[C_SESSIONS]
        sessions.setdefault(provider, set()).update(cell[C_SESSIONS])
    return [_bucket(key, buckets[key]) for key in sorted(buckets)], sessions


def _bucket(key, sums):
    day, hour_start, provider, model = key
    bucket = {"day": day}
    if hour_start != "":
        bucket["hourStart"] = iso_ms(hour_start)
    bucket.update({
        "provider": provider, "model": model,
        "totals": {"uncachedInputTokens": sums[C_UNCACHED], "cachedInputTokens": sums[C_CACHED],
                   "cacheCreationTokens": sums[C_CACHE_WRITE], "outputTokens": sums[C_OUTPUT],
                   "reasoningTokens": sums[C_REASONING]},
        # Стоимость и экономия не округляются; округляются только части и скоростные поля.
        "costUsd": sums[C_COST], "cacheSavingsUsd": sums[C_SAVINGS]})
    if sums[C_SPLIT]:
        bucket["categoryCostUsd"] = {
            "input": _round_usd(sums[C_INPUT_COST]), "cacheRead": _round_usd(sums[C_CACHE_READ_COST]),
            "cacheWrite": _round_usd(sums[C_CACHE_WRITE_COST]), "output": _round_usd(sums[C_OUTPUT_COST])}
    for name, index in (("fastCostUsd", C_FAST), ("ultrafastCostUsd", C_ULTRAFAST),
                        ("speedPremiumUsd", C_PREMIUM)):
        rounded = _round_usd(sums[index])
        if rounded != 0:
            bucket[name] = rounded
    if sums[C_UNPRICED] == sums[C_RECORDS]:
        source = "unpriced"
    else:
        source = "providerReported" if sums[C_REPORTED] == sums[C_RECORDS] else "modelPriced"
    bucket.update({"costSource": source, "records": sums[C_RECORDS], "unpricedRecords": sums[C_UNPRICED],
                   "unpricedTokens": sums[C_UNPRICED_TOKENS], "sessions": len(sums[C_SESSIONS])})
    return bucket


def describe_source(source, index, since_ms, sessions):
    """Источник одного периода. Период видит только файлы, чей mtime не старше его порога."""
    since_ns = since_ms * 1000000
    scanned = skipped = malformed = 0
    for path, mtime_ns in source["files"]:
        if mtime_ns < since_ns:
            continue
        malformed += index[path].malformed
        if index[path].count:
            scanned += 1
        else:
            skipped += 1
    compressed = sum(1 for mtime_ns in source["compressed"] if mtime_ns >= since_ns)
    unread = sum(1 for mtime_ns in source["unread"] if mtime_ns is None or mtime_ns >= since_ns)
    if not source["exists"] and scanned == 0:
        status = "missing"
    else:
        status = "partial" if malformed or unread or compressed else "ok"
    message = None
    if not source["exists"]:
        message = "no_history"
    elif unread:
        message = "read_failed"
    elif compressed:
        message = "zstd_unavailable"
    return {"provider": source["provider"], "status": status, "scannedFiles": scanned,
            "skippedFiles": skipped + compressed, "malformedRecords": malformed,
            "distinctSessions": len(sessions), "message": message}


# ──────────────────────────────────────────────────────────── команда

def write_status(state, detail="", done=0, total=0):
    core.write_json(usage_path("status.json"),
                    {"ts": int(time.time()), "state": state, "detail": detail, "done": done, "total": total},
                    mode=core.SECURE_FILE)


def _progress_writer():
    last = [0.0]  # первый вызов пишет сразу: в нём впервые известно общее число файлов

    def report(done, total):
        if time.monotonic() - last[0] < STATUS_INTERVAL:
            return False
        last[0] = time.monotonic()
        write_status("scanning", "", done, total)
        return True

    return report


def collect_cells(cache, sources, index, rates, overrides, aliases):
    """Все записи в порядке счёта → минутные ячейки."""
    seen, shared = set(), set()
    for source in sources:
        if source["provider"] != "codex":
            continue
        for path, _mtime in source["files"]:
            shared.update(seen.intersection(index[path].sessions))
            seen.update(index[path].sessions)
    ledger = Ledger(rates.table, overrides, aliases)
    stored = cache.all_records()
    for source in sources:
        sessions = shared if source["provider"] == "codex" else ()
        for path, _mtime in source["files"]:
            records, tail = stored.pop(path, ("[]", "[]"))
            rows = _load(records, path) + (_load(tail, path) if tail != "[]" else [])
            ledger.add_file(source["provider"], rows, sessions)
    return ledger.finish()


def summarize(cache, refresh):
    started = now_ms()
    time_zone = system_time_zone()
    windows = {days: make_window(days, started, time_zone) for days in PERIODS}
    starts = {days: window_start_ms(window) for days, window in windows.items()}
    rates = Rates()
    # Цены качаются, пока идёт просмотр: медленная сеть не должна держать счётчик файлов на нуле.
    fetch = threading.Thread(target=rates.ensure, args=(refresh,), daemon=True)
    fetch.start()
    dropped = 0
    while True:
        try:
            sources, index = scan(cache, transcript_roots(), min(starts.values()),
                                  max(0, started - RETENTION_DAYS * DAY_MS), _progress_writer())
            fetch.join()
            overrides, aliases = read_price_settings()
            models = {aliases.get(model, model) for source in sources for path, _mtime in source["files"]
                      for model in index[path].models}
            rates.refresh_for_unlisted(sorted(model for model in models if model.strip() not in overrides))
            cells = collect_cells(cache, sources, index, rates, overrides, aliases)
            break
        except BrokenRow as row:
            # Нечитаемая строка — порча записей одного файла, а в остальном кэше лежит единственная
            # копия расхода из транскриптов, которых на диске уже нет. Выбрасываются только записи
            # этого файла, и следующий проход пересматривает один его. Много таких строк — уже
            # порча всей базы: чинить её по файлу значило бы столько же раз обходить историю.
            dropped += 1
            if dropped > BROKEN_ROWS_LIMIT:
                raise sqlite3.DatabaseError("too many broken cache rows") from None
            cache.delete([row.path])
            cache.commit()
    periods, days = {}, {}
    for number, window in windows.items():
        buckets, sessions = aggregate(cells, window, time_zone, days)
        period = {"resolution": window["resolution"], "sinceDay": window["sinceDay"],
                  "untilDay": window["untilDay"]}
        if window["resolution"] == "hour":
            period.update(sinceTime=iso_ms(window["sinceMs"]), untilTime=iso_ms(window["untilMs"]))
        period["buckets"] = buckets
        period["sources"] = [describe_source(source, index, starts[number], sessions.get(source["provider"], ()))
                             for source in sources]
        periods[str(number)] = period
    return {"version": SUMMARY_VERSION, "readAt": started // 1000, "timeZone": time_zone,
            "scanDurationMs": max(0, now_ms() - started), "pricing": rates.describe(), "periods": periods}


def _run(refresh):
    directory = usage_path("")
    # Корень состояния создаётся отдельно: для usage/ он промежуточный каталог, а на такие mode
    # у makedirs не действует — на свежей машине корень родился бы с правами umask (0755).
    os.makedirs(core.ROOT, mode=core.SECURE_DIR, exist_ok=True)
    os.makedirs(directory, mode=core.SECURE_DIR, exist_ok=True)
    lock = os.open(usage_path("scan.lock"), os.O_WRONLY | os.O_CREAT, core.SECURE_FILE)
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            # Второй просмотр уже идёт и сам пишет status.json; мешать ему записью нельзя.
            raise UsageFailure("busy")
        write_status("scanning")
        cache_path = usage_path("scan-cache.sqlite3")
        try:
            cache = ScanCache(cache_path)
            try:
                summary = summarize(cache, refresh)
            finally:
                cache.close()
        except sqlite3.DatabaseError as error:
            # Удаляется только кэш, испорченный целиком; следующий запуск соберёт его заново.
            # О такой порче sqlite сообщает самим DatabaseError. Его подклассы — занятая база,
            # отказ записи, ошибка запроса — файл не трогают: в нём единственная копия расхода
            # из уже удалённых транскриптов.
            if type(error) is sqlite3.DatabaseError:
                _remove_quietly(cache_path)
            raise UsageFailure("cache_failed")
        # NaN или бесконечность в сводке Swift не разберёт; лучше честный сбой, чем битый файл.
        json.dumps(summary, allow_nan=False)
        core.write_json(usage_path("summary.json"), summary, mode=core.SECURE_FILE)
        # Сводка раньше статуса: «ok» обещает, что файл уже свежий.
        write_status("ok")
    finally:
        os.close(lock)


def _remove_quietly(path):
    try:
        os.remove(path)
    except OSError:
        pass


def command(argv):
    """`mcpbar.py usage [--refresh]`. Код 0 — summary.json свежий; наружу исключения не выходят."""
    try:
        _run("--refresh" in argv)
        return 0
    except UsageFailure as failure:
        category = str(failure)
    except Exception:
        category = "scan_failed"
    if category != "busy":
        try:
            write_status("failed", category)
        except Exception:
            pass
    print("usage: %s" % category, file=sys.stderr)
    return 1
