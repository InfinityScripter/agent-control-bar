import Foundation

/// One product's line in whenreset.app's answer: the odds of an early limit reset and how many
/// resets the site has counted. Every field is optional on purpose — a field the site left out or
/// sent in another shape is unknown, and the panel says "—" for it rather than a 0 that would read
/// as "no chance".
struct ResetOddsProduct: Equatable {
    /// The key in `products`, which is also the app's Provider.id for the two it knows.
    let id: String
    let name: String
    let p24: Int?
    let p48: Int?
    let p7d: Int?
    let total: Int?
    let last30d: Int?
    /// "YYYY-MM-DD", UTC, as the site writes it.
    let lastRegular: String?
    /// The last reset the vendor handed out as a bankable credit, which users redeem themselves;
    /// it is not a reset of everybody's limits, so it is kept apart from `lastRegular`.
    let lastBanked: String?
}

extension ResetOddsProduct {
    init(id: String, json o: [String: Any]) {
        let stats = (o["stats"] as? [String: Any]) ?? [:]
        let result = ((o["odds"] as? [String: Any])?["result"] as? [String: Any]) ?? [:]
        self.init(id: id,
                  name: (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                  p24: ResetOddsFeed.percent(result["1"]),
                  p48: ResetOddsFeed.percent(result["2"]),
                  p7d: ResetOddsFeed.percent(result["7"]),
                  total: ResetOddsFeed.count(stats["total"]),
                  last30d: ResetOddsFeed.count(stats["last30d"]),
                  lastRegular: ResetOddsFeed.date(stats["last_regular_date"]) ?? ResetOddsFeed.date(stats["last_date"]),
                  lastBanked: ResetOddsFeed.date(stats["last_banked_date"]))
    }
}

/// The whole of /api/v1/resets.json that the panel uses. The site documents the format as
/// "fields are only ever added", which is why the raw bytes are what gets cached: an older cache
/// is read by newer code through this same parser.
struct ResetOdds: Equatable {
    let products: [ResetOddsProduct]

    init?(json: [String: Any]) {
        guard let all = json["products"] as? [String: Any] else { return nil }
        let parsed = all.compactMap { id, value -> ResetOddsProduct? in
            (value as? [String: Any]).map { ResetOddsProduct(id: id, json: $0) }
        }
        guard !parsed.isEmpty else { return nil }
        // The panel lists providers in the order the limits strip does; a product the site adds
        // later goes after them in a stable order rather than in dictionary order, which changes
        // between launches.
        let known = Provider.all.map(\.id)
        products = parsed.sorted { a, b in
            let ra = known.firstIndex(of: a.id) ?? known.count
            let rb = known.firstIndex(of: b.id) ?? known.count
            return ra != rb ? ra < rb : a.id < b.id
        }
    }

    init?(data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        self.init(json: json)
    }

    func product(_ id: String) -> ResetOddsProduct? { products.first { $0.id == id } }
}

enum ResetOddsFeed {
    static let endpoint = "https://whenreset.app/api/v1/resets.json"
    static let site = "https://whenreset.app/"
    /// The site only changes when a vendor announces a reset and caches its answer for five
    /// minutes, so asking more often than this would only spend someone else's bandwidth.
    static let interval: Double = 900
    static let staleAfter: Double = 21600

    /// Counted from the last attempt, not the last success, so a site that is down costs one
    /// request per interval instead of one per timer tick and panel open.
    static func due(now: Double, lastAttempt: Double) -> Bool {
        lastAttempt <= 0 || lastAttempt > now || now - lastAttempt >= interval
    }

    /// A share 0…1 as whole percent. Anything that cannot be a probability is nil rather than
    /// clamped: 1e30 clamped would draw a confident 100%, which is worse than a dash. The small
    /// allowance over 1 is for a share the site rounded up.
    static func percent(_ value: Any?) -> Int? {
        guard let v = number(value), v >= 0, v <= 1.005 else { return nil }
        return min(100, (v * 100).rounded().clampedInt)
    }

    /// Whole days from a "YYYY-MM-DD" UTC date to `now`. A date ahead of this Mac's clock is
    /// today: the site's clock and this one can disagree by hours around midnight.
    static func daysSince(_ date: String?, now: Double) -> Int? {
        guard let day = day(date) else { return nil }
        return max(0, ((now - day.timeIntervalSince1970) / 86400).rounded(.down).clampedInt)
    }

    /// "Sep 22" for "2026-09-22". In English and UTC whatever this Mac is set to: the panel is in
    /// English, and the site's dates are UTC days.
    static func monthDay(_ date: String?) -> String? {
        guard let day = day(date) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM d"
        return f.string(from: day)
    }

    static func problem(status: Int?, error: Error?) -> String {
        if error != nil { return "whenreset.app didn't answer" }
        switch status {
        case nil: return "whenreset.app didn't answer"
        case 200: return "whenreset.app sent an answer this app can't read"
        case 403: return "whenreset.app refused the request (403)"
        case let code?: return "whenreset.app answered \(code)"
        }
    }

    /// A count of resets. Over a million is not a count of vendor announcements, so it is
    /// unknown rather than clamped into a believable-looking figure.
    static func count(_ value: Any?) -> Int? {
        guard let v = number(value), v >= 0, v <= 1_000_000 else { return nil }
        return v.rounded().clampedInt
    }

    static func date(_ value: Any?) -> String? {
        guard let s = value as? String, day(s) != nil else { return nil }
        return s
    }

    /// JSONSerialization hands `true` over as an NSNumber 1, which would read as a 100% chance.
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let v = n.doubleValue
        return v.isFinite ? v : nil
    }

    private static func day(_ date: String?) -> Date? {
        guard let date else { return nil }
        let parts = date.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        guard let day = calendar.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        // Calendar rolls 31 February over into March instead of refusing it.
        let back = calendar.dateComponents([.year, .month, .day], from: day)
        return back.year == y && back.month == m && back.day == d ? day : nil
    }
}
