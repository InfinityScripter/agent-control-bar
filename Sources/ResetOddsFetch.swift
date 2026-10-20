import Cocoa

extension StatusController {
    /// The last good answer is kept as its raw bytes so the panel has figures the moment the app
    /// starts, before any request — and so the CONTROL_BAR_DUMP_MENU dump, which quits after 1.5 s,
    /// can print them at all.
    func loadResetOddsCache() {
        guard resetOddsOn else { return }
        let d = UserDefaults.standard
        resetOdds = d.data(forKey: "resetOddsCache").flatMap { ResetOdds(data: $0) }
        resetOddsFetchedAt = resetOdds == nil ? 0 : d.double(forKey: "resetOddsFetchedAt")
        let ledger = d.dictionary(forKey: "resetAnnouncementLedger")
        resetAnnouncementTracker = ResetAnnouncementTracker(json: ledger)
        if ledger == nil, let resetOdds {
            // Upgrade an existing raw cache silently; historical events are not new announcements.
            _ = resetAnnouncementTracker.consume(resetOdds, now: Date().timeIntervalSince1970)
            d.set(resetAnnouncementTracker.json, forKey: "resetAnnouncementLedger")
        }
    }

    /// `force` is the switch being turned on: someone who just asked for the odds should not
    /// wait out a throttle that counted an attempt made before they switched it off.
    func fetchResetOddsIfDue(force: Bool = false) {
        guard resetOddsOn, !resetOddsRunning, let url = URL(string: ResetOddsFeed.endpoint) else { return }
        let d = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        guard force || ResetOddsFeed.due(now: now, lastAttempt: d.double(forKey: "lastResetOddsAttempt")) else { return }
        // Stamped before the request, like the update check: a site that is down must cost one
        // request per interval, not one per panel open.
        d.set(now, forKey: "lastResetOddsAttempt")
        resetOddsRunning = true
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // The site sits behind Cloudflare, which answers 403 to the default URLSession and
        // scripting user agents.
        req.setValue("AgentControlBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        // Ephemeral and redirect-free for the reason the ping is: no cookie the site sets can
        // follow the next request, and the request goes to the host PRIVACY.md names or nowhere.
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect.shared, delegateQueue: nil)
        session.dataTask(with: req) { [weak self] data, response, error in
            session.finishTasksAndInvalidate()
            let status = (response as? HTTPURLResponse)?.statusCode
            let odds = status == 200 ? data.flatMap { ResetOdds(data: $0) } : nil
            DispatchQueue.main.async {
                self?.resetOddsFinished(odds: odds, data: data, status: status, error: error)
            }
        }.resume()
    }

    private func resetOddsFinished(odds: ResetOdds?, data: Data?, status: Int?, error: Error?) {
        resetOddsRunning = false
        // Switched off while the request was out: the answer is dropped, not cached behind the
        // switch's back.
        guard resetOddsOn else { return }
        if error == nil, let odds, let data {
            let now = Date().timeIntervalSince1970
            resetOdds = odds
            resetOddsFetchedAt = now
            resetOddsProblem = nil
            let announcements = resetAnnouncementTracker.consume(odds, now: now)
            // Store identities before presenting, so the next launch cannot repeat this batch.
            UserDefaults.standard.set(resetAnnouncementTracker.json, forKey: "resetAnnouncementLedger")
            UserDefaults.standard.set(data, forKey: "resetOddsCache")
            UserDefaults.standard.set(now, forKey: "resetOddsFetchedAt")
            resetCelebration.show(providers: announcements.map(\.provider), anchor: statusItem.button)
        } else {
            // The previous figures stay: an old estimate, labelled as old, is still the estimate.
            resetOddsProblem = ResetOddsFeed.problem(status: status, error: error)
        }
        refreshCounts()
    }

    /// Off forgets everything, cache included, so "off" means the app holds nothing from the site
    /// and sends it nothing.
    func applyResetOdds(_ on: Bool) {
        resetOddsOn = on
        let d = UserDefaults.standard
        d.set(on, forKey: "resetOdds")
        if on {
            fetchResetOddsIfDue(force: true)
        } else {
            for key in ["resetOddsCache", "resetOddsFetchedAt", "lastResetOddsAttempt", "resetAnnouncementLedger"] { d.removeObject(forKey: key) }
            resetAnnouncementTracker = ResetAnnouncementTracker()
            resetCelebration.close()
            resetOdds = nil
            resetOddsFetchedAt = 0
            resetOddsProblem = nil
        }
        refreshCounts()
    }

    func openResetOddsSite() {
        if let url = URL(string: ResetOddsFeed.site) { NSWorkspace.shared.open(url) }
    }
}
