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
    /// glance needs a cell about twice as tall as the pixels you end up seeing.
    private static let height: CGFloat = 32

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
        .frame(width: Self.height * CGFloat(cell.cellWidth) / CGFloat(cell.cellHeight),
               height: Self.height)
    }
}
