---
description: Проектные отклонения от стандартного стиля — Swift-модели, Node-хуки, Python-скрипты
paths:
  - "Sources/**/*.swift"
  - "hooks/**"
  - "scripts/**/*.py"
  - "tests/**"
alwaysApply: false
---

# Код-конвенции

## Контекст

Хуки и Swift-модели читают/пишут файлы состояния друг друга (`state.d/*.json`,
`mcp.json`, `model-windows.json`) без общей схемы или общего рантайма — только
формат JSON на диске. Отклонения ниже существуют, чтобы эта граница не ломалась
молча: trapping-конверсии, необработанные ошибки или чужой пакетный менеджер
здесь роняют не тест, а бегущий процесс пользователя.

## Правила

1. **Состояние сессий/серверов моделируй как `struct` + init(json:) с safe-дефолтами, движок состояния — отдельный `final class`.** Модель не тянет UI и легко проверяется отдельно от `main.swift`.
2. **Статусы — строки-перечисления ("ok"/"failed"/"pending"/"off", "idle"/"thinking"/"tool"/"permission"), не Swift `enum`.** Значения приходят из JSON, который пишут Node/Python; строка не требует синхронной ревалидации enum на обеих сторонах при добавлении нового статуса.
3. **Double → Int только через `clampedInt` (SafeInt.swift), никогда `Int(someDouble)` на данных из файла.** JSON на диске может быть руками испорчен или устареть; трапящая конверсия кладёт процесс, а не рисует неверное число.
4. **Комментарии объясняют «почему», а не пересказывают код.** Здесь это единственный канал передачи причины решения между Swift/Node/Python — общего issue-трекера по коммиту нет.
5. **Node-хуки: только `node:*` (fs, os, path, child_process), без npm-зависимостей.** Хуки исполняются на машине пользователя при каждом событии Claude Code; лишняя зависимость — лишняя точка отказа установки.
6. **Чтение JSON в хуках — `try/catch`, возвращающий `null`/дефолт, не проброс исключения.** Хук, упавший на повреждённом файле состояния, обрывает событие Claude Code (prompt/tool), а не только своё обновление статуса.
7. **Python-скрипты запускаются системным `/usr/bin/python3`, без venv/pip-зависимостей.** Хук стартует в SessionStart на чужой машине без подготовленного окружения — venv там взять неоткуда.
8. **Запись файлов состояния в Python — атомарно: `os.open(tmp, O_WRONLY|O_CREAT|O_TRUNC, 0o600)` + `os.replace`, каталоги `0o700`.** Домашний каталог на macOS открыт группе `staff`; state.d читают конкурентные хуки — недописанный файл не должен быть виден другим читателем.
9. **Хуки идемпотентны: повторный запуск на том же состоянии не должен давать другой результат.** Одно и то же событие (SessionStart на resume, PostToolUse) может прилететь дважды или гонкой с другим хуком того же события.
10. **PATH в `hooks.json` фиксирован строкой `"/opt/homebrew/bin:/usr/local/bin${PATH:+:$PATH}"`, не полагаться на PATH хоста.** Claude Code запускает hook-команду без гарантии, что `node` уже в PATH пользовательского шелла.
11. **Длинный текст во SwiftUI-вьюхе — типизированная константа (`private static let x: String = "…" + "…"`), а не цепочка `"…" + "…"` внутри `Text(...)`/`Label(...)`.** Там каждый `+` между литералами умножает перегрузки, которые перебирает type checker, вместе со всем остальным `body`: Swift 6.0.3 сдался на `GeneralSettings.body` («unable to type-check this expression in reasonable time»), а CI на своём более новом компиляторе это принял. Плагин собирает приложение компилятором пользователя, поэтому такое падение — это приложение, которое у него не собирается вовсе. Страхует задача `swift-6-0` в `ci.yml`.

## Примеры

НЕПРАВИЛЬНО:
```swift
self.pid = o["pid"] as! Int32
```
ПРАВИЛЬНО (Sessions.swift):
```swift
self.pid = Int32(truncatingIfNeeded: (o["pid"] as? NSNumber)?.intValue ?? 0)
```
Файл состояния пишет отдельный процесс (Node-хук); принудительный каст на неожиданном типе валит модель на входе, а не деградирует значение.

НЕПРАВИЛЬНО:
```swift
enum ServerState { case ok, failed, pending, off }
```
ПРАВИЛЬНО (MCPModel.swift):
```swift
var state: String   // ok | failed | pending | off | unknown (remote project server, unprobed)
```
`state` пишет `scripts/mcpbar.py`, а не Swift-код; строка не требует держать перечисление в двух языках синхронно при появлении нового статуса.

НЕПРАВИЛЬНО:
```swift
let n = Int(someDouble)  // fatal error на NaN/переполнении
```
ПРАВИЛЬНО (SafeInt.swift):
```swift
let n = someDouble.clampedInt  // NaN → 0, за границами Int → clamp к границе
```
Double приходит из JSON на диске, который может быть повреждён или отредактирован руками; крашнутый процесс самозапускается заново и падает в тот же краш-луп.

НЕПРАВИЛЬНО:
```js
const data = JSON.parse(fs.readFileSync(file, "utf8")); // бросает на битом файле
```
ПРАВИЛЬНО (update.js:47):
```js
const readJSON = (file) => { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; } };
```
Необработанное исключение в хуке обрывает само событие Claude Code (PreToolUse/Stop), а не только чтение одного файла состояния.

НЕПРАВИЛЬНО:
```python
with open(path, "w") as fh:
    json.dump(data, fh)  # не атомарно, права по умолчанию (0644 при обычном umask)
```
ПРАВИЛЬНО (bootstrap.py:87-91):
```python
os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
tmp = f"{path}.{os.getpid()}.tmp"
with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as fh:
    json.dump(data, fh, ensure_ascii=False)
os.replace(tmp, path)
```
Каталог состояния общий для всех локальных пользователей машины (`staff`-группа); неатомарная запись оставляет окно, где параллельный хук читает наполовину записанный файл.
