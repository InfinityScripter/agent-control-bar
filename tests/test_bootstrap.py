#!/usr/bin/env python3
"""Plugin bootstrap: определение своих хуков в settings.json.

Запуск: /usr/bin/python3 -m unittest discover -s tests -v
"""

import json
import os
import shutil
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hooks"))

import bootstrap  # noqa: E402


def settings_with(commands):
    return {"hooks": {"Stop": [{"hooks": [
        {"type": "command", "command": c} for c in commands
    ]}]}}


class AppHooksPresent(unittest.TestCase):
    """`ROOT in command` — подстрока без границы пути: чужой каталог control-bar-extra и
    команда, всего лишь читающая файл из нашего каталога, считались нашими хуками. Пока такая
    «наша» запись жива, plugin-канал не может забрать lease — и оба канала стреляют вечно."""

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self._saved = bootstrap.SETTINGS
        bootstrap.SETTINGS = os.path.join(self._dir.name, "settings.json")

    def tearDown(self):
        bootstrap.SETTINGS = self._saved
        self._dir.cleanup()

    def write(self, data):
        with open(bootstrap.SETTINGS, "w") as fh:
            json.dump(data, fh)

    def test_настоящие_хуки_видны(self):
        for script in ("update.js", "lifecycle.js"):
            self.write(settings_with(
                [f"PATH=\"…\" node '{os.path.join(bootstrap.ROOT, script)}' pre"]))
            self.assertTrue(bootstrap.app_hooks_present(), script)

    def test_старое_написание_без_кавычек_видно(self):
        self.write(settings_with([f"node {os.path.join(bootstrap.ROOT, 'update.js')} pre"]))
        self.assertTrue(bootstrap.app_hooks_present())

    def test_чужой_каталог_с_нашим_префиксом_не_наш(self):
        self.write(settings_with([f"node '{bootstrap.ROOT}-extra/custom.js' pre"]))
        self.assertFalse(bootstrap.app_hooks_present())

    def test_чтение_файла_из_нашего_каталога_не_наш_хук(self):
        self.write(settings_with([f"cat '{os.path.join(bootstrap.ROOT, 'mcp.json')}'"]))
        self.assertFalse(bootstrap.app_hooks_present())

    def test_сосед_с_именем_префиксом_не_наш(self):
        """update.js — сам по себе префикс имени update.js.bak: без правой границы
        совпадение по голому написанию считало соседа нашим хуком."""
        self.write(settings_with([f"cat '{os.path.join(bootstrap.ROOT, 'update.js.bak')}'"]))
        self.assertFalse(bootstrap.app_hooks_present())

    def test_домашний_каталог_с_апострофом_виден(self):
        """install.js квотирует апостроф как '\\'': голого пути в такой команде нет вовсе.
        Без кавычной ветки детектор его не видел — и plugin забирал lease, не сняв дубли."""
        saved_root = bootstrap.ROOT
        bootstrap.ROOT = "/Volumes/O'Brien/.claude/control-bar"
        try:
            script = os.path.join(bootstrap.ROOT, "update.js")
            command = f"PATH=\"…\" node {bootstrap.shell_quoted(script)} pre"
            self.assertNotIn(script, command)  # голое написание и правда отсутствует
            self.write(settings_with([command]))
            self.assertTrue(bootstrap.app_hooks_present())
        finally:
            bootstrap.ROOT = saved_root


class QuitIntent(unittest.TestCase):
    """Явный Quit обязан пережить резюме сессии.

    SessionStart стреляет и на новую сессию, и на резюме (--resume/--continue, пробуждение,
    компакция). bootstrap.py бежит ПАРАЛЛЕЛЬНО lifecycle.js, поэтому не может полагаться на
    то, что тот уже удалил маркер: правило source→можно-ли-запускать у него своё, одинаковое
    с lifecycle. Без него приложение «возвращалось само» при открытии крышки ноутбука.
    """

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        tmp = self._dir.name
        self._saved = {k: getattr(bootstrap, k) for k in
                       ("ROOT", "QUIT_MARKER", "PATHS", "OWNER", "SETTINGS")}
        bootstrap.ROOT = tmp
        bootstrap.QUIT_MARKER = os.path.join(tmp, "quit-intent")
        bootstrap.PATHS = os.path.join(tmp, "paths.json")
        bootstrap.OWNER = os.path.join(tmp, "owner.json")
        bootstrap.SETTINGS = os.path.join(tmp, "settings.json")

    def tearDown(self):
        for k, v in self._saved.items():
            setattr(bootstrap, k, v)
        self._dir.cleanup()

    def marker(self):
        with open(bootstrap.QUIT_MARKER, "w"):
            pass

    def test_резюме_с_маркером_не_запускает(self):
        self.marker()
        self.assertFalse(bootstrap.may_launch({"source": "resume"}))
        self.assertFalse(bootstrap.may_launch({"source": "compact"}))
        self.assertFalse(bootstrap.may_launch({"source": "fork"}))

    def test_новая_сессия_запускает_даже_с_маркером(self):
        self.marker()
        self.assertTrue(bootstrap.may_launch({"source": "startup"}))
        self.assertTrue(bootstrap.may_launch({"source": "clear"}))

    def test_резюме_без_маркера_запускает(self):
        self.assertTrue(bootstrap.may_launch({"source": "resume"}))

    def test_старый_клод_без_source_запускает(self):
        """Payload без source — старый Claude Code: считать его резюме значило бы, что один
        Quit оставляет приложение лежать навсегда."""
        self.marker()
        self.assertTrue(bootstrap.may_launch({}))
        self.assertTrue(bootstrap.may_launch(None))
        self.assertTrue(bootstrap.may_launch("мусор вместо словаря"))

    def _run_main(self, payload, system_version):
        """main() целиком: заглушки на границах — бандлы, pgrep, Popen, stdin, платформа.

        sys.platform подменяется на darwin: main() на другой платформе выходит сразу, и на
        Linux-машине контрибьютора оба теста ниже проверяли бы пустоту (один падал, второй
        проходил случайно). Все пути и границы уже подменены — darwin-специфики не остаётся.
        """
        import io
        launches = []
        saved = {
            "bundle_version": bootstrap.bundle_version,
            "running": bootstrap.running,
        }
        saved_popen, saved_stdin = bootstrap.subprocess.Popen, sys.stdin
        saved_platform = sys.platform
        bootstrap.bundle_version = (
            lambda app: system_version if app == bootstrap.SYSTEM_APP
            else bootstrap.plugin_version())
        bootstrap.running = lambda: False
        bootstrap.subprocess.Popen = lambda *a, **kw: launches.append(a[0]) or None
        sys.stdin = io.StringIO(json.dumps(payload))
        sys.platform = "darwin"
        try:
            rc = bootstrap.main()
        finally:
            for k, v in saved.items():
                setattr(bootstrap, k, v)
            bootstrap.subprocess.Popen = saved_popen
            sys.stdin = saved_stdin
            sys.platform = saved_platform
        return rc, launches

    def test_main_не_поднимает_приложение_на_резюме_после_quit(self):
        self.marker()
        # Ветка «в /Applications стоит DMG-копия» — первый из двух пусков.
        rc, launches = self._run_main({"source": "resume"}, system_version="9.9.9")
        self.assertEqual(rc, 0)
        self.assertEqual(launches, [])
        # Ветка «своя сборка актуальна» — второй пуск.
        rc, launches = self._run_main({"source": "resume"}, system_version=None)
        self.assertEqual(rc, 0)
        self.assertEqual(launches, [])

    def test_main_поднимает_на_новой_сессии_несмотря_на_маркер(self):
        self.marker()
        rc, launches = self._run_main({"source": "startup"}, system_version="9.9.9")
        self.assertEqual(rc, 0)
        self.assertEqual(len(launches), 1)


class BuildTimeout(unittest.TestCase):
    """Затянувшаяся сборка — событие, а не трейсбек.

    subprocess.run(timeout=300) кидает TimeoutExpired, который никто не ловил: хук падал
    необработанным исключением (Claude Code показывает это как ошибку хука), а дети bash —
    swiftc/lipo/codesign — оставались жить: питон убивает только непосредственного ребёнка.
    """

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self._saved = {k: getattr(bootstrap, k) for k in ("ROOT", "PLUGIN_ROOT")}
        bootstrap.ROOT = self._dir.name
        bootstrap.PLUGIN_ROOT = self._dir.name

    def tearDown(self):
        for k, v in self._saved.items():
            setattr(bootstrap, k, v)
        self._dir.cleanup()

    def _write_build_script(self, body):
        path = os.path.join(bootstrap.PLUGIN_ROOT, "build.sh")
        with open(path, "w") as fh:
            fh.write("#!/bin/bash\n" + body)
        os.chmod(path, 0o755)

    def test_таймаут_не_роняет_хук_и_пишет_в_problems_log(self):
        """Скрипт спит дольше потолка: build() обязан вернуть False, а не кинуть."""
        self._write_build_script("sleep 30\n")
        result = bootstrap.build(os.path.join(self._dir.name, "out.app"), timeout=1)
        self.assertFalse(result)
        with open(os.path.join(bootstrap.ROOT, "problems.log")) as fh:
            self.assertIn("timed out", fh.read())

    def test_внутренний_потолок_с_запасом_под_внешним_хук_таймаутом(self):
        """Равные потолки — гонка: Claude Code убивает хук раньше, чем сборка успеет
        залогировать таймаут, а start_new_session уводит детей из досягаемости внешнего kill.
        Дефолт build() обязан быть строго меньше timeout'а SessionStart в hooks.json."""
        import inspect
        hooks = json.load(open(os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hooks", "hooks.json")))
        outer = hooks["hooks"]["SessionStart"][0]["hooks"][0]["timeout"]
        inner = inspect.signature(bootstrap.build).parameters["timeout"].default
        self.assertLess(inner, outer)

    def test_таймаут_убивает_всю_группу_а_не_только_bash(self):
        """bash порождает внука и умирает бы один — внук должен уйти вместе с группой."""
        pidfile = os.path.join(self._dir.name, "grandchild.pid")
        self._write_build_script(f"(sleep 30 & echo $! > {pidfile}; wait)\n")
        bootstrap.build(os.path.join(self._dir.name, "out.app"), timeout=1)
        with open(pidfile) as fh:
            pid = int(fh.read().strip())
        # Группа убита SIGKILL'ом — внука-«sleep 30» быть не должно.
        try:
            os.kill(pid, 9)
            self.fail("внук сборки пережил таймаут")
        except ProcessLookupError:
            pass


class WorkingNode(unittest.TestCase):
    """Исполняемый файл ≠ node, который запускается.

    После того как Homebrew обновил llhttp, /opt/homebrew/bin/node оставался исполняемым и падал
    в dyld, не выполнив ни строки. find_node() отдавал его первым, uninstall.js --hooks-only не
    запускался, дубли хуков приложения оставались в settings.json, и lease не забирался. Идея
    пробного запуска — из PR #19.
    """

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self._saved_root = bootstrap.ROOT
        bootstrap.ROOT = self._dir.name

    def tearDown(self):
        bootstrap.ROOT = self._saved_root
        self._dir.cleanup()

    def _exe(self, name, body):
        path = os.path.join(self._dir.name, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write("#!/bin/sh\n" + body)
        os.chmod(path, 0o755)
        return path

    def _log(self):
        try:
            with open(os.path.join(bootstrap.ROOT, "problems.log")) as fh:
                return fh.read()
        except OSError:
            return ""

    def test_пропускает_исполняемый_но_не_запускающийся(self):
        broken = self._exe("broken-node", "exit 1\n")
        good = self._exe("good-node", "exit 0\n")
        self.assertEqual(bootstrap.first_working_node([broken, good]), good)
        self.assertIn(broken + ": exited with code 1", self._log())

    def test_все_битые_дают_none(self):
        broken = self._exe("broken-node", "exit 1\n")
        self.assertIsNone(bootstrap.first_working_node([broken]))

    def test_отсутствующий_кандидат_не_пробуется_и_не_логируется(self):
        good = self._exe("good-node", "exit 0\n")
        missing = os.path.join(self._dir.name, "no-such-node")
        self.assertEqual(bootstrap.first_working_node([missing, good]), good)
        self.assertEqual(self._log(), "")

    def test_причина_из_dyld_и_подсказка_brew_попадают_в_лог(self):
        """Ровно то, что пишет dyld мёртвому node; путь — ссылка в Cellar, как у Homebrew."""
        target = self._exe("Cellar/node/25.8.2/bin/node", (
            'echo "dyld[13151]: Library not loaded: /opt/homebrew/opt/llhttp/lib/libllhttp.9.3.dylib" >&2\n'
            'echo "  Referenced from: <E834CE0F> /opt/homebrew/Cellar/node/25.8.2/bin/node" >&2\n'
            "kill -ABRT $$\n"))
        link = os.path.join(self._dir.name, "bin", "node")
        os.makedirs(os.path.dirname(link))
        os.symlink(target, link)
        good = self._exe("good-node", "exit 0\n")

        self.assertEqual(bootstrap.first_working_node([link, good]), good)
        log = self._log()
        self.assertIn(link + ": Library not loaded: libllhttp.9.3.dylib", log)
        self.assertIn("usually fixed by: brew upgrade node", log)

    def test_не_homebrew_node_без_подсказки_brew(self):
        broken = self._exe("broken-node", "echo 'TypeError: nope' >&2\nexit 1\n")
        bootstrap.first_working_node([broken])
        self.assertIn(broken + ": TypeError: nope\n", self._log())
        self.assertNotIn("brew", self._log())

    def test_тот_же_битый_node_на_каждом_старте_не_раздувает_лог(self):
        first_broken = self._exe("broken-a", "exit 1\n")
        second_broken = self._exe("broken-b", "exit 2\n")
        bootstrap.first_working_node([first_broken, second_broken])
        once = self._log()
        bootstrap.first_working_node([first_broken, second_broken])
        self.assertEqual(self._log(), once)

    def test_зависший_кандидат_бросается_по_таймауту(self):
        hung = self._exe("hung-node", "exec sleep 30\n")
        good = self._exe("good-node", "exit 0\n")
        started = time.monotonic()
        self.assertEqual(bootstrap.first_working_node([hung, good], timeout=0.5, budget=10), good)
        self.assertLess(time.monotonic() - started, 5)
        self.assertIn(hung + ": did not answer within 0.5s", self._log())

    def test_бюджет_поиска_конечен(self):
        """Два зависших подряд съедают бюджет — третий, живой, уже не пробуется: сборке в том же
        хуке нужен её запас, а lease подождёт следующей сессии."""
        first = self._exe("hung-a", "exec sleep 30\n")
        second = self._exe("hung-b", "exec sleep 30\n")
        good = self._exe("good-node", "exit 0\n")
        started = time.monotonic()
        self.assertIsNone(bootstrap.first_working_node([first, second, good], timeout=5, budget=0.6))
        self.assertLess(time.monotonic() - started, 3)
        self.assertIn("stopped looking after 0.6s", self._log())

    def test_поиск_uninstall_и_сборка_помещаются_в_таймаут_хука(self):
        """Все трое идут в одном SessionStart под одним потолком из hooks.json."""
        import inspect
        hooks = json.load(open(os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hooks", "hooks.json")))
        outer = hooks["hooks"]["SessionStart"][0]["hooks"][0]["timeout"]
        build = inspect.signature(bootstrap.build).parameters["timeout"].default
        self.assertLess(bootstrap.NODE_SEARCH_BUDGET + bootstrap.UNINSTALL_TIMEOUT + build, outer)

    @unittest.skipUnless(shutil.which("node"), "нужен настоящий node, чтобы запустить uninstall.js")
    def test_lease_забирается_мимо_мёртвого_первого_node(self):
        """Весь путь целиком: мёртвый node первым в списке, настоящий uninstall.js --hooks-only,
        песочница вместо HOME. Дубли хуков приложения уходят, owner.json — за плагином."""
        home = self._dir.name
        root = os.path.join(home, ".claude", "control-bar")
        settings = os.path.join(home, ".claude", "settings.json")
        os.makedirs(root)
        ours = (f"PATH=\"/opt/homebrew/bin:/usr/local/bin${{PATH:+:$PATH}}\" node "
                f"'{os.path.join(root, 'update.js')}' pre")
        with open(settings, "w") as fh:
            json.dump(settings_with([ours, "echo keep-me"]), fh)
        dead = self._exe("dead-node", "kill -ABRT $$\n")

        names = ("ROOT", "SETTINGS", "OWNER", "PLUGIN_ROOT", "node_candidates")
        saved = {name: getattr(bootstrap, name) for name in names}
        saved_home = os.environ.get("HOME")
        bootstrap.ROOT, bootstrap.SETTINGS = root, settings
        bootstrap.OWNER = os.path.join(root, "owner.json")
        bootstrap.PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        bootstrap.node_candidates = lambda: [dead, shutil.which("node")]
        os.environ["HOME"] = home  # uninstall.js finds settings.json through os.homedir()
        try:
            bootstrap.claim_hooks()
            present = bootstrap.app_hooks_present()
        finally:
            for name, value in saved.items():
                setattr(bootstrap, name, value)
            if saved_home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = saved_home

        self.assertFalse(present, "дубли хуков приложения остались в settings.json")
        with open(os.path.join(root, "owner.json")) as fh:
            self.assertEqual(json.load(fh)["channel"], "plugin")
        with open(settings) as fh:
            self.assertIn("echo keep-me", fh.read())

    def test_первыми_пробуются_каталоги_из_PATH_хуков(self):
        """Команды хуков ставят их в начало PATH — их node и будет запущен в хуках."""
        self.assertEqual(bootstrap.node_candidates()[:2],
                         ["/opt/homebrew/bin/node", "/usr/local/bin/node"])


if __name__ == "__main__":
    unittest.main()
