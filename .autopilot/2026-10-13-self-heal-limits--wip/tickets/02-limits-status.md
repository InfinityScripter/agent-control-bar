# 02 — Панель говорит, почему лимиты не обновляются

**Требования:** R02, R02.1, R02.2, R02.3, R02.4, A01, A02, R04, R05, R06, R08
**Зависит от:** 01
**Зона:** `scripts/mcpbar.py` (`fetch_limits`, `STRINGS`) · `tests/test_mcpbar.py` · `Sources/Model/LimitsStatus.swift` (новый) · `Sources/main.swift` · `Sources/StatePolling.swift` · `Sources/Notifications.swift` · `Sources/PanelData.swift` · `Sources/PanelStore.swift` · `Sources/PanelView.swift` · `Sources/SettingsStore.swift` · `Sources/SettingsView.swift` · `tests/model/main.swift` · `CHANGELOG.md` · `PRIVACY.md` · `README.md` · `README.ru.md` · `TROUBLESHOOTING.md`
**Волна:** 2
**Ревью:** да — фундамент (модель `LimitsStatus` нужна таску 03)
**Модель:** сильная

## Что должно заработать

Опрос лимитов Claude после каждого запуска оставляет файл состояния: получилось или нет и почему. Панель читает его и, когда цифры получить не удалось, показывает блок с причиной («Claude Code is not signed in», «Limits poll failed: HTTPError») и возрастом последних цифр. Старые цифры остаются видны, но подпись честно говорит, насколько они старые. Успешный опрос убирает блок. При выключенном «Limits via Anthropic API» блока нет. Если файла состояния нет (старый бэкенд), панель ведёт себя как раньше. Один раз за запуск приложения приходит уведомление macOS о выходе из аккаунта. В Settings под переключателем видна та же причина и время последнего опроса. Кнопка входа в блоке появится в таске 03: здесь блок без кнопки.

## Из брифа, дословно

> «Они не обновляются, особенно в клоде коде.»

> «Нужно это делать все на автомате, а не руками, чтобы и новых пользователей тоже это было.»

> «Можешь новые прямо функции добавлять. Я не против.»

## Разделы спецификации

Истории 8–14; Решения по реализации — файл состояния, чтение в Swift, панель, уведомление, Settings; `interfaces.md` — контракт `limits-status.json`, модель `LimitsStatus`/`LimitsNotice`, снимок панели, состояние контроллера, чтение.

## Критерии приёмки

- [ ] `mcpbar.py limits` пишет `limits-status.json` при каждом исходе: `ok` (после успешной записи `limits.json`), `no-login` (нет токена), `failed` (сеть/HTTP/разбор, `detail` — имя исключения), `empty`; атомарно, 0600; `limits.json` при сбое не меняется
- [ ] тест Python пишет шов `build/seam/limits-status.json` с состоянием `no-login`; Swift-модель читает его и разбирает
- [ ] `LimitsStatus(json:)` разбирает файл, возвращает nil без `state`; `LimitsStatus.notice(...)` даёт nil при `ok` и при `oauthLimits == false`, текст с возрастом цифр при `no-login`/`failed`/`empty`; `emptyStripText` даёт «Claude Code is not signed in — sign in to see limits» при `no-login` и прежние строки иначе — всё проверено в `tests/model/main.swift`
- [ ] `loadLimitsStatus()` в `StatePolling.swift` с mtime-гейтом; отсутствие файла → `limitsStatus = nil`, поведение панели прежнее
- [ ] в панели над полосой лимитов блок `PanelNotice` с заголовком и подсказкой из `LimitsNotice`; подпись группы Claude «measured 1d ago» остаётся
- [ ] уведомление macOS один раз за запуск при первом `no-login` (флаг в `main.swift`), не при `ok`, не при выключенном переключателе
- [ ] Settings → Limits: строка «Last poll: not signed in · figures from 1d ago» / «Last poll: ok · 4 min ago» под переключателем, через типизированную константу или вычисляемую строку в `SettingsStore`
- [ ] тесты Python, Node, Swift-модель зелёные; `swiftc -typecheck` проходит; в `Sources/` нет `@State`
- [ ] `CHANGELOG.md` `### Added`; `PRIVACY.md` — новый файл `limits-status.json` (что в нём, кто пишет); `README.md`/`README.ru.md` — абзац про блок состояния; `TROUBLESHOOTING.md` — «No data — not signed in»
