# Границы

Читается каждым исполнителем первым. Заметки по коду — `notes.md` рядом.

## Правила проекта (действуют на каждый таск)

- `.claude/rules/architecture.md` и `.claude/rules/code-conventions.md` — обязательны.
- Вьюха читает только `PanelStore.snapshot`; сеть, UserDefaults и таймеры — только в `StatusController`.
- Double → Int только `.clampedInt`; никаких `as!`; длинные строки во вьюхах — `private static let x: String`.
- Ни одного вхождения `@State` (даже в комментарии) — CI это режет; состояние вьюхи через `State<…>(initialValue:)`.
- macOS 13 минимум; код должен проходить typecheck Swift 6.0 (мелкие подвьюхи).
- Комментарии — только «почему», без пересказа кода.

Договорились с прошлой сборки (не пересматривать):

- Чужую statusLine приложение не трогает никогда; чинится только своя мёртвая обёртка (R01.1)
- Состояние опроса лимитов живёт в отдельном файле `limits-status.json`, а не в `limits.json` (R02)
- Вход в Claude Code — через `.command`-файл и Terminal, без AppleScript и разрешения Automation (R03)
- Версия и релиз — только по слову пользователя; `## [Unreleased]` в CHANGELOG заполнен

## Границы, решённые в спецификации

### Модель — `Sources/Model/ResetOdds.swift` (только Foundation)

Владеет: разбором ответа whenreset и чистыми правилами. Скрывает: форму JSON.

```swift
struct ResetOddsProduct: Equatable {
    let id: String            // "claude" | "codex" — ключ в products, совпадает с Provider.id
    let name: String          // products.<id>.name, иначе id
    let p24: Int?             // odds.result["1"] → проценты 0…100; nil, если нет
    let p48: Int?             // odds.result["2"]
    let p7d: Int?             // odds.result["7"]
    let total: Int?           // stats.total
    let last30d: Int?         // stats.last30d
    let lastRegular: String?  // stats.last_regular_date, иначе stats.last_date ("YYYY-MM-DD", UTC)
    let lastBanked: String?   // stats.last_banked_date
}

struct ResetOdds: Equatable {
    let products: [ResetOddsProduct]   // порядок: claude, затем codex, затем прочие по алфавиту
    init?(json: [String: Any])         // nil, если нет ни одного продукта
    init?(data: Data)                  // JSONSerialization + init(json:)
    func product(_ id: String) -> ResetOddsProduct?
}

enum ResetOddsFeed {
    static let endpoint: String        // "https://whenreset.app/api/v1/resets.json"
    static let site: String            // "https://whenreset.app/"
    static let interval: Double        // 900 — не чаще раза в 15 минут
    static let staleAfter: Double      // 21600 — старше 6 часов = устарело
    static func due(now: Double, lastAttempt: Double) -> Bool        // lastAttempt 0 → true; часы назад (lastAttempt > now) → true
    static func percent(_ value: Any?) -> Int?                         // доля 0…1 (NSNumber) → 0…100, через clampedInt; не число/NaN → nil
    static func daysSince(_ date: String?, now: Double) -> Int?        // "YYYY-MM-DD" UTC → целые сутки, ≥ 0; битая дата → nil
    static func problem(status: Int?, error: Error?) -> String         // короткий английский текст причины сбоя
}
```

### Контроллер — `Sources/ResetOdds.swift` (extension StatusController) + хранимые поля в `main.swift`

Владеет: сетью, кэшем в UserDefaults, таймером, выключателем. Ключи UserDefaults: `"resetOdds"` (Bool, выключатель), `"lastResetOddsAttempt"` (Double), `"resetOddsCache"` (Data), `"resetOddsFetchedAt"` (Double).

```swift
// main.swift, хранимые поля StatusController
var resetOddsOn = true
var resetOdds: ResetOdds?          // из кэша при init и после удачного ответа
var resetOddsFetchedAt: Double = 0 // epoch секунд последнего удачного ответа
var resetOddsProblem: String?      // текст последнего сбоя; nil после удачи
var resetOddsRunning = false

// Sources/ResetOdds.swift
func loadResetOddsCache()                 // зовётся из init
func fetchResetOddsIfDue(force: Bool = false)
func applyResetOdds(_ on: Bool)           // пишет "resetOdds"; off → кэш и поля очищены; on → fetch(force: true); затем refreshCounts()
```

### Снимок — `PanelStore.swift` (+ сборка в `PanelData.swift`)

```swift
struct PanelResetOdds: Equatable {
    let state: String                 // "ok" | "loading" | "unavailable"
    let rows: [PanelResetOddsRow]     // пусто при loading/unavailable
    let stale: Bool                   // удачный ответ старше staleAfter
    let note: String                  // низ развёрнутого вида: "estimate from past resets, not official · updated 4 min ago" или "couldn't refresh — showing data from 3h ago"; при unavailable — причина
}
struct PanelResetOddsRow: Equatable, Identifiable {
    let provider: String              // id = provider
    let title: String                 // "Claude" / "Codex"
    let glyph: String                 // Provider.named(provider)?.glyph
    let p24: Int?, p48: Int?, p7d: Int?
    let lastReset: String?            // "today" | "1d ago" | "22d ago"
    let counts: String?               // "53 resets tracked · 5 in last 30 days"
    let banked: String?               // "Banked reset handed out Sep 22" или nil
    var id: String { provider }
}
// PanelSnapshot: var resetOdds: PanelResetOdds? = nil   (nil = выключено)
// StatusController (PanelData.swift): func panelResetOdds(now: Double) -> PanelResetOdds?
// PanelStore: static let resetOddsID = "reset-odds"; func openResetOddsSite()
```

`panelLimitGroups(now:)` дописывает к `tip` группы строку "Early reset in 24h: 13% (whenreset.app)", когда у провайдера есть `p24` и выключатель включён.

### Вьюха — `Sources/PanelResetOdds.swift`

`struct PanelResetOddsCard: View { @ObservedObject var store: PanelStore; let odds: PanelResetOdds }` — вставляется в `PanelView.body` сразу после `limitsStrip`, когда `store.snapshot.resetOdds != nil`. Раскрытие — `store.expanded.contains(PanelStore.resetOddsID)` и `store.toggleExpanded(PanelStore.resetOddsID)`.

### Швы для проверки

- Модельная проверка (`tests/model/main.swift`): `ResetOdds(json:)` на реальной фикстуре ответа и на битых данных, `ResetOddsFeed.due/percent/daysSince/problem`.
- Дамп `CONTROL_BAR_DUMP_MENU=1` — блок «Reset odds».

## Что построили таски

(дописывается по ходу)

## Команды и окружение

- Swift 6.x (`swiftc` из Xcode/CLT), macOS 13 минимум, без внешних зависимостей. Python/Node эта сборка не трогает.
- Одна проверка: `swiftc -O Sources/Model/*.swift tests/model/main.swift -o /tmp/acb-model -framework Cocoa && /tmp/acb-model | tail -3 && swiftc -typecheck -target arm64-apple-macos13.0 Sources/*.swift Sources/Model/*.swift -framework Cocoa -framework SwiftUI && ! grep -rnE '@State([^A-Za-z]|$)' Sources`
- Сборка приложения: `CONTROL_BAR_APP=/tmp/acb-whenreset-app/Agent\ Control\ Bar.app ./build.sh` — **не ставить поверх установленного у пользователя приложения** (по умолчанию build.sh ставит в его место). Сначала прочитай build.sh и убедись, что эта переменная действительно уводит установку в /tmp и не перезапускает рабочую копию пользователя.
- Дамп: `CONTROL_BAR_DUMP_MENU=1 "/tmp/acb-whenreset-app/Agent Control Bar.app/Contents/MacOS/<exec из identity.env>"`.
- Реальный ответ API для фикстур: `/tmp/whenreset/v1_resets.json` (53 КБ; в фикстуру — урезанная копия, без длинного списка events).
- Не трогать: `hooks/`, `scripts/`, `.claude-plugin/` (версию не поднимать), `identity.env`.

## Как посмотреть результат, не трогая приложение пользователя

- У пользователя запущено установленное `/Applications/Agent Control Bar.app`. **Не завершать и не перезаписывать его.**
- Сборка по умолчанию кладёт `.app` в `build/` внутри рабочей копии — это безопасно (`CONTROL_BAR_APP` не нужен).
- Копия из `build/` с тем же bundle id **сама уходит** при запуске, если установленная уже работает (`enforceSingleInstance`, AppLifecycle.swift:62). Для дампа и скриншота: скопируй собранный `.app` в `/tmp/acb-whenreset-app/`, в копии поменяй `CFBundleIdentifier` в Info.plist на `io.github.infinityscripter.claude-control-bar.dev` (`/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier …'`) и переподпиши ad-hoc (`codesign --force --deep -s - …`). Такая копия не считается установленной (не в /Applications), хуки не ставит, предшественников не трогает. UserDefaults у неё свои — кэш пустой, ответ сети приходит за ~1 с.
- Скриншот панели: запусти копию с `CONTROL_BAR_DIAGNOSE=menu`, через ~5 с `screencapture -x` и вырежи панель; затем завершай только свой процесс (по pid). Если панель не видно (иконку спрятал менеджер строки меню), отрисуй `PanelResetOddsCard` в PNG через `ImageRenderer` во временном исполняемом файле в `/tmp` и скажи об этом в отчёте.
