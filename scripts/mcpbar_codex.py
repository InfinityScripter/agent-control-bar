#!/usr/bin/env python3
"""Codex-половина mcpbar.py: лимиты из rollout-файлов, MCP-серверы Codex и доверие к нашим хукам.

Отдельный модуль, а не отдельный скрипт: команды по-прежнему приходят через `mcpbar.py`
(codex-limits, codex-mcp, codex-hooks), общие помощники — запись файлов, строки, разбор
времени — берутся оттуда же. Своих зависимостей, кроме стандартной библиотеки, нет.

`ROOT` читается как `core.ROOT` в момент вызова, а не копируется при импорте: тесты подменяют
корень на модуле mcpbar, и копия здесь осталась бы старой.
"""

import glob
import json
import os
import time

import mcpbar as core
from mcpbar import (HOME, SECURE_DIR, STRINGS, Refused, describe_tool, mtime, parse_reset,
                    read_json, read_json_line, t, tail_lines, write_json)


# ──────────────────────────────────────────────────────────── лимиты Codex

# Codex CLI пишет ход сессии в rollout-файл, и каждый ответ модели кладёт туда снимок
# лимитов аккаунта — те же 5 часов и неделя, что показывает его `/status`. Читаем только
# этот файл: ни auth.json, ни сети, ни запуска самого Codex. Цифры уже лежат на диске,
# и спрашивать за них токен пользователя не за что.
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
    used = block.get("used_percent", block.get("used_percentage"))
    try:
        pct = int(round(float(used)))
    # OverflowError — это Infinity: json.loads принимает голый Infinity-токен, и round()
    # на нём кидает именно его. Одно такое окно не должно уносить второе.
    except (TypeError, ValueError, OverflowError):
        return None
    record = {"kind": kind, "used_percentage": max(0, min(100, pct))}
    minutes = block.get("window_minutes")
    # bool — подкласс int, а True в поле длительности окна означает испорченный файл,
    # не окно длиной в минуту.
    if isinstance(minutes, (int, float)) and not isinstance(minutes, bool):
        record["window_minutes"] = int(minutes)
    resets = parse_reset(block.get("resets_at"))
    if resets is None:
        after = block.get("resets_in_seconds", block.get("reset_after_seconds"))
        if isinstance(after, (int, float)) and not isinstance(after, bool):
            resets = int(base + after)
    record["resets_at"] = resets
    return record


def codex_pool(model):
    """Какой пул лимитов мерил ход этой модели: обычный ("codex") или резервный ("reserve").

    Резервный — тот, на который Codex уходит, когда обычный лимит кончился.

    Модель, а не поле снимка, — и это проверено, а не выбрано: 13 сентября 2026 на
    codex-cli 0.154.0 в снимке rollout ОБА пула приходят под одним и тем же
    `limit_id: "codex"`, а соседнее `limit_name`, которое и было бы именем пула, всегда
    приходит пустым. Имя пула Codex сообщает только своему интерфейсу — `hooks/list`-сосед
    `account/rateLimits/read` отдаёт резервный пул как `base_model_inference` с
    `limitName: "gpt-reserve"`, — но это уже сетевой запрос под аккаунтом человека, а
    лимиты здесь читаются с диска и ничего никуда не шлют. Так что различает пулы модель
    хода: резервный тратит только `gpt-reserve`. Совпадение по префиксу — соседние slug'и
    того же семейства должны читаться так же, а вот `gpt-5.6-luna` сюда не входит
    намеренно: это обычная модель, доступная и без всякого резерва.

    Цена выбора названа прямо: переименуют slug — пометка молча пропадёт, и окно снова
    подпишется своей длиной. Поэтому пул, названный в файле, здесь был бы лучше, и если
    Codex когда-нибудь начнёт присылать `limit_name`, читать надо его.
    """
    return "reserve" if isinstance(model, str) and model.startswith("gpt-reserve") else "codex"


# Окна снимка и их порядок — одним списком, из которого считается и ранг для сортировки.
# Порядок нужен дважды: так окна читаются из снимка и так они ложатся в файл, где к ним
# добавляется резервное. Двумя списками эти два места разъезжались бы молча — строки панели
# просто начали бы меняться местами от опроса к опросу.
CODEX_WINDOW_KINDS = ("primary", "secondary")
CODEX_WINDOW_ORDER = {kind: at for at, kind in enumerate(CODEX_WINDOW_KINDS)}


def codex_limits_record(snapshot, ts=None, now=None, model=None):
    """rate_limits из rollout → codex/limits.json.

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
    pool = codex_pool(model)
    windows = []
    for kind in CODEX_WINDOW_KINDS:
        window = codex_window(snapshot.get(kind), kind, base=stamp)
        if window:
            window["pool"] = pool
            window["ts"] = stamp
            windows.append(window)
    if not windows:
        return None
    record = {"ts": stamp, "source": "rollout", "windows": windows}
    plan = snapshot.get("plan_type")
    if isinstance(plan, str) and plan.strip():
        record["plan"] = plan.strip()
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

    Поэтому окна живут дольше снимка, который их принёс, и ключ у них парный — пул и kind:
    резервное окно тоже приходит под kind "primary" и обязано лежать отдельно от обычного.

    Возраст записи — самый СТАРЫЙ из замеров: подпись «measured N min ago» одна на всю
    группу, и свежесть резервного окна ничего не говорит про обычное, снятое утром.
    """
    def measured(window):
        stamp = window.get("ts")
        return stamp if isinstance(stamp, (int, float)) and not isinstance(stamp, bool) else 0

    windows = {}
    for window in codex_known_windows(previous) + codex_known_windows(fresh):
        key = (window["pool"], window["kind"])
        # Побеждает более поздний замер, а не более поздний аргумент: снимки приезжают из
        # разных файлов сессий, и снимок из позавчерашней сессии не должен лечь поверх
        # сегодняшнего только потому, что его прочитали вторым.
        if key not in windows or measured(window) >= measured(windows[key]):
            windows[key] = window
    if not windows:
        return fresh
    record = dict(fresh)
    record["windows"] = sorted(windows.values(),
                               key=lambda w: (w["pool"] != "codex",
                                              CODEX_WINDOW_ORDER.get(w["kind"], 2), w["kind"]))
    stamps = [w["ts"] for w in record["windows"]
              if isinstance(w["ts"], (int, float)) and not isinstance(w["ts"], bool)]
    if stamps:
        record["ts"] = min(stamps)
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
            if isinstance(snapshot, dict):
                pending.append((snapshot, parse_reset(record.get("timestamp"))))
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


def codex_snapshots(known_pools=()):
    """Записи по пулам из файлов сессий → ({пул: запись}, попадался ли снимок вообще).

    Уйдя на резерв, Codex перестаёт присылать обычные окна совсем, и хвост свежего файла
    может целиком состоять из резервных ходов. Тогда последний обычный замер лежит в
    предыдущей сессии, и взять его больше неоткуда — а без него панель не знает даже того,
    что у пятичасового окна есть срок и он уже прошёл.

    Назад идём ровно за обычными окнами и только когда их нет ни здесь, ни в уже записанном
    файле. За резервным окном — никогда: у аккаунта, который ни разу не упирался в лимит,
    его нет вовсе, и поиск повторялся бы на каждом опросе без единого шанса найти.

    Поиск останавливает измеренное окно, а не всякий снимок: Codex пишет снимок и на ходы,
    где мерить нечего (`primary` и `secondary` приходят пустыми, а `limit_id` — чужой). Такой
    снимок принимали за найденный обычный пул, и поиск замирал на первом же коротком ходе,
    не дойдя до сессии, где обычные окна есть. Проверено 13 сентября 2026: ровно так и было.
    """
    found, seen = {}, False
    for path in rollouts_by_age()[:CODEX_ROLLOUT_LOOKBACK]:
        for pool, (snapshot, ts, model) in codex_file_snapshots(path).items():
            seen = True
            record = codex_limits_record(snapshot, ts=ts, model=model)
            if record:
                found.setdefault(pool, record)
        if "codex" in found or "codex" in known_pools:
            break
    return found, seen


def fetch_codex_limits():
    """Один проход: файлы сессий Codex → codex/limits.json. Молчалив при любом сбое."""
    if not os.path.isdir(CODEX):
        return t("codex.absent")
    previous = read_json(CODEX_LIMITS)
    steps, seen = codex_snapshots({w["pool"] for w in codex_known_windows(previous)})
    if not steps:
        return t("codex.empty") if seen else t("codex.nosnapshot")
    record = previous
    # От старого замера к свежему: последним слоем должен лечь самый свежий снимок — от него
    # запись берёт и план, и источник.
    for step in sorted(steps.values(), key=lambda step: step["ts"]):
        record = merge_codex_limits(record, step)
    secure_codex_root()
    write_json(CODEX_LIMITS, record)
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


def codex_rpc(method, params=None, timeout=30):
    """Один вызов метода `codex app-server` по stdio → (result, ошибка строкой).

    JSON-RPC: initialize → нужный метод → выходим. Поля ответов в camelCase — проверено
    на codex-cli 0.154.0; snake_case там не встречается.

    Три вызывающих на три разных метода: статус серверов, запись настроек и список хуков.
    Разбор ответа у каждого свой, а поднять процесс, дождаться СВОЕГО id среди чужих
    уведомлений и погасить процесс — общее, и в трёх копиях расходилось бы построчно.
    """
    import subprocess, threading, queue
    binary = find_codex()
    if not binary:
        return None, t("codex.nobinary")
    try:
        proc = subprocess.Popen([binary, "app-server"], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True, bufsize=1)
    except OSError as exc:
        return None, str(exc)[:200]
    lines = queue.Queue()
    threading.Thread(target=lambda: [lines.put(line) for line in proc.stdout],
                     daemon=True).start()
    try:
        for request in ({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                         "params": {"clientInfo": {"name": "claude-control-bar",
                                                   "title": "Claude Control Bar",
                                                   "version": "1"}}},
                        {"jsonrpc": "2.0", "id": 2, "method": method,
                         "params": params or {}}):
            proc.stdin.write(json.dumps(request) + "\n")
            proc.stdin.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                line = lines.get(timeout=max(0.1, deadline - time.time()))
            except Exception:
                break
            reply = read_json_line(line)
            # Между ответами приходят уведомления (remoteControl/status/changed и прочие);
            # ждём именно свой id, а не первую строку, похожую на ответ.
            if not isinstance(reply, dict) or reply.get("id") != 2:
                continue
            if reply.get("error"):
                return None, str(reply["error"].get("message", ""))[:200]
            return reply.get("result"), None
        return None, t("codex.timeout")
    except OSError as exc:
        return None, str(exc)[:200]
    finally:
        # Та же лестница, что в ask_server_for_tools: закрыть stdin, попросить, добить.
        try:
            proc.stdin.close()
        except Exception:
            pass
        try:
            proc.terminate()
            proc.wait(2)
        except Exception:
            try:
                proc.kill()
                proc.wait(2)
            except Exception:
                pass


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
