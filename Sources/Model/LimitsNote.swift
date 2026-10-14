import Foundation

/// The words under the limits strip about how old its figures are.
enum LimitsNote {
    /// How old a figure is. Short: the line shares the footer with two buttons across 300pt, and
    /// "measured 4 minutes ago" truncated to "Limits measured 2…", which says nothing at all.
    static func age(of ts: Double, now: Double) -> String {
        let minutes = (now - ts).clampedInt / 60
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        // Rolled up past an hour for the same reason the panel's reset countdown drops the minutes
        // past a day: a Codex snapshot is allowed to be days old while its weekly window is still
        // open, and "8640 min ago" is arithmetic in a line that has to fit beside two buttons.
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h ago" : "\(hours / 24)d ago"
    }

    /// The footer line, one entry per provider that has figures. Each provider is dated by its own
    /// stamp: one shared "oldest" stamp let a Claude poll that stopped a day ago make live Codex
    /// figures read "1d ago". A lone provider needs no name to be told apart from anything.
    static func footer(_ groups: [(title: String, age: String)]) -> String {
        switch groups.count {
        case 0: return ""
        case 1: return "Limits · " + groups[0].age
        default: return groups.map { "\($0.title) \($0.age)" }.joined(separator: " · ")
        }
    }
}
