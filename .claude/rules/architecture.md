---
description: Направление зависимостей между тремя слоями (Node-хуки, Python, Swift UI) и владельцы файлов состояния
paths:
  - "Sources/**"
  - "hooks/**"
  - "scripts/**"
alwaysApply: false
---

# Слои и владельцы файлов состояния

## Контекст

Проект состоит из трёх независимых слоёв: Node-хуки (`hooks/install.js`, `uninstall.js`, `update.js`, `lifecycle.js`), Python-скрипты (`hooks/bootstrap.py`, `hooks/statusline.py`, `scripts/mcpbar.py`) и Swift UI (`Sources/*.swift`). Между слоями нет прямых импортов — обмен данными идёт только через JSON-файлы в `~/.claude/control-bar/`. Единственный межпроцессный вызов — Swift спавнит `mcpbar.py` как `Process` в `runBackend()` (`Sources/main.swift`, комментарий «the script writes mcp.json and the model re-reads it») и не парсит его stdout: скрипт пишет `mcp.json`, модель Swift перечитывает файл. Если это направление нарушить, слои начинают требовать друг у друга знания о внутреннем устройстве — ровно то, чего дизайн избегает.

## Правила

- Обмен между Node-хуками, Python и Swift — только через JSON-файлы в `~/.claude/control-bar/`. Прямых импортов между слоями нет и быть не должно.
- Единственный разрешённый межпроцессный вызов — Swift спавнит `mcpbar.py` как процесс и не читает его stdout как источник данных; результат — только через файл `mcp.json`.
- Python не читает чужой `.mcp.json` проекта (`mcpbar.py:393-395`) — это конфиг Claude Code, а не файл состояния control-bar.
- Swift не пишет `mcp.json`, `limits.json`, `codex/mcp.json` и `codex/limits.json` напрямую — эти файлы формирует только `mcpbar.py` (и `statusline.py` для `limits.json`). Исключение: Swift удаляет `state.d/*.json` мёртвых процессов в `evaluate()` (`main.swift`, `FileManager.removeItem` при `dead == true`) — это намеренная garbage collection, не запись состояния.
- `limits.json` — файл с двумя писателями (`capture_limits` в `hooks/statusline.py` и команда `limits` в `scripts/mcpbar.py`) и `model-windows.json` — тоже с двумя (`hooks/statusline.py` и `scripts/mcpbar.py`; `hooks/update.js` его только читает); формат между писателями согласован намеренно, оба должны сохранять совместимость при правке.
- `uiconfig.json` правит только пользователь вручную — в кодовой базе писателя нет, только чтение в `main.swift`. Не добавлять код, который пишет в этот файл.
- Хуки (Node, Python) хардкодят identity-значения (bundle id, exec, app name) намеренно, а не читают `identity.env` — после копирования хуков в целевой проект `identity.env` недоступен. Это гвардит CI (`ci.yml:62-95`), не забытая интеграция.
- Внутри Swift-слоя: `main.swift` — единственный владелец путей и жизненного цикла приложения. Модели (`MCPModel`, `Sessions`, `DesktopSessions`, `RunningProcesses`, `Changelog`, `HookInstall`) — чистые структуры/парсеры без побочных эффектов на файловую систему помимо своего файла.
- Контракт `install.js` → Swift — код выхода, а не текст: 0 значит «хуки на месте» (записаны, уже актуальны или ими владеет плагин), любой другой — «не установлены», 75 — `settings.json` поменялся во время записи. `checkHooks()` в `main.swift` читает, как завершился процесс, показывает причину в панели и в Settings и повторяет попытку по таймеру. Путь установщика, который ничего не записал, не должен выходить с 0 — иначе Swift снова примет отсутствие хуков за успех, как раньше принимал за успех node, упавший ещё в dyld.
- Панель (`PanelView`, `PanelTabs`) читает только `PanelStore`, а тот — только снимок, собранный в `PanelData.swift` из `StatusController`. SwiftUI-вьюхи не обращаются к `MCPModel`, `Sessions` и файлам состояния напрямую: односторонний поток «файлы → StatusController → снимок → вьюха» и есть причина, по которой панель можно перерисовывать 2.5 раза в секунду, не боясь, что она сама что-то поменяет.
- Обратное направление — только через методы `PanelStore` (`setServer`, `setTool`, `openSession`, …), которые зовут `StatusController`. Вьюха не запускает `Process` и не пишет файлы.

## Контракты файлов состояния

| Файл | Канонический писатель |
|---|---|
| `state.d/<id>.json` | `hooks/update.js` (Swift только удаляет файлы мёртвых процессов в `evaluate()`, `main.swift`) |
| `mcp.json` | `scripts/mcpbar.py` (refresh) |
| `limits.json` | `capture_limits` в `hooks/statusline.py` и команда `limits` в `scripts/mcpbar.py` (двойной писатель, формат согласован) |
| `codex/state.d/<session_id>.json` | `hooks/update.js --provider codex` и `hooks/lifecycle.js --provider codex` — та же форма, что у `state.d/`, плюс поля `provider` и `surface`. Отдельный каталог, а не общий: у Claude-контракта свои правила reap, и чужой файл в `state.d/` вычистили бы по ним. Swift удаляет файлы мёртвых процессов через `statePath(of:)` (`main.swift`) — путь считается из провайдера сессии, а не из ключа словаря |
| `codex/mcp.json` | `scripts/mcpbar.py` (команда `codex-mcp refresh`) — единственный писатель; данные берёт у самого Codex (`codex mcp list --json`, `codex mcp get --json`, `mcpServerStatus/list` через `codex app-server`), а не из его `config.toml`: в системном python 3.9 нет `tomllib`, и разбирать чужой TOML со слоями руками — та же ошибка, которой скрипт избегает для `settings.json`. Форма файла совпадает с `mcp.json`, чтобы `MCPModel` читал оба одним парсером |
| `~/.codex/config.toml` | **не наш файл**: переключатели серверов и инструментов Codex пишет сам Codex через `config/batchWrite` у `codex app-server` (`codex_config_write` в `mcpbar.py`). Своего TOML-писателя не заводить — комментарии, форматирование и чужие таблицы должен сохранять владелец файла |
| `~/.codex/hooks.json` | `hooks/install.js` (мерж, чужие хуки не трогает) и `hooks/uninstall.js` (снятие только при полном удалении, не при `--hooks-only`). Доверие к хукам (`[hooks.state]` в `config.toml`) выдаётся только нажатием пользователя — в самом Codex или кнопкой приложения (`mcpbar.py codex-hooks approve`), никогда при запуске. Пишет его сам Codex через `config/batchWrite`, хеш берётся из его `hooks/list`: свой хеш не считать, чужие хуки не одобрять |
| `codex/limits.json` | `scripts/mcpbar.py` (команда `codex-limits`) — единственный писатель; читает снимки из чужих файлов `~/.codex/sessions/**/rollout-*.jsonl` и наружу отдаёт только факты (пул, проценты, длительность окна, момент сброса, момент замера), а подписи окон собирает Swift. Файл — не копия последнего снимка, а последний замер **по каждому пулу**: сессия, ушедшая на резерв, перестаёт присылать обычные окна вовсе, и без этой памяти они пропадали из панели вместе со сроком своего сброса |
| `owner.json` | `hooks/install.js` |
| quit-intent | Swift: `quit()` и `restartIntoInstalledCopy()` в `main.swift` |
| `model-windows.json` | `hooks/statusline.py` (`learn_window`) и `scripts/mcpbar.py` (двойной писатель; `hooks/update.js` только читает) |
| `context.d/` | `hooks/statusline.py` |
| `paths.json` | `hooks/bootstrap.py` |
| `uiconfig.json` | нет писателя в коде — правит только пользователь; Swift читает в `main.swift` |

## Примеры

НЕПРАВИЛЬНО: Swift напрямую пишет запись в `mcp.json` после получения данных о сервере — теперь у файла два независимых писателя с несогласованным форматом, и `mcpbar.py` может затереть изменения Swift при следующем запуске.
ПРАВИЛЬНО: Swift спавнит `mcpbar.py` (`runBackend()` в `main.swift`) и ждёт, пока тот перезапишет `mcp.json`, затем перечитывает файл — единственный писатель, формат не расходится.

НЕПРАВИЛЬНО: `mcpbar.py` читает `.mcp.json` проекта, чтобы получить список серверов в обход штатного пути.
ПРАВИЛЬНО: `mcpbar.py` не трогает `.mcp.json` проекта (`mcpbar.py:393-395`) — это конфиг Claude Code, а не файл состояния control-bar; данные о серверах идут через собственный `mcp.json` слоя.
