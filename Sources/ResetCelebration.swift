import Cocoa
import SwiftUI

/// A passive window: an announcement never takes the keyboard or opens the main panel.
final class ResetCelebrationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ResetCelebrationPresenter {
    private var window: ResetCelebrationPanel?
    private var dismissal: DispatchWorkItem?
    private var providers = Set<String>()
    private var isPreview = false

    func show(providers incoming: [String], anchor: NSStatusBarButton?, preview: Bool = false) {
        let known = Set(incoming).intersection(Provider.all.map(\.id))
        guard !known.isEmpty else { return }
        let merged = window?.isVisible == true && isPreview == preview ? providers.union(known) : known
        close()
        providers = merged
        isPreview = preview
        let labels = Provider.all.filter { merged.contains($0.id) }.map { ($0.title, $0.glyph) }
        let size = NSSize(width: PanelTheme.width, height: 112)
        let panel = ResetCelebrationPanel(contentRect: NSRect(origin: .zero, size: size),
                                         styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        panel.title = preview ? "Reset reported Preview" : "Reset reported"
        panel.contentView = NSHostingView(rootView: ResetCelebrationCard(providers: labels, preview: preview))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.animationBehavior = .none
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        if let anchor { panel.appearance = anchor.effectiveAppearance }
        let visible = (anchor?.window?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let anchorFrame = anchor.flatMap { button in
            button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        }
        let frame = anchorFrame.flatMap { visible.intersects($0) ? $0 : nil }
        let x = min(max((frame?.maxX ?? visible.maxX - 8) - size.width, visible.minX + 8),
                    max(visible.minX + 8, visible.maxX - size.width - 8))
        let y = min(max((frame?.minY ?? visible.maxY) - size.height - 4, visible.minY + 8),
                    max(visible.minY + 8, visible.maxY - size.height - 4))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        window = panel
        panel.orderFrontRegardless()
        if Motion.enabled, let layer = panel.contentView?.layer {
            Motion.appear(layer, from: CGPoint(x: 0, y: 5), seconds: 0.2)
        }
        let dismiss = DispatchWorkItem { [weak self, weak panel] in
            guard let self, self.window === panel else { return }
            self.close()
        }
        dismissal = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: dismiss)
    }

    func close() {
        dismissal?.cancel()
        dismissal = nil
        window?.contentView?.layer?.removeAllAnimations()
        window?.orderOut(nil)
        window?.close()
        window = nil
        providers.removeAll()
    }

    deinit { dismissal?.cancel(); window?.orderOut(nil) }
}

/// Only presentation values enter SwiftUI; no cache, detector or account files are read here.
private struct ResetCelebrationCard: View {
    let providers: [(String, String)]
    let preview: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(nsColor: .systemGreen))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color(nsColor: .systemGreen).opacity(0.12)))
            VStack(alignment: .leading, spacing: 5) {
                Text(preview ? "Preview · Reset reported" : "Reset reported")
                    .font(.system(size: 12.5, weight: .semibold))
                HStack(spacing: 8) {
                    ForEach(providers.indices, id: \.self) { index in
                        Label(providers[index].0, systemImage: providers[index].1)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                Text("Public announcement · whenreset.app")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Text("Account eligibility may vary")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(width: PanelTheme.width, height: 112, alignment: .leading)
        .background(PanelMaterial())
        .overlay(ResetConfetti().allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: PanelTheme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PanelTheme.corner, style: .continuous)
            .strokeBorder(PanelTheme.cardBorder(scheme), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

private struct ResetConfetti: NSViewRepresentable {
    func makeNSView(context: Context) -> ResetConfettiView { ResetConfettiView() }
    func updateNSView(_ view: ResetConfettiView, context: Context) {}
}

/// Committed once to Core Animation. The render server supplies every intermediate frame.
private final class ResetConfettiView: NSView {
    private var played = false
    override func layout() {
        super.layout()
        guard !played, bounds.width > 0, bounds.height > 0 else { return }
        played = true
        guard Motion.moves else { return }
        wantsLayer = true
        guard let layer else { return }
        let colors: [NSColor] = [.systemGreen, .systemTeal, .systemOrange, .systemPink, .systemIndigo]
        for index in 0..<24 {
            let piece = CALayer()
            piece.bounds = CGRect(x: 0, y: 0, width: index % 3 == 0 ? 4 : 3, height: 6)
            piece.cornerRadius = 1
            piece.backgroundColor = colors[index % colors.count].withAlphaComponent(0.8).cgColor
            piece.opacity = 0
            layer.addSublayer(piece)
            let left = index.isMultiple(of: 2)
            let start = CGPoint(x: left ? 15 : bounds.width - 15, y: bounds.height - 9)
            let travel = CGFloat(28 + (index * 29) % 130)
            let endX = start.x + (left ? travel : -travel)
            let path = CAKeyframeAnimation(keyPath: "position")
            path.values = [NSValue(point: start),
                           NSValue(point: CGPoint(x: endX, y: bounds.height + CGFloat(index % 4) * 7)),
                           NSValue(point: CGPoint(x: endX + (left ? 14 : -14), y: -10))]
            path.keyTimes = [0, 0.25, 1]
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = Double(index)
            spin.toValue = Double(index) + (left ? 5 : -5)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.85, 0.7, 0]
            fade.keyTimes = [0, 0.08, 0.65, 1]
            let animation = CAAnimationGroup()
            animation.animations = [path, spin, fade]
            animation.duration = Motion.time(1.7)
            animation.beginTime = CACurrentMediaTime() + Double(index % 6) * Motion.time(0.025)
            piece.add(animation, forKey: "celebrate")
        }
    }
}
