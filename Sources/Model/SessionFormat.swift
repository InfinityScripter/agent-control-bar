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
        guard s.provider == "codex", s.surface == "app", !s.id.isEmpty else { return nil }
        // Percent-encoded as a path component: an id carrying a slash would otherwise address a
        // different route of the app, and one carrying "?" would arrive as a query.
        guard let id = s.id.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~")))
        else { return nil }
        return URL(string: "codex://threads/" + id)
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
