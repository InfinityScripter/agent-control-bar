# Troubleshooting

**Icon nowhere to be seen, but the app is running?** Your menu bar is full. An item that does not
fit is not clipped — macOS parks it off-screen and puts it behind the `›` overflow chevron, and
from the outside that is indistinguishable from an app that failed to start. Measure instead of
guessing:

```bash
CONTROL_BAR_DIAGNOSE=1 "/Applications/Claude Control Bar.app/Contents/MacOS/ClaudeControlBar"
```

It prints the item's window frame against the screen and says which of the two it is. A real
reading from a full menu bar looks like `item window=(-1110.0, 1410.0, …) screen=(0, 0, 2560, 1440)` —
the item exists, is visible, and sits at x = −1110.

Quit any running copy first, or you are measuring a second instance that never got a slot. The
bars cost about 35pt on top of the plain icon, so freeing one text-bearing item (anything showing
a clock or a percentage) is usually enough. Cmd-drag rearranges menu bar items.

**You don't open this app, it opens itself.** The only time you launch it by hand is once, right after install, so it can wire up the Claude Code hooks. After that it starts itself whenever a Claude Code session is running and quits when none is. So opening it from Finder or Spotlight with no session active can look like it launches and immediately quits. That is expected, not a crash: just start a Claude Code session and the icon appears on its own. Upgrades self-heal: drop the new version into Applications and it refreshes its own hooks the next time it starts up. (It relaunches itself when your next session begins, and on a version change it re-runs its installer automatically, so you never run anything by hand.)

**Updated (or just installed) while Claude Code sessions were already running?** Sessions already open appear the next time they do something (a prompt or a tool call), so the panel can look empty until then. Starting a new `claude` session also works. (On 0.4.0 and earlier, a new session was the only way; update if you're seeing that.)

**Using Chat or Cowork in the desktop app?** Those don't move the icon. Claude Code Chat and Cowork don't fire the same hooks this app runs on, so there's no live signal to drive the timer or the animation. Only Claude Code sessions move it: the desktop app's Code mode, or `claude` in a terminal. You'll still see the resting spark while the desktop app is open.

**Icon stuck on "thinking" in the terminal after you interrupted?** If you press Esc or Ctrl+C during the early thinking phase, before any output has streamed, Claude Code doesn't emit a signal for the app to catch, so the icon can sit on thinking until it times out (about 15 minutes). Sending any new prompt clears it right away. This one is terminal only, and it's an upstream Claude Code quirk, covered under [Known issues](#known-issues) below.

**Icon disappeared weeks ago and never came back?** If you installed Node via Homebrew, versions before 0.4.2 wrote a version-specific Node path into the hooks, and a `brew upgrade node` broke them silently. Fixed in 0.4.2: update the app and launch it once, and the hooks repair themselves.

**`node` crashes with `Library not loaded: …/libllhttp.*.dylib` (dyld)?** Homebrew upgraded `llhttp` out from under `node` — the binary on disk is still there, but it was linked against an older `libllhttp` the Cellar no longer ships. Confirm with `node -e 'console.log(process.version)'` (same dyld error) or `otool -L "$(brew --prefix)/bin/node" | grep llhttp`. Fix: `brew reinstall node` (or `brew reinstall llhttp && brew reinstall node`). Then launch Claude Control Bar once so hook install can run under a working Node. The app skips a dyld-broken Homebrew `node` and falls through to other installs when it can find one; if Homebrew is your only Node, reinstall is required.

**Icon stuck on "thinking" in the desktop app?** If a session hits your usage limit mid-turn, Claude Code fires no hook to close it out, so the icon keeps thinking until it times out (about 15 minutes). To clear it right away, click the icon in the menu bar and press **Quit**.

**The icon doesn't appear at all?**
- Make sure a Claude session is actually running, not just a terminal window open. Start a new session (or restart Claude Code) and the bar appears automatically.
- A session that was already running *before* you installed won't show up until you start a fresh session.
- Confirm it's running with `pgrep -x ClaudeControlBar`: a number means it's running (it may just be hidden), no output means it exited because no Claude session is active.
- If first-launch setup never took, run the installer manually: `node "/Applications/Claude Control Bar.app/Contents/Resources/install.js"`. Installed as a plugin, the app lives in `~/Applications` instead.

**Codex sessions don't show up?** Codex reviews hooks it has not seen before and asks you to
trust them, once, on its own screen — and it runs none of them until you do. So: start `codex`
in a terminal, confirm the hooks named `.claude/control-bar/update.js` and `lifecycle.js`, and
the sessions appear from that moment. Two things follow from it:

- The screen comes back after an app update that changes a hook's command. Codex identifies a
  hook by a hash of the command, so a new command is a new hook to it. Confirming again is all
  it takes.
- If you declined, nothing is broken and nothing retries silently — the hooks sit in
  `~/.codex/hooks.json` unused. `codex mcp list` still works, so Codex's MCP servers show up in
  the panel either way; only its sessions depend on the hooks.

The panel says so itself: while Codex is skipping hooks of ours AND no Codex session is known,
the Sessions tab carries the line *Codex sessions hidden — approve its hooks* instead of simply
showing nothing. An empty tab and an unapproved hook look identical otherwise, which is what
sent people looking for a fault that was not there.

Check what the app sees with `/usr/bin/python3 "/Applications/Claude Control Bar.app/Contents/Resources/scripts/mcpbar.py" doctor` — it prints the newest Codex session file it found, how many Codex MCP servers it knows about, and how many of our hooks Codex has not been told to trust.

**Seeing 2 icons?** The desktop app shows its own menu bar icon (the quick-screenshot one). To avoid two icons sitting side by side, open Claude's **Settings → General** and turn that built-in menu bar item off.

**MCP checks fail with `EPERM`, or you declined "access files on a network volume"?** Both are
the same story. macOS counts FUSE mounts (arc, sshfs, some Docker setups) as network volumes, so
when a Claude Code session lives on one, the health check needs the "files on a network volume"
permission to look at that project's servers. The system asks exactly once — decline it and every
later check fails with `EPERM`, and macOS never asks again on its own. The panel now says this
under the failed check and offers both ways out:

- **Grant access to network volumes…** opens System Settings → Privacy & Security → Files &
  Folders — enable Claude Control Bar there; or
- copy the **Ask again** command (`tccutil reset SystemPolicyNetworkVolumes <bundle id>`), run it
  in a terminal, and the original permission dialog returns on the next check.

---

## Knobs and diagnostics

None of these have a UI; they exist for someone who wants a different number.

- `~/.claude/control-bar/uiconfig.json` — panel layout, read on every open, no rebuild needed. One key survives the panel: `boxWidth` (the panel's width, default 300). The row-geometry keys (`nameMax`, `pillInset`, `timerGap`) described the old hand-laid-out menu row and do nothing now — the panel lays its rows out and truncates by pixel. Example: `{"boxWidth": 340}`.
- `defaults write io.github.infinityscripter.claude-control-bar hideIdleAfter -int 1800` — how long, in seconds, a resting session stays in the panel (default 900; 0 keeps every row). Render-only: the session itself is tracked by its process, and the most recent one is always shown.
- Environment variables for the hooks and the backend: `CONTROL_BAR_DEBUG=1` logs every hook event to `control-bar/hooks.log` (capped and rotated, see [PRIVACY.md](PRIVACY.md)); `CONTROL_BAR_TTL` (seconds, default 600) is how old the MCP picture may be before `/mcp-health` re-checks; `CONTROL_BAR_LANG=en` or `ru` picks the language of that report.
- Diagnostic modes of the binary: `CONTROL_BAR_DIAGNOSE=1` (above), `CONTROL_BAR_DIAGNOSE=menu` opens the panel by itself so it can be screenshotted, `CONTROL_BAR_DIAGNOSE=toggle` replays what a click on the icon does to an open panel and prints whether it closed (the icon cannot be clicked at all when the menu bar has parked it off-screen, which is where that bug hides), and `CONTROL_BAR_DUMP_MENU=1` prints the panel as text and quits — near enough what VoiceOver would read. `CONTROL_BAR_UPDATE_NOW=1` runs the one-click update at launch without the panel (the update path can be rehearsed against a local HTTP server by seeding `latestVersion` and `latestAsset` in the app's defaults).

---

## Known issues

**Interrupting during the reasoning phase (CLI only) can freeze the icon on "thinking".** If you hit Ctrl+C while a turn is still in the extended-thinking phase, before any answer text has streamed, Claude Code writes nothing to the transcript and fires no hook, so there's no signal for the app to react to. The session sits on "thinking" until the 15-minute cap.
- Clears instantly if you type a new prompt in that session or close the terminal.
- Interrupting *after* answer text starts streaming recovers normally, within a poll.
- The desktop app is unaffected. Root cause is upstream in Claude Code, not fixable from here.

**Clicking a session brings the app forward, not the exact session.** Desktop sessions raise the Claude app rather than that specific conversation; terminal sessions raise your terminal app rather than that window or tab. Exact terminal focus needs a one-time Automation permission grant; the original project has it in a test build, this fork does not yet.

**The app launches and tracks sessions inside Cursor.** Cursor's Third-party skills feature reads the same `~/.claude/settings.json` and runs your hooks against its own agent, so Cursor sessions show up here too. Most things work (spark, timer, rows); the amber permission dot, the CLI/APP pill and click-to-focus don't, because Cursor doesn't pass those events. To turn it off, disable **Third-party skills** in Cursor's Settings → Features. Your Claude Code usage is unaffected.

---
Back to the [README](README.md).
