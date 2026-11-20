import Foundation

enum SessionActivityGroup: String, CaseIterable {
    case needsYou = "Needs you"
    case working = "Working"
    case idle = "Idle"

    init(state: String, asyncQuestion: Bool) {
        if state == "permission" || asyncQuestion { self = .needsYou }
        else if isWorkingState(state) { self = .working }
        else { self = .idle }
    }
}

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
    // originator), while Claude's has to be inferred here. An unknown surface yields no badge at
    // all, for either agent — a wrong "CLI" on a desktop session is worse than an empty spot. So
    // Claude's terminal badge needs the one entrypoint that names a terminal: an SDK run or a
    // host this build has never heard of is not a CLI session just because it is nothing else.
    static func surfaceTag(_ s: Session) -> String {
        if s.provider == "codex" { return surfaceLabel(s.surface) }
        // "t3-code" is T3 Code running Claude in one of its threads: no terminal, an app's window.
        if s.entrypoint == "claude-desktop" || s.entrypoint == "t3-code" { return surfaceLabel("app") }
        if s.entrypoint.isEmpty { return "" }
        if s.entrypoint == "claude-vscode" || s.termProgram == "vscode" { return surfaceLabel("ide") }
        return s.entrypoint == "cli" ? surfaceLabel("cli") : ""
    }

    // The word for a surface code, for the whole Sessions tab: the Live rows above and the Codex
    // history list both ask here, so one chat is not "CLI" while it runs and "Terminal" once it
    // has ended. The pill's short spelling won because a Live row has no room for a longer one.
    // "t3" is a chat T3 Code started, which only Codex's own history index can name.
    static func surfaceLabel(_ code: String) -> String {
        switch code {
        case "cli": return "CLI"
        case "ide": return "IDE"
        case "app": return "APP"
        case "exec": return "EXEC"
        case "t3": return "T3"
        default: return ""
        }
    }

    // The link that opens ONE Codex conversation, or nil when the click belongs somewhere else.
    //
    // Codex's desktop app registers the `codex://` scheme and spells a single thread as
    // `codex://threads/<id>` — its own resources carry that template, and the id the hooks record
    // is the thread id. That is the same depth a Claude desktop row already gets: the conversation
    // itself, not merely the app, which is normally frontmost anyway.
    //
    // Only a session Codex itself calls a desktop one. A terminal session is read where the user
    // put it, and pulling them into another app for the same conversation is worse than raising
    // that terminal. An unknown surface is NOT treated as desktop either, however tempting: this
    // build's own hooks answer "unknown" for an originator they have never seen, and a CLI
    // session whose terminal left no trace in the environment would then be dragged into the
    // desktop app. Unknown means unknown here, the same as it does where the surface is read.
    static func codexThreadURL(_ s: Session) -> URL? {
        guard s.provider == "codex", s.surface == "app" else { return nil }
        return codexThreadURL(id: s.id)
    }

    static func codexThreadURL(id: String) -> URL? {
        urlPathComponent(id).flatMap { URL(string: "codex://threads/" + $0) }
    }

    // Whether a click on the row has anywhere to go: one term per branch of the controller's
    // openSession, in its order. A session can be alive with no window on record — a terminal
    // whose environment named neither a program nor a bundle — and for that one the panel stays
    // open and the row says so, instead of closing on a click that raises nothing.
    //
    // It answers "is a place recorded", not "will the open succeed": whether the app is still
    // installed is a question for the system, asked at the click.
    static func canOpen(_ s: Session) -> Bool {
        (s.entrypoint == "t3-code" && !s.t3Thread.isEmpty) || codexThreadURL(s) != nil
            || s.entrypoint == "claude-desktop" || !s.termBundle.isEmpty || !s.termProgram.isEmpty
    }

    /// An id as one path component of a deep link, or nil for an empty one. Percent-encoded: an id
    /// carrying a slash would otherwise address a different route of the app, and one carrying
    /// "?" would arrive as a query.
    static func urlPathComponent(_ id: String) -> String? {
        guard !id.isEmpty else { return nil }
        return id.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~")))
    }

    // The session's terminal device as a string safe to name inside an AppleScript literal, or nil
    // when there is nothing usable to name.
    //
    // Two jobs in one place. It normalises — the hooks write "/dev/ttys004", but a hand-written or
    // older file may carry the bare "ttys004" that `ps` prints, and the scripting dictionaries
    // compare against the full path. And it refuses anything that is not a device name: this string
    // is interpolated into `if tty of t is "…"`, where one quote character would close the literal
    // and leave whatever follows as script. The state file is a file a user is invited to look at
    // and can edit, so "it came from our own hook" is not a guarantee about its contents.
    //
    // Letters, digits and slashes only, because that is what a tty device name is. No attempt to
    // escape a richer string: refusing is the answer, and the caller has a perfectly good fallback.
    static func ttyDevice(_ tty: String) -> String? {
        guard !tty.isEmpty else { return nil }
        let dev = tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
        guard dev.count <= 64,
              dev.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "/") }),
              dev.hasPrefix("/dev/tty")
        else { return nil }
        return dev
    }

    // "claude-fable-5-1" -> "Fable 5.1", "claude-opus-4-8-20260101" -> "Opus 4.8". Unknown
    // shapes fall through untouched: a wrong pretty name is worse than a raw id.
    static func prettyModel(_ id: String) -> String {
        var parts = id.lowercased().split(separator: "-").map(String.init)
        guard parts.first == "claude" else { return id }
        parts.removeFirst()
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
