import Foundation

/// Turning a row into the T3 Code thread that hosts its session.
///
/// T3 Code runs `claude` as its own child process, so the bundle id the hooks record can only
/// bring the app's window forward — on whichever thread it happened to be showing. The app parses
/// t3code://threads/<environment>/<thread> itself, and both halves are on hand: T3 exports the
/// thread id to the session as T3CODE_THREAD_ID, which the hooks record, and files the id of its
/// local environment under its home directory.
///
/// Claude only. Codex threads share one `codex app-server`, and T3 hands each its thread id
/// through per-thread shell configuration rather than the process environment the hooks see.
/// And the ordinary install only: a development build keeps another home and another scheme.
enum T3Sessions {
    static let defaultHome = (NSHomeDirectory() as NSString).appendingPathComponent(".t3")

    /// The link that opens one thread, or nil when the session is not T3 Code's or this machine
    /// has no environment id for it — then the click falls back to raising the hosting app.
    static func threadURL(threadID: String, home: String = defaultHome) -> URL? {
        let file = (home as NSString).appendingPathComponent("userdata/environment-id")
        guard let environment = (try? String(contentsOfFile: file, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let environment = SessionFormat.urlPathComponent(environment),
              let thread = SessionFormat.urlPathComponent(threadID)
        else { return nil }
        return URL(string: "t3code://threads/\(environment)/\(thread)")
    }
}
