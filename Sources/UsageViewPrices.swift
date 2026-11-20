import SwiftUI

// The "Custom model prices" editor: T3 Code's dialog of the same name (UsagePriceOverrides.tsx)
// for the one settings file of this Mac, so without its "Apply to" menu and its per-environment
// results. The root view puts it on the dialog surface, 896pt wide at most, with the ✕.
//
// Every rule is UsagePriceEditor's (Sources/Model/UsagePricesModel.swift): which rows there are,
// what a cell shows, which keystrokes a price cell takes, what blocks Save. This file draws its
// rows and hands it what was typed; it decides nothing about a price.

struct UsagePricesEditor: View {
    @ObservedObject private var store: UsageStore
    /// What is typed and not saved yet. It lives exactly as long as the dialog is open, so every
    /// opening starts from the saved file, as in T3. Not the State attribute: see Motion.swift.
    private let editor: State<UsagePriceEditor>
    private let outcome = State(initialValue: UsagePricesOutcome.none)
    /// The cell that takes the keyboard as it appears: the model ID of a row just added, or the
    /// input price of the row "Set price" arrived with. Any edit forgets it, so a cell that comes
    /// back later — the prices of a row whose mapping was cleared — does not pull the caret away.
    private let wanted: State<UsagePricesSlot?>

    /// `model` is the one "Set price" was pressed for, or nil.
    init(store: UsageStore, model: String?) {
        _store = ObservedObject(wrappedValue: store)
        let start = UsagePriceEditor(saved: store.snapshot.prices, settingPriceFor: model)
        editor = State(initialValue: start)
        // The only added row there can be this early is the one "Set price" asked for.
        let prefilled = start.rows.first(where: \.isNew)
        wanted = State(initialValue: prefilled.map { UsagePricesSlot(row: $0.id, column: .price(.input)) })
    }

    private static let explanation: String = "Prices and mappings apply to all past and future usage on this Mac."
    private static let help: String = "Blank cache rates use the input price. Enter 0 for free tokens. "
        + "A mapped model\u{2019}s usage counts as the model it maps to."
    private static let empty: String = "No custom prices or mappings. Add a row to set one."
    private static let failed: String = "Not saved \u{B7} Could not save. Try again."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            // The one part that gives way when the window is short; the title and the buttons stay.
            UsagePricesFit { ScrollView(.vertical) { panel } }
            footer
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom model prices")
                .font(UsageTheme.font(20, .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(Self.explanation)
                .font(UsageTheme.font(14))
                .foregroundStyle(UsageTheme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        // 48 on the right keeps the title clear of the surface's ✕.
        .padding(EdgeInsets(top: 24, leading: 24, bottom: 12, trailing: 48))
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("USD / million tokens")
                .foregroundStyle(UsageTheme.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .trailing)
            table
            Text(Self.help)
                .foregroundStyle(UsageTheme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(UsageTheme.font(12))
        .padding(.horizontal, 24)
        .padding(.vertical, 4)
    }

    private var table: some View {
        let rows = editor.wrappedValue.rows
        let seen = store.seenModels
        let models = editor.wrappedValue.modelSuggestions(seen: seen)
        let targets = editor.wrappedValue.aliasSuggestions(seen: seen)
        let shape = RoundedRectangle(cornerRadius: UsageTheme.Radius.lg, style: .continuous)
        return VStack(spacing: 0) {
            headings
            if rows.isEmpty {
                Text(Self.empty)
                    .foregroundStyle(UsageTheme.mutedForeground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .overlay(alignment: .top) { rule }
            }
            ForEach(rows) { row in
                line(row, models: models, targets: targets).overlay(alignment: .top) { rule }
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(UsageTheme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Custom model prices")
    }

    private var rule: some View { Rectangle().fill(UsageTheme.border).frame(height: 1) }

    private var headings: some View {
        UsagePricesColumns(minHeight: 40) {
            Text("Model ID")
            Text("Map to")
            ForEach(UsagePriceField.allCases, id: \.self) { Text($0.label) }
            UsageIconButton(symbol: "plus", label: "Add model price", symbolSize: 12, side: 24, action: addRow)
        }
        .font(UsageTheme.font(12, .medium))
        .lineLimit(1)
    }

    private func line(_ row: UsagePriceRow, models: [String], targets: [String]) -> some View {
        UsageHover { hovered in
            UsagePricesColumns {
                modelCell(row, suggestions: models)
                if row.removed {
                    Text("Automatic pricing after saving")
                        .foregroundStyle(UsageTheme.mutedForeground)
                        .layoutValue(key: UsagePricesSpan.self, value: 5)
                } else {
                    aliasCell(row, suggestions: targets)
                    if row.countedAs.isEmpty {
                        ForEach(UsagePriceField.allCases, id: \.self) { priceCell(row, $0) }
                    } else {
                        Text("Counted as \(row.countedAs)")
                            .foregroundStyle(UsageTheme.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutValue(key: UsagePricesSpan.self, value: 4)
                    }
                }
                rowButton(row)
            }
            .background(UsageTheme.muted.opacity(hovered ? 0.5 : 0))
        }
    }

    /// The ID is typed only in an added row; a saved model is renamed by adding another.
    private func modelCell(_ row: UsagePriceRow, suggestions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if row.isNew {
                input(row, .model, UsagePriceCell(value: row.model, placeholder: "Model ID"), label: "New model ID",
                      invalid: row.modelInvalid, suggestions: suggestions) { text in
                    change { $0.setModel(text, row: row.id) }
                    return true
                }
            } else {
                Text(row.model)
                    .strikethrough(row.removed)
                    .foregroundStyle(row.removed ? UsageTheme.mutedForeground : UsageTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = row.error {
                Text(error)
                    .foregroundStyle(UsageTheme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func aliasCell(_ row: UsagePriceRow, suggestions: [String]) -> some View {
        input(row, .alias, row.alias, label: "Map \(Self.name(row)) to model", suggestions: suggestions) { text in
            change { $0.setAlias(text, row: row.id) }
            return true
        }
    }

    private func priceCell(_ row: UsagePriceRow, _ field: UsagePriceField) -> some View {
        let cell = row.prices[field] ?? UsagePriceCell(value: "", placeholder: "")
        return input(row, .price(field), cell, label: "\(field.label) price for \(Self.name(row))", mono: true) { text in
            change { $0.setPrice(text, field, row: row.id) }
        }
    }

    private func input(_ row: UsagePriceRow, _ column: UsagePricesSlot.Column, _ cell: UsagePriceCell, label: String,
                       mono: Bool = false, invalid: Bool = false, suggestions: [String] = [],
                       edit: @escaping (String) -> Bool) -> some View {
        let slot = UsagePricesSlot(row: row.id, column: column)
        return UsagePricesInput(cell: cell, label: label, mono: mono, invalid: invalid, suggestions: suggestions,
                                autofocus: wanted.wrappedValue == slot, edit: edit, submit: save)
    }

    private func rowButton(_ row: UsagePriceRow) -> some View {
        let label = row.removed ? "Undo reset" : row.isNew ? "Remove row" : "Reset to automatic"
        return UsageIconButton(symbol: row.isNew ? "xmark" : "arrow.counterclockwise", label: label,
                               symbolSize: 12, side: 24) { change { $0.toggleRow(row.id) } }
    }

    private static func name(_ row: UsagePriceRow) -> String { row.model.isEmpty ? "new model" : row.model }

    private var footer: some View {
        HStack(spacing: 8) {
            status
            Spacer(minLength: 0)
            if editor.wrappedValue.hasChanges {
                Button("Discard changes") { change { $0.discard() } }
                    .buttonStyle(UsageButtonStyle(variant: .ghost))
            }
            Button("Save changes", action: save)
                .buttonStyle(UsageButtonStyle(variant: .primary))
                .disabled(!editor.wrappedValue.canSave)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    /// How the last Save ended, until the next edit. There is no "Saving…" in between: the file
    /// is written before the press returns.
    @ViewBuilder
    private var status: some View {
        switch outcome.wrappedValue {
        case .none: EmptyView()
        case .saved: Text("Saved").font(UsageTheme.font(12)).foregroundStyle(UsageTheme.mutedForeground)
        case .failed: Text(Self.failed).font(UsageTheme.font(12)).foregroundStyle(UsageTheme.destructive)
        }
    }

    // MARK: actions

    /// Every edit goes through here, because each of them also takes the last save's line away
    /// and ends the wait of the cell that was to take the keyboard.
    @discardableResult
    private func change<Result>(_ edit: (inout UsagePriceEditor) -> Result) -> Result {
        let result = edit(&editor.wrappedValue)
        outcome.wrappedValue = .none
        wanted.wrappedValue = nil
        return result
    }

    private func addRow() {
        let id = change { $0.addRow() }
        wanted.wrappedValue = UsagePricesSlot(row: id, column: .model)
    }

    /// Also what Return does in any cell, so it checks for itself that there is something valid
    /// to save. A failed write keeps every typed row for the next press.
    private func save() {
        guard editor.wrappedValue.canSave else { return }
        outcome.wrappedValue = store.savePrices(&editor.wrappedValue) ? .saved : .failed
    }
}

private enum UsagePricesOutcome { case none, saved, failed }

/// One input of the table.
private struct UsagePricesSlot: Hashable {
    enum Column: Hashable {
        case model, alias
        case price(UsagePriceField)
    }

    let row: String
    let column: Column
}

/// T3's compact input: 28pt tall, 12pt text, a hairline that turns into the focus ring.
private struct UsagePricesInput: View {
    let cell: UsagePriceCell
    let label: String
    let mono: Bool
    let invalid: Bool
    /// Offered in a menu at the field's end, the way T3's datalist is.
    let suggestions: [String]
    /// Gets every keystroke; false when it is refused, and the field then keeps what it showed.
    let edit: (String) -> Bool
    let submit: () -> Void
    private let focused = State(initialValue: false)
    /// How many times the field was asked to take the keyboard: once as it appears when it is
    /// the cell the editor wants, and once per click on the box around the text.
    private let grabs: State<Int>

    init(cell: UsagePriceCell, label: String, mono: Bool, invalid: Bool, suggestions: [String], autofocus: Bool,
         edit: @escaping (String) -> Bool, submit: @escaping () -> Void) {
        self.cell = cell
        self.label = label
        self.mono = mono
        self.invalid = invalid
        self.suggestions = suggestions
        self.edit = edit
        self.submit = submit
        grabs = State(initialValue: autofocus ? 1 : 0)
    }

    var body: some View {
        let isFocused = focused.wrappedValue
        let tint: Color = invalid ? UsageTheme.destructive : UsageTheme.primary
        let edge: Color = isFocused ? tint.opacity(invalid ? 0.64 : 1) : invalid ? tint.opacity(0.36) : UsageTheme.input
        let ring: Color = tint.opacity(invalid ? 0.16 : 0.24)
        let ringWidth: CGFloat = isFocused ? 3 : 0
        let shape = RoundedRectangle(cornerRadius: UsageTheme.Radius.md, style: .continuous)
        return HStack(spacing: 4) {
            UsagePricesNativeField(cell: cell, label: label, mono: mono, grabs: grabs.wrappedValue, edit: edit,
                             submit: submit) { focused.wrappedValue = $0 }
                // The text line is 16 of the box's 28 points and, beside the menu, no wider than
                // its text; a click anywhere on the box short of the menu is a click on the field.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { grabs.wrappedValue += 1 }
            if !suggestions.isEmpty { menu }
        }
        // 7 and the field's own 2 make T3's 9 to the first character.
        .padding(.horizontal, 7)
        .frame(height: 28)
        .background(shape.fill(UsageTheme.muted))
        .overlay(shape.strokeBorder(edge, lineWidth: 1))
        .overlay(shape.inset(by: 1).strokeBorder(ring, lineWidth: ringWidth))
    }

    private var menu: some View {
        Menu {
            ForEach(suggestions, id: \.self) { model in Button(model) { _ = edit(model) } }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(UsageTheme.mutedForeground)
                .frame(width: 12, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // Part of the field, as a combo box's arrow is: with the system's keyboard navigation on,
        // Tab would otherwise stop here between Model ID, Map to and Input.
        .focusable(false)
        .help("Suggested models")
        .accessibilityLabel("Suggested models")
    }
}

/// The text field itself, AppKit's own: SwiftUI's TextField goes on showing a keystroke its
/// binding refused until the field loses the keyboard, and a price cell must not show one at all.
private struct UsagePricesNativeField: NSViewRepresentable {
    let cell: UsagePriceCell
    let label: String
    let mono: Bool
    let grabs: Int
    let edit: (String) -> Bool
    let submit: () -> Void
    let focused: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = UsagePricesTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.font = mono ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        field.textColor = NSColor(UsageTheme.foreground)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.shown = cell.value
        if field.stringValue != cell.value { field.stringValue = cell.value }
        if field.placeholderAttributedString?.string != cell.placeholder {
            // The system's placeholder colour is not T3's, hence the attributed one.
            let look: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor(UsageTheme.mutedForeground),
                                                       .font: field.font ?? .systemFont(ofSize: 12)]
            field.placeholderAttributedString = NSAttributedString(string: cell.placeholder, attributes: look)
        }
        field.setAccessibilityLabel(label)
        if grabs != coordinator.grabs {
            coordinator.grabs = grabs
            // After this update: the field of a row just added is not in the window yet, and
            // taking the keyboard reports the focus back into a view that is being updated.
            // Not while it is being typed in: asking again would end the editing and select all.
            DispatchQueue.main.async {
                if field.currentEditor() == nil { field.window?.makeFirstResponder(field) }
            }
        }
    }

    /// As wide as the cell and one line tall; left to itself the field is as wide as its text.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let line = nsView.intrinsicContentSize
        return CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? line.width, height: line.height)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: UsagePricesNativeField
        /// What the cell held before the keystroke being handled.
        var shown = ""
        var grabs = 0

        init(_ parent: UsagePricesNativeField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let typed = field.stringValue
            if parent.edit(typed) {
                shown = typed
                return
            }
            // Refused: the text goes back, and the caret to where the keystroke found it.
            let caret = field.currentEditor()?.selectedRange.location ?? 0
            let grown = max(0, typed.utf16.count - shown.utf16.count)
            field.stringValue = shown
            field.currentEditor()?.selectedRange = NSRange(location: min(shown.utf16.count, max(0, caret - grown)),
                                                           length: 0)
        }

        func controlTextDidEndEditing(_ notification: Notification) { parent.focused(false) }

        /// Return saves and the caret stays where it is; left to the field, Return would end
        /// the editing and select the cell's text.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.submit()
            return true
        }
    }
}

/// Tells the input when it takes the keyboard; nothing else in AppKit announces that moment
/// before the first keystroke.
private final class UsagePricesTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            (delegate as? UsagePricesNativeField.Coordinator)?.parent.focused(true)
            // In a short window the table scrolls, and neither Tab nor a row just added brings
            // its cell into view. 14 more each way is the cell's box and its padding in the row.
            scrollToVisible(bounds.insetBy(dx: 0, dy: -14))
        }
        return became
    }
}

/// How many of the table's seven columns a cell covers.
private struct UsagePricesSpan: LayoutValueKey {
    static let defaultValue = 1
}

/// One row of T3's fixed table: Model ID 22%, Map to 18%, four equal price columns, 40pt for the
/// row's button. A cell is 8pt in from its column on every side and centred in the row's height.
private struct UsagePricesColumns: Layout {
    var minHeight: CGFloat = 0

    private static let inset: CGFloat = 8
    /// The table's width in T3 when nothing proposes one.
    private static let width: CGFloat = 720

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? Self.width
        var height: CGFloat = 0
        for (subview, cell) in zip(subviews, cells(width: width, subviews: subviews)) {
            height = max(height, subview.sizeThatFits(ProposedViewSize(width: cell.width, height: nil)).height)
        }
        return CGSize(width: width, height: max(minHeight, height + 2 * Self.inset))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, cell) in zip(subviews, cells(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + cell.x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: cell.width, height: nil))
        }
    }

    /// Where each cell's content starts and how wide it may be.
    private func cells(width: CGFloat, subviews: Subviews) -> [(x: CGFloat, width: CGFloat)] {
        let model = width * 0.22, alias = width * 0.18, button: CGFloat = 40
        let price = max(0, width - model - alias - button) / 4
        let columns = [model, alias, price, price, price, price, button]
        var cells: [(x: CGFloat, width: CGFloat)] = []
        var column = 0
        var x: CGFloat = 0
        for subview in subviews {
            let end = min(columns.count, column + max(1, subview[UsagePricesSpan.self]))
            let covered = columns[min(column, end)..<end].reduce(0, +)
            cells.append((x + Self.inset, max(0, covered - 2 * Self.inset)))
            x += covered
            column = end
        }
        return cells
    }
}

/// As tall as the scroll view's content while the window has room for it, and what is left when
/// it has not — only then does the content scroll. A bare ScrollView takes every point it is
/// offered, which would stretch the dialog over the whole window for a table of two rows.
private struct UsagePricesFit: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, proposal.height ?? ideal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
