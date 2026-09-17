#!/usr/bin/env python3
"""Claude Control Bar — MCP-бэкенд: состояние серверов, инструменты, переключатели.

Работает только со стандартной библиотекой: скрипт вызывается из GUI-приложения,
где PATH урезан и никакого pyenv нет.

Разделение труда в приложении: сессии и их контекст ведут Node-хуки (state.d/),
MCP-картину ведёт этот скрипт (mcp.json), рисует всё Swift.

Команды:
    refresh          проверить всё заново и переписать mcp.json (медленно, ~7 сек)
    report           человекочитаемая карта
    toggle-server    выключить/включить сервер целиком
    toggle-tool      выключить/включить отдельный инструмент
    statusline       перехват лимитов: --install / --uninstall / без флага — статус
    limits           спросить лимиты аккаунта у эндпоинта и переписать limits.json
    codex-limits     снять лимиты Codex со свежего rollout и переписать codex/limits.json
    codex-mcp        серверы MCP Codex: refresh | toggle-server | toggle-tool
    codex-hooks      спросить Codex, каким нашим хукам он не доверяет; approve — одобрить их
    doctor           проверить окружение и показать, что откуда берётся
"""

import glob
import hashlib
import json
import os
import re
import sys
import time

HOME = os.path.expanduser("~")
CLAUDE = os.path.join(HOME, ".claude")
ROOT = os.path.join(CLAUDE, "control-bar")
STATE = os.path.join(ROOT, "mcp.json")
LIMITS = os.path.join(ROOT, "limits.json")
# Сессии ведут Node-хуки: один файл на сессию, тот же каталог читает приложение.
# Свой реестр сессий скрипт не держит намеренно — два источника правды разошлись бы.
SESSIONS = os.path.join(ROOT, "state.d")
LOCK = os.path.join(ROOT, "refresh.lock")

CONFIG = os.path.join(HOME, ".claude.json")
SETTINGS = os.path.join(CLAUDE, "settings.json")
# Приставка наших бэкапов settings.json — всегда SETTINGS + ".bak-control-bar", и всегда
# собирается НА МЕСТЕ вызова, не константой: тесты подменяют SETTINGS на лету, а константа,
# вычисленная при импорте, один раз уже увела ротацию и свип в настоящий ~/.claude — с
# удалением настоящих бэкапов. Тем же литералом (другой язык) пользуется install.js.
NEEDS_AUTH = os.path.join(CLAUDE, "mcp-needs-auth-cache.json")
MCP_LOGS = os.path.join(HOME, "Library", "Caches", "claude-cli-nodejs", "*", "mcp-logs-*")
DESKTOP_SESSIONS = os.path.join(
    HOME, "Library", "Application Support", "Claude", "claude-code-sessions"
)
TRANSCRIPTS = os.path.join(CLAUDE, "projects", "*", "*.jsonl")

TTL = int(os.environ.get("CONTROL_BAR_TTL", "600"))

OK, FAILED, PENDING, AUTH, OFF = "ok", "failed", "pending", "auth", "off"
UNKNOWN = "unknown"

# Насколько состояние плохо. Нужно там, где два одноимённых сервера сливаются в одну строку:
# остаётся худшее из состояний, иначе зелёный молча закрывает собой упавший сервер.
SEVERITY = {OK: 0, PENDING: 1, AUTH: 1, FAILED: 2}


# ──────────────────────────────────────────────────────────── язык

LANGS = ("en", "ru")


def detect_lang():
    """Язык интерфейса. Приложение и отчёт должны говорить одинаково."""
    forced = os.environ.get("CONTROL_BAR_LANG", "").lower()[:2]
    if forced in LANGS:
        return forced
    for var in ("LC_ALL", "LC_MESSAGES", "LANG"):
        if os.environ.get(var, "").lower().startswith("ru"):
            return "ru"
    # GUI-процессу переменных локали не достаётся — спрашиваем систему напрямую.
    try:
        import plistlib

        prefs = os.path.join(HOME, "Library", "Preferences", ".GlobalPreferences.plist")
        with open(prefs, "rb") as fh:
            languages = plistlib.load(fh).get("AppleLanguages") or []
        if languages and str(languages[0]).lower().startswith("ru"):
            return "ru"
    except Exception:
        pass
    return "en"


LANG = detect_lang()

STRINGS = {
    "group.user": ("LOCAL CONFIG  ~/.claude.json", "ЛОКАЛЬНЫЙ КОНФИГ  ~/.claude.json"),
    "group.claude.ai": ("CLAUDE.AI CONNECTORS", "КОННЕКТОРЫ CLAUDE.AI"),
    "group.plugin": ("FROM PLUGINS", "ОТ ПЛАГИНОВ"),
    "group.project": ("PROJECT  .mcp.json", "ПРОЕКТНЫЕ  .mcp.json"),
    "head.auth": ("WAITING FOR AUTHORISATION", "ЖДУТ АВТОРИЗАЦИИ"),
    "head.sessions": ("SESSIONS", "СЕССИИ"),
    "head.limits": ("LIMITS", "ЛИМИТЫ"),
    "auth.hint": ("/mcp to authorise", "/mcp → авторизовать"),
    "server.off": ("disabled", "выключен"),
    "server.restart": ("on, from the next session", "включён, со следующей сессии"),
    "server.project": ("project {dir}", "проект {dir}"),
    "open.settings": ("Open settings.json", "Открыть settings.json"),
    "server.muted": ("({n} disabled)", "({n} выключено)"),
    "tools.none": ("— tools", "— инстр."),
    "session.context": ("context {pct}%", "контекст {pct}%"),
    "session.spent": ("{used} of {total}", "{used} из {total}"),
    "limits.five": ("5 hours", "5 часов"),
    "limits.seven": ("7 days", "7 дней"),
    "limits.fable": ("Fable, 7 days", "Fable, 7 дней"),
    "limits.age": ("data {n} min old, source: {src}", "данным {n} мин, источник: {src}"),
    "limits.none": ("not measured yet", "ещё не измерены"),
    "error.check": ("Check failed: {e}", "Ошибка проверки: {e}"),
    "check.running": ("a check is already running — try again in a few seconds",
                      "проверка уже идёт — повтори через несколько секунд"),
    "summary": ("Total: {live}/{total} connected, {tools} {word}",
                "Итого: {live}/{total} на связи, {tools} {word}"),
    "summary.off": (", {n} disabled", ", {n} выключено"),
    "summary.auth": (", {n} unauthorised", ", {n} без авторизации"),
    "checked": ("Checked {n} s ago.", "Проверено {n} сек назад."),
    "err.nobinary": ("claude binary not found", "не нашла бинарь claude"),
    "err.timeout": ("claude mcp list timed out", "claude mcp list не ответил вовремя"),
    "err.empty": ("empty output", "пустой вывод"),
    "doc.binary": ("claude binary", "бинарь claude"),
    "doc.settings": ("settings", "настройки"),
    "doc.state": ("state", "состояние"),
    "doc.sessions": ("sessions registered", "сессий зарегистрировано"),
    "doc.off": ("servers disabled", "выключено серверов"),
    "doc.rules": ("tool rules", "правил на инструменты"),
    "doc.windows": ("model windows cached", "окон моделей в кеше"),
    "doc.missing": ("NOT FOUND", "НЕ НАЙДЕН"),
    "doc.nofile": ("no file", "нет файла"),
    "doc.nostate": ("not collected yet", "ещё не собрано"),
    "lang": ("interface language", "язык интерфейса"),
    "sl.nowrapper": ("statusline.sh not found next to the script",
                     "statusline.sh не найден рядом со скриптом"),
    "sl.already": ("already installed", "уже установлен"),
    "sl.busy": ("settings.json is being edited by someone else — nothing written",
                "settings.json прямо сейчас правит кто-то ещё — ничего не записано"),
    "sl.installed": ("installed; previous command saved: {cmd}",
                     "установлен; прежняя команда сохранена: {cmd}"),
    "sl.nocommand": ("(there was none)", "(её не было)"),
    "sl.notours": ("not installed — the statusLine is not ours, leaving it alone",
                   "не установлен — statusLine не наш, ничего не трогаю"),
    "sl.changed": ("not removed — the statusLine was changed after install, leaving it alone",
                   "не снят — statusLine изменён после установки, ничего не трогаю"),
    "sl.restored": ("restored: {cmd}", "возвращено: {cmd}"),
    "sl.removed": ("(statusLine removed)", "(statusLine удалён)"),
    "sl.on": ("capture on", "перехват включён"),
    "sl.off": ("capture off", "перехват выключен"),
    "sl.current": ("current command: {cmd}", "текущая команда: {cmd}"),
    "sl.unset": ("(statusLine not configured)", "(statusLine не настроен)"),
    "lim.notoken": ("no token: Claude Code is not logged in via browser OAuth",
                    "нет токена: Claude Code не залогинен через браузерный OAuth"),
    "lim.failed": ("poll failed: {e}", "опрос не удался: {e}"),
    "lim.empty": ("the response carried no limit windows", "ответ без единого окна лимитов"),
    "lim.updated": ("updated: {w}", "обновлено: {w}"),
    "codex.absent": ("no ~/.codex — Codex CLI is not installed here",
                     "нет ~/.codex — Codex CLI на этой машине не стоит"),
    "codex.nosnapshot": ("no rollout carries a limits snapshot yet",
                         "ни в одном rollout ещё нет снимка лимитов"),
    "codex.empty": ("the snapshot carried no limit windows",
                    "снимок без единого окна лимитов"),
    "codex.updated": ("updated: {w}", "обновлено: {w}"),
    "codex.nobinary": ("codex not found on PATH", "не нашла codex в PATH"),
    "codex.timeout": ("codex did not answer in time", "codex не ответил вовремя"),
    "codex.badreply": ("codex replied in a shape this build does not know",
                       "codex ответил в форме, которую эта сборка не знает"),
    "codex.noservers": ("no MCP servers in the Codex config",
                        "в конфиге Codex нет MCP-серверов"),
    "codex.servers": ("updated: {n} Codex MCP server", "обновлено: серверов MCP Codex — {n}"),
    "codex.login": ("run {cmd}", "выполни {cmd}"),
    "codex.unknown": ("no Codex server named {name} — refresh first",
                      "сервера Codex с именем {name} нет — сначала refresh"),
    "codex.hooks": ("hooks Codex has not been told to trust: {n}",
                    "хуков без доверия Codex: {n}"),
    "doc.codex": ("codex rollout", "rollout codex"),
    "doc.codexmcp": ("codex mcp servers", "серверы mcp codex"),
    "doc.codexhooks": ("codex hooks untrusted", "хуки codex без доверия"),
}


def t(key, **kw):
    text = STRINGS[key][0 if LANG == "en" else 1]
    return text.format(**kw) if kw else text


def plural_tools(count):
    if LANG == "en":
        return "tool" if count == 1 else "tools"
    tail, hundred = count % 10, count % 100
    if 11 <= hundred <= 14 or tail == 0 or tail >= 5:
        return "инструментов"
    return "инструмент" if tail == 1 else "инструмента"


# ──────────────────────────────────────────────────────────── общее

SECURE_DIR, SECURE_FILE = 0o700, 0o600


def secure_root(path=None):
    """Каталог состояния закрыт для всех, кроме владельца — снаружи и внутри.

    Домашний каталог на macOS открыт группе staff, а в ней состоят все локальные
    пользователи машины. Внутри лежат рабочие каталоги сессий и пути к их транскриптам,
    проценты лимитов аккаунта и — при CONTROL_BAR_DEBUG=1 — обрывки набранного.
    Рождалось это всё с umask, то есть 0644.

    Проход делается на каждый refresh, а не только при создании: обновление версии само по
    себе прав не чинит, и без прохода исправленными оказались бы только новые установки.
    """
    root = path or ROOT
    try:
        os.makedirs(root, mode=SECURE_DIR, exist_ok=True)
        os.chmod(root, SECURE_DIR)
    except OSError:
        return
    for current, dirs, files in os.walk(root):
        for name in dirs + files:
            target = os.path.join(current, name)
            # Симлинк пропускаем: chmod пошёл бы по ссылке и переписал права чужому файлу.
            if os.path.islink(target):
                continue
            try:
                os.chmod(target, SECURE_DIR if os.path.isdir(target) else SECURE_FILE)
            except OSError:
                # Ошибка на одном файле — не повод бросить остальные: хуки пишут сюда
                # параллельно, и исчезнувший временный файл оставлял бы весь каталог
                # незакрытым до следующего прохода.
                continue
    # Бэкапы settings.json живут не под ROOT, а рядом с оригиналом — и первый из них,
    # рождённый install.js до фикса прав, лежал 0644 с полным снимком настроек навсегда:
    # ротация честно «чужого не трогает», а перечитать права было некому. Файл с нашим
    # именным префиксом — наш; владельческие биты оставляем как есть, группу и остальных
    # снимаем. Симлинк пропускаем по той же причине, что и выше. chmod — только когда
    # есть что снимать: безусловный дёргал ctime каждых десяти минут на давно чистых
    # файлах. Провал chmod на снимке с секретами — не гонка ротации, а событие: одна
    # строка в problems.log, не молчание.
    for backup in glob.glob(SETTINGS + ".bak-control-bar*"):
        if os.path.islink(backup):
            continue
        try:
            mode = os.stat(backup).st_mode
        except OSError:
            continue
        if not mode & 0o077:
            continue
        try:
            os.chmod(backup, mode & 0o700)
        except FileNotFoundError:
            continue
        except OSError as exc:
            try:
                with open(os.path.join(ROOT, "problems.log"), "a") as fh:
                    fh.write(f"could not restrict permissions on {backup}: {exc}\n")
            except OSError:
                pass


def read_json(path, default=None):
    """Чтение с проверкой формы: распарсенное не того типа, что default, — это default.

    Половину этих файлов пишут чужие программы, половину может править человек: массив
    наверху там, где ждали словарь, ронял AttributeError'ом весь refresh (кеш десктопа и
    ответ лимитов — дважды чинившийся точечно один и тот же класс). default=None оставляет
    разбор как есть — три вызова осознанно различают «файла нет» и «форма не та».
    """
    try:
        with open(path) as fh:
            parsed = json.load(fh)
    except Exception:
        return default
    if default is not None and not isinstance(parsed, type(default)):
        return default
    return parsed


def mtime(path):
    """Время правки, 0 для исчезнувшего файла.

    Ключ сортировки не имеет права бросать. Логи MCP и транскрипты переписывает Claude Code, и
    файл, пропавший между glob() и sorted(), ронял OSError'ом весь refresh — вместе с картой,
    которую он собирал.
    """
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0


def write_json(path, data, indent=None, mode=None):
    # Симлинк разрешается до цели: settings.json часто указывает в ~/dotfiles, а os.replace
    # заменяет саму ссылку обычным файлом — оригинал в dotfiles остаётся старым, и человек
    # тихо теряет синхронизацию своих настроек.
    path = os.path.realpath(path)
    # mode= как у secure_root(): первым командой на свежей машине может оказаться `limits`
    # или `doctor`, и без него ~/.claude/control-bar рождался с umask-правами (0755) и лежал
    # открытым staff-группе до первого refresh. На уже существующие каталоги mode не влияет.
    os.makedirs(os.path.dirname(path), mode=SECURE_DIR, exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    # Права исходника переезжают на замену. Временный файл рождается с umask процесса,
    # и без этого settings.json с правами 0600 после первого переключателя становился
    # 0644 — а в нём бывают env-значения MCP-серверов.
    if mode is None:
        try:
            mode = os.stat(path).st_mode & 0o777
        except OSError:
            pass
    # Дескриптор с 0600, а не open() с umask: содержимое попадает на диск раньше chmod,
    # и в этот промежуток временный файл иначе лежал бы читаемым для всей машины.
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=indent)
        if indent:
            fh.write("\n")
    if mode is not None:
        os.chmod(tmp, mode)
    os.replace(tmp, path)


def read_settings_for_edit():
    """Настройки под изменение: `(данные, отпечаток)`, либо `(None, "")` — не трогать.

    read_json() глушит любую ошибку и возвращает default — то есть «файла нет». Для чтения
    это безобидно, для записи катастрофа: человек правит settings.json
    руками, между двумя нажатиями файл невалиден, и один клик по переключателю заменял все
    его настройки единственным правилом deny. Здесь отсутствие файла и битый разбор — разные
    ответы, и второй означает отказ от операции.

    Отпечаток берётся с байтов и проверяется перед самой заменой: блокировка держит только
    процессы панели, а Claude Code и редактор человека её не берут.
    """
    try:
        with open(SETTINGS, "rb") as fh:
            raw = fh.read()
    except FileNotFoundError:
        return {}, ""
    except OSError:
        return None, ""
    try:
        return json.loads(raw), hashlib.sha256(raw).hexdigest()
    except ValueError:
        return None, ""


def settings_fingerprint():
    try:
        with open(SETTINGS, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except FileNotFoundError:
        return ""
    except OSError:
        return None


def write_settings(data, expect=None):
    """settings.json человек правит руками — значит и мы пишем его для человека.

    Компактной записью первый же переключатель схлопывал файл пользователя в одну строку:
    ни прочитать, ни сравнить в git. Отступ тот же, что ставит сам Claude Code и hooks/install.js.

    `expect` — отпечаток той версии файла, на основе которой посчитаны данные. Не совпал,
    значит между чтением и заменой файл изменил кто-то ещё (Claude Code, редактор), и его
    правку затирать нельзя: возвращаем False, вызывающий отказывается от операции.
    """
    if expect is not None and settings_fingerprint() != expect:
        return False
    write_json(SETTINGS, data, indent=2)
    return True


def find_claude():
    for path in (
        os.path.join(HOME, ".local", "bin", "claude"),
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
    ):
        if os.access(path, os.X_OK):
            return path
    import shutil

    return shutil.which("claude")


# ──────────────────────────────────────────────────────────── состояние серверов

def parse_list_line(line):
    """`name: target - ✔ Connected` → запись о сервере.

    Имя режем по первому «двоеточие-пробел», а не по первому двоеточию: плагинные серверы
    называются plugin:figma:figma, и наивный split превращал их всех в «plugin».
    Статус берём по ПОСЛЕДНЕМУ « - »: у claude-mem команда запуска длиной 1400 символов
    и полна дефисов, по первому вхождению разбор бы развалился.
    """
    if ": " not in line or " - " not in line:
        return None
    name, rest = line.split(": ", 1)
    target, _, status = rest.rpartition(" - ")
    name, status = name.strip(), status.strip()
    if not name or not status:
        return None
    if "Connected" in status:
        state = OK
    elif "Pending" in status:
        state = PENDING
    else:
        state = FAILED
    return {"name": name, "target": target.strip(), "status": status, "state": state}


def run_health_check(cwd="/"):
    """`claude mcp list` — единственный источник живого статуса. Флага --json у неё нет.

    По умолчанию cwd закреплён на корне: ответ этой команды зависит от каталога запуска
    (local- и project-scope серверы видны только из своего проекта), а этот вызов строит
    ОБЩУЮ часть карты — user, плагины, коннекторы. Без закрепления картина зависела бы от
    того, откуда случайно запущено приложение.

    Для серверов проекта эта же команда зовётся ещё раз, с каталогом проекта. Так и надо:
    сам Claude Code решает, какой сервер из `.mcp.json` он готов поднять, а какой ждёт
    одобрения — и печатает второй как `⏸ Pending approval`, не подключаясь к нему. Читать
    чужой `.mcp.json` и запускать команду оттуда самим нельзя: одобрения у нас нет, спросить
    его мы не можем, а конфигурация приезжает вместе с репозиторием.
    """
    import subprocess

    claude = find_claude()
    if not claude:
        return [], t("err.nobinary")
    try:
        proc = subprocess.run(
            [claude, "mcp", "list"], capture_output=True, text=True, timeout=120, cwd=cwd
        )
    except subprocess.TimeoutExpired:
        return [], t("err.timeout")
    except Exception as exc:
        return [], str(exc)[:200]

    servers = [s for s in map(parse_list_line, proc.stdout.splitlines()) if s]
    if not servers:
        return [], (proc.stderr or proc.stdout or t("err.empty")).strip()[:200]
    return servers, None


# ──────────────────────────────────────────────────────────── число и имена инструментов

def counts_from_logs():
    """stdio-серверы печатают число инструментов в stderr при старте.

    Claude Code складывает stderr в ~/Library/Caches/claude-cli-nodejs/<cwd>/mcp-logs-<server>/,
    и переписывает на каждый `claude mcp list` — то есть refresh освежает их сам.
    Папки заведены на каждый cwd, поэтому берём запись с самым свежим mtime.
    В имени папки подчёркивания заменены дефисами: mcp-logs-my-server = my_server.
    """
    best = {}
    for folder in glob.glob(MCP_LOGS):
        server = os.path.basename(folder)[len("mcp-logs-") :]
        logs = sorted(glob.glob(folder + "/*.jsonl"), key=mtime, reverse=True)
        for log in logs[:3]:
            count = None
            try:
                with open(log) as fh:
                    for line in fh:
                        found = re.search(r"(\d+)\s+tools available", line)
                        if found:
                            count = int(found.group(1))
            except OSError:
                continue
            if count is not None:
                stamp = mtime(log)
                if server not in best or stamp > best[server][1]:
                    best[server] = (count, stamp)
                break
    return {k: v[0] for k, v in best.items()}


DESCRIPTIONS = os.path.join(ROOT, "descriptions.json")
DESCRIPTIONS_TTL = 24 * 3600
# Через сколько повторить опрос сервера, который на прошлой попытке не ответил.
FAILED_PROBE_RETRY = 3600
DESCRIPTIONS_FORMAT = 2


def describe_tool(tool):
    """Имя, описание и параметры — всё, что нужно карточке при наведении.

    Параметры лежат в inputSchema (это JSON Schema): properties плюс список required.
    Порядок properties оставляем как отдал сервер: он осмысленный, у большинства серверов
    обязательное идёт первым, и сортировка по алфавиту эту подсказку теряет.
    """
    # Форма на каждом уровне, не только у prop: инструмент приходит из кеша чужого приложения
    # или от чужого сервера, и строка на месте словаря (tools: ["имя"], inputSchema: "…")
    # роняла AttributeError'ом весь refresh — молча, stderr его процесса смотрит в DEVNULL.
    if not isinstance(tool, dict):
        return {"name": "", "description": "", "params": []}
    schema = tool.get("inputSchema") or tool.get("input_schema")
    schema = schema if isinstance(schema, dict) else {}
    required = schema.get("required")
    required = set(required) if isinstance(required, list) else set()
    props = schema.get("properties")
    params = [
        {
            "name": name,
            "type": (prop.get("type") if isinstance(prop, dict) else "") or "",
            "required": name in required,
            "description": ((prop.get("description") if isinstance(prop, dict) else "") or "").strip(),
        }
        for name, prop in (props.items() if isinstance(props, dict) else [])
    ]
    return {
        "name": tool.get("name") or "",
        "description": (tool.get("description") or "").strip(),
        "params": params,
    }


def ask_server_for_tools(name, config, timeout=20, cwd=None):
    """Спросить у сервера его инструменты по протоколу MCP (JSON-RPC поверх stdio).

    Ни логи, ни транскрипты описаний не содержат — их знает только сам сервер.
    Порядок обязательный: initialize → notifications/initialized → tools/list.
    Читаем построчно в отдельном потоке: иначе на таймауте всё виснет.
    """
    import queue
    import subprocess
    import threading

    command = config.get("command")
    if not command or config.get("type", "stdio") != "stdio":
        return None

    try:
        proc = subprocess.Popen(
            [command] + list(config.get("args") or []),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, bufsize=1, env={**os.environ, **(config.get("env") or {})},
            # Сервер проекта запускается из своего проекта: относительные пути в его
            # команде и конфиге считаются от каталога, в котором живёт .mcp.json.
            cwd=cwd,
        )
    except Exception:
        return None

    lines = queue.Queue()

    def pump():
        try:
            for line in proc.stdout:
                lines.put(line)
        except Exception:
            pass
        lines.put(None)

    threading.Thread(target=pump, daemon=True).start()

    def send(payload):
        proc.stdin.write(json.dumps(payload) + "\n")
        proc.stdin.flush()

    def await_id(wanted, deadline):
        while time.time() < deadline:
            try:
                line = lines.get(timeout=max(0.1, deadline - time.time()))
            except Exception:
                return None
            if line is None:
                return None
            if not line.lstrip().startswith("{"):
                continue  # транспорт иногда пишет в stdout не-JSON
            message = read_json_line(line)
            if message and message.get("id") == wanted:
                return message
        return None

    deadline = time.time() + timeout
    tools = []
    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "claude-control-bar", "version": "1.0"}}})
        if not await_id(1, deadline):
            return None
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})

        cursor, request_id = None, 2
        while True:
            params = {"cursor": cursor} if cursor else {}
            send({"jsonrpc": "2.0", "id": request_id, "method": "tools/list", "params": params})
            answer = await_id(request_id, deadline)
            result = (answer or {}).get("result") or {}
            tools += [describe_tool(t) for t in result.get("tools") or []]
            cursor = result.get("nextCursor")
            request_id += 1
            if not cursor or time.time() > deadline:
                break
    except Exception:
        return None
    finally:
        # terminate() без wait() оставлял жить сервер, игнорирующий SIGTERM, — и кеш для
        # неответившего не заполняется, так что каждый следующий refresh плодил ему брата.
        # Ступени: закрыть stdin (stdio-серверам это штатный сигнал уйти) → SIGTERM →
        # два тика подождать → SIGKILL. wait() после kill забирает зомби.
        try:
            proc.stdin.close()
        except Exception:
            pass
        try:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=2)
        except Exception:
            pass

    return tools or None


def refresh_descriptions(force=False):
    """Описания меняются редко, а опрос поднимает все серверы — держим сутки в кеше."""
    import threading

    cached = read_json(DESCRIPTIONS, {})
    # Выключенный сервер не запускаем. Опрос — это Popen его собственной команды, то есть панель
    # своими руками поднимала процесс, который пользователь её же тумблером погасил (проверено:
    # выключенный сервер с командой `touch marker` этот marker создавал). Ответ при этом даже не
    # нужен: выключенный сервер в контекст не попадает, описывать в карточке нечего.
    off = set(denied_servers())
    servers = {
        name: config
        for name, config in (read_json(CONFIG, {}).get("mcpServers") or {}).items()
        if name not in off
    }
    fresh_until = time.time() - DESCRIPTIONS_TTL
    # Формат записи версионируем: в первой версии параметров инструментов не было,
    # и без этой проверки карточка при наведении оставалась бы пустой ещё сутки —
    # ровно до истечения TTL, уже собранного старым кодом.
    todo = [
        (name, config) for name, config in servers.items()
        if force
        # Запись не той формы (руками правленный descriptions.json) — то же, что её нет:
        # .get на строке ронял AttributeError'ом весь refresh.
        or not isinstance(cached.get(name), dict)
        or (cached[name].get("ts") or 0) < fresh_until
        or cached[name].get("v") != DESCRIPTIONS_FORMAT
    ]
    if not todo:
        return cached

    results = {}
    lock = threading.Lock()

    def work(name, config):
        tools = ask_server_for_tools(name, config)
        if tools:
            with lock:
                results[name] = {
                    "ts": int(time.time()), "v": DESCRIPTIONS_FORMAT, "tools": tools
                }
        elif config.get("command") and config.get("type", "stdio") == "stdio":
            # Опрошенный и не ответивший stdio-сервер — тоже результат. Без записи каждый
            # refresh (раз в ~10 минут) заново поднимал его процесс и высиживал 20-секундный
            # таймаут — вечно. Штамп сдвинут в прошлое, чтобы попытка вернулась через час,
            # а не через сутки: сервер могли просто починить. Пустой список инструментов
            # attach_tools() и так замещает кешем десктопа или именами из транскриптов.
            # Только stdio с командой: для remote/SSE ask_server_for_tools() выходит сразу,
            # и запись о «неответившем» глушила бы кеш коннекторов на ровном месте.
            with lock:
                results[name] = {
                    "ts": int(time.time()) - DESCRIPTIONS_TTL + FAILED_PROBE_RETRY,
                    "v": DESCRIPTIONS_FORMAT, "tools": [],
                }

    threads = [threading.Thread(target=work, args=pair, daemon=True) for pair in todo]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)

    cached.update(results)
    write_json(DESCRIPTIONS, cached)
    return cached


def connectors_from_desktop():
    """Коннекторы claude.ai в stderr молчат — их схемы кеширует десктоп-приложение.

    Кроме инструментов отсюда берётся uuid: именно он, а не отображаемое имя, стоит внутри
    имён инструментов коннектора (mcp__b3c4de1c-…__create_event), и без него правило deny
    собиралось из «claude.ai Google Calendar» и не совпадало ни с чем.
    """
    files = sorted(
        glob.glob(DESKTOP_SESSIONS + "/**/*.json", recursive=True),
        key=mtime,
        reverse=True,
    )
    for path in files[:200]:
        # Кеш пишет чужое приложение: словари в списке — не гарантия, а сегодняшняя
        # случайность. Неожиданная форма — «коннекторов нет», не AttributeError на весь
        # refresh; верхний уровень сверяет сама read_json.
        remote = read_json(path, {}).get("remoteMcpServersConfig")
        if remote and isinstance(remote, list):
            return {
                s["name"]: {
                    "uuid": s.get("uuid") or "",
                    "tools": [describe_tool(t) for t in
                              (s["tools"] if isinstance(s.get("tools"), list) else [])],
                }
                for s in remote
                if isinstance(s, dict) and s.get("name")
            }
    return {}


def tool_names_from_transcripts():
    """Имена инструментов нужны для поштучных запретов — их даёт только транскрипт.

    Claude Code пишет записи deferred_tools_delta с полными именами вида mcp__wiki__GetPageById.
    Свежий по mtime файл может дельт не содержать (транскрипты субагентов), поэтому ищем перебором.
    """
    files = sorted(glob.glob(TRANSCRIPTS), key=mtime, reverse=True)
    for path in files[:60]:
        names = []
        try:
            with open(path) as fh:
                for line in fh:
                    if '"deferred_tools_delta"' not in line:
                        continue
                    record = read_json_line(line)
                    delta = record.get("attachment") if isinstance(record, dict) else None
                    if not isinstance(delta, dict):
                        continue
                    for key in ("addedNames", "readdedNames"):
                        added = delta.get(key)
                        names += added if isinstance(added, list) else []
                    removed = delta.get("removedNames")
                    for gone in removed if isinstance(removed, list) else []:
                        if gone in names:
                            names.remove(gone)
        except OSError:
            continue
        if not names:
            continue
        grouped = {}
        for full in names:
            if not isinstance(full, str):
                continue
            parts = full.split("__", 2)
            if full.startswith("mcp__") and len(parts) == 3:
                grouped.setdefault(parts[1], []).append(parts[2])
        if grouped:
            return {k: sorted(v) for k, v in grouped.items()}
    return {}


def read_json_line(line):
    try:
        return json.loads(line)
    except Exception:
        return None


def classify(name, local_servers):
    if name.startswith("claude.ai "):
        return "claude.ai"
    if name.startswith("plugin:"):
        return "plugin"
    return "user" if name in local_servers else "project"


def short_name(name):
    """Имя без служебных приставок: claude.ai Figma → Figma, plugin:figma:figma → figma."""
    if name.startswith("claude.ai "):
        return name[len("claude.ai ") :]
    if name.startswith("plugin:"):
        return name.rsplit(":", 1)[-1]
    return name


def sanitized_prefix(name):
    """Отображаемое имя, приведённое к тому виду, в котором оно может стоять внутри имени
    инструмента: приставка «claude.ai » снимается, всё, кроме букв, цифр, дефиса и
    подчёркивания, становится подчёркиванием."""
    bare = name[len("claude.ai ") :] if name.startswith("claude.ai ") else name
    return re.sub(r"[^A-Za-z0-9_-]", "_", bare)


def tool_prefix(name, index=None, uuid=""):
    """Как сервер зовётся ВНУТРИ имени инструмента: mcp__<приставка>__<инструмент>.

    Это не то же самое, что отображаемое имя, и правило deny строится именно отсюда. Настоящие
    имена инструментов не содержат ни пробелов, ни двоеточий: plugin:claude-mem:mcp-search живёт
    в контексте как plugin_claude-mem_mcp-search, а коннектор claude.ai — под своим uuid. Правило,
    собранное из отображаемого имени, не совпадало ни с одним инструментом: тумблер в панели
    гас, а инструмент продолжал грузиться в каждой новой сессии — и счётчик «N/M tools on»
    обещал экономию контекста, которой не было.

    Транскрипт знает настоящие приставки, поэтому кандидат, который в нём нашёлся, побеждает
    догадку; догадка нужна для сервера, которым ещё ни разу не пользовались.
    """
    candidates = [c for c in (uuid, sanitized_prefix(name), name) if c]
    for candidate in candidates:
        if index and candidate.lower() in index:
            return candidate
    return candidates[0]


def session_cwds():
    """Каталоги проектов живых сессий, по state.d (живость — pid, как и везде)."""
    cwds = []
    for path in glob.glob(os.path.join(SESSIONS, "*.json")):
        info = read_json(path, {})
        # pid ≤ 0 — сигнал группе процессов, а не процессу: os.kill(0, 0) успешен всегда,
        # и битая запись с pid 0 становилась бессмертной «живой» сессией.
        try:
            pid = int(info.get("pid"))
            if pid <= 0:
                continue
            os.kill(pid, 0)
        except (OSError, ValueError, TypeError):
            continue
        cwd = info.get("cwd")
        if cwd and os.path.isdir(cwd) and cwd not in cwds:
            cwds.append(cwd)
    return cwds


def project_cwds(cwds, global_config):
    """Каталоги живых сессий, у которых вообще есть свои MCP-серверы.

    Нужно только чтобы не гонять `claude mcp list` (полминуты) по проектам, где искать
    нечего. Сами конфигурации отсюда никуда не идут: что из них поднимать, решает Claude
    Code — он один знает, какой сервер из `.mcp.json` человек одобрил.

    Два места, где живут серверы проекта: `~/.claude.json` → `projects[<cwd>].mcpServers`
    (их добавляет сам человек) и `<cwd>/.mcp.json` (приезжает вместе с репозиторием).
    """
    projects = (global_config or {}).get("projects") or {}
    out = []
    for cwd in cwds:
        has = bool((projects.get(cwd) or {}).get("mcpServers"))
        config = os.path.join(cwd, ".mcp.json")
        if not has and os.path.exists(config):
            parsed = read_json(config)
            # Файл есть, но не разбирается — проект всё равно идёт на проверку. Сломанная
            # конфигурация MCP как раз то, про что инструмент здоровья обязан сказать, а
            # read_json глушит ошибку разбора, и проект исчезал из карты целиком — вместе
            # с уже поднятыми серверами. Что там внутри, разбирает Claude Code, не мы.
            has = not isinstance(parsed, dict) or bool(parsed.get("mcpServers"))
        if has and cwd not in out:
            out.append(cwd)
    return out


def attach_tools(servers):
    """Проставить каждому серверу инструменты: имена, описания и счётчик.

    Источники по убыванию полноты: опрос самого сервера (даёт описания),
    кеш десктоп-приложения для коннекторов (тоже с описаниями),
    транскрипты (только имена — на них и падаем, если сервер не ответил).
    """
    counts = {k.replace("_", "-"): v for k, v in counts_from_logs().items()}
    connectors = connectors_from_desktop()
    asked = refresh_descriptions()
    index = {k.lower(): v for k, v in tool_names_from_transcripts().items()}

    for entry in servers:
        bare = short_name(entry["name"])
        connector = connectors.get(bare) or {}
        # Форма кеша проверяется и здесь: descriptions.json лежит на диске и может быть
        # испорчен руками. Пустой ответ опроса (негативная запись) отдаёт слово кешу
        # десктопа, а не глушит его.
        probed = asked.get(entry["name"])
        described = probed.get("tools") if isinstance(probed, dict) else None
        described = [t for t in described or [] if isinstance(t, dict) and t.get("name")]
        if not described and connector:
            described = [t for t in connector.get("tools") or []
                         if isinstance(t, dict) and t.get("name")]
        prefix = tool_prefix(entry["name"], index, connector.get("uuid", ""))
        # Приставка едет в состояние: правило deny собирает приложение, и второй экземпляр этой
        # логики в Swift разошёлся бы с этим — ровно так и появилось правило, которое ничего
        # не запрещало.
        entry["toolPrefix"] = prefix
        names = sorted(t["name"] for t in described) if described else index.get(prefix.lower(), [])

        entry["toolNames"] = names
        entry["toolDocs"] = {t["name"]: t["description"] for t in described if t.get("description")}
        entry["toolParams"] = {t["name"]: t["params"] for t in described if t.get("params")}
        entry["tools"] = counts.get(bare.replace("_", "-"))
        # Счётчика из логов нет (коннекторы и плагины его не печатают) — считаем по именам.
        if entry["tools"] is None and names:
            entry["tools"] = len(names)


# ──────────────────────────────────────────────────────────── запреты

def denied_servers():
    """`deniedMcpServers` в settings.json — единственный способ выключить сервер глобально.

    Проверено запуском: запись объектная, плоскую строку Claude Code молча игнорирует.
    """
    raw = read_json(SETTINGS, {}).get("deniedMcpServers") or []
    return [d["serverName"] for d in raw if isinstance(d, dict) and "serverName" in d]


def denied_tools():
    """`permissions.deny` не просто запрещает вызов, а вырезает инструмент из контекста.

    Проверено: одно правило mcp__docs__read_page уменьшило список с 26 инструментов до 25.
    """
    # Форма, не только наличие: settings.json правят руками, и "permissions": [...] на месте
    # словаря ронял AttributeError'ом и refresh, и оба тумблера. Не та форма — правил нет.
    perms = read_json(SETTINGS, {}).get("permissions")
    deny = perms.get("deny") if isinstance(perms, dict) else None
    return [rule for rule in (deny if isinstance(deny, list) else [])
            if isinstance(rule, str) and rule.startswith("mcp__")]


def tool_denied(rules, prefix, tool):
    """Инструмент погашен правилом на весь сервер, точным именем или глобом.

    Первым аргументом идёт приставка из tool_prefix(), а не отображаемое имя: правило пишется
    ровно теми буквами, которыми Claude Code зовёт инструмент, иначе оно ничего не запрещает.
    """
    full = f"mcp__{prefix}__{tool}"
    for rule in rules:
        if rule == f"mcp__{prefix}" or rule == full:
            return True
        if rule.endswith("*") and full.startswith(rule[:-1]):
            return True
    return False


def backup_settings():
    # default=None намеренно, НЕ {}: бэкап обязан быть дословным снимком, а «файл не читается»
    # — поводом не бэкапить вовсе. read_json(SETTINGS, {}) записал бы пустышку поверх правды.
    settings = read_json(SETTINGS)
    if settings is None:
        return None
    # Имя несёт имя приложения и микросекунды. Приставка — граница ротации: голая маска
    # `.bak-2*` совпадала с любым датированным бэкапом рядом с настройками, в том числе
    # сделанным руками или другим инструментом, и чистка «наших десяти» удаляла чужое.
    # Микросекунды — потому что секундного разрешения мало: два быстрых переключения
    # попадали в один файл, и второй снимок молча не делался.
    from datetime import datetime

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    path = f"{SETTINGS}.bak-control-bar-{stamp}"
    # Копии ещё нет, наследовать режим неоткуда — и при обычном umask 022 она рождалась 0644,
    # хотя сам settings.json стоит 0600 и хранит env MCP-серверов с токенами. Берём режим
    # исходника и в любом случае не шире владельца: резервная копия секрета — тот же секрет.
    try:
        mode = (os.stat(os.path.realpath(SETTINGS)).st_mode & 0o777) & 0o700
    except OSError:
        mode = 0o600
    write_json(path, settings, mode=mode)
    # Переключатель дёргают часто — храним десяток последних СВОИХ снимков, остальное чистим.
    # Ротация ходит строго по своей приставке: старые `.bak-<дата>` без неё, разовый
    # `.bak-control-bar` установщика хуков и любые чужие файлы не трогаются — доказать их
    # принадлежность приложению уже нельзя.
    ours = sorted(glob.glob(f"{SETTINGS}.bak-control-bar-2*"), reverse=True)
    for stale in ours[10:]:
        try:
            os.remove(stale)
        except OSError:
            pass
    return path


def patch_state_after_toggle():
    """Пересчитать в состоянии только то, что зависит от настроек.

    Полная проверка занимает семь секунд — для переключателя в меню это вечность.
    Здесь же переключатель обязан отзываться мгновенно, поэтому трогаем ровно
    признаки «выключен» и «погашенные инструменты», остальное оставляем как было.
    """
    data = load_state()
    if not data:
        return None
    off = set(denied_servers())
    rules = denied_tools()
    known = {s["name"] for s in data.get("servers", [])}
    local = set(read_json(CONFIG, {}).get("mcpServers") or {})

    for name in off - known:
        data.setdefault("servers", []).append({
            "name": name, "target": "", "status": t("server.off"), "state": OFF,
            "source": classify(name, local), "tools": None, "toolNames": [], "toolDocs": {},
            "toolPrefix": tool_prefix(name),
        })
    for entry in data.get("servers", []):
        entry["disabled"] = entry["name"] in off
        if entry["disabled"]:
            entry["state"] = OFF
        elif entry.get("state") == OFF:
            # Включили обратно: до следующей проверки честнее сказать «неизвестно», а не
            # рисовать зелёный кружок. Проверка приезжает следом — приложение заказывает её
            # сразу после переключения, а не ждёт своего десятиминутного таймера.
            entry["state"] = PENDING
            entry["status"] = t("server.restart")
        entry["deniedTools"] = [
            tool for tool in entry.get("toolNames", [])
            if tool_denied(rules, entry.get("toolPrefix") or entry["name"], tool)
        ]
    data["denyRules"] = rules
    write_json(STATE, data)
    return data


def settings_lock():
    """Эксклюзивная межпроцессная блокировка на всё время «прочитал → изменил → записал».

    Каждый клик по переключателю приложение запускает отдельным процессом на глобальной
    очереди, так что два быстрых клика реально работают параллельно. Атомарной записи мало:
    оба процесса читают одну версию файла, и чья запись вторая — тот и затёр чужое изменение
    (замер до блокировки: 43 потери на 50 прогонов двух одновременных переключений).
    Блокировка снимается сама при выходе процесса, зависший держатель не вечен.
    """
    import fcntl
    from contextlib import contextmanager

    @contextmanager
    def held():
        os.makedirs(ROOT, mode=SECURE_DIR, exist_ok=True)
        lock = os.path.join(ROOT, "settings.lock")
        with os.fdopen(os.open(lock, os.O_WRONLY | os.O_CREAT, SECURE_FILE), "w") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(fh, fcntl.LOCK_UN)

    return held()


class Refused(Exception):
    """Переключатель, который скрипт делать не станет, и почему.

    Раньше все четыре исхода — нечитаемый settings.json, чужая форма ключа, «уже так» и
    гонка с чужой записью — печатались одним словом unchanged. «Я не тронул твой битый
    файл» и «уже выключено» — разные ответы, и человек в /mcp-health должен их различать.
    """


def toggle_server(name, turn_off):
    with settings_lock():
        return _toggle_server_locked(name, turn_off)


def _toggle_server_locked(name, turn_off):
    settings, seen = read_settings_for_edit()
    if settings is None:
        raise Refused("settings.json is unreadable or not valid JSON; nothing written")
    current = settings.get("deniedMcpServers")
    if current is None:
        current = []
    elif not isinstance(current, list):
        # Ключ есть, но не список — файл правили руками. Отказ, как на нечитаемом файле:
        # чинить чужую форму своим переключателем значит молча снести то, что там лежало.
        raise Refused("deniedMcpServers in settings.json is not a list; nothing written")
    kept = [
        d for d in current
        if not (isinstance(d, dict) and d.get("serverName") == name)
    ]
    if turn_off:
        kept.append({"serverName": name})
    if kept == current:
        return False
    backup_settings()
    if kept:
        settings["deniedMcpServers"] = kept
    else:
        settings.pop("deniedMcpServers", None)
    if not write_settings(settings, expect=seen):
        raise Refused("settings.json changed underneath the switch; nothing written")
    return True


def rule_for_tool(server, tool):
    """Правило deny для инструмента — и написания, которыми оно когда-то собиралось ошибочно.

    Приставку берём из состояния: её посчитал refresh, когда видел и транскрипты, и кеш
    десктопа. Ошибочные написания уходят вместе с рабочим правилом, иначе строка, которая
    ничего не запрещает, осталась бы в настройках пользователя навсегда.
    """
    known = {s["name"]: s.get("toolPrefix") for s in load_state().get("servers", [])}
    prefix = known.get(server) or tool_prefix(server)
    rule = f"mcp__{prefix}__{tool}"
    wrong = {f"mcp__{p}__{tool}" for p in (server, short_name(server), sanitized_prefix(server))}
    return rule, sorted(wrong - {rule})


def toggle_tool(rule, turn_off, stale=()):
    with settings_lock():
        return _toggle_tool_locked(rule, turn_off, stale)


def _toggle_tool_locked(rule, turn_off, stale=()):
    settings, seen = read_settings_for_edit()
    if settings is None:
        raise Refused("settings.json is unreadable or not valid JSON; nothing written")
    perms = settings.setdefault("permissions", {})
    if not isinstance(perms, dict):
        # setdefault вернул существующее значение не той формы (руками вписанный список).
        # Отказ, как на нечитаемом файле: crash внутри замка хуже честного «не вышло».
        raise Refused("permissions in settings.json is not an object; nothing written")
    deny = perms.get("deny")
    if deny is not None and not isinstance(deny, list):
        raise Refused("permissions.deny in settings.json is not a list; nothing written")
    current = list(deny or [])
    drop = {rule, *stale}
    kept = [r for r in current if r not in drop]
    if turn_off:
        kept.append(rule)
    if kept == current:
        return False
    backup_settings()
    if kept:
        perms["deny"] = kept
    else:
        # Не оставлять за собой пустой ключ: настройки должны вернуться ровно к тому,
        # что было до первого переключения.
        perms.pop("deny", None)
        if not perms:
            settings.pop("permissions", None)
    if not write_settings(settings, expect=seen):
        raise Refused("settings.json changed underneath the switch; nothing written")
    return True


# ──────────────────────────────────────────────────────── перехват statusLine

STATUSLINE_INNER = os.path.join(ROOT, "statusline-inner-command")
# Весь исходный объект statusLine, не только command: у него есть поддерживаемые поля
# (padding, refreshInterval, hideVimModeIndicator), и «сохранить только команду» значило
# молча снести их при установке и не вернуть при откате.
STATUSLINE_SAVED = os.path.join(ROOT, "statusline-saved.json")
# Точная команда, которую записала установка. Единственный надёжный ответ на вопрос «наш ли
# текущий statusLine»: сам факт существования сайдкаров таким ответом не является — они
# говорят лишь, что установка КОГДА-ТО была, а команду человек мог с тех пор сменить руками.
STATUSLINE_INSTALLED = os.path.join(ROOT, "statusline-installed.json")


def statusline_sidecars():
    """Один список на все операции: «след установки» обязан значить одно и то же в проверке,
    откате неудачной установки и чистке после отката — разные списки в этих местах уже успели
    разойтись на одну правку. Функция, а не кортеж-константа: тесты подменяют пути поимённо,
    и снимок, сделанный на импорте, смотрел бы мимо подмены — в настоящий домашний каталог."""
    return (STATUSLINE_SAVED, STATUSLINE_INNER, STATUSLINE_INSTALLED)


def drop_statusline_sidecars():
    for leftover in statusline_sidecars():
        try:
            os.remove(leftover)
        except OSError:
            pass


def find_statusline_wrapper():
    """Обёртка лежит рядом с этим скриптом, но раскладка разная в двух каналах поставки.

    В плагине и в репозитории это hooks/statusline.sh; внутри собранного .app всё
    вспомогательное сложено плоско в Contents/Resources.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    parent = os.path.dirname(here)
    for candidate in (
        os.path.join(parent, "hooks", "statusline.sh"),
        os.path.join(parent, "statusline.sh"),
    ):
        if os.path.exists(candidate):
            return candidate
    return None


def statusline_ours(command):
    """Наша ли это команда statusLine.

    Не по подстроке «statusline.sh»: это имя из официального примера в документации Claude
    Code, так что своя строка состояния пользователя опознавалась как наша — install молча
    отвечал «уже установлен» и не делал ничего, а uninstall удалял чужую команду, которую
    никогда не сохранял. Признаки конкретные, по убыванию силы: команда буква в букву та,
    что записала установка; команда указывает на файл, лежащий рядом с ЭТИМ скриптом.

    След установки (сайдкары) сам по себе ответом НЕ является: человек мог сменить команду
    руками уже после установки, и «сайдкары есть, значит наша» затирало при откате его самую
    свежую настройку самой старой. Сайдкары участвуют только в узком унаследованном случае —
    запись установки ещё не велась, а команда указывает на statusline.sh, которого больше нет
    на диске: путь плагина несёт в себе номер версии и переезжает при каждом обновлении.
    Живая чужая строка состояния так выглядеть не может — её файл существует.
    """
    command = (command or "").strip()
    if not command:
        return False
    installed = read_json(STATUSLINE_INSTALLED, {}).get("command") or ""
    if command == installed.strip():
        return True
    import shlex

    try:
        words = shlex.split(command)
    except ValueError:
        words = command.split()
    named = [w for w in words if os.path.basename(w) == "statusline.sh"]
    wrapper = find_statusline_wrapper()
    if wrapper:
        mine = os.path.realpath(wrapper)
        if any(os.path.realpath(w) == mine for w in named):
            return True
    # Ниже — миграционный шим для установок, сделанных ДО появления файла-записи, и только
    # для них: запись есть и не совпала — команда чужая, «похоже на нашу» больше не аргумент.
    # Без этого гейта чужая ЖИВАЯ команда вида `bash ~/.claude/statusline.sh` читалась как
    # мёртвая обёртка прошлой версии: shlex не раскрывает ни ~, ни $HOME, и os.path.exists
    # на таком слове всегда False. Шим самозакрывается первой же установкой этой версии.
    if installed:
        return False
    if any(map(os.path.exists, statusline_sidecars())):
        return any(not os.path.exists(w) for w in named)
    return False


def statusline_command(settings):
    """Команда statusLine с проверкой формы: строка на месте объекта — «команды нет»,
    а не AttributeError (settings.json правят руками)."""
    entry = settings.get("statusLine")
    return ((entry.get("command") if isinstance(entry, dict) else "") or "").strip()


def statusline_state():
    current = statusline_command(read_json(SETTINGS, {}))
    return current, statusline_ours(current)


def statusline_install():
    """Обернуть уже настроенный statusLine, не потеряв его.

    Лимиты Claude Code не хранит на диске вовсе — они живут в памяти процесса и выходят
    наружу единственной дверью, payload'ом statusLine. Поэтому единственный бесплатный
    способ их увидеть — встать в эту дверь, ничего в ней не сломав.

    Пишется тем же контрактом, что и тумблеры: блокировка на всё время правки,
    read_settings_for_edit() вместо обычного read_json() и отпечаток при записи. Без него
    невалидный в этот момент settings.json (человек правит руками) читался как пустой, и файл
    целиком — вместе с permissions.deny и env, где лежат токены — заменялся одним ключом
    statusLine; резервной копии не оставалось тоже, backup_settings() на нечитаемом файле
    молча возвращает None.
    """
    wrapper = find_statusline_wrapper()
    if not wrapper:
        return t("sl.nowrapper")
    with settings_lock():
        settings, seen = read_settings_for_edit()
        if settings is None:
            return t("sl.busy")
        current = statusline_command(settings)
        if statusline_ours(current):
            return t("sl.already")

        backup_settings()
        os.makedirs(ROOT, mode=SECURE_DIR, exist_ok=True)
        original = settings.get("statusLine")
        # Целиком, включая None для «его не было»: по этой записи делается откат.
        write_json(STATUSLINE_SAVED, original)
        # Команду — отдельным файлом: её на каждой перерисовке читает bash-обёртка,
        # и парсить JSON ей нечем. Права 0600, как у всего в этом каталоге: с umask копия
        # чужой команды рождалась читаемой всей машине.
        tmp = STATUSLINE_INNER + ".tmp"
        with os.fdopen(
            os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, SECURE_FILE), "w"
        ) as fh:
            fh.write(current + "\n")
        os.replace(tmp, STATUSLINE_INNER)
        # Подменяется ровно одно поле. padding, refreshInterval, hideVimModeIndicator и что
        # там ещё настроено — остаются и продолжают действовать с обёрткой.
        installed = dict(original) if isinstance(original, dict) else {}
        installed.update({"type": "command", "command": f'bash "{wrapper}"'})
        write_json(STATUSLINE_INSTALLED, {"command": installed["command"]})
        settings["statusLine"] = installed
        if not write_settings(settings, expect=seen):
            # Сайдкары написаны до настроек, и раз настройки не изменились — следа установки
            # быть не должно: по нему следующая проверка отвечала бы «перехват стоит».
            drop_statusline_sidecars()
            return t("sl.busy")
        return t("sl.installed", cmd=current or t("sl.nocommand"))


def statusline_uninstall():
    with settings_lock():
        settings, seen = read_settings_for_edit()
        if settings is None:
            return t("sl.busy")
        current = statusline_command(settings)
        if not statusline_ours(current):
            # След установки есть, а команда уже другая: человек сменил statusLine руками
            # ПОСЛЕ установки. Восстановить «как было» = затереть его самую свежую настройку
            # самой старой, поэтому здесь остановка, а не откат.
            trace = any(map(os.path.exists, statusline_sidecars()))
            return t("sl.changed") if trace else t("sl.notours")
        saved = ""
        try:
            with open(STATUSLINE_INNER) as fh:
                saved = fh.read().strip()
        except OSError:
            pass
        backup_settings()
        if os.path.exists(STATUSLINE_SAVED):
            # Полный объект как он был. None означает «statusLine не был настроен вовсе».
            original = read_json(STATUSLINE_SAVED)
            if isinstance(original, dict):
                settings["statusLine"] = original
            else:
                settings.pop("statusLine", None)
        elif saved:
            # Установка старой версией: полного объекта нет, есть только команда.
            settings["statusLine"] = {"type": "command", "command": saved}
        else:
            settings.pop("statusLine", None)
        if not write_settings(settings, expect=seen):
            return t("sl.busy")
        drop_statusline_sidecars()
        return t("sl.restored", cmd=saved or t("sl.removed"))


# ──────────────────────────────────────────────────────────── лимиты по OAuth

# Тот же эндпоинт, которым /usage в самом Claude Code рисует свои проценты. statusLine-перехват
# остаётся вторым источником, но работает он только пока в терминале открыт CLI с живым TUI —
# у пользователя десктопного приложения лимиты через него не обновляются вообще. Опрос эндпоинта
# от сессий не зависит.
#
# Токен — тот, что Claude Code сам положил в Keychain. Он не печатается, не логируется и не
# уходит никуда, кроме api.anthropic.com. Чаще раза в 3 минуты спрашивать нельзя (community-
# консенсус: агрессивный rate limit), приложение ходит раз в 5.
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
KEYCHAIN_SERVICE = "Claude Code-credentials"
CREDENTIALS_FILE = os.path.join(CLAUDE, ".credentials.json")


def oauth_token():
    """Access token Claude Code: Keychain на macOS, файл на Linux/Windows. None — не настроен."""
    import subprocess

    raw = ""
    try:
        raw = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=30,
        ).stdout.strip()
    except Exception:
        pass
    if not raw:
        try:
            with open(CREDENTIALS_FILE) as fh:
                raw = fh.read()
        except OSError:
            return None
    try:
        creds = json.loads(raw).get("claudeAiOauth") or {}
    except ValueError:
        return None
    # expiresAt в миллисекундах; просроченный токен вернёт 401, но честнее не ходить вовсе —
    # CLI сам обновит запись при следующем запуске.
    expires = creds.get("expiresAt")
    if isinstance(expires, (int, float)) and expires / 1000 < time.time():
        return None
    return creds.get("accessToken") or None


def parse_reset(value):
    """resets_at приходит ISO-строкой с таймзоной; statusLine шлёт epoch. Наружу — epoch int."""
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        from datetime import datetime

        try:
            return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
        except ValueError:
            return None
    return None


def usage_record(payload, now=None):
    """Ответ эндпоинта → limits.json той же формы, что пишет statusline.py.

    Поле там называется utilization, в statusLine — used_percentage; наружу всегда
    used_percentage и всегда int: Swift читает `as? Int`, и дробное значение молча
    выключило бы секцию лимитов при здоровом на вид файле.
    """
    # Эндпоинт недокументирован: сегодняшний словарь завтра может оказаться массивом или
    # строкой ошибки. Любая неожиданная форма — это «окон нет», не исключение: вызов стоит
    # в fetch_limits, чей контракт — молчать при любом сбое и не трогать прошлые цифры.
    if not isinstance(payload, dict):
        return None
    record = {"ts": int(now or time.time()), "source": "oauth"}
    for name, block in payload.items():
        if not isinstance(block, dict):
            continue
        # Окно с служебным именем затёрло бы штамп времени — и report() падал бы
        # на `time.time() - limits["ts"]` с TypeError.
        if name in ("ts", "source"):
            continue
        used = block.get("utilization", block.get("used_percentage"))
        if used is None:
            continue
        try:
            pct = int(round(float(used)))
        # OverflowError — это Infinity: json.loads пропускает голый Infinity/NaN-токен,
        # а round(inf) кидает именно его, и одно такое окно роняло бы весь разбор.
        except (TypeError, ValueError, OverflowError):
            continue
        record[name] = {
            "used_percentage": pct,
            "resets_at": parse_reset(block.get("resets_at")),
        }
    # Окно Fable эндпоинт отдаёт не верхним ключом, а элементом массива limits[] с
    # kind=weekly_scoped и scope.model.display_name="Fable" (поле percent, не utilization).
    # Наружу — под именем seven_day_fable, по образцу seven_day_opus: приложение и
    # report() читают один ключ, и верхнеуровневый seven_day_fable, если он однажды
    # появится, ляжет в ту же ячейку.
    scoped = scoped_model_window(payload.get("limits"), "fable")
    if scoped is not None and "seven_day_fable" not in record:
        record["seven_day_fable"] = scoped
    return record if len(record) > 2 else None


def scoped_model_window(limits, model):
    """Элемент limits[] с недельным окном модели → {used_percentage, resets_at} или None."""
    if not isinstance(limits, list):
        return None
    for entry in limits:
        if not isinstance(entry, dict) or entry.get("kind") != "weekly_scoped":
            continue
        scope = entry.get("scope") or {}
        name = ((scope.get("model") or {}).get("display_name") or "") if isinstance(scope, dict) else ""
        if not isinstance(name, str) or name.strip().lower() != model:
            continue
        try:
            pct = int(round(float(entry.get("percent"))))
        except (TypeError, ValueError, OverflowError):
            continue
        return {"used_percentage": pct, "resets_at": parse_reset(entry.get("resets_at"))}
    return None


def fetch_limits():
    """Один опрос: токен → эндпоинт → limits.json. Молчалив при любом сбое — прошлые
    цифры в файле лучше, чем затёртые ошибкой."""
    token = oauth_token()
    if not token:
        return t("lim.notoken")
    import urllib.request

    # Редиректы запрещены целиком. Стандартный обработчик urllib переносит Authorization на
    # новый хост как есть (requests так не делает, urllib делает), поэтому одного 302 — от
    # эндпоинта, прокси или будущего переезда API — хватило бы, чтобы токен аккаунта уехал
    # чужому серверу. Проверять resp.geturl() после запроса поздно: заголовок уже ушёл.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None

    req = urllib.request.Request(USAGE_URL, headers={
        "Authorization": f"Bearer {token}",
        "anthropic-beta": "oauth-2025-04-20",
        "Content-Type": "application/json",
        # Без узнаваемого UA запросы попадают в агрессивно лимитируемую корзину.
        "User-Agent": "claude-control-bar (statusline companion)",
    })
    try:
        with urllib.request.build_opener(NoRedirect).open(req, timeout=15) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
        # Внутри try, а не после: разбор дрейфующего ответа — такой же сбой опроса, как сеть
        # или 401. Снаружи он однажды и стоял — и массив вместо объекта ронял весь скрипт.
        record = usage_record(payload)
    except Exception as exc:  # noqa: BLE001 — сеть, 401, редирект, JSON: файл не трогаем
        return t("lim.failed", e=type(exc).__name__)
    if not record:
        return t("lim.empty")
    write_json(LIMITS, record)
    windows = ", ".join(f"{k} {v['used_percentage']}%" for k, v in record.items()
                        if isinstance(v, dict))
    return t("lim.updated", w=windows)


# ──────────────────────────────────────────────────────────── лимиты Codex

# Codex CLI пишет ход сессии в rollout-файл, и каждый ответ модели кладёт туда снимок
# лимитов аккаунта — те же 5 часов и неделя, что показывает его `/status`. Читаем только
# этот файл: ни auth.json, ни сети, ни запуска самого Codex. Цифры уже лежат на диске,
# и спрашивать за них токен пользователя не за что.
CODEX = os.path.join(HOME, ".codex")
# YYYY/MM/DD разложены каталогами; три звёздочки вместо рекурсии — архив сессий лежит
# в соседнем каталоге и обходить его незачем.
CODEX_ROLLOUTS = os.path.join(CODEX, "sessions", "*", "*", "*", "rollout-*.jsonl")
CODEX_ROOT = os.path.join(ROOT, "codex")
CODEX_LIMITS = os.path.join(CODEX_ROOT, "limits.json")


def secure_codex_root():
    """Оба каталога под codex/*.json — руками и до записи.

    `os.makedirs(..., mode=)` ставит права только последнему каталогу пути, промежуточные
    рождаются с umask: на свежей машине, где первой командой оказался `codex-limits`, сам
    ~/.claude/control-bar остался бы 0755 — открытым всей группе staff вместе с процентами
    лимитов аккаунта. Общая на трёх писателей: правило «оба каталога 0700» держалось на
    дисциплине копирования, и четвёртый писатель легко обошёлся бы одним makedirs.
    """
    for directory in (ROOT, CODEX_ROOT):
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
    for script in (os.path.join(ROOT, name) for name in OUR_HOOK_SCRIPTS):
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


# ──────────────────────────────────────────────────────────── контекстное окно

WINDOW_CACHE = os.path.join(ROOT, "model-windows.json")
DEFAULT_WINDOW = 200_000

# Записи, по которым считать контекст нельзя: служебные ответы и прерванные ходы.
SKIP_TEXTS = {
    "[Request interrupted by user]",
    "[Request interrupted by user for tool use]",
    "No response requested.",
}


def scrape_model_windows():
    """Размеры окон живут в реестре моделей внутри бинаря CLI.

    Выскребаем один раз и кешируем: тогда обновление Claude Code не сломает расчёт.
    """
    claude = find_claude()
    if not claude:
        return {}
    try:
        with open(os.path.realpath(claude), "rb") as fh:
            blob = fh.read().decode("latin-1")
    except OSError:
        return {}
    found = {}
    for match in re.finditer(r'\{id:"(claude-[a-z0-9.\-]+)",family:"', blob):
        segment = blob[match.start() : match.start() + 1200]
        window = re.search(r"context:\{[^}]*?window:([0-9e.+]+)", segment)
        if window:
            found[match.group(1)] = int(float(window.group(1)))
    return found


def model_windows():
    cached = read_json(WINDOW_CACHE, {})
    # Наблюдения из statusLine (hooks/statusline.py) переживают пересборку таблицы: они точнее
    # выскребленного, потому что их назвала сама модель, которая только что ответила, и
    # добываются они дорого — только когда пользователь реально запустил эту модель в терминале.
    observed = cached.get("observed") or {}
    claude = find_claude()
    version = os.path.realpath(claude) if claude else ""
    # isinstance, не истинность: пустая таблица от сдвинувшегося паттерна — тоже результат.
    # Условие «непустая» после такого сдвига не выполнялось больше никогда, и каждый refresh
    # заново читал и декодировал весь бинарь CLI (сотни МБ, секунды, под замком проверки).
    # Наблюдения statusline.py в кеш дописывает сам statusline.py — прямо в models.
    if cached.get("version") == version and isinstance(cached.get("models"), dict):
        return cached["models"]
    # Таблица собирается на машине пользователя из его же установленного Claude Code.
    # Захардкоженного списка моделей здесь намеренно нет: он и устаревает с каждым
    # релизом, и не наше дело его публиковать. Пробелы закрывает правило ниже —
    # «наблюдение сильнее таблицы»: токенов больше окна, значит окно на самом деле больше.
    models = {**scrape_model_windows(), **observed}
    write_json(WINDOW_CACHE, {"version": version, "models": models, "observed": observed})
    return models


FAMILIES = ("opus", "sonnet", "haiku", "fable", "mythos")


def family_of(model_id):
    return next((part for part in model_id.split("-") if part in FAMILIES), "")


def window_for(model_id, windows):
    """Размер окна и признак «знаем точно». Логика повторяет hooks/update.js — держать вместе.

    Таблица неполна не по недосмотру: транскрипт пишет имя обслужившей модели, а его в
    локальном реестре может не быть вовсе. Замер на Claude Code 2.1.205 — реестр знает
    claude-opus-4-8 и алиас opus на него, транскрипт говорит claude-opus-5, и такого имени
    в бинаре нет ни одного. Падение на дефолт 200k давало 77% там, где честные 15%, поэтому
    незнакомое имя берёт самое широкое окно своей же семьи: внутри семьи окно от поколения
    к поколению не сужалось ни разу. Это всё ещё догадка — отсюда второе значение.
    """
    mid = (model_id or "").lower()
    if "[1m]" in mid:
        return 1_000_000, True
    base = re.sub(r"-\d{8}$", "", mid)
    if base in windows:
        return windows[base], True
    family = family_of(base)
    kin = [w for name, w in windows.items() if family_of(name) == family]
    if family and kin:
        return max(kin), False
    return DEFAULT_WINDOW, False


def tail_lines(path, nbytes=2_000_000):
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        fh.seek(max(0, size - nbytes))
        chunk = fh.read()
    if size > nbytes:
        chunk = chunk.split(b"\n", 1)[-1]
    return chunk.split(b"\n")


def usable_assistant_record(record):
    if record.get("type") != "assistant" or record.get("isSidechain"):
        return False
    message = record.get("message") or {}
    if message.get("model") == "<synthetic>":
        return False
    blocks = message.get("content") or []
    if blocks and isinstance(blocks[0], dict):
        if blocks[0].get("text") in SKIP_TEXTS:
            return False
    return "input_tokens" in (message.get("usage") or {})


def context_of(transcript, windows):
    """Формула повторяет ту, что Claude Code отдаёт в statusLine.

    used% = clamp(round((input + cache_creation + cache_read) / window * 100), 0, 100).
    output_tokens в знаменатель НЕ входит. Сверено с живым payload: 55455 токенов → 28%.
    """
    try:
        lines = tail_lines(transcript)
    except OSError:
        return None
    for raw in reversed(lines):
        if b'"usage"' not in raw:
            continue
        record = read_json_line(raw)
        if not record or not usable_assistant_record(record):
            continue
        message = record["message"]
        usage = message["usage"]
        total = (
            usage["input_tokens"]
            + usage.get("cache_creation_input_tokens", 0)
            + usage.get("cache_read_input_tokens", 0)
        )
        window, exact = window_for(message.get("model", ""), windows)
        assumed = not exact
        if total > window:
            # Наблюдение противоречит таблице: столько токенов в окно 200k физически
            # не влезло бы. Значит сессия идёт в миллионном окне, а таблица отстала.
            # Честнее показать пересчёт с пометкой, чем упереться в фальшивые 100%.
            window = 1_000_000
            assumed = True
        return {
            "pct": max(0, min(100, round(total / window * 100))),
            "tokens": total,
            "window": window,
            "model": message.get("model"),
            "assumed": assumed,
        }
    return None


def live_sessions():
    """Сессии ведут Node-хуки; здесь их файлы только читаются — для текстового отчёта.

    Заполненность контекста хук считает сам на каждом событии. У сессии, открытой ещё
    до установки, её может не быть — такую добираем по транскрипту.

    Мёртвые записи здесь НЕ удаляются, хотя раньше удалялись: чистка теперь одна, в
    приложении (оно же следит за живостью по pid). Два уборщика на один каталог
    отнимали бы файл друг у друга посреди чтения.
    """
    windows = None
    out = []
    for path in glob.glob(os.path.join(SESSIONS, "*.json")):
        info = read_json(path, {})
        if not info:
            continue
        # Та же граница, что в session_cwds(): pid ≤ 0 сигналит группе и «жив» всегда.
        try:
            pid = int(info.get("pid"))
            if pid <= 0:
                continue
            os.kill(pid, 0)
        except (OSError, ValueError, TypeError):
            continue
        entry = {
            "id": (info.get("sessionId") or "")[:8],
            "project": info.get("project") or "",
            "entrypoint": info.get("entrypoint") or "",
            "ts": info.get("ts") or 0,
        }
        for key in ("pct", "tokens", "window", "model"):
            if info.get(key) is not None:
                entry[key] = info[key]
        transcript = info.get("transcript")
        if entry.get("pct") is None and transcript and os.path.exists(transcript):
            if windows is None:
                windows = model_windows()
            entry.update(context_of(transcript, windows) or {})
        out.append(entry)
    return sorted(out, key=lambda s: s.get("ts") or 0, reverse=True)


# ──────────────────────────────────────────────────────────── сборка состояния

def refresh():
    """Полная проверка — под межпроцессным замком, потому что путей к ней несколько.

    Приложение зовёт `mcpbar.py refresh` напрямую, есть `report --force` и `toggle --refresh`.
    Две проверки разом — это дважды поднятые пользовательские серверы и две записи mcp.json
    наперегонки, где побеждает последняя, а не самая свежая.

    Замок неблокирующий: раз проверка уже идёт, вторая ничего не добавит — честнее сразу
    вернуть последнюю картину, идущая проверка перепишет её через считанные секунды.
    flock отпускается закрытием дескриптора, то есть и при аварийном выходе процесса —
    протухший замок невозможен.
    """
    import fcntl

    secure_root()
    # Дескриптор нужен только под flock, содержимое файла не пишется вовсе. Взаимное
    # исключение — flock, не байты; выход из with отпускает замок в любом исходе.
    with os.fdopen(os.open(LOCK, os.O_WRONLY | os.O_CREAT, SECURE_FILE), "w") as fh:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return load_state()
        return _refresh_locked()


def _refresh_locked():
    servers, error = run_health_check()
    previous = load_state()

    # Проверка сорвалась (сеть, гонка двух запусков, занятый бинарь) — НЕ затирать
    # последнюю удачную картину пустотой: индикатор обнулялся бы на ровном месте.
    # Показываем прошлые данные и честно помечаем их устаревшими.
    if error and not servers and previous.get("servers"):
        stale = dict(previous)
        stale["error"] = error
        stale["stale_since"] = previous.get("checked_at", 0)
        write_json(STATE, stale)
        return stale

    config = read_json(CONFIG, {})
    local = set(config.get("mcpServers") or {})
    for entry in servers:
        entry["source"] = classify(entry["name"], local)

    # Серверы проектов живых сессий — тем же `claude mcp list`, но из каталога проекта:
    # общая проверка выше их не видит, её cwd закреплён на корне.
    #
    # Одно имя — одна строка, и это не упрощение: settings.json адресует сервер единственным
    # полем serverName, поэтому два тумблера на одно имя врали бы — выключение «db в alpha»
    # гасит db во всех проектах разом. Но состояния у одноимённых серверов разные, и зелёная
    # строка поверх упавшего сервера соседнего проекта — ровно та ложь, ради которой это
    # приложение и написано. Поэтому строка достаётся худшему состоянию, а имя проекта в ней
    # говорит, где именно смотреть.
    by_name = {s["name"]: s for s in servers}
    project_errors = []
    for cwd in project_cwds(session_cwds(), config):
        label = os.path.basename(cwd.rstrip("/")) or cwd
        found, failure = run_health_check(cwd=cwd)
        # Своя переменная, не общая: раньше здесь переиспользовалась `error` общей проверки,
        # и удачный следующий проект обнулял ошибку предыдущего — в меню не оставалось ни
        # упавшего проекта, ни строки «проверка не удалась».
        if failure:
            project_errors.append(f"{label}: {failure}")
            continue
        for entry in found:
            # «⏸ Pending approval» здесь значит именно то, что написано: Claude Code этот
            # сервер не поднял и ждёт ответа человека. Отличаем от своего pending («включён,
            # со следующей сессии») — совет у них противоположный.
            entry["needsApproval"] = entry["state"] == PENDING
            entry["project"] = label
            same_name = by_name.get(entry["name"])
            if same_name is None:
                entry["source"] = "project"
                by_name[entry["name"]] = entry
                servers.append(entry)
            elif SEVERITY.get(entry["state"], 0) > SEVERITY.get(same_name["state"], 0):
                same_name.update(state=entry["state"], status=entry["status"],
                                 project=label, needsApproval=entry["needsApproval"])

    # Строго после всех health-check'ов: каждый из них переписывает stderr-логи, из которых
    # берутся числа инструментов, — в том числе логи серверов проекта.
    attach_tools(servers)

    # Таблицу размеров окон держим свежей здесь, хотя сама она нужна не нам, а Node-хуку:
    # выскребается она из бинаря Claude Code (226 МБ) и в хуке, который срабатывает на
    # каждый вызов инструмента, такому месту не бывать. Кеш привязан к версии бинаря,
    # так что на деле это работа один раз за обновление Claude Code.
    model_windows()

    off = denied_servers()
    rules = denied_tools()
    known = {s["name"] for s in servers}
    # Выключенный сервер исчезает из вывода целиком, вместе со счётчиком инструментов.
    # Достаём его из прошлого состояния: иначе не видно ни как включить обратно,
    # ни сколько инструментов он вернёт в контекст.
    remembered = {s["name"]: s for s in previous.get("servers", [])}
    for name in off:
        if name in known:
            continue
        was = remembered.get(name, {})
        servers.append({
            "name": name, "target": was.get("target", ""), "status": t("server.off"),
            "state": OFF, "source": classify(name, local),
            "tools": was.get("tools"), "toolNames": was.get("toolNames", []),
            "toolPrefix": was.get("toolPrefix") or tool_prefix(name),
        })
    for entry in servers:
        entry["disabled"] = entry["name"] in off
        if entry["disabled"]:
            entry["state"] = OFF
        entry["deniedTools"] = [
            t for t in entry.get("toolNames", [])
            if tool_denied(rules, entry.get("toolPrefix") or entry["name"], t)
        ]

    # Кеш «нужна авторизация» не чистится сам: сервер мог с тех пор подняться,
    # и тогда он попадал в список дважды — и подключённым, и ждущим.
    listed = {s["name"] for s in servers}
    waiting = sorted(n for n in read_json(NEEDS_AUTH, {}) if n not in listed)

    data = {
        "checked_at": time.time(),
        "servers": servers,
        "auth": waiting,
        "sessions": live_sessions(),
        "limits": read_json(LIMITS, {}),
        "denyRules": rules,
    }
    # Ошибки проектов идут рядом с общей, а не вместо неё: общая значит «карты нет вообще»,
    # проектная — «вот этот проект не ответил», и вторая без имени проекта бесполезна.
    problems = ([error] if error else []) + project_errors
    if problems:
        # EPERM вперёд: Swift-меню узнаёт отказ в правах на сетевые тома по этой подстроке и
        # показывает под ошибкой строки «как починить»; при нескольких упавших проектах срез
        # ниже отрезал бы именно её. Сортировка стабильная — внутри групп порядок прежний.
        problems.sort(key=lambda p: "EPERM" not in p)
        # Предел тот же, что у одиночной ошибки: строка уходит в заголовок меню, и десяток
        # неответивших проектов растянул бы его на весь экран.
        data["error"] = "; ".join(problems)[:200]
    write_json(STATE, data)
    return data


def load_state():
    return read_json(STATE, {})


# ──────────────────────────────────────────────────────────── вывод

GLYPH = {OK: "●", FAILED: "✗", PENDING: "⏸", AUTH: "◌", OFF: "○", UNKNOWN: "·"}
COLOR = {OK: "32", FAILED: "31", PENDING: "33", AUTH: "33", OFF: "2", UNKNOWN: "2"}
GROUPS = ["user", "claude.ai", "plugin", "project"]


def report(force=False):
    data = load_state()
    if force or not data or time.time() - data.get("checked_at", 0) > TTL:
        data = refresh()
        # Пустой ответ — это «замок занят, а карты ещё не было»: первый запуск плюс идущая
        # параллельно проверка. Отчёт «0/0 серверов, проверено эпоху назад» звучал бы уверенно
        # и врал бы; честный ответ здесь один — проверка уже идёт.
        if not data:
            return t("check.running")

    tty = sys.stdout.isatty()
    paint = (lambda text, code: f"\x1b[{code}m{text}\x1b[0m") if tty else (lambda text, _: text)

    servers = data.get("servers", [])
    pending = data.get("auth", [])
    width = max([len(s["name"]) for s in servers] + [len(a) for a in pending] + [10])
    out = []

    for key in GROUPS:
        group = sorted(
            (s for s in servers if s.get("source") == key), key=lambda x: x["name"]
        )
        if not group:
            continue
        out.append(paint(t("group." + key), "1"))
        for server in group:
            # Через .get, а не по жёсткому индексу: состояние без значка роняло всю команду
            # KeyError'ом (так и появился unknown — у HTTP-сервера проекта). Теперь unknown
            # работает как запасной выход для любого будущего состояния, а не как запись,
            # которую надо не забыть добавить.
            state = server["state"]
            glyph = paint(GLYPH.get(state, GLYPH[UNKNOWN]), COLOR.get(state, COLOR[UNKNOWN]))
            count = server.get("tools")
            tools = (f"{count} {plural_tools(count)}"
                     if count is not None else t("tools.none")).rjust(10)
            muted = len(server.get("deniedTools") or [])
            note = ""
            if server["state"] == OFF:
                note = "   " + t("server.off")
            elif server["state"] != OK:
                note = f"   {server['status']}"
            elif muted:
                note = "   " + t("server.muted", n=muted)
            out.append(
                f"  {glyph} {server['name']:<{width}}  {paint(tools, '2')}{note}".rstrip())
        out.append("")

    if pending:
        out.append(paint(t("head.auth"), "1"))
        for name in pending:
            mark = paint(GLYPH[AUTH], COLOR[AUTH])
            out.append(f"  {mark} {name:<{width}}   {t('auth.hint')}")
        out.append("")

    measured = [s for s in data.get("sessions", []) if s.get("pct") is not None]
    if measured:
        out.append(paint(t("head.sessions"), "1"))
        for session in measured:
            label = session["project"] or session["id"]
            # .get: запись пишет Node-хук, и pct без tokens/window представим (перенос из
            # старой версии хука) — жёсткий индекс ронял KeyError'ом весь отчёт.
            spent = t("session.spent",
                      used=f"{session.get('tokens') or 0:,}".replace(",", " "),
                      total=f"{session.get('window') or 0:,}".replace(",", " "))
            context = t("session.context", pct=session["pct"])
            out.append(f"  {label:<{width}}  {context}  ({spent})")
        out.append("")

    limits = data.get("limits") or {}
    # The weekly Fable window is per model and arrives only on plans that have it; the app
    # reads the same key (Sources/Model/Limits.swift), so the two must not drift apart.
    windows = (("five_hour", t("limits.five")), ("seven_day", t("limits.seven")),
               ("seven_day_fable", t("limits.fable")))
    if any(limits.get(key) for key, _ in windows):
        out.append(paint(t("head.limits"), "1"))
        for key, label in windows:
            block = limits.get(key)
            if isinstance(block, dict) and block.get("used_percentage") is not None:
                out.append(f"  {label:<{width}}  {block['used_percentage']:>3}%")
        age = int(time.time() - (limits.get("ts") or 0)) // 60
        out.append(paint("  " + t("limits.age", n=age, src=limits.get("source", "?")), "2"))
        out.append("")

    if data.get("error"):
        out.append(paint(t("error.check", e=data["error"]), "31"))
        out.append("")

    visible = [s for s in servers if not s.get("disabled")]
    live = sum(1 for s in visible if s["state"] == OK)
    tools = sum(s.get("tools") or 0 for s in visible)
    summary = t("summary", live=live, total=len(visible),
                tools=tools, word=plural_tools(tools))
    disabled = len(servers) - len(visible)
    if disabled:
        summary += t("summary.off", n=disabled)
    if pending:
        summary += t("summary.auth", n=len(pending))
    out.append(paint(summary, "32" if live == len(visible) else "31"))
    out.append(paint(t("checked", n=int(time.time() - data.get("checked_at", 0))), "2"))
    return "\n".join(out)


def doctor():
    claude = find_claude()
    checks = [
        (t("doc.binary"), claude or t("doc.missing")),
        (t("doc.settings"), SETTINGS if os.path.exists(SETTINGS) else t("doc.nofile")),
        (t("doc.state"), STATE if os.path.exists(STATE) else t("doc.nostate")),
        (t("doc.sessions"), str(len(glob.glob(os.path.join(SESSIONS, "*.json"))))),
        (t("doc.off"), str(len(denied_servers()))),
        (t("doc.rules"), str(len(denied_tools()))),
        (t("doc.windows"), str(len(model_windows()))),
        (t("doc.codex"), newest_rollout() or t("doc.nofile")),
        (t("doc.codexmcp"), str(len((read_json(CODEX_MCP, {}) or {}).get("servers") or []))
         if os.path.exists(CODEX_MCP) else t("doc.nofile")),
        (t("doc.codexhooks"),
         str((read_json(CODEX_HOOKS, {}) or {}).get("untrusted", 0))
         if os.path.exists(CODEX_HOOKS) else t("doc.nofile")),
        (t("lang"), LANG),
    ]
    width = max(len(name) for name, _ in checks) + 2
    return "\n".join(f"{name:<{width}} {value}" for name, value in checks)


# ──────────────────────────────────────────────────────────── точка входа

def flag_value(argv, flag):
    try:
        return argv[argv.index(flag) + 1]
    except (ValueError, IndexError):
        return ""


def refused(exc, rest):
    # mcp.json пересчитывается и при отказе: меню уже показало оптимистичную догадку, и
    # именно перечитанный файл её отменяет. Причина — в stderr и код 2: приложение выводит
    # stderr бэкенда в лог только при ненулевом выходе.
    refresh() if "--refresh" in rest else patch_state_after_toggle()
    print("refused: %s" % exc, file=sys.stderr)
    return 2


def main(argv):
    command = argv[0] if argv else "report"
    rest = argv[1:]

    if command == "refresh":
        refresh()
    elif command == "report":
        print(report(force="--force" in rest))
    elif command == "doctor":
        print(doctor())
    elif command == "limits":
        print(fetch_limits())
    elif command == "codex-limits":
        print(fetch_codex_limits())
    elif command == "codex-hooks":
        print(approve_codex_hooks() if rest[:1] == ["approve"] else fetch_codex_hooks())
    elif command == "codex-mcp":
        # Своё слово после команды, как у statusline: три действия над одним файлом, и
        # отдельные команды верхнего уровня для них читались бы как отдельные подсистемы.
        verb = rest[0] if rest else ""
        target = next((a for a in rest[1:] if not a.startswith("--")), "")
        turn_off = "--off" in rest
        if verb == "refresh":
            print(refresh_codex_mcp())
        elif verb == "toggle-server":
            if not target:
                print(__doc__)
                return 1
            try:
                changed = toggle_codex_server(target, turn_off)
            except Refused as exc:
                print(f"refused: {exc}", file=sys.stderr)
                return 2
            # Перечитываем у Codex, а не правим свой файл руками: состояние сервера после
            # записи — его ответ, не наша догадка.
            refresh_codex_mcp()
            print("changed" if changed else "unchanged")
        elif verb == "toggle-tool":
            server = flag_value(rest, "--server")
            tool = flag_value(rest, "--tool")
            if not server or not tool:
                print(__doc__)
                return 1
            try:
                changed = toggle_codex_tool(server, tool, turn_off)
            except Refused as exc:
                print(f"refused: {exc}", file=sys.stderr)
                return 2
            if changed:
                refresh_codex_mcp()
            print("changed" if changed else "unchanged")
        else:
            print(__doc__)
            return 1
    elif command == "statusline":
        if "--install" in rest:
            print(statusline_install())
        elif "--uninstall" in rest:
            print(statusline_uninstall())
        else:
            current, ours = statusline_state()
            print(t("sl.on" if ours else "sl.off")
                  + "\n" + t("sl.current", cmd=current or t("sl.unset")))
    elif command in ("toggle-server", "toggle-tool"):
        turn_off = "--off" in rest
        # Первое не-флаговое слово, а не rest[0]: `toggle-tool --off` без цели писал бы
        # правило "--off" прямо в permissions.deny, а пустой rest ронял IndexError.
        target = next((a for a in rest if not a.startswith("--")), "")
        if command == "toggle-server":
            if not target:
                print(__doc__)
                return 1
            try:
                changed = toggle_server(target, turn_off)
            except Refused as exc:
                return refused(exc, rest)
        else:
            # Приложение присылает и готовое правило (первым словом), и сервер с инструментом
            # по отдельности. Правило нужно старым сборкам скрипта, пара — этой: только здесь
            # известно, какими буквами Claude Code зовёт инструмент, и правило из отображаемого
            # имени сервера не запрещало ничего.
            server, tool = flag_value(rest, "--server"), flag_value(rest, "--tool")
            if server and tool:
                rule, stale = rule_for_tool(server, tool)
            elif target.startswith("mcp__"):
                rule, stale = target, ()
            else:
                print(__doc__)
                return 1
            try:
                changed = toggle_tool(rule, turn_off, stale)
            except Refused as exc:
                return refused(exc, rest)
        # Меню ждёт мгновенного отклика, поэтому по умолчанию только пересчёт признаков.
        # Полная проверка — по явному --refresh.
        refresh() if "--refresh" in rest else patch_state_after_toggle()
        print("changed" if changed else "unchanged")
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
