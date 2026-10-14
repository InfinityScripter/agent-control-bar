# Заметки разведки: самовосстановление statusLine и состояние лимитов

Репозиторий agent-control-bar, версия 0.24.5, ветка от origin/main, рабочая копия `/Users/talalaev-m/projects/acb-self-heal`.
Здесь только факты о коде на момент разведки. Домашний каталог пользователя (`~/.claude`) не читался.

## 1. Раскладка репозитория

- `Sources/*.swift` — приложение (меню-бар). Компилируется целиком: `swiftc -O ... Sources/*.swift Sources/Model/*.swift ... -framework Cocoa -framework SwiftUI` (`build.sh:46-47`).
- `Sources/Model/*.swift` — часть без UI: разборщики, правила, данные кадров. CI компилирует её отдельно вместе с `tests/model/main.swift` и запускает (`.github/workflows/ci.yml`, шаг "Swift model checks": `swiftc -O Sources/Model/*.swift tests/model/main.swift -o "$RUNNER_TEMP/model" -framework Cocoa`, затем запуск). Файл модели, который тянет UI, не линкуется. Новый файл в `Sources/Model/` подхватывается маской, список не правится.
- Не в `Sources/Model/` и потому вне модельной проверки: `PanelData.swift` (в том числе `age(of:now:)`), `PanelStore.swift`, `PanelView.swift`, `PanelTabs.swift`, `Backend.swift`, `StatePolling.swift`, `Actions.swift`, `Notifications.swift`, `main.swift`.
- `scripts/mcpbar.py` (2106 строк) — Python-бэкенд. `scripts/mcpbar_codex.py` (824 строки) — модуль того же бэкенда, импортируется в конце `mcpbar.py` как `codex` (`mcpbar.py:2102`); сам импортирует `mcpbar as core` (`mcpbar_codex.py:17`).
- `hooks/`: Node — `install.js`, `uninstall.js`, `update.js`, `lifecycle.js`; Python — `bootstrap.py`, `statusline.py`; shell — `statusline.sh`; `hooks.json` — хуки плагина.
- `commands/limits-capture.md` — слэш-команда плагина `/limits-capture install|uninstall|status`; зовёт `mcpbar.py statusline --install|--uninstall|(без флага)`.
- `tools/release/bump.js`, `tools/update-signing`, `tools/analytics`, `tools/crab-previews`, `tools/pet-sheet`.
- `tests/`: `test_mcpbar.py`, `test_statusline.py`, `test_bootstrap.py`, `*.test.js`, `hook-harness.js`, `model/main.swift`, `fixtures/window-for.json`.
- `identity.env`: `BUNDLE_ID="io.github.infinityscripter.claude-control-bar"`, `EXEC="ClaudeControlBar"`, `APP_NAME="Agent Control Bar"`, `STATE_DIR=".claude/control-bar"`.
- Сборка `.app` (`build.sh`): версия читается из `.claude-plugin/plugin.json` (`build.sh:13`), Info.plist пишется из heredoc (`build.sh:51-68`), в `Contents/Resources/` кладутся: `update.js lifecycle.js install.js uninstall.js statusline.sh statusline.py` (плоско, `build.sh:73`), `scripts/mcpbar.py` и `scripts/mcpbar_codex.py` (`build.sh:76-78`), `AppIcon.icns`, `CHANGELOG.md`, `completion.mp3`, `pets/`. Подпись с `app.entitlements`, которое даёт только `com.apple.security.automation.apple-events`.
- Две раскладки обёртки statusLine: в плагине/репозитории `hooks/statusline.sh`, в `.app` — `Contents/Resources/statusline.sh` рядом с `statusline.py`. Скрипт бэкенда в `.app` лежит в `Contents/Resources/scripts/mcpbar.py`.
- Хуки плагина (`hooks/hooks.json`): SessionStart запускает `bootstrap.py` (таймаут 300) и `lifecycle.js start`; остальное — `update.js`/`lifecycle.js`. `bootstrap.py:335-349` (`write_paths`) пишет `~/.claude/control-bar/paths.json` с ключами `python`, `script` (путь `mcpbar.py` в каталоге плагина), `pluginRoot`, `version`. `bootstrap.py:118` знает старое имя `Claude Control Bar.app` (поиск установленного приложения).

## 2. Правила проекта (`.claude/rules/`)

`architecture.md` (пути: `Sources/**`, `hooks/**`, `scripts/**`):
- Слои Node-хуки, Python, Swift общаются только через JSON-файлы в `~/.claude/control-bar/`. Прямых импортов между слоями нет.
- Swift спавнит `mcpbar.py` как процесс и не читает его stdout как источник данных; результат — только через файл (`mcp.json`, `limits.json`, `codex/limits.json`).
- Swift не пишет `mcp.json`, `limits.json`, `codex/mcp.json`, `codex/limits.json`. Исключение: удаление `state.d/*.json` мёртвых процессов в `evaluate()`.
- `limits.json` — два писателя: `capture_limits` в `hooks/statusline.py` и команда `limits` в `scripts/mcpbar.py`; формат согласован, совпадение держит тест `LimitsWriters` в `tests/test_statusline.py`; образец для Swift — `build/seam/limits.json`.
- `codex/limits.json` — единственный писатель `mcpbar.py codex-limits`; наружу отдаёт факты (пул, проценты, длительность окна, момент сброса, момент замера); подписи окон собирает Swift. Файл хранит последний замер по каждому пулу.
- `scripts/mcpbar_codex.py` — модуль `mcpbar.py`, `ROOT` читает как `core.ROOT` в момент вызова; `build.sh` копирует оба файла; новый модуль рядом нужно добавить в `build.sh`.
- Хуки хардкодят identity-значения, не читают `identity.env`; сверку делает CI (`ci.yml`, шаг "Identity is consistent").
- `StatusController` — единственный владелец путей и жизненного цикла. Хранимое состояние и `init` в `main.swift`, поведение — по файлам-расширениям по темам (`AppLifecycle`, `HookSetup`, `Backend`, `StatePolling`, `Notifications`, `Pets`, `Updates`, `Actions`, `IconRender`, `PanelWindow`). Новый метод контроллера кладётся в файл своей темы.
- Правила, которые можно проверить без UI, живут в `Sources/Model` и проверяются модельной проверкой: `SessionBoard`, `LimitsBoard`, `Provider`, `BackendCommand` (слова командной строки `mcpbar.py`), `IdleQuit`, `GitBranches`, `StateFileLook`, `ReleaseVersion`, `HookInstall`, `MCPChange.notifications`.
- Все запуски `mcpbar.py` идут через `spawnBackend()`; второго пути с выводом в `/dev/null` нет и не заводится.
- Контракт `install.js` → Swift — код выхода: 0 хуки на месте, другой — не установлены, 75 — `settings.json` изменился во время записи. `checkHooks()` читает код и повторяет по таймеру.
- Панель: `PanelView`/`PanelTabs` читают только `PanelStore`; тот — снимок из `PanelData.swift`; вьюха не запускает `Process` и не пишет файлы; обратное направление — методы `PanelStore`, которые зовут `StatusController`.
- Таблица владельцев файлов: `owner.json` — `install.js`; `paths.json` — `bootstrap.py`; `context.d/` и `model-windows.json` — `statusline.py` (+`mcpbar.py` для второго); `uiconfig.json` — только пользователь.

`code-conventions.md` (пути: `Sources/**/*.swift`, `hooks/**`, `scripts/**/*.py`, `tests/**`):
1. Состояние — `struct` + `init(json:)` с безопасными значениями по умолчанию; движок — отдельный `final class`.
2. Статусы — строки, не Swift `enum` (значения приходят из JSON от Node/Python).
3. `Double` в `Int` только через `clampedInt` (`SafeInt.swift`), не `Int(someDouble)`.
4. Комментарии объясняют "почему", не пересказывают код. Язык комментариев правило не задаёт; по факту: `Sources/`, `hooks/*.js`, `tests/*.js`, `tests/model/main.swift` — английский; `scripts/mcpbar.py`, `scripts/mcpbar_codex.py`, `tests/test_mcpbar.py`, `tests/test_statusline.py` — русский; `hooks/statusline.py`, `hooks/bootstrap.py` — в основном английский с отдельными русскими строками. Строки интерфейса бэкенда двуязычные (`STRINGS`: пара en/ru).
5. Node-хуки: только `node:*`, без npm-зависимостей.
6. Чтение JSON в хуках — `try/catch`, возврат `null`/значения по умолчанию.
7. Python — системный `/usr/bin/python3` (3.9.6 на этой машине), без venv и pip.
8. Запись состояния в Python атомарно: `os.open(tmp, O_WRONLY|O_CREAT|O_TRUNC, 0o600)` + `os.replace`, каталоги `0o700`.
9. Хуки идемпотентны.
10. PATH в `hooks.json` фиксирован строкой `"/opt/homebrew/bin:/usr/local/bin${PATH:+:$PATH}"`.
11. Длинный текст во вьюхе SwiftUI — `private static let x: String = "…" + "…"`, не цепочка `+` внутри `Text(...)`. Страхует задача `swift-6-0` в CI (`swiftc -typecheck` под Swift 6.0).
- CI также запрещает `@State` в `Sources` (шаг "No @State in Sources"; вместо него `State(initialValue:)`), гонит `shellcheck -x build.sh hooks/statusline.sh`.
- Из `~/.claude/CLAUDE.md`/`AGENTS.md` проекта: macOS без GNU `timeout`; минимальный дифф; пуш и коммит только по прямой команде.

## 3. statusLine в `scripts/mcpbar.py`

Константы и пути: `ROOT = ~/.claude/control-bar` (`mcpbar.py:39`), `SETTINGS = ~/.claude/settings.json` (`:48`), `SECURE_DIR, SECURE_FILE = 0o700, 0o600` (`:207`).
- `STATUSLINE_INNER = ROOT/statusline-inner-command` (`:1142`) — исходная команда пользователя, текст с `\n` в конце.
- `STATUSLINE_SAVED = ROOT/statusline-saved.json` (`:1146`) — исходный объект `statusLine` целиком (или JSON `null`, если его не было).
- `STATUSLINE_INSTALLED = ROOT/statusline-installed.json` (`:1150`) — `{"command": "bash \"<wrapper>\""}`, ровно то, что записала установка.
- `statusline_sidecars()` (`:1153-1158`) — функция, возвращает кортеж из трёх путей в порядке SAVED, INNER, INSTALLED; функция нужна, потому что тесты подменяют пути по имени. `drop_statusline_sidecars()` (`:1161-1166`) удаляет все три.
- `find_statusline_wrapper()` (`:1169-1183`): от `__file__` берёт `here` и `parent`; кандидаты по порядку `parent/hooks/statusline.sh`, `parent/statusline.sh`; возвращает первый существующий путь или `None`.
- `statusline_ours(command)` (`:1186-1229`), порядок проверок:
  1. пустая команда — `False`;
  2. команда равна `statusline-installed.json["command"]` (после `strip`) — `True`, даже если файла-обёртки на диске нет;
  3. слова команды (`shlex.split`, при `ValueError` — `split()`) с базовым именем `statusline.sh`; если среди них путь с тем же `realpath`, что у `find_statusline_wrapper()`, — `True`;
  4. если запись `installed` непустая и не совпала — `False`;
  5. если записи нет, но существует хотя бы один сайдкар — `True` тогда и только тогда, когда какое-то из слов `statusline.sh` указывает на несуществующий файл (`os.path.exists`); слова не раскрываются: `~` и `$HOME` дают несуществующий путь;
  6. иначе `False`.
- `statusline_command(settings)` (`:1232-1236`): `settings["statusLine"]["command"]` со `strip`; строка вместо объекта — пустая команда.
- `statusline_state()` (`:1239-1241`): читает `SETTINGS` через `read_json(SETTINGS, {})`, возвращает `(команда, ours)`.
- `statusline_install()` (`:1244-1294`): `find_statusline_wrapper()` пуст → `t("sl.nowrapper")`; под `settings_lock()`; `read_settings_for_edit()` (`:329`) возвращает `(None, "")` для нечитаемого файла → `t("sl.busy")`; если `statusline_ours(current)` — возврат `t("sl.already")` (`:1266-1267`) без записи и без проверки, что обёртка существует; иначе `backup_settings()`, запись трёх сайдкаров, `settings["statusLine"] = {**original, "type": "command", "command": f'bash "{wrapper}"'}`, `write_settings(settings, expect=seen)`; при `False` — `drop_statusline_sidecars()` и `t("sl.busy")`.
- `statusline_uninstall()` (`:1297-1331`): при `not statusline_ours(current)` возвращает `sl.changed` (если сайдкар есть) или `sl.notours`; иначе возвращает `STATUSLINE_SAVED` (объект, либо удаляет ключ при `null`), либо команду из `STATUSLINE_INNER`.
- Помощники записи: `settings_lock()` (`:1019`, flock на `ROOT/settings.lock`), `read_settings_for_edit()` (`:329`), `settings_fingerprint()` (`:354`), `write_settings(data, expect=None)` (`:364`, `indent=2`, `False` при несовпадении отпечатка), `backup_settings()` (`:943`, файлы `settings.json.bak-control-bar-<время>`, хранит 10), `write_json(path, data, indent=None, mode=None)` (`:300`, атомарно, разворачивает симлинк через `realpath`).
- Диспетчер `main(argv)` (`:1999`): ветка `statusline` на `:2053-2061`. `--install` печатает результат `statusline_install()`, `--uninstall` — `statusline_uninstall()`, без флага — две строки `t("sl.on"|"sl.off")` и `t("sl.current", cmd=...)`. Код выхода всегда 0 (`main` возвращает 0 в конце, `:2099`).
- Строки `sl.*` в `STRINGS`: `:143-160`; `t(key, **kw)` — `:191-193`; язык `detect_lang()` (`:75-94`, `CONTROL_BAR_LANG`, затем `LC_ALL/LC_MESSAGES/LANG`, затем `AppleLanguages` из `.GlobalPreferences.plist`).
- Обёртка `hooks/statusline.sh`: корень `${CONTROL_BAR_ROOT:-$HOME/.claude/control-bar}`; защита от рекурсии переменной `CONTROL_BAR_STATUSLINE_ACTIVE`; `SELF_DIR="${BASH_SOURCE[0]%/*}"`; `statusline.py` из того же каталога запускается в фоне с закрытыми stdout/stderr (`:37-39`); внутренняя команда читается из `$ROOT/statusline-inner-command` и получает те же байты stdin (`:44-50`); пустая внутренняя команда — `exit 0`.
- Кто вызывает `statusline --install`: только команда плагина `/limits-capture install` (`commands/limits-capture.md:17`). Ни `Sources/*.swift`, ни `hooks/install.js`, ни `hooks/bootstrap.py` её не вызывают (поиск `statusline` в `Sources/` даёт только комментарии: `StatePolling.swift:21,24`, `main.swift:323`, `Limits.swift:15`, `Sessions.swift:24,31`).
- Кто вызывает `statusline --uninstall`: `hooks/uninstall.js:75-91` (только если в `~/.claude/control-bar` есть один из трёх сайдкаров; путь к `mcpbar.py` ищется как `__dirname/scripts/mcpbar.py` или `__dirname/../scripts/mcpbar.py`; запуск `/usr/bin/python3 <mcpbar> statusline --uninstall`; не вызывается при `--hooks-only`).
- Переключателя перехвата statusLine в Settings нет. `SettingsView.swift:186` — только `Toggle("Limits via Anthropic API", isOn: store.oauthLimits)`; `SettingsStore.swift:224-232` `applyOAuthLimits`.

## 3a. Как Swift вызывает бэкенд и что происходит при запуске

- `Sources/Model/BackendCommand.swift:4-38` — `enum BackendCommand`: `mcpRefresh(provider:)` → `["refresh"]` / `["codex-mcp","refresh"]`; `limits(provider:)` → `["limits"]` / `["codex-limits"]`; `codexHooks` → `["codex-hooks"]`; `codexHooksApprove` → `["codex-hooks","approve"]`; `toggleServer(provider:name:on:)`; `toggleTool(provider:server:tool:prefix:on:)`. Кейса для `statusline` нет. Золотые слова команд закреплены в `tests/model/main.swift:2793-2808` (`backendGolden`, проверка циклом на `:2808`).
- `Sources/Backend.swift`:
  - `runBackend(_:then:)` `:13-43` — на `backendQueue` (последовательная), `mcpBusy`, после запуска перечитывает `mcp`/`codexMCP`.
  - `runQuietCommand(_:then:)` `:139-146` — `DispatchQueue.global(qos: .utility)`, без `mcpBusy`.
  - `spawnBackend(_:)` `:155-176`: `executableURL = backend.python`, `arguments = [backend.script] + command.arguments`, `standardOutput = FileHandle.nullDevice` (`:161`), stderr в `Pipe` (`:162-163`), `NSLog("ClaudeControlBar: mcpbar.py <args> exited <код>: <stderr, последние 2000 байт>")` только при `terminationStatus != 0` (`:168-172`), `NSLog("ClaudeControlBar: \(backend.python) failed: \(error)")` при ошибке запуска (`:173-175`).
  - `pollLimits()` `:85-98`: Claude — если `oauthLimits` и `now - lastLimitsPoll >= 60`, вызов `pollClaudeLimits(now:)`; Codex — если `codexLimits` и `codexHasRun`, `runQuietCommand(.limits(provider: "codex"))`.
  - `pollClaudeLimits(now:)` `:130-134`: `lastLimitsPoll = now`, `limitsTimer?.fireDate = now+300`, `runQuietCommand(.limits(provider: "claude"))`.
  - `pollLimitsIfRolledOver(now:)` `:120-126`, вызывается из `tick()` (`StatePolling.swift:92`).
  - `refreshMCP()` `:48-73` — коалесцирует запуски; Codex и хуки Codex через `runQuietCommand`, Claude через `runBackend(.mcpRefresh(provider: "claude"))`.
  - `openConfig(of:)` `:240-243` — `NSWorkspace.shared.open(URL(fileURLWithPath: ...))`.
- `Sources/main.swift`:
  - `lazy var backend: (python: String, script: String)` `:48-57`: если есть `~/.claude/control-bar/paths.json` и файл `script` существует — берёт `python`/`script` оттуда (канал плагина); иначе `Bundle.main.path(forResource: "mcpbar", ofType: "py", inDirectory: "scripts")` с `/usr/bin/python3`. При пустом `script` `runBackend`/`runQuietCommand` ничего не запускают (в `runBackend` — `NSLog "no mcpbar.py"`).
  - Точка входа: `main.swift:487-490` (`NSApplication.shared`, `.accessory`, `let controller = StatusController()`, `app.run()`); `applicationDidFinishLaunching` не используется, весь запуск выполняет `StatusController.override init()` `:284-…`: чтение `UserDefaults` (`oauthLimits` `:290`, `codexLimits` `:291`, `limitsLayout` `:294`, `limitsProvider` `:295`), таймер тика 0.4 с (`:313-315`), `observeDesktopApp()` `:316`, таймер `refreshMCP` раз в 600 с (`:319-321`, `mcpRefreshInterval` объявлен на `:41`), `refreshMCP()` `:322`, `limitsTimer` 300 с (`:328-330`), `pollLimits()` `:331`, `refreshNotificationAuthStatus()` `:332`, `tick()`, затем (`:424-428`) `enforceSingleInstance()`, `retirePredecessors()`, `checkHooks()`, `checkForUpdate()`, `announceVersionChange()`.
  - Поля состояния лимитов: `var limits: Limits?` `:18`, `var codexWindows: LimitsSet?` `:22`, `limitsMTime` `:122`, `lastLimitsPoll` `:123`, `limitsTimer` `:124`, `rolledOverHandled` `:125`, `codexLimitsMTime` `:126`, `oauthLimits = true` `:210`, `codexLimits = true` `:211`, `codexInstalled` `:137`, `codexHasRun` `:140`. Расширение не может хранить поля: новые поля контроллера объявляются в `main.swift`.
  - `PanelWindow.swift:61` — `openPanel()` каждый раз зовёт `pollLimits()`.
- `Sources/HookSetup.swift`: `checkHooks(thenApproveCodex:)` `:28-68`. Условие `guard isInstalledCopy, !hookCheckRunning` (`:31`). `isInstalledCopy` (`AppLifecycle.swift:25-31`): путь бандла (с разрешёнными симлинками) начинается с `/Applications/` или `~/Applications/`. Установщик — `Bundle.main.path(forResource: "install", ofType: "js")`; запуск `Self.installHooks(installer:)` `:84-102` на фоне (`DispatchQueue.global(qos: .utility)`): подбор `node` (`HookInstall.nodeCandidates`, затем `shellNode()`), запуск `HookInstall.run(node, [installer], timeout: 60)`, вердикт `HookInstall.health(...)`; результат пишется в `hookHealth`; при проблеме — `scheduleHookRetry()` (`:73-80`, `HookInstall.retryDelay(afterFailures:)`). `checkHooks()` вызывается при запуске (`main.swift:426`), при открытии панели с проблемой/пустой вкладкой (`PanelWindow.swift:66-69`), кнопками панели/Settings. Вывод `install.js` попадает только в строку-след для `NSLog`.
- `hooks/install.js` (300 строк): при каждом запуске копирует `update.js` и `lifecycle.js` в `~/.claude/control-bar/` через temp+rename (`:41-46`); ставит хуки Codex (`:111-150`, `installCodexHooks()`, только если есть `~/.codex`, вызывается для обоих каналов); если плагин владеет хуками (`owner.json` с `channel:"plugin"` и существующим `pluginRoot`, `:27-28`) — печатает "Plugin channel owns the hooks" и выходит 0 (`:152-155`); удаляет артефакты старых версий (`:157-166`); бэкап `settings.json.bak-control-bar` один раз (`:225-238`); пишет хуки в `settings.json` через `writeSettingsAtomic` (`:196-209`) только если текст отличается (`:268-287`); `process.exitCode = 75`, если запись не удалась (`:286`); `process.exit(1)` на неразбираемом `settings.json` (`:223`). Поля `statusLine` `install.js` не читает и не пишет (слова `statusLine` в файле нет).
- Поле `statusLine` в `settings.json` читают и пишут только функции `mcpbar.py` (`statusline_state`, `statusline_install`, `statusline_uninstall`), и только по команде `statusline`. При запуске приложения (`init`, `checkHooks`, `refreshMCP`, `pollLimits`) эту команду никто не вызывает; сравнения пути обёртки с существующим файлом при запуске нет.

## 4. Лимиты Claude

Python (`scripts/mcpbar.py`):
- `LIMITS = ROOT/limits.json` (`:41`); константы `USAGE_URL = https://api.anthropic.com/api/oauth/usage` (`:1344`), `KEYCHAIN_SERVICE = "Claude Code-credentials"` (`:1345`), `CREDENTIALS_FILE = ~/.claude/.credentials.json` (`:1346`).
- `oauth_token()` (`:1349-1377`): `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` (таймаут 30; любое исключение игнорируется) → если пусто, чтение `CREDENTIALS_FILE` (нет файла → `None`) → `json.loads(raw)["claudeAiOauth"]` (`ValueError` → `None`) → `expiresAt` в миллисекундах: просрочен → `None` → иначе `accessToken or None`. Все причины отказа неразличимы: возвращается `None`.
- `parse_reset(value)` `:1380`; `usage_record(payload, now=None)` `:1394-1435` → `{"ts": int, "source": "oauth", <окно>: {"used_percentage": int, "resets_at": epoch|None}, ...}`; не-словарь на входе или нет окон → `None`; ключи `ts` и `source` в ответе пропускаются; окно Fable берётся из `payload["limits"]` через `scoped_model_window(limits, "fable")` (`:1438-1454`) под ключом `seven_day_fable`.
- `fetch_limits()` (`:1457-1501`): нет токена → `return t("lim.notoken")` (`:1462`); запрос без редиректов (`NoRedirect`), таймаут 15; любое `Exception` при запросе/разборе → `return t("lim.failed", e=type(exc).__name__)` (`:1487`; в тексте только имя класса исключения, например `HTTPError`); `usage_record` вернул `None` → `return t("lim.empty")` (`:1489`); успех → `write_json(LIMITS, record)` и `t("lim.updated", w=...)`. При любом отказе `limits.json` не меняется. Функция возвращает строку, `main` печатает её (`:2009-2010`) и завершается кодом 0.
- Строки: `lim.notoken` `:161-162` ("no token: Claude Code is not logged in via browser OAuth"), `lim.failed` `:163`, `lim.empty` `:164`, `lim.updated` `:165`; `limits.age` `:119` (используется в `report()` `:1936-1937`: возраст берётся из корневого `ts`).
- `report()` читает `read_json(LIMITS, {})` (`:1828`, вывод блока лимитов `:1925-1938`).
- Запись `limits.json` от `statusline.py` (`hooks/statusline.py:79-119`, `capture_limits`): `{"ts": int(time.time()), "source": "statusline", "five_hour": {"used_percentage": int, "resets_at": epoch|None}, "seven_day": {...}, ...}`; блок `rate_limits` пустой/не словарь → ничего не пишет; запись пропускается, если все окна совпали и корневой `ts` младше 60 с (`:115-118`). Остальные шаги `statusline.py`: `learn_window` (`model-windows.json`), `capture_context` (`context.d/<session>.json`); сбой шага пишется в `problems.log` через `log_problem` (`:212-220`, `capture` `:223-231`).
- Тест паритета двух писателей: `tests/test_statusline.py:343-394` (`LimitsWriters`, сравнивает тело записи без `ts` и `source`; второй тест копирует файл в `build/seam/limits.json`).

Swift:
- `StatePolling.swift:7-32` `loadLimits()`: путь `<root>/limits.json`; mtime-гейт `limitsMTime` (`:13-15`); нет файла или не парсится → `return` без изменения `limits` и `limitsMTime` (`:16-18`); при `!oauthLimits` и `source == "oauth"` → `limits = nil` (`:25-28`); иначе `limits = Limits(json: root)`.
- `Sources/Model/Limits.swift`: `LimitWindow` `:5-26` (`used: Int`, `resets: Double?`; `init?(json:)` читает `used_percentage` как `Int` и `resets_at` как `Double`); `Limits` `:31-63` (`fiveHour`, `sevenDay`, `fable`, `source: String`, `ts: Double`; `init?(json:)` читает `five_hour`, `seven_day`, ключ по `Limits.fableKey(in:)`; возвращает `nil`, если окон нет); `NamedWindow` `:69-139` (`key`, `title`, `badge`, `minutes`, `ts: Double?` — момент замера окна, `window`; `ended(at:ts:)` `:123-127` берёт `self.ts ?? ts`; `emptied` `:135`); `LimitsSet` `:144-228` (`provider`, `windows`, `source`, `ts`, `plan`; `isSnapshot` = `source == "rollout"` `:160`; `drawable(at:)` `:171-183`; `rolledOver(since:at:)` `:193-197`; `worst` `:201`; `title(minutes:kind:)` `:211`); `NamedWindow.init?(codex:legacyReserve:)` `:243-259` (`ts` из `object["ts"]` на `:257`); `LimitsSet.init?(codex:)` `:265-275` (корневой `ts` из `root["ts"]`, `:273`); `Limits.set` `:282-295` собирает `LimitsSet(provider:"claude", windows:…, source:, ts:, plan:nil)`; окна Claude создаются без `ts` (поле `ts` по умолчанию `nil`).
- `Sources/Model/LimitsBoard.swift`: `LimitsBoard(claude:, codex:)`; `shown(at:)` `:12-18` (провайдеры с хотя бы одним рисуемым окном, Claude первым); `gauge(at:)` `:28-40` (пара Claude `five_hour`/`seven_day`, иначе до двух окон Codex с метками); `codexBarWindows(at:)` `:43-47`; `showing(_:among:)` `:52-54`.
- `StatePolling.swift:103-105` `limitsBoard` = `agentDisplay.limits(claude: limits?.set, codex: codexWindows, forBar: false)` (`AgentDisplay.limits` `Sources/Model/AgentDisplay.swift:57`).
- `PanelData.swift:97-134` `panelLimitGroups(now:) -> ([PanelLimitGroup], String)`:
  - нет провайдеров для показа → пустой список и строка `"No data yet — is Claude Code signed in?"` при `oauthLimits`, иначе `"Limits are switched off in Settings"` (`:106-107`); других причин пустоты код не различает;
  - для каждого провайдера `age: Self.age(of: entry.set.ts, now: now)` (`:128`) — корневой `ts` набора;
  - вторым элементом возвращает `Self.age(of: sources.map { $0.set.ts }.min() ?? 0, now: now)` (`:133`) — минимум корневых `ts` по провайдерам.
- `PanelData.swift:139-148` `static func age(of ts: Double, now: Double) -> String`: минуты = `(now - ts).clampedInt / 60`; `< 1` → `"just now"`; `< 60` → `"N min ago"`; иначе `"Nh ago"` (до 24 ч) или `"Nd ago"`. Тестов на эту функцию в `tests/model/main.swift` нет (`PanelData.swift` вне модели). `until(_:)` `:152-159`.
- `PanelStore.swift`: `PanelLimitGroup` `:208-234` (`provider`, `title`, `glyph`, `limits: [PanelLimit]`, `resets: String?`, `age: String`, `plan: String?`, `worst: PanelLimit?`; `tip` `:231-233` = `[title, plan, "measured " + age]` через " · "); `PanelSnapshot` `:236-281` (`limitGroups` `:266`, `limitsNote` `:268`, `hooks: PanelHooks?`); `PanelLimit` `:347-359`; сборка снимка `PanelSnapshot.init(_:mcp:update:)` `:439-468` (`(limitGroups, limitsNote) = c.panelLimitGroups(now: now)` на `:458`). `PanelHooks` `:326-333` (`title`, `reason`, `hint`, `checking`) и `StatusController.panelHooks()` (`PanelData.swift:83-87`) — существующий образец "проблемного блока" в снимке.
- `PanelView.swift`: `limitsStrip` `:73-109` — при пустом `limitGroups` рисует `Text(store.snapshot.limitsNote)` (серый текст в скруглённой подложке, `:75-85`); иначе `limitRow(_:named:)` `:111-121` (`.help(group.tip)` `:120`), `limitHeader(_:)` `:126-146`, `providerSwitcher(_:)` `:148-…` (`.accessibilityLabel(group.tip + …)` `:187`, `.help(group.tip)` `:188`); `footer` `:265-288` — первый `Text` на `:267`: `store.snapshot.limitGroups.isEmpty ? "" : "Limits · " + store.snapshot.limitsNote`, затем кнопки Settings и Quit. Эта строка и есть подпись вида "Limits · 28d ago". `PanelLimitTile` `:301-340`.
- `PanelTabs.swift:97-117` `hooksBlock(_:)` — образец блока с `PanelNotice`, поясняющим текстом и кнопкой (`Button(hooks.checking ? "Checking…" : "Try again") { store.checkHooks() }`, `.buttonStyle(PanelButtonStyle())`); вызывается на `:16`. `PanelNotice` — `PanelTheme.swift:114`, `PanelButtonStyle` — `PanelTheme.swift:223`.
- `PanelWindow.swift:216-228` `describePanel()` печатает `Limits — <limitsNote>` и строки групп с `group.tip` (используется `CONTROL_BAR_DUMP_MENU=1`).
- Меню-бар: `IconRender.swift:7-12` `renderMenuBar(now:)` берёт `MenuBarAgent.shown(agentDisplay, board:, claude: limits?.set, codex: codexWindows, now:)`; при пустом списке — запасной `MenuBarAgent(provider: .claude, ..., gauge: Gauge())`. `Sources/Model/MenuBar.swift:29-42` `MenuBarAgent.shown` строит `LimitsBoard` на провайдера и кладёт `gauge: limits.gauge(at: now)` (`:39`). `Gauge` (`Sources/Model/Gauge.swift:11-30`) хранит `fiveHour`, `sevenDay`, `labels`, `signature`, `rows`, `isEmpty`. Подпись в `IconRender.swift:46` включает `agent.gauge.signature`; доступное описание — `:97-100` (`", limits: "` + проценты). В иконку из лимитов попадают только числа `Gauge`; сведений о возрасте или ошибке в `MenuBarAgent`/`Gauge` нет.

## 5. Codex

- `scripts/mcpbar_codex.py`: пути `CODEX` `:28`, `CODEX_ROLLOUTS` `:31`, `CODEX_ROOT = core.ROOT/codex` `:32`, `CODEX_LIMITS` `:33`.
- `CODEX_WINDOW_KINDS = ("primary","secondary")` `:126`; `CODEX_WINDOW_ORDER = {kind: index}` `:127`.
- `codex_window(block, kind, base)` `:68-96` → `{kind, used_percentage (0..100), window_minutes?, resets_at}`.
- `codex_pool(model)` `:99-123`: `"reserve"`, если модель начинается с `gpt-reserve`, иначе `"codex"`.
- `codex_limits_record(snapshot, ts=None, now=None, model=None)` `:130-164`: `stamp = ts или now или time.time()`; каждое окно получает `window["pool"]` и `window["ts"] = stamp`; запись `{"ts": stamp, "source": "rollout", "windows": [...], "plan"?}`.
- `codex_known_windows(record)` `:167-191`: нормализует окна старого файла (пул из `record["reserve"]`, `ts` из `record["ts"]`).
- `merge_codex_limits(previous, fresh)` `:194-239`: окна группируются по пулу; свежий снимок заменяет все окна своего пула; итог сортируется по `(пул != "codex", CODEX_WINDOW_ORDER[kind], kind)`; корневой `ts` — `min(stamps)` по `ts` всех окон, включая окна резервного пула (`:231-234`); `plan` берётся из прежней записи, если в свежей нет.
- `codex_file_snapshots(path)` `:259-308`, `codex_snapshots(known_pools)` `:314-340` (`CODEX_ROLLOUT_LOOKBACK = 12` `:311`), `fetch_codex_limits()` `:343-365`: нет `~/.codex` → `t("codex.absent")`; нет снимков → `t("codex.empty")` или `t("codex.nosnapshot")`; возвращают строки, код выхода 0. Запись `write_json(CODEX_LIMITS, record)` с `secure_codex_root()`.
- Swift читает `windows[i]["ts"]` как `NamedWindow.ts` (`Limits.swift:257`) и `ts` корня как `LimitsSet.ts` (`:273`); `PanelData.age` использует только `LimitsSet.ts`.
- Тесты (`tests/test_mcpbar.py`, класс `CodexLimits` `:1867-2310`; помощники `rollout(...)` `:1890`, `token_count(...)` `:1899`, в части тестов — `self.window(...)`): `test_окна_снимка_становятся_фактами` `:1909`, `test_процент_целый_как_у_claude` `:1925`, `test_на_free_плане_второго_окна_нет` `:1931`, `test_остаток_секунд_отсчитывается_от_снимка` `:1936`, `test_битое_окно_не_уносит_соседнее` `:1943`, `test_берётся_последняя_запись_файла` `:1955`, `test_резервная_модель_помечает_запись` `:1969`, `test_резерв_доезжает_до_файла` `:2045`, `test_резервный_снимок_не_затирает_обычные_окна` `:2080`, `test_обычный_снимок_возвращает_свои_окна_на_место` `:2094`, `test_смена_подписки_не_оставляет_старое_недельное_окно` `:2108`, `test_старый_снимок_не_возвращает_удалённое_окно` `:2127`, `test_возраст_записи_это_самый_старый_замер` `:2141` (утверждает `merge_codex_limits(...)["ts"] == 1_789_000_000`, то есть корневой `ts` = минимум), `test_файл_прошлой_версии_переезжает_без_потери` `:2151`, `test_битый_предыдущий_файл_не_мешает_свежему_снимку` `:2165`, `test_обычные_окна_ищутся_в_прошлых_сессиях` `:2171`, `test_память_доезжает_до_файла` `:2279`. Швы для Swift пишутся в `build/seam/codex-limits.json` (`:2041-2043`), `codex-limits-reserve.json` (`:2059`), `codex-limits-pools.json` (`:2306`).
- Swift-проверки по Codex-лимитам: `tests/model/main.swift:1596-1690` (`codexJSON`, `reserveSet`, `bothPools`, `legacyReserve`, `undated`), швы `:1760-1823`.

## 6. Уведомления и внешние действия

- Уведомления: `Notifications.swift` — `notifyMCPChange()` `:9-18`, `notify(title:body:)` `:32-65` (UserNotifications; без `bundleIdentifier` выходит `:37`; первый вызов запрашивает разрешение; `notificationsDenied`), `refreshNotificationAuthStatus()` `:69-76`. `notify` вызывается из `notifyMCPChange` и из `announceVersionChange()` (`Updates.swift:145`). Уведомлений про лимиты и вход в Claude нет.
- Панель при отказе в уведомлениях: `PanelView.swift:253` (`notificationsWarning`, вызов на `:52`), `Actions.swift:25-34` `openNotificationSettings()`.
- `Actions.swift`: `openFilesPrivacySettings` `:13`, `openNotificationSettings` `:25`, `quit` `:37`, `openClaude` `:48` (`NSWorkspace.shared.openApplication(at:)` по bundle id `com.anthropic.claudefordesktop`), `openSession` `:61`, `focusTerminalTab(termProgram:tty:)` `:155-206` (`NSAppleScript(source:)`, `tell application "Terminal"` / `"iTerm"` с поиском вкладки по `tty`, ошибка `-1743` → `.denied`; вызывается только при включённом `exactTerminalFocus`, `Actions.swift:98`), `resetAutomationGrant()` `:214` (`/usr/bin/tccutil reset AppleEvents <bundle id>`), `private func openTool(_ arguments:)` `:225` (`Process` с `/usr/bin/open`; приватный).
- Других вызовов Terminal, `osascript`, `.command`-файлов в `Sources/` нет (поиск `osascript`, `NSAppleScript`, `Terminal`, `.command`). В `Info.plist` текст `NSAppleEventsUsageDescription` (`build.sh:66`) говорит, что Apple Events используются только для фокуса терминала при включённом "Exact terminal focus"; `app.entitlements` объясняет то же.
- В Swift нет поиска бинаря `claude`. В Python он есть: `find_claude()` `mcpbar.py:380-390` (кандидаты `~/.local/bin/claude`, `/usr/local/bin/claude`, `/opt/homebrew/bin/claude`, затем `shutil.which`). Строки `claude auth login` и `setup-token` в репозитории не встречаются вне `.autopilot/`. Текст "Claude Code is not logged in via browser OAuth" — `mcpbar.py:161`.
- `NSWorkspace.shared.open(...)` встречается: `Actions.swift:16,28,31,80`, `Updates.swift:113,161`, `HookSetup.swift:155`, `Backend.swift:241`.
- Журнал: `StatusController.logProblem(_:)` `Updates.swift:411-422` пишет в `NSLog("ClaudeControlBar: …")` и дописывает `~/.claude/control-bar/problems.log` (0600). Префикс `NSLog` во всём коде — `ClaudeControlBar:`.
- Настройки: ключи `UserDefaults` — `oauthLimits`, `codexLimits`, `codexServers`, `limitsLayout`, `limitsProvider`, `exactTerminalFocus`, `agentDisplay`, `lastRunVersion`. Settings-окно: `SettingsView.swift` (секция "Limits" `:185-192`, подпись `limitsFooter` `:101-103`), применение — `SettingsStore.swift`.

## 7. Тесты и команды

Команды (`CLAUDE.md`, `ci.yml`): Python — `/usr/bin/python3 -m unittest discover -s tests -v`; Node — `node --test tests/*.test.js`; Swift — `swiftc -O Sources/Model/*.swift tests/model/main.swift -o <exe> -framework Cocoa && <exe>` из корня репозитория. Порядок в CI: сначала Python, затем Node (пишут `build/seam/*.json`), потом Swift (читает их по `FileManager.default.currentDirectoryPath + "/build/seam/<имя>.json"`; нет файла — `check(false, …)`). В этой рабочей копии каталога `build/` нет. Типы-проверки Swift 6.0: `swiftc -typecheck -target arm64-apple-macos13.0 Sources/*.swift Sources/Model/*.swift -framework Cocoa -framework SwiftUI` (задача `swift-6-0`). Установлены: `/usr/bin/swiftc`, node v26.7.0, `/usr/bin/python3` 3.9.6.
- `tests/test_mcpbar.py` (2719 строк): `sys.path` добавляет `scripts`; `import mcpbar`, `import mcpbar_codex`; `home(name)` (`:28`) возвращает модуль, где живёт имя (подмена путей идёт на нужном модуле). Образец подмены для statusLine — класс `StatusLineObject` (`:542`): `setUp` создаёт временный `HOME`, пишет `settings.json` с `{"statusLine": ORIGINAL}`, ставит через `setattr(home(k), k, v)` значения `SETTINGS`, `ROOT`, `STATUSLINE_INNER`, `STATUSLINE_SAVED`, `STATUSLINE_INSTALLED`, `tearDown` возвращает; обёртка ищется рядом с настоящим скриптом из репозитория. Тесты класса: `test_установка_сохраняет_дополнительные_поля_живыми`, `test_откат_возвращает_объект_целиком`, `test_откат_без_исходного_statusline_убирает_ключ`, `test_битый_settings_не_затирается_установкой`, `test_чужая_строка_состояния_не_считается_нашей`, `test_команда_кладётся_с_правами_владельца`, `test_ручная_замена_после_установки_не_считается_нашей`, `test_живой_чужой_statusline_после_нашей_установки_не_наш`, `test_нераскрытая_переменная_в_чужой_команде_не_наша`, `test_обёртка_прошлой_версии_с_мёртвым_путём_остаётся_нашей` (`:678`; пишет `STATUSLINE_SAVED`, `STATUSLINE_INNER` без `STATUSLINE_INSTALLED`, ждёт `statusline_state()[1] == True`), `test_интеграция_чужой_statusline_установка_исполнение_замена_откат`, `test_неудачная_запись_настроек_не_оставляет_сайдкаров`. Рядом: `SettingsShapeDrift.test_statusline_строкой_не_роняет_проверку` (`:1709`).
- Тесты `fetch_limits`: `UsageEndpoint` (`:1215`, чистые функции), `UsageToken` (`:1276`; два локальных HTTP-сервера; подмена `USAGE_URL`, `LIMITS`, `oauth_token = lambda: "SECRET"`; `test_редирект_считается_сбоем_а_не_данными` сравнивает результат с `mcpbar.t("lim.failed", e="HTTPError")`), `UsagePayloadDrift` (`:1472`; `test_fetch_limits_переживает_массив_от_эндпоинта` подменяет `USAGE_URL` на `data:`-URL).
- `tests/test_statusline.py` (394 строки): `HOOKS` и `SCRIPTS` добавляются в `sys.path`; `Capture` ставит `os.environ["CONTROL_BAR_ROOT"]` во временный каталог и `importlib.reload(statusline)` (`ROOT` считается на импорте); `Wrapper` (`:286`) запускает `bash hooks/statusline.sh` с `CONTROL_BAR_ROOT`; `LimitsWriters` (`:343`).
- `tests/install.test.js`, `tests/uninstall.test.js`, `tests/lifecycle.test.js`, `tests/update-hook.test.js` — через `node:test`; `install.test.js` запускает скрипт дочерним `node -e` с подменой `HOME`, `execSync` и `process.execPath` (`runScript` `:14-30`); `hook-harness.js` даёт `sandbox(t)`, `run(script, home, {argv, stdin, env})`, заглушки `execSync/execFileSync/spawn` с журналами в `exec-log.txt`, `execfile-log.txt`, `spawn-calls.txt`. `tests/uninstall.test.js:85-123` проверяет вызов `statusline --uninstall`.
- `tests/model/main.swift` (2939 строк): один исполняемый файл с верхнеуровневым кодом; `var failures`, `func check(_ passed: Bool, _ what: String)` (`:11-15`); блоки `// MARK:` и `do { … }`; в конце `print(failures == 0 ? … )` и `exit(…)`. Объявлять до использования. Новая проверка — вызов `check(условие, "описание")` в нужном месте. Лимиты: `:1488-1560` (`Limits`, `fableKey`), `:1559-1751` (`LimitsSet`, `drawable`, `rolledOver`, `worst`, `title`), блоки `do { … }` на `:2529`, `:2612`, `:2647` (`LimitsBoard`, иконка, `Gauge`), `:696-720` (шов `limits.json`), `:2793-2809` (`BackendCommand`).

## 8. Версия и релиз

- Версия — `"version": "0.24.5"` в `.claude-plugin/plugin.json` (поле `version`) и в `.claude-plugin/marketplace.json` (`plugins[0].version`). В Info.plist версия не хранится в репозитории: `build.sh:13` читает её из `plugin.json`, подставляет в `CFBundleVersion` и `CFBundleShortVersionString` (`:60-61`).
- Гвард CI (шаг "One version everywhere", после сборки): `plugin.json` == все `plugins[].version` в `marketplace.json` == `CFBundleShortVersionString` == `CFBundleVersion` собранного бандла; дополнительно шаг "Manifests are valid JSON".
- `tools/release/bump.js <patch|minor|major> [--date YYYY-MM-DD] [--root dir]`: считает следующую версию, правит текстом обе манифест-версии, переименовывает секцию `## [Unreleased]` в `## [x.y.z] - <дата>`, печатает версию; без секции `## [Unreleased]` или с пустой секцией завершается кодом 1 и файлы не трогает (`bump.js` проверки, тесты `tests/release-bump.test.js`).
- В `CHANGELOG.md` сейчас нет секции `## [Unreleased]`: первая запись `## [0.24.5] - 2026-10-08`. Формат записи: `## [x.y.z] - YYYY-MM-DD`, подзаголовки `### Added|Changed|Fixed`, пункты `- **Жирная лидирующая фраза.** Продолжение…` с переносом строк около 100 символов, на английском. Пример (верх файла):
  ```
  ## [0.24.5] - 2026-10-08

  ### Changed
  - **A shared app icon for Claude and Codex.** Clawd and the Codex companion appear inside two
    session cards in one control panel. The dark navy palette uses mint and coral state indicators.

  ### Fixed
  - **The app icon has no extra white background on macOS 26.** Its large image uses an opaque
    background for system masking; smaller images keep the rounded artwork.
  ```
- Коммит релиза 0.24.5 (`899ad11 chore(release): 0.24.5`) менял три файла: оба манифеста и `CHANGELOG.md` (добавил секцию версии). Релизный процесс по `CONTRIBUTING.md` ("Releasing"): пользовательское изменение добавляет строку под `## [Unreleased]`; релиз готовит workflow "Release bump" (`release-bump.yml`): запускает `tools/release/bump.js`, пушит ветку `release/<version>`, открывает PR `release: x.y.z`; мерж PR меняет версию в `plugin.json` на `main`, и `release.yml` (триггер: push в `main` с изменением `.claude-plugin/plugin.json`) создаёт тег `v<version>`, собирает DMG и публикует релиз; заметки релиза — секция версии из `CHANGELOG.md` (граница от `## [x.y.z] - date` до следующего `## [`, как в `Sources/Model/Changelog.swift:section(for:in:)`). `CHANGELOG.md` копируется в `.app` (`build.sh:80`) и показывается в окне "What's new".
- Конвенции коммитов: Conventional Commits (`feat`, `fix`, `chore`, `refactor`, `docs`, `perf`), в теле — причина (`CONTRIBUTING.md`). Сообщения последних коммитов: `feat: add shared session dashboard app icon`, `chore(release): 0.24.5`.
- Документы, где описаны лимиты и перехват (для справки при правке поведения): `README.md:107`, `README.md:201`, `README.ru.md`, `PRIVACY.md` (разделы про опрос раз в 5 минут, `statusLine` payload, файлы `statusline-*`, `limits.json`), `CONTRIBUTING.md:17-24` (правило: поведение, меняющее файлы пользователя, описывается в PRIVACY.md и README в том же PR), `TROUBLESHOOTING.md`, `docs/decision-log.md`.

## 9. Факты о сбоях и тихих выходах

- `mcpbar.py limits`: три отказа (`lim.notoken`, `lim.failed`, `lim.empty`) возвращают строку из `fetch_limits()`, `main` печатает её в stdout и возвращает 0 (`mcpbar.py:2009-2010`, `:2099`). `Backend.swift:161` отправляет stdout в `/dev/null`; ненулевого кода нет, поэтому `NSLog` на `Backend.swift:168-172` не срабатывает. Приложение не получает от скрипта признака отказа ни кодом, ни файлом.
- `limits.json` при отказе не меняется. Его поля: `ts`, `source`, окна. Поля со статусом ошибки в файле нет.
- `loadLimits()` (`StatePolling.swift:16-18`): удалённый или нечитаемый `limits.json` оставляет прежний `limits`. Для `codex/limits.json` отсутствие файла даёт `codexWindows = nil` (`loadCodexLimits`, `:50`).
- Если `limits.json` есть, а новый опрос не удаётся, `PanelData` продолжает показывать окна из файла; возраст в футере берётся из его `ts`. Окно с `resets_at` в прошлом рисуется нулевым (`LimitsSet.drawable`).
- `oauth_token()` не различает: Keychain пуст, нет `.credentials.json`, битый JSON, просроченный `expiresAt`, нет `accessToken`.
- `fetch_limits()` не различает HTTP 401 и сетевой сбой: строка `poll failed: <ИмяИсключения>`.
- `fetch_codex_limits()`: `codex.absent`, `codex.empty`, `codex.nosnapshot` — тоже строка и код 0.
- Эмпирические значения подписи: `age(of:)` берёт `(now - ts) / 60`; для провайдера `codex` корневой `ts` = минимум `ts` окон (`mcpbar_codex.py:231-234`), включая окна резервного пула, которые перезаписываются только когда приходит снимок этого пула; общая подпись в футере — минимум корневых `ts` по всем провайдерам (`PanelData.swift:133`).
- Обёртка статусной строки: если команда в `settings.json` указывает на несуществующий `statusline.sh`, `bash "<путь>"` завершается ошибкой "No such file", `statusline.py` не запускается, `limits.json` от statusLine не обновляется. `statusline_install` в таком состоянии отвечает `already installed`, если команда записана в `statusline-installed.json` (`statusline_ours`, пункт 2); если записи нет, а сайдкары есть — тоже считает команду своей (пункт 5).
- `statusline.sh` молчит и выходит 0 при пустой внутренней команде (`:47`), при защитной переменной окружения (`:21`), а `statusline.py` запускается в фоне с закрытыми stdout/stderr; сбои шагов `statusline.py` идут в `problems.log`.
- `hooks/statusline.py` `main()` возвращает 0 при нечитаемом stdin и не-словаре (`:236-241`).
- `grep TODO|FIXME|XXX|HACK` по `Sources`, `scripts`, `hooks`, `tests` не находит комментариев-пометок про лимиты или statusLine (совпадения только в base64-строках `CrabFrames.swift`).
- Рабочая копия: `.gitignore` изменён (`.autopilot/serve.*`), `.autopilot/` не отслеживается git.

## Таблица идентификаторов

| Что | Где | Строки |
|---|---|---|
| `statusline_sidecars`, `drop_statusline_sidecars` | `scripts/mcpbar.py` | 1153, 1161 |
| `find_statusline_wrapper` | `scripts/mcpbar.py` | 1169 |
| `statusline_ours`, `statusline_command`, `statusline_state` | `scripts/mcpbar.py` | 1186, 1232, 1239 |
| `statusline_install`, `statusline_uninstall` | `scripts/mcpbar.py` | 1244, 1297 |
| `STATUSLINE_INNER`, `STATUSLINE_SAVED`, `STATUSLINE_INSTALLED` | `scripts/mcpbar.py` | 1142, 1146, 1150 |
| `ROOT`, `SETTINGS`, `LIMITS`, `SECURE_DIR`, `SECURE_FILE` | `scripts/mcpbar.py` | 39, 48, 41, 207 |
| `settings_lock`, `read_settings_for_edit`, `write_settings`, `backup_settings`, `write_json`, `read_json` | `scripts/mcpbar.py` | 1019, 329, 364, 943, 300, 269 |
| диспетчер `main`, ветки `limits`, `codex-limits`, `statusline` | `scripts/mcpbar.py` | 1999, 2009, 2011, 2053 |
| `t`, `STRINGS`, `detect_lang`; ключи `lim.notoken/failed/empty/updated`, `sl.*`, `limits.age` | `scripts/mcpbar.py` | 191, 99, 75; 161-165, 143-160, 119 |
| `oauth_token`, `usage_record`, `fetch_limits`, `parse_reset` | `scripts/mcpbar.py` | 1349, 1394, 1457, 1380 |
| `find_claude` | `scripts/mcpbar.py` | 380 |
| `merge_codex_limits`, `codex_limits_record`, `codex_known_windows`, `fetch_codex_limits`, `CODEX_WINDOW_ORDER` | `scripts/mcpbar_codex.py` | 194, 130, 167, 343, 127 |
| `capture_limits`, `capture`, `log_problem` | `hooks/statusline.py` | 79, 223, 212 |
| обёртка | `hooks/statusline.sh` | 1-50 |
| `write_paths` (`paths.json`) | `hooks/bootstrap.py` | 335 |
| вызов `statusline --uninstall` | `hooks/uninstall.js` | 75-91 |
| `BackendCommand` (кейсы, `arguments`) | `Sources/Model/BackendCommand.swift` | 4-38 |
| `runBackend`, `runQuietCommand`, `spawnBackend`, `pollLimits`, `pollClaudeLimits`, `pollLimitsIfRolledOver`, `refreshMCP`, `refreshCounts` | `Sources/Backend.swift` | 13, 139, 155, 85, 130, 120, 48, 182 |
| `backend` (python/script), `init`, `limitsTimer`, поля лимитов, `oauthLimits`, `codexLimits` | `Sources/main.swift` | 48, 284, 124, 18-22/122-126, 210, 211 |
| `checkHooks`, `installHooks`, `scheduleHookRetry`, `isInstalledCopy` | `Sources/HookSetup.swift`, `Sources/AppLifecycle.swift` | 28, 84, 73; 25 |
| `loadLimits`, `loadCodexLimits`, `tick`, `limitsBoard` | `Sources/StatePolling.swift` | 7, 44, 73, 103 |
| `LimitWindow`, `Limits`, `NamedWindow` (`ts`, `ended`), `LimitsSet` (`ts`, `drawable`, `rolledOver`), `LimitsSet(codex:)` | `Sources/Model/Limits.swift` | 5, 31, 69/83/123, 144/150/171/193, 265 |
| `LimitsBoard` (`shown`, `gauge`, `codexBarWindows`) | `Sources/Model/LimitsBoard.swift` | 5, 12, 28, 43 |
| `MenuBarAgent.shown`, `Gauge` | `Sources/Model/MenuBar.swift`, `Sources/Model/Gauge.swift` | 29; 11 |
| `renderMenuBar` | `Sources/IconRender.swift` | 7 |
| `panelLimitGroups`, `age(of:now:)`, `until`, `panelHooks`, строки "No data yet — is Claude Code signed in?" и "Limits are switched off in Settings" | `Sources/PanelData.swift` | 97, 139, 152, 83, 106-107 |
| `PanelLimitGroup` (`age`, `tip`), `PanelSnapshot` (`limitGroups`, `limitsNote`, `hooks`), `PanelHooks`, `PanelStore` (методы действий), сборка снимка | `Sources/PanelStore.swift` | 208 (219, 231), 236 (266, 268), 326, 130-145, 439-468 |
| `limitsStrip`, `footer` (строка `"Limits · " + limitsNote`), `limitRow`, `limitHeader`, `providerSwitcher` | `Sources/PanelView.swift` | 73, 265 (267), 111, 126, 148 |
| `hooksBlock` (образец блока с кнопкой), `PanelNotice`, `PanelButtonStyle` | `Sources/PanelTabs.swift`, `Sources/PanelTheme.swift` | 97; 114, 223 |
| `describePanel` | `Sources/PanelWindow.swift` | ~205-230 |
| `notify`, `refreshNotificationAuthStatus`, `notificationsDenied` | `Sources/Notifications.swift`, `Sources/main.swift` | 32, 69; поле в `main.swift` |
| `focusTerminalTab`, `openTool` (private), `openClaude`, `openNotificationSettings` | `Sources/Actions.swift` | 155, 225, 48, 25 |
| `logProblem` | `Sources/Updates.swift` | 411 |
| `applyOAuthLimits`, `Toggle("Limits via Anthropic API")`, `limitsFooter` | `Sources/SettingsStore.swift`, `Sources/SettingsView.swift` | 224; 186, 101 |
| ключи JSON `limits.json` | `ts`, `source` (`oauth`/`statusline`), `five_hour`, `seven_day`, `seven_day_fable`, `<окно>.used_percentage`, `<окно>.resets_at` | — |
| ключи JSON `codex/limits.json` | `ts`, `source` (`rollout`), `plan`, `windows[].kind/used_percentage/window_minutes/resets_at/pool/ts` | — |
| файлы состояния | `~/.claude/control-bar/{limits.json,codex/limits.json,paths.json,statusline-saved.json,statusline-inner-command,statusline-installed.json,settings.lock,problems.log}` | — |
| `UserDefaults`-ключи | `oauthLimits`, `codexLimits`, `limitsLayout`, `limitsProvider`, `exactTerminalFocus` | — |
| команды бэкенда | `limits`, `codex-limits`, `statusline [--install|--uninstall]`, `refresh`, `codex-hooks [approve]` | — |
| тесты | `tests/test_mcpbar.py` (`StatusLineObject` 542, `UsageToken` 1276, `UsagePayloadDrift` 1472, `CodexLimits` 1867), `tests/test_statusline.py` (`Wrapper` 286, `LimitsWriters` 343), `tests/model/main.swift` (`backendGolden` 2793, Limits 1488-1751, LimitsBoard 2528-2580), `tests/uninstall.test.js:85-123` | — |
| версия и релиз | `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `CHANGELOG.md` (`## [Unreleased]`), `tools/release/bump.js`, `tests/release-bump.test.js`, `ci.yml` шаг "One version everywhere" | — |
