import Cocoa

// Regenerates assets/pets/clawd/spritesheet.png — the pet the app ships with — from the runtime
// crab frames:
//   swiftc -O Sources/Model/*.swift tools/pet-sheet/main.swift -o /tmp/petsheet -framework Cocoa && /tmp/petsheet
// Run from the repository root.
//
// The art is the menu bar's own crab, laid out in the sprite-atlas format described in
// Sources/Model/PetSheet.swift. Drawing our own rather than shipping somebody else's keeps the
// repository's licence honest, and generating it from the runtime frames means the pet in the
// panel and the crab in the menu bar can never drift apart.
//
// The v1 atlas (nine rows) and not the taller v2: the two extra rows of v2 hold sixteen
// look-direction cells for a pet that follows the cursor, and we have no such art. An atlas of
// blank rows claiming to be v2 would be a promise the file does not keep.

let format = PetFormat.v1
let cellScale = 3   // 51x36 source art -> 153x108 inside a 192x208 cell
let outDir = FileManager.default.currentDirectoryPath + "/assets/pets/clawd"

let set = CrabFrameSet(walking: clawdCrabFramePNGs.compactMap {
    Data(base64Encoded: $0).flatMap(NSImage.init(data:))
})

// Which of the crab's moods stands in for each animation the format asks for. The three the panel
// actually draws are idle, waiting and running; the rest are filled so the file is a complete pet
// rather than one with holes in it, which is what lets it be dropped into ~/.codex/pets and used
// anywhere else that reads this format.
let sources: [(PetRow, CrabMood, mirrored: Bool)] = [
    (.idle, .sleeping, false),
    (.runningRight, .walking, false),
    (.runningLeft, .walking, true),
    (.waving, .waitingPermission, false),
    (.jumping, .walking, false),
    (.failed, .onFire, false),
    (.waiting, .waitingPermission, false),
    (.running, .walking, false),
    (.review, .cigar, false),
]

/// Picks `count` frames evenly spaced across a loop of any length, so a twenty-frame walk becomes
/// a six-frame one that still covers the whole cycle instead of its first third.
func resample(_ frames: [NSImage], to count: Int) -> [NSImage] {
    guard !frames.isEmpty, count > 0 else { return [] }
    return (0..<count).map { frames[$0 * frames.count / count] }
}

guard let sheet = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: format.width, pixelsHigh: format.height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: format.width * 4, bitsPerPixel: 32),
      let ctx = NSGraphicsContext(bitmapImageRep: sheet) else {
    print("FAILED to make the atlas bitmap"); exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
ctx.cgContext.interpolationQuality = .none   // pixel art: never smooth it

for (row, mood, mirrored) in sources {
    let wanted = format.frames(for: row).count
    for (column, frame) in resample(set.frames(for: mood), to: wanted).enumerated() {
        guard let rep = frame.representations.first as? NSBitmapImageRep else { continue }
        let w = CGFloat(rep.pixelsWide * cellScale), h = CGFloat(rep.pixelsHigh * cellScale)
        // The atlas is addressed from its top left, the drawing context from its bottom left, so
        // the row index has to be flipped on the way in. Getting this wrong writes a pet upside
        // down in row order — every animation plays, each one the wrong one.
        let cell = format.rect(row: row, column: column)
        let x = cell.minX + (cell.width - w) / 2
        let y = CGFloat(format.height) - cell.maxY + (cell.height - h) / 2
        ctx.cgContext.saveGState()
        if mirrored {
            ctx.cgContext.translateBy(x: x + w, y: y)
            ctx.cgContext.scaleBy(x: -1, y: 1)
            rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        } else {
            rep.draw(in: NSRect(x: x, y: y, width: w, height: h))
        }
        ctx.cgContext.restoreGState()
    }
    print("row \(row.rawValue) \(row) <- \(mood.rawValue), \(wanted) frames"
          + (mirrored ? ", mirrored" : ""))
}

NSGraphicsContext.restoreGraphicsState()

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
guard let png = sheet.representation(using: .png, properties: [:]) else {
    print("FAILED to encode the atlas"); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outDir + "/spritesheet.png"))

let manifest = """
{
  "id": "clawd",
  "displayName": "Clawd",
  "description": "The menu bar crab, in the panel.",
  "spritesheetPath": "spritesheet.png"
}

"""
try! manifest.write(toFile: outDir + "/pet.json", atomically: true, encoding: .utf8)
print("wrote \(outDir)/spritesheet.png — \(format.width)x\(format.height), v\(format.version)")
