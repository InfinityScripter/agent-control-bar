# Claude Control Bar

**English** | [Русский](README.ru.md)

https://github.com/user-attachments/assets/39381f85-c8ce-4d32-8baa-dce67d39ee7e

A macOS menu bar app for **Claude Code**. It shows what Claude is doing and lets you manage sessions, MCP servers and usage limits from the menu bar.

- **Sessions.** An animated icon while Claude works, a yellow dot when it waits for your permission, a turn timer and context-window usage for each session. Click a session to focus the terminal or editor it runs in.
- **MCP.** Every server and every tool has its own switch. A muted tool disappears from Claude's context at the next session start.
- **Codex too.** If you also run **OpenAI Codex**, its sessions appear in the same list as Claude's — same states, same turn timer, same context figure, same "needs you" dot — and its MCP servers in the same tab, with switches. Clicking a Codex row lands where the session can actually be read: a desktop session opens its own conversation through Codex's `codex://threads/` link, a terminal one raises its terminal. Codex asks you once to trust the hooks; until you do, its sessions stay invisible, and the panel says so rather than showing nothing. Everything is read from what Codex already writes on this machine.
- **Limits.** 5-hour and 7-day usage as bars in the menu bar; the panel lists them with reset times, plus Fable's weekly window on plans that have one. If you also use **OpenAI Codex**, its own windows appear beside Claude's — read from the session file Codex writes itself, without a token or a request.

## Install

### As a Claude Code plugin (recommended)

```bash
/plugin marketplace add InfinityScripter/claude-control-bar
```

```bash
/plugin install claude-control-bar
```

The app compiles from source on your Mac at the next session start, so you need the Xcode Command Line Tools (`xcode-select --install`). Updates arrive with the plugin.

### DMG

1. Download `claude-control-bar.dmg` from [the latest release](../../releases/latest).
2. Drag **Claude Control Bar** into Applications.
3. Launch it once to install the hooks — with no Claude session running it may quit again right away, and that's fine: the hooks are in.

> [!IMPORTANT]
> The DMG is not notarized, so macOS blocks the first launch. Open **System Settings → Privacy & Security** and press **Open Anyway**, or run
> `xattr -dr com.apple.quarantine "/Applications/Claude Control Bar.app"`.

Updates for the DMG install are one click: when a newer release is out, the panel opens with an
**Update available** card. Click it to read what changed, then **Download and install** — the
app fetches the release DMG, checks its size and SHA-256 against what GitHub advertises, swaps
itself in place and restarts. No Gatekeeper prompt the second time: the app clears the quarantine
flag from the copy it installs itself.

Pick one install channel. With both installed every hook runs twice; the app resolves the conflict in favor of the plugin, but there is no reason to keep both.

## First launch

The app lives in the **menu bar**, in the top-right corner of the screen, next to the clock. It has no Dock icon. Clicking the icon drops a panel under it; Settings (⌘,) opens a window of its own, and while that window is open the app appears in the Dock like any other, going back to icon-only when you close it. You don't open it yourself: it starts with the first Claude Code session and quits when the last one ends.

After installing:

1. **Start a new Claude Code session** — `claude` in a terminal, or a Code session in the desktop app. Sessions that were already open before the install show up only after their next prompt or tool call.
2. **Plugin channel: wait out the first build.** The first session start compiles the app from source, which takes a minute or three; the icon appears when the build finishes. If it never does, look in `~/.claude/control-bar/problems.log`.
3. **Find the crab in the menu bar.** With no session working it sleeps; it walks while Claude works, and a yellow dot means a session waits for your permission. Click the icon — the panel has two tabs, **Sessions** and **MCP**, with the usage limits pinned above both; the settings have a window of their own.

No icon?

- A DMG-installed app opened by hand **quits right away when no session is active** — designed behavior, not a crash. Launch it once so it installs its hooks, then start a session.
- A full menu bar is the most common cause: macOS parks items that don't fit behind the `›` overflow chevron, which from the outside looks exactly like "the app didn't start". Cmd-drag a few icons out of the bar to free a slot.
- `pgrep -x ClaudeControlBar` in a terminal: a number means the app is running and only the icon is hidden; no output means it isn't — start a session, or see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Usage

Sessions, limits and MCP switches live in the panel under the menu bar icon, the settings in a window of their own; the app starts and quits on its own, as described above.

### Crab mascot

**Crab Walking** is the default animation on a fresh install. The mascot changes with the number of Claude Code sessions working in parallel. Only sessions that are currently thinking or running a tool count; open but idle sessions do not.

| Working sessions | What the Crab does |
| ---: | --- |
| 0 | Sleeps |
| 1 | Relaxes with a cigar |
| 2–3 | Walks — at an easy pace with two sessions, at full tempo with three |
| 4–5 | Turns red, sways and sweats |
| 6+ | Its head catches fire |

These previews use the same runtime frames and timing as the menu-bar app:

| 0 · Sleeping | 1 · Cigar | 2–3 · Walking |
| :---: | :---: | :---: |
| ![Crab sleeping animation](assets/crab-moods/sleeping.gif) | ![Crab cigar animation](assets/crab-moods/cigar.gif) | ![Crab walking animation](assets/crab-moods/walking.gif) |
| 4–5 · Overheated | 6+ · On fire | Permission needed |
| ![Overheated Crab animation](assets/crab-moods/overheated.gif) | ![Crab on fire animation](assets/crab-moods/on-fire.gif) | ![Crab waiting for permission animation](assets/crab-moods/permission.gif) |

When a session needs permission, the Crab switches to a separate waiting scene: it holds up a sign with a question mark, then looks at the screen. A yellow warning dot stays beside it, and the status text reads `Needs you`. Once permission is handled, it returns to the state for the current number of working sessions.

The sprite is lit from the top left — a lighter rim on top, a darker one underneath — so it reads as a shape rather than a sticker at menu-bar size; in the System color it becomes a shaded monochrome silhouette. Inside a band the tempo follows the exact count: the sweating crab pants faster with a fifth session, and the fire flickers faster the more sessions burn.

Server and tool switches apply to new sessions: Claude Code assembles the tool list at session start, so sessions that are already open keep their old set.

### Settings

**Settings** at the bottom of the panel, or ⌘, — a window with five pages.

**General**

- **Timer in menu bar** — the running turn's elapsed time next to the icon. The session rows always show theirs.
- **Thinking words** — one of Claude Code's own spinner verbs ("Manifesting…") in place of "Thinking…".
- **Limits via Anthropic API** — the usage poll behind the 5h/7d bars; off means the request never happens (see [PRIVACY.md](PRIVACY.md)).
- **Codex limits** — Codex's own 5-hour and weekly windows in the strip, read from the newest file in `~/.codex/sessions`. Nothing is sent anywhere, and a figure older than the window it measures is dropped rather than shown, so the row disappears until Codex runs again. When Codex has moved you onto its **reserve** model — what it does once the ordinary limit runs out — the window says `RESERVE` rather than its length, because from then on the figure measures the reserve pool and not the limit you were watching.
- **Codex MCP servers** — Codex's own servers in the MCP tab, in their own groups, with the same switches. Asking Codex for the tool names starts each configured server the way Codex itself does, so with a slow server this is the switch to turn off.
- **Anonymous usage ping** — once a day: app version, macOS version, chip, install channel, and no identifier, so the project can count copies in use. Off means the request never happens; `CONTROL_BAR_NO_ANALYTICS=1` in the environment does the same. Exact bytes in [PRIVACY.md](PRIVACY.md).

**Appearance**

- **Animation** — Crab Walking (default), Claude Spark, or Claude Code, the terminal glyph spinner.
- **Color** — Orange, or System for an adaptive black/white icon.
- **Limits strip** — how the strip shows two providers. *Two rows* (default) stacks Claude and Codex, each under its own name and next reset. *Switcher* gives one the full width and puts the other behind a tab, with a hairline of its fullest window under the tab name. With one provider the strip is a single row either way.

**Motion** — how much the panel itself moves. *Off* stops every animation; *Subtle* (default) moves the panel, its cards and its switches; *Expressive* adds a staggered entrance for the rows in a list. macOS's own Reduce Motion is honoured on top of the choice: movement becomes a crossfade rather than nothing at all, so a change of state is still visible.

**Sounds** — two events. *When a turn finishes*: off (default), every turn, or only turns longer than 1, 5 or 15 minutes. *When Claude needs you*: a short macOS alert sound the moment a session starts waiting for your permission — Tink by default, or Purr, Ping, Glass, Hero, Submarine; picking one plays it. It stays quiet when the terminal or app hosting that session is already in front: the prompt is on your screen and you don't need to hear about it.

**Check MCP now** (⌘R) and **Open settings.json** are the two glyphs in the MCP tab's header rather than settings here — they are actions, not settings. Every server and tool switch is written to `~/.claude/settings.json`.

The app also posts a macOS notification when an MCP server goes down or comes back. If you declined notifications, a *Notifications are off* row in the panel opens the right System Settings pane.

### Slash commands

The plugin adds two commands inside Claude Code:

- `/mcp-health` — the MCP map as text: which servers answered, tool counts, what is switched off, plus the context window of every open session and the limits.
- `/limits-capture install|uninstall|status` — the optional second source for the limit bars. It wraps your `statusLine` command so the figures refresh from the payload Claude Code hands it, fresher than the API poll while a terminal session is active; `uninstall` restores the previous command exactly.

Layout knobs, `defaults write` switches and the diagnostic modes are listed in [TROUBLESHOOTING.md](TROUBLESHOOTING.md#knobs-and-diagnostics).

The Claude limit figures come from the same Anthropic usage endpoint that the `/usage` command asks. The app polls it with the OAuth token Claude Code keeps in your Keychain and sends it to `api.anthropic.com` only. The poll has an off switch in Settings → General. The Codex figures are local: Codex records its own remaining limits into the session file it keeps in `~/.codex/sessions`, and the app reads the newest one — no token, no request, nothing sent. [PRIVACY.md](PRIVACY.md) lists every file the app writes and every request it makes.

## Requirements

- macOS 13+
- [Claude Code](https://claude.com/claude-code) (CLI or Desktop app)
- Node.js and the system `/usr/bin/python3`
- Xcode Command Line Tools for the plugin channel (it compiles the app locally); the DMG doesn't need them

## Uninstall

Installed as a plugin: run `/plugin uninstall claude-control-bar`, then drag `~/Applications/Claude Control Bar.app` to the Trash.

Installed from the DMG:

```bash
node "/Applications/Claude Control Bar.app/Contents/Resources/uninstall.js"
```

The script removes the hooks; after that drag the app to the Trash. State lives in `~/.claude/control-bar/`.

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Acknowledgements & license

The project grew out of [claude-status-bar](https://github.com/m1ckc3s/claude-status-bar) by Mick Cesanek, merged with [claude-mcp-bar](https://github.com/InfinityScripter/claude-mcp-bar). Contributors are listed in [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).

MIT, see [LICENSE](LICENSE). This is an unofficial project with no affiliation to Anthropic. "Claude" is a trademark of Anthropic, used nominatively.
