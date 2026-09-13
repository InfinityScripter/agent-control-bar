# Contributing

This is a fork of [claude-status-bar](https://github.com/m1ckc3s/claude-status-bar) merged with
[claude-mcp-bar](https://github.com/InfinityScripter/claude-mcp-bar), and its scope is wider
than upstream's: it shows Claude Code's live status **and** controls what Claude has to work
with. The upstream contract ("display only, one network request") does not describe this
project — this file does.

## What this app is

Three parts, deliberately separated:

- **Sessions** — hooks write one small state file per event; the app draws them. Context usage
  is computed from the transcript.
- **MCP** — a Python backend runs `claude mcp list` and a `tools/list` round trip on a slow
  timer, and switches servers/tools by editing `~/.claude/settings.json`.
- **Limits** — a five-minute poll of Anthropic's usage endpoint, plus an optional `statusLine`
  capture. OpenAI Codex's own windows are read on the same timer from the session file Codex
  writes in `~/.codex/sessions` — a local read, with no token and no request of its own.

So yes: this app *does* change machine state (settings.json, the statusLine wrapper) and *does*
make network requests (Anthropic usage endpoint, a daily update check, and it starts the user's
own MCP servers when health-checking). Every one of those is documented in
[PRIVACY.md](PRIVACY.md), reversible, and has an off switch or an uninstall path. Keep it that
way — a change that breaks any of those three properties won't be merged.

## What's welcome

Bug fixes, performance wins (measure before and after — `sample` and `ps -o time=` beat
adjectives), honest-UX improvements, compatibility fixes, tests that reproduce a real defect.
Visual polish and new animations too.

## Won't be merged

- Telemetry, analytics, or anything that sends user data to anyone other than the services
  already named in PRIVACY.md.
- Anything that costs money or needs an API key beyond what Claude Code itself has.
- Heavy work in the per-event hooks — they run on every Claude event and must write one small
  file and exit. (The slow-timer backend is where expensive work lives.)
- Undisclosed state changes: if it edits a file the user owns or opens a network connection,
  PRIVACY.md and the README must say so in the same PR.
- Support for other agents or platforms. Claude Code on macOS.

## Building

macOS 12+, Swift toolchain (Command Line Tools), Node.js, and the system `/usr/bin/python3`.

```bash
./build.sh          # -> "build/Claude Control Bar.app"
./build.sh --dmg    # also builds a .dmg
```

The build stages into a temporary bundle and swaps only on success, so a failed compile never
destroys an installed copy.

## Testing

CI runs the Python, Node and Swift suites plus a build and identity checks — `git push` tells
you most of it. But before a PR, run the app: both surfaces (desktop app and terminal CLI)
behave differently, and say which terminal you used. For visual changes attach a screenshot;
`CONTROL_BAR_DUMP_MENU=1` prints the panel as text.

The panel's layout is drawn out at full size in `docs/panel-design.html`, and the two directions
it was chosen over are in `docs/panel-directions.html` — open either in a browser. Motion has its
own spec in `docs/motion.md`.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/): `feat`, `fix`, `chore`,
`refactor`, `docs`, `perf`. Explain *why* in the body — most fixes here exist because something
was measured, and the measurement belongs in the message.

## License

MIT, same as upstream. Copyright for the original work remains with Mick Cesanek.
