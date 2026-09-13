import Foundation

// Pure formatting for the session card, kept in the model half so the model checks can pin it.
enum SessionFormat {
    // A short all-caps badge naming the surface a session runs on, one uniform 3-letter pill.
    // APP is a desktop app. IDE is a session living inside an editor — Claude Code's extension
    // panel (entrypoint "claude-vscode") or its CLI in a VS Code-family integrated terminal
    // (Cursor, Windsurf and VS Code all report TERM_PROGRAM="vscode"). CLI is a standalone
    // terminal. EXEC is Codex's non-interactive run, which never asks for permission.
    //
    // Two paths to one pill, because the two agents know different things about themselves:
    // Codex writes its surface into the state file (it is a fact from its own rollout's
    // originator), while Claude's has to be inferred here. An unknown Codex surface yields no
    // badge at all — a wrong "CLI" on a desktop session is worse than an empty spot.
    static func surfaceTag(_ s: Session) -> String {
        if s.provider == "codex" { return s.surface.uppercased() }
        if s.entrypoint == "claude-desktop" { return "APP" }
        if s.entrypoint.isEmpty { return "" }
        if s.entrypoint == "claude-vscode" || s.termProgram == "vscode" { return "IDE" }
        return "CLI"
    }

    // "claude-fable-5-1" -> "Fable 5.1", "claude-opus-4-8-20260101" -> "Opus 4.8". Unknown
    // shapes fall through untouched: a wrong pretty name is worse than a raw id.
    static func prettyModel(_ id: String) -> String {
        var parts = id.lowercased().split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        guard let family = parts.first, !family.isEmpty, family.first!.isLetter else { return id }
        let digits = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) && $0.count < 8 }
        let version = digits.joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }

    // 87_956 -> "88k", 1_000_000 -> "1M": the card is glanced at, not audited.
    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return m == m.rounded() ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
        if n >= 1000 { return "\((Double(n) / 1000).rounded().clampedInt)k" }
        return "\(n)"
    }

    static func elapsed(_ secs: Int) -> String {
        let minutes = secs / 60
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

}
