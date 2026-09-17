#!/usr/bin/env python3
"""Тесты разбора и переключателей.

Запуск: /usr/bin/python3 -m unittest discover -s tests -v
Каждый случай здесь — реальная ошибка, на которую наступили при разработке.
"""

import glob
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

import mcpbar  # noqa: E402


class ParseListLine(unittest.TestCase):
    def test_обычный_сервер(self):
        got = mcpbar.parse_list_line("wiki: npx -y @modelcontextprotocol/server-wiki - ✔ Connected")
        self.assertEqual(got["name"], "wiki")
        self.assertEqual(got["state"], mcpbar.OK)

    def test_имя_с_двоеточиями_не_режется(self):
        """plugin:figma:figma по первому двоеточию превращался в «plugin»."""
        got = mcpbar.parse_list_line("plugin:figma:figma: https://mcp.figma.com/mcp (HTTP) - ✔ Connected")
        self.assertEqual(got["name"], "plugin:figma:figma")

    def test_имя_с_пробелом(self):
        got = mcpbar.parse_list_line("claude.ai Google Calendar: https://x/mcp/v1 - ✔ Connected")
        self.assertEqual(got["name"], "claude.ai Google Calendar")

    def test_команда_с_дефисами_не_ломает_статус(self):
        """У одного сервера команда запуска длиной 1400 символов и полна « - »."""
        command = "node -e const a=1-2; const b=3 - 4; process.exit(0)"
        got = mcpbar.parse_list_line(f"weird: {command} - ✘ Failed to connect")
        self.assertEqual(got["name"], "weird")
        self.assertEqual(got["state"], mcpbar.FAILED)
        self.assertEqual(got["status"], "✘ Failed to connect")

    def test_ожидает_одобрения(self):
        got = mcpbar.parse_list_line("proj: npx thing - ⏸ Pending approval")
        self.assertEqual(got["state"], mcpbar.PENDING)

    def test_мусорные_строки_отбрасываются(self):
        self.assertIsNone(mcpbar.parse_list_line("Checking MCP server health…"))
        self.assertIsNone(mcpbar.parse_list_line(""))


class Classify(unittest.TestCase):
    def test_разделение_по_источникам(self):
        local = {"wiki"}
        self.assertEqual(mcpbar.classify("wiki", local), "user")
        self.assertEqual(mcpbar.classify("claude.ai Figma", local), "claude.ai")
        self.assertEqual(mcpbar.classify("plugin:figma:figma", local), "plugin")
        self.assertEqual(mcpbar.classify("someproj", local), "project")

    def test_короткое_имя(self):
        self.assertEqual(mcpbar.short_name("claude.ai Figma"), "Figma")
        self.assertEqual(mcpbar.short_name("plugin:figma:figma"), "figma")
        self.assertEqual(mcpbar.short_name("wiki"), "wiki")


class ToolDenied(unittest.TestCase):
    def test_точное_имя(self):
        self.assertTrue(mcpbar.tool_denied(["mcp__wiki__DeletePage"], "wiki", "DeletePage"))
        self.assertFalse(mcpbar.tool_denied(["mcp__wiki__DeletePage"], "wiki", "GetPage"))

    def test_правило_на_весь_сервер(self):
        self.assertTrue(mcpbar.tool_denied(["mcp__wiki"], "wiki", "GetPage"))

    def test_глоб(self):
        rules = ["mcp__wiki__Delete*"]
        self.assertTrue(mcpbar.tool_denied(rules, "wiki", "DeleteGrid"))
        self.assertFalse(mcpbar.tool_denied(rules, "wiki", "CreateGrid"))

    def test_чужой_сервер_не_задет(self):
        self.assertFalse(mcpbar.tool_denied(["mcp__wiki"], "yt", "GetPage"))


class Language(unittest.TestCase):
    def setUp(self):
        self._lang = mcpbar.LANG

    def tearDown(self):
        mcpbar.LANG = self._lang

    def test_русские_окончания(self):
        mcpbar.LANG = "ru"
        cases = {1: "инструмент", 2: "инструмента", 5: "инструментов",
                 11: "инструментов", 21: "инструмент", 104: "инструмента",
                 301: "инструмент", 0: "инструментов"}
        for number, expected in cases.items():
            with self.subTest(number=number):
                self.assertEqual(mcpbar.plural_tools(number), expected)

    def test_английские_окончания(self):
        mcpbar.LANG = "en"
        self.assertEqual(mcpbar.plural_tools(1), "tool")
        for number in (0, 2, 5, 11, 301):
            self.assertEqual(mcpbar.plural_tools(number), "tools")

    def test_переключение_языка(self):
        mcpbar.LANG = "en"
        self.assertEqual(mcpbar.t("server.off"), "disabled")
        mcpbar.LANG = "ru"
        self.assertEqual(mcpbar.t("server.off"), "выключен")

    def test_подстановка_значений(self):
        mcpbar.LANG = "ru"
        self.assertEqual(mcpbar.t("server.muted", n=3), "(3 выключено)")

    def test_все_ключи_переведены_на_оба_языка(self):
        for key, value in mcpbar.STRINGS.items():
            with self.subTest(key=key):
                self.assertEqual(len(value), 2, f"{key}: нужны обе формы")
                self.assertTrue(all(v.strip() for v in value), f"{key}: пустой перевод")

    def test_принудительный_язык_из_окружения(self):
        real = os.environ.get("CONTROL_BAR_LANG")
        try:
            os.environ["CONTROL_BAR_LANG"] = "ru"
            self.assertEqual(mcpbar.detect_lang(), "ru")
            os.environ["CONTROL_BAR_LANG"] = "en"
            self.assertEqual(mcpbar.detect_lang(), "en")
        finally:
            if real is None:
                os.environ.pop("CONTROL_BAR_LANG", None)
            else:
                os.environ["CONTROL_BAR_LANG"] = real


class PatchStateAfterToggle(unittest.TestCase):
    """Переключатель обязан отвечать мгновенно, значит правит состояние, а не пересобирает."""

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.settings = os.path.join(self._dir.name, "settings.json")
        self.state = os.path.join(self._dir.name, "state.json")
        with open(self.settings, "w") as fh:
            json.dump({}, fh)
        with open(self.state, "w") as fh:
            json.dump({"checked_at": 1, "servers": [
                {"name": "wiki", "state": "ok", "status": "✔ Connected", "source": "user",
                 "tools": 31, "toolNames": ["GetPage", "DeletePage"], "toolDocs": {}},
            ]}, fh)
        self._saved = (mcpbar.SETTINGS, mcpbar.STATE, mcpbar.ROOT)
        mcpbar.SETTINGS, mcpbar.STATE = self.settings, self.state
        # ROOT — тоже подмена: settings_lock() кладёт файл блокировки в ROOT, и без этого
        # тест писал в настоящий ~/.claude/control-bar.
        mcpbar.ROOT = os.path.join(self._dir.name, "control-bar")

    def tearDown(self):
        mcpbar.SETTINGS, mcpbar.STATE, mcpbar.ROOT = self._saved
        self._dir.cleanup()

    def read_state(self):
        with open(self.state) as fh:
            return json.load(fh)

    def test_выключенный_сервер_помечается(self):
        mcpbar.toggle_server("wiki", turn_off=True)
        mcpbar.patch_state_after_toggle()
        wiki = self.read_state()["servers"][0]
        self.assertTrue(wiki["disabled"])
        self.assertEqual(wiki["state"], "off")

    def test_счётчик_инструментов_не_теряется(self):
        """Иначе не видно, сколько контекста вернёт обратное включение."""
        mcpbar.toggle_server("wiki", turn_off=True)
        mcpbar.patch_state_after_toggle()
        self.assertEqual(self.read_state()["servers"][0]["tools"], 31)

    def test_включение_честно_говорит_что_нужна_новая_сессия(self):
        mcpbar.toggle_server("wiki", turn_off=True)
        mcpbar.patch_state_after_toggle()
        mcpbar.toggle_server("wiki", turn_off=False)
        mcpbar.patch_state_after_toggle()
        wiki = self.read_state()["servers"][0]
        self.assertFalse(wiki["disabled"])
        self.assertEqual(wiki["state"], "pending")

    def test_погашенный_инструмент_виден_в_состоянии(self):
        mcpbar.toggle_tool("mcp__wiki__DeletePage", turn_off=True)
        mcpbar.patch_state_after_toggle()
        self.assertEqual(self.read_state()["servers"][0]["deniedTools"], ["DeletePage"])

    def test_неизвестный_выключенный_сервер_появляется_строкой(self):
        """Иначе его нечем было бы включить обратно: из списка он исчезает целиком."""
        mcpbar.toggle_server("призрак", turn_off=True)
        mcpbar.patch_state_after_toggle()
        names = [s["name"] for s in self.read_state()["servers"]]
        self.assertIn("призрак", names)


class ToolPrefix(unittest.TestCase):
    """Приставка, которой Claude Code зовёт инструмент, — не то же самое, что отображаемое имя
    сервера, а правило deny собирается именно из неё."""

    def test_плагинный_сервер(self):
        self.assertEqual(mcpbar.tool_prefix("plugin:claude-mem:mcp-search"),
                         "plugin_claude-mem_mcp-search")

    def test_коннектор_без_uuid(self):
        self.assertEqual(mcpbar.tool_prefix("claude.ai Control Chrome"), "Control_Chrome")

    def test_коннектор_с_uuid(self):
        """Коннекторы десктопа живут в контексте под uuid, а не под своим названием."""
        self.assertEqual(
            mcpbar.tool_prefix("claude.ai Google Calendar", uuid="b3c4de1c-0f19"),
            "b3c4de1c-0f19")

    def test_обычный_сервер_остаётся_собой(self):
        self.assertEqual(mcpbar.tool_prefix("wiki"), "wiki")

    def test_транскрипт_сильнее_догадки(self):
        """uuid — только догадка: если транскрипт знает сервер под именем, побеждает имя."""
        self.assertEqual(
            mcpbar.tool_prefix("claude.ai Figma", {"figma": ["get_screenshot"]}, "b6d68fb1"),
            "Figma")

    def test_правило_из_отображаемого_имени_ничего_не_запрещало(self):
        """Тумблер гас, а инструмент грузился в каждой новой сессии: правило не совпадало."""
        prefix = mcpbar.tool_prefix("plugin:claude-mem:mcp-search")
        self.assertTrue(mcpbar.tool_denied([f"mcp__{prefix}__search"], prefix, "search"))
        self.assertFalse(
            mcpbar.tool_denied(["mcp__plugin:claude-mem:mcp-search__search"], prefix, "search"))


class StaleToolRules(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        root = self._dir.name
        self.settings = os.path.join(root, "settings.json")
        state = os.path.join(root, "mcp.json")
        with open(state, "w") as fh:
            json.dump({"servers": [{"name": "claude.ai Figma", "toolPrefix": "b6d68fb1"}]}, fh)
        self.saved = {k: getattr(mcpbar, k) for k in ("SETTINGS", "ROOT", "STATE")}
        mcpbar.SETTINGS, mcpbar.ROOT, mcpbar.STATE = self.settings, root, state

    def tearDown(self):
        for key, value in self.saved.items():
            setattr(mcpbar, key, value)
        self._dir.cleanup()

    def test_приставка_берётся_из_состояния(self):
        rule, stale = mcpbar.rule_for_tool("claude.ai Figma", "get_screenshot")
        self.assertEqual(rule, "mcp__b6d68fb1__get_screenshot")
        self.assertIn("mcp__claude.ai Figma__get_screenshot", stale)

    def test_включение_убирает_и_старое_нерабочее_правило(self):
        """Иначе строка, которая ничего не запрещает, осталась бы в настройках навсегда."""
        with open(self.settings, "w") as fh:
            json.dump({"permissions": {"deny": ["mcp__claude.ai Figma__get_screenshot"]}}, fh)
        rule, stale = mcpbar.rule_for_tool("claude.ai Figma", "get_screenshot")
        mcpbar.toggle_tool(rule, turn_off=False, stale=stale)
        with open(self.settings) as fh:
            self.assertNotIn("permissions", json.load(fh))


class DisabledServersStayDown(unittest.TestCase):
    """Опрос описаний — это Popen команды сервера, то есть панель поднимала процесс, который
    пользователь её же тумблером погасил."""

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        root = self._dir.name
        self.saved = {k: getattr(mcpbar, k) for k in ("CONFIG", "SETTINGS", "DESCRIPTIONS")}
        mcpbar.CONFIG = os.path.join(root, "claude.json")
        mcpbar.SETTINGS = os.path.join(root, "settings.json")
        mcpbar.DESCRIPTIONS = os.path.join(root, "descriptions.json")
        with open(mcpbar.CONFIG, "w") as fh:
            json.dump({"mcpServers": {"выключенный": {"command": "true"},
                                      "живой": {"command": "true"}}}, fh)
        with open(mcpbar.SETTINGS, "w") as fh:
            json.dump({"deniedMcpServers": [{"serverName": "выключенный"}]}, fh)
        self.asked = []
        self._ask = mcpbar.ask_server_for_tools
        mcpbar.ask_server_for_tools = lambda name, config, **kw: self.asked.append(name)

    def tearDown(self):
        mcpbar.ask_server_for_tools = self._ask
        for key, value in self.saved.items():
            setattr(mcpbar, key, value)
        self._dir.cleanup()

    def test_выключенный_сервер_не_запускается_за_описаниями(self):
        mcpbar.refresh_descriptions()
        self.assertEqual(self.asked, ["живой"])


class ContextWindow(unittest.TestCase):
    def test_подбор_окна(self):
        windows = {"claude-opus-5": 1_000_000, "claude-sonnet-4-5": 200_000}
        self.assertEqual(mcpbar.window_for("claude-opus-5", windows), (1_000_000, True))
        self.assertEqual(mcpbar.window_for("claude-sonnet-4-5-20260101", windows), (200_000, True))
        self.assertEqual(
            mcpbar.window_for("что-то-незнакомое", windows),
            (mcpbar.DEFAULT_WINDOW, False))

    def test_суффикс_1m(self):
        self.assertEqual(mcpbar.window_for("claude-sonnet-4-5[1m]", {}), (1_000_000, True))

    def test_модель_которой_нет_в_реестре_берёт_окно_своей_семьи(self):
        """Живой случай: транскрипт пишет claude-opus-5, а в бинаре есть только claude-opus-4-8.

        На дефолте 200k сессия со 154 тысячами токенов показывала 77% вместо 15%.
        """
        windows = {
            "claude-opus-4-5": 200_000, "claude-opus-4-8": 1_000_000,
            "claude-haiku-4-5": 200_000,
        }
        self.assertEqual(mcpbar.window_for("claude-opus-5", windows), (1_000_000, False))
        self.assertEqual(mcpbar.window_for("claude-haiku-9", windows), (200_000, False))

    def test_чужая_семья_окно_не_одалживает(self):
        """Иначе haiku унаследовал бы миллион от opus и показывал бы 3% вместо 100%."""
        windows = {"claude-opus-4-8": 1_000_000}
        self.assertEqual(
            mcpbar.window_for("claude-haiku-7", windows),
            (mcpbar.DEFAULT_WINDOW, False))

    def test_служебные_записи_пропускаются(self):
        """Без этого фильтра индикатор показывал 0% на прерванном ходе."""
        synthetic = {"type": "assistant", "message": {
            "model": "<synthetic>", "usage": {"input_tokens": 10}}}
        interrupted = {"type": "assistant", "message": {
            "model": "claude-opus-5", "usage": {"input_tokens": 10},
            "content": [{"text": "[Request interrupted by user]"}]}}
        sidechain = {"type": "assistant", "isSidechain": True, "message": {
            "model": "claude-opus-5", "usage": {"input_tokens": 10}}}
        good = {"type": "assistant", "message": {
            "model": "claude-opus-5", "usage": {"input_tokens": 10},
            "content": [{"text": "нормальный ответ"}]}}
        self.assertFalse(mcpbar.usable_assistant_record(synthetic))
        self.assertFalse(mcpbar.usable_assistant_record(interrupted))
        self.assertFalse(mcpbar.usable_assistant_record(sidechain))
        self.assertTrue(mcpbar.usable_assistant_record(good))

    def test_таблица_собирается_локально_и_не_зашита_в_код(self):
        """Список моделей не наш, чтобы его публиковать: он читается из установленного CLI."""
        self.assertFalse(hasattr(mcpbar, "FALLBACK_WINDOWS"))
        self.assertIsInstance(mcpbar.model_windows(), dict)

    def test_неизвестная_модель_получает_умолчание(self):
        self.assertEqual(
            mcpbar.window_for("совсем-новая-модель", {}), (mcpbar.DEFAULT_WINDOW, False))

    def test_наблюдение_перебивает_устаревшую_таблицу(self):
        """413 тысяч токенов в окно 200k не влезли бы — значит таблица отстала."""
        transcript = os.path.join(self.tmp, "big.jsonl")
        record = {"type": "assistant", "message": {
            "model": "неизвестная-модель",
            "content": [{"text": "ok"}],
            "usage": {"input_tokens": 413862, "cache_creation_input_tokens": 0,
                      "cache_read_input_tokens": 0}}}
        with open(transcript, "w") as fh:
            fh.write(json.dumps(record) + "\n")
        got = mcpbar.context_of(transcript, {})
        self.assertTrue(got["assumed"])
        self.assertEqual(got["window"], 1_000_000)
        self.assertEqual(got["pct"], 41)

    def test_процент_считается_как_в_cli(self):
        """output_tokens в знаменатель не входит — сверено с живым payload statusLine."""
        transcript = os.path.join(self.tmp, "t.jsonl")
        record = {"type": "assistant", "message": {
            "model": "claude-sonnet-4-5",
            "content": [{"text": "ok"}],
            "usage": {"input_tokens": 55455, "cache_creation_input_tokens": 0,
                      "cache_read_input_tokens": 0, "output_tokens": 9999}}}
        with open(transcript, "w") as fh:
            fh.write(json.dumps(record) + "\n")
        got = mcpbar.context_of(transcript, {"claude-sonnet-4-5": 200_000})
        self.assertEqual(got["pct"], 28)
        self.assertEqual(got["tokens"], 55455)

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.tmp = self._dir.name
        # WINDOW_CACHE подменяется тоже: model_windows() ПИШЕТ таблицу, и без подмены тест лез
        # в настоящий ~/.claude/control-bar живой установки — то есть менял состояние машины,
        # на которой запущен, и падал там, где домашнего каталога нет вовсе.
        self._window_cache = mcpbar.WINDOW_CACHE
        mcpbar.WINDOW_CACHE = os.path.join(self.tmp, "model-windows.json")

    def tearDown(self):
        mcpbar.WINDOW_CACHE = self._window_cache
        self._dir.cleanup()


class Toggles(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.settings = os.path.join(self._dir.name, "settings.json")
        with open(self.settings, "w") as fh:
            json.dump({"alwaysThinkingEnabled": True}, fh)
        # ROOT подменяется вместе с SETTINGS: settings_lock() кладёт файл блокировки в ROOT,
        # и без подмены тест писал в настоящий ~/.claude/control-bar живой установки.
        self._real = (mcpbar.SETTINGS, mcpbar.ROOT)
        mcpbar.SETTINGS = self.settings
        mcpbar.ROOT = os.path.join(self._dir.name, "control-bar")

    def tearDown(self):
        mcpbar.SETTINGS, mcpbar.ROOT = self._real
        self._dir.cleanup()

    def read(self):
        with open(self.settings) as fh:
            return json.load(fh)

    def test_сервер_выключается_объектом_а_не_строкой(self):
        """Плоскую строку Claude Code молча игнорирует — проверено на живом бинаре."""
        mcpbar.toggle_server("wiki", turn_off=True)
        self.assertEqual(self.read()["deniedMcpServers"], [{"serverName": "wiki"}])

    def test_цикл_не_оставляет_следов(self):
        before = self.read()
        mcpbar.toggle_server("wiki", turn_off=True)
        mcpbar.toggle_server("wiki", turn_off=False)
        self.assertEqual(self.read(), before)

    def test_инструмент_не_оставляет_пустой_ключ(self):
        before = self.read()
        mcpbar.toggle_tool("mcp__wiki__DeletePage", turn_off=True)
        self.assertEqual(self.read()["permissions"]["deny"], ["mcp__wiki__DeletePage"])
        mcpbar.toggle_tool("mcp__wiki__DeletePage", turn_off=False)
        self.assertEqual(self.read(), before)

    def test_повторное_выключение_ничего_не_меняет(self):
        self.assertTrue(mcpbar.toggle_server("wiki", turn_off=True))
        self.assertFalse(mcpbar.toggle_server("wiki", turn_off=True))

    def test_чужие_настройки_сохраняются(self):
        mcpbar.toggle_server("wiki", turn_off=True)
        self.assertTrue(self.read()["alwaysThinkingEnabled"])

    def test_чужие_правила_запрета_сохраняются(self):
        with open(self.settings, "w") as fh:
            json.dump({"permissions": {"deny": ["WebSearch"], "allow": ["Bash"]}}, fh)
        mcpbar.toggle_tool("mcp__wiki__DeletePage", turn_off=True)
        after = self.read()["permissions"]
        self.assertIn("WebSearch", after["deny"])
        self.assertEqual(after["allow"], ["Bash"])


class ConcurrentToggles(unittest.TestCase):
    """Гонка настоящими процессами, не имитацией: каждый клик в приложении — отдельный
    процесс на глобальной очереди. До файловой блокировки два одновременных переключения
    теряли одно из двух изменений в 43 прогонах из 50."""

    def test_параллельные_переключения_не_теряют_друг_друга(self):
        import subprocess

        home = tempfile.mkdtemp()
        os.makedirs(os.path.join(home, ".claude"), exist_ok=True)
        settings = os.path.join(home, ".claude", "settings.json")
        with open(settings, "w") as fh:
            json.dump({"hooks": {"keep": "me"}}, fh)
        script = ("import sys; sys.path.insert(0, %r); import mcpbar; "
                  "mcpbar.toggle_server(sys.argv[1], turn_off=True)"
                  % os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))
        procs = [
            subprocess.Popen([sys.executable, "-c", script, f"srv{i}"],
                             env={**os.environ, "HOME": home})
            for i in range(12)
        ]
        for p in procs:
            self.assertEqual(p.wait(timeout=60), 0)
        with open(settings) as fh:
            after = json.load(fh)
        denied = {d["serverName"] for d in after.get("deniedMcpServers", [])}
        self.assertEqual(denied, {f"srv{i}" for i in range(12)})
        self.assertEqual(after.get("hooks"), {"keep": "me"})

    def test_права_файла_переживают_переключатель(self):
        import subprocess

        home = tempfile.mkdtemp()
        os.makedirs(os.path.join(home, ".claude"), exist_ok=True)
        settings = os.path.join(home, ".claude", "settings.json")
        with open(settings, "w") as fh:
            json.dump({}, fh)
        os.chmod(settings, 0o600)
        script = ("import sys; sys.path.insert(0, %r); import mcpbar; "
                  "mcpbar.toggle_server('x', turn_off=True)"
                  % os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))
        subprocess.run([sys.executable, "-c", script], env={**os.environ, "HOME": home}, check=True)
        # Временный файл рождается с umask 0644; без явного chmod он подменял собой
        # файл 0600 — и env-значения MCP-серверов становились читаемы всем локальным.
        self.assertEqual(os.stat(settings).st_mode & 0o777, 0o600)


class StatusLineObject(unittest.TestCase):
    """Установка перехвата обязана пережить ВСЕ поля statusLine, не только command:
    padding, refreshInterval и hideVimModeIndicator — поддерживаемые настройки Claude Code,
    и первая версия install молча их съедала, а uninstall не возвращал."""

    ORIGINAL = {
        "type": "command", "command": "printf old",
        "padding": 2, "refreshInterval": 5, "hideVimModeIndicator": True,
    }

    def setUp(self):
        self.home = tempfile.mkdtemp()
        claude = os.path.join(self.home, ".claude")
        os.makedirs(os.path.join(claude, "control-bar"), exist_ok=True)
        self.settings = os.path.join(claude, "settings.json")
        with open(self.settings, "w") as fh:
            json.dump({"statusLine": dict(self.ORIGINAL)}, fh)
        self.patched = {
            "SETTINGS": self.settings,
            "ROOT": os.path.join(claude, "control-bar"),
            "STATUSLINE_INNER": os.path.join(claude, "control-bar", "statusline-inner-command"),
            "STATUSLINE_SAVED": os.path.join(claude, "control-bar", "statusline-saved.json"),
            "STATUSLINE_INSTALLED": os.path.join(claude, "control-bar", "statusline-installed.json"),
        }
        self.saved = {k: getattr(mcpbar, k) for k in self.patched}
        for k, v in self.patched.items():
            setattr(mcpbar, k, v)
        # Обёртка ищется рядом со скриптом; в тестовом прогоне она есть в репозитории.

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(mcpbar, k, v)

    def read(self):
        with open(self.settings) as fh:
            return json.load(fh)

    def test_установка_сохраняет_дополнительные_поля_живыми(self):
        mcpbar.statusline_install()
        after = self.read()["statusLine"]
        self.assertIn("statusline.sh", after["command"])
        self.assertEqual(after["padding"], 2)
        self.assertEqual(after["refreshInterval"], 5)
        self.assertTrue(after["hideVimModeIndicator"])

    def test_откат_возвращает_объект_целиком(self):
        mcpbar.statusline_install()
        mcpbar.statusline_uninstall()
        self.assertEqual(self.read()["statusLine"], self.ORIGINAL)

    def test_откат_без_исходного_statusline_убирает_ключ(self):
        with open(self.settings, "w") as fh:
            json.dump({}, fh)
        mcpbar.statusline_install()
        mcpbar.statusline_uninstall()
        self.assertNotIn("statusLine", self.read())

    def test_битый_settings_не_затирается_установкой(self):
        """Тот же контракт, что у тумблеров: невалидный файл — отказ, а не «файла нет».

        Без него `read_json(...) or {}` читал оборванный JSON как пустые настройки, и файл
        целиком — вместе с permissions.deny и env, где лежат токены серверов, — заменялся одним
        ключом statusLine. Резервной копии не оставалось тоже: backup_settings() на нечитаемом
        файле молча возвращает None.
        """
        broken = '{"statusLine": {"command": "printf old"},'
        with open(self.settings, "w") as fh:
            fh.write(broken)
        mcpbar.statusline_install()
        with open(self.settings) as fh:
            self.assertEqual(fh.read(), broken)
        self.assertFalse(os.path.exists(self.patched["STATUSLINE_SAVED"]))

    def test_чужая_строка_состояния_не_считается_нашей(self):
        """statusline.sh — имя из официального примера в документации Claude Code. По подстроке
        install отвечал «уже установлен» и не делал ничего, а uninstall удалял чужую команду."""
        foreign = 'bash "$HOME/.claude/statusline.sh"'
        with open(self.settings, "w") as fh:
            json.dump({"statusLine": {"type": "command", "command": foreign}}, fh)
        self.assertFalse(mcpbar.statusline_state()[1])
        mcpbar.statusline_uninstall()
        self.assertEqual(self.read()["statusLine"]["command"], foreign)
        mcpbar.statusline_install()
        self.assertIn("statusline.sh", self.read()["statusLine"]["command"])
        self.assertEqual(mcpbar.read_json(self.patched["STATUSLINE_SAVED"])["command"], foreign)

    def test_команда_кладётся_с_правами_владельца(self):
        """В сохранённой команде бывает что угодно, включая ключи; каталог живёт под 0600."""
        mcpbar.statusline_install()
        mode = os.stat(self.patched["STATUSLINE_INNER"]).st_mode & 0o777
        self.assertEqual(mode, mcpbar.SECURE_FILE)

    def test_ручная_замена_после_установки_не_считается_нашей(self):
        """След установки (сайдкары) — не доказательство, что ТЕКУЩАЯ команда наша.

        По одному факту их существования uninstall восстанавливал сохранённую при установке
        команду поверх той, которую человек поставил руками ПОСЛЕ, — то есть затирал самую
        свежую его настройку самой старой.
        """
        mcpbar.statusline_install()
        replacement = 'bash "$HOME/bin/replacement-statusline.sh"'
        data = self.read()
        data["statusLine"] = {"type": "command", "command": replacement}
        with open(self.settings, "w") as fh:
            json.dump(data, fh)
        self.assertFalse(mcpbar.statusline_state()[1])
        mcpbar.statusline_uninstall()
        self.assertEqual(self.read()["statusLine"]["command"], replacement)

    def test_живой_чужой_statusline_после_нашей_установки_не_наш(self):
        """Самый жёсткий случай: чужой файл называется ровно statusline.sh и существует."""
        mcpbar.statusline_install()
        foreign = os.path.join(self.home, "bin", "statusline.sh")
        os.makedirs(os.path.dirname(foreign))
        with open(foreign, "w") as fh:
            fh.write("#!/bin/bash\nprintf mine\n")
        data = self.read()
        data["statusLine"] = {"type": "command", "command": f'bash "{foreign}"'}
        with open(self.settings, "w") as fh:
            json.dump(data, fh)
        self.assertFalse(mcpbar.statusline_state()[1])
        mcpbar.statusline_uninstall()
        self.assertEqual(self.read()["statusLine"]["command"], f'bash "{foreign}"')

    def test_нераскрытая_переменная_в_чужой_команде_не_наша(self):
        """shlex не раскрывает ни ~, ни $HOME — os.path.exists на таком слове всегда False,
        и чужая ЖИВАЯ команда читалась как мёртвая обёртка прошлой версии. Пока установка
        вела запись, «не существует на диске» — не аргумент."""
        mcpbar.statusline_install()
        for foreign in ('bash ~/.claude/statusline.sh', 'bash "$HOME/bin/statusline.sh"'):
            data = self.read()
            data["statusLine"] = {"type": "command", "command": foreign}
            with open(self.settings, "w") as fh:
                json.dump(data, fh)
            self.assertFalse(mcpbar.statusline_state()[1], foreign)

    def test_обёртка_прошлой_версии_с_мёртвым_путём_остаётся_нашей(self):
        """Путь плагина несёт версию и переезжает при обновлении: файла обёртки уже нет,
        но команда в настройках — та самая, что писала установка. Такую uninstall обязан
        уметь откатить, иначе после обновления плагина перехват не снять."""
        dead = os.path.join(self.home, "plugin-old", "hooks", "statusline.sh")
        with open(self.settings, "w") as fh:
            json.dump({"statusLine": {"type": "command", "command": f'bash "{dead}"'}}, fh)
        mcpbar.write_json(self.patched["STATUSLINE_SAVED"], dict(self.ORIGINAL))
        with open(self.patched["STATUSLINE_INNER"], "w") as fh:
            fh.write(self.ORIGINAL["command"] + "\n")
        self.assertTrue(mcpbar.statusline_state()[1])
        mcpbar.statusline_uninstall()
        self.assertEqual(self.read()["statusLine"], self.ORIGINAL)

    def test_интеграция_чужой_statusline_установка_исполнение_замена_откат(self):
        """Вся цепочка целиком: чужая строка состояния с именем из документации → установка
        перехвата → обёртка РЕАЛЬНО исполняет чужую команду → ручная замена → откат её не
        затирает. Каждый шаг здесь ломался по-своему: обёртка глушила чужой statusline.sh по
        имени, а uninstall восстанавливал сохранённое поверх ручной замены."""
        foreign = os.path.join(self.home, "bin", "statusline.sh")
        os.makedirs(os.path.dirname(foreign))
        with open(foreign, "w") as fh:
            fh.write("#!/bin/bash\nprintf 'FOREIGN OK'\n")
        os.chmod(foreign, 0o755)
        with open(self.settings, "w") as fh:
            json.dump({"statusLine": {"type": "command", "command": f'bash "{foreign}"'}}, fh)

        mcpbar.statusline_install()
        wrapped = self.read()["statusLine"]["command"]
        self.assertIn("statusline.sh", wrapped)
        result = subprocess.run(
            ["bash", "-c", wrapped], input="{}", capture_output=True, text=True,
            env={**os.environ, "CONTROL_BAR_ROOT": self.patched["ROOT"]}, timeout=30,
        )
        self.assertEqual(result.stdout, "FOREIGN OK")

        replacement = 'printf mine'
        data = self.read()
        data["statusLine"] = {"type": "command", "command": replacement}
        with open(self.settings, "w") as fh:
            json.dump(data, fh)
        mcpbar.statusline_uninstall()
        self.assertEqual(self.read()["statusLine"]["command"], replacement)

    def test_неудачная_запись_настроек_не_оставляет_сайдкаров(self):
        """Сайдкары пишутся до settings.json. Если сама запись сорвалась (файл правит кто-то
        ещё), недоделанная установка не имеет права оставлять след: по нему следующая проверка
        решила бы, что перехват стоит."""
        original = mcpbar.write_settings
        mcpbar.write_settings = lambda *a, **k: False
        try:
            mcpbar.statusline_install()
        finally:
            mcpbar.write_settings = original
        self.assertFalse(os.path.exists(self.patched["STATUSLINE_INNER"]))
        self.assertFalse(os.path.exists(self.patched["STATUSLINE_SAVED"]))
        self.assertFalse(os.path.exists(self.patched["STATUSLINE_INSTALLED"]))
        self.assertEqual(self.read()["statusLine"], self.ORIGINAL)


class ProjectServers(unittest.TestCase):
    """Серверы local- и project-scope видны только из каталога проекта, поэтому общий
    `claude mcp list` (его cwd закреплён на корне) их не показывает — они добираются
    из конфигурации по каталогам живых сессий."""

    def test_каталог_с_серверами_обоих_scope_попадает_в_список(self):
        cwd = tempfile.mkdtemp()
        with open(os.path.join(cwd, ".mcp.json"), "w") as fh:
            json.dump({"mcpServers": {"repo-tool": {"command": "./run.sh"}}}, fh)
        self.assertEqual(mcpbar.project_cwds([cwd], {}), [cwd])

        other = tempfile.mkdtemp()
        config = {"projects": {other: {"mcpServers": {"mine": {"command": "echo"}}}}}
        self.assertEqual(mcpbar.project_cwds([other], config), [other])

    def test_проект_без_конфигурации_даёт_пусто(self):
        """Пустой список значит «не звать сюда claude mcp list» — а это полминуты."""
        self.assertEqual(mcpbar.project_cwds([tempfile.mkdtemp()], {}), [])

    def test_команда_из_mcp_json_не_запускается(self):
        """Главное правило: .mcp.json лежит в репозитории, который мог написать кто угодно.

        Раньше эта конфигурация читалась и её команда уходила в Popen — достаточно было
        склонировать чужой репозиторий и открыть его. Теперь скрипт только смотрит, есть ли
        в каталоге серверы, и дальше спрашивает `claude mcp list`: что из .mcp.json поднимать,
        а что держать в «⏸ Pending approval», решает Claude Code, у которого одобрение и есть.
        """
        cwd = tempfile.mkdtemp()
        marker = os.path.join(cwd, "executed")
        with open(os.path.join(cwd, ".mcp.json"), "w") as fh:
            json.dump({"mcpServers": {
                "evil": {"command": "/usr/bin/touch", "args": [marker]},
            }}, fh)
        self.assertEqual(mcpbar.project_cwds([cwd], {}), [cwd])
        self.assertFalse(os.path.exists(marker), "команда из .mcp.json была выполнена")

    def test_ожидающий_одобрения_сервер_разбирается_как_pending(self):
        """Строка, которой Claude Code отвечает про неодобренный сервер, — наш признак."""
        got = mcpbar.parse_list_line("repo-tool: npx thing - ⏸ Pending approval")
        self.assertEqual(got["state"], mcpbar.PENDING)

    def test_битый_mcp_json_не_прячет_проект(self):
        """Сломанный конфиг — как раз то, про что инструмент здоровья обязан сказать.

        Разбор здесь только фильтр «есть ли смысл звать claude mcp list», а не чтение
        конфигурации; ошибка разбора убирала весь проект из карты молча, вместе с уже
        поднятыми серверами.
        """
        cwd = tempfile.mkdtemp()
        with open(os.path.join(cwd, ".mcp.json"), "w") as fh:
            fh.write("{ broken json")
        self.assertEqual(mcpbar.project_cwds([cwd], {}), [cwd])

    def test_конфиг_не_объектом_тоже_идёт_на_проверку(self):
        cwd = tempfile.mkdtemp()
        with open(os.path.join(cwd, ".mcp.json"), "w") as fh:
            json.dump(["nonsense"], fh)
        self.assertEqual(mcpbar.project_cwds([cwd], {}), [cwd])

    def test_целый_но_пустой_конфиг_проверку_не_вызывает(self):
        """Здесь искать нечего, а вызов стоит полминуты — ради этого фильтр и существует."""
        cwd = tempfile.mkdtemp()
        with open(os.path.join(cwd, ".mcp.json"), "w") as fh:
            json.dump({"mcpServers": {}}, fh)
        self.assertEqual(mcpbar.project_cwds([cwd], {}), [])


class RefreshProjects(unittest.TestCase):
    """Что refresh() делает с проектами: их ошибками и их одноимёнными серверами.

    Оба случая ниже приводили к одному итогу — приложение показывало здоровую картину
    там, где здоровья не было.
    """

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        tmp = self._dir.name
        self.answers = {}
        self.projects = []
        patched = {
            "ROOT": tmp,
            "STATE": os.path.join(tmp, "mcp.json"),
            "LIMITS": os.path.join(tmp, "limits.json"),
            "SESSIONS": os.path.join(tmp, "state.d"),
            "CONFIG": os.path.join(tmp, "claude.json"),
            "SETTINGS": os.path.join(tmp, "settings.json"),
            "NEEDS_AUTH": os.path.join(tmp, "needs-auth.json"),
            "LOCK": os.path.join(tmp, "refresh.lock"),
            # Сеть и Claude Code из проверки убраны целиком: здесь проверяется сборка карты.
            "run_health_check": lambda cwd="/": self.answers.get(cwd, ([], "нет ответа")),
            "session_cwds": lambda: list(self.projects),
            "project_cwds": lambda cwds, config: list(cwds),
            "attach_tools": lambda servers: None,
            "model_windows": lambda: {},
        }
        self.saved = {k: getattr(mcpbar, k) for k in patched}
        for k, v in patched.items():
            setattr(mcpbar, k, v)

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(mcpbar, k, v)
        self._dir.cleanup()

    @staticmethod
    def server(name, state, status="✔ Connected"):
        return {"name": name, "target": "", "status": status, "state": state}

    def test_сорванная_проверка_не_затирает_прошлую_карту(self):
        """Проверка сорвалась целиком (сеть, занятый бинарь): прошлые серверы обязаны остаться
        на экране с честной пометкой stale_since, а не обнулиться в пустое меню."""
        self.answers = {"/": ([self.server("wiki", mcpbar.OK)], None)}
        mcpbar.refresh()
        self.answers = {"/": ([], "claude mcp list не ответил вовремя")}
        data = mcpbar.refresh()
        self.assertEqual([s["name"] for s in data.get("servers", [])], ["wiki"])
        self.assertIn("stale_since", data)
        self.assertIn("не ответил", data.get("error") or "")

    def test_ошибка_проекта_не_исчезает_от_успеха_соседа(self):
        """Одна переменная на общую проверку и на все проекты: упавший проект уходил в
        continue, а следующий удачный обнулял ошибку — в меню не было ни строки «упал»,
        ни строки «проверка не удалась»."""
        self.answers = {
            "/": ([self.server("wiki", mcpbar.OK)], None),
            "/work/broken": ([], "claude mcp list не ответил вовремя"),
            "/work/healthy": ([self.server("db", mcpbar.OK)], None),
        }
        self.projects = ["/work/broken", "/work/healthy"]
        data = mcpbar.refresh()
        self.assertIn("broken", data.get("error") or "")

    def test_ошибка_проекта_названа_поимённо(self):
        self.answers = {
            "/": ([self.server("wiki", mcpbar.OK)], None),
            "/work/broken": ([], "claude mcp list не ответил вовремя"),
        }
        self.projects = ["/work/broken"]
        data = mcpbar.refresh()
        self.assertIn("broken", data.get("error") or "")
        self.assertIn("не ответил", data.get("error") or "")

    def test_eperm_переживает_обрезку_длинного_списка_ошибок(self):
        """Swift-меню узнаёт отказ в правах на сетевые тома по подстроке EPERM и вешает под
        ошибкой строки «как починить». При нескольких упавших проектах 200-символьный срез
        отрезал именно её — EPERM-ошибка шла в конце списка и до меню не доезжала."""
        self.answers = {"/": ([self.server("wiki", mcpbar.OK)], None)}
        long = "claude mcp list не ответил вовремя, подробности длинные и занимают место"
        for i in range(4):
            path = f"/work/noisy-{i}"
            self.answers[path] = ([], long)
            self.projects.append(path)
        self.answers["/work/fuse"] = ([], "error: An internal error occurred (EPERM)")
        self.projects.append("/work/fuse")
        data = mcpbar.refresh()
        error = data.get("error") or ""
        self.assertIn("EPERM", error)
        self.assertLessEqual(len(error), 200)

    def test_упавший_сервер_не_прячется_за_одноимённым_зелёным(self):
        self.answers = {
            "/": ([self.server("wiki", mcpbar.OK)], None),
            "/work/alpha": ([self.server("db", mcpbar.OK)], None),
            "/work/beta": ([self.server("db", mcpbar.FAILED, "✘ Failed to connect")], None),
        }
        self.projects = ["/work/alpha", "/work/beta"]
        rows = [s for s in mcpbar.refresh()["servers"] if s["name"] == "db"]
        # Строка одна: settings.json адресует сервер по имени, и два тумблера на одно имя
        # врали бы в другую сторону — выключение «db в alpha» гасит db везде.
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["state"], mcpbar.FAILED)
        self.assertEqual(rows[0]["project"], "beta")

    def test_зелёный_не_перебивает_упавшего(self):
        """Порядок обхода проектов случаен — правило одностороннее: хуже перебивает лучше."""
        self.answers = {
            "/": ([self.server("wiki", mcpbar.OK)], None),
            "/work/beta": ([self.server("db", mcpbar.FAILED, "✘ Failed to connect")], None),
            "/work/alpha": ([self.server("db", mcpbar.OK)], None),
        }
        self.projects = ["/work/beta", "/work/alpha"]
        rows = [s for s in mcpbar.refresh()["servers"] if s["name"] == "db"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["state"], mcpbar.FAILED)
        self.assertEqual(rows[0]["project"], "beta")


class RefreshLock(unittest.TestCase):
    """Проверка приходит с нескольких сторон разом: statusLine спаунит фоновый refresh,
    приложение зовёт `mcpbar.py refresh` напрямую, есть ещё `report --force`.

    Замок в spawn_refresh() прикрывал только первый путь. Две одновременные проверки — это
    дважды поднятые пользовательские серверы и две записи mcp.json наперегонки: побеждала
    последняя, не обязательно самая свежая. Замок обязан жить в самом refresh().
    """

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        tmp = self._dir.name
        self.checks = []

        def fake_check(cwd="/"):
            self.checks.append(cwd)
            return [], None

        patched = {
            "ROOT": tmp,
            "STATE": os.path.join(tmp, "mcp.json"),
            "LIMITS": os.path.join(tmp, "limits.json"),
            "SESSIONS": os.path.join(tmp, "state.d"),
            "CONFIG": os.path.join(tmp, "claude.json"),
            "SETTINGS": os.path.join(tmp, "settings.json"),
            "NEEDS_AUTH": os.path.join(tmp, "needs-auth.json"),
            "LOCK": os.path.join(tmp, "refresh.lock"),
            "run_health_check": fake_check,
            "session_cwds": lambda: [],
            "project_cwds": lambda cwds, config: [],
            "attach_tools": lambda servers: None,
            "model_windows": lambda: {},
        }
        self.saved = {k: getattr(mcpbar, k) for k in patched}
        for k, v in patched.items():
            setattr(mcpbar, k, v)

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(mcpbar, k, v)
        self._dir.cleanup()

    def test_второй_refresh_при_занятом_локе_не_гоняет_проверку(self):
        """flock держит другой «процесс» (другой дескриптор — семантика та же): refresh
        обязан не запускать health-check и вернуть последнюю картину как есть."""
        import fcntl

        mcpbar.write_json(mcpbar.STATE, {"checked_at": 42, "servers": []})
        holder = open(mcpbar.LOCK, "w")
        fcntl.flock(holder, fcntl.LOCK_EX)
        try:
            data = mcpbar.refresh()
        finally:
            holder.close()
        self.assertEqual(self.checks, [])
        self.assertEqual(data.get("checked_at"), 42)
        self.assertEqual(mcpbar.load_state().get("checked_at"), 42)

    def test_свободный_лок_отпускается_после_проверки(self):
        mcpbar.refresh()
        self.assertTrue(self.checks)
        self.checks.clear()
        mcpbar.refresh()
        self.assertTrue(self.checks, "лок не отпущен — вторая проверка не прошла")

    def test_отчёт_при_занятом_локе_без_карты_говорит_что_проверка_идёт(self):
        """Первый запуск + параллельная проверка: карты ещё нет, замок занят. Отчёт
        «Итого: 0/0, проверено эпоху назад» звучал бы уверенно и врал бы."""
        import fcntl

        holder = open(mcpbar.LOCK, "w")
        fcntl.flock(holder, fcntl.LOCK_EX)
        try:
            out = mcpbar.report(force=True)
        finally:
            holder.close()
        self.assertEqual(out, mcpbar.t("check.running"))


class StatePermissions(unittest.TestCase):
    """В ~/.claude/control-bar/ лежат рабочие каталоги, транскрипты сессий и лимиты аккаунта.

    Домашний каталог на macOS открыт группе staff, в которой состоят все локальные
    пользователи, — при 0644 второй аккаунт машины читал эти файлы свободно.
    """

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self._real = (mcpbar.ROOT, mcpbar.SESSIONS)
        mcpbar.ROOT = os.path.join(self._dir.name, "control-bar")
        mcpbar.SESSIONS = os.path.join(mcpbar.ROOT, "state.d")

    def tearDown(self):
        mcpbar.ROOT, mcpbar.SESSIONS = self._real
        self._dir.cleanup()

    def test_каталог_и_файлы_закрываются_от_чужих(self):
        os.makedirs(mcpbar.SESSIONS)
        os.chmod(mcpbar.ROOT, 0o755)
        os.chmod(mcpbar.SESSIONS, 0o755)
        open_file = os.path.join(mcpbar.ROOT, "limits.json")
        with open(open_file, "w") as fh:
            fh.write("{}")
        os.chmod(open_file, 0o644)

        mcpbar.secure_root()

        self.assertEqual(stat.S_IMODE(os.stat(mcpbar.ROOT).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(mcpbar.SESSIONS).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(open_file).st_mode), 0o600)

    def test_каталог_создаётся_сразу_закрытым(self):
        mcpbar.secure_root()
        self.assertEqual(stat.S_IMODE(os.stat(mcpbar.ROOT).st_mode), 0o700)

    def test_новый_файл_состояния_рождается_закрытым(self):
        mcpbar.secure_root()
        mcpbar.write_json(os.path.join(mcpbar.ROOT, "mcp.json"), {"servers": []})
        self.assertEqual(
            stat.S_IMODE(os.stat(os.path.join(mcpbar.ROOT, "mcp.json")).st_mode), 0o600)


class SettingsSafety(unittest.TestCase):
    """settings.json принадлежит человеку: в нём его правила и env MCP-серверов с токенами.

    Каждый случай здесь — способ, которым переключатель мог этот файл испортить.
    """

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.settings = os.path.join(self._dir.name, "settings.json")
        self._saved = (mcpbar.SETTINGS, mcpbar.STATE, mcpbar.ROOT)
        mcpbar.SETTINGS = self.settings
        mcpbar.STATE = os.path.join(self._dir.name, "state.json")
        # ROOT тоже: без него settings_lock() лезет за файлом блокировки в настоящий
        # ~/.claude/control-bar — тест перестаёт быть герметичным и падает в песочнице.
        mcpbar.ROOT = os.path.join(self._dir.name, "control-bar")

    def tearDown(self):
        mcpbar.SETTINGS, mcpbar.STATE, mcpbar.ROOT = self._saved
        self._dir.cleanup()

    def write(self, text, mode=0o600):
        with open(self.settings, "w") as fh:
            fh.write(text)
        os.chmod(self.settings, mode)

    def read(self):
        with open(self.settings) as fh:
            return fh.read()

    def backups(self):
        return sorted(glob.glob(f"{self.settings}.bak-*"))

    def test_бэкап_не_шире_исходника(self):
        """0600 у настроек — не украшение: в них лежат env MCP-серверов с токенами.

        Резервная копия создавалась заново, копировать режим было неоткуда, и при обычном
        umask 022 она рождалась 0644 — секреты становились читаемы всем на машине.
        """
        self.write(json.dumps({"env": {"TOKEN": "s3cr3t"}}), mode=0o600)
        path = mcpbar.backup_settings()
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)

    def test_чужие_бэкапы_не_ротируются(self):
        """Маска `.bak-2*` совпадает с ЛЮБЫМ датированным бэкапом рядом с настройками — в том
        числе сделанным руками или другим инструментом. Ротация «наших десяти» молча удаляла
        чужие файлы, принадлежность которых приложению ничем не доказана."""
        self.write(json.dumps({"mine": 1}))
        foreign = [f"{self.settings}.bak-20000101-manual-{i:02d}" for i in range(12)]
        for path in foreign:
            with open(path, "w") as fh:
                fh.write("{}")
        mcpbar.backup_settings()
        survivors = [p for p in foreign if os.path.exists(p)]
        self.assertEqual(survivors, foreign)

    def test_два_бэкапа_в_одну_секунду_не_делят_один_снимок(self):
        """Секундного разрешения в имени мало: два быстрых переключения попадали в один файл,
        и второй снимок молча не делался — хотя PRIVACY.md обещает снимок перед КАЖДЫМ."""
        self.write(json.dumps({"version": 1}))
        first = mcpbar.backup_settings()
        self.write(json.dumps({"version": 2}))
        second = mcpbar.backup_settings()
        self.assertNotEqual(first, second)
        self.assertEqual(mcpbar.read_json(first), {"version": 1})
        self.assertEqual(mcpbar.read_json(second), {"version": 2})

    def test_ротация_держит_десять_последних_своих(self):
        self.write(json.dumps({"n": 0}))
        made = []
        for n in range(12):
            self.write(json.dumps({"n": n}))
            made.append(mcpbar.backup_settings())
        alive = [p for p in made if os.path.exists(p)]
        self.assertEqual(len(alive), 10)
        self.assertEqual(alive, made[2:])

    def test_битый_json_не_затирается_переключателем(self):
        """Человек редактирует файл руками; между двумя нажатиями он бывает невалиден.

        read_json() глушила любую ошибку и возвращала None, а вызывающий писал `or {}` —
        то есть «файла нет». Один клик заменял все настройки одним правилом deny, и
        резервной копии тоже не оставалось: backup_settings() на нечитаемом файле выходила.
        """
        broken = '{ "permissions": { "deny": ["Bash(rm:*)"] }, "apiKeyHelper": "x"\n'
        self.write(broken)
        with self.assertRaises(mcpbar.Refused):
            mcpbar.toggle_server("wiki", turn_off=True)
        self.assertEqual(self.read(), broken)

    def test_отказ_из_командной_строки_отличим_от_unchanged(self):
        """Четыре исхода печатались одним словом unchanged; «я не тронул твой битый файл»
        и «уже выключено» — разные ответы, и /mcp-health должен их различать."""
        import contextlib
        import io

        self.write('{ oops\n')
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            code = mcpbar.main(["toggle-server", "wiki", "--off"])
        self.assertEqual(code, 2)
        self.assertIn("refused: settings.json is unreadable", err.getvalue())

    def test_битый_json_не_затирается_переключателем_инструмента(self):
        broken = '{ oops\n'
        self.write(broken)
        with self.assertRaises(mcpbar.Refused):
            mcpbar.toggle_tool("mcp__wiki__DeletePage", turn_off=True)
        self.assertEqual(self.read(), broken)

    def test_чужая_запись_между_чтением_и_заменой_не_теряется(self):
        """Блокировка держит только процессы панели. Claude Code и редактор её не берут.

        Чужая правка имитируется из backup_settings() — она и правда вызывается между
        чтением настроек и их заменой, так что окно тут настоящее, а не выдуманное.
        """
        self.write(json.dumps({"mine": 1}))
        original = mcpbar.backup_settings

        def someone_else_writes_first():
            result = original()
            with open(self.settings, "w") as fh:
                json.dump({"mine": 1, "theirs": 2}, fh)
            return result

        mcpbar.backup_settings = someone_else_writes_first
        try:
            with self.assertRaises(mcpbar.Refused):
                mcpbar.toggle_server("wiki", turn_off=True)
        finally:
            mcpbar.backup_settings = original
        with open(self.settings) as fh:
            self.assertEqual(json.load(fh), {"mine": 1, "theirs": 2})

    def test_symlink_на_dotfiles_остаётся_symlink(self):
        """Настройки часто симлинк в ~/dotfiles. os.replace заменял саму ссылку обычным
        файлом: оригинал в dotfiles оставался старым, а синхронизация тихо умирала."""
        target = os.path.join(self._dir.name, "dotfiles-settings.json")
        with open(target, "w") as fh:
            json.dump({"mine": 1}, fh)
        os.symlink(target, self.settings)
        self.assertTrue(mcpbar.toggle_server("wiki", turn_off=True))
        self.assertTrue(os.path.islink(self.settings), "симлинк заменён обычным файлом")
        with open(target) as fh:
            self.assertIn("deniedMcpServers", json.load(fh))


class ReportGlyphs(unittest.TestCase):
    def test_каждое_состояние_имеет_значок_и_цвет(self):
        """`/mcp-health` печатает GLYPH[state] по жёсткому индексу: состояние без значка
        роняет всю команду KeyError'ом. Первым таким стал unknown у HTTP-сервера проекта."""
        for state in (mcpbar.OK, mcpbar.FAILED, mcpbar.PENDING, mcpbar.AUTH,
                      mcpbar.OFF, mcpbar.UNKNOWN):
            self.assertIn(state, mcpbar.GLYPH)
            self.assertIn(state, mcpbar.COLOR)

    def test_каждое_состояние_из_разбора_печатается(self):
        """Разбор — единственное место, где состояния рождаются; печатать надо все."""
        for line in (
            "a: cmd - ✔ Connected",
            "b: cmd - ✘ Failed to connect",
            "c: cmd - ⏸ Pending approval",
            "d: https://x/mcp (HTTP) - ✔ Connected",
        ):
            got = mcpbar.parse_list_line(line)
            self.assertIsNotNone(got, line)
            self.assertIn(got["state"], mcpbar.GLYPH)


class UsageEndpoint(unittest.TestCase):
    """Разбор ответа api/oauth/usage. Сеть в тестах не участвует — только чистые функции."""

    def test_ответ_эндпоинта_превращается_в_формат_statusline(self):
        record = mcpbar.usage_record({
            "five_hour": {"utilization": 23.4, "resets_at": "2026-08-04T18:00:00+00:00"},
            "seven_day": {"utilization": 79.0, "resets_at": "2026-08-05T12:00:00Z"},
        }, now=1_785_850_000)
        self.assertEqual(record["source"], "oauth")
        # int, не float: Swift читает used_percentage как `as? Int`, дробное значение
        # молча выключает секцию лимитов при здоровом на вид файле.
        self.assertEqual(record["five_hour"]["used_percentage"], 23)
        self.assertEqual(record["seven_day"]["used_percentage"], 79)
        # ISO с таймзоной → epoch, обе нотации зоны.
        self.assertEqual(record["five_hour"]["resets_at"], 1_785_866_400)
        self.assertEqual(record["seven_day"]["resets_at"], 1_785_931_200)

    def test_неизвестные_окна_проходят_как_есть(self):
        record = mcpbar.usage_record({
            "five_hour": {"utilization": 1, "resets_at": None},
            "seven_day_opus": {"utilization": 55, "resets_at": None},
        }, now=1)
        self.assertIn("seven_day_opus", record)

    def test_окно_fable_берётся_из_массива_limits(self):
        """Реальная форма ответа: Fable — элемент limits[] с kind=weekly_scoped, не верхний
        ключ. Прочие верхние окна (тот же nimbus_quill) Fable не являются."""
        record = mcpbar.usage_record({
            "five_hour": {"utilization": 6, "resets_at": None},
            "seven_day": {"utilization": 60, "resets_at": None},
            "nimbus_quill": {"utilization": 0, "resets_at": None},
            "limits": [
                {"kind": "five_hour", "percent": 6},
                {"kind": "weekly_scoped", "percent": 12.4, "resets_at": "2026-09-13T07:00:00Z",
                 "is_active": True, "scope": {"model": {"display_name": "Fable"}}},
            ],
        }, now=1)
        self.assertEqual(record["seven_day_fable"],
                         {"used_percentage": 12, "resets_at": 1_789_282_800})
        self.assertIn("nimbus_quill", record)

    def test_массив_limits_без_fable_не_рождает_окно(self):
        record = mcpbar.usage_record({
            "five_hour": {"utilization": 6, "resets_at": None},
            "limits": [{"kind": "weekly_scoped", "percent": 3,
                        "scope": {"model": {"display_name": "Opus"}}}, "garbage", None],
        }, now=1)
        self.assertNotIn("seven_day_fable", record)

    def test_пустой_ответ_не_рождает_запись(self):
        self.assertIsNone(mcpbar.usage_record({}, now=1))
        self.assertIsNone(mcpbar.usage_record({"error": "x"}, now=1))
        self.assertIsNone(mcpbar.usage_record(None, now=1))

    def test_epoch_в_resets_at_проходит_без_изменений(self):
        # statusLine шлёт epoch — общий разборщик обязан понимать обе формы.
        self.assertEqual(mcpbar.parse_reset(1_785_866_400), 1_785_866_400)
        self.assertIsNone(mcpbar.parse_reset("not-a-date"))
        self.assertIsNone(mcpbar.parse_reset(None))


class UsageToken(unittest.TestCase):
    """Токен уходит на api.anthropic.com и никуда больше — обещание PRIVACY.md.

    urllib, в отличие от requests, переносит Authorization на новый хост при 302 как есть:
    одного редиректа со стороны эндпоинта, прокси или будущего переезда API хватало, чтобы
    Bearer лёг у чужого сервера. Проверяется двумя настоящими локальными серверами —
    подделка urlopen проверила бы только саму подделку.
    """

    def setUp(self):
        import http.server
        import threading

        self.seen = {}
        seen = self.seen

        class Target(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                seen["auth"] = self.headers.get("Authorization")
                body = b'{"five_hour": {"utilization": 5}}'
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.target = http.server.HTTPServer(("127.0.0.1", 0), Target)
        target_url = "http://127.0.0.1:%d/" % self.target.server_address[1]

        class Bouncer(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", target_url)
                self.end_headers()

            def log_message(self, *args):
                pass

        self.bouncer = http.server.HTTPServer(("127.0.0.1", 0), Bouncer)
        for server in (self.target, self.bouncer):
            threading.Thread(target=server.serve_forever, daemon=True).start()

        self._dir = tempfile.TemporaryDirectory()
        self.saved = {k: getattr(mcpbar, k) for k in ("USAGE_URL", "LIMITS", "oauth_token")}
        mcpbar.USAGE_URL = "http://127.0.0.1:%d/" % self.bouncer.server_address[1]
        mcpbar.LIMITS = os.path.join(self._dir.name, "limits.json")
        mcpbar.oauth_token = lambda: "SECRET"

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(mcpbar, k, v)
        for server in (self.target, self.bouncer):
            server.shutdown()
            server.server_close()
        self._dir.cleanup()

    def test_редирект_не_уносит_токен_на_другой_хост(self):
        mcpbar.fetch_limits()
        self.assertIsNone(self.seen.get("auth"), "Authorization уехал по редиректу")

    def test_редирект_считается_сбоем_а_не_данными(self):
        result = mcpbar.fetch_limits()
        # Через t(), не литералом: текст локализован, и на en-машине литерал зелёного
        # прогона не увидел бы.
        self.assertEqual(mcpbar.t("lim.failed", e="HTTPError"), result)
        self.assertFalse(os.path.exists(mcpbar.LIMITS))


class ReadJsonShape(unittest.TestCase):
    """read_json сверяет форму с default: чужой файл с массивом наверху там, где ждали
    словарь, — это «данных нет», а не AttributeError на весь refresh.

    Класс бага чинился дважды точечно (кеш десктопа, ответ лимитов), а точек чтения чужих
    или руками правимых JSON — около пятнадцати; сверка типа в самой read_json закрывает
    их разом. default=None оставляет разбор как есть — три вызова осознанно различают
    «файла нет» и «форма не та» (project .mcp.json, backup_settings, statusline-restore).
    """

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self._dir.cleanup()

    def put(self, content):
        path = os.path.join(self._dir.name, "f.json")
        with open(path, "w") as fh:
            fh.write(content)
        return path

    def test_массив_при_ожидании_словаря_это_default(self):
        self.assertEqual(mcpbar.read_json(self.put("[1, 2, 3]"), {}), {})

    def test_строка_при_ожидании_списка_это_default(self):
        self.assertEqual(mcpbar.read_json(self.put('"строка"'), []), [])

    def test_совпавшая_форма_проходит_как_есть(self):
        self.assertEqual(mcpbar.read_json(self.put('{"a": 1}'), {}), {"a": 1})

    def test_отсутствующий_файл_это_default(self):
        self.assertEqual(mcpbar.read_json(os.path.join(self._dir.name, "нет"), {}), {})

    def test_default_none_не_проверяет_форму(self):
        self.assertEqual(mcpbar.read_json(self.put("[1]")), [1])


class BackupPermissions(unittest.TestCase):
    """Бэкап секрета — тоже секрет, включая самый первый.

    Первый бэкап install.js рождался copyFileSync'ом и наследовал права оригинала того дня —
    на живой машине лежал 0644 с полным снимком settings.json, читаемый группой staff, то
    есть любым локальным пользователем. Ротация «чужое не трогает» — верно, но файл с нашим
    именным префиксом bak-control-bar наш: свип на каждом refresh обязан накрывать и его.
    """

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        tmp = self._dir.name
        self.saved = {k: getattr(mcpbar, k) for k in ("ROOT", "SETTINGS")}
        mcpbar.ROOT = os.path.join(tmp, "control-bar")
        mcpbar.SETTINGS = os.path.join(tmp, "settings.json")

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(mcpbar, k, v)
        self._dir.cleanup()

    def put(self, path, mode):
        with open(path, "w") as fh:
            fh.write("{}")
        os.chmod(path, mode)

    def test_свип_забирает_у_группы_оба_вида_наших_бэкапов(self):
        self.put(mcpbar.SETTINGS, 0o600)
        ours_first = mcpbar.SETTINGS + ".bak-control-bar"
        ours_dated = mcpbar.SETTINGS + ".bak-control-bar-20260804-131800-000001"
        foreign = mcpbar.SETTINGS + ".bak-mine"
        for path in (ours_first, ours_dated, foreign):
            self.put(path, 0o644)

        mcpbar.secure_root()

        self.assertEqual(os.stat(ours_first).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(ours_dated).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(foreign).st_mode & 0o777, 0o644,
                         "чужой бэкап трогать нельзя")

    def test_симлинк_на_месте_бэкапа_не_чинит_права_по_ссылке(self):
        victim = os.path.join(self._dir.name, "victim.json")
        self.put(victim, 0o644)
        os.symlink(victim, mcpbar.SETTINGS + ".bak-control-bar")

        mcpbar.secure_root()

        self.assertEqual(os.stat(victim).st_mode & 0o777, 0o644,
                         "chmod ушёл по симлинку в чужой файл")


class ServerChildReaping(unittest.TestCase):
    """Опрошенный сервер не имеет права пережить опрос.

    finally делал terminate() без wait()/kill(): сервер, игнорирующий SIGTERM (или просто
    медленно умирающий), оставался жить. Кеш для неответившего не заполняется, поэтому его
    переопрашивают каждые ~10 минут — по свежему сироте за цикл, неделями.
    """

    def test_сервер_игнорирующий_sigterm_мёртв_к_возврату_функции(self):
        tmp = tempfile.TemporaryDirectory()
        pidfile = os.path.join(tmp.name, "pid")
        # Дважды живучий: SIGTERM игнорирует, закрытие stdin переживает вечным сном.
        stubborn = (
            "import os,signal,sys,time\n"
            f"open({pidfile!r},'w').write(str(os.getpid()))\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "sys.stdin.read()\n"
            "while True: time.sleep(1)\n"
        )
        config = {"command": "/usr/bin/python3", "args": ["-c", stubborn]}
        try:
            result = mcpbar.ask_server_for_tools("stubborn", config, timeout=2)
            self.assertIsNone(result)
            with open(pidfile) as fh:
                pid = int(fh.read())
            # kill(pid, 9) — сам и проба, и добивающий: успех значит «пережил» (и уже прибит,
            # сирота после провала не остаётся), ProcessLookupError — мёртв, как и должно.
            try:
                os.kill(pid, 9)
                self.fail("ребёнок пережил ask_server_for_tools")
            except ProcessLookupError:
                pass
        finally:
            tmp.cleanup()


class UsagePayloadDrift(unittest.TestCase):
    """Эндпоинт недокументирован — форма ответа может смениться в любой день.

    usage_record(payload) стоял ВНЕ try/except fetch_limits и предполагал словарь: JSON-массив
    вместо объекта ронял весь скрипт AttributeError'ом — вопреки его же контракту «молчалив
    при любом сбое» (Swift глотает вывод, лимиты просто тихо перестают обновляться). Тот же
    паттерн в connectors_from_desktop ронял весь refresh на неожиданном кеше десктопа.
    """

    def test_массив_вместо_объекта_это_none_а_не_краш(self):
        self.assertIsNone(mcpbar.usage_record([1, 2, 3]))
        self.assertIsNone(mcpbar.usage_record("строка"))
        self.assertIsNone(mcpbar.usage_record(42))

    def test_нечисловой_процент_пропускает_окно_не_роняя_остальные(self):
        record = mcpbar.usage_record({
            "five_hour": {"utilization": "N/A"},
            # json.loads пропускает голый Infinity-токен, а round(inf) кидает OverflowError —
            # не ValueError: одно такое окно роняло весь разбор вместо пропуска окна.
            "inf_window": {"utilization": float("inf")},
            "seven_day": {"utilization": 50},
        })
        self.assertIsNotNone(record)
        self.assertNotIn("five_hour", record)
        self.assertNotIn("inf_window", record)
        self.assertEqual(record["seven_day"]["used_percentage"], 50)

    def test_окно_со_служебным_именем_не_затирает_штамп(self):
        record = mcpbar.usage_record(
            {"ts": {"utilization": 5}, "five_hour": {"utilization": 7}}, now=1000)
        self.assertEqual(record["ts"], 1000)
        self.assertEqual(record["five_hour"]["used_percentage"], 7)

    def test_fetch_limits_переживает_массив_от_эндпоинта(self):
        # data:-URL вместо третьего локального HTTP-сервера в файле: build_opener открывает
        # их штатно, тем же путём с NoRedirect — проверено живым запуском.
        tmp = tempfile.TemporaryDirectory()
        saved = {k: getattr(mcpbar, k) for k in ("USAGE_URL", "LIMITS", "oauth_token")}
        mcpbar.USAGE_URL = "data:application/json,[1,2,3]"
        mcpbar.LIMITS = os.path.join(tmp.name, "limits.json")
        mcpbar.oauth_token = lambda: "SECRET"
        try:
            result = mcpbar.fetch_limits()
            self.assertIsInstance(result, str)
            self.assertFalse(os.path.exists(mcpbar.LIMITS), "мусор не должен стать limits.json")
        finally:
            for k, v in saved.items():
                setattr(mcpbar, k, v)
            tmp.cleanup()

    def test_кеш_десктопа_с_неожиданными_формами_не_роняет_и_не_подбирает_мусор(self):
        """Дрейфнутый файл (массив наверху) пропускается переходом к следующему; внутри
        валидного не-словарные и безымянные элементы списка отбрасываются поштучно."""
        tmp = tempfile.TemporaryDirectory()
        saved = mcpbar.DESKTOP_SESSIONS
        mcpbar.DESKTOP_SESSIONS = tmp.name
        try:
            valid = os.path.join(tmp.name, "older-valid.json")
            with open(valid, "w") as fh:
                json.dump({"remoteMcpServersConfig": [
                    "не словарь",
                    {"uuid": "без-имени"},
                    {"name": "Figma", "uuid": "u1", "tools": []},
                ]}, fh)
            with open(os.path.join(tmp.name, "drifted.json"), "w") as fh:
                json.dump([{"это": "массив"}], fh)
            os.utime(valid, (1, 1))  # дрейфнутый свежее — его смотрят первым
            self.assertEqual(list(mcpbar.connectors_from_desktop()), ["Figma"])
        finally:
            mcpbar.DESKTOP_SESSIONS = saved
            tmp.cleanup()


class DescribeToolDrift(unittest.TestCase):
    """Кеш десктопа и ответ чужого сервера — не наши данные: строка на месте словаря
    на ЛЮБОМ уровне (инструмент, inputSchema, properties, required) — это «поля нет»,
    а не AttributeError на весь refresh (его stderr смотрит в DEVNULL — падение немое)."""

    def test_инструмент_не_словарём_даёт_пустышку(self):
        self.assertEqual(mcpbar.describe_tool("get_screenshot"),
                         {"name": "", "description": "", "params": []})

    def test_схема_не_словарём_даёт_пустые_параметры(self):
        tool = mcpbar.describe_tool({"name": "t", "inputSchema": "не схема"})
        self.assertEqual(tool["name"], "t")
        self.assertEqual(tool["params"], [])

    def test_properties_и_required_не_той_формы_не_роняют(self):
        tool = mcpbar.describe_tool({"name": "t", "inputSchema": {
            "properties": ["не", "словарь"], "required": "не список"}})
        self.assertEqual(tool["params"], [])

    def test_мусор_в_tools_коннектора_отбрасывается_поштучно(self):
        tmp = tempfile.TemporaryDirectory()
        saved = mcpbar.DESKTOP_SESSIONS
        mcpbar.DESKTOP_SESSIONS = tmp.name
        try:
            with open(os.path.join(tmp.name, "cache.json"), "w") as fh:
                json.dump({"remoteMcpServersConfig": [
                    {"name": "Figma", "uuid": "u1",
                     "tools": ["строка", {"name": "ok"}, {"без": "имени"}]},
                    {"name": "Linear", "uuid": "u2", "tools": {"не": "список"}},
                ]}, fh)
            connectors = mcpbar.connectors_from_desktop()
        finally:
            mcpbar.DESKTOP_SESSIONS = saved
            tmp.cleanup()
        self.assertEqual([t["name"] for t in connectors["Figma"]["tools"]], ["", "ok", ""])
        self.assertEqual(connectors["Linear"]["tools"], [])


class DescriptionsNegativeCache(unittest.TestCase):
    """Неответивший stdio-сервер — тоже результат опроса.

    Без записи каждый refresh (раз в ~10 минут) заново поднимал процесс сломанного сервера
    и высиживал его 20-секундный таймаут — вечно. Запись со сдвинутым в прошлое штампом
    возвращает попытку через FAILED_PROBE_RETRY, а не через сутки."""

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        root = self._dir.name
        self.saved = {k: getattr(mcpbar, k) for k in ("CONFIG", "SETTINGS", "DESCRIPTIONS")}
        mcpbar.CONFIG = os.path.join(root, "claude.json")
        mcpbar.SETTINGS = os.path.join(root, "settings.json")
        mcpbar.DESCRIPTIONS = os.path.join(root, "descriptions.json")
        with open(mcpbar.SETTINGS, "w") as fh:
            json.dump({}, fh)
        self.asked = []
        self._ask = mcpbar.ask_server_for_tools
        mcpbar.ask_server_for_tools = lambda name, config, **kw: self.asked.append(name)

    def tearDown(self):
        mcpbar.ask_server_for_tools = self._ask
        for key, value in self.saved.items():
            setattr(mcpbar, key, value)
        self._dir.cleanup()

    def config(self, servers):
        with open(mcpbar.CONFIG, "w") as fh:
            json.dump({"mcpServers": servers}, fh)

    def test_неответивший_stdio_не_переопрашивается_следующим_refresh(self):
        self.config({"молчун": {"command": "true"}})
        mcpbar.refresh_descriptions()
        mcpbar.refresh_descriptions()
        self.assertEqual(self.asked, ["молчун"])

    def test_попытка_возвращается_через_retry_а_не_через_сутки(self):
        self.config({"молчун": {"command": "true"}})
        mcpbar.refresh_descriptions()
        with open(mcpbar.DESCRIPTIONS) as fh:
            entry = json.load(fh)["молчун"]
        self.assertEqual(entry["tools"], [])
        expected = time.time() - mcpbar.DESCRIPTIONS_TTL + mcpbar.FAILED_PROBE_RETRY
        self.assertLess(abs(entry["ts"] - expected), 60)

    def test_remote_сервер_не_получает_негативную_запись(self):
        """ask_server_for_tools выходит из remote/SSE сразу — «неответивший» о нём не знает
        ничего, и запись глушила бы кеш коннекторов десктопа."""
        self.config({"коннектор": {"type": "http", "url": "https://example.com/mcp"}})
        mcpbar.refresh_descriptions()
        cached = mcpbar.read_json(mcpbar.DESCRIPTIONS, {})
        self.assertNotIn("коннектор", cached)

    def test_негативная_запись_отдаёт_слово_кешу_десктопа(self):
        """attach_tools: пустой список инструментов от опроса — «сервер молчит», и имена
        берутся из кеша десктопа, а не глушатся пустотой."""
        patched = {
            "counts_from_logs": lambda: {},
            "connectors_from_desktop": lambda: {"Figma": {"uuid": "u1", "tools": [
                {"name": "t1", "description": "d", "params": []}]}},
            "refresh_descriptions": lambda force=False: {
                "Figma": {"ts": 1, "v": mcpbar.DESCRIPTIONS_FORMAT, "tools": []}},
            "tool_names_from_transcripts": lambda: {},
        }
        saved = {k: getattr(mcpbar, k) for k in patched}
        for k, v in patched.items():
            setattr(mcpbar, k, v)
        try:
            servers = [{"name": "Figma"}]
            mcpbar.attach_tools(servers)
        finally:
            for k, v in saved.items():
                setattr(mcpbar, k, v)
        self.assertEqual(servers[0]["toolNames"], ["t1"])


class SettingsShapeDrift(unittest.TestCase):
    """settings.json правят руками: валидный JSON не той формы (список на месте словаря)
    обязан читаться как «данных нет» и НЕ редактироваться — не AttributeError в refresh
    и не «починка» чужой структуры своим переключателем."""

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.settings = os.path.join(self._dir.name, "settings.json")
        self._saved = (mcpbar.SETTINGS, mcpbar.ROOT)
        mcpbar.SETTINGS = self.settings
        mcpbar.ROOT = os.path.join(self._dir.name, "control-bar")

    def tearDown(self):
        mcpbar.SETTINGS, mcpbar.ROOT = self._saved
        self._dir.cleanup()

    def write(self, data):
        with open(self.settings, "w") as fh:
            json.dump(data, fh)
        with open(self.settings, "rb") as fh:
            return fh.read()

    def test_permissions_списком_читается_как_пусто_и_не_редактируется(self):
        before = self.write({"permissions": ["mcp__x"]})
        self.assertEqual(mcpbar.denied_tools(), [])
        with self.assertRaises(mcpbar.Refused):
            mcpbar.toggle_tool("mcp__a__b", turn_off=True)
        with open(self.settings, "rb") as fh:
            self.assertEqual(fh.read(), before)

    def test_deny_строкой_читается_как_пусто_и_не_редактируется(self):
        before = self.write({"permissions": {"deny": "mcp__x"}})
        self.assertEqual(mcpbar.denied_tools(), [])
        with self.assertRaises(mcpbar.Refused):
            mcpbar.toggle_tool("mcp__a__b", turn_off=True)
        with open(self.settings, "rb") as fh:
            self.assertEqual(fh.read(), before)

    def test_нестроковые_правила_в_deny_пропускаются(self):
        self.write({"permissions": {"deny": [42, None, "mcp__wiki__Get"]}})
        self.assertEqual(mcpbar.denied_tools(), ["mcp__wiki__Get"])

    def test_deniedMcpServers_словарём_не_редактируется(self):
        before = self.write({"deniedMcpServers": {"wiki": True}})
        self.assertEqual(mcpbar.denied_servers(), [])
        with self.assertRaises(mcpbar.Refused):
            mcpbar.toggle_server("wiki", turn_off=True)
        with open(self.settings, "rb") as fh:
            self.assertEqual(fh.read(), before)

    def test_statusline_строкой_не_роняет_проверку(self):
        self.write({"statusLine": "echo сегмент"})
        current, ours = mcpbar.statusline_state()
        self.assertEqual(current, "")
        self.assertFalse(ours)


class ReportResilience(unittest.TestCase):
    """Записи сессий пишет Node-хук, лимиты — два разных источника: report() обязан
    пережить запись с pct без tokens/window и не-словарь на месте окна лимитов."""

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self._saved = mcpbar.STATE
        mcpbar.STATE = os.path.join(self._dir.name, "mcp.json")
        with open(mcpbar.STATE, "w") as fh:
            json.dump({
                "checked_at": time.time(),
                "servers": [],
                "sessions": [{"id": "abcd1234", "project": "проект", "entrypoint": "cli",
                              "ts": 1, "pct": 42}],
                "limits": {"ts": time.time(), "source": "oauth", "five_hour": 3,
                           "seven_day": {"used_percentage": 55, "resets_at": None},
                           "seven_day_fable": {"used_percentage": 17, "resets_at": None}},
            }, fh)

    def tearDown(self):
        mcpbar.STATE = self._saved
        self._dir.cleanup()

    def test_сессия_с_pct_без_tokens_не_роняет_отчёт(self):
        text = mcpbar.report()
        self.assertIn("42", text)

    def test_окно_лимитов_не_словарём_пропускается(self):
        text = mcpbar.report()
        self.assertIn("55", text)

    def test_недельное_окно_fable_показывается_своей_строкой(self):
        text = mcpbar.report()
        self.assertIn("Fable", text)
        self.assertIn(" 17%", text)


class SeamContract(unittest.TestCase):
    """Шов python→swift: mcp.json пишет настоящий refresh(), а не рукописная фикстура.

    До этого теста схему пинили дважды независимо — питон в своих тестах, свифт в своих,
    оба на выдуманных данных. Согласованное переименование ключа (toolNames, deniedTools,
    toolPrefix…) проходило все сьюты зелёными, а меню молча пустело. Здесь стабы стоят
    только на границе subprocess/сети; кеш описаний, deny-правила и кеш десктопа читает
    реальный код. Результат уезжает в build/seam/mcp.json — swift-ская model-проверка
    парсит именно его (запускать питон раньше свифта, CI так и делает).
    """

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        tmp = self._dir.name
        desktop = os.path.join(tmp, "desktop-sessions")
        os.makedirs(desktop)
        patched = {
            "ROOT": tmp,
            "STATE": os.path.join(tmp, "mcp.json"),
            "LIMITS": os.path.join(tmp, "limits.json"),
            "SESSIONS": os.path.join(tmp, "state.d"),
            "CONFIG": os.path.join(tmp, "claude.json"),
            "SETTINGS": os.path.join(tmp, "settings.json"),
            "NEEDS_AUTH": os.path.join(tmp, "needs-auth.json"),
            "LOCK": os.path.join(tmp, "refresh.lock"),
            "DESCRIPTIONS": os.path.join(tmp, "descriptions.json"),
            "DESKTOP_SESSIONS": desktop,
            "MCP_LOGS": os.path.join(tmp, "no-logs", "mcp-logs-*"),
            "TRANSCRIPTS": os.path.join(tmp, "no-transcripts", "*.jsonl"),
            # Сеть и Claude Code за границей: сам ответ health-check — фикстура,
            # всё после него — боевой код.
            "run_health_check": lambda cwd="/": (
                [
                    {"name": "wiki", "target": "", "status": "✔ Connected", "state": mcpbar.OK},
                    {"name": "claude.ai Figma", "target": "", "status": "✔ Connected",
                     "state": mcpbar.OK},
                ],
                None,
            ),
            "session_cwds": lambda: [],
            "model_windows": lambda: {},
        }
        self.saved = {k: getattr(mcpbar, k) for k in patched}
        for k, v in patched.items():
            setattr(mcpbar, k, v)

        write = mcpbar.write_json
        write(mcpbar.CONFIG, {"mcpServers": {"wiki": {"command": "true"}}})
        write(mcpbar.SETTINGS, {
            "permissions": {"deny": ["mcp__wiki__Delete", "mcp__b6d68fb1__get_screenshot"]},
            "deniedMcpServers": [{"serverName": "off-one"}],
        })
        write(mcpbar.NEEDS_AUTH, {"needs-oauth": True})
        # Свежий кеш с текущей версией формата — todo пуст, ни один сервер не поднимается.
        write(mcpbar.DESCRIPTIONS, {"wiki": {
            "ts": int(time.time()), "v": mcpbar.DESCRIPTIONS_FORMAT,
            "tools": [
                {"name": "Read", "description": "read a page",
                 "params": [{"name": "id", "type": "integer", "required": True,
                             "description": "page id"}]},
                {"name": "Write", "description": "write a page", "params": []},
                {"name": "Delete", "description": "delete a page", "params": []},
            ],
        }})
        # Кеш десктопа — источник uuid коннектора: правило deny собирается из него,
        # а не из отображаемого имени (реальный баг 0.5.0).
        write(os.path.join(desktop, "session.json"), {"remoteMcpServersConfig": [
            {"name": "Figma", "uuid": "b6d68fb1",
             "tools": [{"name": "get_screenshot", "description": "shot", "inputSchema": {}}]},
        ]})

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(mcpbar, k, v)
        self._dir.cleanup()

    def test_схема_написанного_настоящим_refresh_закреплена_и_уезжает_свифту(self):
        data = mcpbar.refresh()

        self.assertEqual(
            sorted(data.keys()),
            ["auth", "checked_at", "denyRules", "limits", "servers", "sessions"],
            "верхний уровень mcp.json — ровно эти ключи, их читает MCPModel.swift",
        )
        by_name = {s["name"]: s for s in data["servers"]}
        wiki = by_name["wiki"]
        self.assertEqual(
            sorted(wiki.keys()),
            ["deniedTools", "disabled", "name", "source", "state", "status",
             "target", "toolDocs", "toolNames", "toolParams", "toolPrefix", "tools"],
            "инвентарь ключей сервера — то, что парсит MCPModel.server(from:)",
        )
        self.assertEqual(wiki["source"], "user")
        self.assertEqual(wiki["toolNames"], ["Delete", "Read", "Write"])
        self.assertEqual(wiki["deniedTools"], ["Delete"])
        self.assertEqual(wiki["toolParams"]["Read"][0]["required"], True)
        self.assertEqual(wiki["tools"], 3)
        # Приставка коннектора — uuid из кеша десктопа, не отображаемое имя.
        figma = by_name["claude.ai Figma"]
        self.assertEqual(figma["toolPrefix"], "b6d68fb1")
        self.assertEqual(figma["source"], "claude.ai")
        self.assertEqual(figma["deniedTools"], ["get_screenshot"])
        # Выключенный сервер воскресает строкой из deniedMcpServers.
        self.assertEqual(by_name["off-one"]["state"], mcpbar.OFF)
        self.assertTrue(by_name["off-one"]["disabled"])
        self.assertEqual(data["auth"], ["needs-oauth"])

        # Артефакт для swift-стороны шва: model-проверка читает этот файл.
        repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        seam_dir = os.path.join(repo, "build", "seam")
        os.makedirs(seam_dir, exist_ok=True)
        shutil.copyfile(mcpbar.STATE, os.path.join(seam_dir, "mcp.json"))


class CodexLimits(unittest.TestCase):
    """Лимиты Codex снимаются с rollout-файла — чужого формата, который пишет не наш код.

    Каждый случай здесь — форма, на которой наивный разбор либо врал числом, либо падал.
    """

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.saved = {k: getattr(mcpbar, k)
                      for k in ("CODEX", "CODEX_ROLLOUTS", "CODEX_LIMITS", "CODEX_ROOT")}
        mcpbar.CODEX = os.path.join(self._dir.name, ".codex")
        mcpbar.CODEX_ROLLOUTS = os.path.join(mcpbar.CODEX, "sessions", "*", "*", "*", "rollout-*.jsonl")
        mcpbar.CODEX_ROOT = os.path.join(self._dir.name, "control-bar", "codex")
        self.root = os.path.join(self._dir.name, "control-bar")
        mcpbar.CODEX_LIMITS = os.path.join(self.root, "codex", "limits.json")
        self.saved["ROOT"] = mcpbar.ROOT
        mcpbar.ROOT = self.root

    def tearDown(self):
        for key, value in self.saved.items():
            setattr(mcpbar, key, value)
        self._dir.cleanup()

    def rollout(self, name, lines, day="11"):
        path = os.path.join(mcpbar.CODEX, "sessions", "2026", "09", day, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            for line in lines:
                fh.write((line if isinstance(line, str) else json.dumps(line)) + "\n")
        return path

    @staticmethod
    def token_count(primary, secondary=None, stamp="2026-09-11T10:00:00Z", plan=None):
        limits = {"primary": primary}
        if secondary is not None:
            limits["secondary"] = secondary
        if plan:
            limits["plan_type"] = plan
        return {"timestamp": stamp, "type": "event_msg",
                "payload": {"type": "token_count", "rate_limits": limits,
                            "info": {"total_token_usage": {"input_tokens": 10}}}}

    def test_окна_снимка_становятся_фактами(self):
        record = mcpbar.codex_limits_record({
            "primary": {"used_percent": 12.4, "window_minutes": 300, "resets_at": 1_789_012_345},
            "secondary": {"used_percent": 58.6, "window_minutes": 10080, "resets_at": 1_789_500_000},
            "plan_type": "pro",
        }, ts=1_789_000_000)
        self.assertEqual(record["source"], "rollout")
        self.assertEqual(record["ts"], 1_789_000_000)
        self.assertEqual(record["plan"], "pro")
        self.assertEqual(record["windows"], [
            {"kind": "primary", "pool": "codex", "ts": 1_789_000_000, "used_percentage": 12,
             "window_minutes": 300, "resets_at": 1_789_012_345},
            {"kind": "secondary", "pool": "codex", "ts": 1_789_000_000, "used_percentage": 59,
             "window_minutes": 10080, "resets_at": 1_789_500_000},
        ])

    def test_процент_целый_как_у_claude(self):
        """Swift читает used_percentage как `as? Int`: дробь молча выключила бы окно."""
        record = mcpbar.codex_limits_record({"primary": {"used_percent": 0.6}}, ts=1)
        self.assertIsInstance(record["windows"][0]["used_percentage"], int)
        self.assertEqual(record["windows"][0]["used_percentage"], 1)

    def test_на_free_плане_второго_окна_нет(self):
        """secondary_window приходит null — окно пропускается, а не рисуется нулём."""
        record = mcpbar.codex_limits_record({"primary": {"used_percent": 3}, "secondary": None}, ts=1)
        self.assertEqual([w["kind"] for w in record["windows"]], ["primary"])

    def test_остаток_секунд_отсчитывается_от_снимка(self):
        """Старые сборки шлют «через сколько», а не «когда». Отсчёт от `сейчас` двигал бы
        сброс вперёд на каждый опрос — окно не сбрасывалось бы в панели никогда."""
        record = mcpbar.codex_limits_record(
            {"primary": {"used_percent": 5, "resets_in_seconds": 600}}, ts=1_789_000_000)
        self.assertEqual(record["windows"][0]["resets_at"], 1_789_000_600)

    def test_битое_окно_не_уносит_соседнее(self):
        record = mcpbar.codex_limits_record({
            "primary": {"used_percent": None},
            "secondary": {"used_percent": 40, "window_minutes": 10080},
        }, ts=1)
        self.assertEqual([w["kind"] for w in record["windows"]], ["secondary"])

    def test_неожиданная_форма_это_нет_данных(self):
        self.assertIsNone(mcpbar.codex_limits_record(["primary"], ts=1))
        self.assertIsNone(mcpbar.codex_limits_record({}, ts=1))
        self.assertIsNone(mcpbar.codex_limits_record({"primary": "12%"}, ts=1))

    def test_берётся_последняя_запись_файла(self):
        path = self.rollout("rollout-2026-09-11T10-00-00-aaa.jsonl", [
            {"timestamp": "2026-09-11T10:00:00Z", "type": "session_meta", "payload": {"cwd": "/x"}},
            self.token_count({"used_percent": 10, "window_minutes": 300}),
            "{это не json",
            self.token_count({"used_percent": 20, "window_minutes": 300},
                             stamp="2026-09-11T11:00:00Z"),
        ])
        snapshot, ts, _model = mcpbar.codex_file_snapshots(path)["codex"]
        self.assertEqual(snapshot["primary"]["used_percent"], 20)
        # Момент записи, а не время файла: панель показывает возраст цифр, и возраст
        # недельного снимка должен читаться неделей, а не «только что».
        self.assertEqual(ts, 1_789_124_400)   # 2026-09-11T11:00:00Z

    def test_резервная_модель_помечает_запись(self):
        """Кончился обычный лимит — Codex уводит сессию на резервную модель, и снимок в файле
        начинает мерить ДРУГОЙ пул. limit_id у обоих пулов одинаковый ("codex"), так что
        отличает их только модель хода: без пометки панель показала бы резервные проценты
        как обычные, и 100% выжранного пятичасового окна остались бы невидимыми."""
        record = mcpbar.codex_limits_record(
            {"primary": {"used_percent": 13, "window_minutes": 10080}},
            ts=1, model="gpt-reserve")
        self.assertEqual([w["pool"] for w in record["windows"]], ["reserve"])

    def test_обычная_модель_ничего_не_помечает(self):
        record = mcpbar.codex_limits_record(
            {"primary": {"used_percent": 13, "window_minutes": 300}}, ts=1, model="gpt-5.6-terra")
        self.assertEqual([w["pool"] for w in record["windows"]], ["codex"])

    def test_модель_снимка_берётся_из_хода_а_не_из_всего_файла(self):
        """Сессия начинается на обычной модели и переезжает на резервную, когда лимит кончился.
        Мерить надо модель ПОСЛЕДНЕГО хода: первая строка файла сказала бы, что пул обычный,
        когда он уже резервный."""
        path = self.rollout("rollout-2026-09-11T10-00-00-mix.jsonl", [
            {"timestamp": "2026-09-11T10:00:00Z", "type": "turn_context",
             "payload": {"turn_id": "1", "model": "gpt-5.6-terra"}},
            self.token_count({"used_percent": 10, "window_minutes": 300}),
            {"timestamp": "2026-09-11T11:00:00Z", "type": "turn_context",
             "payload": {"turn_id": "2", "model": "gpt-reserve"}},
            self.token_count({"used_percent": 13, "window_minutes": 10080},
                             stamp="2026-09-11T11:00:00Z"),
        ])
        found = mcpbar.codex_file_snapshots(path)
        self.assertEqual(found["reserve"][0]["primary"]["used_percent"], 13)
        self.assertEqual(found["reserve"][2], "gpt-reserve")
        # И обычный снимок того же файла — тот, что был до переезда на резерв. Резервный ход
        # перестаёт присылать обычные окна вовсе, так что взять их больше неоткуда.
        self.assertEqual(found["codex"][0]["primary"]["used_percent"], 10)

    def test_свежий_файл_побеждает_а_архив_пропускается(self):
        old = self.rollout("rollout-2026-09-10T10-00-00-old.jsonl",
                           [self.token_count({"used_percent": 10})], day="10")
        new = self.rollout("rollout-2026-09-11T10-00-00-new.jsonl",
                           [self.token_count({"used_percent": 90})])
        os.utime(old, (1_000_000, 1_000_000))
        os.utime(new, (2_000_000, 2_000_000))
        # Сжатый архив рядом: распаковывать его незачем, живой файл всегда plain.
        with open(new.replace(".jsonl", ".jsonl.zst"), "wb") as fh:
            fh.write(b"\x28\xb5\x2f\xfd")
        self.assertEqual(mcpbar.newest_rollout(), new)

    def test_без_codex_ничего_не_пишется(self):
        self.assertIn("~/.codex", mcpbar.fetch_codex_limits())
        self.assertFalse(os.path.exists(mcpbar.CODEX_LIMITS))

    def test_файл_пишется_только_владельцу(self):
        """Каталог состояния общий для staff-группы: проценты лимитов аккаунта — не для всех."""
        self.rollout("rollout-2026-09-11T10-00-00-aaa.jsonl", [
            # Сбросы позже самой записи: снимок с окном, которое уже закрылось, Swift
            # выбрасывает, и шов проверял бы пустоту вместо разбора.
            self.token_count({"used_percent": 7, "window_minutes": 300, "resets_at": 1_789_124_400},
                             {"used_percent": 42, "window_minutes": 10080,
                              "resets_at": 1_789_700_000}, plan="pro"),
        ])
        mcpbar.fetch_codex_limits()
        with open(mcpbar.CODEX_LIMITS) as fh:
            written = json.load(fh)
        self.assertEqual([w["used_percentage"] for w in written["windows"]], [7, 42])
        self.assertEqual(stat.S_IMODE(os.stat(mcpbar.CODEX_LIMITS).st_mode), 0o600)
        # И оба каталога до него: makedirs со своим mode закрывает только последний, а
        # промежуточный ~/.claude/control-bar на свежей машине оставался бы 0755.
        for directory in (self.root, os.path.dirname(mcpbar.CODEX_LIMITS)):
            self.assertEqual(stat.S_IMODE(os.stat(directory).st_mode), 0o700, directory)

        # Артефакт для swift-стороны шва: model-проверка парсит ровно этот файл.
        repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        seam_dir = os.path.join(repo, "build", "seam")
        os.makedirs(seam_dir, exist_ok=True)
        shutil.copyfile(mcpbar.CODEX_LIMITS, os.path.join(seam_dir, "codex-limits.json"))

    def test_резерв_доезжает_до_файла(self):
        """Сквозь весь путь: ход на резервной модели → пометка в codex/limits.json. Swift-сторона
        шва читает ровно этот файл и по пометке подписывает окно резервным."""
        self.rollout("rollout-2026-09-11T10-00-00-res.jsonl", [
            {"timestamp": "2026-09-11T10:00:00Z", "type": "turn_context",
             "payload": {"turn_id": "1", "model": "gpt-reserve"}},
            self.token_count({"used_percent": 13, "window_minutes": 10080,
                              "resets_at": 1_789_700_000}, plan="plus"),
        ])
        mcpbar.fetch_codex_limits()
        with open(mcpbar.CODEX_LIMITS) as fh:
            written = json.load(fh)
        self.assertEqual([w["pool"] for w in written["windows"]], ["reserve"])
        repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        seam_dir = os.path.join(repo, "build", "seam")
        os.makedirs(seam_dir, exist_ok=True)
        shutil.copyfile(mcpbar.CODEX_LIMITS,
                        os.path.join(seam_dir, "codex-limits-reserve.json"))


    # ─── память по пулам ───────────────────────────────────────────────────────────────
    #
    # Codex в резерве присылает снимок ТОЛЬКО резервного пула: `primary` меряет резерв, а
    # `secondary` приходит пустым. Проверено на живых файлах 13 сентября 2026 — обычное
    # пятичасовое окно и обычное недельное из снимка исчезают целиком. Файл, который просто
    # копировал последний снимок, вместе с ними терял и знание о том, что эти окна существуют:
    # сброс пятичасового проходил, а сказать об этом панели было нечем. Поэтому файл хранит
    # последний замер ПО КАЖДОМУ ПУЛУ, а свежий снимок обновляет только свой.

    @staticmethod
    def window(kind="primary", pool="codex", ts=1_789_000_000, used=10,
               minutes=300, resets=1_789_100_000):
        return {"kind": kind, "pool": pool, "ts": ts, "used_percentage": used,
                "window_minutes": minutes, "resets_at": resets}

    def test_резервный_снимок_не_затирает_обычные_окна(self):
        previous = {"ts": 1_789_000_000, "source": "rollout", "plan": "plus", "windows": [
            self.window("primary", used=97, minutes=300, resets=1_789_018_681),
            self.window("secondary", used=15, minutes=10080, resets=1_789_605_481),
        ]}
        fresh = {"ts": 1_789_018_588, "source": "rollout", "plan": "plus", "windows": [
            self.window("primary", pool="reserve", ts=1_789_018_588, used=29,
                        minutes=10080, resets=1_789_616_476),
        ]}
        merged = mcpbar.merge_codex_limits(previous, fresh)
        self.assertEqual([(w["pool"], w["kind"], w["used_percentage"]) for w in merged["windows"]],
                         [("codex", "primary", 97), ("codex", "secondary", 15),
                          ("reserve", "primary", 29)])

    def test_обычный_снимок_возвращает_свои_окна_на_место(self):
        """И не трогает запомненный резерв: его недельное окно живёт своим сроком."""
        previous = {"ts": 1_789_018_588, "source": "rollout", "windows": [
            self.window("primary", used=97, resets=1_789_018_681),
            self.window("primary", pool="reserve", ts=1_789_018_588, used=29,
                        minutes=10080, resets=1_789_616_476),
        ]}
        fresh = {"ts": 1_789_020_000, "source": "rollout", "windows": [
            self.window("primary", ts=1_789_020_000, used=4, resets=1_789_038_000),
        ]}
        merged = mcpbar.merge_codex_limits(previous, fresh)
        self.assertEqual([(w["pool"], w["used_percentage"]) for w in merged["windows"]],
                         [("codex", 4), ("reserve", 29)])

    def test_возраст_записи_это_самый_старый_замер(self):
        """Подпись «measured N min ago» одна на всю группу, и врать она обязана в свою
        сторону: свежесть резервного окна ничего не говорит про обычное, снятое утром."""
        previous = {"ts": 1_789_000_000, "source": "rollout", "windows": [self.window()]}
        fresh = {"ts": 1_789_020_000, "source": "rollout", "windows": [
            self.window("primary", pool="reserve", ts=1_789_020_000, minutes=10080,
                        resets=1_789_616_476),
        ]}
        self.assertEqual(mcpbar.merge_codex_limits(previous, fresh)["ts"], 1_789_000_000)

    def test_файл_прошлой_версии_переезжает_без_потери(self):
        """До этой версии пул стоял пометкой на всей записи, а момент замера был один на файл.
        Первый же опрос после обновления обязан прочитать такой файл, а не выбросить его."""
        previous = {"ts": 1_789_018_588, "source": "rollout", "reserve": True, "windows": [
            {"kind": "primary", "used_percentage": 29, "window_minutes": 10080,
             "resets_at": 1_789_616_476},
        ]}
        fresh = {"ts": 1_789_020_000, "source": "rollout", "windows": [
            self.window("primary", ts=1_789_020_000, used=4, resets=1_789_038_000),
        ]}
        merged = mcpbar.merge_codex_limits(previous, fresh)
        self.assertEqual([(w["pool"], w["used_percentage"], w["ts"]) for w in merged["windows"]],
                         [("codex", 4, 1_789_020_000), ("reserve", 29, 1_789_018_588)])

    def test_битый_предыдущий_файл_не_мешает_свежему_снимку(self):
        fresh = {"ts": 1_789_020_000, "source": "rollout",
                 "windows": [self.window(ts=1_789_020_000)]}
        for previous in (None, [], {"windows": "нет"}, {"windows": ["строка"]}):
            self.assertEqual(mcpbar.merge_codex_limits(previous, fresh), fresh, previous)

    def test_обычные_окна_ищутся_в_прошлых_сессиях(self):
        """Панель, впервые открытая уже на резерве, обязана показать обычные окна.

        Сессия на резерве не присылает их совсем, а хвост свежего файла может целиком
        состоять из резервных ходов — так и было 13 сентября 2026 на файле в 17 МБ. Тогда
        последний обычный замер лежит в ПРЕДЫДУЩЕЙ сессии, и взять его больше неоткуда.
        """
        old = self.rollout("rollout-2026-09-11T09-00-00-was.jsonl", [
            {"timestamp": "2026-09-11T09:00:00Z", "type": "turn_context",
             "payload": {"turn_id": "1", "model": "gpt-5.6-terra"}},
            self.token_count({"used_percent": 97, "window_minutes": 300,
                              "resets_at": 1_789_124_400},
                             {"used_percent": 15, "window_minutes": 10080,
                              "resets_at": 1_789_700_000},
                             stamp="2026-09-11T09:00:00Z", plan="plus"),
        ])
        now = self.rollout("rollout-2026-09-11T10-00-00-res.jsonl", [
            {"timestamp": "2026-09-11T10:00:00Z", "type": "turn_context",
             "payload": {"turn_id": "1", "model": "gpt-reserve"}},
            self.token_count({"used_percent": 29, "window_minutes": 10080,
                              "resets_at": 1_789_800_000}, plan="plus"),
        ])
        os.utime(old, (1_000_000, 1_000_000))
        os.utime(now, (2_000_000, 2_000_000))
        mcpbar.fetch_codex_limits()
        with open(mcpbar.CODEX_LIMITS) as fh:
            written = json.load(fh)
        self.assertEqual([(w["pool"], w["kind"], w["used_percentage"]) for w in written["windows"]],
                         [("codex", "primary", 97), ("codex", "secondary", 15),
                          ("reserve", "primary", 29)])

    def test_снимок_без_своего_хода_не_считается_обычным(self):
        """Хвост файла обрывается посреди сессии, и у самых старых снимков в нём своей записи
        turn_context уже нет. Пул их неизвестен — а назвать неизвестное обычным значит выдать
        резервные проценты за обычные. Проверено на живом файле 13 сентября 2026: 23%
        резервного пула уехали в файл как обычное недельное окно ровно этим путём."""
        path = self.rollout("rollout-2026-09-11T10-00-00-cut.jsonl", [
            # Самый старый снимок хвоста: его ход остался за границей чтения.
            self.token_count({"used_percent": 23, "window_minutes": 10080},
                             stamp="2026-09-11T09:00:00Z"),
            {"timestamp": "2026-09-11T10:00:00Z", "type": "turn_context",
             "payload": {"turn_id": "1", "model": "gpt-reserve"}},
            self.token_count({"used_percent": 29, "window_minutes": 10080}),
        ])
        self.assertEqual(list(mcpbar.codex_file_snapshots(path)), ["reserve"])

    def test_хвост_без_единого_хода_читается_как_прежде(self):
        """Записи turn_context в хвосте нет вовсе — значит, и следов резервной сессии нет.
        Так этот файл читался и до появления пулов, и ломать это незачем."""
        path = self.rollout("rollout-2026-09-11T10-00-00-plain.jsonl", [
            self.token_count({"used_percent": 12, "window_minutes": 300}),
        ])
        found = mcpbar.codex_file_snapshots(path)
        self.assertEqual(list(found), ["codex"])
        self.assertEqual(found["codex"][0]["primary"]["used_percent"], 12)

    def test_пустой_снимок_не_останавливает_поиск(self):
        """Codex пишет снимок и на ходах, где мерить нечего: `primary` и `secondary` приходят
        пустыми. Такой снимок принимали за найденный обычный пул, и поиск замирал на первом же
        коротком ходе, не дойдя до сессии с настоящими окнами. Проверено на живых файлах
        13 сентября 2026 — панель так и осталась с одной резервной шкалой."""
        files = [
            ("res", [{"timestamp": "2026-09-11T12:00:00Z", "type": "turn_context",
                      "payload": {"turn_id": "1", "model": "gpt-reserve"}},
                     self.token_count({"used_percent": 29, "window_minutes": 10080},
                                      stamp="2026-09-11T12:00:00Z")]),
            ("nil", [{"timestamp": "2026-09-11T11:00:00Z", "type": "turn_context",
                      "payload": {"turn_id": "1", "model": "gpt-5.6-terra"}},
                     self.token_count(None, stamp="2026-09-11T11:00:00Z")]),
            ("real", [{"timestamp": "2026-09-11T10:00:00Z", "type": "turn_context",
                       "payload": {"turn_id": "1", "model": "gpt-5.6-terra"}},
                      self.token_count({"used_percent": 97, "window_minutes": 300},
                                       stamp="2026-09-11T10:00:00Z")]),
        ]
        for at, (name, lines) in enumerate(files):
            path = self.rollout(f"rollout-2026-09-11T10-00-00-{name}.jsonl", lines)
            os.utime(path, (3_000_000 - at, 3_000_000 - at))
        mcpbar.fetch_codex_limits()
        with open(mcpbar.CODEX_LIMITS) as fh:
            written = json.load(fh)
        self.assertEqual([(w["pool"], w["used_percentage"]) for w in written["windows"]],
                         [("codex", 97), ("reserve", 29)])

    def test_за_резервным_окном_в_прошлое_не_ходим(self):
        """Аккаунт, который ни разу не упирался в лимит, резервного окна не имеет вовсе —
        и поиск его в прошлых сессиях повторялся бы на каждом опросе без всякого шанса.
        Назад идём ровно за обычными окнами и только когда их нет."""
        seen = []
        real = mcpbar.codex_file_snapshots

        def counting(path):
            seen.append(path)
            return real(path)

        for name in ("a", "b", "c"):
            path = self.rollout(f"rollout-2026-09-11T10-00-00-{name}.jsonl", [
                {"timestamp": "2026-09-11T10:00:00Z", "type": "turn_context",
                 "payload": {"turn_id": "1", "model": "gpt-5.6-terra"}},
                self.token_count({"used_percent": 10, "window_minutes": 300}),
            ])
            os.utime(path, (1_000_000 + ord(name), 1_000_000 + ord(name)))
        mcpbar.codex_file_snapshots = counting
        try:
            mcpbar.fetch_codex_limits()
        finally:
            mcpbar.codex_file_snapshots = real
        self.assertEqual(len(seen), 1, seen)

    def test_память_доезжает_до_файла(self):
        """Сквозь весь путь: обычный ход, потом резервный — в файле остаются оба пула."""
        first = self.rollout("rollout-2026-09-11T10-00-00-one.jsonl", [
            self.token_count({"used_percent": 97, "window_minutes": 300,
                              "resets_at": 1_789_124_400},
                             {"used_percent": 15, "window_minutes": 10080,
                              "resets_at": 1_789_700_000}, plan="plus"),
        ])
        os.utime(first, (1_000_000, 1_000_000))
        mcpbar.fetch_codex_limits()
        second = self.rollout("rollout-2026-09-11T11-00-00-two.jsonl", [
            {"timestamp": "2026-09-11T11:00:00Z", "type": "turn_context",
             "payload": {"turn_id": "1", "model": "gpt-reserve"}},
            self.token_count({"used_percent": 29, "window_minutes": 10080,
                              "resets_at": 1_789_800_000},
                             stamp="2026-09-11T11:00:00Z", plan="plus"),
        ])
        os.utime(second, (2_000_000, 2_000_000))
        mcpbar.fetch_codex_limits()
        with open(mcpbar.CODEX_LIMITS) as fh:
            written = json.load(fh)
        self.assertEqual([(w["pool"], w["kind"], w["used_percentage"]) for w in written["windows"]],
                         [("codex", "primary", 97), ("codex", "secondary", 15),
                          ("reserve", "primary", 29)])
        # Артефакт для swift-стороны шва: model-проверка парсит ровно этот файл и обязана
        # увидеть в нём три окна — два обычных и резервное.
        repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        seam_dir = os.path.join(repo, "build", "seam")
        os.makedirs(seam_dir, exist_ok=True)
        shutil.copyfile(mcpbar.CODEX_LIMITS,
                        os.path.join(seam_dir, "codex-limits-pools.json"))


class CodexHooks(unittest.TestCase):
    """Codex запускает только те хуки, которым человек дал доверие. Наши он не запускает,
    пока их не одобрили, — и тогда ни один файл сессии Codex не пишется, а вкладка Sessions
    молча пуста. Молчание неотличимо от «Codex просто не запущен», поэтому статус доверия
    спрашивается у самого Codex и доезжает до панели отдельным файлом."""

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.saved = {k: getattr(mcpbar, k)
                      for k in ("CODEX", "CODEX_ROOT", "CODEX_HOOKS", "ROOT",
                                "codex_hooks_list", "codex_rpc")}
        mcpbar.CODEX = os.path.join(self._dir.name, ".codex")
        self.root = os.path.join(self._dir.name, "control-bar")
        mcpbar.ROOT = self.root
        mcpbar.CODEX_ROOT = os.path.join(self.root, "codex")
        mcpbar.CODEX_HOOKS = os.path.join(self.root, "codex", "hooks.json")

    def tearDown(self):
        for key, value in self.saved.items():
            setattr(mcpbar, key, value)
        self._dir.cleanup()

    def groups(self, *hooks):
        """Форма ответа `hooks/list` — проверена живьём на codex-cli 0.154.0."""
        return [{"cwd": "/x", "hooks": list(hooks)}]

    def ours(self, trust, event="preToolUse"):
        command = ('PATH="/opt/homebrew/bin" node ' + os.path.join(self.root, "update.js")
                   + " pre --provider codex")
        return {"eventName": event, "command": command, "enabled": True, "trustStatus": trust}

    def test_считаются_только_свои_неодобренные(self):
        """Чужой неодобренный хук — не наше дело: человеку нельзя показывать подсказку про
        наши хуки из-за чужого, который он сознательно оставил без доверия."""
        alien = {"eventName": "preToolUse", "command": "/usr/local/bin/somebody-else",
                 "enabled": True, "trustStatus": "untrusted"}
        count = mcpbar.codex_untrusted_ours(
            self.groups(self.ours("untrusted"), self.ours("trusted", "stop"), alien))
        self.assertEqual(count, 1)

    def test_дом_с_апострофом_и_соседний_бэкап(self):
        """Обе формы записи пути, как их пишет hooks/install.js. В доме с апострофом голого
        пути в команде нет вовсе — только экранированный, и наивный поиск подстроки дал бы
        ноль, то есть подсказку не увидел бы ровно тот, у кого путь непростой. А справа путь
        якорится: «update.js» — начало соседского «update.js.bak», и он не наш."""
        script = os.path.join(self.root, "update.js")
        quoted = "node '" + script.replace("'", "'\\''") + "' pre --provider codex"
        backup = {"eventName": "preToolUse", "command": f"node {script}.bak pre",
                  "enabled": True, "trustStatus": "untrusted"}
        mine = {"eventName": "preToolUse", "command": quoted,
                "enabled": True, "trustStatus": "untrusted"}
        self.assertEqual(mcpbar.codex_untrusted_ours(self.groups(mine, backup)), 1)

    def test_выключенный_хук_не_считается(self):
        """Выключенный не запустится и с доверием — подсказка про него врала бы."""
        off = dict(self.ours("untrusted"), enabled=False)
        self.assertEqual(mcpbar.codex_untrusted_ours(self.groups(off)), 0)

    def test_неожиданная_форма_это_ноль_а_не_падение(self):
        self.assertEqual(mcpbar.codex_untrusted_ours(None), 0)
        self.assertEqual(mcpbar.codex_untrusted_ours([{"hooks": "нет"}]), 0)
        self.assertEqual(mcpbar.codex_untrusted_ours([{"hooks": [{"command": None}]}]), 0)

    def test_файл_пишется_только_владельцу(self):
        """В нём ничего секретного, но каталог общий для staff, и режим здесь тот же, что
        у соседних файлов состояния — одно правило на весь каталог."""
        os.makedirs(mcpbar.CODEX, exist_ok=True)
        mcpbar.codex_hooks_list = lambda: (self.groups(self.ours("untrusted")), None)
        mcpbar.fetch_codex_hooks()
        with open(mcpbar.CODEX_HOOKS) as fh:
            written = json.load(fh)
        self.assertEqual(written["untrusted"], 1)
        self.assertEqual(stat.S_IMODE(os.stat(mcpbar.CODEX_HOOKS).st_mode), 0o600)
        repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        seam_dir = os.path.join(repo, "build", "seam")
        os.makedirs(seam_dir, exist_ok=True)
        shutil.copyfile(mcpbar.CODEX_HOOKS, os.path.join(seam_dir, "codex-hooks.json"))

    def test_без_codex_ничего_не_пишется(self):
        self.assertIn("~/.codex", mcpbar.fetch_codex_hooks())
        self.assertFalse(os.path.exists(mcpbar.CODEX_HOOKS))

    def test_молчание_app_server_не_гасит_прошлый_ответ(self):
        """Отказ app-server — это «не знаю», а не «всё одобрено»: перезаписать ноль поверх
        честной восьмёрки значит убрать подсказку ровно тогда, когда она нужна."""
        os.makedirs(mcpbar.CODEX, exist_ok=True)
        mcpbar.codex_hooks_list = lambda: (self.groups(self.ours("untrusted")), None)
        mcpbar.fetch_codex_hooks()
        mcpbar.codex_hooks_list = lambda: ([], "app-server timed out")
        mcpbar.fetch_codex_hooks()
        with open(mcpbar.CODEX_HOOKS) as fh:
            self.assertEqual(json.load(fh)["untrusted"], 1)

    def test_изменённый_после_одобрения_тоже_ждёт(self):
        """`modified` — хук, одобренный раньше, чья команда с тех пор поменялась: так бывает
        после обновления приложения. Codex снова его пропускает, и «одобрено» про него — неправда."""
        self.assertEqual(mcpbar.codex_untrusted_ours(self.groups(self.ours("modified"))), 1)

    def fake_app_server(self, before, after, write_error=None):
        """Подмена app-server: `hooks/list` отвечает `before`, а после записи доверия — `after`."""
        calls = []

        def rpc(method, params=None, timeout=30):
            calls.append((method, params))
            if method == "config/batchWrite":
                return (None, write_error) if write_error else ({}, None)
            wrote = any(m == "config/batchWrite" for m, _ in calls)
            return {"data": after if wrote else before}, None

        mcpbar.codex_rpc = rpc
        return calls

    def test_одобрение_пишет_хеш_codex_только_своим_ждущим(self):
        """Хеш берётся из ответа Codex, а не считается нами, и пишется тем же `config/batchWrite`
        в `hooks.state`, что шлёт кнопка доверия в самом Codex. Чужой хук, уже одобренный и
        выключенный — не трогаются: одобряется ровно то, о чём была кнопка."""
        os.makedirs(mcpbar.CODEX, exist_ok=True)
        waiting = dict(self.ours("untrusted"), key="hooks.json:pre_tool_use:0:0",
                       currentHash="sha256:aa")
        changed = dict(self.ours("modified", "stop"), key="hooks.json:stop:0:0",
                       currentHash="sha256:bb")
        done = dict(self.ours("trusted", "sessionStart"), key="k3", currentHash="sha256:cc")
        off = dict(self.ours("untrusted", "sessionEnd"), enabled=False, key="k4",
                   currentHash="sha256:dd")
        alien = {"eventName": "preToolUse", "command": "/usr/local/bin/somebody-else",
                 "enabled": True, "trustStatus": "untrusted", "key": "k5",
                 "currentHash": "sha256:ee"}
        calls = self.fake_app_server(
            self.groups(waiting, changed, done, off, alien),
            self.groups(dict(waiting, trustStatus="trusted"), dict(changed, trustStatus="trusted"),
                        done, off, alien))
        mcpbar.approve_codex_hooks()
        writes = [params for method, params in calls if method == "config/batchWrite"]
        self.assertEqual(writes, [{"edits": [{"keyPath": "hooks.state", "value": {
            "hooks.json:pre_tool_use:0:0": {"trusted_hash": "sha256:aa"},
            "hooks.json:stop:0:0": {"trusted_hash": "sha256:bb"},
        }, "mergeStrategy": "upsert"}]}])
        with open(mcpbar.CODEX_HOOKS) as fh:
            self.assertEqual(json.load(fh)["untrusted"], 0,
                             "счёт — это новый ответ Codex после записи, а не наша догадка")

    def test_нечего_одобрять_конфиг_не_трогаем(self):
        """Запись меняет mtime config.toml, а по нему приложение решает спросить Codex снова —
        пустая запись на каждый клик заставляла бы спрашивать впустую."""
        os.makedirs(mcpbar.CODEX, exist_ok=True)
        done = dict(self.ours("trusted"), key="k", currentHash="sha256:aa")
        calls = self.fake_app_server(self.groups(done), self.groups(done))
        mcpbar.approve_codex_hooks()
        self.assertNotIn("config/batchWrite", [method for method, _ in calls])

    def test_отказ_записи_не_выдаётся_за_одобрение(self):
        os.makedirs(mcpbar.CODEX, exist_ok=True)
        waiting = dict(self.ours("untrusted"), key="k", currentHash="sha256:aa")
        self.fake_app_server(self.groups(waiting),
                             self.groups(dict(waiting, trustStatus="trusted")),
                             write_error="config is locked")
        self.assertEqual(mcpbar.approve_codex_hooks(), "config is locked")
        self.assertFalse(os.path.exists(mcpbar.CODEX_HOOKS))


class FindCodex(unittest.TestCase):
    """С поиска бинаря начинается любой вопрос к Codex: серверы, хуки, доверие. Приложение
    запускает скрипт без PATH из шелла пользователя, а Codex, поставленный десктопным
    приложением, лежит только внутри этого приложения."""

    def test_codex_из_десктопного_приложения(self):
        inside = "/Applications/ChatGPT.app/Contents/Resources/codex"
        with mock.patch("os.path.exists", lambda path: path == inside), \
                mock.patch.dict(os.environ, {"PATH": ""}):
            self.assertEqual(mcpbar.find_codex(), inside)

    def test_нигде_нет_это_пустая_строка_а_не_падение(self):
        with mock.patch("os.path.exists", lambda path: False), \
                mock.patch.dict(os.environ, {"PATH": ""}):
            self.assertEqual(mcpbar.find_codex(), "")


class CodexMCP(unittest.TestCase):
    """Серверы MCP Codex читаются двумя командами самого Codex и пишутся в форме mcp.json.

    Форму отдаёт чужой бинарь, а переключатели правят чужой config.toml — оба места
    проверены на codex-cli 0.154.0 живьём. Каждый случай ниже — форма, на которой
    наивный разбор либо терял сервер, либо показывал чужое число.
    """

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.saved = {k: getattr(mcpbar, k) for k in ("CODEX", "CODEX_ROOT", "CODEX_MCP", "ROOT")}
        mcpbar.CODEX = os.path.join(self._dir.name, ".codex")
        self.root = os.path.join(self._dir.name, "control-bar")
        mcpbar.ROOT = self.root
        mcpbar.CODEX_ROOT = os.path.join(self.root, "codex")
        mcpbar.CODEX_MCP = os.path.join(self.root, "codex", "mcp.json")
        os.makedirs(mcpbar.CODEX, exist_ok=True)

    def tearDown(self):
        for key, value in self.saved.items():
            setattr(mcpbar, key, value)
        self._dir.cleanup()

    # `codex mcp list --json` — проверено живьём: выключенные серверы в списке ЕСТЬ, в отличие
    # от `claude mcp list`, поэтому досинтезировать их из прошлого состояния не нужно.
    LISTED = [
        {"name": "wiki", "enabled": True, "disabled_reason": None,
         "transport": {"type": "stdio", "command": "/usr/local/bin/ya",
                       "args": ["tool", "mcp", "connect"], "env": None},
         "auth_status": "unsupported"},
        {"name": "off-one", "enabled": False, "disabled_reason": None,
         "transport": {"type": "stdio", "command": "/bin/echo", "args": []},
         "auth_status": "unsupported"},
        {"name": "needs-login", "enabled": True, "disabled_reason": None,
         "transport": {"type": "streamable_http", "url": "https://example.test/mcp"},
         "auth_status": "unauthorized"},
    ]

    # `mcpServerStatus/list` через app-server — тоже проверено живьём: camelCase, полные схемы
    # инструментов, и pluginId у серверов, приехавших с плагином Codex.
    STATUS = {
        "wiki": {"runtimeStatus": "ready", "pluginId": None, "toolsError": None,
                 "authStatus": "unsupported", "tools": {
                     "Read": {"name": "Read", "description": "Read a page",
                              "inputSchema": {"type": "object",
                                              "properties": {"slug": {"type": "string",
                                                                      "description": "page slug"}},
                                              "required": ["slug"]}},
                     "Delete": {"name": "Delete", "description": "Delete a page",
                                "inputSchema": {"type": "object", "properties": {}}}}},
        "off-one": {"runtimeStatus": None, "pluginId": None, "toolsError": None,
                    "authStatus": "unsupported", "tools": {}},
    }

    def write_get(self, name, enabled_tools=None, disabled_tools=None):
        """Ответ `codex mcp get <name> --json` — списки allow/deny живут только здесь."""
        self.gets = getattr(self, "gets", {})
        self.gets[name] = {"name": name, "enabled_tools": enabled_tools,
                           "disabled_tools": disabled_tools}

    def refresh(self, listed=None, status=None, list_error=None, status_error=None):
        """Подменяем ровно те функции, что ходят в чужой бинарь; сборка карты — настоящая."""
        self.gets = getattr(self, "gets", {})
        patched = {
            "codex_mcp_list": lambda: (listed if listed is not None else self.LISTED, list_error),
            "codex_mcp_get": lambda name: self.gets.get(name, {}),
            "codex_server_status": lambda: (
                (status if status is not None else self.STATUS), status_error),
        }
        saved = {k: getattr(mcpbar, k) for k in patched}
        for key, value in patched.items():
            setattr(mcpbar, key, value)
        try:
            return mcpbar.refresh_codex_mcp()
        finally:
            for key, value in saved.items():
                setattr(mcpbar, key, value)

    def servers(self):
        with open(mcpbar.CODEX_MCP) as fh:
            data = json.load(fh)
        return {s["name"]: s for s in data["servers"]}, data

    def test_сервер_пишется_в_той_же_форме_что_у_claude(self):
        """MCPModel читает оба файла ОДНИМ парсером — значит ключи обязаны совпадать."""
        self.refresh()
        servers, data = self.servers()
        wiki = servers["wiki"]
        self.assertEqual(wiki["state"], "ok")
        self.assertEqual(wiki["provider"], "codex")
        self.assertEqual(wiki["source"], "codex")
        self.assertEqual(wiki["disabled"], False)
        self.assertEqual(wiki["toolNames"], ["Delete", "Read"])
        self.assertEqual(wiki["tools"], 2)
        self.assertEqual(wiki["toolDocs"]["Read"], "Read a page")
        self.assertEqual(wiki["toolParams"]["Read"],
                         [{"name": "slug", "type": "string", "required": True,
                           "description": "page slug"}])
        self.assertEqual(wiki["deniedTools"], [])
        # Префикс инструментов у Codex тот же mcp__<server>__<tool>, что у Claude, — значит
        # и правило, и подпись в панели совпадают без второй ветки.
        self.assertEqual(wiki["toolPrefix"], "wiki")
        self.assertIn("checked_at", data)

    def test_выключенный_сервер_остаётся_в_списке(self):
        """У Codex он приходит из `mcp list` сам — но обязан читаться как off, а не как рабочий."""
        self.refresh()
        servers, _ = self.servers()
        self.assertEqual(servers["off-one"]["state"], "off")
        self.assertEqual(servers["off-one"]["disabled"], True)

    def test_сломанный_сервер_говорит_почему(self):
        """Текст ошибки от самого сервера — единственное, что объясняет красную строку.

        Тройное условие на этом месте его теряло: тернарник в питоне связывается слабее `or`,
        и проверка ключа перевода съедала ветку с настоящим сообщением. Подсказка у сломанного
        сервера оставалась пустой — то есть пустой ровно там, где нужна причина.
        """
        self.refresh(status={"wiki": {"runtimeStatus": "error", "tools": {},
                                      "toolsError": "spawn ya ENOENT", "pluginId": None}})
        servers, _ = self.servers()
        self.assertEqual(servers["wiki"]["state"], "failed")
        self.assertEqual(servers["wiki"]["status"], "spawn ya ENOENT")
        # А у выключенного и живого сервера подсказка не выдумывается.
        self.assertEqual(servers["off-one"]["status"], "disabled")
        self.assertEqual(mcpbar.codex_status_text("x", "ok", {}), "")

    def test_у_выключенного_сервера_число_инструментов_неизвестно(self):
        """app-server не поднимал его, значит пустой набор — это «не знаем», а не «их нет»."""
        self.refresh()
        servers, _ = self.servers()
        self.assertIsNone(servers["off-one"]["tools"])
        self.assertEqual(servers["off-one"]["toolNames"], [])

    def test_сервер_без_авторизации_просит_логин_а_не_показывает_ноль(self):
        """Иначе OAuth-сервер читается как «сломан» и человек лезет искать несуществующий сбой."""
        self.refresh()
        servers, _ = self.servers()
        self.assertEqual(servers["needs-login"]["state"], "auth")
        self.assertIn("codex mcp login", servers["needs-login"]["status"])

    def test_запрещённый_инструмент_читается_выключенным(self):
        """disabled_tools — это deny-список Codex; панель рисует по нему снятый переключатель."""
        self.write_get("wiki", disabled_tools=["Delete"])
        self.refresh()
        servers, _ = self.servers()
        self.assertEqual(servers["wiki"]["deniedTools"], ["Delete"])

    def test_allow_список_запрещает_всё_остальное(self):
        """enabled_tools — это allow-список: инструмента нет в нём, значит он выключен."""
        self.write_get("wiki", enabled_tools=["Read"])
        self.refresh()
        servers, _ = self.servers()
        self.assertEqual(servers["wiki"]["deniedTools"], ["Delete"])

    def test_app_server_молчит_но_серверы_всё_равно_видны(self):
        """Поднять app-server — секунды и запуск всех серверов; отказ не должен опустошать вкладку."""
        self.refresh(status={}, status_error="app-server timed out")
        servers, data = self.servers()
        self.assertEqual(sorted(servers), ["needs-login", "off-one", "wiki"])
        self.assertIsNone(servers["wiki"]["tools"], "число инструментов неизвестно, а не ноль")
        self.assertEqual(servers["wiki"]["toolNames"], [])
        self.assertEqual(data["error"], "app-server timed out")

    def test_неожиданная_форма_не_уносит_соседей(self):
        """Одна испорченная запись в чужом JSON не должна прятать остальные серверы."""
        self.refresh(listed=[{"name": "fine", "enabled": True,
                              "transport": {"type": "stdio", "command": "/bin/echo"}},
                             {"nope": True}, "строка вместо объекта", None,
                             {"name": "", "enabled": True}])
        servers, _ = self.servers()
        self.assertEqual(list(servers), ["fine"])

    def test_нет_codex_ничего_не_пишем(self):
        """На машине без Codex файл не должен появляться вовсе — иначе вкладка покажет пустую группу."""
        shutil.rmtree(mcpbar.CODEX)
        message = self.refresh()
        self.assertFalse(os.path.exists(mcpbar.CODEX_MCP))
        self.assertIn("codex", message.lower())

    def test_файл_пишется_только_владельцу(self):
        """Имена серверов и команды их запуска — не для чужих учёток на той же машине."""
        self.refresh()
        self.assertEqual(stat.S_IMODE(os.stat(mcpbar.CODEX_MCP).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(mcpbar.CODEX_ROOT).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(mcpbar.ROOT).st_mode), 0o700)

    def test_ключ_записи_у_плагинного_сервера_другой(self):
        """Сервер из плагина Codex живёт в своей таблице; запись по общему пути его не выключит."""
        self.assertEqual(mcpbar.codex_key_path("wiki", None, "enabled"),
                         "mcp_servers.wiki.enabled")
        self.assertEqual(mcpbar.codex_key_path("cua_repl", "openai-bundled", "disabled_tools"),
                         "plugins.openai-bundled.mcp_servers.cua_repl.disabled_tools")

    def test_переключение_инструмента_считает_новый_deny_список(self):
        """Пишем весь массив целиком, поэтому он должен строиться из текущего, а не с нуля."""
        self.assertEqual(mcpbar.codex_deny_next(["Delete"], "Read", True), ["Delete", "Read"])
        self.assertEqual(mcpbar.codex_deny_next(["Delete", "Read"], "Read", False), ["Delete"])
        # Повторное выключение уже выключенного — не повод удвоить запись в чужом конфиге.
        self.assertEqual(mcpbar.codex_deny_next(["Read"], "Read", True), ["Read"])
        self.assertIsNone(mcpbar.codex_deny_next(["Read"], "Read", True, only_changes=True),
                          "ничего не изменилось — значит и писать нечего")

    def test_карта_серверов_переезжает_в_шов_для_swift(self):
        """Тот же шов, что у лимитов: swift разбирает файл, который написал настоящий refresh."""
        self.write_get("wiki", disabled_tools=["Delete"])
        self.refresh()
        repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        seam_dir = os.path.join(repo, "build", "seam")
        os.makedirs(seam_dir, exist_ok=True)
        shutil.copyfile(mcpbar.CODEX_MCP, os.path.join(seam_dir, "codex-mcp.json"))



if __name__ == "__main__":
    unittest.main(verbosity=2)
