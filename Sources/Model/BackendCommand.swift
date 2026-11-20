import Foundation

/// A server or tool switch the backend did not apply: whose config it was meant for, and why not.
struct SwitchRefusal: Equatable {
    let provider: String
    let reason: String
}

/// One request to mcpbar.py, spelled once. The script answers by rewriting its file, never on
/// stdout, so the words on its command line are the whole protocol between the two — and before
/// this they were typed out by hand at every call site, one spelling per provider.
enum BackendCommand {
    /// The full MCP check for one agent; rewrites its mcp.json.
    case mcpRefresh(provider: String)
    case limits(provider: String)
    case codexHooks
    case codexAttention
    case codexHistory
    case claudeHistory
    case codexHooksApprove
    /// Re-point this app's own dead statusLine wrapper in settings.json; a foreign or live one is
    /// left alone by the script, so the call is safe to make on every launch.
    case statuslineHeal
    /// Write a `claude-login.command` next to the state files and have Terminal open it on
    /// `claude auth login`. The script does the opening because a `.command` file needs no
    /// Automation grant, which telling Terminal what to run over Apple Events would.
    case claudeLogin
    case toggleServer(provider: String, name: String, on: Bool)
    case toggleTool(provider: String, server: String, tool: String, prefix: String, on: Bool)
    /// Scan the transcripts and rewrite usage/summary.json for the Usage window. `refresh` is the
    /// user's own press of the refresh button: it also lets the script refetch the price table.
    case usage(refresh: Bool)
    /// Spend one banked reset credit; the script answers in the provider's reset-credit-result.json.
    /// Claude redeems the grant named here. Codex's backend picks the next credit itself, so its
    /// command takes no id.
    case resetCredit(provider: String, creditId: String?)

    /// Which mcpbar.py to run, and with which interpreter; an empty script when there is none.
    ///
    /// The copy inside the app first: build.sh puts one there in every channel, and it is the one
    /// built with this binary. `paths` — the plugin's paths.json — is read only when the bundle
    /// has no script. The order used to be the other way round and decided once per launch: an
    /// app from the DMG beside an older plugin ran the plugin's script for weeks, new commands
    /// came back as its usage text, and once a plugin update removed the versioned folder every
    /// run failed on a path that no longer existed, until the app was restarted.
    static func backend(bundledScript: String?, paths: () -> [String: Any]?,
                        exists: (String) -> Bool) -> (python: String, script: String) {
        if let bundledScript, exists(bundledScript) { return ("/usr/bin/python3", bundledScript) }
        if let plugin = paths(), let script = plugin["script"] as? String, exists(script) {
            return (plugin["python"] as? String ?? "/usr/bin/python3", script)
        }
        return ("/usr/bin/python3", "")
    }

    /// The agent whose config a switch writes; nil for every command that is not a switch.
    var switchProvider: String? {
        switch self {
        case .toggleServer(let provider, _, _), .toggleTool(let provider, _, _, _, _):
            return provider
        default:
            return nil
        }
    }

    /// How long the app waits before it stops the script itself. The script bounds its own calls,
    /// so this is a second net and sits above those budgets, never below them: a run stopped
    /// while still inside its own budget would be a healthy check killed. It is for the hang
    /// those budgets cannot see — a session folder on a FUSE volume that has stopped answering
    /// blocks before any of them starts — which used to leave the MCP tab checking, the Codex
    /// limits unasked or History loading until the app was restarted.
    var deadline: TimeInterval {
        switch self {
        // Python gives up after 1.5 s; the answer is worth nothing a few seconds later.
        case .codexAttention:
            return 3
        // A full check is `claude mcp list` at up to 120 s per root and per project with servers,
        // or Codex's app-server at up to 60 s plus 30 s per `codex mcp` call. Ten minutes is when
        // the next one is due anyway.
        case .mcpRefresh:
            return 600
        // A Codex switch ends in that same full re-read; Claude's only patches its own file.
        case .toggleServer(provider: "codex", _, _), .toggleTool(provider: "codex", _, _, _, _):
            return 600
        // Far past a first full scan (under a minute for 20 GB of transcripts). A scan that hung
        // — a stuck price download, an unreadable volume — would otherwise hold the Usage
        // window's refresh button until the app was restarted.
        case .usage:
            return 600
        // Never stopped from outside: a redemption cut short would leave nobody knowing whether
        // the credit was spent. The script bounds each of its own waits.
        case .resetCredit:
            return .infinity
        default:
            return 120
        }
    }

    /// Why a switch bounced, for the MCP tab; nil for a run that worked or was not a switch.
    ///
    /// Taken from the exit code and stderr, which is where the script explains a failure (stdout
    /// is not read at all): `refused: <reason>` and exit 2 when it declined to write, otherwise
    /// whatever the run died of, worded the way a failed hook install already is.
    func refusal(_ run: HookInstall.Run) -> SwitchRefusal? {
        guard let provider = switchProvider, !run.succeeded else { return nil }
        let marker = "refused: "
        let refused = run.output.split(whereSeparator: \.isNewline).last { $0.hasPrefix(marker) }
        let reason = refused.map { HookInstall.clipped(String($0.dropFirst(marker.count))) }
            ?? HookInstall.describe(run)
        return SwitchRefusal(provider: provider, reason: reason)
    }

    var arguments: [String] {
        switch self {
        case .mcpRefresh(let provider):
            return provider == "codex" ? ["codex-mcp", "refresh"] : ["refresh"]
        case .limits(let provider):
            return [provider == "codex" ? "codex-limits" : "limits"]
        case .codexHooks:
            return ["codex-hooks"]
        case .codexAttention:
            return ["codex-attention"]
        case .codexHistory:
            return ["codex-history"]
        case .claudeHistory:
            return ["claude-history"]
        case .codexHooksApprove:
            return ["codex-hooks", "approve"]
        case .statuslineHeal:
            return ["statusline", "--heal"]
        case .claudeLogin:
            return ["claude-login"]
        case .toggleServer(let provider, let name, let on):
            let words = ["toggle-server", name, on ? "--on" : "--off"]
            return provider == "codex" ? ["codex-mcp"] + words : words
        case .toggleTool(let provider, let server, let tool, let prefix, let on):
            let flag = on ? "--on" : "--off"
            // Codex keeps its deny list per server by plain tool name, so it has no rule to pass.
            // Claude's rule goes first for an older mcpbar.py, which reads exactly one positional
            // argument; `--server`/`--tool` is what a current one uses, because only it can turn
            // a display name into the spelling Claude Code puts inside a tool name.
            if provider == "codex" {
                return ["codex-mcp", "toggle-tool", "--server", server, "--tool", tool, flag]
            }
            return ["toggle-tool", MCPServer.fullToolName(prefix: prefix, tool: tool),
                    "--server", server, "--tool", tool, flag]
        case .usage(let refresh):
            return refresh ? ["usage", "--refresh"] : ["usage"]
        case .resetCredit(let provider, let creditId):
            if provider == "codex" { return ["codex-reset-credit"] }
            return ["claude-reset-credit"] + (creditId.map { [$0] } ?? [])
        }
    }
}
