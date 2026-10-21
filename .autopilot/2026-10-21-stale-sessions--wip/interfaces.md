# Контракты и правила

## Границы, решённые в спецификации
- SessionBoard остаётся единственным источником состава сессий и lead/cues. Добавить injectable owner probe со значением alive/dead/unknown; unknown сохраняет текущий результат PID-проверки. Probe для Codex CLI/tty имеет приоритет над shared daemon PID. Ошибки снятия процессов не превращать в отсутствие владельца.
- RunningProcesses (libproc) получает bounded snapshot/probe для Codex CLI tty + время рождения. Кэш и частота в controller, не в UI. Не блокировать main thread fork/exec.
- Ручное действие PanelStore.dismissSession(PanelSession) → StatusController dismissal → persistence + SessionBoard. SwiftUI только инициирует действие.
- Маркер скрывает наблюдённую версию состояния (fingerprint event, не только секундный ts), хранится в app-owned state. Не удалять transcript и не посылать сигналы PID. Сохранить marker до изменения board. Новое событие снимает подавление. Ошибка записи видима пользователю.
- Конкретные сигнатуры согласует один worker всей фичи; изменения документируются в ответе INTERFACES. Минимум новых абстракций.

## Проверки
/usr/bin/python3 -m unittest discover -s tests -v; node --test tests/*.test.js; Swift model-check и seam fixture команды взять ровно из .github/workflows/ci.yml. Полный build ./build.sh --dmg. Сохранять реальные exit codes, без tail-маскирования. Один test: python3 -m unittest tests.test_<module> либо node --test tests/<file>.test.js.
Тесты изолировать от ~/.claude/control-bar (старые Python fixtures LIMITS_STATUS требуют внимания).

## Ограничения
Стек Swift + Node core + system Python; новых зависимостей нет. Идентичность только identity.env. Пользовательские AGENTS/CLAUDE не редактировать. Основной dirty checkout не трогать. Ветка этой работы codex/stale-sessions-0.27.2 в /Users/talalaev-m/.codex/worktrees/stale-sessions/claude-control-bar.
Версия в .claude-plugin manifests и Info.plist сборки совпадает; существующий tools/release/bump.js предпочтителен.
Чужую statusLine не трогать. Codex конфиги и auth-файлы не читать/писать. Никаких секретов/содержимого бесед в выводах и артефактах.
Пользователь явно разрешил новую версию, push/merge. Workers не коммитят и не публикуют; это делает root после проверок.

D01: app-side auto-reap не делает unlink, чтобы не удалить конкурентный hook. Исключённая версия не влияет на fileCount/lead; изменение файла восстанавливает normal ingestion.

D02: автоматически снятые версии также persist через SessionDismissals; новая активность не блокируется, ошибки видимы.

D03: доказанное отсутствие сохранённого tty после закрытия терминала означает dead; ошибки доступа и невалидный snapshot остаются unknown.
