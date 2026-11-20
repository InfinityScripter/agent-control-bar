#!/usr/bin/env python3
"""Погашение накопленных сбросов лимитов: команды `claude-reset-credit <id>` и `codex-reset-credit`.

Модуль mcpbar.py, как и mcpbar_codex.py: команды приходят через него, общие помощники берутся
оттуда же, `ROOT` читается в момент вызова.

Погашение тратит сброс на настоящем аккаунте и необратимо, поэтому весь модуль — про то, чтобы
одно нажатие не могло потратить два сброса. Порядок и правила перенесены из T3 Code
(resetCreditCoordinator.ts, claudeResetCredits.ts, CodexDriver.ts), но там их держит
долгоживущий сервер в памяти, а здесь каждый запуск — отдельный процесс, и то же самое лежит
в файлах рядом с лимитами (под `codex/` — для Codex):

    reset-credit.lock          замок: одна попытка на аккаунт, вторая сразу получает `busy`
    reset-credit-pending.json  ключ идемпотентности попытки, записанный ДО отправки
    reset-credit-result.json   исход каждого запуска; stdout приложение не читает

Запрос к Anthropic за пределами Linux никем не проверен: T3 на macOS его не шлёт вовсе, потому
что не умеет читать Keychain.
"""

import contextlib
import json
import os
import re
import sys
import time
import uuid

import mcpbar as core
import mcpbar_codex as codex
from mcpbar import SECURE_DIR, SECURE_FILE, finite, read_json, write_json

OUTCOMES = ("reset", "nothingToReset", "noCredit", "alreadyRedeemed")
REQUEST_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")
# Сколько живёт сохранённый ключ. Как долго его помнят сами сервисы, неизвестно: повтор со
# слишком старым ключом был бы уже новой заявкой и стоил бы второго сброса.
KEY_TTL = 24 * 3600

RESET_URL = "https://api.anthropic.com/api/organizations/{organization}/reset_rate_limits"
# Ожидания конечны: зависший вызов иначе держал бы замок аккаунта бесконечно.
CLAIM_TIMEOUT = 25
CONSUME_TIMEOUT = 20
CLAIM_OUTCOMES = {"reset": "reset", "not_limited": "nothingToReset",
                  "already_used": "alreadyRedeemed", "ineligible": "noCredit"}
CLAIM_REFUSALS = {"cooldown": "coolingDown", "unavailable": "unconfirmed"}
# После этих ошибок неизвестно, дошла ли заявка до Claude. Ключ остаётся, и повтор с ним же
# получит `already_used`, а не потратит второй сброс. Любой другой ответ определённый.
CLAIM_UNSETTLED = ("requestFailed", "unconfirmed")


def write_result(root, provider, credit_id, outcome, error, confirmed):
    write_json(os.path.join(root, "reset-credit-result.json"),
               {"ts": int(time.time()), "provider": provider, "creditId": credit_id,
                "outcome": outcome, "error": error, "confirmed": confirmed}, mode=SECURE_FILE)


@contextlib.contextmanager
def account_lock(root):
    """True под замком аккаунта, False — когда его держит другой процесс.

    Не ждём: вторая попытка, дождавшись первой, отправила бы ещё одну заявку. flock
    отпускается закрытием дескриптора, то есть и при аварийном выходе.
    """
    import fcntl

    path = os.path.join(root, "reset-credit.lock")
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT, SECURE_FILE), "w") as fh:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            yield False
        else:
            yield True


def pending_key(root, credit_id):
    """Ключ идемпотентности попытки: сохранённый, пока он годен, иначе новый.

    Новый ложится на диск до отправки запроса: процесс, убитый посреди вызова, не должен
    забыть ключ заявки, которая могла дойти. Сохранённый годен сутки и только для того же
    гранта — старый ключ с другим грантом был бы новой заявкой под чужим именем.
    """
    path = os.path.join(root, "reset-credit-pending.json")
    stored, now = read_json(path, {}), time.time()
    key, created = stored.get("key"), stored.get("createdAt")
    if (isinstance(key, str) and REQUEST_ID.fullmatch(key) and stored.get("creditId") == credit_id
            and finite(created) and 0 <= now - created < KEY_TTL):
        return key
    key = str(uuid.uuid4())
    write_json(path, {"key": key, "creditId": credit_id, "createdAt": int(now)}, mode=SECURE_FILE)
    return key


def drop_key(root):
    # Ключ убирают после определённого ответа сервиса, и сбой удаления этот ответ не отменяет:
    # сброс уже потрачен, исход обязан дойти до файла. Уцелевший ключ безопасен — повтор с ним
    # назовёт ту же заявку, а не новую.
    try:
        os.unlink(os.path.join(root, "reset-credit-pending.json"))
    except OSError:
        pass


def redeem(provider, root, credit_id, failure, attempt, limits_are_fresh):
    """Одна попытка под замком аккаунта → (исход, ошибка). Файл исхода пишется при любом завершении,
    кроме одного: запуск, ничего не отправивший, не стирает запись о заявке, оставшейся открытой.

    `attempt()` возвращает (исход, ошибка, был ли вызов сервиса). После вызова, давшего
    исход, лимиты перечитываются здесь же: приложение ждёт конца команды и свежих цифр.
    Не подтверждённый `reset` — всё равно исход: сброс потрачен, не обновились только цифры.
    """
    outcome, error, confirmed, called = None, failure, False, True
    try:
        with account_lock(root) as free:
            if not free:
                error, called = "busy", False
            else:
                outcome, error, called = attempt()
                confirmed = outcome is not None and outcome != "reset"
                if outcome and called:
                    # Исход на диск до перечитывания: оно длится секунды, а процесс, убитый
                    # за это время, иначе унёс бы с собой знание о потраченном сбросе.
                    write_result(root, provider, credit_id, outcome, None, confirmed)
                    try:
                        confirmed = limits_are_fresh(outcome) or confirmed
                    except Exception:  # noqa: BLE001 — исход уже есть, сбой чтения его не отменяет
                        pass
    finally:
        # По записи о заявке, которая могла дойти, приложение не даёт нажать другой сброс. Отказ
        # до отправки (нет CLI, нет входа, занят замок) о той заявке ничего не узнал: её запись
        # остаётся, пока её ключ на диске, а причину отказа этот запуск называет в stderr.
        left = read_json(os.path.join(root, "reset-credit-result.json"), {})
        if (called or outcome or left.get("error") not in CLAIM_UNSETTLED
                or not os.path.exists(os.path.join(root, "reset-credit-pending.json"))):
            write_result(root, provider, credit_id, outcome, error, confirmed)
    return outcome, error


# ──────────────────────────────────────────────────────────── Claude

def claude_version():
    """Версия установленного CLI для User-Agent заявки, либо None.

    Неудачный запуск версии не сообщает: вывод может принадлежать обёртке, а не Claude Code.
    """
    import subprocess

    binary = core.find_claude()
    if not binary:
        return None
    try:
        done = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if done.returncode != 0:
        return None
    match = re.search(r"\bv?(\d+\.\d+\.\d+)\b", done.stdout + "\n" + done.stderr, re.ASCII)
    return match.group(1) if match else None


def claude_organization():
    """organizationUuid из ~/.claude.json → (значение или None, читается ли файл).

    Нет файла или нет входа — «не вошёл»; файл есть, но форма не та — «аккаунт не читается».
    """
    try:
        with open(core.CONFIG) as fh:
            config = json.load(fh)
    except FileNotFoundError:
        return None, True
    except (OSError, ValueError):
        return None, False
    account = config.get("oauthAccount", {}) if isinstance(config, dict) else None
    organization = account.get("organizationUuid", "") if isinstance(account, dict) else None
    if not isinstance(organization, str):
        return None, False
    return organization.strip() or None, True


def claude_claim(organization, token, version, credit_id, key):
    """Заявка на сброс → (исход, ошибка). Сырой ответ сервера дальше категории не уходит."""
    import urllib.error
    import urllib.parse
    import urllib.request

    request = urllib.request.Request(
        RESET_URL.format(organization=urllib.parse.quote(organization, safe="")),
        data=json.dumps({"program": "cedar_ember", "grant_id": credit_id, "request_id": key}).encode("utf-8"),
        method="POST",
        headers={"Authorization": f"Bearer {token}",
                 "anthropic-beta": "oauth-2025-04-20",
                 "User-Agent": f"claude-cli/{version} (external, cli)",
                 "Content-Type": "application/json"})
    try:
        with core.no_redirect_opener().open(request, timeout=CLAIM_TIMEOUT) as response:
            answer = json.loads(response.read(65536).decode("utf-8"))
    except urllib.error.HTTPError as exc:
        exc.close()
        return None, {429: "rateLimited", 401: "signedOut", 403: "signedOut"}.get(exc.code, "requestFailed")
    except Exception:  # noqa: BLE001 — сеть, таймаут, редирект, не-JSON: дошла ли заявка, неизвестно
        return None, "requestFailed"
    result = answer.get("result") if isinstance(answer, dict) else None
    if not isinstance(result, str):
        return None, "requestFailed"
    if result in CLAIM_OUTCOMES:
        return CLAIM_OUTCOMES[result], None
    return None, CLAIM_REFUSALS.get(result, "requestFailed")


def claude_attempt(credit_id):
    """Проверки в порядке T3; ключ появляется только когда всё готово к отправке.

    Отказ до отправки сохранённый ключ не трогает: он мог остаться от заявки, которая дошла,
    и следующий повтор обязан назвать её тем же именем.
    """
    credits = read_json(core.account_path(), {}).get("resetCredits")
    options = credits.get("options") if isinstance(credits, dict) else None
    published = [option.get("creditId") for option in (options if isinstance(options, list) else ())
                 if isinstance(option, dict)]
    # Тратится только то, что последний опрос сам предложил: id приходит из командной строки.
    if credit_id not in published:
        return "noCredit", None, False
    version = claude_version()
    if not version:
        # CLI не найден, завис или не назвал версию. Заявка не уходила, о сбросах ничего не
        # известно: «сброса нет» было бы выдумкой, поэтому это сбой, а не исход.
        return None, "cliUnavailable", False
    if not core.GRANT_ID.fullmatch(credit_id):
        return None, "malformedCredit", False
    token = core.oauth_token()
    if core.OAUTH_FACTS.get("unreadable"):
        return None, "loginUnreadable", False
    organization, readable = claude_organization()
    if not readable:
        return None, "accountUnreadable", False
    if not token or not organization:
        return None, "signedOut", False
    outcome, error = claude_claim(organization, token, version, credit_id,
                                  pending_key(core.ROOT, credit_id))
    if error not in CLAIM_UNSETTLED:
        drop_key(core.ROOT)
    return outcome, error, True


def claude_limits_are_fresh(outcome):
    """Ровно один опрос сразу после ответа, каким бы он ни был: эндпоинт лимитов нельзя
    спрашивать часто, остальное доделает обычный пятиминутный опрос."""
    core.fetch_limits()
    return read_json(core.LIMITS_STATUS, {}).get("state") == "ok"


def redeem_claude(credit_id):
    os.makedirs(core.ROOT, mode=SECURE_DIR, exist_ok=True)
    return redeem("claude", core.ROOT, credit_id if core.GRANT_ID.fullmatch(credit_id) else None,
                  "requestFailed", lambda: claude_attempt(credit_id), claude_limits_are_fresh)


# ──────────────────────────────────────────────────────────── Codex

def codex_attempt():
    """Заявка через собственный app-server Codex: вход и токен остаются у него.

    Грант не называем — следующий выбирает сам Codex. Любой сбой оставляет ключ: дошла ли
    заявка, по сбою app-server не понять.
    """
    if not os.path.isdir(codex.CODEX):
        return None, "not_installed", False
    key = pending_key(codex.CODEX_ROOT, None)
    # Обычный app-server, не read-only: погашение — запись. experimentalApi — как у T3,
    # единственной конфигурации, в которой этот метод кто-либо вызывал.
    result, error = codex.codex_rpc("account/rateLimitResetCredit/consume", {"idempotencyKey": key},
                                    timeout=CONSUME_TIMEOUT, categories=True,
                                    capabilities={"experimentalApi": True})
    if error:
        return None, error if error in codex.CODEX_RPC_ERRORS else "rpc_error", True
    outcome = result.get("outcome")
    if not isinstance(outcome, str) or outcome not in OUTCOMES:
        return None, "invalid_reply", True
    drop_key(codex.CODEX_ROOT)
    return outcome, None, True


def codex_limits_are_fresh(outcome):
    """После `reset` прежние окна заведомо устарели: до четырёх чтений с паузами 1, 2 и 4 с,
    пока app-server не ответит свежими. Остальным исходам хватает одного чтения."""
    for wait in (0, 1, 2, 4) if outcome == "reset" else (0,):
        if wait:
            time.sleep(wait)
        codex.fetch_codex_limits()
        status = read_json(os.path.join(codex.CODEX_ROOT, "limits-status.json"), {})
        if status.get("state") == "ok":
            return True
    return False


def redeem_codex():
    codex.secure_codex_root()
    return redeem("codex", codex.CODEX_ROOT, None, "rpc_error", codex_attempt, codex_limits_are_fresh)


def command(word, argv):
    """Код 0 — только когда исход получен. В вывод идёт слово-категория, не текст сервера."""
    outcome, error = redeem_codex() if word == "codex-reset-credit" else redeem_claude(argv[0] if argv else "")
    if outcome:
        print(outcome)
        return 0
    # В stderr: приложение пишет его в лог только при ненулевом выходе.
    print(f"{word}: {error}", file=sys.stderr)
    return 1
