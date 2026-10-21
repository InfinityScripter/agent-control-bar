# Исследование кода

База: dfbe2ae (PR65 с исправлением лимитов) поверх main 1e07d4a. Существующий dirty checkout на feat/prs-tab оставлен отдельно.
Sources/Model/SessionBoard.swift reload/tick/reap управляет sessions/mtimes/prevState/lead. На строках 106–109 живой pid полностью исключает stale prune.
Sources/Model/Sessions.swift Session содержит provider/surface/tty/pid/ts/turnID. hooks/update.js и lifecycle.js пишут process.ppid, у современного Codex это общий daemon.
Sources/Model/RunningProcesses.swift использует libproc, allPids уже содержит guard от truncation, но [] не различает ошибку и пустоту — новый probe не должен считать это доказанным отсутствием.
StatePolling.swift reloadSessions читает provider-aware файлы; evaluate удаляет reaped JSON. Новый hook при удалении/скрытии не должен потеряться.
PanelStore.swift PanelSession.id = provider:id. PanelTabs.swift Sessions card уже раскрывается; добавить Remove from list в details. Actions.swift и PanelStore дают направление UI → controller. IconRender/AppLifecycle используют board напрямую; UI-only фильтр недостаточен.
Тесты board в tests/model/main.swift около 3069, сборка через ci.yml. Python suites могут менять реальный LIMITS_STATUS если плохо изолированы.
Живая диагностика: orc-guard последний hook 12:57:31 MSK; сохранённый PID — daemon, tty /dev/ttys002 сейчас содержит только shell-процессы, запущенные позже hook. Read-only существующий daemon status active waitingOnApproval; transcript terminal boundary отсутствует, archived=0. Причина — orphaned CLI wait + неверный owner, не просто устаревший text.
ORCA commit 92bbb380a69d74a0cfcc3d0de970787cbcfd1dfc: src/shared/agent-process-presence-probe.ts (PID+startTime+unknown), src/main/agent-hooks/server/server-agent-presence.ts (guarded reaping), server-cleanup.ts (dropStatusEntry без kill + guarded versions). Local reference /private/tmp/orca-session-reference-20261021.
