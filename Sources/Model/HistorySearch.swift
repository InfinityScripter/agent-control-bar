import Foundation

/// What the Claude and Codex history lists share: how a query matches a chat, and how a path
/// goes into a resume command the user pastes into a shell.
enum HistorySearch {
    /// Every word of the query has to appear in one of the fields; an empty query matches all.
    static func matches(_ query: String, in fields: [String]) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// An absolute path single-quoted for a shell, or nil for one that could break out of the
    /// line it is pasted into.
    static func shellPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        return "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
