# 01 — Данные whenreset: модель, загрузка, выключатель, документы

**Требования:** R01, R03, R04, R05, R06, R07i, R08i
**Зависит от:** —
**Зона:** `Sources/Model/ResetOdds.swift` · `Sources/ResetOdds.swift` · `Sources/main.swift` · `Sources/PanelData.swift` · `Sources/PanelStore.swift` · `Sources/PanelWindow.swift` · `Sources/SettingsStore.swift` · `Sources/SettingsView.swift` · `tests/model/main.swift` · `PRIVACY.md` · `CHANGELOG.md` · `README.md` · `README.ru.md`
**Волна:** 1
**Ревью:** да — фундамент: снимок и модель, которые читает таск 02; новый сетевой запрос к стороннему сервису
**Модель:** сильная

## Что должно заработать

Приложение раз в 15 минут (не чаще) забирает `https://whenreset.app/api/v1/resets.json`, разбирает шансы сброса и счётчики по Claude и Codex, хранит последний удачный ответ в UserDefaults и кладёт готовый к показу `PanelResetOdds` в снимок панели. В Settings → General → «Limits» есть выключатель «Limit reset odds» (по умолчанию включён). Дамп `CONTROL_BAR_DUMP_MENU=1` печатает блок «Reset odds». Подсказка у строки лимитов провайдера говорит «Early reset in 24h: N% (whenreset.app)». Новый запрос описан в PRIVACY.md, фича — в CHANGELOG `[Unreleased]` и README. Саму плашку рисует таск 02 — здесь вьюх, кроме Toggle в Settings, нет.

## Из брифа, дословно

> «https://whenreset.app/api/ можешь добавить апишку в наш вот этот вот э, плагин для определения сессий»
> «процент шанс того, что обнулятся лимиты»
> «у нас есть резеты, да, разные указаны»
> «И там еще вот эту галочку»
> «чтобы можно было через нее посмотреть, сколько в кодексе резетов»

## Разделы спецификации

«Решение» — пункты про переключатель, R01.1, R01.2, R03.1, R04.2, R07i.1–R07i.4, R08i.1–R08i.2, «Дамп»; «Решения по реализации». Точные имена и формы — `interfaces.md` (модель, контроллер, снимок).

## Критерии приёмки

- [ ] `ResetOdds(json:)` на реальном ответе (фикстура в `tests/model/main.swift` — урезанная копия `/tmp/whenreset/v1_resets.json`) даёт Codex `p24=13, p48=31, p7d=71, total=53, last30d=5, lastRegular="2026-10-13", lastBanked="2026-10-07"`, Claude `p24=8, p7d=50, total=13`; битый JSON, пустые `products`, `odds.result = null`, строки вместо чисел, NaN и 1e30 не роняют модель и дают nil/«—», а не 0
- [ ] `ResetOddsFeed.due`, `percent`, `daysSince`, `problem` покрыты модельной проверкой; модельная проверка зелёная
- [ ] Запрос: эфемерная сессия, `NoRedirect`, таймаут 15 с, свой `User-Agent`; попытка помечается в `lastResetOddsAttempt` до запроса; таймер раз в 5 минут + запуск + открытие панели зовут `fetchResetOddsIfDue()`
- [ ] Сбой сети при наличии кэша — снимок `state = "ok"` с `note` «couldn't refresh — showing data from …»; без кэша — `state = "unavailable"`; до первого ответа — `"loading"`; ответ старше 6 часов — `stale = true`
- [ ] Выключатель: off — `snapshot.resetOdds == nil`, кэш стёрт, запросов нет; on — немедленный запрос; значение переживает перезапуск
- [ ] `CONTROL_BAR_DUMP_MENU=1` на собранном приложении печатает «Reset odds» с процентами и счётчиками обоих провайдеров (из кэша, без ожидания сети)
- [ ] PRIVACY.md `## Network` описывает запрос к whenreset.app и выключатель, абзац «the only requests the app makes» обновлён; CHANGELOG `[Unreleased]` → `### Added`; README.md и README.ru.md упоминают плашку
- [ ] `./build.sh` собирается; typecheck в стиле задачи `swift-6-0` проходит; `grep -rnE '@State([^A-Za-z]|$)' Sources` пуст
