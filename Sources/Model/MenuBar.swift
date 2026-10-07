import Cocoa

/// The two independent blocks the one status item shows, using the board after its single tick.
struct MenuBarAgent {
    let provider: Provider
    let lead: Session?
    let mood: CrabMood
    let working: Int
    let gauge: Gauge
    var reserve = false

    var startedAt: Double { lead.map { isWorkingState($0.eff) ? $0.startedAt : 0 } ?? 0 }
    var badge: Bool { lead?.eff == "permission" }

    func animates(_ icon: MenuBarIcon?) -> Bool {
        icon?.restsInMotion == true || (icon != nil && mood != .sleeping)
    }

    func markerColor(fallback: Bool, permissionColor: NSColor) -> NSColor? {
        if badge { return permissionColor }
        return fallback && isWorkingState(lead?.eff ?? "") ? .labelColor : nil
    }

    func markedIcon(_ icon: NSImage, fallback: Bool, permissionColor: NSColor) -> NSImage {
        guard let color = markerColor(fallback: fallback, permissionColor: permissionColor) else { return icon }
        return attentionBadgeIcon(icon, color: color)
    }

    static func shown(_ display: AgentDisplay, board: SessionBoard,
                      claude: LimitsSet?, codex: LimitsSet?, now: Double) -> [MenuBarAgent] {
        Provider.all.filter { display.inBar($0.id) }.map { provider in
            let own = board.sessions.values.filter { $0.provider == provider.id }
            let lead = board.lead(for: [provider.id])
            let limits = LimitsBoard(claude: provider == .claude ? claude : nil,
                                     codex: provider == .codex ? codex : nil)
            return MenuBarAgent(provider: provider, lead: lead,
                mood: CrabMood.display(forEffectiveStates: own.map(\.eff), leadState: lead?.eff),
                working: own.filter { isWorkingState($0.eff) }.count,
                gauge: limits.gauge(at: now),
                reserve: provider == .codex && limits.codexBarWindows(at: now).first?.title == "Reserve")
        }
    }

    func timer(show: Bool, now: Double) -> String {
        guard show, startedAt > 0 else { return "" }
        let seconds = max(0, (now - startedAt).clampedInt)
        if seconds >= 99 * 3600 { return "99h+" }
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds / 60) % 60)m" }
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}

/// Each provider's origin survives the other provider's mood, icon and tempo changes.
struct MenuBarMotion {
    private var key = ""
    private var origin: Double = 0
    private var fps: Double = 1

    mutating func update(key next: String, fps rate: Double, now: Double) {
        if key != next { origin = now }
        else if fps != rate { origin = now - max(0, now - origin) * fps / rate }
        key = next
        fps = rate
    }

    func frame(at now: Double, count: Int) -> Int {
        max(0, ((now - origin) * fps).rounded(.down).clampedInt) % max(1, count)
    }
}

/// Composes actual provider icons and gauges. A bounded text column keeps long tool labels and
/// clocks from moving the neighbouring provider or overflowing the menu bar.
struct MenuBarImage {
    struct Block {
        let image: NSImage
        let label: String
        let timer: String
    }

    static func compose(_ blocks: [Block]) -> NSImage {
        let gap: CGFloat = 10, textGap: CGFloat = 4, textWidth: CGFloat = 84
        let height = NSStatusBar.system.thickness
        let widths = blocks.map { $0.image.size.width + ($0.label.isEmpty && $0.timer.isEmpty ? 0 : textGap + textWidth) }
        let width = widths.reduce(0, +) + CGFloat(max(0, blocks.count - 1)) * gap
        let template = blocks.allSatisfy { $0.image.isTemplate }
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (i, block) in blocks.enumerated() {
                let box = NSRect(x: x, y: ((height - block.image.size.height) / 2).rounded(),
                                 width: block.image.size.width, height: block.image.size.height)
                if block.image.isTemplate && !template {
                    NSColor.labelColor.setFill(); box.fill()
                    block.image.draw(in: box, from: .zero, operation: .destinationIn, fraction: 1)
                } else {
                    block.image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
                }
                let lines = [block.label, block.timer].filter { !$0.isEmpty }
                if !lines.isEmpty {
                    let stacked = lines.count == 2
                    let font = NSFont.monospacedDigitSystemFont(ofSize: stacked ? 9 : 11, weight: .regular)
                    let lineHeight: CGFloat = stacked ? 11 : 14
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.lineBreakMode = .byTruncatingTail
                    for (row, line) in lines.enumerated() {
                        let y = stacked ? (height / 2 + (row == 0 ? 0 : -11)) : ((height - lineHeight) / 2).rounded()
                        NSAttributedString(string: line, attributes: [
                            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
                        ]).draw(in: NSRect(x: x + block.image.size.width + textGap, y: y,
                                          width: textWidth, height: lineHeight))
                    }
                }
                x += widths[i] + gap
            }
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = blocks.map {
            [$0.image.accessibilityDescription ?? "", $0.label, $0.timer].filter { !$0.isEmpty }.joined(separator: ", ")
        }.joined(separator: "; ")
        return image
    }
}
