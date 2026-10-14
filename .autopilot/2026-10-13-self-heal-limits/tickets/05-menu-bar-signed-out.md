# 05 — Знак о выходе из аккаунта в строке меню

**Требования:** R11, R11.1, R11i
**Зависит от:** —
**Зона:** `Sources/Model/MenuBar.swift` · `Sources/Model/LimitsStatus.swift` · `Sources/IconRender.swift` · `Sources/StatePolling.swift` · `Sources/Notifications.swift` · `Sources/PanelData.swift` · `tests/model/main.swift` · `CHANGELOG.md` · `README.md` · `README.ru.md`
**Волна:** 6
**Ревью:** нет
**Модель:** сильная

## Что должно заработать

Пользователь, не открывая панель, видит в строке меню, что Claude Code разлогинен: шкалы Claude приглушены, рядом маленькая пометка, подсказка иконки называет причину и что делать. Знак появляется по тому же правилу, что блок в панели (только `no-login`, опрос включён, цифры не свежее статуса), не мигает, не меняет ширину иконки и сам пропадает после первого успешного опроса.

## Из брифа, дословно

> «наверное если человек разлогинился надо ему где-то про это сказать»

## Разделы спецификации

Истории 25–27; Решения по реализации — «Знак в строке меню (R11)»; `interfaces.md` — «Дополнение 2026-10-14».

## Критерии приёмки

- [ ] `MenuBarAgent.signedOut` выставляется в `MenuBarAgent.shown` по правилу модели `LimitsStatus`; проверки в `tests/model/main.swift`: `no-login` → true; `ok`, выключенный опрос, цифры свежее статуса, `failed` → false
- [ ] правило «показывать ли» одно на панель, уведомление и иконку — без второй копии условий
- [ ] `IconRender`: при `signedOut` шкалы Claude приглушены и есть пометка; ширина иконки не меняется; `signature` включает флаг; tooltip и accessibility-описание — `menuBarTip`
- [ ] после `state: ok` иконка возвращается к обычному виду без перезапуска (через обычный mtime-гейт)
- [ ] тесты Python, Node, Swift-модель зелёные; `swiftc -typecheck` проходит; `@State` в Sources — нет; `./build.sh` собирает бандл в `build/`
- [ ] `CHANGELOG.md` `### Added` под `## [Unreleased]`; одна фраза в `README.md`/`README.ru.md`
