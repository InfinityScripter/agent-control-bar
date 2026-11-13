# ORCA: проверенные первичные источники

Изучен stablyai/orca commit 92bbb380a69d74a0cfcc3d0de970787cbcfd1dfc (21 октября 2026).

- PID + startTime, zombie и tri-state unknown: https://github.com/stablyai/orca/blob/92bbb380a69d74a0cfcc3d0de970787cbcfd1dfc/src/shared/agent-process-presence-probe.ts#L44
- Проверка актуальности записи перед очисткой: https://github.com/stablyai/orca/blob/92bbb380a69d74a0cfcc3d0de970787cbcfd1dfc/src/main/agent-hooks/server/server-agent-presence.ts#L98
- Удаление статуса без остановки агента и без очистки resume: https://github.com/stablyai/orca/blob/92bbb380a69d74a0cfcc3d0de970787cbcfd1dfc/src/main/agent-hooks/server/server-cleanup.ts#L39
- Защита от удаления более новой версии: https://github.com/stablyai/orca/blob/92bbb380a69d74a0cfcc3d0de970787cbcfd1dfc/src/main/agent-hooks/server/server-cleanup.ts#L66
- Проверка подтверждённого PTY exit: https://github.com/stablyai/orca/blob/92bbb380a69d74a0cfcc3d0de970787cbcfd1dfc/src/main/runtime/pty-exit-agent-status-reconciliation.spec.ts#L42
- Настоящий close процесса требует успешного connection.close отдельно от dismiss: https://github.com/stablyai/orca/blob/92bbb380a69d74a0cfcc3d0de970787cbcfd1dfc/src/main/codex/codex-structured-session-close.ts#L72

ORCA владеет PTY и может закрывать своё соединение. Control Bar наблюдает чужие процессы и не должен завершать общий daemon. Переносим проверку настоящего владельца с временем рождения, unknown != exited, guarded dismissal. Код ORCA не копируется; тесты ORCA не запускались, сравнение по исходникам.
