# Заметки по коду для плашки «шанс сброса лимитов» (whenreset)

Рабочая копия: /Users/talalaev-m/projects/acb-whenreset, ветка `claude/whenreset-odds` от main bad2904.
Правила проекта: `.claude/rules/architecture.md`, `.claude/rules/code-conventions.md` — читать обязательно.

## 1. Поток данных полосы лимитов

Файлы → StatusController → снимок → вьюха. Вьюха ничего не читает и не запускает; обратно — только методы `PanelStore`.

- Тик `tick()` StatePolling.swift:90 раз в 0.4 с (Timer в main.swift:320). В конце `refreshCounts()` (Backend.swift:211): `if panelIsOpen { panelStore.refresh() }` и `settingsStore.refresh()`, если окно настроек видимо.
- `PanelStore.refresh()` (PanelStore.swift:55): `PanelSnapshot(controller, mcp:, update:)`, затем `if next != snapshot { snapshot = next }` — снимок обязан быть `Equatable`.
- `extension PanelSnapshot { init(_ c: StatusController, mcp:, update:) }` PanelStore.swift:460–490: `(limitGroups, limitsNote) = c.panelLimitGroups(now:)` (479), `limitsNotice` (480), `limitsLayout` (481), `limitsProvider` (482–483).
- PanelData.swift (extension StatusController): `panelLimitGroups(now:)` 98–132, `panelLimitsNotice(now:)` 136, `static until(_:)` 147 («2h 10m», после суток «3d 4h»), `static age(of:now:)` 141 → `LimitsNote.age`, `panelContentCap` 160, `panelStripExtra` 174 (+80 для `.rows`, +40 для switcher), `static panelChromeHeight = 260` (182).
- Структуры PanelStore.swift: `PanelSnapshot` 242–292 (поля `width`, `contentCap`, `sessions`, …, `limitGroups`, `limitsNote`, `limitsNotice`, `limitsLayout = .rows`, `limitsProvider = "claude"`, `mcp`, `update`, `notificationsDenied`); `PanelLimitGroup` 211 (`provider`, `title`, `glyph`, `limits`, `resets`, `age`, `plan`, `worst`, `id = provider`, `tip`); `PanelLimit` 368; `PanelLimitsNotice` 349; `enum PanelLimitsLayout { rows, switcher }` 185.
- `Provider` (Model/Provider.swift): `.claude` (id "claude", glyph "sparkle"), `.codex` (id "codex", glyph "chevron.left.forwardslash.chevron.right"), `Provider.named(_:)`, `Provider.all`.
- PanelView.swift: `body` 17–68 — баннер обновления (19–22), `limitsStrip` (23), `tabBar` (24), ScrollView с `content`, предупреждение о нотификациях, `footer`. Анимации `.animation(… value: store.tab)` (66) и `value: store.expanded` (67) через `Motion.moves`/`Motion.time(0.18)`.
- `limitsStrip` 72–106: над полосой `limitsNoticeBlock`; пусто → серый текст в `wellFill`; один провайдер → `limitRow(only, named: only.provider != "claude")`; много → `.rows` или `.switcher` (`providerSwitcher` + `limitRow(shownGroup(groups), named: false)`). `shownGroup` — какой провайдер сейчас выбран в переключателе.
- `limitRow` 135, `limitHeader` 150, `providerSwitcher` 172–218.
- Дамп `describePanel()` PanelWindow.swift:202–273, строки полосы лимитов 216–229.

## 2. Переключатель в Settings — образцы

- «Limits via Anthropic API» (`oauthLimits`): main.swift:217 `var oauthLimits = true`; init main.swift:297 `if d.object(forKey: "oauthLimits") != nil { oauthLimits = d.bool(forKey: "oauthLimits") }`; SettingsStore.swift:73 `var oauthLimits: Binding<Bool> { bind({ $0.oauthLimits }, { $0.applyOAuthLimits($1) }, or: true) }`; `applyOAuthLimits(_:)` SettingsStore.swift:237 (extension StatusController от 219): пишет UserDefaults, при on сразу опрашивает, затем перерисовка.
- «Anonymous usage ping» (`analytics`): main.swift:239, чтение main.swift:304, ключ "analytics"; SettingsStore.swift:104; `applyAnalytics(_:)` Analytics.swift:16–25.
- `bind` SettingsStore.swift:49–65: `objectWillChange.send()` до записи, копий состояния в SettingsStore нет. Статусная строка в Settings → значение в `SettingsStore.Live` (23–34) и `refresh()` (36).
- SettingsView.swift, `private struct GeneralSettings` 79–219, `Form` `.formStyle(.grouped)`: секции «Menu bar» 163–177, «Sessions» 178–184, «Limits» 185–196 (`Toggle("Limits via Anthropic API", isOn: store.oauthLimits)`, под ним `Text(store.limitsPollStatus).font(.footnote).foregroundStyle(.secondary)`, `footer: Text(Self.limitsFooter)`), «Codex» 197–205, «Usage» 206–215.
- Подписи — `private static let limitsFooter: String = "…" + "…"` (101) и т.п. **Правило 11**: длинный текст только типизированной константой, иначе Swift 6.0.3 не справляется с type-check.
- Хранимые свойства контроллера — только в main.swift (extension не может их объявлять); поведение — в файле своей темы.

## 3. Сеть и таймеры

- Updates.swift `checkForUpdate(force:)` 39–92: троттлинг по `UserDefaults "lastUpdateCheck"`, метка ставится ДО запроса (считается попытка); `URLRequest`, `User-Agent: ClaudeControlBar`, `URLSession.shared.dataTask`, разбор `try? JSONSerialization.jsonObject(with:) as? [String: Any]`, ошибки → `UpdateFeed.checkProblem(status:answer:error:)`; итог на main через `DispatchQueue.main.async`.
- Analytics.swift `sendAnalyticsPing()` 59–78: `URLRequest(url:, timeoutInterval: 15)`, `URLSession(configuration: .ephemeral, delegate: NoRedirect.shared, delegateQueue: nil)`, `session.finishTasksAndInvalidate()`. `NoRedirect` 82–89 отказывает в любом редиректе. **Образец для запроса whenreset** (без куки, без редиректов).
- Таймеры main.swift: 320 тик 0.4 с; 326 MCP 600 с; 335 лимиты 300 с; 441 `Timer.scheduledTimer(withTimeInterval: 3600, repeats: true)` → `sendAnalyticsPingIfDue()` (комментарий 438–440: часовой таймер + троттл внутри, потому что длинный таймер при сне Mac опаздывает). Запуски при старте ~435, при открытии панели PanelWindow.swift:61–62 (`pollLimits()`, `checkForUpdate()`).
- Время последней попытки — только в `UserDefaults.standard`. Покадровых таймеров не добавлять (Motion.swift:12–14).
- **whenreset**: urllib/дефолтный UA Python Cloudflare режет 403 — в Swift ставить свой `User-Agent`.

## 4. Модельная проверка

- tests/model/main.swift — plain-исполняемый файл, глобальный код сверху вниз, объявлять до использования. Хелпер `check(_ passed: Bool, _ what: String)` (13–16). Блоки `// MARK: …`; новый блок — перед финальным `print(failures == 0 ? …)`. Фикстуры — словари `[String: Any]`; проверять битые данные, нет поля, чужие типы, NaN/огромные числа.
- CI (.github/workflows/ci.yml, job `check`): `swiftc -O Sources/Model/*.swift tests/model/main.swift -o "$RUNNER_TEMP/model" -framework Cocoa` — маска, новый файл в `Sources/Model/` подхватится сам. Модель не может ссылаться на app-код (StatusController, SwiftUI) — только Foundation/Cocoa.
- Образцы моделей: `Model/AnalyticsPing.swift` (enum, константа `endpoint`, чистое `static func due(now:lastAttempt:…)`) — лучший шаблон; `Model/UpdateFeed.swift` (`enum` + статические чистые функции, `checkProblem`); `Model/Limits.swift` (`init?(json:)`); `Model/LimitsNote.swift` (`age(of:now:)` — «just now / 4 min ago / 3h ago / 2d ago»).
- Правила: struct + `init?(json:)` с безопасными дефолтами; статусы строками; Double→Int только `.clampedInt` (Model/SafeInt.swift:11); никогда `as!`.

## 5. Сборка

- build.sh: `swiftc -O -target arm64-apple-macos13.0 Sources/*.swift Sources/Model/*.swift … -framework Cocoa -framework SwiftUI`, то же для x86_64, `lipo`. Маска — новые файлы подхватятся. Минимум macOS 13.0 — API новее 13 не использовать.
- ci.yml `swift-6-0`: `swiftc -typecheck -target arm64-apple-macos13.0 Sources/*.swift Sources/Model/*.swift -framework Cocoa -framework SwiftUI` компилятором Swift 6.0 — мелкие подвьюхи, без длинных цепочек `+` и вложенных тернарников в `body`.
- ci.yml `scripts-linux`: `grep -rnE '@State([^A-Za-z]|$)' Sources` — любое вхождение (даже в комментарии) красное. Состояние вьюхи: `private let _x = State<…>(initialValue:)` + computed (PanelView.swift:11–15).
- Гвард идентичности: литерал bundle id в Sources/main.swift, Updates.swift запрещён; префикс `CLAUDE_STATUSBAR` запрещён.
- Локально: `./build.sh`; модельная проверка `swiftc -O Sources/Model/*.swift tests/model/main.swift -o /tmp/model -framework Cocoa && /tmp/model`; typecheck `swiftc -typecheck -target arm64-apple-macos13.0 Sources/*.swift Sources/Model/*.swift -framework Cocoa -framework SwiftUI`.

## 6. Дамп и переменные окружения

- `CONTROL_BAR_DUMP_MENU=1`: main.swift:424–430, через 1.5 с `print(self.describePanel())` и выход. Сеть за 1.5 с может не успеть → нужен кэш последнего ответа в UserDefaults, тогда дамп покажет данные сразу.
- `CONTROL_BAR_DIAGNOSE=menu` — открыть панель через 3 с (main.swift:353–359), скриншот — системными средствами. Рендера в PNG в коде нет.
- Прочие: `CONTROL_BAR_DIAGNOSE=settings|toggle`, `CONTROL_BAR_UPDATE_NOW`, `CONTROL_BAR_NO_ANALYTICS`, `CONTROL_BAR_APP`, `CONTROL_BAR_DEBUG`.

## 7. Стиль

- PanelTheme.swift: `width=300`, `pad=9`, `corner=13`, `cardCorner=10`; `cardFill` 25, `cardBorder` 29, `wellFill` 39 (фон плиток), `raisedFill` 45, `track` 49; `level(_ fraction:)` 57 — оранжевый/красный при ≥75/90% «почти кончилось». **Для вероятности сброса `level` не использовать** — там больше = хуже.
- Блоки: `PanelCard` 93, `PanelNotice(glyph:text:)` 114 (оранжевая, для предупреждений), `PanelSectionTitle` 136, `PanelBar(value:fill:height:)` 156, `PanelDisclosure(open:)` 184 (`chevron.right` 9 pt, поворот 90°), `PanelTag(text:)` 196, `PanelButtonStyle` 223.
- `PanelLimitTile` PanelView.swift:334–372 — образец ячейки: заголовок 9 pt semibold uppercase kerning 0.35 `.tertiary`; число 14 pt semibold `monospacedDigit`; `PanelBar`; подложка `RoundedRectangle(cornerRadius: 8)` `wellFill`; `.help`, `accessibilityElement(children: .ignore)` + `accessibilityLabel`.
- `store.expanded: Set<String>` (PanelStore.swift:23), `toggleExpanded(_:)` 106, `collapseAll()` 112 (при каждом открытии панели, PanelWindow.swift:75). Константы id рядом: `PanelStore.waitingAuthID` (117). Образец шеврона PanelTabs.swift:206–215: `Button { store.toggleExpanded(id) } label: { PanelDisclosure(open: open).frame(width: 22, height: 26).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel(open ? "Hide details" : "Show details")`; раскрытие `if open { … }`, анимацию даёт общий `.animation(value: store.expanded)`.
- Высота: плашка выше ScrollView → учесть её в `panelStripExtra`/`panelChromeHeight` (PanelData.swift:160–182), иначе длинная панель вылезет за экран.

## 8. Документы

- CHANGELOG.md: `## [Unreleased]` строка 10, сейчас только `### Fixed`; формат — `**Жирная фраза.** пояснение`, перенос ~100 символов, продолжение с 2 пробелами. Добавлять `### Added`.
- PRIVACY.md `## Network` 8–27 — пункты `- **…**: …`; абзац 25–27 «GitHub, Homebrew and Anthropic see that a request arrived … the only requests the app makes for itself» — дописать whenreset.app.
- README.md:107 (Usage limits), README.ru.md — строка о новой плашке и выключателе.

## 9. Изменено после прошлой сборки (как есть сейчас)

- 0e283fe — хвосты транскриптов сканируются байтами (Model/Sessions.swift:278 `scanTail`, Model/CodexRollout.swift:51–60). Плашку не касается.
- bffa1a4, e16e28b, 5b11604, 8788676 — Codex «Needs you»: `CodexRollout.Boundary.failed`, `Session.asyncQuestion`, `Model/CodexAttention.swift`, `pollCodexAttention` (Backend.swift:153), `codex/attention.json`. Со снимком лимитов не пересекается.
