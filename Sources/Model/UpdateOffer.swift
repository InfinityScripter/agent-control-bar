/// What a copy that is behind the latest release can be offered right now.
///
/// One answer, because four places used to work it out separately and disagreed: the panel banner
/// kept quiet while Homebrew's cask lagged a release, yet the About page handed out the brew
/// command anyway (brew then said "already up to date"), the notification promised an update
/// the panel was not showing, and "What's new" offered to download a version already on disk.
enum UpdateOffer: Equatable {
    /// This copy is current, or no release has been seen yet.
    case none
    /// A newer copy already sits on disk under the running process; a restart finishes it.
    case restart(version: String)
    /// Homebrew owns the bundle and its cask has a newer version: the command will work.
    case brew(version: String)
    /// Homebrew owns the bundle and its cask has not caught up with the release yet. There is
    /// nothing to do but wait, so nothing is offered — only said, where someone comes looking.
    case brewPending(version: String)
    /// A newer release this app can fetch and install itself.
    case available(version: String)

    /// The order matters and is not arbitrary: a newer copy already on disk is checked before
    /// anything that fetches one, because there is nothing left to fetch — offering "Update to
    /// 0.5.1" next to a 0.5.1 bundle sends the user to download what they installed an hour ago.
    /// That holds for a Homebrew install too, where `brew upgrade` has just replaced the bundle.
    ///
    /// `onDisk` and `brewManaged` are read from the file system, so they are asked for only once
    /// a newer release is known: the About page puts this question on every tick while it is open.
    static func resolve(current: String, latest: String?, onDisk: @autoclosure () -> String?,
                        brewManaged: @autoclosure () -> Bool, caskVersion: String?) -> UpdateOffer {
        guard let latest, ReleaseVersion.isNewer(latest, than: current) else { return .none }
        if let onDisk = onDisk(), ReleaseVersion.isNewer(onDisk, than: current) {
            return .restart(version: onDisk)
        }
        guard brewManaged() else { return .available(version: latest) }
        // The cask lags a GitHub release by up to about a day (autobump): until it catches up,
        // the command would report "already up to date".
        guard let caskVersion, ReleaseVersion.isNewer(caskVersion, than: current) else {
            return .brewPending(version: latest)
        }
        return .brew(version: caskVersion)
    }

    /// The version an "X is available" notification may name: only an update the panel is
    /// showing a way to get, since the notification sends the reader there.
    var announcedVersion: String? {
        switch self {
        case .available(let version), .brew(let version): return version
        case .none, .restart, .brewPending: return nil
        }
    }
}
