# Experimental Claude Code mod

The first prototype collects Claude CLI activity and context through the mods SDK. The native menu bar app reads the same session JSON as before. Codex continues to use its existing integration.

Use Claude Code CLI **2.1.287 or later** and macOS 13+, with Node.js and `/usr/bin/python3` available. The prototype was validated and tested against SDK 2.1.287. That SDK exposes `process.run` only on CLI hosts, so Desktop stays on the existing command hooks.

## Package and local checks

The plugin is named `agent-control-bar` and includes the mod through `hooks/hooks.json`. The marketplace retains its registered name `claude-control-bar`; its `renames` map transfers existing enabled-plugin and configuration entries to the new plugin name. See the [installation and migration instructions](../README.md#claude-code-plugin).

Run from the repository root with Claude Code 2.1.287+:

```bash
claude plugin validate .claude-plugin/plugin.json
claude plugin validate .claude-plugin/marketplace.json
claude plugin test .
```

The SDK test stubs session data and process execution; it sends no model request and does not install the app. It checks tool-result pass-through, measured context, the question render/answer sequence and an aborted turn.

To try the package in a new CLI session:

```bash
claude --plugin-dir "$PWD"
```

This runs the normal plugin bootstrap, including app launch/build and ownership of Claude command hooks. Close sessions using the old plugin first and keep the checkout available while using it. The package's command hooks contain the new lease checks; using only the mod alongside older global hook copies would let them overwrite its state.

## Collection and fallback

The mod observes session and turn boundaries, main-agent tool calls and the actual `AskUserQuestion` render event. It reads context tokens, window size, percentage and available cost directly from `session.usage()`. It never treats a permission decision of `ask` by itself as proof that a question is visible.

A permission notification with one active tool can be associated with that tool. A notification without an unambiguous tool id yields collection to the command hooks until the next turn boundary. Worker-agent events do not change the main session state.

Each state publication uses a short Python process and an atomic replacement, because SDK `fs.write` is not atomic. State files have mode 0600 and their directory has mode 0700. The five-second heartbeat refreshes activity and context. It preserves a permission request's timestamp so the native answer-recovery logic can still use it.

The legacy hooks skip state writes only while the record has a live PID and a mod lease no older than 15 seconds. App launch, recovery after a crash and explicit Quit handling continue to work. If publication fails, a later command-hook event can resume collection after the last successful lease expires; lease expiry alone does not change the visible state.

Session end removes its own file and invalidates pending observations before removal. `/clear` and `/resume` can change the session id without another `session.start`; the next turn initializes the replacement session. Enabling or reloading the mod during an existing turn releases its previous mod lease, leaves that turn with the legacy collector and starts mod collection on the next turn.

## Prototype limits

- Desktop still uses command hooks because the publisher requires the CLI process API.
- Legacy command hooks remain installed as fallback, so this prototype does not eliminate their process-launch overhead.
- `duration`, `linesAdded`, `linesRemoved` and `dirty` retain their initial values while the mod owns a session. Context, activity, model, working directory and available cost refresh through the SDK.
- Permission notifications do not carry a tool id. Parallel prompts use the legacy fallback described above.
- The native app keeps its existing bundle identity and data directory. The source package includes the mod; a published release must carry these changes before the marketplace installation commands can fetch them.

Useful SDK references: [mods overview](https://code.claude.com/docs/en/plugins/mods/overview), [API](https://code.claude.com/docs/en/plugins/mods/api), [testing](https://code.claude.com/docs/en/plugins/mods/test).
