# Worker verification — 2026-10-21

Implementation frozen for root build/review. No commits, pushes, installs, real user-state edits or signals to agent processes by this worker.

## Changes and contracts

- `RunningProcesses.codexSnapshot()` scans only current-uid PIDs with libproc, caps at 16,384 entries, marks truncation/errors unknown, reads process name/tty/start time (no argv). `CodexSnapshot.presence(of:)` ignores snapshots older than the observed hook file. A same-second process birth is conservatively allowed because hooks stamp whole seconds. CLI terminal ownership overrides the shared daemon PID; app/IDE/exec/unknown tty/Claude keep PID behavior.
- Controller requests a background snapshot at most once per two seconds; a cached snapshot expires after five seconds.
- `SessionBoard.dismiss(key:version:persist:) throws -> Bool` saves before forgetting, compares the observed version before and after persistence, and removes all row/lead/cue/count state. The persisted version hashes sorted state JSON plus precise mtime, so identical same-second hook rewrites return the row. Key is `provider:id`.
- `SessionDismissals.load(at:)` / `save(_:at:)` store `dismissed-sessions.json`; writes use a unique mode-0600 temporary file and atomic rename. Errors propagate to visible panel text.
- UI flow: expanded row → `PanelStore.dismissSession(PanelSession)` → controller refresh/dismiss/evaluate/refresh. The action states that the chat/process stay open.
- Per D01, automatic reaping ignores that file version rather than unlinking the hook file. This prevents a concurrent hook overwrite from being deleted. The ignored file does not count toward lifecycle, influence lead or cue attention. SessionEnd remains hook-owned cleanup.

## Red evidence

Initial owner regression compiled successfully with the injected seam present but unused. `/private/tmp/stale-red-owner.log` reports:

- `FAIL a closed CLI is reaped even while the shared daemon PID is alive`
- `FAIL the closed CLI cannot lead or cue Needs you`

That first run also lacked 11 pre-existing seam fixtures before script suites had run. Its wrapper ended with `rg`, masking the model exit code; it is evidence of those named failed assertions, not a claimed failing shell exit.

A subsequent red run used `result=$?` immediately after compile/model and `exit $result`: exit **1**. `/private/tmp/stale-red-dismiss.log` reports the expected failures with stubbed owner-decision/dismissal bodies:

- `a long-lived CLI owner stays alive`
- `a reused tty cannot keep the previous session alive`
- `a complete scan without the tty owner proves exit`
- `Remove from list persists the observed version and removes its row`
- `a dismissed session cannot lead the menu bar`

It additionally reported two Node seam files not yet generated and the old expected re-read-after-reap assertion, updated for D01. Final runs used the script seams and passed all checks.

## Final commands and results

- `/usr/bin/python3 -m unittest discover -s tests -v` → exit **0**, **288 tests**, 27.297s. `/private/tmp/stale-python.log`. Isolated two older `test_mcpbar.py` LIMITS fixtures' `LIMITS_STATUS` into their temporary folders first; no real `~/.claude/control-bar` writes.
- `node --test tests/*.test.js` → exit **0**, **109 total / 108 pass / 0 fail / 1 existing todo**, 3.741s. `/private/tmp/stale-node.log`. Existing todo: Codex worker SessionStart clears explicit quit-intent; unchanged and outside scope.
- `swiftc -O Sources/Model/*.swift tests/model/main.swift -o /private/tmp/stale-model -framework Cocoa` followed by `/private/tmp/stale-model` → exit **0**, **1192 successful checks**. `/private/tmp/stale-green-full.log`. The real native positive control launches a copy of this owned test binary named `codex` on a fixture PTY; it returns normally after two seconds. An initial attempted copied `/bin/sleep` fixture was rejected by macOS, so it was replaced with the owned binary. No real agent is launched or terminated.
- `swiftc -typecheck -target arm64-apple-macos13.0 Sources/*.swift Sources/Model/*.swift -framework Cocoa -framework SwiftUI` → exit **0**, empty diagnostics. `/private/tmp/stale-typecheck.log`.
- `git diff --check` → exit **0**.
- `node tools/release/bump.js patch --date 2026-10-21` → **0.27.2** in both manifests; CHANGELOG includes the bundled limits fix from PR65.

## Remaining root-owned acceptance

Independent review, universal app/DMG build, actual app button and real orphan verification, clean-copy acceptance, install, publication and release checks. No completion claim for these from this worker.

## Ремонт D02

До исправления: exit 1, восемь ожидаемых regression failures. После: Swift model 1200 checks passed, exit 0; whole-app arm64 typecheck exit 0; diff --check exit 0. Логи: /private/tmp/stale-repair-{red,green,typecheck}.log. Закрытые версии сохраняются одной пачкой перед forget; ошибка оставляет строку и показывается в панели, повтор через 5 секунд.

## Ремонт D03

RED exit 1 на исчезнувшем tty, GREEN exit 0: 1207 model checks. Native synthetic terminal: alive→rows1; closed client→rows0; closed terminal(device missing)→rows0. Старый/неполный snapshot, malformed tty и прочие ошибки не доказывают закрытие. Логи /private/tmp/stale-tty-{red,green}.log и /private/tmp/acb-g4-native-worker/result.log.
