import Foundation

/// What a look at one of the state files another process rewrites found. Three outcomes, because
/// the three mean three different things to a reader: no file at all is an answer (the figures
/// go, rather than standing until a restart), an unchanged mtime is a stat and no parse, and a
/// file that is there but unreadable is a half-written rewrite — for the few milliseconds that
/// lasts, the previous parse is the better of the two things to show, so it reads as unchanged
/// rather than as missing.
enum StateFileLook {
    case missing
    case unchanged
    case changed([String: Any])

    /// Read on a stat-per-tick gate: at 2.5 Hz for the app's whole life, against files another
    /// process rewrites every few minutes. Writes are atomic renames, so a changed mtime always
    /// means a whole new file. `gate` holds the mtime of the last successful parse.
    static func at(_ path: String, gate: inout Date?) -> StateFileLook {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate])
            as? Date
        guard let stamp else {
            gate = nil
            return .missing
        }
        if stamp == gate { return .unchanged }
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unchanged }
        gate = stamp
        return .changed(object)
    }
}
