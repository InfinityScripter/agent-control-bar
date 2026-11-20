import Foundation
import Darwin

// Custom model prices and "Map to" for the Usage window: the app-owned settings file
// `usage/prices.json` and the editor behind the "Custom model prices" table. The rules are
// T3 Code's (usagePriceForm.ts, usagePriceTable.ts, UsagePriceOverrides.tsx), reduced to the one
// settings file of this machine. Swift is the only writer of the file; `mcpbar.py usage` reads
// it and does all cost maths, so nothing here computes a cost.

/// The four price columns. Raw values are T3's settings keys; a Swift enum is safe here because
/// Swift alone writes these keys and Python only reads them.
enum UsagePriceField: String, CaseIterable {
    case input = "inputCostPerMillionTokens"
    case output = "outputCostPerMillionTokens"
    case cacheRead = "cacheReadCostPerMillionTokens"
    case cacheWrite = "cacheWriteCostPerMillionTokens"

    var label: String {
        switch self {
        case .input: return "Input"
        case .output: return "Output"
        case .cacheRead: return "Cache read"
        case .cacheWrite: return "Cache write"
        }
    }

    /// A blank cache rate means "use the input rate"; an explicit 0 means free.
    var isOptional: Bool { self == .cacheRead || self == .cacheWrite }
}

/// One model's custom price in USD per million tokens. It can only be built valid (input and
/// output present, every rate finite and not negative), so the file never receives a NaN.
struct UsagePrice: Equatable {
    let rates: [UsagePriceField: Double]

    init?(_ rates: [UsagePriceField: Double]) {
        guard rates[.input] != nil, rates[.output] != nil,
              rates.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        self.rates = rates
    }

    /// An entry of `usagePriceOverrides`. Like T3's schema, one bad rate rejects the whole entry
    /// and unknown keys are ignored.
    init?(json: Any?) {
        guard let object = json as? [String: Any] else { return nil }
        var rates: [UsagePriceField: Double] = [:]
        for field in UsagePriceField.allCases {
            guard let raw = object[field.rawValue] else { continue }
            // `true` bridges to NSNumber 1; it is not a price.
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            // JSONSerialization hands a long literal (0.002251941003853357) over as an
            // NSDecimalNumber, whose doubleValue can be one unit in the last place off. Its
            // decimal text read by Swift is the nearest double, the one that was written.
            rates[field] = (number as? NSDecimalNumber).flatMap { Double($0.stringValue) } ?? number.doubleValue
        }
        self.init(rates)
    }

    /// The typed cells of one row. Blank cells are left out, so a blank required one fails.
    init?(cells: [UsagePriceField: String]) {
        var rates: [UsagePriceField: Double] = [:]
        for (field, text) in cells where !text.trimmed.isEmpty {
            guard let rate = Self.number(text) else { return nil }
            rates[field] = rate
        }
        self.init(rates)
    }

    /// The rates as the table shows them; an absent cache rate has no entry.
    var cells: [UsagePriceField: String] { rates.mapValues(Self.text) }

    /// A number exactly as JavaScript's `Number.prototype.toString` prints it (`2`, `3.5`, `1e-7`,
    /// `1e+21`). T3 shows saved rates this way, and one spelling for the cell and for the file is
    /// what lets a cell nobody touched compare equal to the saved rate. Swift's own description
    /// has the same shortest round-trip digits but lays them out as `2.0` and `1e-07`.
    static func text(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : value < 0 ? "-Infinity" : "Infinity" }
        if value == 0 { return "0" }
        if value < 0 { return "-" + text(-value) }
        let parts = value.description.split(separator: "e")
        let whole = parts[0].prefix { $0 != "." }
        var digits = "\(whole)\(parts[0].dropFirst(whole.count + 1))"
        // `point` is where the decimal point sits: the value is 0.<digits> × 10^point.
        var point = whole.count + (parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        while digits.hasPrefix("0") {
            digits.removeFirst()
            point -= 1
        }
        while digits.hasSuffix("0") { digits.removeLast() }
        if digits.count <= point && point <= 21 { return digits + String(repeating: "0", count: point - digits.count) }
        if 0 < point && point <= 21 { return "\(digits.prefix(point)).\(digits.dropFirst(point))" }
        if -6 < point && point <= 0 { return "0.\(String(repeating: "0", count: -point))\(digits)" }
        let mantissa = digits.count == 1 ? digits : "\(digits.prefix(1)).\(digits.dropFirst())"
        return "\(mantissa)e\(point > 0 ? "+" : "-")\(abs(point - 1))"
    }

    /// One typed rate, or nil when it is blank or not a finite non-negative number. A comma is read
    /// as the decimal point; `1,2,3` then has two points and stays invalid.
    static func number(_ text: String) -> Double? {
        let raw = text.trimmed.replacingOccurrences(of: ",", with: ".")
        guard raw.range(of: #"\A(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:e[+-]?[0-9]+)?\z"#,
                        options: [.regularExpression, .caseInsensitive]) != nil,
              let value = Double(raw), value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// The keystroke filter of a price cell: anything that can still become a number, plus every
    /// deletion of one run of characters, even when what is left is not a number yet
    /// (`1e-7` → `e-7`). Saving validates the result. `[0-9]` and not `\d`: in NSRegularExpression
    /// `\d` also matches the digits of other scripts, in JavaScript it does not.
    static func acceptsEdit(from previous: String, to next: String) -> Bool {
        if next.range(of: #"\A\s*(?:[0-9]*[.,]?[0-9]*|(?:[0-9]+[.,]?[0-9]*|[.,][0-9]+)e[+-]?[0-9]*)\s*\z"#,
                      options: [.regularExpression, .caseInsensitive]) != nil { return true }
        let old = Array(previous.utf16), new = Array(next.utf16)
        guard new.count < old.count else { return false }
        let kept = zip(new, old).prefix { $0 == $1 }.count
        return new[kept...] == old[(old.count - (new.count - kept))...]
    }
}

/// `usage/prices.json`: `{"usagePriceOverrides": {model: price}, "usageModelAliases": {model: target}}`.
struct UsagePriceSettings: Equatable {
    var prices: [String: UsagePrice] = [:]
    /// "Map to": the key is the model folded away, the value is the model it is counted as.
    var aliases: [String: String] = [:]

    init() {}

    /// Invalid entries are dropped one by one and anything else unexpected means "no custom
    /// prices": a hand-edited file must never stop the Usage window. Model IDs are trimmed as T3's
    /// schema does; when two keys trim to the same ID, the later one in code-unit order wins.
    init(json: Any?) {
        let root = json as? [String: Any] ?? [:]
        let overrides = root["usagePriceOverrides"] as? [String: Any] ?? [:]
        for key in overrides.keys.codeUnitSorted where !key.trimmed.isEmpty {
            if let price = UsagePrice(json: overrides[key]) { prices[key.trimmed] = price }
        }
        let mappings = root["usageModelAliases"] as? [String: Any] ?? [:]
        for key in mappings.keys.codeUnitSorted where !key.trimmed.isEmpty {
            if let target = (mappings[key] as? String)?.trimmed, !target.isEmpty { aliases[key.trimmed] = target }
        }
    }

    init(data: Data?) {
        self.init(json: data.flatMap { try? JSONSerialization.jsonObject(with: $0) })
    }

    static func load(at path: String) -> UsagePriceSettings {
        UsagePriceSettings(data: FileManager.default.contents(atPath: path))
    }

    /// The file bytes: fixed key order, models in code-unit order, numbers as `UsagePrice.text`.
    /// Written by hand because JSONSerialization prints 0.1 as 0.10000000000000001 and escapes
    /// the slash of `vendor/model`, which is ugly in a file the user may open.
    func serialized() -> Data {
        let overrides = prices.keys.codeUnitSorted.map { model -> String in
            let cells = prices[model]?.cells ?? [:]
            let rates = UsagePriceField.allCases.compactMap { field in
                cells[field].map { "\"\(field.rawValue)\":\($0)" }
            }
            return "\(Self.quoted(model)):{\(rates.joined(separator: ","))}"
        }
        let mappings = aliases.keys.codeUnitSorted.map { "\(Self.quoted($0)):\(Self.quoted(aliases[$0] ?? ""))" }
        let text = "{\"usagePriceOverrides\":{\(overrides.joined(separator: ","))},"
            + "\"usageModelAliases\":{\(mappings.joined(separator: ","))}}"
        return Data(text.utf8)
    }

    private static func quoted(_ text: String) -> String {
        var json = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": json += "\\\""
            case "\\": json += "\\\\"
            case _ where scalar.value < 0x20: json += String(format: "\\u%04x", scalar.value)
            default: json.unicodeScalars.append(scalar)
            }
        }
        return json + "\""
    }

    /// Atomic and private to the user, like every state file of the app.
    func save(at path: String) throws {
        let fm = FileManager.default
        let folder = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let temporary = path + "." + UUID().uuidString + ".tmp"
        guard fm.createFile(atPath: temporary, contents: serialized(), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fm.removeItem(atPath: temporary) }
        guard rename(temporary, path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Every model with a custom price or a mapping, in JavaScript's default sort order.
    var customModels: [String] { Set(prices.keys).union(aliases.keys).codeUnitSorted }

    func isCustom(_ model: String) -> Bool { prices[model] != nil || aliases[model] != nil }

    /// Each change replaces or deletes one model's whole entry; other models stay as they are.
    func applying(_ changes: [UsagePriceChange]) -> UsagePriceSettings {
        var next = self
        for change in changes {
            switch change {
            case .price(let model, let price): next.prices[model] = price
            case .alias(let model, let target): next.aliases[model] = target
            }
        }
        return next
    }

    /// The mappings that are in effect while counting: a chain ends at the first model that is
    /// not mapped itself, and a model whose chain runs into a loop (a self-map included) is not
    /// mapped at all. Each model is walked once, so a long hand-written chain stays cheap.
    var resolvedAliases: [String: String] {
        var resolved: [String: String] = [:]
        var looping = Set<String>()
        for model in aliases.keys {
            var path: [String] = []
            var target = model
            while let next = aliases[target], resolved[target] == nil, !looping.contains(target) {
                path.append(target)
                // Marked while the walk is open, so coming back to it is seen as a loop.
                looping.insert(target)
                target = next
            }
            guard let end = aliases[target] == nil ? target : resolved[target] else { continue }
            for alias in path {
                looping.remove(alias)
                resolved[alias] = end
            }
        }
        return resolved
    }
}

/// One edit of the settings; nil removes the model's custom price or its mapping.
enum UsagePriceChange: Equatable {
    case price(String, UsagePrice?)
    case alias(String, String?)
}

/// What the user has typed into one table row and not saved yet.
struct UsagePriceDraft: Equatable {
    /// `model:<id>` for a saved model, `new:<n>` or `new:initial` for an added row.
    let id: String
    var model: String
    let isNew: Bool
    /// Only the price cells that differ from what is saved, as typed.
    var values: [UsagePriceField: String] = [:]
    /// The typed "Map to": nil keeps the saved mapping, blank removes it.
    var alias: String?
    /// A saved row marked "reset to automatic".
    var removed = false

    /// An added row nobody typed into; it is neither a change nor an error.
    var isEmpty: Bool {
        isNew && model.trimmed.isEmpty && (alias ?? "").trimmed.isEmpty && values.values.allSatisfy(\.trimmed.isEmpty)
    }
}

/// The drafts turned into changes of the file, with the reason for every row that cannot be saved.
struct UsagePricePlan: Equatable {
    private(set) var changes: [UsagePriceChange] = []
    /// Draft id → message.
    private(set) var errors: [String: String] = [:]

    init(saved: UsagePriceSettings, drafts: [UsagePriceDraft]) {
        for draft in drafts where !draft.isEmpty {
            let model = draft.model.trimmed
            let savedPrice = saved.prices[model], savedAlias = saved.aliases[model]
            if draft.removed {
                if savedPrice != nil { changes.append(.price(model, nil)) }
                if savedAlias != nil { changes.append(.alias(model, nil)) }
                continue
            }
            let alias = (draft.alias ?? savedAlias ?? "").trimmed
            if !alias.isEmpty {
                if draft.alias == nil && !draft.values.isEmpty {
                    // Reached by clearing the mapping, typing prices and typing the mapping back:
                    // the prices are hidden again, so saving must not silently drop them.
                    errors[draft.id] = "This model is mapped. Clear its mapping first."
                } else if model.isEmpty {
                    errors[draft.id] = "Enter a model ID."
                } else if alias == model {
                    errors[draft.id] = "Map to a different model."
                } else {
                    if alias != savedAlias { changes.append(.alias(model, alias)) }
                    // A mapped model is priced as its target, so its own price would be dead weight.
                    if savedPrice != nil { changes.append(.price(model, nil)) }
                }
                continue
            }
            if savedAlias != nil {
                changes.append(.alias(model, nil))
                if savedPrice == nil && draft.values.values.allSatisfy(\.trimmed.isEmpty) { continue }
            }
            let cells = (savedPrice?.cells ?? [:]).merging(draft.values) { _, typed in typed }
            if model.isEmpty {
                errors[draft.id] = "Enter a model ID."
            } else if let price = UsagePrice(cells: cells) {
                if price != savedPrice { changes.append(.price(model, price)) }
            } else if let missing = UsagePriceField.allCases.first(where: {
                !$0.isOptional && (cells[$0] ?? "").trimmed.isEmpty
            }) {
                errors[draft.id] = "\(missing.label) is required."
            } else {
                errors[draft.id] = "Use non-negative numbers for prices."
            }
        }
        // Checked on the result of the whole batch, so clearing one mapping and reversing it in
        // the same save is valid whatever the row order.
        let aliases = saved.applying(changes).aliases
        for draft in drafts where !draft.removed && errors[draft.id] == nil {
            var model = draft.model.trimmed
            var seen = Set<String>()
            while let next = aliases[model] {
                guard seen.insert(model).inserted else {
                    errors[draft.id] = "Model mappings cannot form a cycle."
                    break
                }
                model = next
            }
        }
    }
}

struct UsagePriceCell: Equatable {
    let value: String
    let placeholder: String
}

/// One table row as the window draws it.
struct UsagePriceRow: Equatable, Identifiable {
    let id: String
    let model: String
    /// The model ID is an input only in an added row.
    let isNew: Bool
    /// Marked "reset to automatic": the ID is struck through and one cell reading
    /// "Automatic pricing after saving" replaces Map to and the prices.
    let removed: Bool
    let alias: UsagePriceCell
    /// Not empty when the model is mapped: "Counted as …" replaces the four price cells.
    let countedAs: String
    let prices: [UsagePriceField: UsagePriceCell]
    /// The message under the model ID, when there is one to show.
    let error: String?
    let modelInvalid: Bool
}

/// The state of the "Custom model prices" table between opening it and Save.
struct UsagePriceEditor {
    private(set) var saved: UsagePriceSettings
    private(set) var drafts: [UsagePriceDraft] = []
    private var addedRows = 0

    /// `model` is the "Set price" entry point: a model Usage shows without a price arrives as a
    /// new row with its ID filled in, unless it already has a row.
    init(saved: UsagePriceSettings, settingPriceFor model: String? = nil) {
        self.saved = saved
        if let model, !saved.isCustom(model) {
            drafts = [UsagePriceDraft(id: "new:initial", model: model, isNew: true)]
        }
    }

    /// Saved models first, then added rows in the order they were added.
    var rows: [UsagePriceRow] {
        let (blocking, hidden) = review
        let savedRows = saved.customModels.compactMap { draft("model:" + $0) }
        return (savedRows + drafts.filter(\.isNew)).map { draft in
            row(draft, error: hidden.contains(draft.id) ? nil : blocking[draft.id])
        }
    }

    private func row(_ draft: UsagePriceDraft, error: String?) -> UsagePriceRow {
        let alias = draft.alias ?? saved.aliases[draft.model] ?? ""
        let savedCells = draft.isNew ? nil : saved.prices[draft.model]?.cells
        var prices: [UsagePriceField: UsagePriceCell] = [:]
        for field in UsagePriceField.allCases {
            let blank = field.isOptional ? "Input rate" : "0.00"
            prices[field] = UsagePriceCell(value: draft.values[field] ?? savedCells?[field] ?? "",
                                           placeholder: draft.isNew || savedCells != nil ? blank : "Automatic")
        }
        let named = !draft.model.trimmed.isEmpty
        // A message appears only once the row has a model ID or a typed price to point at.
        let shown = named || draft.values.values.contains { !$0.isEmpty }
        return UsagePriceRow(
            id: draft.id, model: draft.model, isNew: draft.isNew, removed: draft.removed,
            alias: UsagePriceCell(value: alias, placeholder: draft.isNew ? "Optional" : "None"),
            countedAs: alias.trimmed, prices: prices,
            error: shown ? error : nil, modelInvalid: named && error != nil)
    }

    var hasChanges: Bool { drafts.contains { !$0.isEmpty } }
    var canSave: Bool { hasChanges && review.blocking.isEmpty }
    var plan: UsagePricePlan { UsagePricePlan(saved: saved, drafts: drafts) }
    /// What the file holds after Save.
    var afterSave: UsagePriceSettings { saved.applying(plan.changes) }

    /// Everything that blocks Save, and the rows whose message stays hidden: a new model with
    /// nothing typed beside its ID is waiting for a price, not wrong yet.
    private var review: (blocking: [String: String], hidden: Set<String>) {
        var blocking = plan.errors
        var hidden = Set<String>()
        for draft in drafts where draft.isNew && !draft.isEmpty {
            let model = draft.model.trimmed
            if model.isEmpty {
                blocking[draft.id] = "Enter a model ID."
            } else if saved.isCustom(model)
                        || drafts.contains(where: { $0.id != draft.id && $0.model.trimmed == model }) {
                blocking[draft.id] = "This model already has a row. Edit its prices there."
            } else if (draft.alias ?? "").trimmed.isEmpty && draft.values.values.allSatisfy(\.trimmed.isEmpty) {
                hidden.insert(draft.id)
            }
        }
        return (blocking, hidden)
    }

    /// Returns the id of the added row, so the window can focus its model ID.
    mutating func addRow() -> String {
        let id = "new:\(addedRows)"
        addedRows += 1
        drafts.append(UsagePriceDraft(id: id, model: "", isNew: true))
        return id
    }

    mutating func setModel(_ text: String, row id: String) {
        guard var draft = draft(id), draft.isNew else { return }
        draft.model = text
        store(draft)
    }

    mutating func setAlias(_ text: String, row id: String) {
        guard var draft = draft(id) else { return }
        // A saved mapping typed back to what is saved is not an edit any more.
        let unchanged = !draft.isNew && text == (saved.aliases[draft.model] ?? "")
        draft.alias = unchanged ? nil : text
        store(draft)
    }

    /// False when the text is refused; the cell then keeps what it showed.
    mutating func setPrice(_ text: String, _ field: UsagePriceField, row id: String) -> Bool {
        guard var draft = draft(id) else { return false }
        let savedText = draft.isNew ? "" : saved.prices[draft.model]?.cells[field] ?? ""
        guard UsagePrice.acceptsEdit(from: draft.values[field] ?? savedText, to: text) else { return false }
        let unchanged = !draft.isNew && text == savedText
        draft.values[field] = unchanged ? nil : text
        store(draft)
        return true
    }

    /// The row's button: removes an added row; marks a saved row "reset to automatic" or undoes
    /// that, keeping whatever was typed in the row before.
    mutating func toggleRow(_ id: String) {
        guard var draft = draft(id) else { return }
        if draft.isNew {
            drafts.removeAll { $0.id == id }
        } else {
            draft.removed.toggle()
            store(draft)
        }
    }

    mutating func discard() { drafts = [] }

    /// Writes the planned file and makes it the new baseline. Does nothing while a row is
    /// invalid. Edits that change no value (the saved rate in another spelling) are cleared
    /// without touching the file, as T3 reports such a save done without writing.
    mutating func save(at path: String) throws {
        guard canSave else { return }
        let next = afterSave
        if next != saved {
            try next.save(at: path)
            saved = next
        }
        drafts = []
    }

    /// Model IDs to offer in an added row: models seen in usage that have no row yet.
    func modelSuggestions(seen: [String]) -> [String] {
        Set(seen).subtracting(saved.customModels).codeUnitSorted
    }

    /// Targets to offer in Map to: every known model that is not itself mapped away.
    func aliasSuggestions(seen: [String]) -> [String] {
        Set(seen).union(saved.customModels).filter { saved.aliases[$0] == nil }.codeUnitSorted
    }

    private func draft(_ id: String) -> UsagePriceDraft? {
        if let draft = drafts.first(where: { $0.id == id }) { return draft }
        guard id.hasPrefix("model:") else { return nil }
        let model = String(id.dropFirst("model:".count))
        return saved.isCustom(model) ? UsagePriceDraft(id: id, model: model, isNew: false) : nil
    }

    private mutating func store(_ draft: UsagePriceDraft) {
        // A saved row with nothing typed in it is clean again, not a pending change.
        let clean = !draft.isNew && draft.values.isEmpty && draft.alias == nil && !draft.removed
        if let index = drafts.firstIndex(where: { $0.id == draft.id }) {
            if clean { drafts.remove(at: index) } else { drafts[index] = draft }
        } else if !clean {
            drafts.append(draft)
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private extension Sequence where Element == String {
    /// JavaScript's default sort (UTF-16 code units). Swift's `<` orders by Unicode scalar and
    /// would put an emoji after U+FF5E, so rows and file bytes would differ from T3's.
    var codeUnitSorted: [String] { sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) } }
}
