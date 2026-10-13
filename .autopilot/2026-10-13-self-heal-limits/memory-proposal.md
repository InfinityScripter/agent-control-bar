# Предложение к памяти проекта (сборка self-heal-limits)

`CLAUDE.md` не тронут. Строки ниже готовы к вставке; над каждым блоком сказано, куда.

## В CLAUDE.md
Вместо строки «Swift model-check…» (порядок обязателен: Swift читает `build/seam/*.json`, их пишут Python- и Node-тесты):

- Python-тесты, первыми: `/usr/bin/python3 -m unittest discover -s tests -v`
- Node-тесты: `node --test tests/*.test.js` (один `todo` в `tests/lifecycle.test.js:159` — не падение)
- Swift model-check, последним: `mkdir -p build && swiftc -O Sources/Model/*.swift tests/model/main.swift -o build/model -framework Cocoa && ./build/model`
- Типы всего приложения: `swiftc -typecheck -target arm64-apple-macos13.0 Sources/*.swift Sources/Model/*.swift -framework Cocoa -framework SwiftUI`
- Один Python-тест: `/usr/bin/python3 -m unittest discover -s tests -p test_mcpbar.py -k StatusLineHeal -v`; один Node-файл: `node --test tests/install.test.js`
- `./build.sh` кладёт `build/Agent Control Bar.app`, не в /Applications. Копия из другой папки при запущенной установленной сама завершается («already running, standing down»), поэтому `CONTROL_BAR_DUMP_MENU=1` на машине с работающим приложением не показывает панель.

Новый раздел «Где что лежит»:

- `scripts/mcpbar.py` — бэкенд на системном python (MCP, лимиты Claude, statusLine, вход в Claude Code), комментарии по-русски; `scripts/mcpbar_codex.py` — его модуль для Codex.
- `hooks/` — Node-хуки сессий (`update.js`, `lifecycle.js`, `install.js`, `uninstall.js`); `statusline.py` и `statusline.sh` — перехват лимитов в терминале.
- `Sources/*.swift` — приложение. `StatusController` живёт в `main.swift` и разложен по темам: `Backend.swift`, `StatePolling.swift`, `Actions.swift`, `Notifications.swift`, `HookSetup.swift`.
- `Sources/Model/` — решения без UI; их проверяет `tests/model/main.swift`. `tests/test_mcpbar.py` — Python-тесты бэкенда, по-русски.
- `docs/decision-log.md` — что выбрали, почему и что отвергли; прочитай записи про `statusline --heal` и `limits-status.json`, прежде чем менять эти места.
- `CHANGELOG.md` — запись под `## [Unreleased]`, по-английски: `- **Lead phrase.** Continuation…`. Swift, JS и docs пишутся по-английски, `scripts/*.py` и `tests/test_*.py` — по-русски.

Новый раздел «Где больно»:

- Поведение, меняющее файлы пользователя, описывается в `PRIVACY.md`, `README.md` и `README.ru.md` в том же изменении (эта сборка тронула ещё `TROUBLESHOOTING.md`).
- `@State` в `Sources/` запрещён (CI-проверка grep): пиши `State<Bool>(initialValue: false)`, образец — `Sources/Motion.swift`.
- Python-тесты подменяют пути атрибутами модуля (`mcpbar.ROOT = …`, `setattr(home(k), k, v)`). `LIMITS_STATUS` и `CLAUDE_LOGIN_COMMAND` вычислены при импорте, подмена `ROOT` их не двигает: подменяй каждый в `setUp`, иначе тест пишет в настоящий `~/.claude`.
- Запуск из `build/` не чинит statusLine и не ставит хуки: `isInstalledCopy` (`Sources/AppLifecycle.swift`) верен только для `/Applications` и `~/Applications`.

### Правка без автопилота

Мелкий баг или доводка после сборки делается в обычной сессии, без автопилота. Сначала прочитай `.autopilot/PROGRESS.md`: что не доделано, известные баги, о чём договорились. Что правили после последней сборки: `git log --oneline "$(git log -1 --format=%h --grep='^Autopilot: сборка сдана')"..HEAD -- . ':(exclude).autopilot'` (пока коммита `Autopilot: сборка сдана` нет, команда ничего не печатает). После правки сделай коммит по правилам ниже и допиши строку в «Правки без автопилота» в `PROGRESS.md`.

### История git

- Что правили после последней сборки: команда из «Правка без автопилота».
- Всё, что делали ради требования: `git log --oneline --grep="R02"`.
- История файла: `git log --oneline -10 -- <файл>`.
- Коммит: Conventional Commits с трейлером `--trailer "Requirements: R02"`. Заголовок `Autopilot: сборка сдана` пишет только автопилот.

## В .claude/rules/architecture.md
Правило «Swift не пишет…»: после `limits.json,` вставить `limits-status.json`, `claude-login.command`,.
В список `PanelStore` (`setServer`, `setTool`, `openSession`, …) вставить `signInClaude`.
В список моделей «Решения, которые раньше жили в `StatusController`…» вставить: `LimitsStatus` (чем объяснить пустую полосу лимитов Claude, показывать ли кнопку входа, нужен ли баннер «вышел из аккаунта» — раз за запуск и только по опросу после запуска), `LimitsNote` (возраст цифр и строка футера).
Новое правило после «Единственный разрешённый межпроцессный вызов…»:

- Ещё две команды `mcpbar.py` Swift зовёт через `runQuietCommand` и их ответ не читает: `statusline --heal` (результат — поле `statusLine` в `~/.claude/settings.json`) и `claude-login` (результат — `claude-login.command`, который Python открывает в Terminal через `/usr/bin/open`). Слово «результат — только через `mcp.json`» относится к `refresh`.
- Починка statusLine при запуске: `healStatusLine()` в `Sources/HookSetup.swift` зовётся из `init` сразу после `checkHooks()`, только в установленной копии. Скрипт чинит одно: нашу мёртвую обёртку (`statusline_ours` и ни один путь `statusline.sh` в команде не существует). Живую или чужую строку он не трогает.

Строки в таблицу «Контракты файлов состояния»:

| `limits-status.json` | `fetch_limits()` в `scripts/mcpbar.py` — единственный писатель, пишет при каждом вызове `limits`, и при успехе тоже: `{ts, provider, state, detail}`, `state` — `ok`, `no-login`, `failed` или `empty`. Swift читает его в `loadLimitsStatus()` (`StatePolling.swift`) и молчит, если `limits.json` новее опроса: цифры обновил второй писатель `limits.json`. Образец для Swift — `build/seam/limits-status.json` |
| `claude-login.command` | `claude_login()` в `scripts/mcpbar.py` — единственный писатель, права 0700, внутри `exec <claude> auth login`. Кнопка в панели: `PanelStore.signInClaude()`, команда бэкенда `claude-login` |
| `settings.json` и `statusline-installed.json` | поле `statusLine` и запись установки — `statusline_install`, `statusline_uninstall`, `statusline_heal` в `scripts/mcpbar.py`; `hooks` — `hooks/install.js`; `permissions.deny` — переключатели `mcpbar.py`. Каждый пишет с проверкой отпечатка файла, чужие поля не трогает |

К строке `codex/limits.json` добавить: корневой `ts` — самый свежий замер окон обычного пула (нет их — всех окон); `ts` отдельных окон не меняется.

Устаревшие указатели (неверны ещё до этой сборки): `mcpbar.py:393-395` (два места) заменить на «докстринг `run_health_check` в `scripts/mcpbar.py`», `ci.yml:62-95` — на «шаг `Identity is consistent` в `.github/workflows/ci.yml`».
