# Границы, решённые в спецификации

## Правила проекта (обязательны для каждого исполнителя и ревьюера)
- Слои Node / Python / Swift общаются только через JSON-файлы в `~/.claude/control-bar/`. Swift спавнит `mcpbar.py` через `spawnBackend()` и **не читает его stdout**; все новые команды — через `BackendCommand` + `runQuietCommand`/`runBackend`.
- Swift не пишет файлы состояния (`limits.json`, `limits-status.json`, `codex/*.json`). Писатель `limits-status.json` и `claude-login.command` — только `mcpbar.py`.
- Python: системный `/usr/bin/python3` 3.9, без зависимостей; запись файлов атомарно через `write_json`/`os.open(..., 0o600)` + `os.replace`; каталоги `0o700`.
- Swift: статусы — строки; `Double → Int` только `clampedInt`; **никакого `@State`** в `Sources/` (использовать `State(initialValue:)`); длинный текст во вьюхе — `private static let`; новые методы контроллера — в файл своей темы (`Backend.swift`, `StatePolling.swift`, `Actions.swift`, `Notifications.swift`), хранимые поля — только в `main.swift`.
- Комментарии объясняют «почему», не пересказывают код. Языки: Swift, JS, docs — английский; `scripts/*.py` и `tests/test_*.py` — русский.
- Один тест: `/usr/bin/python3 -m unittest discover -s tests -p test_mcpbar.py -k StatusLineHeal -v`; Node один файл: `node --test tests/install.test.js`.
- Тесты запускать в порядке: Python → Node → Swift-модель (Swift читает `build/seam/*.json`, которые пишут Python-тесты). Команды: `/usr/bin/python3 -m unittest discover -s tests -v`; `node --test tests/*.test.js`; `swiftc -O Sources/Model/*.swift tests/model/main.swift -o build/model -framework Cocoa && ./build/model`; типизация всего приложения: `swiftc -typecheck -target arm64-apple-macos13.0 Sources/*.swift Sources/Model/*.swift -framework Cocoa -framework SwiftUI`.
- Поведение, меняющее файлы пользователя, описывается в `PRIVACY.md` и README в том же изменении (CONTRIBUTING). Запись в `CHANGELOG.md` — под `## [Unreleased]`, формат `- **Лидирующая фраза.** Продолжение…`, английский.
- Никаких коммитов и пушей исполнителем: коммитит оркестратор; пуш — только по слову пользователя.

## Контракты файлов и команд

### `~/.claude/control-bar/limits-status.json` (новый; писатель `fetch_limits()` в `scripts/mcpbar.py`)
```json
{"ts": 1791921000, "provider": "claude", "state": "no-login", "detail": "no token"}
```
- `state` ∈ `ok` | `no-login` | `failed` | `empty`; `detail` — короткая строка для человека (`"no token"`, `"HTTPError"`, `"no windows"`, `""` при `ok`); `ts` — момент опроса (int, секунды).
- Пишется при **каждом** вызове `limits`, в том числе при успехе. При сбое `limits.json` не меняется (как сейчас).

### `~/.claude/control-bar/claude-login.command` (новый; писатель `claude_login()` в `scripts/mcpbar.py`)
- Права 0700. Содержимое: shebang `#!/bin/bash`, если `find_claude()` нашёл бинарь — `exec "<путь>" auth login`; иначе печать `Claude Code CLI not found. Install it, then run: claude auth login` и `read -r -n 1`.
- Открывается `/usr/bin/open <файл>` (Terminal). Команда бэкенда: `claude-login`, печатает `t("login.opened")` или `t("login.missing")`, код выхода 0.

### Команда `statusline --heal` (`statusline_heal()` в `scripts/mcpbar.py`)
- Вход: `settings.json`. Условие починки: `statusline_ours(current)` **и** ни одно слово команды с базовым именем `statusline.sh` не существует на диске (`os.path.exists`).
- Действие: как `statusline_install`, но без перезаписи `STATUSLINE_SAVED`/`STATUSLINE_INNER`: `backup_settings()`, `settings["statusLine"]["command"] = f'bash "{find_statusline_wrapper()}"'` с сохранением прочих полей, `STATUSLINE_INSTALLED = {"command": …}`, `write_settings(expect=seen)`.
- Ответы (ключи `STRINGS`, en/ru): `sl.healed` («statusLine wrapper re-pointed to {path}»), `sl.healthy` («statusLine wrapper is alive»), `sl.off` (не наша или не настроена — без изменений), `sl.busy`, `sl.nowrapper`. Код выхода 0 всегда.
- Диспетчер: ветка `statusline`, флаг `--heal` рядом с `--install`/`--uninstall`.

### `BackendCommand` (`Sources/Model/BackendCommand.swift`)
- `case statuslineHeal` → `["statusline", "--heal"]`
- `case claudeLogin` → `["claude-login"]`
- Оба добавить в `backendGolden` (`tests/model/main.swift`).

### Модель `Sources/Model/LimitsStatus.swift` (новый файл, без UI-импортов)
```swift
struct LimitsStatus: Equatable {
    let state: String      // ok | no-login | failed | empty
    let ts: Double
    let detail: String
    init?(json: [String: Any])   // nil без поля state
}
struct LimitsNotice: Equatable {
    let title: String      // "Claude Code is not signed in"
    let hint: String       // "Limits stopped updating 1d ago. Sign in to resume." / "Poll failed: HTTPError"
    let offerSignIn: Bool  // true только для no-login
}
extension LimitsStatus {
    /// nil при state == ok или oauthLimits == false. figuresTs — ts из limits.json (nil, если файла нет).
    static func notice(_ status: LimitsStatus?, oauthLimits: Bool, figuresTs: Double?, now: Double) -> LimitsNotice?
    /// Текст пустой полосы: без статуса — прежние строки; no-login → "Claude Code is not signed in — sign in to see limits".
    static func emptyStripText(_ status: LimitsStatus?, oauthLimits: Bool) -> String
}
```

### Модель `Sources/Model/LimitsNote.swift` (новый файл)
```swift
enum LimitsNote {
    static func age(of ts: Double, now: Double) -> String        // перенос из PanelData, поведение прежнее
    static func footer(_ groups: [(title: String, age: String)]) -> String
    // один провайдер → "Limits · <age>"; два и больше → "Claude 1d ago · Codex just now"; пусто → ""
}
```
`PanelData.age(of:now:)` становится обёрткой над `LimitsNote.age` или удаляется с заменой вызовов.

### Снимок панели (`Sources/PanelStore.swift`)
- `PanelLimitsNotice: Equatable { title, hint, offerSignIn }` и поле `PanelSnapshot.limitsNotice: PanelLimitsNotice?`; собирается в `PanelSnapshot.init` из `LimitsStatus.notice(...)`.
- `PanelStore.signInClaude()` → `controller.signInClaude()`.
- `StatusController.signInClaude()` в `Actions.swift`: `runQuietCommand(.claudeLogin)`; затем `lastLimitsPoll = 0`, чтобы следующее открытие панели опросило сразу.

### Состояние контроллера (`Sources/main.swift`)
- `var limitsStatus: LimitsStatus?`, `var limitsStatusMTime: Date?`, `var limitsNoticeSent = false`.

### Чтение (`Sources/StatePolling.swift`)
- `loadLimitsStatus()` по образцу `loadLimits()` (mtime-гейт, файл `limits-status.json`); вызывается из `tick()` рядом с `loadLimits()`. После чтения: `no-login` и `!limitsNoticeSent` и `oauthLimits` → `notify(title: "Claude Code is signed out", body: "Limits stopped updating. Open the panel to sign in.")`, флаг = true.

### Codex (`scripts/mcpbar_codex.py`, `merge_codex_limits`)
- Корневой `ts` = `max(ts окон пула "codex")`, при их отсутствии `max(ts всех окон)`. Per-window `ts` без изменений. Тест `test_возраст_записи_это_самый_старый_замер` заменяется на тест нового правила; шов `build/seam/codex-limits-pools.json` перегенерируется тестами.

## Швы для тестов
- Python → Swift: тест в `tests/test_mcpbar.py` пишет `build/seam/limits-status.json` (образец `no-login`); `tests/model/main.swift` читает его и проверяет `LimitsStatus(json:)` и `notice`.
- Python: `StatusLineObject`-подобный класс для `statusline_heal` (временный `HOME`, подмена `SETTINGS`, `ROOT`, сайдкаров через `setattr(home(k), k, v)`); `UsageToken`-подобный для статуса (`oauth_token = lambda: None`, локальный HTTP-сервер для `failed`); для `claude_login` — подмена `subprocess.run` и `find_claude`.
- Swift-модель: `LimitsNote.footer`, `LimitsNote.age`, `LimitsStatus.notice` (ok/no-login/failed, oauth off), `backendGolden`.

## Что построили законченные таски
(заполняется по ходу Phase 5)

### Таск 01 — построено
- `statusline_heal() -> str` в `scripts/mcpbar.py`: ключи `sl.healed{path}` / `sl.healthy` / `sl.off` / `sl.busy` / `sl.nowrapper`, код выхода 0; `statusline-installed.json` пишется после `write_settings` (обрыв между ними оставляет команду «нашей»).
- `statusline_script_words(command) -> list[str]` — общий помощник `statusline_ours` и починки (слова команды с базовым именем `statusline.sh`).
- CLI: `mcpbar.py statusline --heal`.
- `BackendCommand.statuslineHeal.arguments == ["statusline", "--heal"]` (в `backendGolden`).
- `StatusController.healStatusLine()` в `Sources/HookSetup.swift` (guard `isInstalledCopy`, `runQuietCommand`), вызов в `init` сразу после `checkHooks()`.
- После ремонта: `statusline_script_words` возвращает слова с раскрытыми `~` и `$HOME` (`expanduser` + `expandvars`); живая чужая строка по такому пути → `sl.off`.

### Таск 02 — построено
- Python: `LIMITS_STATUS = ROOT/limits-status.json`; `write_limits_status(state, detail="")` → `{"ts", "provider": "claude", "state", "detail"}` (0600, атомарно); `fetch_limits()` пишет его при каждом исходе (`ok` после `limits.json`, `no-login` — "no token", `failed` — имя исключения, `empty` — "no windows"). Шов `build/seam/limits-status.json` (no-login).
- Swift-модель `Sources/Model/LimitsStatus.swift`: `LimitsStatus { state; ts; detail; init?(json:) }`, `LimitsNotice { title; hint; offerSignIn }`, `LimitsStatus.notice(_:oauthLimits:figuresAge: String?) -> LimitsNotice?` (подпись изменена против первоначального контракта: возраст приходит готовой строкой), `LimitsStatus.emptyStripText(_:oauthLimits:) -> String`, `LimitsStatus.pollLine(_:polledAge:figuresAge:) -> String` (строка Settings).
- Контроллер: `limitsStatus`, `limitsStatusMTime`, `limitsNoticeSent` (main.swift); `loadLimitsStatus()` (StatePolling.swift, `StateFileLook.at`), `notifyLimitsSignedOut()` (Notifications.swift), оба из `tick()`.
- Панель: `PanelLimitsNotice { title; hint; offerSignIn }`, `PanelSnapshot.limitsNotice` ← `StatusController.panelLimitsNotice(now:)` (PanelData.swift); `PanelView.limitsNoticeBlock(_:)` над полосой, пока без кнопки — таск 03 добавляет кнопку, когда `offerSignIn`.
- Settings: `SettingsStore.limitsPollStatus: String`, рисуется под `Toggle("Limits via Anthropic API")`.

### Таск 03 — построено
- Python: `CLAUDE_LOGIN_COMMAND = ROOT/claude-login.command`; `claude_login() -> str` (файл 0700 атомарно, `/usr/bin/open`), `STRINGS` `login.opened`/`login.missing`; CLI `mcpbar.py claude-login` → код 0.
- Swift: `BackendCommand.claudeLogin.arguments == ["claude-login"]`; `StatusController.signInClaude()` (Actions.swift: `runQuietCommand(.claudeLogin)`, `lastLimitsPoll = 0`); `PanelStore.signInClaude()`; кнопка «Sign in to Claude Code» в `PanelView.limitsNoticeBlock` при `offerSignIn`.

### Таск 04 — построено
- `Sources/Model/LimitsNote.swift`: `LimitsNote.age(of:now:) -> String`, `LimitsNote.footer(_ groups: [(title: String, age: String)]) -> String`. `PanelData.age` делегирует в `LimitsNote.age` (его зовёт `SettingsStore`).
- `merge_codex_limits`: корневой `ts` = max `ts` окон пула `codex`, иначе max по всем; per-window `ts` без изменений.
- `PanelLimitGroup.tip` у Codex кончается « · from the last Codex session»; `PanelSnapshot.limitsNote` при наличии групп — целиком строка футера; при двух и более провайдерах строка стоит отдельным рядом над кнопками.

### Таск F1 — построено (ремонт по ревью ветки)
- `LimitsStatus.notice(_:oauthLimits:figuresTs: Double?, now: Double) -> LimitsNotice?` — подпись вернулась к исходному контракту; nil, если `figuresTs > status.ts` (цифры обновил другой писатель позже неудачного опроса). Запись «Таск 02 — построено» про `figuresAge` устарела.
- `LimitsStatus.signedOutBannerDue(_:oauthLimits:figuresTs:launchedAt:) -> Bool` — true только для `no-login` с `status.ts >= floor(launchedAt)` и без более свежих цифр; `StatusController.launchedAt: Double` (main.swift).
- `claude_login`: в `.command` только `exec <shlex.quote(path)> auth login` при `os.path.isabs(path)`, иначе ветка «not found»; `STRINGS` `login.openfailed` (TimeoutExpired/OSError от open → текст, код 0).

## Дополнение 2026-10-14 — знак в строке меню (R11)
- `Sources/Model/MenuBar.swift`: `MenuBarAgent` получает `signedOut: Bool` (по умолчанию false); `MenuBarAgent.shown(..., claudeStatus: LimitsStatus?, oauthLimits: Bool, ...)` выставляет его для провайдера Claude по правилу `LimitsStatus` (`no-login`, опрос включён, `figuresTs` не новее `status.ts`) — вынести это правило в `LimitsStatus.signedOutShown(_:oauthLimits:figuresTs:) -> Bool` и использовать его и в `notice`/`signedOutBannerDue`, если там дублируется.
- Строки: `LimitsStatus.menuBarTip` = "Claude Code is not signed in — open the panel to sign in" (константа в модели).
- `Sources/IconRender.swift`: при `agent.signedOut` шкалы Claude с пониженной непрозрачностью + пометка в углу области шкал, ширина иконки прежняя; `signature` включает флаг; tooltip статус-айтема и accessibility-описание берут `menuBarTip`.
- Проверки в `tests/model/main.swift`: `MenuBarAgent.shown` с `no-login` → `signedOut == true`; с `ok`, с выключенным опросом, с более свежими цифрами, с `failed` → false; `signature` различается.
