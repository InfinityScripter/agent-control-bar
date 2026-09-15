import Darwin
import Foundation

// Installing the hooks, and saying so when it did not work.
//
// Every session row, the icon's state and the needs-you sound come out of files the hooks write,
// so hooks that never got installed make the whole app look like "nothing is running" — with no
// error anywhere. That is exactly how it failed on a real machine: Homebrew had upgraded llhttp out
// from under node 25, the node at /opt/homebrew/bin died in dyld before reading a line of
// install.js, the app ignored the exit status, and it meant to try again only on its next launch —
// while it went on running for seven hours. This file is the half of the fix the model checks can
// hold: a child process with a deadline, a node that is picked because it starts rather than
// because it exists, and a verdict worded for someone who has to act on it.

/// What the last look at the hooks found.
enum HookHealth: Equatable {
    /// No look has finished yet (the first runs at launch), or this copy does not manage hooks at
    /// all — a development build outside Applications keeps its hands off settings.json.
    case unchecked
    case ok
    /// The installer never ran, or ran and said it did not install them.
    case notInstalled(reason: String, hint: String?)
    /// They are written, but the node their commands call does not start, so every hook fails.
    case cannotRun(reason: String, hint: String?)

    /// The line a reader sees first, the cause under it, and what usually fixes it.
    var problem: (title: String, reason: String, hint: String?)? {
        switch self {
        case .unchecked, .ok:
            return nil
        case .notInstalled(let reason, let hint):
            return ("Session hooks aren't installed", reason, hint)
        case .cannotRun(let reason, let hint):
            return ("Session hooks can't run", reason, hint)
        }
    }
}

enum HookInstall {

    /// A child process that has finished, or that was given up on.
    struct Run: Equatable {
        enum End: Equatable {
            case exited(Int32)
            case signalled(Int32)
            case timedOut
            case notStarted(String)
        }
        let end: End
        /// Standard output and standard error together, in the order they were written.
        let output: String

        var succeeded: Bool { end == .exited(0) }
    }

    /// Runs a program to its end, or for `timeout` seconds, whichever comes first.
    ///
    /// The old spawn ignored how the child ended (`try? task.run()`, then nothing), which is the
    /// whole reason a node killed by dyld read as a finished install. It also had no deadline, and
    /// a check that never returns blocks every later one.
    ///
    /// Output goes to a temporary file rather than a pipe. A pipe is read until EOF, and EOF comes
    /// only once every process holding the write end has closed it: `zsh -ilc` whose .zshrc starts
    /// an agent in the background keeps the pipe open long after zsh itself has exited, and the
    /// read never returns. A file owes nothing to anyone else's lifetime, and cannot fill up and
    /// stall a chatty child either.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> Run {
        let fm = FileManager.default
        let log = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("control-bar-\(UUID().uuidString).log")
        guard fm.createFile(atPath: log, contents: nil, attributes: [.posixPermissions: 0o600]),
              let sink = FileHandle(forWritingAtPath: log)
        else { return Run(end: .notStarted("no temporary file to collect its output in"), output: "") }
        defer { try? fm.removeItem(atPath: log) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = sink
        task.standardError = sink
        let finished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in finished.signal() }
        do {
            try task.run()
        } catch {
            try? sink.close()
            return Run(end: .notStarted(error.localizedDescription), output: "")
        }
        try? sink.close()  // the child has its own descriptors; ours would only keep the file open

        let end: Run.End
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            // TERM first: a node that is merely slow gets to exit cleanly. A wedged one does not
            // get to hold the check forever. terminationReason is not read on this path — asking a
            // task that may still be running for it raises.
            task.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(task.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            end = .timedOut
        } else {
            end = task.terminationReason == .uncaughtSignal
                ? .signalled(task.terminationStatus) : .exited(task.terminationStatus)
        }
        return Run(end: end, output: String(decoding: fm.contents(atPath: log) ?? Data(), as: UTF8.self))
    }

    /// A candidate that is there but does not run, and what it said on the way down.
    struct Rejected: Equatable {
        let path: String
        let run: Run
    }

    /// The first candidate that actually starts, and every one before it that did not.
    ///
    /// "Executable" is not the question. The node that stopped the install on a real machine was
    /// an executable file, first on the list, and it died in dyld on a library Homebrew had already
    /// upgraded away — while a working node from nvm sat further down the same list, never tried.
    static func firstRunning(
        _ candidates: [String],
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:),
        probe: (String) -> Run = { HookInstall.run($0, ["-e", ""], timeout: 15) }
    ) -> (node: String?, rejected: [Rejected]) {
        var rejected: [Rejected] = []
        var tried = Set<String>()
        for path in candidates where isExecutable(path) {
            guard tried.insert(path).inserted else { continue }
            let result = probe(path)
            if result.succeeded { return (path, rejected) }
            rejected.append(Rejected(path: path, run: result))
        }
        return (nil, rejected)
    }

    /// The directories every hook command install.js writes puts in front of the session's PATH:
    /// `PATH="/opt/homebrew/bin:/usr/local/bin${PATH:+:$PATH}" node …`. Shared with the app's
    /// candidate list so the nodes the hooks will call are always the first ones probed.
    static let hookPathPrefix = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The node the hook commands will actually run — not necessarily the one that ran the
    /// installer. A node in either prefix directory wins over anything on the session's own PATH,
    /// broken or not, so a dead Homebrew node fails every hook while an installer run with a
    /// working nvm node reports success. nil when neither directory has one: then the session's
    /// PATH decides, and that cannot be seen from here.
    static func hookRuntime(
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> String? {
        hookPathPrefix.map { $0 + "/node" }.first(where: isExecutable)
    }

    /// One check, put into words: the nodes that did not start, how the installer ended — nil
    /// when no node started to run it with — and whether the node the hooks call is among the dead.
    static func health(rejected: [Rejected], installer: Run?, runtime: String?,
                       isHomebrew: (String) -> Bool = HookInstall.isHomebrew) -> HookHealth {
        guard let installer else {
            guard let first = rejected.first else {
                return .notInstalled(reason: "No node was found on this Mac, and the hooks are Node scripts.",
                                     hint: "Install Node.js (brew install node), then try again.")
            }
            let others = rejected.count > 1 ? " — and \(rejected.count - 1) more like it" : ""
            return .notInstalled(reason: "\(first.path) does not start: \(describe(first.run))\(others)",
                                 hint: repairHint(first.path, isHomebrew))
        }
        guard installer.succeeded else {
            return .notInstalled(reason: "install.js failed: \(describe(installer))", hint: nil)
        }
        if let runtime, let broken = rejected.first(where: { $0.path == runtime }) {
            return .cannotRun(reason: "They call \(runtime), and it does not start: \(describe(broken.run))",
                              hint: repairHint(runtime, isHomebrew))
        }
        return .ok
    }

    /// How a run ended, as the second half of a sentence about it.
    static func describe(_ run: Run) -> String {
        let said = summary(of: run.output)
        switch run.end {
        case .exited(let code):      return said ?? "exited with code \(code)"
        case .signalled(let signal): return said ?? "crashed (signal \(signal))"
        case .timedOut:              return "did not finish in time"
        case .notStarted(let why):   return why
        }
    }

    /// The one line of a child's output worth showing: dyld's reason, a JavaScript error, or else
    /// the first thing it said. nil when it said nothing.
    static func summary(of output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // "dyld[13151]: Library not loaded: /opt/homebrew/opt/llhttp/lib/libllhttp.9.3.dylib",
        // then "Referenced from" and "Reason: tried" lines. The pid is noise, and at the panel's
        // width so is the directory — the library's own name is what says which upgrade did it.
        if let dyld = lines.first(where: { $0.hasPrefix("dyld") }), let colon = dyld.firstIndex(of: ":") {
            var text = dyld[dyld.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let marker = "Library not loaded: "
            if text.hasPrefix(marker) {
                text = marker + (String(text.dropFirst(marker.count)) as NSString).lastPathComponent
            }
            return clipped(text)
        }
        // An uncaught exception prints the source line and a caret first; the reason is the line
        // that names the error.
        if let error = lines.first(where: {
            $0.range(of: #"^[A-Za-z]*Error\b"#, options: .regularExpression) != nil
        }) {
            return clipped(error)
        }
        return lines.first.map(clipped)
    }

    private static func clipped(_ text: String) -> String {
        text.count > 180 ? String(text.prefix(179)) + "…" : text
    }

    /// Homebrew's node is the one that breaks this way — a dependency upgraded without node being
    /// rebuilt against it — and the fix is always the same command. Told by where the link
    /// resolves, not by the directory: /usr/local/bin holds Homebrew's node on Intel and
    /// nodejs.org's installer puts its own there too.
    static func isHomebrew(_ path: String) -> Bool {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path.contains("/Cellar/")
    }

    private static func repairHint(_ path: String, _ isHomebrew: (String) -> Bool) -> String? {
        isHomebrew(path) ? "Usually fixed by: brew upgrade node" : nil
    }

    /// How long to wait before looking again after `failures` failed checks in a row. The first
    /// retry is quick because the one transient cause — settings.json rewritten while the installer
    /// held it — clears in seconds. A broken node stays broken until someone repairs it, and a look
    /// every five minutes notices the repair soon enough without spawning node all day.
    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        switch failures {
        case ..<2: return 30
        case 2:    return 120
        default:   return 300
        }
    }

    /// Whether opening the panel should look at the hooks again. With a problem on screen, almost
    /// always: the person opening it may have just run the fix. With none, only when the Sessions
    /// tab is empty — that is the moment someone wonders whether the hooks work — and not more
    /// than every two minutes, because a look runs node twice.
    static func checkDueOnOpen(problem: Bool, noSessions: Bool, sinceLastCheck age: Double) -> Bool {
        problem ? age >= 10 : (noSessions && age >= 120)
    }
}
