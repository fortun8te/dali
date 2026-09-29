// DALI — the room, live.
//
// Four layers, bottom to top:
//   1. furniture  — floor glow, desk, monitor, listener. Rendered ONCE per size.
//   2. light      — pools, waves, pulses, room glow. The only per-frame layer,
//                   and it only exists while the room is starting, streaming or
//                   fading out.
//   3. cabinets   — each pair rendered once dark and once lit; the lit copy
//                   cross-fades in with the spring. No per-frame path work.
//
// Budget: ≤ 20 fps, zero blur, and the timeline pauses whenever the window
// is minimised, covered, or the room is idle and settled.
//
// Audio-reactive light reads ONLY the store's delayed level path
// (`audioLevel`, `bassLevel`, `beatCount`) — the sample the speakers are
// actually playing now, not what the tap captured a second ago.

import SwiftUI
import Observation

struct RoomCanvas: View {
    @Environment(DALIStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    @State private var visible = true
    @State private var layers: RoomLayers?
    @State private var smoother = LevelSmoother()
    @State private var frontChangedAt: Date?
    @State private var backChangedAt: Date?
    @State private var recentBeats: [Date] = []
    @State private var coastTick = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let layers {
                    Image(nsImage: layers.furniture).resizable()
                }
                if lightLayerNeeded {
                    TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: paused)) { tl in
                        Canvas { ctx, size in drawLight(ctx, size: size, now: tl.date) }
                    }
                }
                if let layers {
                    cabinets(store.front, dark: layers.frontDark, lit: layers.frontLit)
                    cabinets(store.back, dark: layers.backDark, lit: layers.backLit)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture { location in
                let target = location.y < geo.size.height / 2 ? store.front : store.back
                if let target { store.toggle(target) }
            }
            .onChange(of: geo.size, initial: true) { _, size in
                layers = RoomLayers.render(size: size, scale: displayScale)
            }
            // Dragged to a display with another backing scale: the cached
            // bitmaps are at the old one and would blur or pixelate.
            .onChange(of: displayScale) { _, scale in
                layers = RoomLayers.render(size: geo.size, scale: scale)
            }
        }
        .background(WindowVisibilityReader(isVisible: $visible))
        .onAppear { store.roomCanvasVisible = visible }
        .onChange(of: visible) { _, value in store.roomCanvasVisible = value }
        .onDisappear { store.roomCanvasVisible = false }
        .onChange(of: store.isLit(store.front)) { _, _ in frontChangedAt = Date(); coast() }
        .onChange(of: store.isLit(store.back)) { _, _ in backChangedAt = Date(); coast() }
        .onChange(of: store.beatCount) { old, new in
            guard new > old, let playedAt = store.beatPlayedAt else { return }
            recentBeats.append(playedAt)
            if recentBeats.count > 3 { recentBeats.removeFirst(recentBeats.count - 3) }
        }
        .onChange(of: store.phase) { _, _ in coast() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Room")
        .accessibilityValue(store.statusText)
        .accessibilityHint("Click the front or back half to switch that pair on or off")
    }

    // MARK: cabinets

    @ViewBuilder
    private func cabinets(_ speaker: RoomSpeaker?, dark: NSImage, lit: NSImage) -> some View {
        if let speaker {
            let on = store.isLit(speaker)
            Image(nsImage: dark).resizable()
                // Keep the cabinet visible when its pair is switched off.
                // The unlit artwork is intentionally dark, so 0.4 made it
                // disappear against the room background.
                .opacity(speaker.enabled ? 1 : 0.8)
            Image(nsImage: lit).resizable()
                .opacity(on ? 1 : 0)
                .animation(Motion.respecting(reduceMotion), value: on)
        }
    }

    // MARK: timeline control

    private var active: Bool { store.phase == .streaming || store.phase == .starting }

    /// The light layer is only in the tree while there is light to draw.
    private var lightLayerNeeded: Bool { active || coastTick > 0 }

    private var paused: Bool { reduceMotion || !visible }

    /// Keep the light layer alive past a state change so fades can finish,
    /// then drop it.
    private func coast() {
        coastTick += 1
        let tick = coastTick
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(850))
            if coastTick == tick { coastTick = 0 }
        }
    }

    // MARK: the light

    private func drawLight(_ ctx: GraphicsContext, size: CGSize, now: Date) {
        let t = now.timeIntervalSinceReferenceDate
        // The store republishes the levels at ~30 Hz. Read inside the Canvas
        // they are OBSERVED, so each publish invalidated this canvas on top of
        // the 20 fps timeline — up to ~50 redraws a second against the 20 the
        // budget above promises. The timeline is what should drive the frame,
        // so sample them without registering. (Reduce Motion pauses the
        // timeline, and there the observation is the only thing that redraws.)
        let (rawLevel, rawBass) = reduceMotion
            ? (store.audioLevel, store.bassLevel)
            : withObservationTracking({ (store.audioLevel, store.bassLevel) }, onChange: {})
        let (level, bass) = smoother.step(level: rawLevel, bass: rawBass, at: now)
        let me = RoomLayout.listener.scaled(to: size)
        let motion = !reduceMotion
        // Connecting: pools breathe on the spec's 1.2 s ease — the only
        // repeating motion, and it means something.
        let connecting = store.phase == .starting
        let breath = connecting && motion ? 0.5 - 0.5 * cos(2 * .pi * t / 2.4) : 0

        let pairs: [(RoomSpeaker?, Cabinet, Date?)] = [
            (store.front, .opticon2, frontChangedAt),
            (store.back, .era100, backChangedAt),
        ]
        var roomLight = 0.0
        var resolved: [(Cabinet, Double, Double, RoomSpeaker)] = []
        for case let (speaker?, cabinet, changedAt) in pairs {
            let lit = store.isLit(speaker)
            // Presence eases toward the lit state from the moment it changed.
            var presence = lit ? 1.0 : 0.0
            if motion, let changedAt {
                let p = easeOutCubic((now.timeIntervalSince(changedAt) - cabinet.delay) / 0.5)
                presence = lit ? p : 1 - p
            }
            let vol = Double(store.effectiveVolume(speaker)) / 100
            var energy = (0.12 + 0.88 * pow(level, 0.9)) * (0.55 + 0.45 * vol) * presence
            if speaker.health == .trouble { energy *= 0.45 }
            let light = max(presence, connecting && speaker.enabled ? 0.25 + 0.45 * breath : 0)
            roomLight = max(roomLight, presence)
            resolved.append((cabinet, light, energy, speaker))
        }

        RoomArt.drawRoomGlow(ctx, size: size, light: roomLight, level: level, bass: bass)

        for (cabinet, light, energy, speaker) in resolved {
            for p in RoomLayout.positions(cabinet, in: size) {
                let aim = atan2(me.y - p.y, me.x - p.x)
                RoomArt.drawPool(ctx, at: p, aim: aim, cabinet: cabinet, light: light, energy: energy)
                guard motion, store.isLit(speaker) else { continue }
                if let a = shot(since: cabinet == .opticon2 ? frontChangedAt : backChangedAt,
                                now: now, duration: 0.9, delay: cabinet.delay) {
                    RoomArt.drawPulse(ctx, at: p, aim: aim, progress: a,
                                      from: cabinet.reach, to: cabinet.reach * 2.8, alpha: 0.28)
                }
                for beatAt in recentBeats {
                    if let b = shot(since: beatAt, now: now, duration: 0.85, delay: 0) {
                        RoomArt.drawPulse(ctx, at: p, aim: aim, progress: b,
                                          from: cabinet.reach * 0.9, to: cabinet.reach * 2.4,
                                          alpha: 0.17 * (0.65 + 0.35 * bass))
                    }
                }
            }
        }
    }

    private func shot(since: Date?, now: Date, duration: Double, delay: Double) -> Double? {
        guard let since else { return nil }
        let e = now.timeIntervalSince(since) - delay
        guard e >= 0, e < duration else { return nil }
        return e / duration
    }
}

// MARK: - cached layers

/// The room's static pixels, rendered once per canvas size.
struct RoomLayers {
    let furniture: NSImage
    let frontDark: NSImage, frontLit: NSImage
    let backDark: NSImage, backLit: NSImage

    @MainActor
    static func render(size: CGSize, scale: CGFloat) -> RoomLayers? {
        guard size.width > 1, size.height > 1, size.width.isFinite, size.height.isFinite else { return nil }
        // A scale of 0 (no window yet) would render every layer empty.
        let scale = scale.isFinite && scale >= 1 ? scale : 1
        func image(_ draw: @escaping (GraphicsContext, CGSize) -> Void) -> NSImage {
            let renderer = ImageRenderer(content:
                Canvas { ctx, s in draw(ctx, s) }.frame(width: size.width, height: size.height))
            renderer.scale = scale
            renderer.isOpaque = false
            return renderer.nsImage ?? NSImage(size: size)
        }
        return RoomLayers(
            furniture: image { RoomArt.drawFurniture($0, size: $1) },
            frontDark: image { RoomArt.drawPair($0, .opticon2, size: $1, lit: 0) },
            frontLit: image { RoomArt.drawPair($0, .opticon2, size: $1, lit: 1) },
            backDark: image { RoomArt.drawPair($0, .era100, size: $1, lit: 0) },
            backLit: image { RoomArt.drawPair($0, .era100, size: $1, lit: 1) })
    }
}

// MARK: - level smoothing

/// The store's delayed levels tick at ~30 Hz; the canvas draws at 20. Ease both
/// directions so short transients make a soft swell instead of a sharp flash.
final class LevelSmoother {
    private var level = 0.0, bass = 0.0
    private var last: Date?

    func step(level target: Double, bass bassTarget: Double, at now: Date) -> (Double, Double) {
        let dt = min(max(last.map { now.timeIntervalSince($0) } ?? 1.0 / 20, 0), 0.1)
        last = now
        func ema(_ v: inout Double, _ target: Double) {
            // One NaN from the meter would stay in the filter forever (NaN in,
            // NaN out on every later step) and feed NaN into every gradient,
            // pow() and path the canvas draws.
            let target = target.isFinite ? min(max(target, 0), 1) : 0
            let tau = target > v ? 0.075 : 0.22
            v += (target - v) * (1 - exp(-dt / tau))
        }
        ema(&level, target)
        ema(&bass, bassTarget)
        return (level, bass)
    }
}
