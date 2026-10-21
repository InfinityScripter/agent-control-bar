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
    enum Presence { case alive, dead, unknown }
    struct CodexOwner {
        let terminal: UInt32
        let startedAt: Double
    }

    struct CodexSnapshot {
        let takenAt: Date
        let owners: [CodexOwner]
        let complete: Bool

        func presence(on terminal: UInt32, eventAt: Double) -> Presence {
            guard eventAt > 0 else { return .unknown }
            // Hooks have whole-second timestamps; a start in that same second may be the
            // original owner. A start in a later second belongs to a reused terminal.
            if owners.contains(where: { $0.terminal == terminal && $0.startedAt < eventAt + 1 }) {
                return .alive
            }
            return complete ? .dead : .unknown
        }

        func presence(of session: Session) -> Presence {
            guard session.provider == "codex", session.surface == "cli",
                  session.tty.hasPrefix("/dev/tty"), session.ts > 0,
                  session.fileMtime <= takenAt else { return .unknown }
            var info = stat()
            guard stat(session.tty, &info) == 0, (info.st_mode & S_IFMT) == S_IFCHR else { return .unknown }
            return presence(on: UInt32(bitPattern: info.st_rdev), eventAt: session.ts)
        }
    }

    /// One bounded native snapshot of this user's processes. Failure/truncation is unknown,
    /// never proof of exit. No process is spawned and no command-line arguments are read.
    static func codexSnapshot() -> CodexSnapshot {
        let takenAt = Date()
        let width = MemoryLayout<pid_t>.size
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard bytes > 0, bytes / Int32(width) < 16_384 else {
            return CodexSnapshot(takenAt: takenAt, owners: [], complete: false)
        }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / width + 64)
        let count = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, Int32(pids.count * width))
        guard count > 0, Int(count) < pids.count * width, Int(count) % width == 0 else {
            return CodexSnapshot(takenAt: takenAt, owners: [], complete: false)
        }
        var owners: [CodexOwner] = []
        var complete = true
        for pid in pids.prefix(Int(count) / width) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            errno = 0
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
                // A process that vanished during the scan cannot own a live terminal client.
                if errno != ESRCH { complete = false }
                continue
            }
            guard info.pbi_uid == getuid(), info.pbi_status != SZOMB else { continue }
            let name = withUnsafeBytes(of: info.pbi_name) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            let command = withUnsafeBytes(of: info.pbi_comm) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard (name.isEmpty ? command : name) == "codex" else { continue }
            let started = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
            guard started > 0 else { complete = false; continue }
            owners.append(CodexOwner(terminal: info.e_tdev, startedAt: started))
        }
        return CodexSnapshot(takenAt: takenAt, owners: owners, complete: complete)
    }

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
