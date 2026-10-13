import Foundation

/// How the last Claude limits poll ended, as scripts/mcpbar.py wrote it to limits-status.json.
/// Written on every poll, including the ones that leave limits.json alone — so the figures on
/// screen can be old while this says why they stopped moving.
struct LimitsStatus: Equatable {
    /// ok | no-login | failed | empty — the script's word, kept as a string like every status
    /// that crosses the JSON border.
    let state: String
    /// When the poll ran, epoch seconds.
    let ts: Double
    /// The short reason: "no token", the exception class name, "no windows"; "" for ok.
    let detail: String

    init?(json: [String: Any]) {
        guard let state = json["state"] as? String else { return nil }
        self.state = state
        self.ts = (json["ts"] as? NSNumber)?.doubleValue ?? 0
        self.detail = json["detail"] as? String ?? ""
    }
}

/// The block the panel draws over the limits strip when the poll brought no figures.
struct LimitsNotice: Equatable {
    let title: String
    let hint: String
    /// Only a signed-out Claude Code can be fixed from the panel; a network failure cannot.
    let offerSignIn: Bool
}

extension LimitsStatus {
    /// nil when there is nothing to explain: the poll succeeded, the API poll is switched off (the
    /// file may still say no-login from before the switch), or the backend is too old to write the
    /// file at all. `figuresTs` is the stamp of limits.json, nil when there are no figures — the
    /// hint never invents an age.
    ///
    /// Also nil when the figures are newer than the poll: limits.json has a second writer, the
    /// statusLine capture, and while it keeps the figures moving a block saying they stopped
    /// would sit over live numbers.
    static func notice(_ status: LimitsStatus?, oauthLimits: Bool, figuresTs: Double?, now: Double) -> LimitsNotice? {
        guard let status = explainable(status, oauthLimits: oauthLimits, figuresTs: figuresTs) else { return nil }
        let figuresAge = figuresTs.map { LimitsNote.age(of: $0, now: now) }
        if status.state == "no-login" {
            let hint = figuresAge.map { "Limits stopped updating \($0). Sign in to resume." }
                ?? "Sign in to see limits."
            return LimitsNotice(title: "Claude Code is not signed in", hint: hint, offerSignIn: true)
        }
        let title = status.state == "empty"
            ? "The usage endpoint returned no limit windows"
            : "Limits poll failed" + (status.detail.isEmpty ? "" : ": " + status.detail)
        let hint = (figuresAge.map { "Showing figures from \($0)." } ?? "No figures yet.")
            + " The next poll is a few minutes away."
        return LimitsNotice(title: title, hint: hint, offerSignIn: false)
    }

    /// Whether the one signed-out banner is due for this status. Only a poll made since launch
    /// counts: the first tick reads the file the previous run left behind, before this launch's
    /// own poll has answered, and a banner off that file announces a sign-out that may be over.
    /// Gated like the block, so the banner never says what the panel does not show.
    static func signedOutBannerDue(_ status: LimitsStatus?, oauthLimits: Bool, figuresTs: Double?,
                                   launchedAt: Double) -> Bool {
        guard let status = explainable(status, oauthLimits: oauthLimits, figuresTs: figuresTs),
              status.state == "no-login" else { return false }
        // The script stamps whole seconds, so a poll answered within the launch second carries a
        // stamp just below launchedAt and must still count as this launch's.
        return status.ts >= launchedAt.rounded(.down)
    }

    private static func explainable(_ status: LimitsStatus?, oauthLimits: Bool, figuresTs: Double?) -> LimitsStatus? {
        guard oauthLimits, let status, status.state != "ok" else { return nil }
        if let figuresTs, figuresTs > status.ts { return nil }
        return status
    }

    /// What the strip says when it has no figures to draw. The old two lines stay for every case
    /// but one: a poll that found no login names the cause instead of asking.
    static func emptyStripText(_ status: LimitsStatus?, oauthLimits: Bool) -> String {
        guard oauthLimits else { return "Limits are switched off in Settings" }
        if status?.state == "no-login" { return "Claude Code is not signed in — sign in to see limits" }
        return "No data yet — is Claude Code signed in?"
    }

    /// The line under the Settings switch: the outcome of the last poll and, when it brought
    /// nothing, how old the figures on screen are. "" without a status file.
    static func pollLine(_ status: LimitsStatus?, polledAge: String, figuresAge: String?) -> String {
        guard let status else { return "" }
        switch status.state {
        case "ok": return "Last poll: ok · " + polledAge
        case "no-login": return "Last poll: not signed in" + figuresSuffix(figuresAge)
        case "empty": return "Last poll: no limit windows" + figuresSuffix(figuresAge)
        case "failed":
            let reason = status.detail.isEmpty ? "failed" : "failed (\(status.detail))"
            return "Last poll: " + reason + figuresSuffix(figuresAge)
        default: return "Last poll: " + status.state + figuresSuffix(figuresAge)
        }
    }

    private static func figuresSuffix(_ figuresAge: String?) -> String {
        figuresAge.map { " · figures from \($0)" } ?? ""
    }
}
