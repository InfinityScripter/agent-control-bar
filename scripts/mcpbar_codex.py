#!/usr/bin/env python3
"""Codex-половина mcpbar.py: лимиты аккаунта и запасные rollout-снимки, MCP-серверы Codex и доверие к нашим хукам.

Отдельный модуль, а не отдельный скрипт: команды по-прежнему приходят через `mcpbar.py`
(codex-limits, codex-mcp, codex-hooks), общие помощники — запись файлов, строки, разбор
времени — берутся оттуда же. Своих зависимостей, кроме стандартной библиотеки, нет.

`ROOT` читается как `core.ROOT` в момент вызова, а не копируется при импорте: тесты подменяют
корень на модуле mcpbar, и копия здесь осталась бы старой.
"""

import base64
import glob
import hashlib
import json
import math
import os
import socket
import stat
import struct
import time

import mcpbar as core
from mcpbar import (HOME, SECURE_DIR, STRINGS, Refused, describe_tool, mtime, parse_reset,
                    read_json, read_json_line, t, tail_lines, write_json)


CODEX_ATTENTION_TIMEOUT = 1.5


def read_codex_attention(thread_ids, deadline):
    """Читает только статус уже работающей службы; deadline общий для всех thread/read."""
    observed = {}
    connection = None
    try:
        path = os.path.realpath(os.path.join(CODEX, "app-server-control", "app-server-control.sock"))
        try:
            attributes = os.stat(path)
        except OSError:
            return {}, "socket_unavailable"
        if not stat.S_ISSOCK(attributes.st_mode) or attributes.st_uid != os.getuid() \
                or stat.S_IMODE(attributes.st_mode) & 0o077:
            return {}, "unsafe_socket"
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)

        def remaining():
            seconds = deadline - time.monotonic()
            if seconds <= 0:
                raise socket.timeout()
            connection.settimeout(seconds)

        remaining()
        connection.connect(path)
        total_bytes = 0

        def exact(count):
            nonlocal total_bytes
            total_bytes += count
            if total_bytes > 8 * 1024 * 1024:
                raise ValueError("invalid_frame")
            value = bytearray()
            while len(value) < count:
                remaining()
                chunk = connection.recv(count - len(value))
                if not chunk:
                    raise ValueError("connection_closed")
                value.extend(chunk)
            return bytes(value)

        def send(payload, opcode=1):
            count = len(payload)
            mask = os.urandom(4)
            header = bytes([128 | opcode])
            if count < 126:
                header += bytes([128 | count])
            elif count < 65536:
                header += bytes([128 | 126]) + struct.pack("!H", count)
            else:
                header += bytes([128 | 127]) + struct.pack("!Q", count)
            remaining()
            connection.sendall(header + mask + bytes(value ^ mask[index % 4]
                                                     for index, value in enumerate(payload)))

        key = base64.b64encode(os.urandom(16))
        remaining()
        connection.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                           b"Connection: Upgrade\r\nSec-WebSocket-Key: " + key +
                           b"\r\nSec-WebSocket-Version: 13\r\n\r\n")
        header = bytearray()
        while not header.endswith(b"\r\n\r\n"):
            header.extend(exact(1))
            if len(header) > 8192:
                raise ValueError("invalid_handshake")
        lines = bytes(header).split(b"\r\n")
        fields = {line.split(b":", 1)[0].strip().lower(): line.split(b":", 1)[1].strip()
                  for line in lines[1:] if b":" in line}
        accepted = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
        if not lines[0].startswith(b"HTTP/1.1 101 ") or fields.get(b"sec-websocket-accept") != accepted \
                or fields.get(b"upgrade", b"").lower() != b"websocket" \
                or b"upgrade" not in fields.get(b"connection", b"").lower().split(b", "):
            raise ValueError("invalid_handshake")

        def receive(request_id):
            assembled = bytearray()
            fragmented = False
            while True:
                first, second = exact(2)
                opcode, final = first & 15, bool(first & 128)
                count = second & 127
                if count == 126:
                    count = struct.unpack("!H", exact(2))[0]
                elif count == 127:
                    count = struct.unpack("!Q", exact(8))[0]
                if first & 0x70 or second & 128 or count > 1024 * 1024:
                    raise ValueError("invalid_frame")
                if opcode >= 8 and (not final or count > 125):
                    raise ValueError("invalid_frame")
                payload = exact(count)
                if opcode == 8:
                    raise ValueError("connection_closed")
                if opcode == 9:
                    send(payload, 10)
                    continue
                if opcode == 10:
                    continue
                if opcode not in (0, 1) or (opcode == 0) != fragmented:
                    raise ValueError("invalid_frame")
                assembled.extend(payload)
                if len(assembled) > 1024 * 1024:
                    raise ValueError("invalid_frame")
                fragmented = not final
                if not final:
                    continue
                try:
                    reply = json.loads(assembled)
                except (ValueError, UnicodeDecodeError):
                    raise ValueError("invalid_reply")
                assembled.clear()
                if not isinstance(reply, dict):
                    raise ValueError("invalid_reply")
                # Уведомления и чужие server requests не требуют ответа наблюдателя.
                if reply.get("id") != request_id or "method" in reply:
                    continue
                if "error" in reply:
                    raise ValueError("rpc_error")
                result = reply.get("result")
                if not isinstance(result, dict):
                    raise ValueError("invalid_reply")
                return result

        send(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "agent-control-bar-attention", "version": "1"},
            "capabilities": {"experimentalApi": False}}}).encode())
        receive(1)
        send(b'{"jsonrpc":"2.0","method":"initialized"}')
        for request_id, thread_id in enumerate(thread_ids, 2):
            send(json.dumps({"jsonrpc": "2.0", "id": request_id, "method": "thread/read",
                             "params": {"threadId": thread_id, "includeTurns": False}}).encode())
            result = receive(request_id)
            thread = result.get("thread")
            if not isinstance(thread, dict) or thread.get("id") != thread_id:
                raise ValueError("invalid_reply")
            status = thread.get("status")
            if not isinstance(status, dict) or status.get("type") not in ("active", "idle", "notLoaded", "systemError"):
                raise ValueError("invalid_status")
            flags = status.get("activeFlags")
            if status["type"] == "active" and (not isinstance(flags, list)
                                               or not all(isinstance(flag, str) for flag in flags)):
                raise ValueError("invalid_status")
            observed[thread_id] = {"awaiting_approval": status["type"] == "active" and "waitingOnApproval" in flags,
                                   "observed_at": time.time()}
        return observed, None
    except socket.timeout:
        return {}, "timeout"
    except OSError:
        return {}, "connection_unavailable"
    except ValueError as exc:
        return {}, str(exc)
    finally:
        if connection is not None:
            connection.close()


def fetch_codex_attention():
    deadline = time.monotonic() + CODEX_ATTENTION_TIMEOUT
    codex_root = os.path.join(core.ROOT, "codex")
    sessions = {}
    for path in sorted(glob.glob(os.path.join(codex_root, "state.d", "*.json"))):
        if time.monotonic() >= deadline:
            break
        try:
            if os.stat(path).st_size > 65536:
                continue
        except OSError:
            continue
        state = read_json(path)
        if not isinstance(state, dict) or state.get("started") is not True \
                or state.get("thread_source") == "subagent":
            continue
        thread_id = state.get("sessionId")
        turn_id, pid = state.get("turn_id"), state.get("pid")
        if not isinstance(thread_id, str) or not 0 < len(thread_id) <= 128 \
                or not isinstance(turn_id, str) or not 0 < len(turn_id) <= 128 \
                or not isinstance(pid, int) or isinstance(pid, bool) or not 0 < pid <= 2 ** 31 - 1:
            continue
        try:
            os.kill(pid, 0)
        except OSError:
            continue
        sessions[thread_id] = {"thread_id": thread_id, "pid": pid, "turn_id": turn_id}
    observed, error = read_codex_attention(sessions, deadline) if sessions else ({}, None)
    record = {"version": 1, "status": "unavailable" if error else "ok", "sessions": []}
    if error:
        record["error"] = error
    else:
        record["sessions"] = [dict(session, **observed[thread_id]) for thread_id, session in sessions.items()]
    for directory in (core.ROOT, codex_root):
        os.makedirs(directory, mode=SECURE_DIR, exist_ok=True)
        os.chmod(directory, SECURE_DIR)
    write_json(os.path.join(codex_root, "attention.json"), record, mode=0o600)
    return record["status"] + (": " + error if error else "")


# ──────────────────────────────────────────────────────────── лимиты Codex

# Текущую квоту отдаёт app-server; журналы сессий используются только при его недоступности.
CODEX = os.path.join(HOME, ".codex")
# YYYY/MM/DD разложены каталогами; три звёздочки вместо рекурсии — архив сессий лежит
# в соседнем каталоге и обходить его незачем.
CODEX_ROLLOUTS = os.path.join(CODEX, "sessions", "*", "*", "*", "rollout-*.jsonl")
CODEX_ROOT = os.path.join(core.ROOT, "codex")
CODEX_LIMITS = os.path.join(CODEX_ROOT, "limits.json")


def secure_codex_root():
    """Оба каталога под codex/*.json — руками и до записи.

    `os.makedirs(..., mode=)` ставит права только последнему каталогу пути, промежуточные
    рождаются с umask: на свежей машине, где первой командой оказался `codex-limits`, сам
    ~/.claude/control-bar остался бы 0755 — открытым всей группе staff вместе с процентами
    лимитов аккаунта. Общая на трёх писателей: правило «оба каталога 0700» держалось на
    дисциплине копирования, и четвёртый писатель легко обошёлся бы одним makedirs.
    """
    for directory in (core.ROOT, CODEX_ROOT):
        try:
            os.makedirs(directory, mode=SECURE_DIR, exist_ok=True)
        except OSError:
            pass


def rollouts_by_age(pattern=None):
    """Файлы сессий Codex от свежего к старому.

    Только .jsonl: старые ходы Codex ужимает в .jsonl.zst, а распаковывать архив ради
    цифр, которые всё равно протухли, незачем — живой файл всегда несжатый.
    """
    files = [path for path in glob.glob(pattern or CODEX_ROLLOUTS) if path.endswith(".jsonl")]
    return sorted(files, key=mtime, reverse=True)


def newest_rollout(pattern=None):
    """Самый свежий rollout по времени правки, или None."""
    files = rollouts_by_age(pattern)
    return files[0] if files else None


def codex_window(block, kind, base):
    """Окно снимка → {kind, window_minutes, used_percentage, resets_at} или None.

    `base` — момент самого снимка: старые сборки Codex сообщают не время сброса, а
    сколько секунд до него осталось, и отсчитывать их от «сейчас» значило бы двигать
    сброс вперёд на каждый опрос.
    """
    if not isinstance(block, dict):
        return None
    used = block.get("usedPercent", block.get("used_percent", block.get("used_percentage")))
    if isinstance(used, bool):
        return None
    try:
        pct = int(round(float(used)))
    # OverflowError — это Infinity: json.loads принимает голый Infinity-токен, и round()
    # на нём кидает именно его. Одно такое окно не должно уносить второе.
    except (TypeError, ValueError, OverflowError):
        return None
    record = {"kind": kind, "used_percentage": max(0, min(100, pct))}
    minutes = block.get("windowDurationMins", block.get("window_minutes"))
    # bool — подкласс int, а True в поле длительности окна означает испорченный файл,
    # не окно длиной в минуту.
    if isinstance(minutes, (int, float)) and not isinstance(minutes, bool) and math.isfinite(minutes) and minutes > 0:
        record["window_minutes"] = int(minutes)
    resets = parse_reset(block.get("resetsAt", block.get("resets_at")))
    if resets is None:
        after = block.get("resets_in_seconds", block.get("reset_after_seconds"))
        if isinstance(after, (int, float)) and not isinstance(after, bool) and math.isfinite(after):
            resets = int(base + after)
    record["resets_at"] = resets
    return record


def codex_pool(model):
    """Какой пул лимитов мерил ход этой модели: обычный ("codex") или резервный ("reserve").

    Резервный — тот, на который Codex уходит, когда обычный лимит кончился.

    В rollout оба пула приходят под limit_id="codex", поэтому только для запасного
    снимка пул определяется моделью хода. Прямой API использует limitId/limitName.
    """
    return "reserve" if isinstance(model, str) and model.startswith("gpt-reserve") else "codex"


# Окна снимка и их порядок — одним списком, из которого считается и ранг для сортировки.
# Порядок нужен дважды: так окна читаются из снимка и так они ложатся в файл, где к ним
# добавляется резервное. Двумя списками эти два места разъезжались бы молча — строки панели
# просто начали бы меняться местами от опроса к опросу.
CODEX_WINDOW_KINDS = ("primary", "secondary")
CODEX_WINDOW_ORDER = {kind: at for at, kind in enumerate(CODEX_WINDOW_KINDS)}


def codex_limits_record(snapshot, ts=None, now=None, model=None, source="rollout"):
    """Снимок rollout или ответ account/rateLimits/read → codex/limits.json.

    Наружу идут факты, а не подписи: процент, длительность окна в минутах и момент
    сброса epoch-секундами. Как назвать окно в панели, решает Swift — у разных планов
    Codex окна разные, и на Free вторичного окна нет вовсе.

    `ts` — время самой записи, а не время записи файла: снимок может быть недельной
    давности, и панель обязана показывать возраст цифр честно, иначе «12% за 5 часов»
    из прошлой среды читается как сегодняшнее.

    `model` — модель того хода, к которому относится снимок: от неё зависит, какой пул
    лимитов он измеряет, и панель обязана сказать это словом, а не показать резервные
    проценты как обычные. Пул стоит на каждом окне, а не на всей записи: записи живут дольше
    одного снимка (см. merge_codex_limits), и в одной сходятся окна обоих пулов.
    """
    if not isinstance(snapshot, dict):
        return None
    stamp = int(ts if isinstance(ts, (int, float)) and not isinstance(ts, bool)
                else (now if now is not None else time.time()))
    snapshots = [(codex_pool(model), snapshot)]
    if source == "app-server":
        limits = snapshot.get("rateLimitsByLimitId")
        if limits is None:
            legacy = snapshot.get("rateLimits")
            limits = {legacy.get("limitId") or "codex": legacy} if isinstance(legacy, dict) else {}
        if not isinstance(limits, dict):
            return None
        snapshots = []
        for limit_id, limit in limits.items():
            if not isinstance(limit, dict):
                continue
            if limit_id == "codex":
                snapshots.insert(0, ("codex", limit))
            elif limit_id == "base_model_inference" and limit.get("limitName") == "gpt-reserve":
                snapshots.append(("reserve", limit))
    windows, plan = [], None
    for pool, limit in snapshots:
        for kind in CODEX_WINDOW_KINDS:
            window = codex_window(limit.get(kind), kind, base=stamp)
            if window:
                window["pool"] = pool
                window["ts"] = stamp
                windows.append(window)
        value = limit.get("planType" if source == "app-server" else "plan_type")
        if plan is None and isinstance(value, str) and value.strip():
            plan = value.strip()
    if not windows:
        return None
    record = {"ts": stamp, "source": source, "windows": windows}
    if plan:
        record["plan"] = plan
    return record


def codex_known_windows(record):
    """Окна записи с проставленными пулом и моментом замера, включая файл прошлой версии.

    До этой версии пул был пометкой на всей записи (`reserve: true`), а момент замера — один
    на файл. Такой файл читается как есть: иначе первый же опрос после обновления выбросил бы
    последнее, что мы знали об обычных окнах, — ровно то, чего эта память и не допускает.
    """
    if not isinstance(record, dict) or not isinstance(record.get("windows"), list):
        return []
    fallback_pool = "reserve" if record.get("reserve") is True else "codex"
    fallback_ts = record.get("ts")
    known = []
    for window in record["windows"]:
        if not isinstance(window, dict):
            continue
        used, kind = window.get("used_percentage"), window.get("kind")
        if not isinstance(used, int) or isinstance(used, bool) or not isinstance(kind, str) or not kind:
            continue
        window = dict(window)
        if window.get("pool") not in ("codex", "reserve"):
            window["pool"] = fallback_pool
        if not isinstance(window.get("ts"), (int, float)) or isinstance(window.get("ts"), bool):
            window["ts"] = fallback_ts
        known.append(window)
    return known


def merge_codex_limits(previous, fresh):
    """Свежий снимок поверх последнего известного замера ПО КАЖДОМУ ПУЛУ.

    Уйдя на резерв, Codex присылает снимок только резервного пула: `primary` меряет резерв,
    `secondary` приходит пустым. Записывать такой снимок поверх прежнего значило бы стереть и
    сами обычные окна — а вместе с ними знание о том, что у пятичасового окна есть срок и он
    уже прошёл. Именно это и видел пользователь: панель застревала на резервной шкале и не
    возвращалась к обычным, потому что возвращаться было не к чему.

    Каждый снимок заменяет ВСЕ окна своего пула: после смены подписки недельное окно может
    переехать из secondary в primary, а secondary стать null. Сохранять старый secondary
    означало бы показать второй недельный лимит с прежними процентами и временем сброса.
    Другой пул сохраняется отдельно: резервное primary не заменяет обычное primary.

    Возраст записи — свежайший замер среди окон обычного пула, а при их отсутствии среди всех:
    подпись «measured N min ago» одна на группу, а резерв после смены подписки может неделями
    не обновляться — по самому старому окну панель писала «28d ago» при живых цифрах. Свежий
    резерв при этом обычные окна, снятые утром, не омолаживает. Замеры самих окон не меняются:
    «окно закончилось» Swift решает по ним, а не по возрасту записи.
    """
    def measured(window):
        stamp = window.get("ts")
        return stamp if isinstance(stamp, (int, float)) and not isinstance(stamp, bool) else 0

    previous_windows = codex_known_windows(previous)
    fresh_windows = codex_known_windows(fresh)
    pools = {}
    for windows in (previous_windows, fresh_windows):
        for pool in ("codex", "reserve"):
            snapshot = [w for w in windows if w["pool"] == pool]
            # Старый файл не должен вернуть окно, удалённое новым снимком. Root ts — возраст
            # всей группы, поэтому сравниваются замеры именно этого пула.
            if snapshot and max(map(measured, snapshot)) >= max(map(measured, pools.get(pool, [])), default=0):
                pools[pool] = snapshot
    if not pools:
        return fresh
    record = dict(fresh)
    record["windows"] = sorted((w for snapshot in pools.values() for w in snapshot),
                               key=lambda w: (w["pool"] != "codex",
                                              CODEX_WINDOW_ORDER.get(w["kind"], 2), w["kind"]))
    ordinary = [w for w in record["windows"] if w["pool"] == "codex"]
    stamps = [w["ts"] for w in (ordinary or record["windows"])
              if isinstance(w["ts"], (int, float)) and not isinstance(w["ts"], bool)]
    if stamps:
        record["ts"] = max(stamps)
    # План приходит не в каждом снимке: резервные записи Codex шлют его так же исправно, а
    # вот минимальные — нет, и терять подписку из-за одного бедного снимка незачем.
    if not record.get("plan") and isinstance(previous, dict) and previous.get("plan"):
        record["plan"] = previous["plan"]
    return record


def turn_model(lines):
    """Модель ближайшего хода в строках rollout, идущих ОТ снимка к началу файла.

    Первая встреченная запись `turn_context` и есть тот ход, к которому снимок относится, —
    искать дальше нечего: следующая описывает уже другой ход, а сессия меняет модель прямо
    посреди работы. Так проход и заканчивается на ней, а не дочитывает хвост до начала.
    """
    for raw in lines:
        if b'"turn_context"' not in raw:
            continue
        record = read_json_line(raw)
        payload = record.get("payload") if isinstance(record, dict) else None
        model = payload.get("model") if isinstance(payload, dict) else None
        return model if isinstance(model, str) and model else None
    return None


def codex_file_snapshots(path):
    """Хвост одного файла сессии → новейший снимок КАЖДОГО пула: {пул: (снимок, время, модель)}.

    Форма строки — {"timestamp", "type", "payload"}; payload с запасом разбирается и как
    плоская запись, если Codex однажды перестанет её вкладывать.

    Пул снимка — это модель ближайшей записи `turn_context` ПЕРЕД ним: сессия переезжает на
    резервную модель прямо посреди работы, когда обычный лимит кончился. Идём с конца файла,
    и там эта запись встречается ПОСЛЕ снимка — поэтому снимки копятся, пока не встретится
    turn_context, и достаются ей все разом. Одним проходом, а не поиском модели для каждого
    снимка по отдельности: в хвосте их десятки, и каждый такой поиск шёл бы до начала файла.
    """
    try:
        lines = tail_lines(path)
    except OSError:
        return {}
    found, pending, dated = {}, [], False
    for raw in reversed(lines):
        if b'"rate_limits"' in raw:
            record = read_json_line(raw)
            if not isinstance(record, dict):
                continue
            payload = record.get("payload")
            if not isinstance(payload, dict):
                payload = record
            snapshot = payload.get("rate_limits")
            stamp = parse_reset(record.get("timestamp"))
            if stamp is not None and codex_limits_record(snapshot, ts=stamp):
                pending.append((snapshot, stamp))
        elif b'"turn_context"' in raw:
            dated = True
            if pending:
                model = turn_model([raw])
                found.setdefault(codex_pool(model), pending[0] + (model,))
                pending = []
                if len(found) == 2:
                    return found
    # Снимки, оставшиеся ПЕРЕД уже разобранным ходом, не достаются никому: их собственный
    # turn_context в хвост не попал, пул неизвестен, и назвать их обычными значило бы выдать
    # резервные проценты за обычные — ровно ту ложь, ради которой пулы и заведены. Проверено
    # 13 сентября 2026: в хвосте 17-мегабайтного файла именно так и вышло — 23% резервного
    # пула поехали в файл как обычное недельное окно.
    #
    # А вот хвост вообще без turn_context — другое дело: модель там тоже неизвестна, но и
    # следов резервной сессии в нём нет. Так этот файл читался и до появления пулов.
    if pending and not dated:
        found.setdefault("codex", pending[0] + (None,))
    return found


# Сколько файлов сессий пересматривать в поисках обычных окон. Ходим назад редко (см.
# codex_snapshots), но когда ходим — упереться можно в несколько подряд коротких сессий,
# не доживших до первого снимка лимитов: 13 сентября 2026 таких оказалось три штуки подряд.
CODEX_ROLLOUT_LOOKBACK = 12


def codex_snapshots():
    """Новейшее датированное измерение каждого пула среди последних файлов сессий.

    Mtime задаёт только ограниченную область поиска: старый rollout могут дописать
    служебными событиями без нового замера, поэтому сравниваются timestamps снимков.
    """
    found, seen = {}, False
    for path in rollouts_by_age()[:CODEX_ROLLOUT_LOOKBACK]:
        for pool, (snapshot, ts, model) in codex_file_snapshots(path).items():
            seen = True
            record = codex_limits_record(snapshot, ts=ts, model=model)
            if record and (pool not in found or record["ts"] > found[pool]["ts"]):
                found[pool] = record
    return found, seen


def fetch_codex_limits():
    """Текущая квота через Codex; журналы остаются запасным источником со своим возрастом."""
    now = int(time.time())
    previous = read_json(CODEX_LIMITS)
    record, state, detail = None, "failed", "not_installed"
    if os.path.isdir(CODEX):
        result, error = codex_rpc("account/rateLimits/read", read_only=True)
        now = int(time.time())
        if not error:
            record = codex_limits_record(result, now=now, source="app-server")
            state, detail = ("ok", "") if record else ("empty", "no_windows")
        else:
            detail = error if error in ("timeout", "not_installed", "connection_unavailable",
                                        "connection_closed", "invalid_reply", "rpc_error") else "rpc_error"
        if record is None:
            steps, _ = codex_snapshots()
            record = previous
            known = codex_known_windows(previous)
            measured = max((w["ts"] for w in known if isinstance(w.get("ts"), (int, float))), default=0)
            for step in sorted(steps.values(), key=lambda step: step["ts"]):
                if step["ts"] <= measured:
                    if isinstance(previous, dict) and previous.get("source") == "app-server":
                        continue
                    if step["windows"][0]["pool"] == "reserve" and not any(w["pool"] == "reserve" for w in known):
                        continue
                record = merge_codex_limits(record, step)
    secure_codex_root()
    if record and record != previous:
        write_json(CODEX_LIMITS, record)
    write_json(os.path.join(CODEX_ROOT, "limits-status.json"),
               {"ts": int(time.time()), "state": state, "detail": detail}, mode=0o600)
    if state != "ok":
        return t("codex.absent") if detail == "not_installed" else detail
    windows = ", ".join(f"{w['kind']} {w['used_percentage']}%" for w in record["windows"])
    return t("codex.updated", w=windows)


# ──────────────────────────────────────────────────────────── MCP-серверы Codex

# Читаем через сам Codex, а не его config.toml: системный /usr/bin/python3 на macOS — 3.9,
# tomllib в нём нет, а разбирать TOML руками ради чужого файла со слоями (config.toml
# пользователя, проектный, таблицы плагинов) — ровно та ошибка, которой этот скрипт избегает
# для settings.json. `codex mcp list --json` уже сводит слои в один ответ.
CODEX_MCP = os.path.join(CODEX_ROOT, "mcp.json")
# Сколько ждём app-server. Он поднимает КАЖДЫЙ сервер пользователя, чтобы спросить у них
# список инструментов, поэтому это секунды, а не миллисекунды — но зато Codex сам разбирается
# с транспортом и авторизацией, чего своим stdio-опросом мы не умеем.
CODEX_APP_SERVER_TIMEOUT = 60


def find_codex():
    """Путь к бинарю `codex`, или "" — тем же перебором, что find_claude().

    Последние из известных путей — бинарь внутри десктопного приложения (Codex.app, позже
    ChatGPT.app): оно кладёт `codex` только к себе и в PATH его не добавляет, а скрипт
    запускается приложением без PATH шелла. Висячая ссылка Homebrew на удалённый cask
    `os.path.exists` не проходит и до запуска не доходит.
    """
    for path in ("/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                 os.path.join(HOME, ".local", "bin", "codex"),
                 "/Applications/Codex.app/Contents/Resources/codex",
                 "/Applications/ChatGPT.app/Contents/Resources/codex"):
        if os.path.exists(path):
            return path
    import shutil

    return shutil.which("codex") or ""


def codex_json(args, timeout=30):
    """`codex <args> --json` → разобранный ответ, или (None, ошибка строкой)."""
    import subprocess
    binary = find_codex()
    if not binary:
        return None, t("codex.nobinary")
    try:
        done = subprocess.run([binary] + args + ["--json"], capture_output=True,
                              text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, t("codex.timeout")
    except OSError as exc:
        return None, str(exc)[:200]
    if done.returncode != 0:
        return None, (done.stderr or done.stdout or "").strip()[:200]
    try:
        return json.loads(done.stdout), None
    except ValueError:
        return None, t("codex.badreply")


def codex_mcp_list():
    """Все серверы Codex, включая выключенные, или ([], ошибка)."""
    data, error = codex_json(["mcp", "list"])
    return (data if isinstance(data, list) else []), error


def codex_mcp_get(name):
    """Один сервер целиком: только здесь есть enabled_tools / disabled_tools."""
    data, _ = codex_json(["mcp", "get", name])
    return data if isinstance(data, dict) else {}


def codex_rpc(method, params=None, timeout=30, read_only=False):
    """Один вызов app-server: initialize → initialized → метод → завершение процесса."""
    import subprocess, select
    binary = find_codex()
    if not binary:
        return None, "not_installed" if read_only else t("codex.nobinary")
    try:
        options = ["-c", 'approval_policy="never"', "-c", "features.plugins=false",
                   "-s", "read-only", "-a", "never"] if read_only else []
        proc = subprocess.Popen([binary] + options + ["app-server"], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True, bufsize=1)
    except OSError:
        return None, "connection_unavailable"
    pending = b""
    deadline = time.monotonic() + timeout

    def receive(request_id):
        nonlocal pending
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None, "timeout" if read_only else t("codex.timeout")
            if b"\n" not in pending:
                ready, _, _ = select.select([proc.stdout], [], [], remaining)
                if not ready:
                    return None, "timeout" if read_only else t("codex.timeout")
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk:
                    return None, "connection_closed"
                pending += chunk
                continue
            line, pending = pending.split(b"\n", 1)
            reply = read_json_line(line)
            if not isinstance(reply, dict) or reply.get("id") != request_id or "method" in reply:
                continue
            if "error" in reply:
                return None, "rpc_error"
            if not isinstance(reply.get("result"), dict):
                return None, "invalid_reply" if read_only else t("codex.badreply")
            return reply["result"], None

    try:
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                     "params": {"clientInfo": {"name": "claude-control-bar",
                                                               "title": "Agent Control Bar",
                                                               "version": "1"}}}) + "\n")
        proc.stdin.flush()
        _, error = receive(1)
        if error:
            return None, error
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "initialized"}) + "\n")
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 2, "method": method,
                                     "params": params or {}}) + "\n")
        proc.stdin.flush()
        return receive(2)
    except OSError:
        return None, "connection_unavailable"
    finally:
        try:
            proc.stdin.close()
        except OSError:
            pass
        try:
            proc.terminate()
            proc.wait(2)
        except (OSError, subprocess.TimeoutExpired):
            proc.kill()
            proc.wait(2)
        proc.stdout.close()


def codex_server_status():
    """Живой статус и списки инструментов от `codex app-server`, или ({}, ошибка).

    Таймаут здесь свой и щедрый: этот метод поднимает КАЖДЫЙ настроенный сервер, чтобы
    спросить у него инструменты.
    """
    result, error = codex_rpc("mcpServerStatus/list", timeout=CODEX_APP_SERVER_TIMEOUT)
    if error:
        return {}, error
    rows = (result or {}).get("data")
    if not isinstance(rows, list):
        return {}, t("codex.badreply")
    return {row.get("name"): row for row in rows
            if isinstance(row, dict) and row.get("name")}, None


def codex_state(entry, status):
    """Строка состояния для панели: те же слова, что у серверов Claude.

    `auth` идёт ПЕРЕД проверкой инструментов: сервер за OAuth без логина инструментов не
    отдаёт, и без этой ветки он читался бы как сломанный — человек шёл бы искать сбой,
    которого нет, вместо одной команды `codex mcp login`.
    """
    if not entry.get("enabled", True):
        return "off"
    if (entry.get("auth_status") or (status or {}).get("authStatus")) == "unauthorized":
        return "auth"
    if not status:
        return "unknown"          # app-server не спрашивали или не ответил
    if status.get("toolsError"):
        return "failed"
    runtime = status.get("runtimeStatus")
    if isinstance(runtime, str) and runtime not in ("ready", "running", "ok"):
        return "failed"
    return "ok"


def codex_denied(tools, get):
    """Какие инструменты Codex не отдаст модели, по обоим его спискам.

    allow-список сужает, deny-список вычитает, и применяются они в этом порядке — то есть
    инструмента нет в enabled_tools, значит он уже запрещён, независимо от disabled_tools.
    """
    allowed = get.get("enabled_tools")
    denied = set(get.get("disabled_tools") or [])
    if isinstance(allowed, list):
        denied |= {name for name in tools if name not in allowed}
    return sorted(denied)


def codex_status_text(name, state, status):
    """Строка под курсором: что именно не так с этим сервером, если что-то не так.

    Отдельной функцией, а не тройным условием в словаре: одно такое выражение уже потеряло
    здесь `toolsError` целиком. Питоновский тернарник связывается слабее `or`, и проверка
    «есть ли ключ перевода для server.<state>» проглатывала ветку с настоящим текстом ошибки —
    сломанный сервер показывал пустую подсказку, то есть ровно то место, где человеку нужна
    причина, оставалось пустым.
    """
    if state == "auth":
        return t("codex.login", cmd="codex mcp login " + name)
    # Текст от самого сервера важнее любой нашей формулировки — он и есть причина.
    failure = status.get("toolsError")
    if isinstance(failure, str) and failure.strip():
        return failure.strip()[:200]
    return t("server." + state) if ("server." + state) in STRINGS else ""


def codex_server_record(entry, status, get):
    """Одна запись сервера в форме mcp.json, или None для неожиданной формы."""
    if not isinstance(entry, dict):
        return None
    name = entry.get("name")
    if not isinstance(name, str) or not name:
        return None
    status = status if isinstance(status, dict) else {}
    get = get if isinstance(get, dict) else {}
    raw_tools = status.get("tools")
    tools = sorted(raw_tools) if isinstance(raw_tools, dict) else []
    described = [describe_tool(raw_tools[key]) for key in tools] if tools else []
    described = [tool for tool in described if tool]
    transport = entry.get("transport") if isinstance(entry.get("transport"), dict) else {}
    state = codex_state(entry, status)
    return {
        "name": name,
        # Чем сервер поднимается — то же место, что у Claude занимает target строки списка.
        "target": transport.get("url") or transport.get("command") or "",
        "status": codex_status_text(name, state, status),
        "state": state,
        # Своя группа во вкладке MCP: серверы из плагина Codex человек правит не там, где
        # свои, и смешивать их в одну группу значит обещать переключатель, который уедет
        # в чужую таблицу конфига.
        "source": "codex-plugin" if status.get("pluginId") else "codex",
        "provider": "codex",
        "plugin": status.get("pluginId") or "",
        "disabled": state == "off",
        # None, а не 0: «не знаем» и «инструментов нет» — разные вещи, и ноль на месте первого
        # читается как пустой сервер. Про выключенный сервер мы не знаем ничего: app-server
        # отдаёт по нему пустой набор, потому что не поднимал его, а не потому что он пустой.
        "tools": len(tools) if status and state != "off" else None,
        "toolNames": tools,
        # Codex зовёт инструменты MCP тем же mcp__<server>__<tool>, что Claude, — значит и
        # подпись в панели, и правило совпадают без второй ветки.
        "toolPrefix": name,
        "toolDocs": {tool["name"]: tool["description"] for tool in described},
        "toolParams": {tool["name"]: tool["params"] for tool in described},
        "deniedTools": codex_denied(tools, get),
    }


def codex_mcp_record(entries, statuses, error=None):
    """Вся карта серверов Codex в форме mcp.json."""
    servers = []
    for entry in entries:
        name = entry.get("name") if isinstance(entry, dict) else None
        record = codex_server_record(entry, (statuses or {}).get(name),
                                     codex_mcp_get(name) if name else {})
        if record:
            servers.append(record)
    data = {"checked_at": time.time(),
            "servers": sorted(servers, key=lambda s: s["name"].lower())}
    if error:
        data["error"] = error
    return data


def refresh_codex_mcp():
    """Один проход: спросить Codex о серверах → переписать codex/mcp.json."""
    if not os.path.isdir(CODEX):
        return t("codex.absent")
    entries, list_error = codex_mcp_list()
    if not entries:
        return list_error or t("codex.noservers")
    # Список серверов дешёвый, статус — дорогой. Если app-server не ответил, серверы всё
    # равно записываются: вкладка со списком без счётчиков полезнее пустой вкладки.
    statuses, status_error = codex_server_status()
    secure_codex_root()
    record = codex_mcp_record(entries, statuses, error=list_error or status_error)
    write_json(CODEX_MCP, record)
    return t("codex.servers", n=len(record["servers"]))


def codex_key_path(name, plugin, field):
    """Путь к настройке сервера в config.toml — у плагинного сервера он свой.

    Сервер, приехавший с плагином Codex, объявлен в манифесте плагина, а переопределения
    для него живут в [plugins.<id>.mcp_servers.<name>]. Запись по общему пути создала бы
    ВТОРОЙ, пустой сервер с тем же именем вместо того, чтобы выключить существующий.
    """
    if plugin:
        return f"plugins.{plugin}.mcp_servers.{name}.{field}"
    return f"mcp_servers.{name}.{field}"


def codex_deny_next(current, tool, turn_off, only_changes=False):
    """Новый deny-список после щелчка по одному инструменту.

    Пишется он целиком (config/batchWrite заменяет значение), поэтому строится из текущего,
    а не с нуля. `only_changes` возвращает None, когда список не изменился: писать чужой
    конфиг ради того же значения — лишний повод для вопроса о доверии и лишняя правка файла.
    """
    kept = [name for name in (current or []) if isinstance(name, str)]
    after = sorted(set(kept) | {tool}) if turn_off else [n for n in kept if n != tool]
    if only_changes and sorted(kept) == sorted(after):
        return None
    return after


def codex_config_write(edits):
    """Записать настройки в config.toml через сам Codex, или вернуть ошибку строкой.

    Чужой TOML правит его владелец: app-server сохраняет комментарии, чужие таблицы и
    форматирование — ровно то, чего ручной писатель не удержит. Форма запроса проверена
    живьём на codex-cli 0.154.0: `edits` со `keyPath`, `value` и ОБЯЗАТЕЛЬНЫМ
    `mergeStrategy` (snake_case из плана отвергается с "missing field `mergeStrategy`").
    """
    _, error = codex_rpc("config/batchWrite", {"edits": [
        {"keyPath": key, "value": value, "mergeStrategy": "upsert"}
        for key, value in edits]})
    return error or ""


def codex_server_of(name):
    """Запись сервера из codex/mcp.json — нужна за именем плагина при записи."""
    for server in (read_json(CODEX_MCP, {}) or {}).get("servers") or []:
        if isinstance(server, dict) and server.get("name") == name:
            return server
    return {}


def toggle_codex_server(name, turn_off):
    """Выключить/включить сервер Codex целиком."""
    known = codex_server_of(name)
    if not known:
        raise Refused(t("codex.unknown", name=name))
    error = codex_config_write([(codex_key_path(name, known.get("plugin"), "enabled"),
                                 not turn_off)])
    if error:
        raise Refused(error)
    return True


def toggle_codex_tool(server, tool, turn_off):
    """Убрать/вернуть один инструмент сервера Codex."""
    known = codex_server_of(server)
    if not known:
        raise Refused(t("codex.unknown", name=server))
    current = codex_mcp_get(server).get("disabled_tools") or []
    after = codex_deny_next(current, tool, turn_off, only_changes=True)
    if after is None:
        return False
    error = codex_config_write([(codex_key_path(server, known.get("plugin"),
                                                "disabled_tools"), after)])
    if error:
        raise Refused(error)
    return True


# ──────────────────────────────────────────────────────────── доверие к хукам Codex

# Codex запускает только те хуки, которым человек однажды дал доверие: их хеши он держит
# в своём config.toml, а неодобренный хук молча пропускает. Наш и есть тот хук, который
# пишет файл сессии, — значит без доверия вкладка Sessions пуста, и пустота ничем не
# отличается от «Codex просто не запущен». Отсюда этот файл: панели нужно знать разницу,
# чтобы сказать её словом.
CODEX_HOOKS = os.path.join(CODEX_ROOT, "hooks.json")
# Наши хуки в чужом файле узнаются по пути скрипта, ровно как их ставит hooks/install.js.
OUR_HOOK_SCRIPTS = ("update.js", "lifecycle.js")


def our_hook_command(command):
    """Наш ли это хук — четвёртая копия pointsAt() из install.js/uninstall.js/bootstrap.py.

    Копия, а не импорт: bootstrap.py уезжает в хуки Claude Code, а этот скрипт — в Resources
    приложения, и общего места у них на диске нет. Держать все четыре в согласии обязательно,
    и обе формы записи здесь не для красоты: голое имя якорится справа, иначе "update.js"
    совпадёт с соседским "update.js.bak", а в доме с апострофом install.js пишет ТОЛЬКО
    экранированную форму — без неё счёт молча даёт ноль, то есть подсказка не покажется
    ровно у того, у кого путь непростой.
    """
    if not isinstance(command, str):
        return False
    for script in (os.path.join(core.ROOT, name) for name in OUR_HOOK_SCRIPTS):
        at = command.find(script)
        while at != -1:
            if command[at + len(script):at + len(script) + 1] in ("", " ", "'", '"'):
                return True
            at = command.find(script, at + 1)
        if "'" + script.replace("'", "'\\''") + "'" in command:
            return True
    return False


def codex_hooks_list():
    """Хуки, как их видит сам Codex, или ([], ошибка).

    Спрашиваем Codex, а не читаем его config.toml: доверие в нём хранится ключами вида
    `hooks.json:pre_tool_use:1:0` и хешем команды — внутренние детали чужого формата, и
    повторять их разбор значит тихо разойтись с ним при первом же изменении.
    """
    result, error = codex_rpc("hooks/list")
    if error:
        return [], error
    rows = (result or {}).get("data")
    if not isinstance(rows, list):
        return [], t("codex.badreply")
    return rows, None


def codex_hooks_waiting(groups):
    """НАШИ включённые хуки, которые Codex не запустит, пока их не одобрят.

    Только свои: чужой неодобренный хук — сознательный выбор человека, и ни подсказка, ни
    кнопка одобрения его не касаются. Только включённые: выключенный не запустится и с
    доверием. `modified` — хук, одобренный раньше, чья команда с тех пор поменялась (так
    бывает после обновления приложения): Codex пропускает его так же, как неодобренный.
    """
    waiting = []
    for group in groups or []:
        hooks = group.get("hooks") if isinstance(group, dict) else None
        for hook in hooks if isinstance(hooks, list) else []:
            if not isinstance(hook, dict) or hook.get("enabled") is False:
                continue
            if not our_hook_command(hook.get("command")):
                continue
            if hook.get("trustStatus") in ("untrusted", "modified"):
                waiting.append(hook)
    return waiting


def codex_untrusted_ours(groups):
    """Сколько НАШИХ включённых хуков Codex пропускает за отсутствием одобрения."""
    return len(codex_hooks_waiting(groups))


def fetch_codex_hooks():
    """Один проход: спросить Codex о доверии к хукам → переписать codex/hooks.json."""
    if not os.path.isdir(CODEX):
        return t("codex.absent")
    groups, error = codex_hooks_list()
    # Отказ app-server — это «не знаю», а не «всё одобрено». Ноль поверх честного числа
    # убрал бы подсказку ровно в тот момент, когда она нужна: Codex занят и не ответил.
    if error:
        return error
    secure_codex_root()
    untrusted = codex_untrusted_ours(groups)
    write_json(CODEX_HOOKS, {"ts": int(time.time()), "untrusted": untrusted})
    return t("codex.hooks", n=untrusted)


def approve_codex_hooks():
    """Одобрить в Codex НАШИ ждущие хуки → переспросить Codex и переписать codex/hooks.json.

    Только по нажатию кнопки человеком, никогда при запуске: одобрение остаётся его решением,
    кнопка лишь передаёт его, не заставляя искать экран одобрения в самом Codex. Запись делает
    сам Codex — тот же `config/batchWrite` в `hooks.state`, что шлёт кнопка доверия в его
    приложении, — и хеш берётся из его же `hooks/list`: свой хеш мы не считаем, так что
    одобрено ровно то, что Codex показал бы на своём экране.
    """
    if not os.path.isdir(CODEX):
        return t("codex.absent")
    groups, error = codex_hooks_list()
    if error:
        return error
    trust = {hook["key"]: {"trusted_hash": hook["currentHash"]}
             for hook in codex_hooks_waiting(groups)
             if isinstance(hook.get("key"), str) and isinstance(hook.get("currentHash"), str)}
    if trust:
        error = codex_config_write([("hooks.state", trust)])
        if error:
            return error
    return fetch_codex_hooks()
