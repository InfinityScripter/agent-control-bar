# Privacy

Agent Control Bar keeps session metadata and settings on your Mac. It runs no account or cloud
service. The one thing it sends the developer is a daily count of one, with
nothing in it that names a machine — described in full under "The anonymous ping" below, with
the switch that stops it.

## Network

- **A usage poll to `api.anthropic.com` every five minutes**, authenticated with the OAuth token
  Claude Code keeps in your Keychain. It is one request (`/api/oauth/usage?cedar_ember=1`) and
  returns your limit percentages — the same numbers `/usage` shows — together with the weekly
  windows of individual models, the percentage of your monthly extra-usage budget, and the reset
  credits banked on your account: how many, of which kind, when they expire, and the grant ids
  needed to redeem one. These are stored on your Mac in `limits.json` and `account.json` and go
  nowhere else. The `cedar_ember=1` parameter is what asks for the reset credits; it carries
  nothing about you. The Usage window's refresh button makes the same request at once, never
  beside one that is already on its way. The token is sent to
  Anthropic and to no other host: the request refuses redirects outright, so a `30x` answer from
  the endpoint, a proxy or a future move of the API cannot carry the token to another origin —
  it is reported as a failed poll instead. Switch **Limits via Anthropic API** off in Settings → General and
  this request never happens.
- **Current Codex limits every five minutes and on panel opens**, with at least a minute between
  requests: the app calls `account/rateLimits/read` through a read-only `codex app-server` process.
  Codex handles the request to OpenAI and its own authentication. The app does not read Codex's
  credentials itself or refresh its tokens. From the limits answer it keeps the plan name, the
  monthly credit limit percentage and the number and earliest expiry of banked reset credits.
  At most once every 24 hours the app also starts a second read-only `codex app-server` and
  calls `account/read` to learn the e-mail address of the signed-in ChatGPT account. Credit ids,
  the account id and the workspace name are not stored. Switch **Codex limits** off in
  Settings → General to stop these requests and the session-snapshot fallback.
- **Redeeming a banked reset credit — only when you press Use / Use reset in the Usage window
  and confirm.** It spends one credit on your account and cannot be undone; the app never
  redeems anything on its own. For Claude the app sends one
  `POST https://api.anthropic.com/api/organizations/<your organization id>/reset_rate_limits`
  carrying the grant id you chose and a random request id. It is authenticated with the same
  OAuth token and identifies itself the way the Claude Code CLI does
  (`User-Agent: claude-cli/<installed version> (external, cli)`; the version comes from running
  `claude --version`) — the one request of this app that does. Redirects are refused. For Codex
  the app starts a regular — not read-only — `codex app-server`, initialised with
  `capabilities.experimentalApi: true`, and calls `account/rateLimitResetCredit/consume` with a
  random idempotency key; Codex makes the request to OpenAI and picks the credit itself. After
  an answer the app asks for the limits again (Claude once, Codex up to four times over a few
  seconds) so the bars show what the reset did. This happens whatever the two limits switches
  say: it is the action you asked for.
- **Model prices for the Usage window, from LiteLLM's public table**: a plain `GET` of
  `https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json`
  and, only if that fails, of the same file through
  `https://api.github.com/repos/BerriAI/litellm/contents/…`. No key, no cookie, no parameters
  and nothing about you or your usage. It is made only as part of a usage scan, and a scan runs
  only for the Usage window — when it is opened or shown with figures older than five minutes,
  on its refresh button, and after you change a custom price. By itself the table is fetched at
  most once every 24 hours; a press of refresh, or a model the cached table does not know, may
  fetch it again, at most once a minute. The table is cached in `usage/model-rates.json`;
  without network and without a cache every cost reads as unpriced. Costs are computed on your
  Mac from that table and are an estimate at API prices, not your bill.
- **DeepSeek balance and Z.ai Personal Coding Plan quotas**, if you add a key in **Connected
  accounts**. The app reads `https://api.deepseek.com/user/balance` or
  `https://api.z.ai/api/monitor/usage/quota/limit` every five minutes and on panel opens, with
  at least a minute between automatic requests. Each key is sent only to its own service,
  and redirects are refused. Account figures are held in memory. Hide a service in **Model
  services** to pause checks or use **Remove key** to disconnect it.
- **One update check a day**: a request to GitHub's public releases API for the latest tag, and
  one to Homebrew's public formulae API for the current cask version. Both only decide whether
  the panel shows an update banner.
- **The update itself, when you ask for it**: clicking *Download and install* in the panel's
  "What's new" window downloads that release's DMG from GitHub (or its source archive, built
  locally, for a release that shipped without a DMG). This request only ever happens on that
  click — the daily check above never downloads anything.
- **Limit reset odds from `whenreset.app`, at most once every 15 minutes**: a plain `GET` of
  `https://whenreset.app/api/v1/resets.json`, the site's public estimate of an early Claude or
  Codex limit reset and its count of past resets. No key, no cookie, no parameters and nothing
  about you or your usage; the request refuses redirects. The last answer is kept in the app's
  own preferences so the panel can show it at launch. Switch **Limit reset odds** off in
  Settings → General and this request never happens, and the kept answer is deleted.

GitHub, Homebrew, Anthropic, OpenAI, DeepSeek, Z.ai and whenreset.app see requests sent to their
services. Only the anonymous ping described below goes to the developer. There is no crash reporting
or analytics kit in the binary. Token counts, costs and transcripts are never part of any request.

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

- **Session transcripts** (`~/.claude/projects/**/*.jsonl`). Three reasons. The context percentage
  is computed from the token counts the transcript records, since Claude Code hands that figure
  to a `statusLine` command and to nothing else. The last few KB are parsed for the interrupt
  marker Claude Code writes when a turn is cut short, which is how the app notices a turn that
  ended without an event. Both read the file; neither copies it anywhere. And the Usage window
  counts tokens and cost from them: when it is opened, every transcript changed in the last 92
  days is read in full, and from each answer of the model the app takes its token counts, model
  name, speed tier, time, session id and request id — the last two only to count sessions and to
  count a copied request once. The text of prompts and replies is skipped. Nothing of this
  leaves the Mac; what was taken is kept in `usage/scan-cache.sqlite3` (see "Where it writes"),
  so the next scan reads only the files that changed.
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
  From its `oauthAccount` block the app also reads your account e-mail address, shown in the
  Usage window and stored in `account.json`, and — only at the moment you redeem a reset credit —
  your organization id, which the request address needs and which is never stored.
- **Your MCP servers**, via `claude mcp list` and a `tools/list` request to each. That returns
  tool names, descriptions and parameters — the same information Claude Code itself receives.
- **Claude Code's own MCP logs** (`~/Library/Caches/claude-cli-nodejs/**/mcp-logs-*`), for the
  tool count each server prints when it starts. Only that number is taken.
- **Claude desktop's session cache** (`~/Library/Application Support/Claude/claude-code-sessions`),
  for the tool list of your claude.ai connectors: they report nothing at startup, so this is the
  only place their schemas exist locally.
- **Your Claude Code OAuth token**, if the Anthropic limits poll is switched on (Settings → General → "Limits
  via Anthropic API"). Read from the login Keychain entry, or from `~/.claude/.credentials.json`
  where there is no Keychain. From the same Keychain entry the app keeps two non-secret fields,
  `subscriptionType` and `rateLimitTier` (your plan), in `account.json`. The token itself is
  sent to `api.anthropic.com` and nowhere else, is never written to disk by this app, and never
  appears in a log. With the option off it is read only when you redeem a reset credit.
- **Codex's own session files** (`~/.codex/sessions/**/rollout-*.jsonl`), as a fallback when
  **Codex limits** is on and the live request fails or returns no usable windows. The app reads
  the tails of at most twelve recent files and selects the newest measurement for each pool by
  its recorded timestamp. It keeps percentages, window lengths, reset times, plan and measurement
  times; it does not copy conversations. Switching **Codex limits** off stops this fallback read.
  Codex manages its own authentication; this app does not open `~/.codex/auth.json` itself.
  The Usage window reads these files too, in full and whatever that switch says: every rollout
  of the last 92 days, for the same token counts, model names, times and session ids as from
  Claude's transcripts and nothing else. Compressed rollouts (`*.jsonl.zst`) are read by piping
  them through a `zstd` binary or a `node` found on this Mac; with neither they are skipped and
  the window says so.
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
- **Local process metadata** for Codex terminal sessions: this user's process names, controlling
  terminal devices and process start times, through macOS's native process API. The app does not
  read command-line arguments for this check, send this metadata anywhere, or stop those processes.
- **The current directory and git branch** of each session, to label its row.

## Where it writes

Everything of its own lives under `~/.claude/control-bar/`. The complete list:

- **Per session:** one small JSON file in `state.d/` (state, working directory, transcript path,
  pid, context figures), and the context percentage the session's status line reported in
  `context.d/`. The SessionEnd hook removes them. A Codex session's file is the same shape, in
  `codex/state.d/`, plus which surface it runs on. If the client exits without a hook, the app
  ignores the closed status but leaves its small JSON file in place so cleanup cannot delete a
  concurrent hook event. Conversation history is never deleted by this cleanup.
- **Removed session statuses:** `dismissed-sessions.json` stores provider/session ids and hashes
  of the exact state-file versions removed automatically or with **Remove from list**. It is readable only by
  your account and contains no conversation text. A new hook event is a different version and
  becomes visible again. Removing a status never stops the agent process or deletes a chat.
- **The MCP picture:** `mcp.json`, `codex/mcp.json` for Codex's servers, the per-server
  descriptions cache `descriptions.json`, and the model-to-context-window table
  `model-windows.json`.
- **Codex history:** opening or refreshing **Codex history** requests up to 50 recent thread
  summaries from Codex's local index. The private `codex/history.json` snapshot stores IDs,
  titles, directories, branches, host and model service labels, update times, and profile path.
  Prompts, replies, and credentials are excluded from the snapshot.
- **The limits:** `limits.json`, and `codex/limits.json` for Codex's windows — percentages,
  window lengths, reset stamps, plan, source and measurement times. Beside them, `limits-status.json`
  and `codex/limits-status.json` record how each provider's latest poll ended, when, and a short
  reason. The Codex reason is a fixed error category. These status files never contain tokens
  or raw responses; the panel reads them to explain why figures stopped updating.
- **Account details and reset credits:** `account.json` and `codex/account.json` — plan, account
  e-mail, extra limit rows, the monthly spend percentage and banked reset credits (for Claude
  including grant ids; for Codex also the time the e-mail was last asked for). When you redeem a
  credit: `reset-credit-pending.json` (a random request id, the grant id and a timestamp; it is
  reused for at most 24 hours so a retry cannot spend a second credit, and the file is removed
  when the service gives a definite answer or replaced on the next attempt),
  `reset-credit-result.json` (the outcome or a fixed error category) and `reset-credit.lock`;
  the same three under `codex/`. All are readable only by your account and hold no token and no
  raw server response. If an account file cannot be written, one line with the error's type name
  goes to `problems.log`, or to `codex/problems.log` for Codex.
- **Usage history, once the Usage window has been opened:** `usage/summary.json` — tokens and
  estimated cost per provider, model and day (per hour for the last 24 hours) for the last 1, 7,
  30 and 90 days, with counts of sessions and files; `usage/status.json` — how far a running
  scan is and how the last one ended; `usage/scan-cache.sqlite3` — what the scan took from each
  transcript (see "What it reads"): the file's path, size and modification time, session ids,
  model names, times, request ids and token counts, no message text, dropped after 92 days;
  `usage/model-rates.json` and `usage/rates-state.json` — LiteLLM's price table and when it was
  last fetched or failed; `usage/prices.json` — the custom prices and model mappings you enter
  in the window, written by the app itself; and `usage/scan.lock`. The cache keeps counting a
  session whose transcript you have since deleted, until it ages out; delete the `usage/` folder
  to forget all of it — the next opening of the window rebuilds it from the transcripts that
  are still there.
- **Install bookkeeping:** `owner.json` (which channel owns the hooks), `paths.json` (where the
  backend script and interpreter are), a copy of the hook scripts and the build script, and
  `releases/` with the source archives a plugin-channel update downloaded.
- **Markers and locks:** `quit-intent` (a Quit from the panel, so the hooks do not relaunch the app),
  `self-heal-probed` (an empty file whose date throttles the hooks' "is the app running" check),
  and `refresh.lock`, `settings.lock`, `build.lock` while the matching operation runs.
- **The statusLine capture, if installed:** `statusline-saved.json` (your previous `statusLine`
  object, whole, so `/limits-capture uninstall` can restore it), `statusline-inner-command` and
  `statusline-installed.json`. At every launch an installed copy also checks that the capture
  still works: it reads the `statusLine` command from `~/.claude/settings.json` and these three
  files, and only when the command is the one this app wrote and the wrapper file it names no
  longer exists (the plugin path carries the version; the app bundle was renamed) it re-points
  that one `command` field to the current wrapper and updates `statusline-installed.json`. The
  other `statusLine` fields, your inner command and `statusline-saved.json` are left as they
  are; a status line that is not this app's, or a wrapper that still exists, is not written to
  at all. A rewrite takes the same dated backup of `settings.json` as a switch does.
- **The sign-in helper, only when you press the button:** `claude-login.command`, written when
  "Sign in to Claude Code" is pressed in the panel and at no other time. It is a shell script of
  two or three lines — `exec "<the claude binary this app found>" auth login`, or, when no binary was found,
  a line that prints "Claude Code CLI not found. Install it, then run: claude auth login" and
  waits for a key — and the backend hands it to `/usr/bin/open`, so Terminal runs it the way it
  runs any `.command` file, with no Automation grant. The sign-in itself happens in Claude Code
  and your browser; the file holds no token or account data, and nothing here reads what
  Terminal shows.
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

The DeepSeek and Z.ai keys you add are separate entries in macOS Keychain. Use **Remove key**
in **Connected accounts** to delete an entry, including before uninstalling the app.

Once installed, the hook scripts in `~/.claude/control-bar/` run on every Claude Code event. That
is how the app knows anything at all, and it makes those files trusted local code — worth keeping
in a directory only you can write to.

---
Back to the [README](README.md).
