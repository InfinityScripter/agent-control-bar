# 03 — Вход в Claude Code одной кнопкой из панели

**Требования:** R03, R03.1, R03.2
**Зависит от:** 02
**Зона:** `scripts/mcpbar.py` (`claude_login`, `STRINGS`, диспетчер) · `tests/test_mcpbar.py` · `Sources/Model/BackendCommand.swift` · `Sources/Actions.swift` · `Sources/PanelStore.swift` · `Sources/PanelView.swift` · `Sources/main.swift` · `tests/model/main.swift` · `CHANGELOG.md` · `PRIVACY.md` · `README.md` · `README.ru.md`
**Волна:** 3
**Ревью:** да — вход и доступ (запуск команды входа в аккаунт из приложения)
**Модель:** сильная

## Что должно заработать

В блоке «Claude Code is not signed in» появляется кнопка «Sign in to Claude Code». Нажатие открывает Terminal, где уже запущена команда входа Claude Code; пользователь проходит вход в браузере. Если бинарь `claude` не найден, Terminal говорит об этом словами и ждёт клавишу, а не закрывается с ошибкой. После входа цифры появляются без перезапуска приложения: следующее открытие панели опрашивает сразу, таймер — не позже пяти минут.

## Из брифа, дословно

> «Нужно это делать все на автомате, а не руками»

> «Можешь новые прямо функции добавлять. Я не против.»

## Разделы спецификации

Истории 15–17; Решения по реализации — команда `claude-login`; `interfaces.md` — контракт `claude-login.command`, `BackendCommand.claudeLogin`, `PanelStore.signInClaude`, `StatusController.signInClaude`.

## Критерии приёмки

- [ ] `mcpbar.py claude-login` пишет `~/.claude/control-bar/claude-login.command` с правами 0700: при найденном бинаре — `exec "<путь>" auth login`; иначе печать «Claude Code CLI not found. Install it, then run: claude auth login» и ожидание клавиши; затем вызывает `/usr/bin/open <файл>`; ответ `login.opened`/`login.missing`, код 0 — проверено тестами с подменой `find_claude` и `subprocess.run`
- [ ] `BackendCommand.claudeLogin.arguments == ["claude-login"]`, слово в `backendGolden`
- [ ] кнопка видна только когда `LimitsNotice.offerSignIn == true`; нажатие → `PanelStore.signInClaude()` → `StatusController.signInClaude()` (`Actions.swift`) → `runQuietCommand(.claudeLogin)` и сброс `lastLimitsPoll = 0`
- [ ] вьюха не запускает `Process` и не пишет файлы сама
- [ ] тесты Python, Node, Swift-модель зелёные; `swiftc -typecheck` проходит
- [ ] `CHANGELOG.md` `### Added`; `PRIVACY.md` — файл `claude-login.command` и что он делает; `README.md`/`README.ru.md` — одна фраза про кнопку
