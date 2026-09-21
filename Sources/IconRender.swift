import Cocoa

// The status item itself: title, animation timer, frame cache and the three icon styles.
extension StatusController {
    // MARK: render

    func render(label: String, color: NSColor?, animate: Bool, startedAt: Double, badge: Bool = false) {
        guard let button = statusItem.button else { return }
        button.contentTintColor = nil // we paint the icon color ourselves; template-tint is unreliable
        activeBase = label
        activeColor = color
        self.startedAt = startedAt
        if activeBadge != badge {
            activeBadge = badge
            iconCacheKey = ""
            iconCache.removeAll()
            button.image = nil
        }

        if animate {
            if animTimer == nil {
                let t = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in self?.animStep() }
                RunLoop.main.add(t, forMode: .common)
                animTimer = t
            }
        } else {
            animTimer?.invalidate(); animTimer = nil
            frameIdx = 0
            let icon = restingIcon(color: color)
            button.image = decorate(badge ? attentionBadgeIcon(icon, color: Self.amber) : icon)
        }
        applyTitle()
        // Only the animated path can arrive here imageless (the badge flip above cleared it and
        // the first animStep is a frame away); the resting path assigned its image just above.
        if animate, button.image == nil { button.image = cachedIcon(frame: frameIdx) }
    }

    func animStep() {
        frameIdx = (frameIdx + 1) % frameCount
        statusItem.button?.image = cachedIcon(frame: frameIdx)
        applyTitle() // refresh the elapsed clock
    }

    /// The animation cycles through a small fixed set of frames forever, and each one is a bitmap
    /// composite with the limit bars drawn over it. Rebuilding the same handful of images twenty
    /// times a second was a large part of what the app did while Claude worked.
    ///
    /// Everything that can change what a frame looks like is in the key — the appearance included,
    /// because a cached image must not outlive a switch between a light and a dark menu bar.
    func cachedIcon(frame: Int) -> NSImage? {
        let key = [drawnIcon.raw,
                   drawnIcon.variant(mood: crabMood),
                   activeBadge ? "badge" : "",
                   activeColor.map { "\($0)" } ?? "template",
                   currentGauge().signature,
                   NSApp.effectiveAppearance.name.rawValue].joined(separator: "|")
        if key != iconCacheKey {
            iconCacheKey = key
            iconCache.removeAll()
        }
        if let hit = iconCache[frame] { return hit }
        let icon = iconImage(color: activeColor, frame: frame)
        let made = decorate(activeBadge ? attentionBadgeIcon(icon, color: Self.amber) : icon)
        iconCache[frame] = made
        return made
    }

    func applyTitle() {
        guard let button = statusItem.button else { return }
        // Joined rather than concatenated: with the word switched off the old form left the
        // separator behind, so the bar read "  4m 12s" with a hole where the word had been.
        var parts: [String] = []
        if !activeBase.isEmpty { parts.append(activeBase) }
        if showTimer, startedAt > 0 {
            parts.append(elapsed(max(0, (Date().timeIntervalSince1970 - startedAt).clampedInt)))
        }
        let text = parts.joined(separator: "  ")
        // Assigning a title re-lays-out and redraws the whole status item. This is called on
        // every animation frame — twenty times a second — and the text it would write is the
        // same one nineteen times out of twenty, since the clock only moves once a second.
        guard text != renderedTitle else { return }
        renderedTitle = text
        if text.isEmpty {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        button.imagePosition = .imageLeading
        // labelColor adapts: white on a dark menu bar, black on a light one. Monospaced
        // digits keep the elapsed clock from nudging neighboring menu bar icons.
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular),
        ]
        button.attributedTitle = NSAttributedString(string: " \(text)", attributes: attrs)
    }

    // MARK: icon

    static func loadFrames() -> [NSImage] { decodePNGs(claudeSparkFramePNGs) }
    static func decodePNGs(_ list: [String]) -> [NSImage] {
        list.compactMap { Data(base64Encoded: $0).flatMap(NSImage.init(data:)) }
    }

    func iconImage(color: NSColor?, frame: Int) -> NSImage {
        if let pet = petIcon(frame: frame) { return pet }
        if drawnIcon == .web { return tint(frames, color: color, frame: frame) }
        if drawnIcon == .crab { return crabIcon(color: color, frame: frame) }
        let i = (frame / codeSub) % codeGlyphs.count
        let local = (CGFloat(frame % codeSub) + 0.5) / CGFloat(codeSub) // 0…1 within this glyph
        // Scale envelope per glyph: rise, hold at peak, fall, so each lands before the swap.
        let env: CGFloat
        if local < 0.30 { let u = local / 0.30; env = u * u * (3 - 2 * u) }
        else if local > 0.70 { let u = (1 - local) / 0.30; env = u * u * (3 - 2 * u) }
        else { env = 1 }
        let scale = codeDip + (codePeaks[i] - codeDip) * env
        return codeIcon(color: color, glyph: i, scale: scale)
    }

    // nil color => adaptive template image (system draws it black/white per the menu bar).
    func codeIcon(color: NSColor?, glyph: Int, scale: CGFloat) -> NSImage {
        let s: CGFloat = 18
        guard glyph < codeGlyphMasks.count else { return NSImage(size: NSSize(width: s, height: s)) }
        let mask = codeGlyphMasks[glyph]
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let dw = s * scale
            let r = NSRect(x: (s - dw) / 2, y: (s - dw) / 2, width: dw, height: dw)
            if let c = color {
                c.setFill(); r.fill()
                mask.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1.0)
            } else {
                mask.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // Rasterize a single glyph into a centered 60x60 alpha mask filling ~92%.
    static func glyphMask(_ g: String) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 180), .foregroundColor: NSColor.black,
        ]
        let str = NSAttributedString(string: g, attributes: attrs)
        let sz = str.size()
        let big = NSImage(size: sz, flipped: false) { _ in str.draw(at: .zero); return true }
        guard let rep = big.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else {
            return NSImage(size: NSSize(width: 60, height: 60))
        }
        let w = rep.pixelsWide, h = rep.pixelsHigh, data = rep.bitmapData!
        var minx = w, miny = h, maxx = -1, maxy = -1
        for y in 0..<h { for x in 0..<w where data[(y*w+x)*4+3] > 20 {
            minx = min(minx, x); maxx = max(maxx, x); miny = min(miny, y); maxy = max(maxy, y)
        }}
        guard maxx >= 0 else { return NSImage(size: NSSize(width: 60, height: 60)) }
        let bw = CGFloat(maxx - minx + 1), bh = CGFloat(maxy - miny + 1)
        let out: CGFloat = 60, fill = out * 0.92
        let scale = fill / max(bw, bh)
        let dw = bw * scale, dh = bh * scale
        // NSBitmapImageRep origin is top-left; convert the bbox to bottom-left for drawing.
        let srcRect = NSRect(x: CGFloat(minx), y: CGFloat(h - maxy - 1), width: bw, height: bh)
        return NSImage(size: NSSize(width: out, height: out), flipped: false) { _ in
            big.draw(in: NSRect(x: (out - dw)/2, y: (out - dh)/2, width: dw, height: dh),
                     from: srcRect, operation: .sourceOver, fraction: 1.0)
            return true
        }
    }

    func restingIcon(color: NSColor?) -> NSImage {
        if let pet = petIcon(frame: 0) { return pet }
        if drawnIcon == .crab { return crabIcon(color: color, frame: 0) }
        return tint(logoSet.isEmpty ? frames : logoSet, color: color, frame: 0)
    }

    /// The menu bar pet's picture for this step, or nil when the bar is not drawing one.
    ///
    /// No colour argument: the two drawn styles are a single shape that the System setting turns
    /// black or white with the menu bar, and a pet is a painted sprite with nothing left of itself
    /// once it is flattened into one colour. So a pet is always itself, and the Color setting says
    /// as much rather than silently doing nothing.
    func petIcon(frame: Int) -> NSImage? {
        guard let ticks = petIconTicks, !ticks.isEmpty else { return nil }
        return ticks[frame % ticks.count]
    }

    // nil color (System) => adaptive shaded template (see adaptiveCrabFrame in CrabRender.swift);
    // non-nil (Orange) => the original full-color sprite, drawn as-is.
    /// `mood` is the one showing now unless the caller names another, which the Settings picker
    /// does: there the crab walks whatever the machine happens to be doing.
    func crabIcon(color: NSColor?, frame: Int, mood asked: CrabMood? = nil) -> NSImage {
        let mood = asked ?? crabMood
        let fullColor = crabFrameSet.frames(for: mood)
        let pool = color == nil ? (crabTemplateFrames[mood] ?? fullColor) : fullColor
        guard !pool.isEmpty else { return NSImage(size: NSSize(width: 18, height: 18)) }
        let src = pool[frame % pool.count]
        let rep = src.representations.first
        let pw = CGFloat(rep?.pixelsWide ?? Int(src.size.width))
        let ph = CGFloat(rep?.pixelsHigh ?? Int(src.size.height))
        let h: CGFloat = 18, w = (ph > 0 ? h * (pw / ph) : h)
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // Paint `color` through a frame mask's alpha (destinationIn) so frames recolor.
    func tint(_ set: [NSImage], color: NSColor?, frame: Int) -> NSImage {
        let s: CGFloat = 18
        guard !set.isEmpty else { return NSImage(size: NSSize(width: s, height: s)) }
        let mask = set[frame % set.count]
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            if let c = color {
                c.setFill()
                rect.fill()
                mask.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            } else {
                mask.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        img.isTemplate = (color == nil) // nil => adaptive black/white in the menu bar
        return img
    }
}
