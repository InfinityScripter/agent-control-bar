import Cocoa

// The Usage window's picture from the live state. The parts are plain values and the builder is
// pure (UsageInputs and UsageSnapshot(_:) in Model/UsageWindowModel.swift), because two callers
// need the same picture from different places: the controller here, and the render mode from a
// directory of fixture files with no controller, no status item and no backend at all.

extension StatusController {
    /// The providers the Usage window shows: the panel's own answer, so the agents setting and a
    /// hidden model service mean the same in both.
    var usageProviders: [String] {
        Provider.all.map(\.id).filter {
            agentDisplay.inPanel($0) && !hiddenModelServices.contains(.native(for: $0))
        }
    }

    /// The window's picture from the live state. The limits are the very values the panel draws
    /// (`limits`, `codexWindows`), which is what keeps the two from disagreeing about a figure.
    func usageSnapshot() -> UsageSnapshot {
        var inputs = UsageInputs(now: usage.now, providers: usageProviders)
        inputs.limits = [
            Provider.claude.id: UsageLimitsInput(set: limits?.set, status: limitsStatus, enabled: oauthLimits),
            Provider.codex.id: UsageLimitsInput(set: codexWindows, status: codexLimitsStatus, enabled: codexLimits),
        ]
        inputs.files = usage.files
        inputs.usageRunning = usage.scanRunning
        inputs.usageFailed = usage.scanFailed
        inputs.limitsRefreshing = usageLimitsRefreshing
        inputs.resetBusy = usage.resetBusy
        inputs.resetUnanswered = usage.resetUnanswered
        inputs.resetNewsSince = usage.openedAt
        inputs.resetDismissed = usage.resetDismissed
        inputs.hour12 = UsageFormat.uses12HourClock(.current)
        return UsageSnapshot(inputs)
    }
}
