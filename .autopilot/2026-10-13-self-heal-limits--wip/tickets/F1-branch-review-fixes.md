# F1 — Ремонт по ревью ветки

**Требования:** R02, R02.1, A01, R03, R03.1
**Зависит от:** —
**Зона:** `Sources/main.swift` · `Sources/Notifications.swift` · `Sources/StatePolling.swift` · `Sources/Actions.swift` · `Sources/PanelView.swift` · `Sources/PanelStore.swift` · `Sources/PanelData.swift` · `Sources/Model/LimitsStatus.swift` · `scripts/mcpbar.py` · `tests/test_mcpbar.py` · `tests/model/main.swift`
**Волна:** 5
**Ревью:** да — ремонт ветки
**Модель:** сильная

## Что должно заработать

Уведомление «Claude Code is signed out» не приходит ложно при запуске по вчерашнему файлу состояния. Блок состояния не висит над живыми цифрами, когда их обновляет второй источник (перехват statusLine), а падает только опрос через API. Путь к `claude` попадает в `.command` только абсолютным и экранированным. Зависший `open` не роняет бэкенд с traceback. Комментарии, пересказывающие код, убраны.

## Из брифа, дословно

> «Нужно это делать все на автомате, а не руками, чтобы и новых пользователей тоже это было.»

## Разделы спецификации

Истории 8–10, 13, 15–16; `interfaces.md` — контракты `limits-status.json`, `claude-login.command`, разделы «Таск 02/03 — построено».

## Критерии приёмки

- [ ] craft · Sources/main.swift:335-337 + Sources/Notifications.swift:26 · pollLimits() на старте асинхронный, а tick() сразу за ним читает limits-status.json прошлого запуска; файл «no-login» со вчера даёт баннер «Claude Code is signed out» до ответа первого опроса. Условие: баннер только по статусу с ts не старше момента запуска (или только по `.changed` после первого опроса этого запуска), никогда по файлу, застигнутому при старте; проверка в tests/model/main.swift, если правило вынесено в модель
- [ ] craft · комментарии в трёх местах: Sources/Actions.swift:55-56 («see BackendCommand.claudeLogin»), Sources/PanelView.swift:108-110 (пересказ содержимого блока), Sources/PanelStore.swift:345-346 (пересказ полей). Условие: в Actions оставить только фразу про lastLimitsPoll = 0 и 60-секундный гейт, два других комментария убрать
- [ ] безопасность · scripts/mcpbar.py:1401 (find_claude — :390-399) · Условие: в .command попадает только `shlex.quote(path)` и только при `os.path.isabs(path)`, иначе ветка «not found»; тест с `$` и одинарной кавычкой в пути; тест с относительным путём → ветка not found
- [ ] craft · scripts/mcpbar.py:1413 · `subprocess.run(open, timeout=30)` без перехвата. Условие: TimeoutExpired и OSError → текстовый ответ (новый ключ STRINGS или `login.missing`-подобный), код 0; тест
- [ ] spec/craft · Sources/Model/LimitsStatus.swift:36-49, Sources/PanelData.swift panelLimitsNotice · у limits.json второй писатель — перехват statusLine; пока он обновляет цифры, а OAuth-опрос падает, блок висит над живыми цифрами и пишет «Limits stopped updating just now». Условие: если `limits.ts` новее `status.ts` — блока нет (уведомления тоже нет); проверка в tests/model/main.swift
- [ ] тесты Python, Node, Swift-модель зелёные; `swiftc -typecheck` проходит; `@State` в Sources — нет
