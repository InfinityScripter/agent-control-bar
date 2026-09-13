import Darwin
import Foundation

/// Is a process with this name running right now?
///
/// The app decides whether it is still needed. Counting the session files hooks leave behind
/// answers that only when the hooks actually fired: a session started where `node` is not on the
/// PATH, or with hooks switched off, or under `--setting-sources` that exclude the user's
/// settings, writes no file at all — and the app then quit about ten seconds after launch while
/// Claude Code was plainly running in a terminal. It looked like the app only worked with the
/// desktop app, because the desktop app is a GUI application and was being detected a second way.
///
/// So the last word before quitting is the process table itself. Asked through libproc rather
/// than by spawning `pgrep`: this is called from the timer on the main thread, and a fork+exec
/// there is a visible hitch for an answer two syscalls can give.
enum RunningProcesses {
    /// Every live pid — the WHOLE table. Split out of exists() so the model checks can pin
    /// that wholeness directly (pid 1 must be in here), because the naming half below is
    /// permission-gated and cannot witness it.
    static func allPids() -> [pid_t] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        // Slack on top of the count: processes start between the two calls, and a buffer that is
        // exactly full silently truncates the list — the missed pid could be the one being
        // looked for.
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let width = Int32(MemoryLayout<pid_t>.size)
        // proc_listallpids returns a COUNT of pids, not bytes — libproc divides by sizeof(int)
        // itself (the sizing call above already relies on that). Dividing again by the width
        // walked only the first quarter of the table, and `claude` sitting in the other three
        // quarters read as "not running" — the app then quit itself mid-session, the exact
        // regression this file's header says it exists to prevent. min() guards the paranoid
        // case of the kernel reporting more than the buffer holds.
        let count = proc_listallpids(&pids, Int32(pids.count) * width)
        guard count > 0 else { return [] }
        return Array(pids.prefix(min(Int(count), pids.count))).filter { $0 > 0 }
    }

    static func exists(named name: String) -> Bool {
        existsAny(of: [name])
    }

    /// Is any of these process names running? One walk of the table for all of them: with two
    /// agents to look for, asking twice doubles a scan of every pid on the machine for an answer
    /// a single pass gives.
    static func existsAny(of names: Set<String>) -> Bool {
        var buffer = [CChar](repeating: 0, count: 256)
        for pid in allPids() {
            // Fails with EPERM for processes belonging to other users; an agent session is
            // always this user's, so there is nothing to recover there.
            guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            if names.contains(String(cString: buffer)) { return true }
        }
        return false
    }
}
