import SwiftUI

/// A pet beside a session row, playing the animation that session's state asks for.
///
/// Motion.swift sets the rule this view is the exception to: the panel commits an animation once
/// and lets the render server interpolate it, so the process does no work per frame. A sprite
/// animation is per-frame work by definition — there is no way to interpolate between two drawings
/// of a crab. The exception is paid for as narrowly as it can be. TimelineView schedules redraws
/// only while the view is on screen, which for a menu bar panel means only while it is open; the
/// schedule is anchored to a fixed instant rather than to "now", so every row on screen ticks
/// together instead of each waking the main thread on its own phase; the rate is the slowest one
/// the art needs; and switching motion off (or the system's Reduce Motion) drops the schedule and
/// leaves a still pet rather than an empty gap.
struct PetView: View {
    let atlas: PetAtlas
    /// The session's effective state — the string the hooks write, not a display label.
    let state: String

    /// Ten ticks a second. Every frame duration in PetRow.timing is a multiple of it, so this is
    /// the slowest schedule that still shows each frame for exactly as long as it asks for.
    private static let tick = 0.1

    /// The height of the CELL, not of the visible animal. Our own crab fills about half of its
    /// cell's height — it is a wide, short thing in a portrait cell — so a figure that reads at a
    /// glance needs a cell about twice as tall as the pixels you end up seeing. A session row asks
    /// for the default; the picker in Settings asks for a larger one, because there the animal is
    /// the thing being chosen rather than a marker beside a name.
    var height: CGFloat = 32

    private var loop: PetLoop { atlas.loop(for: PetRow.forSessionState(state)) }

    var body: some View {
        if Motion.moves {
            // Anchored at the reference date, not at .now: .now is read when the body runs, so
            // every row would get its own phase and the panel would wake the main thread once per
            // row per tick instead of once per tick.
            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: Self.tick)) {
                sprite(at: $0.date.timeIntervalSinceReferenceDate)
            }
        } else {
            sprite(at: 0)
        }
    }

    private func sprite(at seconds: Double) -> some View {
        let loop = self.loop
        let cell = atlas.pet.format
        return Group {
            if !loop.images.isEmpty {
                // .none: the art is pixels drawn at a size, and smoothing them turns a crab into
                // a smudge at the sizes a row has room for.
                Image(nsImage: loop.images[loop.index(at: seconds)])
                    .interpolation(.none).resizable().scaledToFit()
            }
        }
        .frame(width: height * CGFloat(cell.cellWidth) / CGFloat(cell.cellHeight),
               height: height)
    }
}

/// A list of pictures played at a fixed tick, which is how everything the menu bar draws is
/// handed around: the durations were spent when the frames were built, so what is left is one
/// picture per tenth of a second and an index into it.
///
/// The same exception to Motion.swift that PetView is, for the same reason, with the same escape:
/// switching motion off leaves the first frame rather than an empty space.
struct TickedFrames: View {
    let frames: [NSImage]
    let height: CGFloat

    var body: some View {
        if Motion.moves, frames.count > 1 {
            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0),
                                   by: 1 / PetIconFrames.fps)) {
                picture(at: $0.date.timeIntervalSinceReferenceDate)
            }
        } else {
            picture(at: 0)
        }
    }

    private func picture(at seconds: Double) -> some View {
        let step = Int((seconds * PetIconFrames.fps).rounded(.down))
        let frame = frames.isEmpty ? nil : frames[((step % frames.count) + frames.count) % frames.count]
        return Group {
            if let frame {
                // .none for the same reason the panel's pets use it: these are pixels drawn at a
                // size, and smoothing them turns a small animal into a smudge.
                Image(nsImage: frame).interpolation(.none).resizable().scaledToFit()
            }
        }
        .frame(height: height)
    }
}

/// One ringed, named choice in a picker. Shared by the three pickers in Settings — the menu bar
/// icon and the two session-row pets — so that picking a picture looks and behaves the same way
/// wherever it is done.
struct PickerCell<Content: View>: View {
    let name: String
    let picked: Bool
    /// What the tooltip says about the one already in use, e.g. "the pet your Claude rows use".
    let role: String
    let choose: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 2) {
                ZStack { content }
                    .frame(width: pickerCellWidth - 8, height: 48)
                Text(name)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(picked ? .primary : .secondary)
            }
            .frame(width: pickerCellWidth)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(picked ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(picked ? "\(name) — \(role)" : "Use \(name)")
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
    }
}

/// Wide enough for the picture plus its ring and its name underneath, and the step the three
/// pickers lay their grids out on.
private let pickerCellWidth: CGFloat = 72
private let pickerColumns = [GridItem(.adaptive(minimum: pickerCellWidth), spacing: 6)]

/// The pet chooser in Settings: the animals themselves, in a row, with the chosen one ringed.
///
/// A dropdown of names was the first version of this, and it answered the wrong question. The
/// names come from other people's manifests — "Hoots", "Null Signal", whatever a gallery called
/// its pet — so reading one tells you nothing about what will appear beside your sessions, and
/// the only way to find out was to close the window and look. Here the choice IS the picture,
/// and every one of them is animating while you decide.
struct PetPicker: View {
    @ObservedObject var store: SettingsStore
    /// Which rows this picker is choosing for — the binding, and the words the tooltip uses.
    let selection: Binding<String>
    let role: String

    var body: some View {
        LazyVGrid(columns: pickerColumns, alignment: .leading, spacing: 6) {
            // The pets are shown at work rather than at rest: it is the liveliest thing each one
            // does, so it is what tells them apart at a glance.
            PickerCell(name: "None", picked: selection.wrappedValue.isEmpty, role: role,
                       choose: { selection.wrappedValue = "" }) {
                // What a row falls back to without a pet, drawn at the size it really appears, so
                // "None" shows its outcome instead of describing it.
                Circle().fill(.secondary.opacity(0.45)).frame(width: 7, height: 7)
            }
            ForEach(store.petChoices, id: \.pet.id) { entry in
                PickerCell(name: entry.pet.displayName,
                           picked: selection.wrappedValue == entry.pet.id, role: role,
                           choose: { selection.wrappedValue = entry.pet.id }) {
                    if let atlas = entry.atlas {
                        PetView(atlas: atlas, state: "thinking", height: 44)
                    }
                }
            }
        }
    }
}

/// The menu bar chooser: the three styles the app draws itself, then every pet, each one playing
/// at the size the bar will show it.
///
/// Eighteen points is small, and that is the point of showing it that way: a pet drawn for a panel
/// row can turn out to be unreadable up there, and the picker is where that is worth finding out
/// rather than after closing the window.
struct MenuBarIconPicker: View {
    @ObservedObject var store: SettingsStore
    private static let role = "the icon in your menu bar"

    var body: some View {
        LazyVGrid(columns: pickerColumns, alignment: .leading, spacing: 6) {
            ForEach(store.iconChoices, id: \.icon.raw) { choice in
                PickerCell(name: choice.name, picked: store.animStyle.wrappedValue == choice.icon,
                           role: Self.role,
                           choose: { store.animStyle.wrappedValue = choice.icon }) {
                    TickedFrames(frames: choice.frames, height: 18)
                }
            }
        }
    }
}
