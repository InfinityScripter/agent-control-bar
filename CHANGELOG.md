# Changelog

All notable changes to Claude Control Bar are documented here. This project follows
[Semantic Versioning](https://semver.org/).

Entries up to and including 0.4.3 belong to
[claude-status-bar](https://github.com/m1ckc3s/claude-status-bar), the project this was forked
from, and are kept so the history reads continuously.

## [0.19.0] - 2026-09-17

### Changed
- **Codex's hooks can be approved from the app.** Codex runs no hook it has not been told to
  trust, and the only way to approve this app's eight was Codex's own review screen — which the
  desktop app does not put in front of you: its Settings → Hooks lists hooks only for projects
  open in it, and with none open it reads *No hooks found*. **Approve** in the panel's Codex block
  and in Settings → Codex, and **Install hooks again** in Settings → About, now approve them.
  Only on a click, never at launch, and only this app's own enabled entries: Codex records the
  approval itself through the same `config/batchWrite` its own trust button sends, with the hash
  from its own `hooks/list`, so nothing is approved that its review screen would not have shown.
  A hook approved before and changed since (a new command after an update) counts as waiting too
  — Codex skips it just the same, and *Hooks approved* about it was wrong.

### Fixed
- **Every question to Codex failed on a Mac where Codex came with its desktop app.** The script
  looked for `codex` in Homebrew and `~/.local/bin`, then called `shutil.which` without importing
  `shutil`, so it died with `NameError` before asking anything — and the desktop app keeps its
  `codex` inside `ChatGPT.app`, where nothing looked. The hook-trust notice therefore never
  appeared, and Codex's MCP servers never reached the MCP tab. The app bundles are searched now,
  and a missing binary is an answer rather than a crash.

## [0.18.0] - 2026-09-16

### Added
- **Exact terminal focus: a click lands on the session's own window and tab.** Until now a click
  on a CLI session raised its terminal application, and macOS then showed whichever window was
  used last — with a handful of tabs open, reliably not the one clicked. The hooks now record the
  session's controlling tty, and the click matches it against Terminal's or iTerm's own tab `tty`:
  the only property that identifies a tab from outside, since a title is the shell's to rewrite
  and a window index moves the moment anything is dragged. Ghostty, WezTerm, kitty and Warp
  publish nothing equivalent, so they keep the old behaviour rather than getting a worse guess.
  Off by default, and the only setting in this app that is — it buys its behaviour with a macOS
  Automation permission, and a permission nobody asked for is a worse default than a click that
  lands one tab off. The app explains what is being asked for before macOS asks; saying no
  switches the setting back off and clears the decision, because macOS remembers a refusal and
  never asks again, which would otherwise leave a toggle that is on and a click that does nothing.
  Ported from claude-status-bar's `v0.4.0-beta.1`, which this fork had never carried.

### Fixed
- **A Codex session kept spinning long after its turn had ended.** The session engine read every
  transcript with Claude Code's parser, which searches for `"type":"user"` and `"type":"assistant"`
  records. A Codex rollout carries neither — measured across every rollout file on the machine
  this was found on, zero lines of each — because its format is an envelope:
  `{"timestamp":…,"type":"event_msg","payload":{…}}`. So all three of the engine's recovery nets
  were dead for Codex and only the flat timeouts were left: a session whose `Stop` hook never
  arrived kept its spinner, its live turn timer and its share of the menu bar animation for the
  full fifteen minutes, and a permission wait that had already been answered sat amber for thirty.
  Codex states the boundaries of every turn in the rollout itself, which is the better signal of
  the two — written by the agent rather than inferred — and those are now what end a turn:
  `task_complete` and `turn_aborted`, plus the `turn_*` spelling Codex's newer tracing subsystem
  uses for the same events, so a rename cannot quietly restore the fifteen-minute spinner. The
  hooks also record the `turn_id` Codex stamps on every turn-scoped event, which is what matches a
  boundary to a session exactly instead of comparing a whole-second hook clock against a
  millisecond rollout one.
- **A Codex worker thread could speak for the session it belonged to.** Codex's own hook schemas
  define `agent_id` on `PreToolUse`, `PostToolUse`, `PermissionRequest` and `UserPromptSubmit` —
  and on neither `Stop` nor `Interrupt`, the two events a turn ends with. The rollout, which is
  the net that has actually been seen to work, was read only while a session had no state file
  yet, leaving every later event with nothing but that undefined field to go on. It is now re-read
  whenever an event names a different rollout than the state file records. `SessionEnd` gets the
  same check: it does not rewrite state, it deletes the file, so a worker's end took a live
  session's row off the panel mid-turn.

### Changed
- **The Codex hook-trust notice is something you can act on.** Approving means saying yes to eight
  shell commands pointing at a script in your home folder, and the old surface was one line with
  the explanation hidden in a tooltip — which has to be hovered to be found, and which held not a
  footnote but the two things a reader needs. The panel now says how many hooks are waiting (the
  same number Codex's own review screen shows, so the two can be checked against each other), what
  to do about it, and offers to open `~/.codex/hooks.json` so the real entries can be read before
  deciding. A *Check again* button asks Codex on the spot instead of waiting for the app to notice
  by itself. Settings → Codex keeps the standing answer afterwards, where *not asked yet* is
  deliberately distinct from *all approved*. Both READMEs gain a table of what those hooks write,
  read, run and send — including the commands they run, which the hooks file itself does not show.

## [0.17.2] - 2026-09-15

### Fixed
- **The plugin takes over the hooks even when the first node it finds is broken.** Installed as
  a plugin, the app's own copy of the hooks in `settings.json` has to go on session start, or both
  sets fire on every event. The script that removes them ran with the first file named `node` that
  existed — and a Homebrew node left linked against a library an upgrade had removed died before
  reading a line, so the duplicates stayed, session after session. It now runs with the first node
  that actually starts, the same rule the app follows since 0.17.0. The ones it skips are written
  to `problems.log` once, with the reason (`Library not loaded: libllhttp.9.3.dylib`) and, for
  Homebrew's, the usual fix (`brew upgrade node`). The search is bounded, so a node that hangs
  cannot eat the time the build needs in the same session-start hook. Based on #19.

## [0.17.1] - 2026-09-15

### Fixed
- **The app builds again with Swift 6.0.** The General page of Settings wrote its two longest
  footers as chains of string literals joined with `+` inside `Text(...)`, and Swift 6.0.3 — the
  compiler in the Command Line Tools for Xcode 16.2 — gave up on that page: *unable to type-check
  this expression in reasonable time*. `build.sh` failed, and the plugin, which compiles the app on
  your Mac when there is no copy in Applications, failed the same way on every session start with
  nothing to show for it but a line in `problems.log`. The text is unchanged. CI now type-checks
  the app with Swift 6.0 too: its own compiler is newer and had accepted the page all along.

## [0.17.0] - 2026-09-15

### Fixed
- **A hook install that failed now says so, and tries again.** Every session row comes out of files
  the hooks write, and the app installed them by starting `node` and never looking at how it
  ended. When Homebrew's node broke — an upgrade that left it linked against a library the Cellar
  no longer ships — it died before reading a line of the installer, the hooks were never written,
  and the Sessions tab said *No session running* for as long as the app stayed up, with sessions
  plainly running. The installer's exit is read now. A node that does not start is skipped for the
  next one that does (nvm, Volta, asdf, your shell's), and a failure is tried again — after 30
  seconds, then every few minutes, and whenever the panel opens on an empty Sessions tab — so a
  repaired node is picked up without restarting the app.
- **Hooks that are installed but cannot run are called out.** Their commands put
  `/opt/homebrew/bin` and `/usr/local/bin` first on PATH, so a broken node there fails every hook
  even when the installer succeeded with another one. The app checks that node too.
- **An install that wrote nothing no longer passes for one that worked.** When `settings.json`
  changed between the installer's read and its write, it left the file alone — rightly — and
  exited 0, so the app believed the hooks were in place until its next launch. It exits 75 now,
  and the app tries again.

### Added
- **The Sessions tab says what is wrong with the hooks.** *Session hooks aren't installed* or
  *Session hooks can't run*, with the cause underneath — `Library not loaded:
  libllhttp.9.3.dylib`, a `settings.json` that does not parse — the usual fix when there is one
  (`brew upgrade node`), and **Try again**.
- **Settings → About → Hooks.** Whether the hooks are installed, the cause when they are not —
  selectable, for a terminal or a bug report — and a button that installs them again.

## [0.16.1] - 2026-09-14

### Fixed
- **A window that has reset no longer shows the figure it had before.** Every bar carries the
  moment its window resets, and until now nothing looked at it: the percentage kept being drawn
  as current. At a weekly rollover that meant an almost full red bar where the truth was empty —
  the largest error this app can make, made at every single reset, for up to five minutes.
  A rolled-over window now reads as empty, and the app asks for fresh figures the moment it
  notices instead of waiting out the five-minute timer, so the real number arrives in seconds.
- **Codex keeps its ordinary windows when a session moves to the reserve pool.** Once the
  ordinary limit runs out, Codex sends snapshots of the reserve pool *only* — the five-hour and
  weekly windows vanish from its session file entirely. The panel used to lose them with it and
  show a lone *Reserve* bar with no way back, not even when the five-hour window had long since
  reset. Codex limits are now remembered per pool, so the panel shows all three, and the
  ordinary session window reads as empty again once its reset has passed. The last ordinary
  reading is looked up in earlier sessions when the current one has been on reserve throughout.

## [0.16.0] - 2026-09-13

### Added
- **Codex's reserve pool is named instead of passed off as the ordinary one.** Once the ordinary
  limit is gone Codex moves the session onto its reserve model, and from that turn on the figure
  it writes down measures the RESERVE allowance — while the five-hour window it replaced sits at
  100% and is nowhere on screen. The strip was drawing that reserve figure under the ordinary
  window's name: the number was real and the label was a lie. The window now says `Reserve` and
  carries its length in the badge — the shape Fable's weekly slice already uses, which is the
  same statement: this measures one model's allowance, not the account's. Nothing in Codex's file
  distinguishes the two pools (`limit_id` arrives as "codex" for both, `limit_name` is always
  null), so what identifies the pool is the model of the turn the snapshot belongs to.
- **One amber line when Codex's hooks are still unapproved.** Codex runs only hooks a human has
  approved on its own screen, and every hook of ours writes the session file — so with the set
  unapproved nothing gets written, which is indistinguishable from "Codex is not running". The
  Sessions tab now carries *Approve Codex's hooks to see its sessions*, asked of Codex itself
  rather than guessed from its config, and shown only while no Codex session is known at all — a
  session merely resting past the hide-idle age does not get the wrong cause pinned on it.
  `mcpbar.py doctor` prints the count.

### Changed
- **Clicking a Codex desktop row opens that conversation**, not just the app. Codex registers the
  `codex://` scheme and spells one thread as `codex://threads/<id>`, which is the depth a Claude
  desktop row already had — the app is normally frontmost anyway, so raising it looked like the
  click did nothing. A terminal session is still raised where you put it, and a surface this build
  does not recognise is not assumed to be a desktop one.

### Fixed
- **Codex rows never got their surface badge, and Codex's own subagents appeared as rows of their
  own.** The hooks read the first line of the rollout to learn both facts, with an 8 KB buffer —
  and every one of the 303 rollouts on the machine this was found on opens with more than that:
  median 19 KB, largest 70 KB, all of it workspace roots and git information. `JSON.parse` got
  half an object, the catch swallowed it, and the answer was always "unknown surface, not a
  worker". So no session from 0.15.0 ever carried a `CLI`/`IDE`/`APP` badge, and the promise that
  a Codex worker never becomes a row of its own could not hold — one prompt could still show
  several rows. The ceiling is half a megabyte now, and a line that still does not fit yields no
  answer rather than a truncated one handed to the parser. Codex 0.154 also renamed the
  terminal's originator to `codex-tui`, which was in no version of the table; both spellings are
  mapped, so terminal sessions are told apart from desktop ones again — which is what the click
  above keys on.

## [0.15.0] - 2026-09-13

### Added
- **Codex sessions in the Sessions tab.** A running OpenAI Codex session now appears beside the
  Claude ones, with the same things in the row: what it is doing right now (*Running command*,
  *Editing*, *Reading*), how long the turn has been going, how full its context window is, and an
  amber dot with the "needs you" sound when it is waiting for your permission. Clicking the row
  brings its terminal to the front, as for a Claude session. The badge says which surface it runs
  on — `CLI`, `IDE`, `APP` or `EXEC` for a non-interactive `codex exec` run — read from Codex's
  own session file rather than guessed, and a `</>` glyph marks the row as Codex's.
  Two details worth knowing:
  - The context percentage comes from the figure Codex itself records, so the window size is
    exact rather than inferred from the model name — no `~` in front of the number.
  - A Codex **subagent** never becomes a row of its own. Codex runs workers as full sessions with
    their own ids and hooks; left alone, one prompt showed five running sessions.
- **Codex's MCP servers in the MCP tab**, in their own two groups — *Codex · config.toml* and
  *Codex · plugins*, because those are the two places you would go to change them. The switches
  work the same way: a server switch and one per tool, written into Codex's own `config.toml`
  **by Codex itself** (through its app-server), so comments, formatting and other tools' tables
  survive untouched. A server waiting for OAuth says `codex mcp login` instead of reading as
  broken, and the tab's own counts cover both agents. Off switch in Settings → General →
  *Codex MCP servers*: asking Codex for the tool names starts each configured server, the way
  Codex itself does, and someone with a slow server may not want that on a timer.
  **Codex will ask you once to trust the hooks** it now finds in `~/.codex/hooks.json` — that
  screen is Codex's own, and this app does not forge the approval. Until you confirm it, Codex
  sessions stay invisible.
- **Codex limits beside Claude's.** The strip can now show OpenAI Codex's own windows — its
  5-hour one and its weekly one — next to the Claude figures. Nothing is asked for and nothing
  is sent: Codex writes how much of its limits is gone into its own session file as it works,
  and the app reads the newest one. No token, no request. A snapshot older than the window it
  measures is dropped rather than drawn, so a Codex that has been quiet for a week disappears
  from the strip instead of quoting last week's percentage, and a provider with no figures is
  absent rather than shown empty. Off switch in Settings → General → *Codex limits*.
- **A choice of layout for two providers**, in Settings → Appearance → *Limits strip*. *Two rows*
  (the default) stacks both providers, each under its own name, plan and next reset. *Switcher*
  gives one provider the full width and puts the other behind a tab — and every tab carries a
  hairline bar of its provider's fullest window, so the side you are not looking at still says
  whether it is about to run out. With one provider the strip is a single row either way, which
  is what a Claude-only install has always seen.

### Changed
- **The bars beside the menu bar icon fall back to Codex** when Claude has no figures at all —
  not signed in, or the poll switched off — and they are labelled with the lengths of the
  windows they draw rather than a hardcoded 5h/7d. With Claude figures present nothing changes:
  the icon is still Claude's.

## [0.14.0] - 2026-09-10

### Added
- **An anonymous daily ping, with a switch.** Once a day the app tells the project's own
  receiver that a copy is alive: app version, macOS major version, chip and install channel,
  and nothing that names a machine — no install id, no hostname, no IP kept. The first launch
  posts a notice and the first ping waits a full day after it, so it can be turned off before
  anything is sent: Settings → General → *Anonymous usage ping*, or `CONTROL_BAR_NO_ANALYTICS`
  in the environment. PRIVACY.md has the exact payload and what the receiver does with it; the
  receiver itself is `tools/analytics/`, deployed at `ccb-ping.infinityscripter.workers.dev`.

## [0.13.0] - 2026-09-09

### Changed
- **The dropdown is a panel now, not a menu.** Clicking the icon drops a window of the app's own
  under it: the usage limits pinned across the top as three figures, then two tabs — *Sessions*
  and *MCP* — and two buttons at the bottom. The reason is not decoration. `NSMenu` cannot be
  re-laid-out while it is open, which is why `docs/motion.md` had to record that an accordion was
  impossible: clicking a server could never open its tools underneath it. In a window it can, and
  it does. The panel also keeps the width knob the menu had (`boxWidth` in `uiconfig.json`); the
  row-geometry knobs beside it (`nameMax`, `pillInset`, `timerGap`) described a hand-laid-out
  AppKit row that no longer exists, and now do nothing.
- **Two tabs instead of one long list.** Sessions is what you look at, MCP is what you change, and
  the servers list was long enough that checking a session meant scrolling past twenty rows of it.
  The limits stay visible on both, because the number worth seeing first should not be behind a
  click.
- **Four rows left the bottom of the panel.** *Check MCP now* (⌘R) and *Open settings.json* are
  the two glyphs in the MCP tab's header — they are actions about MCP, and they now sit on it.
  The version line and *What's new* moved to Settings → About. Both shortcuts still work.

### Added
- **Settings → About.** Which version this copy is, what changed in it, whether a newer one is
  out, and a *Check now* that ignores the once-a-day throttle — someone who came looking is asking
  a direct question.
- **Rows expand in place.** A chevron on a session opens the context gauge, the session totals and
  the path; one on a server opens its tool list with a switch per tool. This replaces the card
  that used to appear on hover, which existed only because a menu row could not draw outside the
  menu.

### Fixed
- **Clicking the icon could open the panel but never close it.** The click makes the menu bar's own
  window key, so the panel resigns key and closes — and only then does the button's action arrive,
  find a closed panel, and open it straight back. Caught by review rather than by use, because the
  status item on the machine this was written on is parked off-screen behind the menu bar's
  overflow chevron and cannot be clicked at all; `CONTROL_BAR_DIAGNOSE=toggle` now replays that
  exact order and prints what the panel did, which is the only way to ask on such a machine.
- **The panel's bars were a different red from the strip beside the icon.** Both use the same
  thresholds — quiet until 75%, then amber, then red — but the panel picked `.systemRed` while
  `Gauge.level` returns hand-picked sRGB values, under a comment claiming the two matched. It calls
  `Gauge.level` now. The nearly-empty floor drifted the same way: one point instead of one device
  pixel, so a 1%-left bar in the panel was twice the width of the same bar in the menu bar.
- **The diagnostic modes could never run.** `enforceSingleInstance` compared bundle identifiers,
  and a bare binary has none — so `nil == nil` matched the first other identifier-less process on
  the machine (`universalaccessd`, here) and every `CONTROL_BAR_DUMP_MENU=1` or
  `CONTROL_BAR_DIAGNOSE=1` run stood down before printing anything.

## [0.12.0] - 2026-09-09

### Added
- **A Settings window, opened with ⌘, or from the menu.** Everything that used to sit under
  *Options* now lives in a window of its own, with a sidebar of four pages — General, Appearance,
  Motion and Sounds — leaving the menu to what it is actually read for: which sessions are
  running, which servers answered, how much of the limit is gone. It is an ordinary window: it
  takes the keyboard, ⌘W closes it, and the app goes back to being icon-only the moment it does.
- **Motion, a new setting.** *Off*, *Subtle* (the default) or *Expressive*, under Settings →
  Motion. macOS's own Reduce Motion is honoured on top of the choice: movement is replaced by a
  crossfade rather than dropped, so a change of state stays visible either way.
- **The menu moves.** The hover card grows out of the row it belongs to and fades out instead of
  vanishing, its blocks arriving in reading order; the limit and context bars run up from zero;
  the row highlight fades out; the chevron leans toward its submenu and the switch knob stretches
  as it travels. All of it is one-shot Core Animation, committed once and then interpolated by the
  render server — the app does no work per frame, and none at all while the menu is closed.
- **A progress bar on the update card.** "Downloading… 43%" only changed when a new figure landed,
  so a slow network read as a hang; the bar keeps moving between the figures.

### Changed
- **macOS 13 is now the minimum, up from macOS 12.** The Settings window is built on
  `NavigationSplitView` and the grouped form style, and both start at 13. The build stays
  universal — Apple Silicon and Intel alike.
- The *Options* block is gone from the menu, replaced by a single **Settings…** row. **Check MCP
  now** (⌘R) and **Open settings.json** stay where they were: those are actions, not settings.
- The limit bars are drawn as layers instead of repainted paths. The width still comes from the
  same `Gauge.fillWidth` the strip beside the menu bar icon uses, one-device-pixel floor included,
  so the two still agree about what a small value looks like.

## [0.11.0] - 2026-09-08

### Added
- **Fable's weekly limit in the Limits section.** Plans with the model get a third row, *Fable*
  with a small *7d* badge, under the account's 5-hour and 7-day windows: the same figure and
  reset time, in the indigo the account bars never use, so it reads as the model's own slice
  of the week. The window is read from the usage endpoint's per-model `limits` list; the
  row is absent, not empty, on plans that report no such window. `/mcp-health` lists it too.

### Changed
- The Limits rows are drawn as bars instead of a line of text each: the name and figure on
  one line, a full-width capsule fill under them with the reset countdown, using the same
  honest fill as the strip beside the menu bar icon.

## [0.10.1] - 2026-09-08

### Fixed
- The *Update available* card no longer runs into the menu's rounded top corner: it sits a few
  points lower, with the same room below as before.

## [0.10.0] - 2026-09-08

### Added
- **Hovering a session shows its card.** Alongside the row, the card carries what one line
  cannot: the branch with its count of uncommitted files, the context gauge with the real
  token figures, and the session's cost, wall time and lines changed — the totals Claude Code
  reports to the status line and nowhere else. Every block appears only when its data does:
  a desktop-app session, which runs no status line, shows branch and context alone.

### Fixed
- **Clicking a desktop session opens that conversation again.** The desktop app now files
  every enabled MCP tool into a conversation's record, and with a few hundred tools the record
  passes 200 KB — the size past which the lookup skipped it, so the click fell back to merely
  opening Claude. The lookup reads only the record's head, where the id lives, and the size no
  longer matters.

## [0.9.0] - 2026-09-07

### Added
- **Updating is one click, with no toolchain.** When a newer release is out the menu opens with
  an *Update available* card. Clicking it shows what changed with a *Download and install*
  button; the app downloads the release DMG, checks its size and SHA-256 against what GitHub
  advertises, verifies the bundle's version, swaps itself in place and restarts. Progress shows
  on the card and on the button. Building from source remains the fallback for a release that
  shipped without a DMG; Homebrew installs keep their copyable `brew upgrade` line.
- The *What's new* window marks each entry with its section's glyph — a plus for additions, a
  check for fixes, sliders for changes — and renders a *Summary* paragraph when the notes carry
  one.
- `CONTROL_BAR_UPDATE_NOW=1` runs the update at launch, for rehearsing the path without the menu.

### Changed
- **A version bump is a release.** Pushing a commit that changes the version in
  `.claude-plugin/plugin.json` to `main` tags it, publishes the release with this file's
  section as the notes and attaches the DMG — no manual workflow run. A bump without its
  CHANGELOG section fails before anything is tagged.

## [0.8.0] - 2026-09-03

### Added
- **The crab has volume now.** Every frame of every mood is lit from the top left — a lighter
  rim on top, a darker one underneath, three tones from the sprite's own colour — so it reads
  as a shape at menu-bar size instead of a flat sticker; the System color gets a shaded
  monochrome silhouette out of the same pass. The mood generator's shell colour also matched
  the source at last (it was a lighter orange, which showed as pale patches around the eyes).
  Waiting for permission, the crab now holds up a sign with a question mark where the
  unreadable wristwatch was. And inside each load band the tempo follows the exact session
  count: two sessions stroll, three walk at full tempo, a fifth session makes the sweating crab
  pant faster, and the fire flickers faster the more sessions burn. The README previews are
  regenerated from the runtime frames by `tools/crab-previews`.
- **A sound when Claude needs you.** The *Completion Sound* submenu is now *Sounds*, with a
  second event: the moment a session starts waiting for your permission, a short macOS alert
  sound plays — Tink by default, or Purr, Ping, Glass, Hero, Submarine, picked from the same
  submenu (choosing one plays it). One cue per prompt however many sessions ask at once, and
  none at all when the terminal or app hosting that session is already in front, since the
  prompt is on your screen. *Off* is in the list for anyone who would rather not.
- The README now documents every Option, the two slash commands (`/mcp-health`,
  `/limits-capture`), and — in TROUBLESHOOTING — the `uiconfig.json` keys, the `hideIdleAfter`
  default and the diagnostic modes. PRIVACY lists every file the app writes, not four of them.

### Fixed
- **The two writers of `limits.json` agree again.** The statusLine capture normalizes the reset
  time to a number the way the API poll does — an ISO string passed through unchanged left the
  reset time blank in the menu — and skips a window named `ts`, which would have overwritten
  the timestamp and crashed `/mcp-health`.
- **A failed limits capture leaves a trace.** The capture runs detached with its output closed,
  so a genuine bug in it looked exactly like "no subscription": limits forever *not measured
  yet*. Each failing step now writes a line to `problems.log`, as does a state-file write the
  hooks could not complete (a full disk used to look like a frozen menu bar).
- **A refused switch says why.** `toggle-server`/`toggle-tool` printed `unchanged` for four
  different outcomes; a refusal (unreadable `settings.json`, a hand-edited key of the wrong
  shape, a write race) now reports the reason on stderr with exit code 2.
- The DMG uninstaller no longer swallows a failed statusLine restore; it prints the command to
  run before trashing the app.
- `.claude/rules/architecture.md` was never in the repository: an unanchored `ARCHITECTURE.md`
  in `.gitignore` matched it case-insensitively on APFS.

### Changed
- **Less work per hook event.** The context recomputation read and split 2 MB of transcript on
  every tool call, twice; it now reads 128 KB first and the full 2 MB only when that finds no
  usage record. The self-heal `pgrep` — a fork per event — runs at most once every 30 seconds.
- `main.swift` is split by concern (menu rows, updates, menu, session rows, icon rendering),
  and the UI-free model files live in `Sources/Model/`, which CI compiles as a whole instead of
  from a hand-kept list. The debug switch for the hooks is `CONTROL_BAR_DEBUG` (was
  `CLAUDE_STATUSBAR_DEBUG`). The *Show timer* option is named *Timer in menu bar*, which is
  what it does.
- Dead code removed: the backend's unused `line` subcommand and its refresh spawner, and a
  handful of unused properties and branches in the app.

## [0.7.12] - 2026-08-31

### Fixed

- **The app no longer quits itself while Claude is plainly running.** The last-word liveness
  check walked only the first quarter of the process table — a units mix-up in the libproc
  answer — so a `claude` process anywhere in the other three quarters read as "not running"
  and the app could close mid-session. The whole table is scanned now, and a model check
  pins that it stays scanned.
- **A hand-edited file can no longer crash-loop the app or silently freeze the MCP menu.**
  A negative `nameMax` in `uiconfig.json` crashed every menu open, straight into the hooks'
  relaunch loop; valid JSON of the wrong shape — `"permissions"` written as a list, a string
  where the `statusLine` object belongs, junk tool entries in the desktop connector cache —
  killed every MCP refresh without a trace, leaving the menu stale forever. Every reader of
  a hand-editable or foreign file now degrades to "no data" instead, and the switches refuse
  to edit a shape they don't understand rather than guess.
- **Installing no longer races the hooks it rewrites.** The installer overwrote `update.js`
  and `lifecycle.js` in place on every app launch — while live hooks execute those very
  files, so node could parse a half-written script and fail the event it was handling. All
  installer writes are atomic now, the ownership lease file included.
- **The DMG uninstall gives your status line back.** Following the README — run the
  uninstaller, trash the app — left `statusLine` pointing into the trashed bundle and the
  command it had replaced stranded on disk; the uninstaller now restores the original first.
- **A Mac without the Xcode Command Line Tools is told, not interrogated.** The plugin's
  build step used to pop the system's "install the developer tools?" dialog from a background
  hook on every session start; it now probes quietly, writes the reason to `problems.log`
  once, and keeps launching an already-built older copy while it waits.
- **A broken MCP server is no longer poked awake every ten minutes.** An unresponsive stdio
  server used to be started fresh on every description refresh and sat out a 20-second
  timeout each time, forever; a failed probe is now remembered and retried hourly.
- A cluster of smaller ones: duplicate "server went down / is back" notifications inside the
  45-second window; a data race in the self-update's error capture; context files leaking one
  per session after SessionEnd; a corrupt pid of `0` making a session immortal; the update
  menu row not greying out while a check runs; `toggle-tool --off` writing the literal rule
  `--off` into the deny list; the `limits` command answering in Russian on English machines.

### Changed

- **The limit bars stopped costing a JSON parse 2.5 times a second.** `limits.json` is
  re-read only when it actually changed; the "Limits via Anthropic API" switch still takes
  effect on the next tick.
- CI answers minutes sooner: a Linux job mirrors the Python and Node suites, shellcheck
  guards the shell scripts, and a superseded pull-request run cancels itself.

### Documentation

- **Both READMEs walk the first launch step by step** — where the icon appears, why the app
  is never opened by hand, that the plugin channel's first session compiles for a minute or
  three, that a DMG copy opened with no session quits again by design, and a short "no
  icon?" checklist before the full troubleshooting guide.
- PRIVACY.md names the one request it had missed: the one-click update downloads that
  release's source archive from GitHub, and only when you click it. The last sixteen
  releases' changelog headings render as links again.

## [0.7.11] - 2026-08-23

### Fixed

- **The update menu shows one set of release notes, not two competing versions.** When notes for
  the running version are still unseen and a newer release is already available, the menu now
  shows only `What’s new` for the newer version. The current version’s notes remain available
  whenever no update is being offered.

## [0.7.10] - 2026-08-22

### Changed

- **The Crab's busier moods now read as distinct emotions at menu-bar size.** The cigar pose has
  an asymmetric smug squint, overheating opens into a pant with a visible tongue, and the fire
  panic uses unmistakable `><` eyes with clenched teeth. Stronger anticipation, action and
  recovery poses make the watch check, smoke puff, pant and claw flail feel less static while
  the feet and claw hinges stay planted.
- **Both READMEs now show the actual Crab animations.** The Russian guide has the same six-state
  GIF gallery as the English guide, generated from the app's production frames and timing.

### Fixed

- **Animated README previews no longer show a false gap through the Crab.** Every GIF frame is
  composited onto an opaque background before encoding, avoiding transparency/disposal artifacts
  that could make the connected head and shell look separated in some Markdown viewers.

## [0.7.9] - 2026-08-22

### Changed

- **Every non-walking Crab mood now acts out its state instead of sliding as one rigid sprite.**
  Sleep has a planted breathing cycle and drifting Zs; permission raises only the watch claw and
  moves its gaze; the cigar-side claw lifts while smoke travels upward; overheating pants and
  sweats; and fire alternates its flailing claws under changing flame heights. The original
  twenty-frame walk remains untouched for the normal two-to-three-session load.

### Fixed

- **The Crab keeps one connected silhouette through every key pose.** Head squash-and-stretch is
  anchored to the shell instead of translating a rectangular layer, both claw hinges stay joined,
  all four feet remain planted outside the walking cycle, and each animation recovers cleanly
  before looping.

## [0.7.8] - 2026-08-21

### Added

- **The Crab now shows how much work is happening.** With no active work it sleeps; with one
  working session it relaxes with a cigar; two or three keep the original walk; four or five
  make it turn red, sway and sweat; six or more set its head on fire. Only sessions currently
  thinking or running a tool count, so an open but idle tab does not make the mascot panic.
- **A permission request looks like waiting, not a replacement icon.** The Crab checks a watch,
  looks back at the screen and blinks while the shorter `Needs you` label is visible. A small
  amber badge sits beside the still-animated mascot instead of replacing it, and both the badge
  and the Crab keep their colours when the 5h/7d gauges are present.

### Changed

- **Crab Walking is the default animation for a fresh install.** An existing saved choice still
  wins, so upgrades do not switch people away from Claude Spark or Claude Code.

## [0.7.7] - 2026-08-13

### Fixed

- **The limit bars tell the truth now.** The 5h/7d gauge used to floor its fill at the bar's
  own height — 3pt of a 20pt track — so every value from 0 to 15% drew the same stub, and the
  rounded fill shape ate what little width was left: 18% of the weekly quota read as almost
  empty. The fill is now a straight-edged rect clipped by the track capsule, the way the
  system battery gauge draws its charge, and its width is round(percent × track width) in
  device pixels — with a one-pixel floor above zero, so "critically low" never looks like
  "empty". Pinned by pixel-measuring tests on the actual drawing code in the model suite.

## [0.7.6] - 2026-08-12

### Changed

- **The bar no longer polls the system for Claude Desktop.** It used to ask macOS for the full
  list of running applications on every idle tick; now it subscribes to the workspace
  launch/terminate notifications and just reads a flag. Before the app would quit itself it
  re-checks with a live, targeted query, so a missed notification can delay the quit but can
  never close the bar while Claude Desktop is actually running. Ported from upstream
  [claude-status-bar 0.4.4](https://github.com/m1ckc3s/claude-status-bar) (issue #53).

## [0.7.5] - 2026-08-12

### Changed

- **The "What's new" window looks like the app talking, not a text dump.** It gains a header
  with the app icon, a large title and the version with its release date; section names render
  as small colored labels (added green, fixed blue, changed amber); the changelog's bold lead
  sentences actually show bold in full text color while the prose around them steps back to
  secondary, and inline code gets a monospaced face — so the window scans like release notes
  instead of a wall of matter-of-fact text. The panel content moved to its own source file and
  is rendered to an image by a bare harness, which is how the design was reviewed before
  shipping — main.swift never links into any test.

## [0.7.4] - 2026-08-12

### Added

- **Updates stopped being invisible.** The plugin channel rebuilds and swaps the app with no
  user action — which is convenient exactly until you wonder why the app behaves differently
  and nothing anywhere says it changed. Every version change now announces itself the way
  auto-updating apps do (VS Code, Raycast, Chrome): a notification on the first launch of the
  new version, and a one-time "What's new in X" menu row that opens the changelog section for
  exactly that version — read from the CHANGELOG.md the build now ships inside the bundle, so
  it matches the running copy and works offline. The row retires once opened; a fresh install
  says nothing, because nothing changed.
- **An available update explains itself before you take it.** The daily release check already
  downloads the release notes with the tag; they were dropped on the floor. A newer release
  now raises one notification per version — never a daily drumbeat — and the update section of
  the menu gains "What's new in X" showing those notes, so the decision to update comes with
  the reasons in hand. No new network requests and nothing new sent anywhere: same single
  `releases/latest` call as before.

## [0.7.3] - 2026-08-07

### Fixed

- **A 20-minute build is a working session, not an idle one.** The state timestamp is stamped
  at PreToolUse and untouched until PostToolUse — there is no "still running" hook — so the
  flat 15-minute cap read any long tool call as idle, and the same clock hid the row while the
  build ran. A tool call now gets an hour (a genuinely dead one is caught far earlier by the
  interrupt net or the process reap); thinking keeps its 15 minutes, but a transcript whose
  mtime moved in the last two minutes is proof of streaming and extends it. Two tempting
  designs are recorded as dead ends in the code: "the transcript keeps growing during the
  tool" (it is silent by design — the record lands at completion) and "the session process has
  children" (always true — idle sessions hold their MCP servers as children).
- **A plugin build that outlives its ceiling dies as a group and logs, instead of crashing —
  or hanging — the hook.** The 300-second build timeout raised an exception nothing caught,
  and Python's own kill reached only the immediate bash child: swiftc, lipo and codesign kept
  running unparented. The build now runs in its own process group; a timeout SIGKILLs the
  whole group, drains what stderr already said — the compiler's last words — into
  problems.log, and the drain itself is bounded, because a descendant that left the group
  would otherwise hold the pipe open and hang the SessionStart hook forever with no trace.
  The inner ceiling drops to 240s with a test pinning it below the hook's outer 300s: equal
  ceilings were a race the graceful path lost.
- **A hand-edited or foreign JSON file with the wrong top-level shape cannot crash a refresh
  or a hook.** The same class was patched twice at single call sites in 0.7.2; the shape
  check now lives in read_json itself — the parsed value must match the type of the default —
  across all three copies of the helper (the backend and both hook scripts). The three
  callers that deliberately distinguish "missing" from "wrong shape" are commented in place.

### Changed

- **The session state machine moved out of main.swift and under the model checks.** Session
  parsing, the effective-state caps and both recovery nets now live in Sources/Sessions.swift,
  linked into the CI model checks, each behavior pinned by a test. The js→swift seam closed
  from the reader's side too: the node suite saves a state file written by the real hook, and
  the model checks parse it with the real Session initializer. Model-test timestamps now carry
  fractional seconds — the format real transcripts write; the bare format exercised only the
  parser's fallback branch, and a probe proved those checks stayed green with the primary
  branch broken.
- **The toolchain probe left the menu-open path.** Whether the app can build itself from
  source used to be resolved lazily — a synchronous xcode-select spawn on the main thread,
  inside the first menu open. It is warmed once on a background queue at launch instead.

## [0.7.2] - 2026-08-07

### Fixed

- **An explicit Quit survives a session resume.** SessionStart fires not only for new sessions
  but on `--resume`/`--continue`, wake after sleep and compaction — and every one of them
  voided the quit marker and brought the app back. Both launch paths (lifecycle.js and the
  plugin bootstrap) now read the hook's `source`: startup and `/clear` are fresh consent,
  resume-shaped events honor the Quit. An old Claude Code that sends no `source` keeps the
  previous behavior.
- **A long tool call's session cannot crash the poll behind it.** The Anthropic usage endpoint
  is undocumented; an answer of an unexpected shape (an array, a string, `Infinity` in one
  window) crashed the whole poll script — invisibly, since the app discards its output, so the
  limits just silently froze. Unexpected shapes now read as a failed poll, one malformed window
  is skipped without dropping the rest, and the same hardening covers the desktop-app session
  cache that feeds connector tools.
- **A probed MCP server cannot outlive its probe.** The tools/list round trip ended with a bare
  `terminate()`: a server that ignores SIGTERM survived it, and since an unanswering server is
  re-probed on every refresh, one more orphan process joined it roughly every ten minutes. The
  teardown now closes stdin, waits, and falls back to SIGKILL — with a test that proves a
  deliberately stubborn child is dead by the time the probe returns.
- **A corrupted number in a state file degrades to a wrong figure, not a crash loop.** Swift's
  `Int(Double)` is a trapping conversion, and eight call sites fed it numbers straight from
  JSON files on disk — `limits.json`, session state, and `uiconfig.json`, a file that is
  hand-edited by design. An absurd value crashed the app on every menu open, and the
  self-relaunch walked straight back into it. All sites now clamp instead of trapping.
- **Every backup of settings.json is owner-readable only — including the first one ever
  taken.** The install-time backup inherited whatever mode the original had that day and was
  never revisited: on a real machine that meant a full settings snapshot readable by group
  `staff` (every local account) indefinitely. The backup is now born with owner bits at
  creation, and the per-refresh permission sweep also covers existing `.bak-control-bar*`
  files — quietly when there is nothing to fix, with a `problems.log` line when it cannot.

### Added

- **The cross-language seams are pinned by tests.** The state files (written by the JS hooks,
  parsed by Swift) and `mcp.json` (written by the Python backend, parsed by Swift) each had
  their schema asserted twice, independently, on hand-written fixtures — a coordinated key
  rename passed every suite while the menu silently emptied. The Python suite now feeds a
  file written by the real backend to the Swift model checks, and the JS suite pins the state
  file's exact key inventory.

## [0.7.1] - 2026-08-07

### Added

- **A click on an extension-panel session opens that very conversation.** The Claude Code
  extension registers a URI handler: `<scheme>://anthropic.claude-code/open?session=<id>`
  resumes exactly that session in the editor's Claude panel. The scheme is read from the
  editor's own Info.plist (Cursor says `cursor`, VS Code `vscode`), so every fork works with
  no catalog to maintain, and `open -b` pins the receiving app in case two forks claim one
  scheme. An editor whose extension lacks the handler still comes to the front as before.
  A session running in an integrated *terminal* keeps app-level focus on purpose:
  deep-linking one of those would open a second copy of a conversation that already lives
  in the terminal.

## [0.7.0] - 2026-08-07

### Fixed

- **A session row click focuses the app that actually hosts the session.** The click used to
  resolve the app from `TERM_PROGRAM`, and every VS Code fork inherits `vscode` — so a session
  living in Cursor's terminal opened Visual Studio Code, and a session in the IDE extension
  panel (which sets no `TERM_PROGRAM` at all) opened nothing. The hooks now record
  `__CFBundleIdentifier`, the bundle id LaunchServices stamps on every process launched from an
  app bundle, and the click prefers `open -b <id>` — no name catalog to maintain, and a tmux
  session (`TERM_PROGRAM` says `tmux`, an app `open -a` cannot find) now focuses the terminal
  that launched the tmux server. The `TERM_PROGRAM` map stays as the fallback for ssh and
  pre-upgrade state files.

### Added

- **An IDE badge.** A session living inside an editor — the Claude Code extension panel or a
  VS Code-family integrated terminal (Cursor, Windsurf, VS Code) — now wears **IDE**;
  standalone terminals keep **CLI**, the desktop app keeps **APP**.
- **The README says out loud that sessions are local.** The whole Sessions section is fed by
  hooks firing on this machine; a session running elsewhere (ssh, a cloud worktree, the
  browser) writes no state here, so it is not listed and cannot be focused from here.

## [0.6.0] - 2026-08-07

### Added

- **One-click update that builds from source.** With a Swift toolchain on the machine (Xcode
  command line tools or Xcode), the update row becomes "Update to X": one click downloads the
  release source from GitHub, builds it in place with the same script every channel uses, swaps
  the bundle only after the staging copy verifies, and restarts. No DMG, no Gatekeeper — the
  quarantine that blocks downloaded apps does not apply to a binary compiled on this machine.
  The build is bounded by a watchdog, Quit cancels it cleanly, failures land in
  `~/.claude/control-bar/problems.log`, and the outgoing bundle survives one generation as
  `.previous` beside the app — a compiled-but-broken build must leave something to go back to.
  Without a toolchain the row keeps its old behaviour and opens the release page.
- **A denied network-volume permission now names itself and offers the way back.** macOS counts
  FUSE mounts (arc, sshfs) as network volumes; declining the one-time "access files on a network
  volume" dialog made every MCP check fail with a bare `EPERM`, and the system never asks again.
  The failed check now grows two rows: one opens the right Privacy pane in System Settings, the
  other is a copyable `tccutil reset` command that makes macOS show the original dialog again on
  the next check.

### Fixed

- **The `EPERM` marker survives a crowded error list.** The check error is capped at 200
  characters for the menu; with several projects failing at once the permission error could be
  cut off mid-list, and the new help rows would never appear. Permission errors now sort to the
  front of the line before the cap.

## [0.5.6] - 2026-08-06

### Fixed

- **"Awaiting permission" no longer outlives the prompt it announces.** Denying a permission
  prompt — or dismissing it with Esc — fires no hook at all in Claude Code, so the session's
  state file froze mid-wait and the amber dot sat in the menu bar for up to two hours,
  outranking every live session. The transcript is the one witness that does record the answer:
  while a prompt waits the file is silent, so a user/assistant record younger than the prompt is
  proof it was answered, whatever form the answer took — and the app now reads exactly that.
  Three smaller things kept the old freeze alive and are fixed with it: the tail read stopped at
  8 KB while the bookkeeping Claude Code appends after an interrupt runs to 112 KB in a single
  line (the window now escalates to 1 MB, and only when the cheap read finds nothing, so a
  streaming session pays the old price); a window that happened to cut a multi-byte character —
  an emoji, a dash — made the decoder reject the entire chunk and silently disabled both
  recovery nets for as long as the file sat still; and the last-resort age cap is 30 minutes
  now, not two hours. If Claude Code ever changes the transcript's timestamp format, the app
  logs the drift to Console once per file change instead of degrading in silence.
- **A declined notification permission is now said out loud.** macOS shows the permission dialog
  once per app, ever — no later version, reinstall or second request brings it back, only the
  user in System Settings. The app used to swallow that refusal whole: someone who declined a
  year ago could never learn why "MCP server went down" banners stopped. A menu row now appears
  when notifications are off and opens the app's own pane in System Settings (falling back to
  Settings' root, with a Console trace, on the macOS releases where the undocumented pane link
  stops resolving). The status is re-read at launch, on every menu open and on every delivery
  attempt, so flipping the switch back on clears the row without a restart. The check also no
  longer crashes the bare-binary diagnostic modes (`CONTROL_BAR_DUMP_MENU`,
  `CONTROL_BAR_DIAGNOSE`), where asking the notification center for anything is a trap.

## [0.5.5] - 2026-08-06

### Fixed

- **The app no longer closes itself ten seconds after launch while Claude Code is running.**
  Whether it was still needed was decided by counting the session files the hooks leave in
  `state.d/` — and a session whose hooks never fired writes none (no `node` on the PATH, hooks
  switched off, setting sources that skip the user's file). It never happened next to the
  desktop app, which is a GUI application and is detected a second way, which is exactly why
  this read as "the plugin only works on the desktop". The process table now gets the last
  word: with any `claude` process alive the app stays. Asked through libproc rather than by
  spawning `pgrep`, and only once every cheaper check has already said "not needed".
- **Clicking a session row switches to that session.** For a desktop conversation the click
  merely focused the Claude app — which is normally frontmost already, so every row did nothing
  visible and all of them did the same nothing. The app does file each conversation, at
  `claude-code-sessions/<account>/<workspace>/local_<uuid>.json`, with the CLI session id
  inside — the very id the rows are keyed by. The row resolves it and opens
  `claude://claude.ai/epitaxy/<sessionId>`. Not `claude://code/<id>`: that route wants a bridge
  session id, which a local conversation does not have — 0 of 441 session files on a real
  install carry one. Focusing the app remains the fallback for a conversation with no record on
  disk; a terminal session still brings its terminal to the front.
- **The context percentage in a terminal session is Claude Code's own figure, not a guess.** It
  was recomputed from the transcript against an assumed window size — and the window belongs to
  the session, not to the model: the same `claude-opus-5` answers with 200k in one place and 1M
  in another. Assuming the narrow one turned 30% into 90%. Claude Code states both the size and
  the finished percentage in the statusLine payload, so that is kept per session in
  `context.d/` and preferred to the arithmetic. The recomputation stays for the desktop app and
  the editor extensions, which run no status line at all; a reading older than fifteen minutes
  counts as absent, so a session that moved to the desktop cannot freeze on what the terminal
  last saw. The record is deleted with its session.

### Changed

- **The update row says "Update available".** The version moved into its tooltip, where it is
  not a second number sitting beside the one the line above already gives. "Restart to finish
  updating" lost its version for the same reason.
- **The README no longer claims the plugin channel never meets Gatekeeper.** It says what is
  actually true: the app is compiled from source on your Mac, which needs the Xcode command
  line tools.

## [0.5.4] - 2026-08-06

### Fixed

- **Installing the limits capture no longer silences a foreign `statusline.sh`.** The wrapper's
  recursion guard was a substring check on the saved command's text — and `statusline.sh` is the
  file name from the official Claude Code example, so a user's own status line under that name
  was dropped instead of run: after install their status line simply went blank. The guard is
  now an environment sentinel only this script sets; the saved command's text no longer matters.
- **Uninstalling the capture cannot overwrite a status line the user changed by hand.** "Our
  sidecar files exist" used to pass for "the current command is ours", so after a manual change
  `statusline --uninstall` restored the command saved at install time over the user's newest
  choice. Install now records the exact command it writes, uninstall restores only on an exact
  match (or the wrapper's real path), and otherwise refuses out loud: "changed after install".
  A failed settings write also rolls the sidecar files back instead of leaving a half-install
  that reads as an installed capture.
- **The hook installer and uninstaller no longer delete strangers that resemble them.**
  Ownership was `command.includes("~/.claude/control-bar")` — also a prefix of a user's own
  `control-bar-extra/custom.js`, and a substring of any hook that merely reads a file out of our
  directory. Both kinds of stranger were silently removed on every install and uninstall, and
  the plugin bootstrap used the same check, so one such foreign hook kept the plugin from ever
  claiming the hooks lease. All three now match the exact scripts a hook can point at:
  `update.js` and `lifecycle.js` inside precisely `~/.claude/control-bar/`, with a right-hand
  token boundary on the bare spelling — `update.js` is itself a prefix of a neighbour's
  `update.js.bak`, and "exact" has to mean exact on that side too.
- **Backup rotation touches only its own backups.** The ten-most-recent cleanup globbed
  `settings.json.bak-2*`, which also matches dated backups made by hand or by another tool —
  files whose loss nothing can undo. Backups now live in their own namespace,
  `settings.json.bak-control-bar-<date>-<microseconds>`, rotation is bounded to that exact
  prefix, and pre-existing `.bak-*` files are never deleted. The microseconds also mean two
  switches within one second no longer share a single snapshot — PRIVACY.md promises one per
  switch, and now that is what happens.
- **The MCP check takes a real inter-process lock.** `refresh.lock` was only consulted by the
  statusLine path's spawner; the app's "Check MCP now" and `report --force` ran `refresh()`
  straight past it, so two checks could start every configured server twice and race their
  writes of `mcp.json`, last one winning. `refresh()` itself now takes a non-blocking `flock`
  for the whole check — held to process exit, so a crashed holder releases it — and a
  contending call returns the last picture instead of running a duplicate check — and when
  there is no picture yet (first run), `report` says a check is already running instead of
  presenting a confident "0/0 connected" that was never measured.
- **An ordinary notification cannot park the icon on a two-hour permission alert.** The CLI
  fallback classified notifications by substrings, and `allow` lives inside `shallow`: a
  "Shallow clone finished" notification read as a permission prompt, whose amber state only
  times out after two hours. `notification_type` is now trusted whenever present, and the
  legacy text fallback matches whole words only.
- **"Switch to Homebrew" is offered only once the cask exists.** The row was added for any
  non-brew install as soon as GitHub reported a newer release, while the cask API still returns
  404 — a command guaranteed to fail, handed out by the app's own menu. The row now requires a
  successfully fetched cask version, exactly like the brew-managed upgrade row always did.
- **The hover card shows the tool's real full name.** The identifier line printed
  `mcp__<display name>__<tool>`, but a plugin or claude.ai connector loads its tools under its
  toolPrefix — `plugin:claude-mem:mcp-search` lives in context as
  `plugin_claude-mem_mcp-search`. The switch learned that distinction in 0.5.1; the card now
  uses the same prefix instead of re-deriving a wrong one from the display name.

## [0.5.3] - 2026-08-05

### Security

- **`statusline --install` cannot wipe `settings.json` any more.** The two switches in the menu
  are careful about that file — a lock for the whole read-modify-write, a fingerprint checked
  again just before the rename, and a refusal to treat an unparseable file as an empty one. The
  status line installer, one function away, had none of it: it read through `read_json(...) or {}`
  and wrote with no fingerprint at all. Reproduced against the pre-fix code: with the file
  momentarily invalid — someone editing it by hand — a single `--install` replaced the whole of
  it, `permissions.deny` and the `env` block with its tokens included, with one `statusLine` key.
  No backup was left either, because `backup_settings()` on a file it cannot read quietly returns
  nothing. Both install and uninstall now use the same contract as the switches, and refuse
  rather than guess.

### Fixed

- **Switching a tool off actually switches it off, for plugin servers and claude.ai connectors.**
  The deny rule was assembled from the server's display name, and no real tool name contains a
  space or a colon: `plugin:claude-mem:mcp-search` reaches Claude Code as
  `plugin_claude-mem_mcp-search`, and a connector under its uuid. The rule matched nothing, so
  the tool loaded into every new session while the switch sat off and the "N of M tools on" count
  promised a saving that was not happening — the panel agreeing with itself, since the same wrong
  string was used to read the state back. The spelling Claude Code actually uses is now resolved
  once, in the backend, from the transcripts and the desktop connector cache, and the app is
  handed it rather than rebuilding it. On the development machine that is five servers whose
  switches did nothing. Turning a tool back on also clears the old rule, which would otherwise sit
  in `settings.json` forever, matching nothing.
- **A working session is no longer shown as idle.** The transcript's last line was searched for
  `interrupted by user` anywhere in the raw JSONL, and a tool result is itself a `"type":"user"`
  record — so Claude reading any file that contains the phrase (three of this repository's own
  files do) stopped the animation and the timer mid-turn, and cost a session waiting on permission
  its amber alert. Measured across this machine's transcripts: 27 lines carry the phrase without
  being an interrupt, against 2 that are one. The record is now parsed and the marker matched
  exactly.
- **"A server went down" notifications are delivered.** They were posted for the app's whole life
  without ever asking for permission, and macOS does not prompt on delivery — it declines, with
  nothing but an `NSLog` to say so. Permission is now requested the first time there is something
  to report, so the prompt arrives attached to a real event rather than at first launch.
- **The panel stops starting servers the user switched off.** Collecting tool descriptions runs
  each server's own command, and the list came from `~/.claude.json` with no regard for the
  switches — so a disabled server was launched twice an hour by the very panel that shows it as
  off (reproduced: a disabled server whose command was `touch marker` created the marker). Its
  answer was not even used.
- **`--install` and `--uninstall` recognise their own status line, not any file called
  `statusline.sh`.** That is the name in Claude Code's own documented example, so a user with
  their own status line was told "already installed" and, on uninstall, had their command deleted
  by an operation that promises to undo only its own work.
- **Both channels' hooks can no longer fire at once on a machine using nvm, volta or asdf.** The
  plugin claimed ownership of the hooks before trying to remove the app channel's copies, and it
  looked for node in three fixed paths. Where node lives elsewhere the removal could not run, the
  claim was already written, and `install.js` — which reads that claim and stands down — never
  reclaimed them: two sets of hooks, every event, permanently. The claim is now written only once
  the duplicates are gone, and node is looked for where the app itself looks for it.
- **A saved multi-line status line command is run whole.** The wrapper read one line of it.
- **A pre-release is no longer treated as newer than the release it precedes.** `0.6.0-rc.1`
  compared above `0.6.0`, because an unparsable component became `0` and left the version one
  component longer.
- **A check asked for while another is running is no longer dropped.** A toggle schedules a
  re-check; if a scheduled refresh was already in flight — one that started before the toggle and
  cannot know about it — the new request was discarded and the row stayed stale until the
  ten-minute timer came round.
- **A backend that dies says so.** Its exit code and stderr both went to `/dev/null`, so a script
  failing on a traceback was indistinguishable from one with nothing to report.
- **A dangling `settings.json` symlink stays a symlink.** `realpath` throws on one, and the
  fallback wrote a regular file over the link — the exact dotfiles breakage the resolution exists
  to prevent. A `settings.json` that does not parse now stops the installer with a sentence
  instead of an unhandled stack trace.
- **Assorted:** the saved status line command is written `0600` like everything else in the state
  directory; a log or transcript vanishing mid-sort no longer takes down the whole refresh; the
  refresh lock outlives the refresh it guards; the triage bot points at this repository's issue
  forms rather than the upstream project's; the DMG cleanliness guard inspects the volume
  `hdiutil` actually mounted rather than an assumed path.

### Documentation

- PRIVACY.md now lists everything that is read, including `~/.claude.json` (which holds MCP server
  `env` blocks), Claude Code's MCP logs, the desktop connector cache and the OAuth token behind
  the limits poll — and says that the dated `settings.json` backups live beside the original
  rather than in the state directory.

## [0.5.2] - 2026-08-04

### Security

- **The usage poll no longer follows redirects.** `urllib` copies the `Authorization` header onto
  the redirected request, across origins included — unlike `requests`, which strips it — so a
  single `302` from the endpoint, a proxy or a future move of the API would have delivered the
  account's OAuth token to another host. Reproduced against two local servers on the system
  Python the app actually runs. Redirects are now refused outright and a `30x` is reported as a
  failed poll; checking the final URL afterwards would have been too late, the header having
  already been sent.
- **State files are owner-only.** `~/.claude/control-bar/` and everything under it is created at
  `0700`/`0600`, and existing installs are corrected on every refresh — an upgrade alone does not
  fix permissions. A macOS home folder is readable by the group `staff`, i.e. every local account
  on the machine, and these files hold working directories, transcript paths, account limit
  percentages and, with `CLAUDE_STATUSBAR_DEBUG=1`, fragments of what was typed.

### Fixed

- **The menu says when the app on disk is newer than the app that is running.** Installing over a
  running copy — a DMG, `brew upgrade --cask` — replaces the bundle, but macOS keeps the old
  executable image alive until the app restarts. Measured here: 0.5.1 sat in `/Applications` for
  two hours while a 0.5.0 process drew the menu, and nothing anywhere said so. It is not only
  cosmetic: a process whose bundle was replaced could no longer write its own preferences, so the
  daily update check had nowhere to store the latest tag and the "Update to X" line could never
  appear again either — the app went permanently quiet about updates. There is now a
  **Restart to finish updating to X** row that quits and comes back as the copy on disk; it waits
  for the old process to exit first, because two copies of the same bundle path run side by side
  quite happily.
- **A green server row no longer hides a failed one of the same name.** Two projects with a
  server called `db` collapsed into one row keyed by name, and whichever was seen first won —
  so a working `db` in one project masked a broken `db` in the one being worked in. The row stays
  single (`settings.json` addresses a server by `serverName` alone, so two switches for one name
  would lie in the other direction), but it now takes the worst state of the two and names the
  project it came from.
- **A project whose health check fails is reported instead of vanishing.** The loop reused the
  same `error` variable as the overall check: a project that timed out was skipped by `continue`,
  and the next project that answered reset the variable to nothing. The menu showed neither the
  broken project nor a "check failed" line. Project failures are now collected separately and
  named one by one.
- **A malformed `.mcp.json` no longer removes a project from the map.** The parse that decides
  whether a project is worth checking swallowed its own error and answered "no servers here", so
  a broken config — precisely what a health tool exists to surface — took the whole project's
  servers off the map silently. An unparseable file now sends the project to `claude mcp list`,
  which is where the diagnosis belongs.
- **A development build outside `/Applications` stays a development build.** The installed-copy
  test matched `/Applications/` anywhere in the path, so a build under `/tmp/Applications/…` or
  `~/projects/Applications/…` would have installed hooks into a live `settings.json` and moved
  apps to the Trash. The path is now anchored at `/Applications` or `~/Applications`.

## [0.5.1] - 2026-08-04

### Fixed

- **Servers from a project's `.mcp.json` are back, and the row about them tells the truth.**
  0.5.0 closed a real hole — the app read that file and started its servers itself, so opening a
  cloned repository was enough to run a command from someone else's config — but it closed it by
  refusing to touch project servers at all, and labelled every one of them *approve in Claude
  Code*. For a server the user had already approved that was simply false: nothing was waiting on
  them, and a working server went dark with its tools. The mistake behind it was reading approval
  out of `enabledMcpjsonServers`, which is empty even for approved servers — that list is not
  where the decision lives.
  The app now asks instead of deciding: `claude mcp list` is run in the project's own directory
  and its answer is taken as-is. Claude Code applies its own approval policy, starts what it is
  allowed to start, and reports the rest as `⏸ Pending approval`. No command out of `.mcp.json`
  is ever executed by this app, approved or not — so the hole stays closed while approved servers
  keep working. Costs one extra health check per project that has servers.

## [0.5.0] - 2026-08-04

Renamed to **Claude Control Bar** and merged with
[claude-mcp-bar](https://github.com/InfinityScripter/claude-mcp-bar). The app no longer only
reports on Claude Code — it switches parts of it off.

### Added

- **Context window usage per session**, in the row and in its tooltip. Claude Code gives that
  number to `statusLine` and to nothing else, and the desktop app never runs `statusLine`, so it
  is recomputed from the transcript with the CLI's own formula.
- **MCP section**: servers grouped by where they are configured, one row each with a switch, an
  `enabled/total` tool count and the server's tool list as a submenu off that same row.
- **A spinner on a row being checked**, and `next session` once it has been — a re-enabled server
  is on, but a session assembles its server list at startup, so an open one keeps what it had.
  The check is ordered by the switch itself rather than waiting for the ten-minute timer.
- **Tool cards on hover** — description and parameters, read from the server's own `tools/list`
  response. Parameters are new data; the backend did not collect `inputSchema` before.
- **Usage bars in the menu bar**: the 5h and 7d limits, labelled, with the detail in the menu.
- **A `changed:` line** naming what moved since the last check, plus a notification when a server
  falls over. Tool counts change silently — that is usually you, one click ago.
- `statusline --install`, which wraps an existing `statusLine` command to capture limits without
  altering a byte of its output.
- `CONTROL_BAR_DUMP_MENU=1` prints the menu the app would draw.

### Security

- **A server configured in a project's `.mcp.json` is listed but never started.** The health
  check read that file straight out of the repository and handed its `command` to a subprocess,
  with none of the approval flags Claude Code gates it on — so cloning a repository and opening
  Claude Code in it was enough for a command from someone else's config to run on the next
  check, approved or not, switched off in this app or not. Servers you added yourself are
  unaffected; the row for a project one now says *approve in Claude Code* and stays inert until
  you have.
- **A backup of `settings.json` can no longer be wider than the file it copies.** The backup was
  created fresh, so there was no mode to inherit and the usual `umask 022` made it `0644` while
  the original stood at `0600` — and that file holds the `env` of MCP servers, tokens included.
  Backups now take the source's mode, never wider than the owner.
- **A settings file that will not parse is left alone.** Reading swallowed every error and
  returned "no file", so one click while the user had the file open in an editor mid-edit
  replaced all of their settings with a single deny rule — and the backup step, reading the same
  unparseable file, wrote nothing either. A parse failure now aborts the toggle.
- **A change made by someone else between our read and our write is no longer overwritten.** The
  lock only ever held back this app's own processes; Claude Code and the user's editor do not
  take it. The file's fingerprint is now re-checked immediately before the replace, and a
  mismatch abandons the write.

### Fixed

- **A `settings.json` symlinked into a dotfiles repository stays a symlink.** The atomic replace
  swapped the link itself for a regular file, so the dotfiles original quietly stopped receiving
  changes — no error, just a sync that had died. Both the Python backend and the Node hooks now
  resolve the link and write through to its target.
- **`/mcp-health` no longer dies on a project's HTTP server.** That case produces the state
  `unknown`, which had no entry in the glyph table the report indexes directly, so one correctly
  configured remote server in any open project took the whole command down with a `KeyError`.
- **Turning off "Limits via Anthropic API" now removes the figures.** The switch stopped future
  polls but nothing cleared what had already been fetched, so the bars kept showing old
  percentages with no sign they had stopped moving. Readings that came from the API are dropped
  when the API is off; a statusLine capture is the user's own second source and stays.
- **Two MCP checks can no longer run at once.** The backend ran on a concurrent queue with a
  plain boolean for "busy", so a toggle during a check started a second pass over the same
  servers and the same cache files, and whichever finished first announced that the work was
  done. The queue is serial now, in-flight operations are counted rather than flagged, and a
  refresh asked for while one is already running is dropped instead of queued.
- **A model missing from the local registry no longer inflates the context percentage.** Claude
  Code 2.1.205 knows `claude-opus-4-8` and aliases `opus` to it, while transcripts say
  `claude-opus-5` — a name absent from the binary. Falling through to the 200k default put a
  154k-token session at 77% when the honest figure was 15%. Unknown names now borrow their
  family's widest window and are marked as inferred; a size observed from a real `statusLine`
  payload replaces the guess outright.
- **Switching a server no longer rewrites `~/.claude/settings.json` as a single line.** It is a
  file people edit by hand.
- **A session start no longer clears the whole state directory** when the app is not running.
  Two sessions opening at once both saw it down, and the second wiped the first one's file;
  liveness is the pid now.
- **Reinstalling writes nothing when nothing differs**, instead of rewriting settings.json on
  every launch.
- The routine that cleaned up after an earlier rename deleted bundles **by upstream's id** —
  i.e. this fork would have removed claude-status-bar from the user's disk. It now retires only
  this project's own predecessors, to the Trash rather than by unlink.
- `build.sh` no longer hardcodes a version, nor an Apple Team ID belonging to someone else (the
  grep never matched, so it silently produced an unnotarized DMG while claiming otherwise).
- A development build no longer installs hooks or touches installed apps.
- **"Thinking words" switched off now removes the word.** It used to fall through to the plain
  "Thinking…", which beside an unchecked box is indistinguishable from a broken switch.
- **Roughly half the CPU the app used while Claude works.** Sampling the running process put
  `claudeDesktopRunning()` — which asks LaunchServices about every running application, over IPC,
  on the main thread — at half of everything the 0.4s timer did. It is now reached only when no
  session exists at all, and the quit decision it feeds is sampled every 2s rather than 2.5 times
  a second. The transcript tail is re-read only when the file has actually moved, the animation's
  frames are composed once per look instead of twenty times a second, and the status item title
  is reassigned only when the text it would show has changed. Measured on an M4: 10.2% of a core
  before, 4.7–5.9% after, with the timer's share of a sample falling from 112 to 19.
- **`settings.json` is written through a temp file and renamed**, and left alone entirely if it
  changed between our read and our write. A truncating write that died halfway left an empty
  settings file; a read-modify-write silently dropped whatever Claude Code or the user had
  written in between.
- **The once-a-day update check is once a day even when it fails.** The timestamp was stored only
  on success, so an unreachable GitHub meant both requests fired again on every menu open —
  contradicting PRIVACY.md, and hammering hardest exactly when the network was already unwell.
- **The newest Node is picked numerically.** Version directories were sorted as text, so
  `v9.11.2` outranked `v20.19.0` and the installer could run under a Node too old for the file
  APIs it uses.
- **The debug log is capped at 1 MB and rotated.** It carries an excerpt of each event's message,
  so an uncapped file is a transcript nobody asked for.
- **Two parallel toggles no longer lose one of the changes.** Every click runs as its own
  process; both read the same settings.json and the second write erased the first (measured:
  43 lost of 50 runs of two concurrent toggles). The whole read-modify-write now holds an
  exclusive file lock — 12 concurrent toggles, 12 surviving changes, covered by a test that
  runs real processes.
- **File permissions survive a toggle.** The atomic-write temp file was born with the process
  umask, so a 0600 settings.json became 0644 — and it can carry MCP env values. The original
  mode is copied onto the replacement; tested 0600 → 0600.
- **The MCP map is anchored to projects.** `claude mcp list` answers for the directory it runs
  in, so local- and project-scoped servers were invisible or misclassified. The global check is
  now pinned to a fixed cwd, and servers from live sessions' project configs (`projects[cwd]`
  in ~/.claude.json and the project's .mcp.json) are enumerated and probed from their own
  directory, labelled with their project. A remote project server says "not checked" rather
  than inventing a colour.
- **The statusLine capture keeps the whole object.** Install used to save only `command`, so
  `padding`, `refreshInterval` and `hideVimModeIndicator` vanished on install and did not come
  back on uninstall. The full object is saved, only `command` is swapped, and uninstall
  restores it exactly.
- **A failed build can no longer destroy the installed app.** build.sh removed the app first
  and compiled after; a half-installed CLT or a full disk left nothing but a log. It now
  builds and signs a staging bundle and swaps only after the binary and plist verify —
  and two sessions starting at once can no longer run two builds (a lock file, loser skips).
- **The capture stopped rewriting an unchanged limits.json on every redraw**, and the debug
  log rotation from earlier applies here too.
- **CONTRIBUTING.md describes this project**, not upstream's display-only contract, and
  PRIVACY.md discloses that the health check starts your configured MCP servers on a schedule.
- `/limits-capture` — a slash command that installs, removes or inspects the statusLine
  capture without asking the user to guess the plugin's versioned path.
- **PRIVACY.md now lists what is read locally** — transcripts, the `statusLine` payload,
  `settings.json`, the MCP tool lists — not only what crosses the network.
- **Limits are real now, not whatever a terminal last said.** The 5h/7d figures come from
  Anthropic's usage endpoint — the same one `/usage` asks — polled every five minutes with the
  OAuth token Claude Code already keeps in the Keychain. The `statusLine` capture only fired
  while a terminal CLI was redrawing its TUI, so in the desktop app the bars froze on whatever
  they last showed. The capture stays as a free secondary source; the poll has an off switch in
  Options ("Limits via Anthropic API") because it spends the user's own token, and PRIVACY.md
  names the request.

### Changed

- New identity, frozen in `identity.env`: bundle id
  `io.github.infinityscripter.claude-control-bar`, executable `ClaudeControlBar`, state directory
  `~/.claude/control-bar/`. Menu bar managers key an item's visibility on the bundle id, so this
  re-hides the item once — a one-time cost, paid deliberately rather than by inheriting an id
  that is not ours.
- The DMG is **not notarized**: this fork has no Apple Developer ID. The README says so plainly
  where it previously claimed the opposite.

## [0.4.3] - 2026-07-31

### Added
- **Completion Sound has an "Every turn" option.** The chime can now play the moment any turn finishes, instead of only after turns of a minute or longer. Still off by default.

### Changed
- New app icon.

## [0.4.2] - 2026-07-29

### Fixed
- **Hooks no longer break when Homebrew upgrades Node.** The installer used to write the exact Node binary path into the hook commands, which for Homebrew-installed Node includes the version number, so the next `brew upgrade node` left every hook pointing at a deleted directory: no status, no icon, and no self-heal (that lives in the hooks too). Hook commands now resolve `node` at run time through stable locations instead. If your icon silently died at some point and never came back, this was probably you: install this update and launch the app once. Found, diagnosed, and fixed by [@pedrol2b](https://github.com/pedrol2b) ([#48](https://github.com/m1ckc3s/claude-status-bar/pull/48)), who also contributed the repo's first automated test suite.


## [0.4.1] - 2026-07-22

### Fixed
- **Installing while a Claude Code session is already open no longer looks broken.** The app still quits a few seconds after the first launch (nothing to show yet), but now the hooks relaunch it the moment any session does anything, including sessions that were open before you installed. Previously the icon stayed gone until you started a brand-new session. Thanks to [@Bardin08](https://github.com/Bardin08) for the model bug report and root-cause analysis ([#44](https://github.com/m1ckc3s/claude-status-bar/issues/44)).
- Quit still means quit: quitting from the menu suppresses the relaunch until your next new Claude Code session (or you open the app yourself).

## [0.4.0] - 2026-07-22

### Added
- **Homebrew!** Install (or switch over from an existing DMG install) with `brew install --cask claude-status-bar && open -a "Claude Status Bar"`. The launch at the end is required: it installs the Claude Code hooks, and on a switch-over it also removes your old copy. See [upstream's HOMEBREW.md](https://github.com/m1ckc3s/claude-status-bar/blob/main/HOMEBREW.md) for the full story.
- **The update line in the menu is now brew-aware.** Installed via brew: "Update via brew" appears with a copy button (click, paste in your terminal) and only once Homebrew can actually deliver the new version (the cask lags a release by up to a day). Installed via DMG: "Update available" opens the releases page as before, plus a "Switch to Homebrew" copy button.
- **Completion sound is back**, now as a Completion Sound menu with a length threshold (Off / 1 min+ / 5 min+ / 15 min+) instead of a single on/off toggle. It chimes when a turn that ran at least the chosen length finishes, per session, and is off by default.

### Changed
- **The app bundle is renamed to "Claude Status Bar.app"** (was `ClaudeStatusBar.app`), matching the app's name and its Homebrew cask token. One-time transition: on first launch the app removes the old-named copy from /Applications (after verifying by bundle identifier that it really is this app), so updating over the rename never leaves two copies. Scripts pointing at the old path need the new, quoted path.
- The dropdown timer is now the same size as the session name and sits on its baseline, so it reads as part of the row instead of floating slightly high.
- The working spinner in the dropdown is a touch smaller.

## [0.3.4] - 2026-07-09

### Added
- **Session rows show the git branch** next to the project name ("myrepo · fix-auth"), read straight from `.git/HEAD` (no `git` invocation), works for worktrees, shows a short SHA when detached, shows nothing outside a repo. Updates on session activity and on opening the menu, so a folder that becomes a repo mid-session (git init, first branch) is picked up live. Thanks to [@ethan0905](https://github.com/ethan0905) ([#37](https://github.com/m1ckc3s/claude-status-bar/pull/37)).
- **Same-named projects are told apart.** When two live sessions share a folder name (two clones or worktrees of one repo), rows qualify it with the parent folder: "work/myrepo" vs "tmp/myrepo". Hovering a row shows the full name, branch, and path.

### Fixed
- The dropdown timer now sits on the same text baseline as the session name instead of floating slightly high.
- Long session names keep constant letter spacing on every row; a name that does not fit truncates with an ellipsis instead of being subtly squished next to the timer.

## [0.3.3] - 2026-07-08

### Changed
- The working spinner in the dropdown is now the native macOS spinner. It is smoother and looks cleaner, especially in dark mode.
- Menu cleanup: Animation and Color are their own menu items now, instead of one combined Settings menu. Idle sessions hide after a fixed 15 minutes (the interval picker was removed).

### Removed
- The completion sound, and its toggle.

## [0.3.2] - 2026-07-02

### Added
- Thinking words: the menu bar now rotates through playful verbs while working, more like Claude Code. On by default; toggle it in the menu.

### Changed
- Condensed the settings into a single Settings menu.
- Completion sound now chimes only after turns longer than 5 minutes (was 1 minute).

### Known issues
- Upstream Claude Code bug: pressing Ctrl+C during the reasoning phase in the terminal can leave the icon stuck on a thinking word, since Claude Code emits no hook or transcript signal for that interrupt. Sending your next prompt clears it.

## [0.3.1] - 2026-06-28

### Fixed
- Idle sessions no longer vanish from the menu bar. The icon now follows the live session: it stays while Claude is running and clears when you close it.
- The session list never goes empty: there's always a session to click, or an "Open Claude" shortcut when only the desktop app is open.

### Changed
- Desktop conversations appear only once you work in them, so clicking through conversations no longer clutters the list. Terminal and editor sessions still show the moment they start.
- Menu polish: the session spinner matches the row text, a smaller timer, a tidier Options section, and a light-mode toggle you can actually see.

## [0.3.0] - 2026-06-26

### Added
- **Multi-session support.** The menu bar now tracks every running Claude Code session at once instead of one at a time. When several are active it surfaces the most important one in the bar (a session awaiting your permission outranks one that's working, which outranks idle) and lists them all in the dropdown.
- **Session dropdown.** Each running session gets its own row showing its project, a live status icon (a spinner while working, an amber dot when it needs your approval, a caret when resting), an elapsed timer, and a CLI or APP tag for where it's running.
- **Click a session to jump to it.** Clicking a desktop-app session brings the Claude app forward; clicking a terminal session brings its terminal app forward. Heads up: it raises the terminal app, not a specific window or tab, so if you have several terminal windows open it surfaces your most recent one, not necessarily the exact session you clicked. Precise per-tab focus is in progress: [issue #19](https://github.com/m1ckc3s/claude-status-bar/issues/19).
- **Hide idle sessions** after a delay you choose (5, 15, or 30 minutes, 1 hour, or never), so the list stays focused on what's active.
- **Intel Mac support.** The app now ships as a universal binary and runs natively on both Apple Silicon and Intel Macs.
- **Crab Walking adapts to the color theme.** In System mode the pixel-art crab now renders as a shaded monochrome silhouette that matches the menu bar; Orange mode keeps it full-color. Thanks to @florianheysen for the original implementation.

### Changed
- The menu is now organized around sessions: a Sessions list at the top, with Options, animation, and color settings below.

## [0.2.2] - 2026-06-25

### Fixed
- Fixed install for nvm/fnm users. The hook setup only looked for Node on the login shell's PATH, so the menu bar icon would show but never animate. It now checks the common Node locations and falls back to your interactive shell. Stuck installs heal on the next launch.

## [0.2.1] - 2026-06-25

### Fixed
- Edge case where closing the app (or the Claude desktop app) mid-animation left the menu bar stuck. On reopen it would still show the old "thinking" state with the timer climbing, because a force-quit fires no Stop hook. The status now resets to the idle resting icon when the owning session ends or resumes.
- The menu bar no longer parks on "Waiting for you" after a turn. Claude Code's CLI sends an idle notification ("Claude is waiting for your input") when a session sits idle, and the app was turning that into a persistent label. Now only permission notifications affect the icon, so it simply rests when idle.

## [0.2.0] - 2026-06-25

### Added
- **Awaiting-permission dot now works in the Claude desktop app**, not just the terminal CLI. Previously the yellow "awaiting permission" dot only appeared in the CLI, because the only signal we had (the `Notification` hook) never fires for permission prompts in the desktop app. The app now also listens to Claude Code's `PermissionRequest` hook, which fires the moment an approval dialog is shown in both the CLI and the desktop app, so the dot lights up the instant Claude is waiting on you to approve a tool.

## [0.1.0] - 2026-06-22

### Added
- **Crab Walking** animation style: a pixel-art Clawd crab that scuttles in the menu bar while Claude works. Pick it under Animation. It's always its orange pixel-art self (the Claude and Claude Code styles still follow the Orange/System color setting).
- Optional **completion sound**: a soft chime when a turn longer than a minute finishes. Off by default, toggle it under Options.
- **Version and update check** in the menu: shows your current version, plus a one-click "Update available" that opens the latest release when there's a newer one. The check is a once-a-day read of GitHub's public release tag; no data is collected and nothing is sent to the developer.
- Menu **section headers** (Options / Animation / Color) for easier navigation.

## [0.0.5] - 2026-06-22

### Fixed
- The app no longer quits while a session that was already running before you installed it is actively working. Such a session never fired its one-time `SessionStart` hook, so it wasn't being tracked, even though its other hooks fire normally. The status hooks now register the session on any activity, so any actively-working session keeps the icon alive. (Thanks to the bug report that pinned this down.)

## [0.0.4] - 2026-06-22

### Fixed
- The app now actually runs on macOS 12 (Monterey) and later, as the README states. Earlier builds were compiled without a pinned deployment target, so the binary inherited the build machine's OS (macOS 26) and refused to launch on anything older, despite the stated 12.0 requirement. The build now targets macOS 12.0 explicitly.

## [0.0.3] - 2026-06-22

### Changed
- Reworked how the icon appears on desktop-app launch. The app is now started by the existing session hook (which fires when the Claude desktop app opens, when `claude` runs in a terminal, or when a conversation is opened) and quits itself when Claude is closed and no session is active. This keeps the "icon appears when the desktop app opens" behavior from 0.0.2 with no background helper.

### Removed
- The background watcher (a `launchd` LaunchAgent running a shell script) introduced in 0.0.2. It showed up as a "bash" item under Login Items and Extensions, which was confusing. There is no longer any login item or background item. Upgrading from 0.0.2 removes the old LaunchAgent automatically.

### Fixed
- The menu bar icon now reliably disappears when you quit the Claude desktop app, detected directly rather than relying on the session-end hook (which is unreliable during app shutdown).
- Upgrades now self-heal: the app re-runs its installer when the version changes, so updating from an older version refreshes the hooks and removes the old background watcher without any manual step. Previously the installer only ran on a first-ever install.

## [0.0.2] - 2026-06-21

### Added
- Desktop app watcher: the menu bar icon now appears the moment the Claude desktop app opens, before you start a conversation, and disappears shortly after you quit it. Previously the icon only showed once a session began. Implemented as a lightweight `launchd` LaunchAgent that tracks the Claude desktop process (installed via `install.js`, removed via `uninstall.js`).

### Changed
- Ending a Claude Code session no longer hides the icon while the Claude desktop app is still open.

### Fixed
- Uninstall now removes all of the app's own hooks, including the `SessionStart` / `SessionEnd` lifecycle hooks that a previous version left behind. It only ever touches this app's hooks, never any others.

### Notes
- The desktop watcher is part of the DMG / standalone install path. The Claude Code plugin install path keeps the session-only behavior.

## [0.0.1] - 2026-06-21

### Added
- Initial release: macOS menu bar status indicator for Claude Code, driven entirely by Claude Code hooks.
- Animated Claude spark, elapsed turn timer, and an "awaiting permission" dot.
- Two animation styles (Claude, Claude Code) and two color modes (Orange, System), persisted in preferences.
- Refcounted session lifecycle: launches when Claude Code opens, quits when the last session ends.
- Signed and notarized DMG so it opens without a Gatekeeper warning.
- Claude Code plugin marketplace manifest for the plugin install path.

[0.16.1]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.16.1
[0.16.0]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.16.0
[0.15.0]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.15.0
[0.14.0]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.14.0
[0.13.0]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.13.0
[0.12.0]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.12.0
[0.11.0]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.11.0
[0.10.1]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.10.1
[0.10.0]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.10.0
[0.9.0]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.9.0
[0.8.0]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.8.0
[0.7.12]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.7.12
[0.7.11]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.7.11
[0.7.10]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.7.10
[0.7.9]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.7.9
[0.7.8]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.7.8
[0.7.7]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.7.7
[0.7.6]: https://github.com/InfinityScripter/claude-control-bar/commit/5a8e6df52eff51ff843d9c55eb53be4fae44c839
[0.7.5]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.7.5
[0.7.4]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.7.4
[0.7.3]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.7.3
[0.7.2]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.7.2
[0.7.1]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.7.1
[0.7.0]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.7.0
[0.6.0]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.6.0
[0.5.6]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.5.6
[0.5.5]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.5.5
[0.5.4]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.5.4
[0.5.3]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.5.3
[0.5.2]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.5.2
[0.5.1]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.5.1
[0.5.0]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.5.0
[0.4.3]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.4.3
[0.4.2]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.4.2
[0.4.1]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.4.1
[0.4.0]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.4.0
[0.3.4]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.3.4
[0.3.3]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.3.3
[0.3.2]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.3.2
[0.3.1]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.3.1
[0.3.0]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.3.0
[0.2.2]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.2.2
[0.2.1]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.2.1
[0.2.0]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.2.0
[0.1.0]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.1.0
[0.0.5]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.5
[0.0.4]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.4
[0.0.3]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.3
[0.0.2]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.2
[0.0.1]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.1
