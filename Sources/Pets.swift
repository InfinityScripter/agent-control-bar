import Cocoa

// Which pets are on offer and the pictures decoded for them. The caches are stored properties in
// main.swift, because an extension cannot declare them.

extension StatusController {
    // MARK: pets
    //
    // Both folders are read here rather than in the panel, for the reason every other path is:
    // StatusController owns where things live, models parse what it hands them, and the views draw the
    // result. The pets folder sits beside codexHome so a Codex that moves takes its pets with it.

    /// The pets on offer. Cached because the panel asks on every refresh; dropped when the
    /// Settings window opens, which is the only place the whole list is shown and therefore the
    /// only moment a pet installed while the app was running needs to appear.
    func petLibrary() -> [Pet] {
        if let cached = petLibraryCache { return cached }
        let library = Pet.library(
            bundled: Bundle.main.resourceURL?.appendingPathComponent("pets").path,
            codex: (codexHome as NSString).appendingPathComponent("pets"),
            archive: codexAppArchive)
        petLibraryCache = library
        return library
    }

    /// Which pet a provider's rows draw.
    func petID(of provider: String) -> String { provider == "codex" ? codexPetID : petID }

    /// A chosen pet's atlas, decoded on first use and kept until the choice changes. Only the
    /// chosen ones are ever decoded: an atlas is a megabyte-scale picture, and a folder of gallery
    /// pets would otherwise all sit in memory for the sake of the one or two being drawn. Keyed by
    /// id rather than by provider, so the common case — both agents showing the same pet — decodes
    /// it once and both lists of rows draw the same pictures.
    ///
    /// The dictionary holds an optional: "we looked and there is nothing" has to be told apart
    /// from "we have not looked", or a pet whose art will not decode is decoded again on every
    /// refresh of a panel that asks 2.5 times a second.
    func petAtlas(of provider: String) -> PetAtlas? {
        let id = petID(of: provider)
        if let cached = petAtlasCache[id] { return cached }
        // Only the ids in use are kept. Clicking down a picker of twenty pets changes the setting
        // twenty times, and each one asked for its sheet; without this the last nineteen stay.
        petAtlasCache = petAtlasCache.filter { $0.key == petID || $0.key == codexPetID }
        let atlas = Pet.chosen(id, from: petLibrary()).flatMap(PetAtlas.init)
        petAtlasCache[id] = atlas
        return atlas
    }

    /// The menu bar pet, cut down to the bar's own size. Built once per pick and kept: it is a
    /// couple of dozen pictures 18 points tall, and building it costs a decode of the whole sheet.
    func petIconFrames(id: String, provider: String) -> PetIconFrames? {
        let key = provider + ":" + id
        if let cached = petIconCache[key] { return cached }
        let claudeID: String
        if case .pet(let picked) = animStyle { claudeID = picked } else { claudeID = "" }
        petIconCache = petIconCache.filter { $0.key == "claude:" + claudeID || $0.key == "codex:" + codexPetID }
        let pet = provider == "codex" ? petLibrary().first { $0.id == id }
                                     : Pet.chosen(id, from: petLibrary())
        let frames = pet.flatMap { PetIconFrames($0) }
        petIconCache[key] = frames
        return frames
    }

    func reloadPetLibrary() {
        petLibraryCache = nil
        petAtlasCache = [:]
        petIconCache = [:]
        for provider in barRenders.keys { barRenders[provider]?.cacheKey = "" }
        barCompositeKey = ""
        barImageKey = ""
    }

    /// The archive of the desktop app that carries the Codex companions, when it is installed.
    ///
    /// Known locations rather than a Launch Services lookup, the same list `mcpbar.py` keeps for
    /// finding `codex` itself: that lookup answers from a cache which goes on naming a path long
    /// after the bundle moved. Nothing here is copied — the pets are read out of the app in place,
    /// and on a Mac without it there are simply fewer of them.
    var codexAppArchive: String? {
        let personal = NSHomeDirectory() + "/Applications"
        return ["/Applications/ChatGPT.app", "/Applications/Codex.app",
                personal + "/ChatGPT.app", personal + "/Codex.app"]
            .map { $0 + "/Contents/Resources/app.asar" }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Every pet with its frames, for the picker that shows them rather than naming them.
    ///
    /// This is the one place that decodes more than the chosen pet, because showing the choice is
    /// the whole point of it — so it is also the one place that has to give the memory back. The
    /// pictures live exactly as long as the Settings window: `releasePetPreviews()` runs when that
    /// window closes, leaving only the atlas the panel is drawing.
    func petPreviews() -> [(pet: Pet, atlas: PetAtlas?)] {
        if petPreviewCache.isEmpty {
            petPreviewCache = petLibrary().map { ($0, PetAtlas($0)) }
        }
        return petPreviewCache
    }

    /// Every menu bar choice with the pictures it would put in the bar, at the size the bar draws
    /// them and one picture per tick of the bar's own clock.
    ///
    /// The picker animates all of them for the same reason the pet picker does: a pet's name comes
    /// out of somebody else's manifest and says nothing about what will appear up there. The two
    /// tempos below are approximate — the spark runs at nine frames a second and the glyphs tween
    /// their size — because the picker has to answer "which one is this", not reproduce the bar.
    func iconChoicePreviews() -> [(icon: MenuBarIcon, name: String, frames: [NSImage])] {
        if iconPreviewCache.isEmpty {
            let colour = iconColor
            iconPreviewCache = [
                (.web, MenuBarIcon.web.title,
                 frames.indices.map { tint(frames, color: colour, frame: $0) }),
                (.code, MenuBarIcon.code.title,
                 (0..<codeGlyphs.count).flatMap {
                     repeatElement(codeIcon(color: colour, glyph: $0, scale: 1), count: 8) }),
                (.crab, MenuBarIcon.crab.title,
                 crabFrameSet.frames(for: .walking).indices.map {
                     crabIcon(color: colour, frame: $0, mood: .walking) }),
            ]
            iconPreviewCache += petLibrary().compactMap { pet in
                PetIconFrames(pet).map { (.pet(pet.id), pet.displayName, $0.frames(for: .idle)) }
            }
        }
        return iconPreviewCache
    }

    func releasePetPreviews() {
        petPreviewCache = []
        iconPreviewCache = []
    }
}
