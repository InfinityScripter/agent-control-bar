import Foundation

/// The branch a session row shows, read straight out of `.git/HEAD` — no `git` spawn, because
/// HEAD is a tiny text file and this runs for every session on every reload.
///
/// Lifted out of StatusController so the model check can walk real directories through it: a
/// worktree, a submodule's relative `gitdir:`, a detached HEAD and a directory that only later
/// became a repository are all cases a session's cwd really is, and none of them could be
/// exercised while the logic lived in the app.
final class GitBranches {
    /// cwd -> resolved HEAD path; "" means confirmed non-git. Resolution walks directories toward
    /// /, so it is cached per cwd and dropped by `branch(_:)` if the HEAD read later fails.
    private(set) var headCache: [String: String] = [:]

    /// Resolve `cwd`'s HEAD path by walking toward /. A worktree or submodule has `.git` as a FILE
    /// containing "gitdir: <path>".
    func headPath(_ cwd: String) -> String? {
        if let hit = headCache[cwd] { return hit.isEmpty ? nil : hit }
        let fm = FileManager.default
        var dir = cwd, isDir: ObjCBool = false
        for _ in 0..<40 {
            let g = (dir as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: g, isDirectory: &isDir) {
                var head: String? = nil
                if isDir.boolValue {
                    head = (g as NSString).appendingPathComponent("HEAD")
                } else if let d = fm.contents(atPath: g), d.count <= 4096,
                          let s = String(data: d, encoding: .utf8),
                          let line = s.split(separator: "\n").first, line.hasPrefix("gitdir: ") {
                    var gd = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                    if !gd.hasPrefix("/") { gd = ((dir as NSString).appendingPathComponent(gd) as NSString).standardizingPath }
                    head = (gd as NSString).appendingPathComponent("HEAD")
                }
                headCache[cwd] = head ?? ""
                return head
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        headCache[cwd] = ""
        return nil
    }

    /// The branch name for `cwd`, a short SHA when detached, "" for non-git dirs and anything
    /// unrecognized.
    func branch(_ cwd: String) -> String {
        guard !cwd.isEmpty, let headPath = headPath(cwd) else { return "" }
        guard let d = FileManager.default.contents(atPath: headPath), d.count <= 1024,
              let s = String(data: d, encoding: .utf8) else {
            headCache[cwd] = nil   // stale resolution (repo moved/deleted) — retry next time
            return ""
        }
        return Self.branch(fromHead: s)
    }

    /// A hook event means activity in that cwd, which may have JUST become a repo (git init or a
    /// first branch mid-session) — a cached "" (non-git) would otherwise stick until app restart.
    func fresh(_ cwd: String) -> String {
        if headCache[cwd] == "" { headCache[cwd] = nil }
        return branch(cwd)
    }

    /// Keyed by cwd, so the cache would outlive the sessions that filled it: an entry per
    /// directory ever seen, for the app's lifetime. Kept only for directories still in use.
    func keep(only cwds: Set<String>) {
        headCache = headCache.filter { cwds.contains($0.key) }
    }

    /// HEAD is "ref: refs/heads/<branch>" on a branch, a bare commit hash when detached.
    static func branch(fromHead text: String) -> String {
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst(16)) }
        if head.hasPrefix("ref: ") { return ((head as NSString).lastPathComponent) }
        if (40...64).contains(head.count), head.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
            return String(head.prefix(7))   // detached HEAD -> short SHA
        }
        return ""
    }
}
