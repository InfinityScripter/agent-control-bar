# Privacy

Claude Control Bar keeps no data about you and runs no account or cloud service. Everything it
shows happens on your Mac. The one thing it sends the developer is a daily count of one, with
nothing in it that names a machine — described in full under "The anonymous ping" below, with
the switch that stops it.

## Network

- **A usage poll to `api.anthropic.com` every five minutes**, authenticated with the OAuth token
  Claude Code keeps in your Keychain. It returns your 5-hour and 7-day limit percentages — the
  same numbers `/usage` shows — and nothing else is asked for or stored. The token is sent to
  Anthropic and to no other host: the request refuses redirects outright, so a `30x` answer from
  the endpoint, a proxy or a future move of the API cannot carry the token to another origin —
  it is reported as a failed poll instead. Switch **Limits via Anthropic API** off in Settings → General and
  this request never happens.
- **One update check a day**: a request to GitHub's public releases API for the latest tag, and
  one to Homebrew's public formulae API for the current cask version. Both only decide whether
  the panel shows an update banner.
- **The update itself, when you ask for it**: clicking *Download and install* in the panel's
  "What's new" window downloads that release's DMG from GitHub (or its source archive, built
  locally, for a release that shipped without a DMG). This request only ever happens on that
  click — the daily check above never downloads anything.

GitHub, Homebrew and Anthropic see that a request arrived; the developer never does. Those, and
the ping in the next section, are the only requests the app makes for itself. There is no crash
reporting and no analytics kit of any kind in the binary.

## The anonymous ping

Once a day the app tells the project it exists, so there is an answer to "how many people use
this". That is the entire purpose, and the ping is shaped so it can answer nothing else.

- **What is sent.** One `POST` of exactly this, to `ccb-ping.infinityscripter.workers.dev` —
  the project's own receiver, a Cloudflare Worker whose source is in `tools/analytics/` and
  whose address is the `endpoint` constant in `Sources/Model/AnalyticsPing.swift`:

  ```json
  {"v":1,"app":"0.13.0","os":"15","arch":"arm64","channel":"brew"}
  ```

  The app version, the macOS major version, the CPU architecture, and which of the three
  install channels this copy came through. Each field is a value shared by thousands of Macs.
- **What is not sent.** No identifier of any kind: no install UUID, no hardware id, no
  hostname, no user name, no locale, no time zone, no minor OS version, no Mac model. Two
  pings from the same machine cannot be told from two pings from two machines, which is what
  makes the count a count and not a history.
- **What the receiver keeps.** One row per ping with those four fields and a timestamp, for 90
  days. The Worker never reads the request's IP address, sets no cookie, and has request
  logging switched off; the request itself is made from a fresh session with no cookie jar, so
  nothing the server could set would ride along on the next day's ping. Redirects are refused
  outright, the same way the limits poll refuses them.
- **When.** Not on first launch: the first launch posts a notification saying the ping exists,
  and the first ping is a full day later, so there is time to switch it off before anything is
  sent. After that, at most one a day, counted from the last attempt.
- **Off.** Settings → General → *Anonymous usage ping*. Or set `CONTROL_BAR_NO_ANALYTICS` in
  the app's environment (any value), which wins over the setting, the way `HOMEBREW_NO_ANALYTICS`
  does for brew. Either way the request never happens. A build whose endpoint constant is empty
  sends nothing and shows no switch.
- **Why opt-out and not opt-in.** An opt-in count of a menu bar app measures how many people
  open Settings, not how many use the app. Homebrew's analytics work the same way, with the same
  three protections: no identifier in the payload, no IP stored, a notice before the first
  event. If any of these three ever changes, this page changes first and the version's
  changelog says so.

One indirect kind of traffic is worth naming: the MCP health check runs `claude mcp list` and a
`tools/list` round trip, which **starts your configured MCP servers** — every ten minutes, and
after a toggle. A remote (HTTP/SSE) server sees a connection each time; a corporate one may log
it; a stdio server runs briefly as a local process. That is your own configuration doing what it
does when a session starts, but the app is what triggers it on a schedule.

One boundary inside that: this app never runs a command out of a project's own `.mcp.json`. That
file arrives with the repository rather than from you, and Claude Code asks once before trusting
it. Instead of reading the file and starting things itself, the app runs `claude mcp list` in
that project and takes the answer — so whether a server may start is decided where your approval
is recorded, not here. Cloning a repository and opening it cannot make this app execute anything
out of its config.

## What it reads on your machine

Showing what Claude is doing means reading a few things that belong to you. None of it leaves the
Mac, and all of it is listed here rather than left to be discovered.

- **Session transcripts** (`~/.claude/projects/**/*.jsonl`). Two reasons. The context percentage
  is computed from the token counts the transcript records, since Claude Code hands that figure
  to a `statusLine` command and to nothing else. And the last few KB are parsed for the interrupt
  marker Claude Code writes when a turn is cut short, which is how the app notices a turn that
  ended without an event. Both read the file; neither copies it anywhere.
- **The `statusLine` payload**, if you installed the limits capture. The wrapper receives the JSON
  Claude Code hands your status line command — which includes your usage limits and the model
  name — takes the two percentages and the context window size, and passes the bytes on unchanged.
  The rest is not stored. Undo with `/limits-capture uninstall`.
- **`~/.claude/settings.json`**, to read and write which MCP servers and tools are switched off.
  A backup is taken the first time, at `settings.json.bak-control-bar`, and a dated one before
  every switch — see "Where it writes".
- **`~/.claude.json`**, for the list of configured MCP servers and how to start each one. That
  file also holds the `env` block of every server, which is where API tokens live if you put them
  there. It is read to launch a server and ask it for its tools, and nothing out of it is copied,
  logged or shown — but it is read, and a file with your tokens in it deserves saying out loud.
- **Your MCP servers**, via `claude mcp list` and a `tools/list` request to each. That returns
  tool names, descriptions and parameters — the same information Claude Code itself receives.
- **Claude Code's own MCP logs** (`~/Library/Caches/claude-cli-nodejs/**/mcp-logs-*`), for the
  tool count each server prints when it starts. Only that number is taken.
- **Claude desktop's session cache** (`~/Library/Application Support/Claude/claude-code-sessions`),
  for the tool list of your claude.ai connectors: they report nothing at startup, so this is the
  only place their schemas exist locally.
- **Your Claude Code OAuth token**, if the Anthropic limits poll is switched on (Settings → General → "Limits
  via Anthropic API"). Read from the login Keychain entry, or from `~/.claude/.credentials.json`
  where there is no Keychain. It is sent to `api.anthropic.com` and nowhere else, is never
  written to disk by this app, and never appears in a log. Switch the option off and it is not
  read at all.
- **Codex's own session files** (`~/.codex/sessions/**/rollout-*.jsonl`), if the Codex limits
  option is on (Settings → General → "Codex limits"). Codex records a snapshot of how much of
  your OpenAI limits is gone every time the model answers, and the newest file is read from its
  end for exactly that: two percentages, how long each window is, and when each resets. The
  conversation itself is not parsed, nothing is copied, and no request is made — the figures are
  already on disk. Switch the option off and the directory is not opened at all. Your
  `~/.codex/auth.json` is **not** read: this app never asks OpenAI anything on your behalf.
- **Codex's hook payloads and the head of its session file**, once you have trusted the hooks
  Codex finds in `~/.codex/hooks.json`. A Codex hook hands over the same shape Claude Code's
  does — session id, working directory, the tool about to run, the path of its session file —
  and the file's FIRST line is read once per session for two facts: which surface it runs on and
  whether the thread is yours or one of its workers. The rest of the file is read only from its
  end, and only for numbers (the token counts and the limit snapshot). The conversation is never
  parsed, nothing is copied out, and nothing is sent anywhere.
- **Codex's MCP configuration**, if that option is on (Settings → General → "Codex MCP
  servers"): the server list comes from `codex mcp list --json` and `codex mcp get --json`, and
  the tool names from Codex's own app-server — which starts each configured server to ask it, the
  way Codex does itself. Nothing leaves the machine, and `~/.codex/config.toml` is never parsed
  by this app.
- **The current directory and git branch** of each session, to label its row.

## Where it writes

Everything of its own lives under `~/.claude/control-bar/`. The complete list:

- **Per session:** one small JSON file in `state.d/` (state, working directory, transcript path,
  pid, context figures), and the context percentage the session's status line reported in
  `context.d/`. Both are deleted with the session. A Codex session's file is the same shape, in
  `codex/state.d/`, plus which surface it runs on.
- **The MCP picture:** `mcp.json`, `codex/mcp.json` for Codex's servers, the per-server
  descriptions cache `descriptions.json`, and the model-to-context-window table
  `model-windows.json`.
- **The limits:** `limits.json`, and `codex/limits.json` for the Codex windows — percentages,
  window lengths, reset stamps and the plan name, and nothing else out of the Codex session.
- **Install bookkeeping:** `owner.json` (which channel owns the hooks), `paths.json` (where the
  backend script and interpreter are), a copy of the hook scripts and the build script, and
  `releases/` with the source archives a plugin-channel update downloaded.
- **Markers and locks:** `quit-intent` (a Quit from the panel, so the hooks do not relaunch the app),
  `self-heal-probed` (an empty file whose date throttles the hooks' "is the app running" check),
  and `refresh.lock`, `settings.lock`, `build.lock` while the matching operation runs.
- **The statusLine capture, if installed:** `statusline-saved.json` (your previous `statusLine`
  object, whole, so `/limits-capture uninstall` can restore it), `statusline-inner-command` and
  `statusline-installed.json`.
- **Logs:** `problems.log`, a breadcrumb per failure the app has nowhere else to show (the
  README sends you there when the icon never appears); and `hooks.log`, only with the debug
  switch described below.

The one exception is next door: every switch takes a dated backup of your settings beside the
original, at `~/.claude/settings.json.bak-control-bar-<date>-<microseconds>`. The name carries
the app's own prefix so the rotation has a boundary: the ten most recent of these are kept and
older ones are deleted, while backups made by you or by any other tool are never touched. They
carry the same permissions as the file they copy, because a backup of a secret is still the
secret.

That directory is kept readable by you alone — `0700` on the folders, `0600` on the files, checked
and corrected on every refresh rather than only at install. A macOS home folder is readable by the
group `staff`, which is every local account on the machine, so files left at the usual `0644`
would have handed your working directories, transcript paths and account limits to any other user
of the same Mac.

With `CONTROL_BAR_DEBUG=1` set — off by default — the hook also appends a line per event to
`control-bar/hooks.log`, including the first 160 characters of the event's `message` field. That
can contain fragments of what you typed, so the file is capped and rotated rather than grown
forever, and it is worth deleting when you are done debugging.

## What that means for trust

Once installed, the hook scripts in `~/.claude/control-bar/` run on every Claude Code event. That
is how the app knows anything at all, and it makes those files trusted local code — worth keeping
in a directory only you can write to.

---
Back to the [README](README.md).
