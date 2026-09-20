import Cocoa

// What the menu bar draws, and how a pet drawn for a 32pt panel row is cut down to fit it.

/// The icon the menu bar is showing: one of the three we draw ourselves, or a pet by its id.
///
/// One value rather than a style with an id kept beside it. Two values can be saved half-written,
/// and the pair has a state — "a pet, but which one" — that draws nothing at all; the menu bar is
/// the app's only visible surface while the panel is closed, so there is no blank to fall back to.
/// Everything unrecognised is the crab for the same reason.
enum MenuBarIcon: Equatable {
    case web, code, crab
    case pet(String)

    /// The form the setting is saved in. The three drawn styles keep the names they have always
    /// been saved under, so a preference written by an older version still reads.
    var raw: String {
        switch self {
        case .web:  return "web"
        case .code: return "code"
        case .crab: return "crab"
        case .pet(let id): return Self.petPrefix + id
        }
    }

    private static let petPrefix = "pet:"

    init(raw: String) {
        switch raw {
        case "web":  self = .web
        case "code": self = .code
        case "crab": self = .crab
        default:
            // Split once and keep the rest whole: the ids are other people's folder names, and
            // nothing forbids a colon in one.
            guard raw.hasPrefix(Self.petPrefix) else { self = .crab; return }
            let id = String(raw.dropFirst(Self.petPrefix.count))
            self = id.isEmpty ? .crab : .pet(id)
        }
    }

    /// What the picker calls it. A pet is named by its own manifest where the picker has it to
    /// hand; this is the name for when it does not — a pet that has since been uninstalled.
    var title: String {
        switch self {
        case .web:  return "Claude Spark"
        case .code: return "Claude Code"
        case .crab: return "Crab Walking"
        case .pet(let id): return id
        }
    }

    var isPet: Bool { if case .pet = self { return true }; return false }

    /// Whether this icon has something to show while nothing is happening. The crab sleeps and a
    /// pet breathes, so both keep moving with every session idle; the two drawn styles have one
    /// resting picture and would only flicker.
    var restsInMotion: Bool {
        switch self {
        case .crab, .pet: return true
        case .web, .code: return false
        }
    }

    /// What, besides the icon itself, changes the picture — so a cached frame is not reused across
    /// a change the cache key cannot see. The crab draws a mood; a pet draws one animation per
    /// state, and four of the six moods share it; the two drawn styles have neither.
    func variant(mood: CrabMood) -> String {
        switch self {
        case .crab: return mood.rawValue
        case .pet:  return String(mood.petRow.rawValue)
        case .web, .code: return ""
        }
    }
}

extension CrabMood {
    /// Which of a pet's animations stands in for this mood.
    ///
    /// The crab says how busy the machine is by changing what it is doing — a cigar at one session,
    /// smoke at four, flames at six. A pet has three animations and no vocabulary for degrees, so
    /// the four busy moods land on the same walk. The load is still in the bar, in the crab's
    /// tempo; a pet keeps the tempo its own frames were drawn at, because speeding up somebody
    /// else's animation is a decision about their art rather than about our data.
    var petRow: PetRow {
        switch self {
        case .sleeping: return .idle
        case .waitingPermission: return .waiting
        case .cigar, .walking, .overheated, .onFire: return .running
        }
    }
}

/// A pet's animations cut down to the one size the menu bar has room for.
///
/// Two things have to happen to a pet on its way to the bar. Its transparent margin has to go:
/// the art puts the animal in about half of its cell's height, so a cell drawn whole at 18 points
/// arrives as a nine-point smudge. And its durations have to go: the bar steps through a flat list
/// of frames on one timer, so a frame held for four tenths of a second becomes four entries in
/// that list. Both are done once, when a pet is picked.
///
/// The margin is measured across every animation the bar can show, never per animation. Trimmed
/// per animation, a pet changes size the moment a session starts working — and an icon that
/// resizes reads as the menu bar jumping rather than as the pet moving.
struct PetIconFrames {
    /// How often the bar steps. Every frame duration in the atlas format is a multiple of it, so
    /// writing a loop out as one picture per tick holds each frame for exactly as long as it asks
    /// for, and the timer stepping through them needs to know nothing about durations.
    static let fps: Double = 10

    /// A pixel this faint is the anti-aliased edge of nothing. Measuring the margin down to the
    /// last stray pixel would keep a margin the eye cannot see.
    private static let visibleAlpha: UInt8 = 8

    private let ticks: [PetRow: [NSImage]]

    /// Cuts every animation a mood can ask for. Nil when there is nothing drawn in any of them:
    /// a pet we cannot measure has no height to scale by, and the caller draws the crab.
    init?(_ pet: Pet, height: CGFloat = 18) {
        // Taken from the moods rather than listed here, so an animation cannot be left out by a
        // mood learning to draw something this file was not told about.
        let rows = Set(CrabMood.allCases.map(\.petRow)).sorted { $0.rawValue < $1.rawValue }
        guard let sheet = Self.decodedSheet(of: pet) else { return nil }

        let cut = rows.map { row in
            (row, pet.format.frames(for: row).compactMap { frame in
                sheet.cropping(to: pet.format.rect(row: frame.row, column: frame.column))
                    .map { (cell: $0, duration: frame.duration) }
            })
        }
        guard let box = Self.artBox(of: cut.flatMap { $0.1.map(\.cell) }) else { return nil }

        let scale = height / box.height
        let size = NSSize(width: (box.width * scale).rounded(), height: height)
        var built: [PetRow: [NSImage]] = [:]
        for (row, frames) in cut {
            var out: [NSImage] = []
            for frame in frames {
                let trimmed = Self.trim(frame.cell, to: box, into: size)
                // A duration below one tick still gets its frame: a format that starts holding a
                // frame for a twentieth of a second must not make it disappear instead.
                out.append(contentsOf:
                    repeatElement(trimmed, count: max(1, Int((frame.duration * Self.fps).rounded()))))
            }
            built[row] = out
        }
        ticks = built
    }

    /// The pictures for one animation, one per tick, in order.
    func frames(for row: PetRow) -> [NSImage] { ticks[row] ?? [] }

    /// The whole sheet, decoded into a bitmap of our own, once.
    ///
    /// An image read from a file is decoded lazily — and lazily means once per USE, not once. Every
    /// frame cut out of it pays for the whole picture again, which for a pet packed in WebP inside
    /// an application archive measured 22 ms a frame on this machine: eighteen frames, four tenths
    /// of a second, for one pet. Drawing the sheet into a buffer first costs 26 ms and makes every
    /// cut after it free — 400 ms down to 30 for the same work.
    ///
    /// The buffer lives exactly as long as this initialiser. It is 14 MB for the atlas sizes we
    /// know, and what the bar keeps in the end is a couple of dozen pictures 18 points tall.
    private static func decodedSheet(of pet: Pet) -> CGImage? {
        guard let source = pet.art.imageSource(),
              let lazySheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let ctx = CGContext(data: nil, width: pet.format.width, height: pet.format.height,
                                  bitsPerComponent: 8, bytesPerRow: pet.format.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(lazySheet, in: CGRect(x: 0, y: 0, width: pet.format.width, height: pet.format.height))
        return ctx.makeImage()
    }

    /// The smallest rectangle holding every visible pixel of every frame given, counted from the
    /// TOP left — the same corner the atlas format addresses its cells from, and the same one the
    /// drawing below puts them back at.
    private static func artBox(of cells: [CGImage]) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for cell in cells {
            let width = cell.width, height = cell.height
            // Redrawn into a buffer of our own rather than read out of the picture: a frame cut
            // from an atlas carries whatever layout that file was written in, and reading alpha
            // out of the wrong byte finds art in an empty cell.
            guard width > 0, height > 0,
                  let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            ctx.draw(cell, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let raw = ctx.data else { continue }
            let px = raw.bindMemory(to: UInt8.self, capacity: width * height * 4)
            // The buffer's first row is the TOP of the picture — measured, not assumed, because
            // getting it backwards still yields a box of the right SIZE and puts the animal half
            // out of frame. `trim` turns this the right way up for a context that draws upward.
            for y in 0..<height {
                for x in 0..<width where px[(y * width + x) * 4 + 3] > visibleAlpha {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// One frame, scaled and shifted so that `box` covers the whole of `size`. The cell is drawn
    /// whole and clipped by the image it is drawn into, which is what keeps every frame aligned:
    /// each one keeps its own position inside the shared box instead of being centred on its own.
    private static func trim(_ cell: CGImage, to box: CGRect, into size: NSSize) -> NSImage {
        let cut = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let scale = rect.height / box.height
            // The box was measured downward from the top of the cell, the way the atlas format
            // addresses it; a context draws upward from the bottom. What this needs is the gap
            // underneath the art, which is the rest of the cell below the box.
            let below = CGFloat(cell.height) - box.maxY
            ctx.interpolationQuality = .high
            ctx.draw(cell, in: CGRect(x: rect.minX - box.minX * scale,
                                      y: rect.minY - below * scale,
                                      width: CGFloat(cell.width) * scale,
                                      height: CGFloat(cell.height) * scale))
            return true
        }
        // Never a template: the drawn styles are one shape in one colour and become black or white
        // with the menu bar, but a pet is somebody's painted sprite and has nothing left of itself
        // once it is flattened into a single system colour.
        cut.isTemplate = false
        return cut
    }
}
