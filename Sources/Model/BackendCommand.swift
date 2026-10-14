/// One request to mcpbar.py, spelled once. The script answers by rewriting its file, never on
/// stdout, so the words on its command line are the whole protocol between the two — and before
/// this they were typed out by hand at every call site, one spelling per provider.
enum BackendCommand {
    /// The full MCP check for one agent; rewrites its mcp.json.
    case mcpRefresh(provider: String)
    case limits(provider: String)
    case codexHooks
    case codexAttention
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

    func backend(normal: (python: String, script: String), bundledScript: String?) -> (python: String, script: String) {
        if case .codexAttention = self { return ("/usr/bin/python3", bundledScript ?? "") }
        return normal
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
        }
    }
}
