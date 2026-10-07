import Cocoa

// The status item itself: title, animation timer, frame cache and the three icon styles.
extension StatusController {
    // MARK: render

    func renderMenuBar(now: Double) {
        var agents = MenuBarAgent.shown(agentDisplay, board: board, claude: limits?.set,
                                       codex: codexWindows, now: now)
        if agents.isEmpty {
            agents = [MenuBarAgent(provider: .claude, lead: nil, mood: .sleeping, working: 0, gauge: Gauge())]
        }
        barOrder = agents.map(\.provider.id)
        for agent in agents {
            let provider = agent.provider.id
            var render = barRenders[provider] ?? BarRender(agent: agent)
            render.agent = agent
            var chosen: MenuBarIcon? = provider == "claude" ? animStyle : .pet(codexPetID)
            var ticks: [NSImage]?
            if case .pet(let id) = chosen, let pet = petIconFrames(id: id, provider: provider) {
                let frames = pet.frames(for: agent.mood.petRow)
                if !frames.isEmpty { ticks = frames }
            }
            if chosen?.isPet == true && ticks == nil { chosen = provider == "claude" ? .crab : nil }
            render.icon = chosen
            render.ticks = ticks
            render.color = chosen == .crab && agent.mood.keepsColorInSystem ? brand : iconColor
            render.animate = agent.animates(chosen)
            switch chosen {
            case .web: render.fps = spriteFPS; render.frameCount = max(1, frames.count)
            case .code: render.fps = Double(codeGlyphs.count * codeSub) / codeCycle; render.frameCount = codeGlyphs.count * codeSub
            case .crab: render.fps = agent.mood.framesPerSecond(working: agent.working)
                render.frameCount = max(1, crabFrameSet.frames(for: agent.mood).count)
            case .pet: render.fps = PetIconFrames.fps; render.frameCount = max(1, ticks?.count ?? 1)
            case nil: render.fps = 1; render.frameCount = 1
            }
            let motionKey = (chosen?.raw ?? provider) + "|" + (chosen?.variant(mood: agent.mood) ?? "")
                + (render.animate ? "|animated" : "|still")
            render.motion.update(key: motionKey, fps: render.fps, now: now)
            render.label = agent.lead.map { isActiveState($0.eff) ? statusText($0, eff: $0.eff) : "" } ?? ""
            let marker = agent.markerColor(fallback: chosen == nil, permissionColor: Self.amber)
            let cacheKey = [motionKey, marker.map { "\($0)" } ?? "", render.color.map { "\($0)" } ?? "template",
                            agent.gauge.signature, NSApp.effectiveAppearance.name.rawValue].joined(separator: "|")
            if render.cacheKey != cacheKey { render.cacheKey = cacheKey; render.frames = [:] }
            barRenders[provider] = render
        }
        let rate = barOrder.compactMap { barRenders[$0] }.filter(\.animate).map(\.fps).max() ?? 0
        if barTimerFPS != rate {
            animTimer?.invalidate(); animTimer = nil
            barTimerFPS = rate
            if rate > 0 {
                let timer = Timer(timeInterval: 1 / rate, repeats: true) { [weak self] _ in self?.animStep() }
                RunLoop.main.add(timer, forMode: .common)
                animTimer = timer
            }
        }
        renderMenuBarFrame(now: now)
    }

    func animStep() { renderMenuBarFrame(now: Date().timeIntervalSince1970) }

    func renderMenuBarFrame(now: Double) {
        guard let button = statusItem.button else { return }
        var blocks: [MenuBarImage.Block] = []
        var keys: [String] = [], frames: [String] = [], descriptions: [String] = []
        for provider in barOrder {
            guard var render = barRenders[provider] else { continue }
            let frame = render.animate ? render.motion.frame(at: now, count: render.frameCount) : 0
            let image: NSImage
            if let cached = render.frames[frame] { image = cached }
            else {
                let icon = iconImage(icon: render.icon, mood: render.agent.mood, ticks: render.ticks,
                                     color: render.color, frame: frame, animate: render.animate)
                let badged = render.agent.markedIcon(icon, fallback: render.icon == nil, permissionColor: Self.amber)
                let size = NSSize(width: Gauge.iconMaxW, height: 18)
                let fixed = NSImage(size: size, flipped: false) { _ in
                    let width = min(size.width, badged.size.width)
                    badged.draw(in: NSRect(x: (size.width - width) / 2, y: 0, width: width, height: 18),
                                from: .zero, operation: .sourceOver, fraction: 1)
                    return true
                }
                fixed.isTemplate = badged.isTemplate
                image = render.agent.gauge.image(icon: fixed)
                render.frames[frame] = image
                barRenders[provider] = render
            }
            let timer = render.agent.timer(show: showTimer, now: now)
            blocks.append(.init(image: image, label: render.label, timer: timer))
            keys.append(render.cacheKey + "|" + render.label + "|" + timer)
            frames.append(String(frame))
            let session = render.agent.lead
            var description = "\(render.agent.provider.title): \(session?.eff ?? "idle")"
            if let session { description += ", " + sessionMenuLine(session) }
            let gauge = render.agent.gauge
            if !gauge.isEmpty {
                description += render.agent.reserve ? ", Reserve: " : ", limits: "
                description += gauge.rows.map { "\(Gauge.spoken($0.0)) \(($0.1 * 100).rounded().clampedInt)%" }.joined(separator: ", ")
            }
            descriptions.append(description)
        }
        let key = keys.joined(separator: ";")
        if barCompositeKey != key { barCompositeKey = key; barCompositeFrames = [:] }
        let frameKey = frames.joined(separator: ":")
        let imageKey = key + "|" + frameKey
        if barImageKey != imageKey {
            let image = barCompositeFrames[frameKey] ?? MenuBarImage.compose(blocks)
            if barCompositeFrames.count >= 128 { barCompositeFrames = [:] }
            barCompositeFrames[frameKey] = image
            button.contentTintColor = nil
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.image = image
            barImageKey = imageKey
        }
        let description = agentDisplay == .hidden ? "Open Claude and Codex session panel" : descriptions.joined(separator: "\n")
        if button.toolTip != description { button.toolTip = description; button.setAccessibilityLabel(description) }
    }

    // MARK: icon

    static func loadFrames() -> [NSImage] { decodePNGs(claudeSparkFramePNGs) }
    static func decodePNGs(_ list: [String]) -> [NSImage] {
        list.compactMap { Data(base64Encoded: $0).flatMap(NSImage.init(data:)) }
    }

    func iconImage(icon: MenuBarIcon?, mood: CrabMood, ticks: [NSImage]?,
                   color: NSColor?, frame: Int, animate: Bool) -> NSImage {
        if let ticks, !ticks.isEmpty { return ticks[frame % ticks.count] }
        guard let icon else {
            let symbol = NSImage(systemSymbolName: Provider.codex.glyph, accessibilityDescription: Provider.codex.title)
                ?? NSImage(size: NSSize(width: 18, height: 18))
            symbol.isTemplate = true
            return symbol
        }
        if icon == .crab { return crabIcon(color: color, frame: frame, mood: mood) }
        if !animate { return tint(logoSet.isEmpty ? frames : logoSet, color: color, frame: 0) }
        if icon == .web { return tint(frames, color: color, frame: frame) }
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

    // nil color (System) => adaptive shaded template (see adaptiveCrabFrame in CrabRender.swift);
    // non-nil (Orange) => the original full-color sprite, drawn as-is.
    func crabIcon(color: NSColor?, frame: Int, mood: CrabMood) -> NSImage {
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
