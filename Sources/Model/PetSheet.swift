import Cocoa
import ImageIO

// Animated companions drawn beside a session row, read from a sprite atlas.
//
// The atlas layout is not ours. Codex ships its pets this way, its own hatch-pet skill writes them
// into ~/.codex/pets/<id>/, and several third-party galleries publish hundreds more against the
// same layout. We read that layout so a pet the user already installed simply appears, and we ship
// our own atlas in the same shape so the app has something to draw before they install anything.
//
// Everything here is written to refuse the unfamiliar quietly. The format has already changed once
// — the first atlas was nine rows, the second added sixteen look-direction cells and grew two rows
// taller — so a third version is a question of when. An atlas we do not recognise, a manifest that
// is not JSON, a folder with no image in it: each comes back nil and the remaining pets are
// untouched. A pet that fails to load must never be able to stop the panel from drawing.

/// One animation of a pet, which is one row of the atlas.
///
/// The order is the format's, not ours, so the raw values are the row numbers and must not be
/// rearranged. Rows 9 and 10 of the taller atlas hold sixteen look directions for a pet that
/// follows the cursor; we do not draw those, so they have no case here.
enum PetRow: Int {
    case idle = 0, runningRight, runningLeft, waving, jumping, failed, waiting, running, review

    /// Which animation a session's state asks for. `eff` is the string the hooks write, and the
    /// question "is this session working" is answered in one place for the whole app
    /// (`isWorkingState`, Sessions.swift) — asking it again here with its own list of strings is
    /// how a state added hook-side lights up the spinner everywhere and leaves the pet resting.
    static func forSessionState(_ eff: String) -> PetRow {
        if eff == "permission" { return .waiting }
        return isWorkingState(eff) ? .running : .idle
    }

    /// How long an ordinary frame of this row is held, and how long its last frame rests before
    /// the loop starts over. The rest is what makes a short loop read as a pose instead of a
    /// twitch; without it every animation looks like the same nervous flicker.
    ///
    /// Only the three rows a session can actually ask for are named. Every value is a multiple of
    /// the tenth of a second the panel ticks at, so a frame is held for a whole number of ticks
    /// rather than being rounded to one at random.
    var timing: (frame: Double, rest: Double) {
        switch self {
        case .idle:    return (0.4, 0.6)   // breathing, near the sleeping crab's tempo in the bar
        case .waiting: return (0.2, 0.4)
        case .running: return (0.1, 0.2)   // the walk, at the tempo its frames were drawn for
        default:       return (0.2, 0.3)
        }
    }
}

/// One frame of an atlas: where to cut it, and how long to hold it.
struct PetFrame {
    let row: PetRow
    let column: Int
    let duration: Double
}

/// A published atlas layout, identified by the image's own pixel size.
///
/// Size is the whole identification. A manifest may claim any version it likes, but the picture is
/// the thing we cut frames out of, so its dimensions decide — which is also how Codex itself picks
/// the layout. Anything not on this list is a format we have not seen and do not draw.
struct PetFormat {
    let version: Int
    let width: Int, height: Int
    let cellWidth: Int, cellHeight: Int
    /// How many cells of each row actually hold art. The rest of the row is transparent padding,
    /// and animating through it would show the pet vanishing for a beat.
    let framesByRow: [Int]

    static let v1 = PetFormat(version: 1, width: 1536, height: 1872,
                              cellWidth: 192, cellHeight: 208,
                              framesByRow: [6, 8, 8, 4, 5, 8, 6, 6, 6])
    static let v2 = PetFormat(version: 2, width: 1536, height: 2288,
                              cellWidth: 192, cellHeight: 208,
                              framesByRow: [6, 8, 8, 4, 5, 8, 6, 6, 6, 8, 8])
    static let known = [v1, v2]

    static func matching(width: Int, height: Int) -> PetFormat? {
        known.first { $0.width == width && $0.height == height }
    }

    /// The cell to cut, counted from the top left of the atlas the way image files are addressed.
    func rect(row: PetRow, column: Int) -> CGRect {
        CGRect(x: CGFloat(column * cellWidth), y: CGFloat(row.rawValue * cellHeight),
               width: CGFloat(cellWidth), height: CGFloat(cellHeight))
    }

    /// The frames of one animation, in order. The row count is our own table rather than anything
    /// read off disk, so a row it does not describe is a mistake in this file — it draws a single
    /// still frame instead of trapping, because a menu bar app that crashes relaunches into the
    /// same crash.
    func frames(for row: PetRow) -> [PetFrame] {
        let count = framesByRow.indices.contains(row.rawValue) ? framesByRow[row.rawValue] : 1
        let last = max(0, count - 1)
        let timing = row.timing
        return (0...last).map {
            PetFrame(row: row, column: $0, duration: $0 == last ? timing.rest : timing.frame)
        }
    }
}

/// One installed pet: its manifest, and the atlas beside it.
struct Pet {
    let id: String
    let displayName: String
    let sheetPath: String
    let format: PetFormat

    /// Reads one pet folder: `pet.json` plus the atlas it names. Returns nil on anything at all
    /// unexpected — see the note at the top of the file for why that is the whole design.
    ///
    /// Note what this does NOT do: decode the image. The size is read from the file's header, so
    /// listing a folder of pets costs a few kilobytes rather than a decoded bitmap each.
    static func load(directory: String) -> Pet? {
        let dir = directory.hasSuffix("/") ? directory : directory + "/"
        guard let data = FileManager.default.contents(atPath: dir + "pet.json"),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        // The folder name is the fallback id because it is the one thing every gallery installer
        // guarantees: they all create ~/.codex/pets/<slug>/, and some of them omit "id" entirely.
        let folder = (dir as NSString).lastPathComponent
        let id = (manifest["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folder
        guard !id.isEmpty else { return nil }

        let sheetName = manifest["spritesheetPath"] as? String ?? "spritesheet.webp"
        let sheetPath = sheetName.hasPrefix("/") ? sheetName : dir + sheetName
        guard let size = atlasPixelSize(sheetPath),
              let format = PetFormat.matching(width: size.width, height: size.height)
        else { return nil }

        return Pet(id: id,
                   displayName: (manifest["displayName"] as? String) ?? id,
                   sheetPath: sheetPath,
                   format: format)
    }

    /// Every pet in a folder, by id, skipping the ones that do not load. A missing folder is no
    /// pets rather than an error: not having installed any is the normal case, not a fault.
    static func installed(inPetsFolder folder: String) -> [Pet] {
        let dir = folder.hasSuffix("/") ? folder : folder + "/"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.sorted().compactMap { load(directory: dir + $0) }
    }

    /// The pets on offer: the ones the app ships with, then the ones installed for Codex. Ours
    /// first, and a Codex pet answering to an id we already use does not replace it — the id is
    /// what the setting stores, and two pets under one id would make the picker unstable.
    static func library(bundled: String?, codex: String) -> [Pet] {
        let ours = bundled.map { installed(inPetsFolder: $0) } ?? []
        var seen = Set(ours.map(\.id))
        return ours + installed(inPetsFolder: codex).filter { seen.insert($0.id).inserted }
    }

    /// The pet a saved id names. An empty id is the user switching pets off. Any other id falls
    /// back to the first pet on offer: a saved id stops resolving the moment someone deletes that
    /// pet from ~/.codex/pets, and that must not leave every row without its marker.
    static func chosen(_ id: String, from library: [Pet]) -> Pet? {
        guard !id.isEmpty else { return nil }
        return library.first { $0.id == id } ?? library.first
    }

    /// The atlas's size in real pixels, read from the file's header without decoding the image.
    /// It has to be pixels: NSImage reports a size in points, so an atlas saved at 144 dpi would
    /// measure two-thirds of its true width and match no known format.
    private static func atlasPixelSize(_ path: String) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }
}

/// One animation ready to draw: the pictures, and how long each is held.
///
/// Pictures and durations are built together and kept together, so there is no second list for
/// them to disagree with and nothing to bounds-check at the moment of drawing.
struct PetLoop {
    let images: [NSImage]
    let durations: [Double]

    /// Which picture is showing `seconds` into the loop.
    ///
    /// The animation is read off a clock rather than advanced by a counter. A counter needs
    /// something to own it and to keep ticking while nobody is looking; a clock means a row that
    /// scrolls back into view, or a panel that is opened again, picks up where the animation would
    /// have been rather than snapping back to the first frame.
    func index(at seconds: Double) -> Int {
        let total = durations.reduce(0, +)
        guard total > 0 else { return 0 }
        var left = seconds.truncatingRemainder(dividingBy: total)
        if left < 0 { left += total }   // a clock read before the start still points at a frame
        for (i, duration) in durations.enumerated() {
            left -= duration
            if left < 0 { return i }
        }
        return durations.count - 1
    }
}

/// A pet's atlas, decoded once and cut into animations as each is first asked for.
///
/// Cutting is done on the CGImage rather than on an NSImage because CGImage crops in the file's
/// own pixels, counted from the top left — the same coordinates the format is written in. An
/// NSImage crop would go through points, and an atlas saved at anything other than 72 dpi would
/// come out sliced along the wrong lines.
final class PetAtlas {
    let pet: Pet
    private let sheet: CGImage
    private var cut: [PetRow: PetLoop] = [:]

    init?(_ pet: Pet) {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: pet.sheetPath) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.pet = pet
        self.sheet = image
    }

    /// One animation, cut and kept. A row whose art will not cut comes back empty and the caller
    /// draws nothing, which is the same outcome as a pet that failed to load.
    func loop(for row: PetRow) -> PetLoop {
        if let done = cut[row] { return done }
        let size = NSSize(width: pet.format.cellWidth, height: pet.format.cellHeight)
        var images: [NSImage] = []
        var durations: [Double] = []
        for frame in pet.format.frames(for: row) {
            guard let cell = sheet.cropping(to: pet.format.rect(row: frame.row, column: frame.column))
            else { continue }
            images.append(NSImage(cgImage: cell, size: size))
            durations.append(frame.duration)
        }
        let loop = PetLoop(images: images, durations: durations)
        cut[row] = loop
        return loop
    }
}
