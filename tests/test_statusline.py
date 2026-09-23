#!/usr/bin/env python3
"""Перехват payload'а statusLine.

Запуск: /usr/bin/python3 -m unittest discover -s tests -v
Каждый случай — реальная ошибка, а не проверка формы кода.
"""

import importlib
import json
import os
import subprocess
import sys
import tempfile
import unittest

HOOKS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hooks")
sys.path.insert(0, HOOKS)
SCRIPTS = os.path.join(os.path.dirname(HOOKS), "scripts")
sys.path.insert(0, SCRIPTS)


class Capture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.environ["CONTROL_BAR_ROOT"] = self.tmp
        # ROOT считается на импорте — перезагружаем, чтобы модуль увидел песочницу.
        import statusline

        self.statusline = importlib.reload(statusline)

    def limits(self):
        with open(os.path.join(self.tmp, "limits.json")) as fh:
            return json.load(fh)

    def windows(self):
        with open(os.path.join(self.tmp, "model-windows.json")) as fh:
            return json.load(fh)

    def test_проценты_округляются_до_целого(self):
        """Swift читает это через `as? Int`, и для 4.2 он возвращает nil.

        Лимиты тогда молча исчезают из меню, а файл на диске выглядит совершенно здоровым.
        """
        self.statusline.capture_limits({"rate_limits": {
            "five_hour": {"used_percentage": 4.2, "resets_at": 111},
            "seven_day": {"used_percentage": 68.9, "resets_at": 222},
        }})
        got = self.limits()
        self.assertIsInstance(got["five_hour"]["used_percentage"], int)
        self.assertEqual(got["five_hour"]["used_percentage"], 4)
        self.assertEqual(got["seven_day"]["used_percentage"], 69)

    def test_незнакомые_окна_лимитов_тоже_сохраняются(self):
        """В 2.1.205 есть ещё seven_day_opus и seven_day_sonnet; тариф может добавить свои."""
        self.statusline.capture_limits({"rate_limits": {
            "five_hour": {"used_percentage": 1},
            "seven_day_opus": {"used_percentage": 50},
        }})
        self.assertIn("seven_day_opus", self.limits())

    def test_без_лимитов_файл_не_трогается(self):
        """Блок приходит только подписчикам и только после первого ответа API.

        Пустая запись на ранней отрисовке затёрла бы последние удачные цифры, и раздел
        «Лимиты» мигал бы между числом и пустотой.
        """
        self.statusline.capture_limits({"rate_limits": {
            "five_hour": {"used_percentage": 7}}})
        self.statusline.capture_limits({})
        self.statusline.capture_limits({"rate_limits": {}})
        self.assertEqual(self.limits()["five_hour"]["used_percentage"], 7)

    def test_окно_модели_запоминается_из_payload(self):
        """Реестр моделей внутри бинаря неполон: claude-opus-5 в нём нет вовсе.

        Payload называет размер окна прямо — наблюдение точнее и выскребленного, и догадки.
        """
        self.statusline.learn_window({
            "model": {"id": "claude-opus-5"},
            "context_window": {"context_window_size": 1000000},
        })
        cache = self.windows()
        self.assertEqual(cache["observed"]["claude-opus-5"], 1000000)
        self.assertEqual(cache["models"]["claude-opus-5"], 1000000)

    def test_наблюдение_перебивает_выскребленную_таблицу(self):
        with open(os.path.join(self.tmp, "model-windows.json"), "w") as fh:
            json.dump({"models": {"claude-opus-5": 200000}}, fh)
        self.statusline.learn_window({
            "model": {"id": "claude-opus-5"},
            "context_window": {"context_window_size": 1000000},
        })
        self.assertEqual(self.windows()["models"]["claude-opus-5"], 1000000)

    def test_мусорный_payload_не_роняет(self):
        """Скрипт уходит в фон от строки состояния: падать ему некуда и незачем."""
        for junk in ({}, {"rate_limits": "нет"}, {"model": None}, {"context_window": []}):
            self.statusline.capture_limits(junk)
            self.statusline.learn_window(junk)


    def test_повторение_той_же_картины_не_переписывает_файл(self):
        """statusLine с refreshInterval перерисовывается каждую секунду, цифры движутся
        минутами — идентичная запись на каждой перерисовке была бы чистым дёрганьем диска."""
        payload = {"rate_limits": {"five_hour": {"used_percentage": 12, "resets_at": 1}}}
        self.statusline.capture_limits(payload)
        path = os.path.join(self.tmp, "limits.json")
        first = os.stat(path).st_mtime_ns
        self.statusline.capture_limits(payload)
        self.assertEqual(os.stat(path).st_mtime_ns, first)
        # Изменившееся значение пишется сразу, минуты не ждёт.
        self.statusline.capture_limits(
            {"rate_limits": {"five_hour": {"used_percentage": 13, "resets_at": 1}}})
        self.assertEqual(self.limits()["five_hour"]["used_percentage"], 13)

    def test_окно_с_служебным_именем_не_затирает_штамп_времени(self):
        """mcpbar.py пропускает окна ts/source — иначе report() падает на
        `time.time() - limits["ts"]`. Тот же файл пишет и этот скрипт, а защиты у него не было."""
        self.statusline.capture_limits({"rate_limits": {
            "ts": {"used_percentage": 5},
            "source": {"used_percentage": 6},
            "five_hour": {"used_percentage": 1},
        }})
        got = self.limits()
        self.assertIsInstance(got["ts"], int)
        self.assertEqual(got["source"], "statusline")

    def test_время_сброса_приводится_к_epoch(self):
        """mcpbar.py пишет resets_at как epoch int, приложение читает `as? Double`.
        ISO-строка от statusLine через этот скрипт молча оставляла время сброса пустым."""
        self.statusline.capture_limits({"rate_limits": {
            "five_hour": {"used_percentage": 1, "resets_at": "2026-09-03T10:00:00Z"},
            "seven_day": {"used_percentage": 2, "resets_at": 1_800_000_000},
            "seven_day_opus": {"used_percentage": 3, "resets_at": "garbage"},
        }})
        got = self.limits()
        self.assertEqual(got["five_hour"]["resets_at"], 1_788_429_600)
        self.assertEqual(got["seven_day"]["resets_at"], 1_800_000_000)
        self.assertIsNone(got["seven_day_opus"]["resets_at"])

    def test_упавший_шаг_оставляет_след_в_problems_log(self):
        """Скрипт живёт в фоне с закрытым выводом: настоящий баг в захвате выглядел бы
        ровно как «лимиты не измерены», без единого следа. problems.log — тот же канал,
        которым пользуется mcpbar.py."""
        def broken(_payload):
            raise RuntimeError("boom")
        self.statusline.capture({"rate_limits": {"five_hour": {"used_percentage": 1}}},
                                steps=(broken, self.statusline.capture_limits))
        with open(os.path.join(self.tmp, "problems.log")) as fh:
            log = fh.read()
        self.assertIn("broken", log)
        self.assertIn("boom", log)
        # Остальные шаги после упавшего всё равно отработали.
        self.assertEqual(self.limits()["five_hour"]["used_percentage"], 1)

    def test_файлы_и_каталог_закрыты_от_группы_staff(self):
        """Домашний каталог на macOS читаем группой staff — каждым локальным пользователем.
        Здесь лежат проценты лимитов аккаунта; права ставятся при открытии дескриптора, а не
        chmod'ом после записи. Проверялось до сих пор только для JS-записей."""
        import stat

        sub = os.path.join(self.tmp, "sub")
        self.statusline.ROOT = sub
        self.statusline.LIMITS = os.path.join(sub, "limits.json")
        self.statusline.capture_limits({"rate_limits": {"five_hour": {"used_percentage": 1}}})
        self.assertEqual(stat.S_IMODE(os.stat(self.statusline.LIMITS).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(sub).st_mode), 0o700)
        self.assertFalse([f for f in os.listdir(sub) if f.endswith(".tmp")])


class Context(unittest.TestCase):
    """Процент занятого контекста, снятый с самого Claude Code.

    Пересчёт по транскрипту — догадка про размер окна: он задаётся сессией, а не моделью,
    и одна и та же модель в CLI и в приложении может идти с разным окном. В payload'е
    statusLine Claude Code называет и размер, и уже посчитанный процент — их и берём.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.environ["CONTROL_BAR_ROOT"] = self.tmp
        import statusline

        self.statusline = importlib.reload(statusline)

    def record(self, sid):
        with open(os.path.join(self.tmp, "context.d", sid + ".json")) as fh:
            return json.load(fh)

    def test_процент_берётся_из_payload(self):
        self.statusline.capture_context({
            "session_id": "abc",
            "model": {"id": "claude-opus-5"},
            "context_window": {"used_percentage": 19.4, "total_input_tokens": 192782,
                               "context_window_size": 1000000},
        })
        got = self.record("abc")
        self.assertEqual(got["pct"], 19)
        self.assertEqual(got["tokens"], 192782)
        self.assertEqual(got["window"], 1000000)
        self.assertEqual(got["model"], "claude-opus-5")

    def test_цена_и_длительность_сессии_едут_рядом_с_контекстом(self):
        # Стоимость, время и строки кода Claude Code тоже сообщает только статуслайну.
        self.statusline.capture_context({
            "session_id": "abc",
            "context_window": {"used_percentage": 5, "total_input_tokens": 1000,
                               "context_window_size": 200000},
            "cost": {"total_cost_usd": 0.4249, "total_duration_ms": 4500000,
                     "total_lines_added": 48, "total_lines_removed": 6},
        })
        got = self.record("abc")
        self.assertEqual(got["cost"], 0.42)
        self.assertEqual(got["duration"], 4500)
        self.assertEqual(got["linesAdded"], 48)
        self.assertEqual(got["linesRemoved"], 6)

    def test_бегущая_длительность_сама_по_себе_не_переписывает_файл(self):
        payload = {"session_id": "abc",
                   "context_window": {"used_percentage": 5, "total_input_tokens": 1000,
                                      "context_window_size": 200000},
                   "cost": {"total_cost_usd": 0.1, "total_duration_ms": 1000}}
        self.statusline.capture_context(payload)
        path = os.path.join(self.tmp, "context.d", "abc.json")
        before = os.stat(path).st_mtime_ns
        payload["cost"]["total_duration_ms"] = 3000
        self.statusline.capture_context(payload)
        self.assertEqual(os.stat(path).st_mtime_ns, before)

    def test_пакет_без_cost_не_стирает_уже_снятую_цену(self):
        ctx = {"used_percentage": 5, "total_input_tokens": 1000, "context_window_size": 200000}
        self.statusline.capture_context({"session_id": "abc", "context_window": dict(ctx),
                                         "cost": {"total_cost_usd": 0.5, "total_duration_ms": 9000,
                                                  "total_lines_added": 3, "total_lines_removed": 1}})
        ctx["used_percentage"] = 6
        self.statusline.capture_context({"session_id": "abc", "context_window": ctx})
        got = self.record("abc")
        self.assertEqual(got["pct"], 6)
        self.assertEqual((got["cost"], got["duration"], got["linesAdded"], got["linesRemoved"]),
                         (0.5, 9, 3, 1))

    def test_без_блока_cost_запись_контекста_всё_равно_пишется(self):
        self.statusline.capture_context({
            "session_id": "abc", "cost": "мусор",
            "context_window": {"used_percentage": 5, "total_input_tokens": 1000,
                               "context_window_size": 200000},
        })
        got = self.record("abc")
        self.assertEqual(got["pct"], 5)
        self.assertNotIn("cost", got)

    def test_без_процента_запись_не_появляется(self):
        """used_percentage бывает null до первого ответа API и сразу после /compact."""
        self.statusline.capture_context({"session_id": "abc", "context_window": {}})
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "context.d", "abc.json")))

    def test_без_session_id_ничего_не_пишется(self):
        self.statusline.capture_context({"context_window": {"used_percentage": 5}})
        self.assertFalse(os.path.isdir(os.path.join(self.tmp, "context.d")))

    def test_идентификатор_сессии_не_вырывается_из_каталога(self):
        """session_id приходит извне и становится именем файла."""
        self.statusline.capture_context({
            "session_id": "../../escaped",
            "context_window": {"used_percentage": 5, "total_input_tokens": 1,
                               "context_window_size": 200000},
        })
        self.assertFalse(os.path.exists(os.path.join(os.path.dirname(self.tmp), "escaped.json")))

    def test_та_же_картина_не_переписывает_файл(self):
        """Строка состояния перерисовывается постоянно; цифра между перерисовками та же."""
        payload = {"session_id": "abc", "model": {"id": "claude-opus-5"},
                   "context_window": {"used_percentage": 19, "total_input_tokens": 192782,
                                      "context_window_size": 1000000}}
        self.statusline.capture_context(payload)
        path = os.path.join(self.tmp, "context.d", "abc.json")
        first = os.stat(path).st_mtime_ns
        self.statusline.capture_context(payload)
        self.assertEqual(os.stat(path).st_mtime_ns, first)

    def test_мусорный_payload_не_роняет(self):
        for junk in ({}, {"session_id": 5}, {"context_window": []}, {"context_window": None}):
            self.statusline.capture_context(junk)


class Wrapper(unittest.TestCase):
    """Обёртка обязана отдать вложенной команде ровно те байты, что пришли ей."""

    @staticmethod
    def run_wrapper(root, payload="{}"):
        return subprocess.run(
            ["bash", os.path.join(HOOKS, "statusline.sh")],
            input=payload, capture_output=True, text=True,
            env={**os.environ, "CONTROL_BAR_ROOT": root}, timeout=30,
        )

    def test_вложенная_команда_получает_тот_же_payload(self):
        tmp = tempfile.mkdtemp()
        inner = os.path.join(tmp, "inner.sh")
        with open(inner, "w") as fh:
            fh.write("#!/bin/bash\nwc -c\n")
        os.chmod(inner, 0o755)
        with open(os.path.join(tmp, "statusline-inner-command"), "w") as fh:
            fh.write(f'bash "{inner}"\n')

        payload = json.dumps({"model": {"id": "claude-opus-5"}, "hint": "хвост\n"})
        result = self.run_wrapper(tmp, payload)
        # $(cat) срезал бы хвостовой перевод строки, и вложенный скрипт получил бы не тот вход.
        self.assertEqual(result.stdout.strip(), str(len(payload.encode())))

    def test_обёртка_не_зовёт_саму_себя(self):
        """Sidecar-файл — обычный текст, который можно поправить руками.

        Без этой защиты обёртка, прописанная сама в себя, форкается до отказа машины.
        """
        tmp = tempfile.mkdtemp()
        with open(os.path.join(tmp, "statusline-inner-command"), "w") as fh:
            fh.write(f'bash "{os.path.join(HOOKS, "statusline.sh")}"\n')
        result = self.run_wrapper(tmp)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_чужой_statusline_sh_исполняется_как_вложенная_команда(self):
        """statusline.sh — имя из официального примера в документации Claude Code.

        Защита от рекурсии по подстроке имени глушила ЛЮБУЮ команду с этим именем: чужая
        строка состояния пользователя после установки перехвата просто переставала выводить
        что-либо. Своя ли команда — решает сентинел окружения, а не имя файла.
        """
        tmp = tempfile.mkdtemp()
        foreign_dir = os.path.join(tmp, "foreign")
        os.makedirs(foreign_dir)
        foreign = os.path.join(foreign_dir, "statusline.sh")
        with open(foreign, "w") as fh:
            fh.write("#!/bin/bash\nprintf 'FOREIGN OK'\n")
        os.chmod(foreign, 0o755)
        with open(os.path.join(tmp, "statusline-inner-command"), "w") as fh:
            fh.write(f'bash "{foreign}"\n')
        result = self.run_wrapper(tmp)
        self.assertEqual(result.stdout, "FOREIGN OK")


class LimitsWriters(unittest.TestCase):
    """У limits.json два писателя: statusline.py (из payload statusLine) и mcpbar.py (из ответа
    эндпоинта). Приложение читает файл одним разбором, поэтому одинаковые окна обязаны давать
    одинаковую запись — раньше это держалось на комментарии «same skip as usage_record()»."""

    WINDOWS = {
        "five_hour": {"used_percentage": 4.2, "resets_at": "2026-09-23T12:00:00Z"},
        "seven_day": {"used_percentage": 68.9, "resets_at": 1_790_000_000},
        "seven_day_opus": {"used_percentage": 50},
        "ts": {"used_percentage": 1},
        "source": {"used_percentage": 1},
        # json.loads пропускает голый Infinity, а round(inf) кидает OverflowError.
        "seven_day_sonnet": {"used_percentage": float("inf")},
    }

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.environ["CONTROL_BAR_ROOT"] = self.tmp
        import statusline

        self.statusline = importlib.reload(statusline)
        import mcpbar

        self.mcpbar = mcpbar

    def test_оба_писателя_дают_одну_запись(self):
        self.statusline.capture_limits({"rate_limits": self.WINDOWS})
        with open(os.path.join(self.tmp, "limits.json")) as fh:
            from_statusline = json.load(fh)
        from_endpoint = self.mcpbar.usage_record(self.WINDOWS)

        def body(record):
            return {k: v for k, v in record.items() if k not in ("ts", "source")}

        self.assertEqual(body(from_statusline), body(from_endpoint))
        self.assertEqual(from_statusline["five_hour"],
                         {"used_percentage": 4, "resets_at": 1_790_164_800})
        self.assertNotIn("seven_day_sonnet", from_statusline)

    def test_запись_statusline_уезжает_образцом_для_swift(self):
        """Swift-проверка (tests/model/main.swift) разбирает этот файл через Limits(json:):
        единственная проверка, пересекающая границу языков для limits.json."""
        self.statusline.capture_limits({"rate_limits": self.WINDOWS})
        seam_dir = os.path.join(os.path.dirname(HOOKS), "build", "seam")
        os.makedirs(seam_dir, exist_ok=True)
        import shutil

        shutil.copyfile(os.path.join(self.tmp, "limits.json"), os.path.join(seam_dir, "limits.json"))


if __name__ == "__main__":
    unittest.main()
