import Cocoa

/// Pets that came inside an installed application rather than in a folder of their own.
///
/// ChatGPT.app carries the Codex companions inside its Electron archive (`app.asar`) — there are
/// no loose files for the folder reader to find, and no copy of them anywhere else on the disk.
/// So they are read out of that archive in place, on the machine that already has the app. Nothing
/// is copied and nothing is redistributed: the pictures belong to the application that installed
/// them, and a Mac without that application simply has fewer pets to choose from.
///
/// Reading somebody else's container means every field in it is a claim, not a fact. The name of
/// the file carries a build hash that changes with every release of that app, so nothing about a
/// path can be remembered between runs; the index has to be read each time. And an offset, a
/// length or an index size out of that file could say anything at all, so each one is checked
/// against the size of the file before it is used. Everything that does not add up ends the same
/// way: no pets, no error, the rest of the picker untouched.
enum PetArchive {

    /// The header is four little-endian words. The second one measures everything from itself to
    /// the end of the index, which is what puts the first file's bytes at `8 + that`; the fourth
    /// is the length of the index's JSON, which starts at byte 16.
    private static let headerSize = 16

    /// Every pet inside the archive at `path`, in a stable order.
    static func pets(inAsar path: String) -> [Pet] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil

        guard let header = try? handle.read(upToCount: headerSize), header.count == headerSize
        else { return [] }
        let indexSize = Int(word(header, at: 12))
        let base = 8 + Int(word(header, at: 4))
        // A truncated download, or a file that was never an archive at all, reaches here with
        // numbers that describe something much larger than itself.
        guard indexSize > 0, base > headerSize, let total = fileSize,
              headerSize + indexSize <= total, base <= total
        else { return [] }

        guard let indexBytes = try? handle.read(upToCount: indexSize), indexBytes.count == indexSize,
              let index = (try? JSONSerialization.jsonObject(with: indexBytes)) as? [String: Any]
        else { return [] }

        var pets: [Pet] = []
        var seen = Set<String>()
        for entry in files(in: index).sorted(by: { $0.name < $1.name }) {
            // "hoots-spritesheet-v8-21cacd193ace.webp" — the pet's name, then the sheet's version,
            // then a hash of the build. Only the first part is ours to keep.
            guard let id = entry.name.range(of: "-spritesheet-").map({ String(entry.name[..<$0.lowerBound]) }),
                  seen.insert(id).inserted,
                  entry.offset >= 0, entry.size > 0,
                  base + entry.offset + entry.size <= total
            else { continue }
            let art = PetArt.packed(archive: path,
                                    offset: UInt64(base + entry.offset), size: entry.size)
            if let pet = Pet.unpacked(id: id, art: art) { pets.append(pet) }
        }
        return pets
    }

    private static func word(_ data: Data, at offset: Int) -> UInt32 {
        data[data.startIndex + offset ..< data.startIndex + offset + 4]
            .reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    /// Walks the index's nested folders and returns the leaves. Only sprite sheets are of any
    /// interest, and the archive holds thousands of other files, so the filter is here rather than
    /// at the caller: a list of every file in a 300 MB bundle is not worth building.
    private static func files(in index: [String: Any]) -> [(name: String, offset: Int, size: Int)] {
        var found: [(name: String, offset: Int, size: Int)] = []
        func walk(_ node: [String: Any]) {
            guard let entries = node["files"] as? [String: Any] else { return }
            for (name, value) in entries {
                guard let entry = value as? [String: Any] else { continue }
                if entry["files"] != nil {
                    walk(entry)
                } else if name.contains("-spritesheet-"), name.hasSuffix(".webp"),
                          let size = entry["size"] as? Int,
                          // Written as a string, because a file past 2 GB would not survive the
                          // trip through JSON's number type.
                          let offset = (entry["offset"] as? String).flatMap({ Int($0) })
                                    ?? entry["offset"] as? Int {
                    found.append((name, offset, size))
                }
            }
        }
        walk(index)
        return found
    }
}
