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

/// The pet chooser in Settings: the animals themselves, in a row, with the chosen one ringed.
///
/// A dropdown of names was the first version of this, and it answered the wrong question. The
/// names come from other people's manifests — "Hoots", "Null Signal", whatever a gallery called
/// its pet — so reading one tells you nothing about what will appear beside your sessions, and
/// the only way to find out was to close the window and look. Here the choice IS the picture,
/// and every one of them is animating while you decide.
struct PetPicker: View {
    @ObservedObject var store: SettingsStore
    /// Wide enough for the cell plus its ring and its name underneath.
    private static let cell: CGFloat = 72

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell), spacing: 6)],
                  alignment: .leading, spacing: 6) {
            // The pets are shown at work rather than at rest: it is the liveliest thing each one
            // does, so it is what tells them apart at a glance.
            choice(id: "", name: "None", picked: store.pet.wrappedValue.isEmpty) {
                // What a row falls back to without a pet, drawn at the size it really appears, so
                // "None" shows its outcome instead of describing it.
                Circle().fill(.secondary.opacity(0.45)).frame(width: 7, height: 7)
            }
            ForEach(store.petChoices, id: \.pet.id) { entry in
                choice(id: entry.pet.id, name: entry.pet.displayName,
                       picked: store.pet.wrappedValue == entry.pet.id) {
                    if let atlas = entry.atlas {
                        PetView(atlas: atlas, state: "thinking", height: 44)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func choice<Content: View>(id: String, name: String, picked: Bool,
                                       @ViewBuilder content: () -> Content) -> some View {
        Button { store.pet.wrappedValue = id } label: {
            VStack(spacing: 2) {
                ZStack { content() }
                    .frame(width: Self.cell - 8, height: 48)
                Text(name)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(picked ? .primary : .secondary)
            }
            .frame(width: Self.cell)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(picked ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(picked ? "\(name) — the pet your session rows are using" : "Use \(name)")
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
    }
}
