import Foundation

// The model behind the Usage window's Cost and Tokens tabs.
//
// `mcpbar.py usage` scans the transcripts, prices them and writes usage/summary.json; everything
// here only reads that file and usage/status.json and turns them into the figures the two tabs
// draw. Cost is never recomputed on this side: prices, aliases and custom rates were applied by
// the writer, and a second copy of that arithmetic would be a second answer.
//
// The reduction, the formatters and the chart maths follow T3 Code's Usage page (MIT, commit
// 803f21f: packages/shared/src/usageMerge.ts, usageFormat.ts, and apps/web's usageBreakdown.ts and
// UsageProviderChart.tsx), cut down to one machine and two providers. Where a rule looks
// arbitrary — "1.20M" but "1M", sessions that are not summed from buckets — it is T3's rule, kept
// so the window reads the same as the page it copies.

// MARK: - Reading the files

/// Readers for values another process wrote. Every one of them answers a wrong type with a
/// default instead of failing the whole file: a summary with one bad bucket should lose that
/// bucket's figure, not the window.
private enum UsageField {
    /// 2^53, the largest whole number a JSON double still carries exactly. A count above it is not
    /// a count any writer of ours produced.
    static let largestCount = 9_007_199_254_740_992.0

    /// A finite number, or nil. NSNumber also bridges `true`, which would read as one dollar or
    /// one record, so booleans are turned away by type.
    static func number(_ value: Any?) -> Double? {
        guard let boxed = value as? NSNumber, CFGetTypeID(boxed) != CFBooleanGetTypeID() else { return nil }
        let double = boxed.doubleValue
        return double.isFinite ? double : nil
    }

    /// Tokens, records, sessions, files: whole and never negative.
    ///
    /// Kept as Double on purpose. These figures are only ever added up and printed, and adding
    /// two Ints read from a damaged file traps on overflow exactly like `Int(someDouble)` does.
    /// Doubles cannot trap, and below 2^53 they are exact.
    static func count(_ value: Any?) -> Double {
        guard let number = number(value), number >= 1, number <= largestCount else { return 0 }
        return number.rounded(.down)
    }

    static func cost(_ value: Any?) -> Double { number(value) ?? 0 }

    static func text(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Instants as the summary spells them: JavaScript's `toISOString()`, "2026-11-18T12:37:00.000Z".
private enum UsageInstant {
    private static let writer: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func seconds(_ text: String) -> Double? { Transcript.unixTime(text) }

    static func string(_ seconds: Double) -> String {
        writer.string(from: Date(timeIntervalSince1970: seconds))
    }

    /// The one spelling of an instant. A chart point finds its bucket by comparing hour starts as
    /// text, so "…:00Z" and "…:00.000Z" must not be two different hours. Text that is not an
    /// instant is kept as it came: it still groups its own buckets into one row.
    static func canonical(_ text: String) -> String { seconds(text).map(string) ?? text }
}

/// Calendar days as the summary spells them: "2026-11-19".
private enum UsageDays {
    static let utc: Calendar = calendar(.gmt)

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// The three numbers of a "YYYY-MM-DD", checked for shape only.
    static func parts(_ day: String) -> (year: Int, month: Int, day: Int)? {
        let fields = day.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
              fields.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2])
        else { return nil }
        return (year, month, day)
    }

    /// Midnight UTC of the day, or nil when there is no such day.
    static func date(_ day: String) -> Date? {
        guard let parts = parts(day),
              let date = utc.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))
        else { return nil }
        // Calendar rolls 30 February over into March instead of refusing it.
        return string(date, in: utc) == day ? date : nil
    }

    static func string(_ date: Date, in calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// The five token kinds of a bucket. Reasoning tokens are already inside output, which is why
/// `total` does not add them a second time.
struct UsageTokenTotals: Equatable {
    var uncachedInputTokens = 0.0
    var cachedInputTokens = 0.0
    var cacheCreationTokens = 0.0
    var outputTokens = 0.0
    var reasoningTokens = 0.0

    /// "Processed tokens" everywhere on the page.
    var total: Double { uncachedInputTokens + cachedInputTokens + cacheCreationTokens + outputTokens }

    mutating func add(_ other: UsageTokenTotals) {
        uncachedInputTokens += other.uncachedInputTokens
        cachedInputTokens += other.cachedInputTokens
        cacheCreationTokens += other.cacheCreationTokens
        outputTokens += other.outputTokens
        reasoningTokens += other.reasoningTokens
    }
}

extension UsageTokenTotals {
    init(json: Any?) {
        let o = json as? [String: Any] ?? [:]
        self.init(uncachedInputTokens: UsageField.count(o["uncachedInputTokens"]),
                  cachedInputTokens: UsageField.count(o["cachedInputTokens"]),
                  cacheCreationTokens: UsageField.count(o["cacheCreationTokens"]),
                  outputTokens: UsageField.count(o["outputTokens"]),
                  reasoningTokens: UsageField.count(o["reasoningTokens"]))
    }
}

/// Cost by what was billed. `unsplit` exists only on totals: it is the cost that came without a
/// split (a provider-reported price for a model with no known rates), found by subtraction.
struct UsageCategoryCost: Equatable {
    var input = 0.0
    var cacheRead = 0.0
    var cacheWrite = 0.0
    var output = 0.0
    var unsplit = 0.0
}

/// One cell of the summary: a day (or a rolling hour), a provider and a model.
struct UsageBucket: Equatable {
    let day: String
    /// Present in the Past 24h period only, and then an instant aligned to the minute the scan
    /// ran at, not to the wall clock: "the hour" is 12:37 to 13:37.
    let hourStart: String?
    let provider: String
    let model: String
    let totals: UsageTokenTotals
    let costUsd: Double
    let cacheSavingsUsd: Double
    /// Nil when the writer could not split this bucket's cost, which is different from a split
    /// of zeros: it is what makes the cost "unsplit" in the totals.
    let categoryCost: UsageCategoryCost?
    let fastCostUsd: Double
    let ultrafastCostUsd: Double
    let speedPremiumUsd: Double
    /// providerReported | modelPriced | unpriced
    let costSource: String
    let records: Double
    let unpricedRecords: Double
    /// Nil when the writer left it out; the totals then estimate it from the record share.
    let unpricedTokens: Double?

    /// Nil for a bucket that cannot be placed: no readable day, a provider this app does not
    /// draw, or no model name. Its numbers, on the other hand, only ever degrade to zero. The
    /// per-bucket `sessions` count is not read at all: one session spans days and models, so
    /// those counts cannot be added up, and the per-source count is used instead.
    init?(json: Any?) {
        guard let o = json as? [String: Any] else { return nil }
        let day = UsageField.text(o["day"])
        let provider = UsageField.text(o["provider"])
        let model = UsageField.text(o["model"])
        guard UsageDays.parts(day) != nil, UsageTotals.providerOrder.contains(provider), !model.isEmpty
        else { return nil }
        self.day = day
        self.provider = provider
        self.model = model
        let hour = UsageField.text(o["hourStart"])
        hourStart = hour.isEmpty ? nil : UsageInstant.canonical(hour)
        totals = UsageTokenTotals(json: o["totals"])
        costUsd = UsageField.cost(o["costUsd"])
        cacheSavingsUsd = UsageField.cost(o["cacheSavingsUsd"])
        categoryCost = (o["categoryCostUsd"] as? [String: Any]).map { split in
            UsageCategoryCost(input: UsageField.cost(split["input"]), cacheRead: UsageField.cost(split["cacheRead"]),
                              cacheWrite: UsageField.cost(split["cacheWrite"]), output: UsageField.cost(split["output"]))
        }
        fastCostUsd = UsageField.cost(o["fastCostUsd"])
        ultrafastCostUsd = UsageField.cost(o["ultrafastCostUsd"])
        speedPremiumUsd = UsageField.cost(o["speedPremiumUsd"])
        costSource = UsageField.text(o["costSource"])
        records = UsageField.count(o["records"])
        unpricedRecords = UsageField.count(o["unpricedRecords"])
        unpricedTokens = UsageField.number(o["unpricedTokens"]).map { _ in UsageField.count(o["unpricedTokens"]) }
    }
}

/// What the scan of one provider's history came to, for one period.
struct UsageSource: Equatable {
    let provider: String
    /// ok | missing | partial | failed
    let status: String
    let scannedFiles: Double
    let skippedFiles: Double
    let malformedRecords: Double
    /// Sessions seen in the period. This, not the buckets, is what the page totals.
    let distinctSessions: Double
    /// A fixed category word (zstd_unavailable, read_failed, no_history) or nil. Never shown as
    /// it is: `UsageCopy.sourceWarning` owns the sentences.
    let message: String?

    init?(json: Any?) {
        guard let o = json as? [String: Any] else { return nil }
        let provider = UsageField.text(o["provider"])
        guard UsageTotals.providerOrder.contains(provider) else { return nil }
        self.provider = provider
        status = UsageField.text(o["status"])
        scannedFiles = UsageField.count(o["scannedFiles"])
        skippedFiles = UsageField.count(o["skippedFiles"])
        malformedRecords = UsageField.count(o["malformedRecords"])
        distinctSessions = UsageField.count(o["distinctSessions"])
        let message = UsageField.text(o["message"])
        self.message = message.isEmpty ? nil : message
    }
}

/// One of the four windows the summary carries: Past 24h by rolling hour, 7, 30 and 90 days by day.
struct UsagePeriod {
    /// hour | day
    let resolution: String
    let sinceDay: String
    let untilDay: String
    /// Exact bounds, hourly period only.
    let sinceTime: String?
    let untilTime: String?
    let buckets: [UsageBucket]
    let sources: [UsageSource]

    static let empty = UsagePeriod(json: nil)

    init(json: Any?) {
        let o = json as? [String: Any] ?? [:]
        resolution = UsageField.text(o["resolution"]) == "hour" ? "hour" : "day"
        sinceDay = UsageField.text(o["sinceDay"])
        untilDay = UsageField.text(o["untilDay"])
        let since = UsageField.text(o["sinceTime"])
        let until = UsageField.text(o["untilTime"])
        sinceTime = since.isEmpty ? nil : UsageInstant.canonical(since)
        untilTime = until.isEmpty ? nil : UsageInstant.canonical(until)
        buckets = (o["buckets"] as? [Any] ?? []).compactMap { UsageBucket(json: $0) }
        sources = (o["sources"] as? [Any] ?? []).compactMap { UsageSource(json: $0) }
    }

    var isHourly: Bool { resolution == "hour" }

    /// Every column of the chart, oldest first: each day of the window, or the 24 rolling hours.
    /// The chart is zero-filled from this list; the tables list only what has data.
    var periodKeys: [String] {
        isHourly
            ? UsageFormat.enumerateHourStarts(since: sinceTime ?? "", until: untilTime ?? "")
            : UsageFormat.enumerateDays(since: sinceDay, until: untilDay)
    }

    /// The paragraphs above the overview: what could not be read, said once each.
    ///
    /// A source speaks up when its read was partial or failed, or when it is missing but still has
    /// skipped records on file. A healthy source says nothing, and neither does a provider that
    /// simply has no history on this Mac.
    func warnings(provider only: String? = nil) -> [String] {
        var sentences: [String] = []
        var skipped: [String: Double] = [:]
        for source in sources where only == nil || source.provider == only {
            let speaks = source.status == "partial" || source.status == "failed"
                || (source.status == "missing" && source.malformedRecords > 0)
            guard speaks else { continue }
            skipped[source.provider] = max(skipped[source.provider] ?? 0, source.malformedRecords)
            if let sentence = UsageCopy.sourceWarning(source), !sentences.contains(sentence) {
                sentences.append(sentence)
            }
        }
        let records = skipped.values.reduce(0, +)
        if records > 0 { sentences.append(UsageCopy.malformed(records)) }
        return sentences
    }
}

/// Where the prices came from. Read for completeness of the file; the page itself only shows the
/// consequence, which is records marked unpriced.
struct UsageSummaryPricing: Equatable {
    /// fresh | cached | unavailable
    let status: String
    let source: String
    let fetchedAt: Double?
    let knownModels: Int

    init(json: Any?) {
        let o = json as? [String: Any] ?? [:]
        let status = UsageField.text(o["status"])
        self.status = status.isEmpty ? "unavailable" : status
        source = UsageField.text(o["source"])
        fetchedAt = UsageField.number(o["fetchedAt"])
        knownModels = UsageField.count(o["knownModels"]).clampedInt
    }
}

/// usage/summary.json.
struct UsageSummary {
    /// The period keys of the file, which are also the choices of the period control.
    static let periodDays = [1, 7, 30, 90]

    let version: Int
    let readAt: Double
    /// The IANA zone the writer bucketed days in. Labels must use it rather than this process's
    /// zone, or a bucket filed under "today" could be labelled yesterday.
    let timeZone: String
    let scanDurationMs: Int
    let pricing: UsageSummaryPricing
    private let periods: [Int: UsagePeriod]

    init(json root: [String: Any]) {
        version = UsageField.count(root["version"]).clampedInt
        readAt = UsageField.count(root["readAt"])
        let zone = UsageField.text(root["timeZone"])
        timeZone = TimeZone(identifier: zone) == nil ? "UTC" : zone
        scanDurationMs = UsageField.count(root["scanDurationMs"]).clampedInt
        pricing = UsageSummaryPricing(json: root["pricing"])
        let written = root["periods"] as? [String: Any] ?? [:]
        var periods: [Int: UsagePeriod] = [:]
        for days in UsageSummary.periodDays {
            if let period = written[String(days)] { periods[days] = UsagePeriod(json: period) }
        }
        self.periods = periods
    }

    var zone: TimeZone { TimeZone(identifier: timeZone) ?? .gmt }

    /// A period the file does not carry is an empty one, so the page draws its empty state
    /// instead of holding on to another period's figures.
    func period(_ days: Int) -> UsagePeriod { periods[days] ?? .empty }
}

/// usage/status.json: what the scan is doing, written by the scan itself.
///
/// Whether a scan is running is NOT read from here — the app knows that from the command it
/// spawned, and a file left at "scanning" by a killed process would otherwise spin forever. The
/// file adds what the app cannot know: how far along the scan is, and that the last one failed.
struct UsageScanStatus: Equatable {
    let ts: Double
    /// scanning | ok | failed, or empty when there is no file yet
    let state: String
    /// A fixed category word, or empty.
    let detail: String
    /// Progress in files.
    let done: Int
    let total: Int

    init(json root: [String: Any]) {
        ts = UsageField.count(root["ts"])
        state = UsageField.text(root["state"])
        detail = UsageField.text(root["detail"])
        done = UsageField.count(root["done"]).clampedInt
        total = UsageField.count(root["total"]).clampedInt
    }

    /// The line beside the refresh button while the command runs. T3's two phase words: a first
    /// scan with nothing on screen is "Scanning…", a rescan over figures is "Refreshing…". The
    /// file counts are added only while the file itself says a scan is under way — until the new
    /// run has written its first status, the file still holds the previous run's final numbers.
    func progressText(busy: Bool, hasSummary: Bool) -> String? {
        guard busy else { return nil }
        let phase = hasSummary ? "Refreshing…" : "Scanning…"
        guard state == "scanning", total > 0 else { return phase }
        return "\(phase) \(UsageFormat.count(Double(done))) of \(UsageFormat.count(Double(total))) files"
    }

    var failureText: String? { state == "failed" ? "Usage could not be read." : nil }
}

// MARK: - The reduction

/// Which figure a tab is about. The page has a third tab, Limits, that is not a metric of this
/// model, hence the chart's name for the pair.
enum UsageChartMetric: String {
    case cost, tokens
}

/// Anything with a cost and a token count can be asked for "the figure of the current tab".
protocol UsageMeasured {
    var costUsd: Double { get }
    var totalTokens: Double { get }
}

extension UsageMeasured {
    func value(_ metric: UsageChartMetric) -> Double { metric == .tokens ? totalTokens : costUsd }
}

struct UsageAmount: Equatable, UsageMeasured {
    var costUsd = 0.0
    var totalTokens = 0.0
}

struct UsageProviderTotals: Equatable, UsageMeasured {
    let provider: String
    var costUsd = 0.0
    var totalTokens = 0.0
    var records = 0.0
    var sessions = 0.0
    var costShare = 0.0
    var tokenShare = 0.0
}

struct UsageModelTotals: Equatable, UsageMeasured {
    let model: String
    let provider: String
    var costUsd = 0.0
    var totalTokens = 0.0
    var tokens = UsageTokenTotals()
    var records = 0.0
    var unpricedRecords = 0.0
    /// A Double because it may be an estimate: without the writer's own count it is the model's
    /// tokens times its unpriced share of records.
    var unpricedTokens = 0.0
    var costShare = 0.0
    var tokenShare = 0.0

    /// What a selection of this row is remembered by.
    var id: String { provider + ":" + model }

    /// Every record lacked a price, so the cost is unknown — not zero. The page prints "Unpriced"
    /// instead of a dollar figure and gives the model no share of cost.
    var isCostUnknown: Bool { records > 0 && unpricedRecords >= records }

    /// Share of input that was read from cache; cache writes count as misses, because that input
    /// was processed in full. Nil without any input.
    var cacheHitRate: Double? {
        let input = tokens.uncachedInputTokens + tokens.cachedInputTokens + tokens.cacheCreationTokens
        return input == 0 ? nil : tokens.cachedInputTokens / input
    }

    /// Dollars per million of the tokens that had a price. Nil when none had one.
    var costPerMillionTokens: Double? {
        let priced = totalTokens - unpricedTokens
        return priced <= 0 || isCostUnknown ? nil : costUsd / priced * 1_000_000
    }

    /// The Share column. An unknown cost has no cost share; tokens always have one.
    func share(_ metric: UsageChartMetric) -> Double? {
        if metric == .tokens { return tokenShare }
        return isCostUnknown ? nil : costShare
    }

    /// What the model's own trend chart plots: the page's metric, except that an unknown cost
    /// would draw a flat line at zero, which reads as "free".
    func trendMetric(_ page: UsageChartMetric) -> UsageChartMetric { isCostUnknown ? .tokens : page }
}

/// One day, or one rolling hour, of the window.
struct UsagePeriodTotals: Equatable {
    let day: String
    let hourStart: String?
    var costUsd = 0.0
    var totalTokens = 0.0
    var byProvider: [String: UsageAmount] = [:]

    /// What a chart column is matched by: the hour start in an hourly list, else the day.
    var key: String { hourStart ?? day }

    fileprivate mutating func add(_ bucket: UsageBucket) {
        let tokens = bucket.totals.total
        costUsd += bucket.costUsd
        totalTokens += tokens
        byProvider[bucket.provider, default: UsageAmount()].costUsd += bucket.costUsd
        byProvider[bucket.provider, default: UsageAmount()].totalTokens += tokens
    }
}

/// How much of the cost figure is how good. A bucket counts as provider-reported with all of its
/// records or none; unpriced records are counted one by one.
struct UsageCostQuality: Equatable {
    var providerReportedShare = 0.0
    var modelPricedShare = 0.0
    var unpricedShare = 0.0
    var cacheSavingsUsd = 0.0
}

/// Cost by speed tier. `fast` and `ultrafast` are the whole cost of requests that ran at that
/// tier; `premium` is only what the tier added over the standard price.
struct UsageSpeedCost: Equatable {
    var standard = 0.0
    var fast = 0.0
    var ultrafast = 0.0
    var premium = 0.0

    /// The "Cost by speed" bar is drawn only when something ran above the standard tier.
    var hasFastTiers: Bool { fast + ultrafast > 0 }
}

/// A dictionary that remembers the order its keys first appeared in. Ties in the tables keep
/// first-seen order, and a plain dictionary would shuffle them between launches.
private struct UsageOrdered<Value> {
    private var keys: [String] = []
    private var values: [String: Value] = [:]

    mutating func update(_ key: String, initial: @autoclosure () -> Value, _ change: (inout Value) -> Void) {
        if values[key] == nil { keys.append(key) }
        change(&values[key, default: initial()])
    }

    var inOrder: [Value] { keys.compactMap { values[$0] } }
}

private extension Array {
    /// Swift does not promise that `sorted` keeps equal elements in order; the row order of the
    /// tables depends on it.
    func usageStableSorted(by precedes: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { left, right in
            if precedes(left.element, right.element) { return true }
            if precedes(right.element, left.element) { return false }
            return left.offset < right.offset
        }.map { $0.element }
    }
}

/// Everything the Cost and Tokens tabs show for one period and one provider filter.
struct UsageTotals {
    /// Claude, then Codex, on all three tabs.
    static let providerOrder: [String] = Provider.all.map { $0.id }

    let costUsd: Double
    let tokens: UsageTokenTotals
    let records: Double
    /// Summed from the sources. Buckets cannot be used for this: a session that spans two days or
    /// two models sits in several buckets and would be counted once for each.
    let sessions: Double
    /// By cost, largest first.
    let providers: [UsageProviderTotals]
    /// By cost, then tokens, then first seen.
    let models: [UsageModelTotals]
    /// Only days that have data, oldest first. Built in an hourly period too.
    let daily: [UsagePeriodTotals]
    /// Only hours that have data, oldest first. Empty in a daily period.
    let hourly: [UsagePeriodTotals]
    let costQuality: UsageCostQuality
    let categoryCost: UsageCategoryCost
    let speedCost: UsageSpeedCost

    var totalTokens: Double { tokens.total }

    /// The page: `provider` nil is all providers, otherwise the one that is shown. A filtered-out
    /// provider leaves with its sources too, so sessions and shares are those of what is left.
    init(period: UsagePeriod, provider: String? = nil) {
        self.init(period: period, provider: provider) { _ in true }
    }

    /// The model dialog: the same reduction over that model's buckets alone. It feeds the trend
    /// chart and the dialog's own cost bars; the headline numbers of the dialog come from the
    /// row that was clicked.
    init(period: UsagePeriod, model: UsageModelTotals) {
        self.init(period: period, provider: model.provider) { $0.model == model.model }
    }

    private init(period: UsagePeriod, provider only: String?, keep: (UsageBucket) -> Bool) {
        var providers = UsageOrdered<UsageProviderTotals>()
        // A provider is counted when a source of its own stands behind its buckets. "missing"
        // is the one status that takes a provider out: there is no history to have read.
        var counted = Set<String>()
        var sessions = 0.0
        for source in period.sources where source.status != "missing" && (only == nil || source.provider == only) {
            counted.insert(source.provider)
            sessions += source.distinctSessions
            guard source.distinctSessions > 0 else { continue }
            providers.update(source.provider, initial: UsageProviderTotals(provider: source.provider)) {
                $0.sessions += source.distinctSessions
            }
        }

        var costUsd = 0.0
        var tokens = UsageTokenTotals()
        var records = 0.0
        var unpricedRecords = 0.0
        var providerReportedRecords = 0.0
        var quality = UsageCostQuality()
        var category = UsageCategoryCost()
        var speed = UsageSpeedCost()
        var models = UsageOrdered<UsageModelTotals>()
        var days = UsageOrdered<UsagePeriodTotals>()
        var hours = UsageOrdered<UsagePeriodTotals>()

        for bucket in period.buckets where counted.contains(bucket.provider) && keep(bucket) {
            let bucketTokens = bucket.totals.total
            costUsd += bucket.costUsd
            quality.cacheSavingsUsd += bucket.cacheSavingsUsd
            tokens.add(bucket.totals)
            records += bucket.records
            unpricedRecords += bucket.unpricedRecords
            if bucket.costSource == "providerReported" { providerReportedRecords += bucket.records }
            if let split = bucket.categoryCost {
                category.input += split.input
                category.cacheRead += split.cacheRead
                category.cacheWrite += split.cacheWrite
                category.output += split.output
            }
            speed.fast += bucket.fastCostUsd
            speed.ultrafast += bucket.ultrafastCostUsd
            speed.premium += bucket.speedPremiumUsd

            providers.update(bucket.provider, initial: UsageProviderTotals(provider: bucket.provider)) {
                $0.costUsd += bucket.costUsd
                $0.totalTokens += bucketTokens
                $0.records += bucket.records
            }
            models.update(bucket.provider + " " + bucket.model,
                          initial: UsageModelTotals(model: bucket.model, provider: bucket.provider)) { model in
                model.costUsd += bucket.costUsd
                model.totalTokens += bucketTokens
                model.tokens.add(bucket.totals)
                model.records += bucket.records
                model.unpricedRecords += bucket.unpricedRecords
                if let unpriced = bucket.unpricedTokens {
                    model.unpricedTokens += unpriced
                } else if bucket.records > 0 {
                    model.unpricedTokens += bucketTokens * bucket.unpricedRecords / bucket.records
                }
            }
            days.update(bucket.day, initial: UsagePeriodTotals(day: bucket.day, hourStart: nil)) { $0.add(bucket) }
            if let hourStart = bucket.hourStart {
                hours.update(hourStart, initial: UsagePeriodTotals(day: bucket.day, hourStart: hourStart)) { $0.add(bucket) }
            }
        }

        let totalTokens = tokens.total
        let costShare = { (cost: Double) in costUsd == 0 ? 0 : cost / costUsd }
        let tokenShare = { (count: Double) in totalTokens == 0 ? 0 : count / totalTokens }

        self.costUsd = costUsd
        self.tokens = tokens
        self.records = records
        self.sessions = sessions
        self.providers = providers.inOrder.map { entry in
            var entry = entry
            entry.costShare = costShare(entry.costUsd)
            entry.tokenShare = tokenShare(entry.totalTokens)
            return entry
        }.usageStableSorted { $0.costUsd > $1.costUsd }
        self.models = models.inOrder.map { entry in
            var entry = entry
            entry.costShare = costShare(entry.costUsd)
            entry.tokenShare = tokenShare(entry.totalTokens)
            return entry
        }.usageStableSorted { $0.costUsd != $1.costUsd ? $0.costUsd > $1.costUsd : $0.totalTokens > $1.totalTokens }
        daily = days.inOrder.sorted { $0.day < $1.day }
        hourly = hours.inOrder.sorted { $0.key < $1.key }

        if records > 0 {
            quality.providerReportedShare = providerReportedRecords / records
            quality.unpricedShare = unpricedRecords / records
            quality.modelPricedShare = (records - providerReportedRecords - unpricedRecords) / records
        }
        costQuality = quality
        let split = category.input + category.cacheRead + category.cacheWrite + category.output
        category.unsplit = max(0, costUsd - split)
        categoryCost = category
        speed.standard = max(0, costUsd - speed.fast - speed.ultrafast)
        speedCost = speed
    }

    /// The rows of the "By day" or "By hour" table and the data of the chart.
    func timeline(hourly: Bool) -> [UsagePeriodTotals] { hourly ? self.hourly : daily }

    /// Providers that have anything to show, in the fixed order. These get a summary row, a chart
    /// series and a column in the time table.
    var activeProviders: [String] {
        UsageTotals.providerOrder.filter { id in
            providers.contains { $0.provider == id && ($0.totalTokens > 0 || $0.costUsd > 0) }
        }
    }

    /// The summary rows: active providers, the larger figure of the current tab first.
    func rankedProviders(by metric: UsageChartMetric) -> [UsageProviderTotals] {
        activeProviders.compactMap { id in providers.first { $0.provider == id } }
            .usageStableSorted { $0.value(metric) > $1.value(metric) }
    }

    /// The model table: by cost on the Cost tab, by tokens (then cost) on the Tokens tab.
    func models(by metric: UsageChartMetric) -> [UsageModelTotals] {
        guard metric == .tokens else { return models }
        return models.usageStableSorted {
            $0.totalTokens != $1.totalTokens ? $0.totalTokens > $1.totalTokens : $0.costUsd > $1.costUsd
        }
    }
}

// MARK: - Formatting

/// The page's figures as text, by T3's rules. Nothing here reads this Mac's locale or time zone on
/// its own: the window is in English whatever the system language is, and labels belong to the
/// zone the summary was bucketed in.
enum UsageFormat {
    static let locale = Locale(identifier: "en_US")

    private static let usdFormatter = numberFormatter(locale, currency: true)
    private static let countFormatter = numberFormatter(locale, currency: false)

    private static func numberFormatter(_ locale: Locale, currency: Bool) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = currency ? .currency : .decimal
        if currency { formatter.currencyCode = "USD" }
        formatter.minimumFractionDigits = currency ? 2 : 0
        formatter.maximumFractionDigits = currency ? 2 : 0
        // The default is banker's rounding, which prints half a cent as $0.00. T3 prints $0.01.
        formatter.roundingMode = .halfUp
        return formatter
    }

    /// Always two decimals: there is no sub-cent and no "<$0.01" form, so $0.004 is "$0.00".
    static func usd(_ value: Double, locale: Locale = UsageFormat.locale) -> String {
        let formatter = locale == UsageFormat.locale ? usdFormatter : numberFormatter(locale, currency: true)
        return formatter.string(from: NSNumber(value: value)) ?? ""
    }

    /// A whole number with grouping: "1,234".
    static func count(_ value: Double, locale: Locale = UsageFormat.locale) -> String {
        let formatter = locale == UsageFormat.locale ? countFormatter : numberFormatter(locale, currency: false)
        return formatter.string(from: NSNumber(value: roundedHalfUp(value))) ?? ""
    }

    /// JavaScript's Math.round: halves go up, so -1.5 is -1.
    private static func roundedHalfUp(_ value: Double) -> Double { (value + 0.5).rounded(.down) }

    /// JavaScript's toFixed, which the token and percentage rules are written in.
    ///
    /// printf rounds the binary value correctly and so does toFixed — they part ways only on an
    /// exact tie, where printf goes to the even digit and toFixed goes up: 1,125 tokens are
    /// "1.13K", not "1.12K". A double is a tie at `digits` decimals exactly when it is an odd
    /// multiple of 1/2^(digits+1), and multiplying by a power of two is exact, so the test is too.
    private static func fixed(_ value: Double, digits: Int) -> String {
        let magnitude = abs(value)
        var rounded = magnitude
        let halves = magnitude * Double(1 << (digits + 1))
        if halves == halves.rounded(.down), halves.truncatingRemainder(dividingBy: 2) == 1 {
            let power = pow(10, Double(digits))
            rounded = (magnitude * power).rounded(.up) / power
        }
        return (value < 0 ? "-" : "") + String(format: "%.\(digits)f", rounded)
    }

    private static let tokenSuffixes = ["K", "M", "B", "T"]

    /// Three significant digits and a unit: "1.20M", "12.3K", "123K". The fraction is dropped
    /// only when it is all zeros ("1M"), and the unit is chosen after rounding, so 999,999 reads
    /// "1M" rather than "1000K".
    static func tokens(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let whole = roundedHalfUp(value)
        if abs(whole) < 1000 { return String(whole.clampedInt) }
        var scaled = value / 1000
        var unit = 0
        while abs(Double(trimmed(scaled)) ?? 0) >= 1000, unit < tokenSuffixes.count - 1 {
            scaled /= 1000
            unit += 1
        }
        return trimmed(scaled) + tokenSuffixes[unit]
    }

    private static func trimmed(_ value: Double) -> String {
        let magnitude = abs(value)
        let text = fixed(value, digits: magnitude >= 100 ? 0 : magnitude >= 10 ? 1 : 2)
        guard let dot = text.firstIndex(of: "."), text[text.index(after: dot)...].allSatisfy({ $0 == "0" })
        else { return text }
        return String(text[..<dot])
    }

    /// One decimal, and "<0.1%" for a share that is not nothing but would print as 0.0%.
    static func percent(_ share: Double, digits: Int = 1) -> String {
        let percent = share * 100
        let smallest = 1 / pow(10, Double(digits))
        if percent > 0, percent < smallest { return "<" + fixed(smallest, digits: digits) + "%" }
        return fixed(percent, digits: digits) + "%"
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "Nov 19" for "2026-11-19". Text that is not a day is returned as it came.
    static func dayShort(_ day: String) -> String {
        guard let parts = UsageDays.parts(day), months.indices.contains(parts.month - 1) else { return day }
        return "\(months[parts.month - 1]) \(parts.day)"
    }

    private static func hourLabel(_ hour: Int, hour12: Bool) -> String {
        guard hour12 else { return String(format: "%02ld:00", hour) }
        return "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")"
    }

    /// "1 PM" or "13:00". A rolling hour starts at some minute past, but its label always names
    /// the whole hour. On the night the clocks go back one wall-clock hour happens twice, and
    /// only then the label carries the zone's short name, so the two stay distinguishable:
    /// "1 AM EDT", "1 AM EST".
    static func hourShort(_ instant: String, timeZone: TimeZone, hour12: Bool,
                          locale: Locale = UsageFormat.locale) -> String {
        guard let seconds = UsageInstant.seconds(instant) else { return instant }
        let date = Date(timeIntervalSince1970: seconds)
        let calendar = UsageDays.calendar(timeZone)
        let wallHour = { (moment: Date) in calendar.dateComponents([.year, .month, .day, .hour], from: moment) }
        let label = hourLabel(calendar.component(.hour, from: date), hour12: hour12)
        let here = wallHour(date)
        let repeated = wallHour(date.addingTimeInterval(-3600)) == here || wallHour(date.addingTimeInterval(3600)) == here
        guard repeated else { return label }
        let style: NSTimeZone.NameStyle = timeZone.isDaylightSavingTime(for: date) ? .shortDaylightSaving : .shortStandard
        let zone = timeZone.localizedName(for: style, locale: locale) ?? timeZone.abbreviation(for: date) ?? ""
        return zone.isEmpty ? label : label + " " + zone
    }

    /// "Nov 19, 1 PM" or "Nov 19, 13:00".
    static func dateTimeShort(_ instant: String, timeZone: TimeZone, hour12: Bool) -> String {
        guard let seconds = UsageInstant.seconds(instant) else { return instant }
        let parts = UsageDays.calendar(timeZone).dateComponents([.month, .day, .hour],
                                                                from: Date(timeIntervalSince1970: seconds))
        guard let month = parts.month, months.indices.contains(month - 1), let day = parts.day, let hour = parts.hour
        else { return instant }
        return "\(months[month - 1]) \(day), \(hourLabel(hour, hour12: hour12))"
    }

    /// The chart tooltip's hour: "1 PM today", "1 PM yesterday", else the date form. Days are
    /// calendar days in the window's zone, counted back from `relativeTo` (the window's end).
    static func relativeHourShort(_ instant: String, relativeTo reference: String, timeZone: TimeZone,
                                  hour12: Bool, locale: Locale = UsageFormat.locale) -> String {
        guard let seconds = UsageInstant.seconds(instant), let referenceSeconds = UsageInstant.seconds(reference)
        else { return dateTimeShort(instant, timeZone: timeZone, hour12: hour12) }
        let calendar = UsageDays.calendar(timeZone)
        let localDay = { (moment: Double) in UsageDays.date(UsageDays.string(Date(timeIntervalSince1970: moment), in: calendar)) }
        guard let day = localDay(seconds), let referenceDay = localDay(referenceSeconds)
        else { return dateTimeShort(instant, timeZone: timeZone, hour12: hour12) }
        let daysAgo = (referenceDay.timeIntervalSince(day) / 86_400).rounded()
        let hour = hourShort(instant, timeZone: timeZone, hour12: hour12, locale: locale)
        if daysAgo == 0 { return "\(hour) today" }
        if daysAgo == 1 { return "\(hour) yesterday" }
        return dateTimeShort(instant, timeZone: timeZone, hour12: hour12)
    }

    /// A chart column or table row: the day, or the hour of a rolling hour.
    static func periodLabel(_ key: String, hourly: Bool, timeZone: TimeZone, hour12: Bool) -> String {
        hourly ? hourShort(key, timeZone: timeZone, hour12: hour12) : dayShort(key)
    }

    /// The same column in the chart tooltip, where an hour is also told apart by its day.
    static func tooltipPeriodLabel(_ key: String, in period: UsagePeriod, timeZone: TimeZone, hour12: Bool) -> String {
        guard period.isHourly, let reference = period.untilTime
        else { return periodLabel(key, hourly: period.isHourly, timeZone: timeZone, hour12: hour12) }
        return relativeHourShort(key, relativeTo: reference, timeZone: timeZone, hour12: hour12)
    }

    /// The header's "{start} to {end}": "Oct 21 to Nov 19", or with hours for the Past 24h window.
    static func windowLabel(_ period: UsagePeriod, timeZone: TimeZone, hour12: Bool) -> String {
        if period.isHourly, let since = period.sinceTime, let until = period.untilTime {
            let start = dateTimeShort(since, timeZone: timeZone, hour12: hour12)
            return "\(start) to \(dateTimeShort(until, timeZone: timeZone, hour12: hour12))"
        }
        return "\(dayShort(period.sinceDay)) to \(dayShort(period.untilDay))"
    }

    /// Whether hours read "1 PM" rather than "13:00" for this locale. The window follows the
    /// system clock setting, which `Locale.current` carries.
    static func uses12HourClock(_ locale: Locale) -> Bool {
        DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)?.contains("a") ?? true
    }

    // The writer never asks for more than 90 days or 24 hours. A bound read from a damaged file
    // can span millennia, and a chart that allocates a label for each of those days is a hang;
    // such a window draws nothing instead.
    private static let mostDays = 366.0
    private static let mostHours = 48.0

    /// Every day from `since` to `until`, both included. Calendar arithmetic in UTC, so a
    /// daylight-saving day is neither skipped nor doubled. Empty for unreadable or reversed bounds.
    static func enumerateDays(since: String, until: String) -> [String] {
        guard let start = UsageDays.date(since), let end = UsageDays.date(until) else { return [] }
        let last = (end.timeIntervalSince(start) / 86_400).rounded()
        guard last >= 0, last < mostDays else { return [] }
        return (0...last.clampedInt).map { UsageDays.string(start.addingTimeInterval(Double($0) * 86_400), in: UsageDays.utc) }
    }

    /// The start of every rolling hour from `since` up to, not including, `until`. These equal
    /// the buckets' `hourStart` values, which is how a chart point finds its bucket.
    static func enumerateHourStarts(since: String, until: String) -> [String] {
        guard let start = UsageInstant.seconds(since), let end = UsageInstant.seconds(until), end > start
        else { return [] }
        let count = ((end - start) / 3600).rounded(.up)
        guard count <= mostHours else { return [] }
        return (0..<count.clampedInt).map { UsageInstant.string(start + Double($0) * 3600) }
    }
}

// MARK: - Copy and colours

/// A colour as two 0xRRGGBB numbers, one per appearance. Plain numbers because the model does
/// not import SwiftUI; the view turns them into its own colour type.
struct UsageInk: Equatable {
    let light: UInt32
    let dark: UInt32

    func rgb(dark isDark: Bool) -> (red: Double, green: Double, blue: Double) {
        let hex = isDark ? dark : light
        return (Double((hex >> 16) & 0xff) / 255, Double((hex >> 8) & 0xff) / 255, Double(hex & 0xff) / 255)
    }
}

/// T3's colours for this page, resolved for its default light and dark palettes.
enum UsagePalette {
    /// The series, dot and row bar of a provider. Codex is drawn in the foreground colour of the
    /// appearance, which is why it has two values and Claude's orange has one.
    static func provider(_ id: String) -> UsageInk {
        id == Provider.claude.id ? UsageInk(light: 0xd97757, dark: 0xd97757) : UsageInk(light: 0x18181b, dark: 0xf5f5f5)
    }

    // Share-bar segments are greys: the foreground mixed into the background at a fixed
    // percentage (60, 30, 72, 100, 44 for the types; 34, 66, 100 for the speeds).
    static let input = UsageInk(light: 0x69696c, dark: 0x7b7b7b)
    static let cacheRead = UsageInk(light: 0xb0b0b1, dark: 0x2b2b2b)
    static let cacheWrite = UsageInk(light: 0x4f4f52, dark: 0x9e9e9e)
    static let output = UsageInk(light: 0x18181b, dark: 0xf5f5f5)
    static let other = UsageInk(light: 0x8e8e90, dark: 0x4f4f4f)
    static let standard = UsageInk(light: 0xa6a6a8, dark: 0x353535)
    static let fast = UsageInk(light: 0x5c5c5f, dark: 0x8c8c8c)
    static let ultrafast = UsageInk(light: 0x18181b, dark: 0xf5f5f5)
}

/// One part of a share bar.
struct UsageShareSegment: Equatable {
    let label: String
    let value: Double
    let ink: UsageInk

    /// What is actually drawn: parts of zero are dropped, and with nothing left there is no bar.
    static func visible(_ segments: [UsageShareSegment]) -> [UsageShareSegment] {
        segments.filter { $0.value > 0 }
    }

    /// "Standard · $9.00 · 60.0%".
    static func tooltip(_ segment: UsageShareSegment, among segments: [UsageShareSegment],
                        metric: UsageChartMetric) -> String {
        let total = visible(segments).reduce(0.0) { $0 + $1.value }
        let value = metric == .tokens ? UsageFormat.tokens(segment.value) : UsageFormat.usd(segment.value)
        return "\(segment.label) · \(value) · \(UsageFormat.percent(total > 0 ? segment.value / total : 0))"
    }
}

extension UsageCategoryCost {
    /// "Cost by type". Unsplit cost under half a cent is the rounding of the split, not a cost
    /// of its own, and gets no "Other" part.
    var segments: [UsageShareSegment] {
        [UsageShareSegment(label: "Input", value: input, ink: UsagePalette.input),
         UsageShareSegment(label: "Cache read", value: cacheRead, ink: UsagePalette.cacheRead),
         UsageShareSegment(label: "Cache write", value: cacheWrite, ink: UsagePalette.cacheWrite),
         UsageShareSegment(label: "Output", value: output, ink: UsagePalette.output),
         UsageShareSegment(label: "Other", value: unsplit >= 0.005 ? unsplit : 0, ink: UsagePalette.other)]
    }
}

extension UsageTokenTotals {
    /// "Tokens by type". Reasoning has no part: it is inside Output.
    var segments: [UsageShareSegment] {
        [UsageShareSegment(label: "Input", value: uncachedInputTokens, ink: UsagePalette.input),
         UsageShareSegment(label: "Cache read", value: cachedInputTokens, ink: UsagePalette.cacheRead),
         UsageShareSegment(label: "Cache write", value: cacheCreationTokens, ink: UsagePalette.cacheWrite),
         UsageShareSegment(label: "Output", value: outputTokens, ink: UsagePalette.output)]
    }
}

extension UsageSpeedCost {
    /// "Cost by speed".
    var segments: [UsageShareSegment] {
        [UsageShareSegment(label: "Standard", value: standard, ink: UsagePalette.standard),
         UsageShareSegment(label: "Fast", value: fast, ink: UsagePalette.fast),
         UsageShareSegment(label: "Ultrafast", value: ultrafast, ink: UsagePalette.ultrafast)]
    }
}

/// The English sentences of the two tabs that are more than a fixed label.
enum UsageCopy {
    static let unpriced = "Unpriced"
    static let noActivity = "No activity in this window."

    static func providerName(_ id: String) -> String { Provider.named(id).title }

    /// Under the headline figure. It reads "sessions" for one session too — that is T3's string.
    static func sessionsCaption(_ sessions: Double, metric: UsageChartMetric) -> String {
        "\(UsageFormat.count(sessions)) sessions" + (metric == .cost ? " · API estimate" : "")
    }

    /// Beside a provider's name; this one does have a singular.
    static func providerSessions(_ sessions: Double) -> String {
        "\(UsageFormat.count(sessions)) \(sessions == 1 ? "session" : "sessions")"
    }

    /// Under a provider's name: its share of the tab's figure, and the other figure.
    static func providerDetail(_ provider: UsageProviderTotals, metric: UsageChartMetric) -> String {
        metric == .cost
            ? "\(UsageFormat.percent(provider.costShare)) of cost · \(UsageFormat.tokens(provider.totalTokens)) tokens"
            : "\(UsageFormat.percent(provider.tokenShare)) of tokens · \(UsageFormat.usd(provider.costUsd))"
    }

    static func chartHeading(hourly: Bool, metric: UsageChartMetric) -> String {
        (hourly ? "Hourly " : "Daily ") + (metric == .cost ? "cost" : "processed tokens")
    }

    /// Behind the info mark next to "API estimate", shown only when the share is above zero.
    static func unpricedNotice(share: Double) -> String {
        "API estimate excludes \(UsageFormat.percent(share)) unpriced records."
    }

    /// The model dialog's footer, shown only when the model has unpriced tokens.
    static func unpricedFooter(tokens: Double) -> String {
        "\(UsageFormat.tokens(tokens)) tokens have no known price"
    }

    static func premium(_ usd: Double) -> String { "Premium \(UsageFormat.usd(usd))" }

    static func malformed(_ records: Double) -> String {
        String(format: "%.0f", records)
            + " malformed or inconsistent usage record(s) were skipped; usage may be incomplete."
    }

    /// What one source has to say, or nil. The writer sends a category word, never text of its
    /// own, so nothing from a traceback or a path can end up on screen; a word this build does not
    /// know is answered by the status alone.
    ///
    /// T3 has one sentence per case and no provider in it, because it lists environments. With two
    /// providers in one window the sentence has to say which one it is about.
    static func sourceWarning(_ source: UsageSource) -> String? {
        let name = providerName(source.provider)
        switch source.message {
        case "zstd_unavailable":
            // No number of files: `skippedFiles` also counts files that were read and simply held
            // no usage, so it is not the number of compressed ones.
            return "Compressed \(name) session files were skipped because zstd is not installed; usage may be incomplete."
        case "no_history":
            return "No \(name) transcript directory was found on this Mac."
        default:
            if source.status == "failed" { return "\(name) could not report usage." }
            // A partial read with no reason given but with skipped records is already explained
            // by the skipped-records warning.
            let explained = source.message == nil && source.malformedRecords > 0
            guard source.message == "read_failed" || (source.status == "partial" && !explained) else { return nil }
            return "Some \(name) transcripts could not be read; usage may be incomplete."
        }
    }
}

// MARK: - Chart

struct UsageChartPoint: Equatable {
    let x: Double
    let y: Double
}

/// One cubic Bézier piece of a series line.
struct UsageChartSegment: Equatable {
    let from: UsageChartPoint
    let c1: UsageChartPoint
    let c2: UsageChartPoint
    let to: UsageChartPoint
}

struct UsageChartScale: Equatable {
    let max: Double
    let ticks: [Double]
    /// False for the placeholder grid drawn while the first figures load: lines, no numbers.
    let labeled: Bool
}

struct UsageChartSeries: Equatable {
    let provider: String
    /// One value per chart column; zero where the provider has no data.
    let values: [Double]

    var total: Double { values.reduce(0, +) }
}

/// The layered area chart as numbers: one series per provider, each drawn from zero (not stacked),
/// over every day or hour of the window.
struct UsageChartData {
    let periods: [String]
    /// In the order of the providers asked for.
    let series: [UsageChartSeries]
    let scale: UsageChartScale

    init(periods: [String], timeline: [UsagePeriodTotals], metric: UsageChartMetric, providers: [String],
         loading: Bool = false) {
        var byKey: [String: UsagePeriodTotals] = [:]
        for entry in timeline { byKey[entry.key] = entry }
        self.periods = periods
        series = providers.map { provider in
            UsageChartSeries(provider: provider,
                             values: periods.map { byKey[$0]?.byProvider[provider]?.value(metric) ?? 0 })
        }
        // The largest single value, not the largest column sum: the series overlap rather than
        // stack, and scaling to the sum would leave the top of the plot empty.
        let peak = series.reduce(0.0) { Swift.max($0, $1.values.max() ?? 0) }
        scale = peak == 0 && loading ? UsageChart.placeholderScale : UsageChart.niceScale(peak: peak)
    }

    init(period: UsagePeriod, totals: UsageTotals, metric: UsageChartMetric, providers: [String],
         loading: Bool = false) {
        self.init(periods: period.periodKeys, timeline: totals.timeline(hourly: period.isHourly), metric: metric,
                  providers: providers, loading: loading)
    }

    /// Largest series first, so a smaller one is painted on top of it and stays visible.
    var drawOrder: [UsageChartSeries] { series.usageStableSorted { $0.total > $1.total } }

    /// The tooltip's "Total" row for one column.
    func total(at index: Int) -> Double {
        series.reduce(0.0) { $0 + ($1.values.indices.contains(index) ? $1.values[index] : 0) }
    }

    /// A series' points in a plot of the given size, y growing downwards.
    func points(_ series: UsageChartSeries, width: Double, height: Double) -> [UsageChartPoint] {
        series.values.enumerated().map { index, value in
            UsageChartPoint(x: UsageChart.x(index, count: series.values.count, width: width),
                            y: UsageChart.y(value, max: scale.max, height: height))
        }
    }
}

/// The chart's arithmetic, so the view only draws.
enum UsageChart {
    static let tickCount = 4
    // T3 draws into a 960 by 260 box and keeps the top 8 clear; the same proportion is kept at
    // whatever height the plot really has.
    private static let viewHeight = 260.0
    private static let plotTop = 8.0

    static let placeholderScale = UsageChartScale(max: Double(tickCount), ticks: (0...tickCount).map { Double($0) },
                                                  labeled: false)

    /// A maximum at or above the peak that divides into round steps (1, 2, 5 or 10 times a power
    /// of ten), and those steps as ticks. A peak of 37 gives 0, 10, 20, 30, 40.
    static func niceScale(peak: Double) -> UsageChartScale {
        let none = UsageChartScale(max: 0, ticks: [0], labeled: true)
        guard peak > 0, peak.isFinite else { return none }
        let rawStep = peak / Double(tickCount)
        let magnitude = pow(10, log10(rawStep).rounded(.down))
        let normalized = rawStep / magnitude
        let factor: Double = normalized > 5 ? 10 : normalized > 2 ? 5 : normalized > 1 ? 2 : 1
        let step = factor * magnitude
        // A peak too small to take a logarithm of has no step, and a loop over a step of zero
        // would never end.
        guard step > 0, step.isFinite else { return none }
        let top = (peak / step).rounded(.up) * step
        var ticks: [Double] = []
        var value = 0.0
        while value <= top + step * 1e-6, ticks.count <= 2 * tickCount {
            ticks.append(value)
            value += step
        }
        return UsageChartScale(max: top, ticks: ticks, labeled: true)
    }

    /// Where a value sits, top down: zero on the bottom edge, the scale's maximum just under the top.
    static func y(_ value: Double, max: Double, height: Double) -> Double {
        guard max > 0 else { return height }
        return height - value / max * (height - height * plotTop / viewHeight)
    }

    /// Columns run edge to edge: the first on the left edge, the last on the right.
    static func x(_ index: Int, count: Int, width: Double) -> Double {
        count < 2 ? 0 : Double(index) * width / Double(count - 1)
    }

    /// A smooth line through the points that never overshoots them (monotone cubic interpolation,
    /// Fritsch-Carlson): a day of zero between two busy days touches zero instead of dipping
    /// below it. Fewer than two points draw nothing.
    static func curve(_ points: [UsageChartPoint]) -> [UsageChartSegment] {
        let count = points.count
        guard count >= 2 else { return [] }
        let slopes: [Double] = (0..<count - 1).map { index in
            let dx = points[index + 1].x - points[index].x
            return dx == 0 ? 0 : (points[index + 1].y - points[index].y) / dx
        }
        var tangents = [Double](repeating: 0, count: count)
        tangents[0] = slopes[0]
        tangents[count - 1] = slopes[count - 2]
        if count > 2 {
            for index in 1..<count - 1 {
                let before = slopes[index - 1]
                let after = slopes[index]
                // A change of direction is a peak or a trough: flat there, or the curve bulges past it.
                tangents[index] = before * after <= 0 ? 0 : (before + after) / 2
            }
        }
        for index in 0..<count - 1 {
            let slope = slopes[index]
            if slope == 0 {
                tangents[index] = 0
                tangents[index + 1] = 0
                continue
            }
            let a = tangents[index] / slope
            let b = tangents[index + 1] / slope
            let magnitude = a * a + b * b
            if magnitude > 9 {
                let scale = 3 / magnitude.squareRoot()
                tangents[index] = scale * a * slope
                tangents[index + 1] = scale * b * slope
            }
        }
        return (0..<count - 1).map { index in
            let from = points[index]
            let to = points[index + 1]
            let third = (to.x - from.x) / 3
            return UsageChartSegment(from: from,
                                     c1: UsageChartPoint(x: from.x + third, y: from.y + tangents[index] * third),
                                     c2: UsageChartPoint(x: to.x - third, y: to.y - tangents[index + 1] * third),
                                     to: to)
        }
    }

    /// The column under the pointer: the nearest one, the edge ones outside the plot. Nil when
    /// there is nothing to point at.
    static func hoverIndex(x: Double, width: Double, count: Int) -> Int? {
        guard count > 0, width > 0 else { return nil }
        let inside = min(width, Swift.max(0, x))
        let index = (inside / width * Double(count - 1)).rounded().clampedInt
        return min(count - 1, Swift.max(0, index))
    }

    /// The tooltip's top-left corner: 12 right of and below the pointer, flipped to the other
    /// side where it would not fit, and never outside the plot.
    static func tooltipOrigin(pointer: UsageChartPoint, tooltipWidth: Double, tooltipHeight: Double,
                              plotWidth: Double, plotHeight: Double) -> UsageChartPoint {
        let gap = 12.0
        let left = pointer.x + gap + tooltipWidth <= plotWidth ? pointer.x + gap : pointer.x - gap - tooltipWidth
        let top = pointer.y + gap + tooltipHeight <= plotHeight ? pointer.y + gap : pointer.y - gap - tooltipHeight
        return UsageChartPoint(x: min(Swift.max(0, left), Swift.max(0, plotWidth - tooltipWidth)),
                               y: min(Swift.max(0, top), Swift.max(0, plotHeight - tooltipHeight)))
    }

    /// The y axis: a bare "0" at the bottom, the tab's own format above it.
    static func tickLabel(_ tick: Double, metric: UsageChartMetric) -> String {
        if tick == 0 { return "0" }
        return metric == .tokens ? UsageFormat.tokens(tick) : UsageFormat.usd(tick)
    }

    /// The x axis: the first, the middle and the last period, in capitals. Spread edge to edge
    /// by the view. No periods, no labels.
    static func axisLabels(_ periods: [String], hourly: Bool, timeZone: TimeZone, hour12: Bool) -> [String] {
        guard let first = periods.first, let last = periods.last else { return [] }
        return [first, periods[periods.count / 2], last].map {
            UsageFormat.periodLabel($0, hourly: hourly, timeZone: timeZone, hour12: hour12).uppercased()
        }
    }
}
