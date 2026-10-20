import Foundation

/// A public announcement from whenreset.app, not proof of a reset for this account.
struct ResetAnnouncement: Equatable {
    let provider: String
    let id: String
    let at: Double

    init(provider: String, id: String, at: Double) {
        self.provider = provider
        self.id = id
        self.at = at
    }

    init?(provider: String, json: [String: Any]) {
        guard Provider.all.contains(where: { $0.id == provider }),
              json["type"] as? String == "reset",
              let kind = json["kind"] as? String, ["regular", "banked"].contains(kind),
              let id = json["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let timestamp = json["ts"] as? String,
              timestamp.range(of: #"^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$"#,
                              options: .regularExpression) != nil,
              ResetOddsFeed.date(String(timestamp.prefix(10))) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        if timestamp.contains(".") { formatter.formatOptions.insert(.withFractionalSeconds) }
        guard let date = formatter.date(from: timestamp), date.timeIntervalSince1970 > 0 else { return nil }
        self.init(provider: provider, id: id, at: date.timeIntervalSince1970)
    }
}

/// Pure state: the controller owns storage and presents only after persisting this snapshot.
struct ResetAnnouncementTracker {
    private struct Ledger {
        var ids: Set<String>
        var newest: Double
    }
    private var products: [String: Ledger] = [:]

    init(json: [String: Any]? = nil) {
        guard json?["version"] as? Int == 1,
              let records = json?["providers"] as? [String: Any] else { return }
        for provider in Provider.all {
            guard let record = records[provider.id] as? [String: Any],
                  let ids = record["ids"] as? [String],
                  ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  let newest = record["newest"] as? NSNumber,
                  CFGetTypeID(newest) != CFBooleanGetTypeID(),
                  newest.doubleValue.isFinite, newest.doubleValue >= 0 else { continue }
            products[provider.id] = Ledger(ids: Set(ids), newest: newest.doubleValue)
        }
    }

    var json: [String: Any] {
        ["version": 1, "providers": products.mapValues { ["ids": $0.ids.sorted(), "newest": $0.newest] }]
    }

    mutating func consume(_ odds: ResetOdds, now: Double) -> [ResetAnnouncement] {
        guard now.isFinite, now > 0 else { return [] }
        var result: [ResetAnnouncement] = []
        for provider in Provider.all {
            guard let events = odds.announcements[provider.id] else { continue }
            let previous = products[provider.id]
            let eligible = events.filter { $0.at <= now }
            // A future-only first answer is not a usable history baseline. Otherwise a later
            // historical answer would appear new against an invented zero watermark.
            if previous == nil, eligible.isEmpty, !events.isEmpty { continue }
            var record = previous ?? Ledger(ids: [], newest: 0)
            // A future event stays unseen until its time arrives. Compare with the previous
            // snapshot’s watermark so different IDs at the same timestamp remain distinct.
            for event in eligible.sorted(by: { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }) {
                if record.ids.insert(event.id).inserted, let previous, event.at >= previous.newest {
                    result.append(event)
                }
                record.newest = max(record.newest, event.at)
            }
            products[provider.id] = record
        }
        return result
    }
}
