// DALI — "The Room", top-down like the original room setup: desk at the top with
// the DALI Opticon 2s flanking the monitor, the listener in the middle, Sonos
// Era 100s at the back corners. Recovery is silent, so a pair that drops or
// rejoins never flashes a warning color: it just stays calm and blue.
//
// The canvas is drawn in the app icon's language ("Meridian"): a dawn horizon,
// where light pools low and diffuses upward from warm-white through #4C8DFF
// into near-black, built from layered gradients and blur rather than strokes.
// So: no outlined boxes. Cabinets sit in pools of light and catch a rim on the
// side facing the room; the wave arcs are diffused light, not drawn lines.
//
// Two rules the drawing must never break:
//   1. The wave clock is CONSTANT (`progress = (t/3.4 + offset) mod 1`). Audio
//      level modulates amplitude only — reach, alpha, width, blur. If the clock
//      ever depended on level, the rings would jump on every volume change.
//      Every other clock in here (the 4.2 s breath, the one-shot rings) is a
//      separate constant clock too, deliberately incommensurate with 3.4 s so
//      the room never develops a visible beat.
//   2. Room spacing uses Phi; speaker footprints use the actual products:
//      Opticon 2 MK2 is 195 × 297 mm, Era 100 is 120 × 130.5 mm.
//
// Blur budget: exactly TWO blurred layers per frame (the shared wave halo and
// the horizon bloom). Everything else that needs to look soft is a widening
// stroke or a gradient. Do not add a third. The whole start-up sequence — the
// horizon rising, the beams, the ignitions, the sustain wavefront — is drawn
// inside that same budget.
//
// Nothing in here is allowed to change in a single frame. A Canvas cannot use
// `.animation`, so every transition is computed from elapsed time and shaped by
// one of the easing curves at the bottom of the file. If a value steps — a
// pair going live, a pair being switched off, the start-up handing over to the
// live room — that is a bug, not a style choice.

import SwiftUI

struct RoomView: View {
    @Environment(DALIStore.self) private var store
    @State private var showOtherSpeakers = false

    var body: some View {
        VStack(spacing: 13) {
            Group {
                if store.front != nil || store.back != nil {
                    RoomCanvas()
                } else {
                    SpeakerCollectionView()
                }
            }
                // Flexible, not fixed. The room card is the only element in the
                // panel that can absorb the window's spare height, so the plan
                // gets the surplus instead of it settling as dead air above and
                // below the whole stack. 190 stays the floor (the old fixed
                // height); at the shipped 360×540 window it lands at 208, i.e.
                // 292×208 ≈ 1.40:1 — still plainly a room seen from above, and
                // the cabinets (fixed pt sizes, see `Cabinet`) are sized to be
                // the subject of it rather than markers on a map.
                //
                // Nothing in the drawing needs a fixed height: every position is
                // unit-space, the horizon and glow are expressed in `size`, and
                // the front/back tap split is `geo.size.height / 2`, so all of
                // it follows the canvas automatically.
                //
                // 176, not 190, since the now-playing line under the pairs can
                // be two rows (a held video and Spotify at once); the room
                // gives up the 24pt for as long as that lasts.
                .frame(minHeight: 176, maxHeight: .infinity)
            if let front = store.front {
                PairRow(speaker: front, title: "Front")
            }
            if let back = store.back {
                PairRow(speaker: back, title: "Back")
            }
            if (store.front != nil || store.back != nil), !store.extras.filter(\.enabled).isEmpty {
                Button {
                    showOtherSpeakers.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "hifispeaker.2")
                        Text("\(store.extras.filter(\.enabled).count) more speakers")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(.bodySmall).foregroundStyle(Color.paper60)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showOtherSpeakers) {
                    ScrollView {
                        VStack(spacing: 14) {
                            ForEach(store.extras.filter(\.enabled)) { speaker in
                                SpeakerControlRow(speaker: speaker)
                            }
                        }.padding(18)
                    }
                    .frame(width: 310, height: 280)
                    .background(Color.ink)
                }
            }
            SourceHint()
        }
        .padding(13)
        .background(
            DarkGlassSurface(cornerRadius: DS.cardRadius, tintAlpha: 0.72, clear: false)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cardRadius - 1.5, style: .continuous)
                        .inset(by: 1.5)
                        .fill(Color.field.opacity(0.84))
                )
                .shadow(color: .black.opacity(0.42), radius: 18, y: 8)
        )
        .animation(DS.spring, value: store.speakers.map(\.enabled))
    }
}

/// A neutral room for new installations. Existing front/back rooms keep their
/// familiar canvas, while other configurations show their actual speakers.
struct SpeakerCollectionView: View {
    @Environment(DALIStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your speakers").font(.serifSection).foregroundStyle(Color.paper)
                Spacer()
                Button {
                    Task { await store.refreshSpeakers() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(Color.paper60)
                }
                .buttonStyle(.plain)
                .disabled(store.isDiscovering)
                .help("Refresh speakers")
                .accessibilityLabel("Refresh speakers")
            }
            if store.speakers.isEmpty {
                Spacer()
                SpeakerIcon(kind: .pair)
                    .frame(maxWidth: .infinity)
                Text("Turn on your AirPlay speakers and connect them to the same network as this Mac.")
                    .font(.bodySmall).foregroundStyle(Color.paper60)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(store.speakers) { speaker in
                            SpeakerControlRow(speaker: speaker)
                        }
                    }.padding(.vertical, 4)
                }
            }
            if let message = store.discoveryMessage {
                Text(message).font(.badge).foregroundStyle(Color.paper60)
            }
        }
    }
}

struct SpeakerControlRow: View {
    @Environment(DALIStore.self) private var store
    let speaker: RoomSpeaker

    private var mustKeepPlaying: Bool {
        store.phase.isOn && speaker.enabled && speaker.available
            && store.speakers.filter { $0.enabled && $0.available }.count <= 1
    }

    private var status: String {
        guard speaker.available else { return "Unavailable" }
        guard speaker.enabled else { return "Ready to add" }
        switch speaker.health {
        case .off: return "Selected"
        case .connecting: return "Connecting"
        case .live: return "Playing"
        case .trouble: return "Needs attention"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                SpeakerIcon(kind: .compact, active: speaker.enabled && speaker.health == .live)
                VStack(alignment: .leading, spacing: 3) {
                    Text(speaker.name).font(.bodyMedium).foregroundStyle(Color.paper)
                        .lineLimit(1).help(speaker.name)
                    Text(status).font(.badge)
                        .foregroundStyle(speaker.available ? Color.paper60 : Color.amber)
                }
                Spacer(minLength: 4)
                Toggle(speaker.name, isOn: Binding(
                    get: { speaker.enabled },
                    set: { if $0 != speaker.enabled { store.toggle(speaker) } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .tint(Color.accentBlue)
                    .disabled(store.phase == .starting || mustKeepPlaying
                              || (!speaker.available && !speaker.enabled))
                    .help(mustKeepPlaying ? "Stop room audio to switch off the last speaker" : "Use this speaker")
                    .accessibilityLabel("Use \(speaker.name)")
            }
            if speaker.enabled {
                HStack(spacing: 10) {
                    HSlider(value: Binding(get: { speaker.relVolume },
                                           set: { store.setRelVolume($0, for: speaker) }),
                            active: speaker.available)
                        .accessibilityLabel("\(speaker.name) volume")
                    Text("\(Int(speaker.relVolume))")
                        .font(.serif(12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Color.paper60).frame(width: 24, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - the canvas

struct RoomCanvas: View {
    @Environment(DALIStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Speaker positions in unit space, mirroring the real room.
    private let frontL = CGPoint(x: 0.16, y: 0.20)
    private let frontR = CGPoint(x: 0.84, y: 0.20)
    private let backL  = CGPoint(x: 0.14, y: 0.84)
    private let backR  = CGPoint(x: 0.86, y: 0.84)
    private let listener = CGPoint(x: 0.5, y: Phi.inv)

    // The store's levels tick at ~15 Hz; the canvas draws at 30. These EMAs
    // (reference types so the draw closure can step them) smooth the staircase
    // into a continuous signal. Amplitude only — the wave clock is untouched.
    private let levelEMA = LevelEMA()
    private let bassEMA = LevelEMA()
    private let trebleEMA = LevelEMA()
    private let frameClock = FrameDateBox()

    // Micro-animation state. The room is FIXED — the same two pairs in the same
    // corners, forever — so none of this needs to live in the store or be keyed
    // by identity. All the canvas needs is a handful of timestamps to measure
    // elapsed time from, and it derives them here from the store's own flags.
    //
    // `appearedAt` is a @State initialiser rather than an `.onAppear`: state is
    // created before the first draw, so the staging can never miss a frame and
    // flash the room in fully-lit before animating it in.
    @State private var appearedAt = Date()
    @State private var settled = false          // staging finished; may pause again
    @State private var frontArrivalAt: Date?
    @State private var backArrivalAt: Date?
    @State private var frontDepartAt: Date?
    @State private var backDepartAt: Date?
    @State private var frontEnabledAt: Date?
    @State private var backEnabledAt: Date?
    @State private var frontRippleAt: Date?
    @State private var backRippleAt: Date?
    /// When the room last played a beat. The arcs travel on their own constant
    /// clock (that rule is not negotiable — see the header), so the thing that
    /// actually moves WITH the music is this: one soft pulse leaving each
    /// cabinet as the beat arrives, drawn with the same one-shot primitive the
    /// connect ring and the volume ripple already use.
    @State private var beatAt: Date?

    // Start-up. `startingAt` is when the room entered `.starting`; `bootEndedAt`
    // is when it left, which the boot state uses to hand its light over to the
    // live room (or to give it back to the dark) instead of cutting.
    @State private var startingAt: Date?
    @State private var bootEndedAt: Date?
    /// Keeps the timeline awake past a phase change so a fade-out can finish
    /// instead of freezing half-lit the moment `animating` goes false.
    @State private var coasting = false

    /// Everything a pair needs to draw itself, resolved once per frame so the
    /// passes below (waves, rings, pools, cabinets) all agree.
    private struct Pair {
        var positions: [CGPoint]
        var cabinet: Cabinet
        var present: Bool
        /// Whether the pair is part of the stream set, 0…1 and continuous: a
        /// pair toggled off dims away over a third of a second rather than
        /// dropping a step of brightness in one frame.
        var activeness: Double
        /// How live the pair is, 0…1 and CONTINUOUS: it eases up from the
        /// moment the session connects and eases back down when it drops, so
        /// nothing about a cabinet's light ever changes in a single frame.
        var presence: Double
        /// Per-position start-up arming, 0…1. The boot beams land one cabinet
        /// at a time, so these two are not in step with each other.
        var wakes: [Double]
        /// Per-position ignition flash, 0…1 while it runs.
        var flashes: [Double?]
        var energy: Double
        /// Brightness multiplier for the rim and the pool: the silent-room
        /// breath and the trouble dim/flicker both land here. Light only.
        var glow: Double
        var arrival: Double?    // 0…1 while the connect ring runs, else nil
        var ripple: Double?     // 0…1 while the volume ripple runs, else nil
        var beat: Double?       // 0…1 while a beat pulse runs, else nil
        var stage: Stage

        /// The one number the cabinet and its pool are drawn from: live light,
        /// or the start-up's light while the room is still connecting.
        func lit(_ i: Int) -> Double { max(presence, wakes[i] * 0.92) }
    }

    /// The per-frame clocks, bundled so `pair(_:)` keeps a readable signature.
    private struct Beat {
        var t: TimeInterval
        var now: Date
        var breath: Double
        var motion: Bool
    }

    // MARK: - the start-up

    /// One cabinet's share of the power-up: the light travelling to it, the
    /// cabinet arming as that light lands, and the flash at the moment it does.
    private struct BeamState {
        var travel: Double      // 0…1, eased position of the head along the path
        var retract: Double     // 0…1, the tail catching up after arrival
        var alpha: Double       // trail brightness (decays once it has landed)
        var wake: Double        // 0…1, the cabinet armed
        var flash: Double?      // 0…1 while the ignition pulse runs
    }

    /// The whole start-up choreography, resolved once per frame.
    ///
    /// It is one scripted movement — horizon, desk, four beams, four ignitions,
    /// about 2.2 s — followed by an open-ended sustain, because a real AirPlay
    /// handshake takes anywhere from two seconds to ten and the room must not
    /// look frozen while it waits. Every value here is derived from elapsed
    /// time and shaped by an easing curve; nothing steps.
    private struct Boot {
        var t: Double           // seconds since the room started connecting
        var fade: Double        // 1 while connecting, easing to 0 on hand-over
        var horizon: Double     // 0…1, the field charging
        var desk: Double        // 0…1, the monitor kindling
        var beams: [BeamState]  // frontL, frontR, backL, backR
        var sweep: Double?      // 0…1, a wavefront crossing the room, else nil
        var sustain: Double     // 0…1, how far into the open-ended wait we are
    }

    // Beam schedule. The front pair leaves the desk almost together, the way a
    // stereo pair is addressed; the rears follow a third of a second later.
    private static let beamStart: [Double] = [0.42, 0.52, 0.86, 0.96]
    private static let beamTravel = 0.68
    private static let beamDecay = 0.34
    private static let igniteDur = 0.60
    private static var bootScripted: Double { beamStart[3] + beamTravel + igniteDur }

    private func bootState(now: Date, motion: Bool) -> Boot? {
        guard motion, let startingAt else { return nil }
        var fade = 1.0
        if store.phase != .starting {
            guard let ended = bootEndedAt else { return nil }
            let d = now.timeIntervalSince(ended)
            guard d < 0.62 else { return nil }
            fade = 1 - easeInOutCubic(d / 0.62)
        }
        let t = now.timeIntervalSince(startingAt)

        let beams = Self.beamStart.map { start -> BeamState in
            let e = t - start
            guard e > 0 else { return BeamState(travel: 0, retract: 0, alpha: 0, wake: 0, flash: nil) }
            let travel = easeInOutCubic(clamp01(e / Self.beamTravel))
            let after = e - Self.beamTravel
            // The trail keeps its brightness until the head lands, then the
            // whole thing is drawn into the cabinet rather than switched off.
            let decay = after <= 0 ? 1 : 1 - easeInCubic(clamp01(after / Self.beamDecay))
            let retract = after <= 0 ? 0 : easeOutCubic(clamp01(after / Self.beamDecay))
            let wake = after <= 0 ? 0 : easeOutCubic(clamp01(after / Self.igniteDur))
            let flash = (after >= 0 && after < Self.igniteDur) ? after / Self.igniteDur : nil
            return BeamState(travel: travel, retract: retract, alpha: decay,
                             wake: wake, flash: flash)
        }

        // The sustain: once the scripted part is done, a slow wavefront leaves
        // the desk every 2.6 s and dissolves at the back wall, so a long
        // handshake reads as the room still working rather than stalled.
        let held = t - Self.bootScripted
        var sweep: Double?
        if held > 0 {
            sweep = (held / 2.6).truncatingRemainder(dividingBy: 1)
        }
        // The desk gathers light, gives it away, and settles back — it does not
        // simply stay at full brightness for the rest of the handshake.
        let deskUp = easeOutCubic(clamp01((t - 0.10) / 0.62))
        let deskSettle = 1 - 0.52 * easeInOutCubic(clamp01((t - 1.15) / 0.95))
        return Boot(t: t, fade: fade,
                    horizon: easeInOutCubic(clamp01(t / 0.90)),
                    desk: deskUp * deskSettle,
                    beams: beams, sweep: sweep,
                    sustain: clamp01(held / 0.5))
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { timeline in
                Canvas { ctx, size in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let dt = frameClock.date.map { max(0, timeline.date.timeIntervalSince($0)) } ?? (1.0 / 30.0)
                    frameClock.date = timeline.date
                    let level = levelEMA.step(toward: store.audioLevel, dt: dt)
                    let bass = bassEMA.step(toward: store.bassLevel, dt: dt)
                    let treble = trebleEMA.step(toward: store.trebleLevel, dt: dt)

                    func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
                    let me = pt(listener)
                    let motion = !reduceMotion

                    // Window-open staging. One shared elapsed clock; each element
                    // reads its own slot off it, 90 ms apart. Once `settled` we
                    // hand back infinity so every element draws fully arrived and
                    // the timeline is free to pause again.
                    let since = (motion && !settled)
                        ? timeline.date.timeIntervalSince(appearedAt)
                        : .infinity
                    let deskIn = staged(since, slot: 0)
                    let frontIn = staged(since, slot: 1)
                    let backIn = staged(since, slot: 2)
                    let meIn = staged(since, slot: 3)

                    // The breath: 4.2 s against the wave clock's 3.4 s. The ratio
                    // is deliberately not a whole number, so the two never
                    // phase-lock into a visible pulse.
                    let beat = Beat(t: t, now: timeline.date,
                                    breath: 0.5 + 0.5 * sin(t * 2 * .pi / 4.2),
                                    motion: motion)
                    let boot = bootState(now: timeline.date, motion: motion)
                    let corners = [pt(frontL), pt(frontR), pt(backL), pt(backR)]

                    let pairs = [
                        pair(store.front, [corners[0], corners[1]], .opticon2, level: level,
                             beat: beat, arrivalAt: frontArrivalAt, departAt: frontDepartAt,
                             enabledAt: frontEnabledAt,
                             rippleAt: frontRippleAt, beatAt: beatAt,
                             stage: frontIn, boot: boot, slot: 0),
                        pair(store.back, [corners[2], corners[3]], .era100, level: level,
                             beat: beat, arrivalAt: backArrivalAt, departAt: backDepartAt,
                             enabledAt: backEnabledAt,
                             rippleAt: backRippleAt, beatAt: beatAt,
                             stage: backIn, boot: boot, slot: 1),
                    ].compactMap { $0 }

                    // How lit the room is as a whole, 0…1 and continuous: the
                    // live pairs, or the start-up's own light while connecting.
                    let roomLight = max(pairs.map(\.presence).max() ?? 0,
                                        (boot.map { $0.horizon * $0.fade * 0.55 } ?? 0))

                    // 1. The field. A dawn horizon under everything else, and
                    // the first thing the start-up brings up.
                    drawHorizon(ctx, size: size, level: level,
                                light: max(store.phase == .streaming ? 1 : 0, roomLight),
                                // 1 is the settled horizon; only a running
                                // start-up ever pulls it back below that.
                                charge: boot.map { 1 - (1 - $0.horizon) * $0.fade } ?? 1,
                                stage: deskIn.opacity)

                    // 2. A single soft room glow centered on the listener. It
                    // breathes very gently with the music so the room feels
                    // alive without ever looking busy. Dark when nothing streams.
                    if roomLight > 0.01 {
                        let glowR = size.height * (Phi.inv + 0.12 * level + 0.06 * bass)
                        ctx.fill(Path(ellipseIn: CGRect(x: me.x - glowR, y: me.y - glowR,
                                                        width: glowR * 2, height: glowR * 2)),
                                 with: .radialGradient(
                                    Gradient(colors: [.accentBlue.opacity((0.05 + 0.035 * level) * meIn.opacity * roomLight), .clear]),
                                    center: me, startRadius: 0, endRadius: glowR))
                    }

                    // 2b. The stereo image. Where the two fronts agree there is
                    // a soft pool just ahead of the chair: the Meridian ramp
                    // lying flat on the floor, warm at the centre and blue by
                    // the edge. Level widens it; the front pair's light lights it.
                    if let front = pairs.first(where: { $0.cabinet == .opticon2 }) {
                        drawStage(ctx, size: size, at: me, level: level, bass: bass,
                                  light: front.presence * front.activeness * meIn.opacity)
                    }

                    // 3. Desk and monitor — the source of the start-up light.
                    drawDesk(ctx, size: size, level: level, stage: deskIn,
                             wake: boot.map { $0.desk * $0.fade } ?? 0)

                    // 3b. The sustain wavefront, while the handshake runs long.
                    if let boot, let sweep = boot.sweep {
                        drawSweep(ctx, size: size, progress: sweep,
                                  alpha: 0.140 * boot.fade * boot.sustain * deskIn.opacity)
                    }

                    // 4. Waves, in two passes. Every halo in the room shares ONE
                    // blurred layer — that is the whole per-frame blur budget for
                    // the waves, instead of one layer per arc. The crisp cores go
                    // on top unblurred.
                    if pairs.contains(where: { $0.energy > 0.01 }) {
                        ctx.drawLayer { layer in
                            layer.addFilter(.blur(radius: 6))
                            for p in pairs {
                                drawWaves(layer, size: size, pair: p, t: t,
                                          bass: bass, treble: treble, halo: true)
                            }
                        }
                        for p in pairs {
                            drawWaves(ctx, size: size, pair: p, t: t,
                                      bass: bass, treble: treble, halo: false)
                        }
                    }

                    // 5. The start-up beams: light leaving the desk for one
                    // cabinet at a time, drawn under the cabinets so each head
                    // is absorbed by the box it arrives at.
                    if let boot {
                        for (i, beam) in boot.beams.enumerated() {
                            drawBeam(ctx, from: CGPoint(x: size.width * 0.5, y: size.height * 0.13),
                                     to: corners[i], bow: Self.beamBow[i],
                                     state: beam, opacity: boot.fade * deskIn.opacity)
                        }
                    }

                    // 6. One-shot pulses: the room waking up when a pair goes
                    // live, the cabinet igniting as the start-up light lands,
                    // and a nudged slider. All three are cheap widening strokes
                    // rather than a blur layer, so the budget stays at two. They
                    // travel along the TRUE aim, like the waves.
                    for p in pairs {
                        for (i, pos) in p.positions.enumerated() {
                            let aim = atan2(me.y - pos.y, me.x - pos.x)
                            if let f = p.flashes[i] {
                                drawPulse(ctx, at: pos, aim: aim, progress: f,
                                          from: p.cabinet.reach * 0.7, to: p.cabinet.reach * 3.1,
                                          alpha: 0.52 * p.stage.opacity)
                            }
                            guard p.present else { continue }
                            if let a = p.arrival {
                                drawPulse(ctx, at: pos, aim: aim, progress: a,
                                          from: p.cabinet.reach, to: p.cabinet.reach * 3.4,
                                          alpha: 0.60 * p.stage.opacity)
                            }
                            if let r = p.ripple {
                                drawPulse(ctx, at: pos, aim: aim, progress: r,
                                          from: p.cabinet.reach * 0.8, to: p.cabinet.reach * 2.0,
                                          alpha: 0.46 * p.stage.opacity)
                            }
                            // The beat, scaled by how hard it hit.
                            if let bt = p.beat {
                                drawPulse(ctx, at: pos, aim: aim, progress: bt,
                                          from: p.cabinet.reach * 0.9, to: p.cabinet.reach * 2.6,
                                          alpha: 0.30 * (0.45 + 0.55 * bass) * p.presence * p.stage.opacity)
                            }
                        }
                    }

                    // 7. Cabinets, each sitting in its own pool of light.
                    for p in pairs { drawSpeakers(ctx, pair: p, aimAt: me, bass: bass) }

                    // 8. Listener: a quiet open ring facing the desk (137.5° —
                    // the golden angle), with a still point.
                    drawListener(ctx, at: me, level: level, stage: meIn, light: roomLight)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                // Top half toggles the front pair, bottom half the back pair.
                guard let front = store.front, let back = store.back else { return }
                store.toggle(location.y < geo.size.height / 2 ? front : back)
            }
        }
        // The staging is the one animation that has to run while the room is
        // idle, so the timeline stays awake for it and then lets itself pause.
        .task {
            // The window can be opened onto a room that is already connecting —
            // started from the menu bar, say — and `onChange` would never fire
            // for it. Pick the start-up up from where it is.
            if store.phase == .starting, startingAt == nil { startingAt = Date() }
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            settled = true
        }
        .onChange(of: frontIsLive) { _, live in
            frontArrivalAt = live ? Date() : nil
            frontDepartAt = live ? nil : Date()
        }
        .onChange(of: backIsLive) { _, live in
            backArrivalAt = live ? Date() : nil
            backDepartAt = live ? nil : Date()
        }
        .onChange(of: store.front?.enabled) { _, _ in frontEnabledAt = Date(); coast() }
        .onChange(of: store.back?.enabled) { _, _ in backEnabledAt = Date(); coast() }
        .onChange(of: store.beatCount) { _, _ in beatAt = Date() }
        .onChange(of: store.front?.relVolume) { _, _ in frontRippleAt = bumped(frontRippleAt) }
        .onChange(of: store.back?.relVolume) { _, _ in backRippleAt = bumped(backRippleAt) }
        // The start-up owns its own clock, so the canvas only needs the two
        // instants: when the room began connecting, and when it stopped.
        .onChange(of: store.phase) { old, new in
            if new == .starting {
                startingAt = Date()
                bootEndedAt = nil
            } else if old == .starting {
                bootEndedAt = Date()
            }
            coast()
        }
    }

    /// Hold the timeline open past a phase change. Without it the room can go
    /// `!animating` on the same frame a fade-out starts and freeze half-lit.
    private func coast() {
        coasting = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            coasting = false
        }
    }

    private var animating: Bool {
        store.phase == .streaming || store.phase == .starting
    }

    private var paused: Bool {
        if reduceMotion { return true }
        return !animating && settled && !coasting
    }

    private var frontIsLive: Bool {
        store.front?.enabled == true && store.phase == .streaming && store.front?.health == .live
    }
    private var backIsLive: Bool {
        store.back?.enabled == true && store.phase == .streaming && store.back?.health == .live
    }

    /// Ripple throttle. A continuous slider drag fires dozens of changes a
    /// second; restarting the ripple on each one smears it into a blur. Holding
    /// the previous start until the window has passed makes a drag pulse.
    private func bumped(_ last: Date?) -> Date? {
        let now = Date()
        if let last, now.timeIntervalSince(last) < 0.28 { return last }
        return now
    }

    private func pair(_ speaker: RoomSpeaker?, _ positions: [CGPoint],
                      _ cabinet: Cabinet, level: Double, beat: Beat,
                      arrivalAt: Date?, departAt: Date?, enabledAt: Date?,
                      rippleAt: Date?, beatAt: Date?, stage: Stage, boot: Boot?, slot: Int) -> Pair? {
        guard let speaker else { return nil }
        let active = speaker.enabled
        // Present while the session is up and this pair is enabled. Audible
        // health is separate: trouble dims energy; connecting is calm recovery.
        let present = active && store.phase == .streaming && speaker.health != .off
        let vol = Double(store.effectiveVolume(speaker)) / 100.0
        let trouble = present && speaker.health == .trouble

        // Being part of the stream set is a ramp too, on its own short clock.
        var activeness = active ? 1.0 : 0.0
        if beat.motion, let enabledAt {
            let p = easeInOutCubic(clamp01(beat.now.timeIntervalSince(enabledAt) / 0.35))
            activeness = active ? p : 1 - p
        }

        // Presence: the pair's own light, eased in from the instant its session
        // connected and eased back out when it drops. Every brightness in the
        // cabinet, the rim and the pool is a function of this, so going live is
        // a half-second of light arriving rather than a state swap.
        var presence: Double
        if !beat.motion {
            presence = present ? 1 : 0
        } else if present {
            presence = arrivalAt.map {
                easeOutCubic(clamp01((beat.now.timeIntervalSince($0) - cabinet.arrivalDelay) / 0.55))
            } ?? 1
        } else if let departAt {
            presence = 1 - easeInOutCubic(clamp01(beat.now.timeIntervalSince(departAt) / 0.45))
        } else {
            presence = 0
        }

        // The start-up's share: this pair's two beams, and their ignitions.
        let wakes: [Double] = boot.map { b in
            [b.beams[slot * 2].wake * b.fade, b.beams[slot * 2 + 1].wake * b.fade]
        } ?? [0, 0]
        let flashes: [Double?] = boot.map { b in
            [b.beams[slot * 2].flash, b.beams[slot * 2 + 1].flash]
        } ?? [nil, nil]

        // Volume ripple, amplitude only: `sin(π·p)` swells in and back out, so
        // biasing the reach mid-flight never pops the arcs. The clock underneath
        // them is untouched.
        let ripple = shot(since: rippleAt, now: beat.now, duration: 0.40,
                          delay: 0, enabled: present && beat.motion)
        let rippleBias = ripple.map { sin(.pi * $0) * 0.11 } ?? 0

        // Energy rides the live level but stays gentle: this is ambience, not a
        // demo. It is scaled by presence, so the arcs reach out as the pair
        // connects instead of appearing at full length.
        // The music, mostly: a floor so a live room is never dead, then the
        // level — which is already relative to the record's own peaks — with
        // the volume slider only trimming it.
        var energy = ((0.12 + 0.88 * pow(level, 0.9)) * (0.55 + 0.45 * vol) + rippleBias) * presence
        if trouble { energy *= 0.45 }   // trouble loses reach as well as light

        // While connecting, the armed cabinets already breathe a short arc into
        // the room — the handshake made visible. `max` hands over to the live
        // energy without a seam once the stream is up.
        if let boot {
            let armed = (wakes[0] + wakes[1]) / 2
            energy = max(energy, armed * (0.085 + 0.045 * beat.breath) * boot.fade)
        }

        // Breathing. Live but nothing to hear: the rim and the pool rise and
        // fall on the breath so the room between tracks is still inhabited. It
        // fades out completely the moment there is any level at all — smoothly,
        // so a track starting does not snap the breath off.
        let quiet = presence * (beat.motion ? smoothstep(clamp01(1 - level / 0.06)) : 0)
        var glow = 1 + 0.26 * beat.breath * quiet
        // Trouble reads as light lost, never as a colour swap: dimmer, with a
        // slow uneven flicker from two incommensurate sines. Quiet, not alarming.
        if trouble {
            glow *= beat.motion ? 0.52 + 0.10 * sin(beat.t * 7.3) * sin(beat.t * 3.1) : 0.52
        }

        let arrival = shot(since: arrivalAt, now: beat.now, duration: 0.60,
                           delay: cabinet.arrivalDelay, enabled: beat.motion)

        // The rear pair is a beat behind the front the same way its arrival
        // ring is, so the pulse sweeps through the room rather than flashing.
        let beat = shot(since: beatAt, now: beat.now, duration: 0.46,
                        delay: cabinet.arrivalDelay, enabled: present && beat.motion)

        return Pair(positions: positions, cabinet: cabinet,
                    present: present, activeness: activeness, presence: presence,
                    wakes: wakes, flashes: flashes, energy: max(energy, 0),
                    glow: glow, arrival: arrival, ripple: ripple, beat: beat, stage: stage)
    }

    /// Elapsed-time progress for a one-shot animation, `nil` once it is over —
    /// which is also the signal not to draw it at all.
    private func shot(since: Date?, now: Date, duration: Double,
                      delay: Double, enabled: Bool) -> Double? {
        guard enabled, let since else { return nil }
        let e = now.timeIntervalSince(since) - delay
        guard e >= 0, e < duration else { return nil }
        return e / duration
    }

    // MARK: the field

    /// The Meridian horizon. Light pools along the low edge of the room and
    /// dissolves upward into near-black — the icon's construction, dialled down
    /// to a whisper so the plan stays readable. Only its brightness breathes
    /// with the level; nothing here is on a clock.
    private func drawHorizon(_ ctx: GraphicsContext, size: CGSize, level: Double,
                             light: Double, charge: Double, stage: Double) {
        let w = size.width, h = size.height
        let k = (0.55 + 0.45 * light) * stage

        // Stops are dense and near-exponential on purpose: a two-stop ramp this
        // shallow shows its slope change as a Mach band straight across the room.
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
            Gradient(stops: [
                .init(color: .accentBlue.opacity((0.055 + 0.020 * level) * k), location: 0),
                .init(color: .accentBlue.opacity((0.038 + 0.014 * level) * k), location: 0.16),
                .init(color: .accentBlue.opacity((0.021 + 0.007 * level) * k), location: 0.36),
                .init(color: .accentBlue.opacity(0.009 * k), location: 0.60),
                .init(color: .accentBlue.opacity(0), location: 1),
            ]),
            startPoint: CGPoint(x: w / 2, y: h),
            endPoint: CGPoint(x: w / 2, y: h * 0.04)))

        // The arc itself: one bloom rising off a curved horizon that sits below
        // the canvas, blurred so it has no edge anywhere. One layer, once.
        //
        // During the start-up the horizon literally rises: the arc's centre
        // begins a fifth of the canvas lower and eases up into place, so the
        // room's first move is dawn coming up under it.
        let c = CGPoint(x: w / 2, y: h * (1.34 + 0.20 * (1 - charge)))
        let r = h * 1.06
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: h * 0.09))
            layer.fill(
                Path(ellipseIn: CGRect(x: c.x - w * 0.78, y: c.y - r, width: w * 1.56, height: r * 2)),
                with: .radialGradient(Gradient(stops: [
                    .init(color: .warmWhite.opacity((0.075 + 0.03 * level) * k), location: 0.40),
                    .init(color: .accentBlue.opacity(0.055 * k), location: 0.62),
                    .init(color: .accentBlue.opacity(0), location: 1.0),
                ]), center: c, startRadius: 0, endRadius: r))
        }
    }

    /// The stereo image on the floor. No blur: one squashed radial, like the
    /// sweep, so the two-layer budget is untouched.
    private func drawStage(_ ctx: GraphicsContext, size: CGSize, at me: CGPoint,
                           level: Double, bass: Double, light: Double) {
        let rx = size.height * (0.30 + 0.14 * level + 0.05 * bass)
        let ry = rx * 0.46
        let a = (0.050 + 0.065 * level) * light
        guard a > 0.003 else { return }
        let s = ry / rx
        var g = ctx
        g.scaleBy(x: 1, y: s)
        let c = CGPoint(x: me.x, y: (me.y - size.height * 0.05) / s)
        g.fill(Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - rx, width: rx * 2, height: rx * 2)),
               with: .radialGradient(Gradient(stops: [
                .init(color: meridian(0.10, a), location: 0),
                .init(color: meridian(0.45, a * 0.45), location: 0.40),
                .init(color: meridian(0.85, a * 0.12), location: 0.72),
                .init(color: meridian(1.00, 0), location: 1),
               ]), center: c, startRadius: 0, endRadius: rx))
    }

    // MARK: waves

    /// Three slow arcs per speaker, phase-offset by 1/φ so they never bunch.
    /// The clock, the count and the angles are constant — a slider or a
    /// system-volume change never makes the rings jump. Only reach, brightness,
    /// width and the point on the Meridian ramp ride the music.
    ///
    /// `halo: true` draws the wide soft body (called inside the shared blur
    /// layer); `halo: false` draws the narrow core on top.
    private func drawWaves(_ ctx: GraphicsContext, size: CGSize, pair: Pair,
                           t: TimeInterval, bass: Double, treble: Double, halo: Bool) {
        guard pair.energy > 0.01 else { return }
        let energy = pair.energy
        let maxR = size.height * (Phi.inv4 + 0.5 * energy)
        let spread = Angle.degrees(42.5)   // 85° total ≈ 360/φ³
        let r0 = pair.cabinet.reach * 0.85

        for p in pair.positions {
            let g = ctx
            let baseAngle = Angle(radians: atan2(size.height * listener.y - p.y,
                                                 size.width * listener.x - p.x))
            for i in 0..<3 {
                // Smoothstepped, so the second and third arc fade in as the
                // music grows instead of appearing at a threshold.
                let gate = smoothstep(energy * 4 - Double(i))
                guard gate > 0.01 else { continue }
                let offset = (Double(i) * Phi.inv).truncatingRemainder(dividingBy: 1)
                let progress = ((t / 3.4) + offset).truncatingRemainder(dividingBy: 1)
                let r = r0 + maxR * progress
                // Brighter than before: the arcs are the music, and at a
                // normal listening level they have to be plainly there.
                let alpha = (1 - progress) * (0.22 + 0.62 * energy) * gate
                    * (1 + 0.15 * treble) * pair.stage.opacity
                // Travel along the Meridian ramp: warm-white leaving the baffle,
                // blue by mid-room, gone at the wall.
                let c = meridian(progress, min(alpha, 0.72) * (halo ? 0.7 : 1))
                var path = Path()
                path.addArc(center: p, radius: r,
                            startAngle: baseAngle - spread,
                            endAngle: baseAngle + spread,
                            clockwise: false)
                // Thinner core, wider and dimmer halo: a line of light, not
                // a drawn line.
                let width = halo ? 4.0 + 3.6 * energy + 2.4 * bass
                                 : 1.1 + 0.9 * energy + 0.5 * bass
                g.stroke(path,
                         with: arcShading(center: p, radius: r, base: baseAngle,
                                          spread: spread, color: c),
                         style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
    }

    // MARK: the start-up

    /// Which way each beam bows out of the desk. The fronts sag down into the
    /// room and come back up into the baffle; the rears swing wide along the
    /// side walls, which keeps them clear of the listener in the middle.
    private static let beamBow: [CGFloat] = [-0.15, 0.15, 0.19, -0.19]

    /// One run of light from the desk to a cabinet: a curved trail with a warm
    /// head, dissolved at the tail. Two strokes and one small radial stand in
    /// for a blur, so the per-frame blur budget is untouched.
    private func drawBeam(_ ctx: GraphicsContext, from a: CGPoint, to b: CGPoint,
                          bow: CGFloat, state: BeamState, opacity: Double) {
        let alpha = state.alpha * opacity
        guard alpha > 0.008, state.travel > 0.001 else { return }
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 1)
        let ctrl = CGPoint(x: (a.x + b.x) / 2 - dy * bow,
                           y: (a.y + b.y) / 2 + dx * bow)
        func at(_ u: CGFloat) -> CGPoint {
            let v = 1 - u
            return CGPoint(x: v * v * a.x + 2 * v * u * ctrl.x + u * u * b.x,
                           y: v * v * a.y + 2 * v * u * ctrl.y + u * u * b.y)
        }
        let head = CGFloat(state.travel)
        // A trail about a third of the path long, which the cabinet then draws
        // in: `retract` walks the tail up to the head after the light lands.
        let span = 0.34 * (1 - CGFloat(state.retract))
        let tail = max(0, head - span)
        var path = Path()
        path.move(to: at(tail))
        var u = tail
        while u < head {
            u = min(u + 0.025, head)
            path.addLine(to: at(u))
        }
        let p0 = at(tail), p1 = at(head)
        // Light cools as it travels: the ramp runs from mid-blue at the tail to
        // warm-white at the head, so the head reads as the light itself.
        func shade(_ k: Double) -> GraphicsContext.Shading {
            .linearGradient(Gradient(stops: [
                .init(color: meridian(0.85, 0), location: 0),
                .init(color: meridian(0.55, alpha * 0.34 * k), location: 0.46),
                .init(color: meridian(0.08, alpha * k), location: 1),
            ]), startPoint: p0, endPoint: p1)
        }
        ctx.stroke(path, with: shade(0.34),
                   style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
        ctx.stroke(path, with: shade(1.0),
                   style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))

        // The head itself, kept small so it reads as a moving point of light
        // and not as a second speaker travelling across the room.
        let hr = 5.5 + 2.0 * CGFloat(1 - state.retract) * CGFloat(len / 260)
        ctx.fill(Path(ellipseIn: CGRect(x: p1.x - hr, y: p1.y - hr, width: hr * 2, height: hr * 2)),
                 with: .radialGradient(Gradient(stops: [
                    .init(color: meridian(0.00, alpha * 0.80), location: 0),
                    .init(color: meridian(0.30, alpha * 0.30), location: 0.42),
                    .init(color: meridian(0.75, 0), location: 1),
                 ]), center: p1, startRadius: 0, endRadius: hr))
    }

    /// The sustain wavefront: a wide, very soft band of light that leaves the
    /// desk and dissolves at the back wall, once every 2.6 s, for as long as the
    /// handshake takes. It exists so a slow connect reads as the room working.
    private func drawSweep(_ ctx: GraphicsContext, size: CGSize,
                           progress: Double, alpha: Double) {
        // Eased travel plus a swell that opens and closes, so it has no start
        // edge and no stop — it emerges from the desk and dissolves.
        let p = easeInOutSine(progress)
        let a = alpha * bump(progress)
        guard a > 0.004 else { return }
        let y = size.height * (0.12 + 0.92 * p)
        let rx = size.width * 0.78, ry = size.height * 0.17
        // One radial, squashed on Y into a band: a circular gradient inside an
        // ellipse would leave a visible seam where the shape outruns the light.
        let s = ry / rx
        var g = ctx
        g.scaleBy(x: 1, y: s)
        let c = CGPoint(x: size.width / 2, y: y / s)
        g.fill(Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - rx, width: rx * 2, height: rx * 2)),
               with: .radialGradient(Gradient(stops: [
                .init(color: meridian(0.10 + 0.5 * p, a), location: 0),
                .init(color: meridian(0.35 + 0.5 * p, a * 0.45), location: 0.42),
                .init(color: meridian(0.70 + 0.3 * p, a * 0.12), location: 0.72),
                .init(color: meridian(1.00, 0), location: 1),
               ]), center: c, startRadius: 0, endRadius: rx))
    }

    // MARK: cabinets

    private func drawSpeakers(_ ctx: GraphicsContext, pair: Pair, aimAt me: CGPoint, bass: Double) {
        for (i, p) in pair.positions.enumerated() {
            let aim = atan2(me.y - p.y, me.x - p.x)
            let lit = pair.lit(i)

            // The pool — the eclipse. Horizon light gathering around the
            // cabinet and thrown into the room, pushed slightly along the true
            // aim the way a real speaker throws. It is the Meridian ramp itself,
            // radiating: warm at the box, blue by the edge, gone before the wall.
            //
            // Two things keep it from washing the field grey at this size. The
            // profile PEAKS just outside the silhouette (location 0.13) and
            // falls off convexly from there, so the light reads as a corona
            // around a dark object rather than a lit disc; and the outer half of
            // the ramp is worth only a few percent alpha, which is what keeps
            // near-black near-black. Seven stops, because at this radius five
            // still shows the slope changes as rings.
            if lit > 0.005 || pair.activeness > 0.01 {
                let e = pair.energy
                let a = (0.018 + 0.030 * pair.activeness + 0.150 * lit + 0.150 * e)
                    * pair.glow * pair.stage.opacity
                let pr = (pair.cabinet.pool * (0.70 + 0.30 * lit) + 38.0 * e + 6.0 * bass)
                    * pair.stage.scale
                let c = CGPoint(x: p.x + cos(aim) * pr * 0.14, y: p.y + sin(aim) * pr * 0.14)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - pr, y: c.y - pr, width: pr * 2, height: pr * 2)),
                         with: .radialGradient(Gradient(stops: [
                            .init(color: meridian(0.00, a * 0.86), location: 0.00),
                            .init(color: meridian(0.10, a), location: 0.13),
                            .init(color: meridian(0.30, a * 0.60), location: 0.28),
                            .init(color: meridian(0.48, a * 0.32), location: 0.44),
                            .init(color: meridian(0.66, a * 0.155), location: 0.60),
                            .init(color: meridian(0.84, a * 0.055), location: 0.78),
                            .init(color: meridian(1.00, 0), location: 1.00),
                         ]), center: c, startRadius: 0, endRadius: pr))

                // A tight warm core inside the pool. The cabinet covers most of
                // it, so what shows is the light spilling around the box — the
                // bright inner edge of the eclipse. It carries the contrast that
                // stops the big pool reading as haze.
                if lit > 0.01 {
                    let cr = pr * 0.42
                    let ca = (0.055 + 0.075 * lit + 0.06 * e) * pair.glow * pair.stage.opacity
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - cr, y: c.y - cr,
                                                    width: cr * 2, height: cr * 2)),
                             with: .radialGradient(Gradient(stops: [
                                .init(color: meridian(0.00, ca), location: 0.00),
                                .init(color: meridian(0.12, ca * 0.72), location: 0.38),
                                .init(color: meridian(0.34, ca * 0.24), location: 0.68),
                                .init(color: meridian(0.60, 0), location: 1.00),
                             ]), center: c, startRadius: 0, endRadius: cr))
                }
            }

            // Cabinets are modelled in local space with +Y pointing "forward",
            // then rotated into place. Forward is NOT the full aim: nobody
            // swivels a bookshelf hard at the chair. The body sits at its rest
            // heading plus a fraction of the way toward the listener — see
            // `Cabinet.toeInFraction`. The waves above already left along the
            // true aim, so the room still points at you; only the box is calm.
            let rest = pair.cabinet.restAim
            let facing = rest + shortestAngle(aim - rest) * pair.cabinet.toeInFraction
            // The ignition breathes the box a few percent bigger and back as the
            // light lands on it. `bump` is zero-slope at both ends, so it swells
            // and settles without a kick.
            let kick = pair.flashes[i].map { 1 + 0.055 * bump($0) } ?? 1

            var g = ctx
            g.opacity = pair.stage.opacity
            g.translateBy(x: p.x, y: p.y)
            g.rotate(by: .radians(facing - .pi / 2))
            g.scaleBy(x: pair.stage.scale * kick, y: pair.stage.scale * kick)
            switch pair.cabinet {
            case .opticon2: drawOpticon2(g, lit: lit, on: pair.activeness, glow: pair.glow)
            case .era100:   drawEra100(g, lit: lit, on: pair.activeness, glow: pair.glow)
            }
        }
    }

    /// The connect pulse and the volume ripple, drawn the same way: one wide arc
    /// that expands away from the cabinet and dissolves.
    ///
    /// It is an ARC, not a ring, for the same reason the waves are: a closed
    /// circle around a speaker reads as a selection outline, and this drawing
    /// has no outlines anywhere. So it borrows the waves' own construction —
    /// centred on the true aim, ends dissolved by `arcShading` — just wider and
    /// one-shot. The envelope rises over the first fifth before it decays, so
    /// it never snaps on at full brightness either.
    ///
    /// Two widening strokes stand in for a blur, which keeps the per-frame blur
    /// budget at exactly two layers.
    private func drawPulse(_ ctx: GraphicsContext, at p: CGPoint, aim: Double,
                           progress: Double, from r0: CGFloat, to r1: CGFloat,
                           alpha: Double) {
        // Expansion eases out hard — light leaves fast and slows as it thins —
        // while the envelope rises smoothly and then decays.
        let e = easeOutCubic(progress)
        let a = alpha * smoothstep(progress / 0.22) * pow(1 - progress, 1.4)
        guard a > 0.004 else { return }
        let r = r0 + (r1 - r0) * e
        let base = Angle(radians: aim)
        let spread = Angle.degrees(100)             // 200° — a wake, not a beam
        var path = Path()
        path.addArc(center: p, radius: r, startAngle: base - spread,
                    endAngle: base + spread, clockwise: false)
        ctx.stroke(path, with: arcShading(center: p, radius: r, base: base,
                                          spread: spread, color: meridian(e, a * 0.62)),
                   style: StrokeStyle(lineWidth: 5.0, lineCap: .round))
        ctx.stroke(path, with: arcShading(center: p, radius: r, base: base,
                                          spread: spread, color: meridian(e, a)),
                   style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
    }

    /// Opticon 2 MK2, seen from above: satin cabinet, shallow baffle bevel
    /// and a separate fabric grille edge. Drivers are on the vertical face.
    private func drawOpticon2(_ ctx: GraphicsContext, lit: Double, on: Double, glow: Double) {
        let d: CGFloat = Cabinet.opticon2.depth
        let hw: CGFloat = Cabinet.opticon2.width / 2
        let fx = hw * 0.97, bx = hw
        let fy = d / 2, by = -d / 2
        let rf: CGFloat = 1.6, rb: CGFloat = 0.8

        var body = Path()
        body.move(to: CGPoint(x: -fx + rf, y: fy))
        body.addLine(to: CGPoint(x: fx - rf, y: fy))
        body.addQuadCurve(to: CGPoint(x: fx, y: fy - rf), control: CGPoint(x: fx, y: fy))
        body.addLine(to: CGPoint(x: bx, y: by + rb))
        body.addQuadCurve(to: CGPoint(x: bx - rb, y: by), control: CGPoint(x: bx, y: by))
        body.addLine(to: CGPoint(x: -bx + rb, y: by))
        body.addQuadCurve(to: CGPoint(x: -bx, y: by + rb), control: CGPoint(x: -bx, y: by))
        body.addLine(to: CGPoint(x: -fx, y: fy - rf))
        body.addQuadCurve(to: CGPoint(x: -fx + rf, y: fy), control: CGPoint(x: -fx, y: fy))
        body.closeSubpath()

        // Dark wood-veneer cabinet: it only lifts where the room light reaches it.
        ctx.fill(body, with: .linearGradient(Gradient(colors: [.ink, .field]),
                                             startPoint: CGPoint(x: 0, y: fy),
                                             endPoint: CGPoint(x: 0, y: by)))

        // The lacquered top. At this size a flat black rectangle with a lit
        // edge stops reading as a cabinet — it reads as a phone lying face
        // down. What fixes it is form, not outline: one broad off-axis wash so
        // the top has a light side and a dark side, and a lengthwise gradient
        // so the front of the box is nearer the room light than the back.
        // Clipped to the body, so the silhouette keeps its soft edge.
        var top = ctx
        top.clip(to: body)
        let key = (0.085 + 0.075 * lit) * glow
        let sc = CGPoint(x: -hw * 0.40, y: fy * 0.26)
        let sr = d * 0.62
        top.fill(Path(ellipseIn: CGRect(x: sc.x - sr, y: sc.y - sr, width: sr * 2, height: sr * 2)),
                 with: .radialGradient(Gradient(stops: [
                    .init(color: .warmWhite.opacity(key), location: 0),
                    .init(color: .warmWhite.opacity(key * 0.44), location: 0.44),
                    .init(color: .warmWhite.opacity(0), location: 1),
                 ]), center: sc, startRadius: 0, endRadius: sr))
        top.fill(body, with: .linearGradient(Gradient(stops: [
            .init(color: .warmWhite.opacity(key * 0.62), location: 0),
            .init(color: .warmWhite.opacity(key * 0.16), location: 0.5),
            .init(color: .warmWhite.opacity(0), location: 1),
        ]), startPoint: CGPoint(x: 0, y: fy), endPoint: CGPoint(x: 0, y: by)))

        // Live bloom on the room-facing edge — the same construction as the Era
        // 100's, so both cabinets are lit by one light language. It follows the
        // body path, which means it wraps the softened front corners and dies
        // out along the sides. A straight lit line across the short edge, which
        // is what this was, reads as a phone lying face down; an edge catching
        // light reads as a speaker.
        if lit > 0.01 {
            ctx.stroke(body, with: .linearGradient(Gradient(stops: [
                .init(color: .accentBlue.opacity(0.21 * lit * glow), location: 0),
                .init(color: .accentBlue.opacity(0.045 * lit * glow), location: 0.22),
                .init(color: .accentBlue.opacity(0), location: 0.46),
            ]), startPoint: CGPoint(x: 0, y: fy), endPoint: CGPoint(x: 0, y: by)), lineWidth: 3.6)
        }

        strokeRim(ctx, body, front: fy, back: by,
                  alpha: rimAlpha(lit: lit, on: on) * glow, width: 1.1)

        let grille = Path(roundedRect: CGRect(x: -fx + 1.1, y: fy - 3.9,
                                              width: 2 * fx - 2.2, height: 3.0),
                          cornerRadius: 0.8)
        ctx.fill(grille, with: .color(.field.opacity(0.90)))
        // A few quiet fabric ribs remain legible at the native icon size.
        var weave = Path()
        for i in 0..<9 {
            let x = -fx + 2.3 + CGFloat(i) * (2 * fx - 4.6) / 8
            weave.move(to: CGPoint(x: x, y: fy - 3.3))
            weave.addLine(to: CGPoint(x: x, y: fy - 1.5))
        }
        ctx.stroke(weave, with: .color(.paper.opacity((0.10 + 0.07 * lit) * glow)), lineWidth: 0.45)

        // The front baffle is a separate plate, not an illuminated light bar.
        var seam = Path()
        seam.move(to: CGPoint(x: -fx + 1.5, y: fy - 4.4))
        seam.addLine(to: CGPoint(x: fx - 1.5, y: fy - 4.4))
        ctx.stroke(seam, with: .color(.paper.opacity((0.14 + 0.10 * lit) * glow)), lineWidth: 0.55)
    }

    /// Sonos Era 100 — 120 mm wide over 130.5 mm deep (Sonos' published spec:
    /// 182.5 × 120 × 130.5 mm), so seen from above it is essentially round, a
    /// hair deeper than it is wide. It is drawn at exactly that ratio.
    ///
    /// A flat matte oval top, recessed volume trough and small playback marks
    /// distinguish the Era from a spherical speaker or a bare driver cone.
    private func drawEra100(_ ctx: GraphicsContext, lit: Double, on: Double, glow: Double) {
        let w: CGFloat = Cabinet.era100.width, d: CGFloat = Cabinet.era100.depth   // 120 : 130.5
        let box = CGRect(x: -w / 2, y: -d / 2, width: w, height: d)
        // Corner radius is the full half-width, so the sides never go straight:
        // a pill that is all shoulder, which is what a matte cylinder looks like.
        let body = Path(roundedRect: box, cornerRadius: w / 2, style: .continuous)
        let fy = d / 2, by = -d / 2

        ctx.fill(body, with: .linearGradient(Gradient(colors: [.ink, .field]),
                                             startPoint: CGPoint(x: 0, y: fy),
                                             endPoint: CGPoint(x: 0, y: by)))

        // The sheen. One soft pool of light on the top surface, deliberately
        // pushed off both axes — forward toward the room and over to one side —
        // so it can never resolve into a ring or a centred dome. Clipped to the
        // body so the monolith keeps its uninterrupted edge.
        var top = ctx
        top.clip(to: body)
        let sc = CGPoint(x: -w * 0.19, y: d * 0.17)
        let sr = w * 0.82
        let keyIdle = 0.10 + 0.040 * on
        let key = (keyIdle + (0.19 - keyIdle) * lit) * glow
        top.fill(Path(ellipseIn: CGRect(x: sc.x - sr, y: sc.y - sr * 0.88,
                                        width: sr * 2, height: sr * 1.76)),
                 with: .radialGradient(Gradient(stops: [
                    .init(color: .warmWhite.opacity(key), location: 0),
                    .init(color: .warmWhite.opacity(key * 0.55), location: 0.42),
                    .init(color: .warmWhite.opacity(key * 0.16), location: 0.74),
                    .init(color: .warmWhite.opacity(0), location: 1),
                 ]), center: sc, startRadius: 0, endRadius: sr))
        // A second, much wider and fainter wash across the whole top. Without it
        // the body goes dead black between the sheen and the rim, and a black
        // disc under a bright crescent stops reading as a matte object.
        top.fill(body, with: .linearGradient(Gradient(stops: [
            .init(color: .warmWhite.opacity(key * 0.34), location: 0),
            .init(color: .warmWhite.opacity(key * 0.12), location: 0.55),
            .init(color: .warmWhite.opacity(0), location: 1),
        ]), startPoint: CGPoint(x: -w * 0.5, y: fy), endPoint: CGPoint(x: w * 0.5, y: by)))

        // Live bloom on the room-facing arc only — the gradient does the
        // masking, so there is never a uniform outline anywhere on this glyph.
        if lit > 0.01 {
            ctx.stroke(body, with: .linearGradient(Gradient(stops: [
                .init(color: .accentBlue.opacity(0.38 * lit * glow), location: 0),
                .init(color: .accentBlue.opacity(0.09 * lit * glow), location: 0.30),
                .init(color: .accentBlue.opacity(0), location: 0.58),
            ]), startPoint: CGPoint(x: 0, y: fy), endPoint: CGPoint(x: 0, y: by)), lineWidth: 3.6)
        }
        strokeRim(ctx, body, front: fy, back: by,
                  alpha: rimAlpha(lit: lit, on: on) * glow, width: 1.2)

        // Sonos' recessed volume slider lies across the rear half of the top.
        let trough = CGRect(x: -w * 0.30, y: -d * 0.21, width: w * 0.60, height: 2.0)
        ctx.fill(Path(roundedRect: trough, cornerRadius: 1), with: .color(.field.opacity(0.92)))
        var lip = Path()
        lip.move(to: CGPoint(x: trough.minX + 1, y: trough.maxY))
        lip.addLine(to: CGPoint(x: trough.maxX - 1, y: trough.maxY))
        let detail = (0.26 + 0.10 * lit) * glow
        ctx.stroke(lip, with: .color(.paper.opacity(detail * 0.52)), lineWidth: 0.45)
        var controls = Path()
        controls.move(to: CGPoint(x: -0.6, y: 1.0))
        controls.addLine(to: CGPoint(x: 0.9, y: 1.9))
        controls.addLine(to: CGPoint(x: -0.6, y: 2.8))
        controls.closeSubpath()
        ctx.fill(controls, with: .color(.paper.opacity(detail)))
        for x: CGFloat in [-4.2, 4.2] {
            ctx.fill(Path(ellipseIn: CGRect(x: x - 0.35, y: 1.6, width: 0.7, height: 0.7)),
                     with: .color(.paper.opacity(detail * 0.70)))
        }
    }

    /// A rim, not an outline: bright where the cabinet faces the room light,
    /// gone by the time it reaches the back wall.
    private func strokeRim(_ ctx: GraphicsContext, _ shape: Path,
                           front: CGFloat, back: CGFloat, alpha: Double,
                           width: CGFloat) {
        // Four stops, falling away fast: at the enlarged glyph size a rim that
        // is still 20% bright halfway round the shape stops being a catch of
        // light and becomes an outline, which this drawing does not have.
        ctx.stroke(shape, with: .linearGradient(Gradient(stops: [
            .init(color: .warmWhite.opacity(alpha), location: 0),
            .init(color: .warmWhite.opacity(alpha * 0.34), location: 0.30),
            .init(color: .warmWhite.opacity(alpha * 0.08), location: 0.58),
            .init(color: .warmWhite.opacity(0), location: 0.86),
        ]), startPoint: CGPoint(x: 0, y: front), endPoint: CGPoint(x: 0, y: back)),
        lineWidth: width)
    }

    /// The same three calm states as before — live, idle, disabled — except the
    /// step from idle to live is now a continuous ramp, so a pair connecting
    /// (or the start-up arming it) is light arriving, not a value changing.
    private func rimAlpha(lit: Double, on: Double) -> Double {
        let idle = 0.08 + 0.14 * on
        return idle + (0.44 - idle) * lit
    }

    // MARK: room furniture

    private func drawDesk(_ ctx: GraphicsContext, size: CGSize, level: Double,
                          stage: Stage, wake: Double) {
        let desk = CGRect(x: size.width * 0.26, y: size.height * 0.07,
                          width: size.width * 0.48, height: size.height * 0.20)
        let shape = Path(roundedRect: desk, cornerRadius: 5, style: .continuous)

        // Staging: scale about the desk's own centre so it settles in place
        // rather than sliding in from the origin.
        var ctx = ctx
        ctx.opacity = stage.opacity
        ctx.translateBy(x: desk.midX, y: desk.midY)
        ctx.scaleBy(x: stage.scale, y: stage.scale)
        ctx.translateBy(x: -desk.midX, y: -desk.midY)
        ctx.fill(shape, with: .linearGradient(
            Gradient(colors: [.warmWhite.opacity(0.026), .warmWhite.opacity(0)]),
            startPoint: CGPoint(x: desk.midX, y: desk.maxY),
            endPoint: CGPoint(x: desk.midX, y: desk.minY)))
        // The near edge catches the room light; the far edge dissolves.
        ctx.stroke(shape, with: .linearGradient(Gradient(stops: [
            .init(color: .warmWhite.opacity(0.115), location: 0),
            .init(color: .warmWhite.opacity(0.035), location: 0.5),
            .init(color: .warmWhite.opacity(0), location: 1),
        ]), startPoint: CGPoint(x: desk.midX, y: desk.maxY),
            endPoint: CGPoint(x: desk.midX, y: desk.minY)), lineWidth: 1)

        let monitor = CGRect(x: desk.midX - desk.width * 0.28, y: desk.minY + desk.height * 0.30,
                             width: desk.width * 0.56, height: 2.5)
        // The screen's own light spills toward the listener. `wake` is the
        // start-up kindling the desk: the spill widens and warms before any of
        // it leaves for the cabinets, so the light plainly has a source.
        //
        // It is a circular gradient squashed on Y, not a circular gradient
        // inside a wide ellipse — that shape outruns its own light and leaves a
        // hard elliptical edge sitting over the desk.
        let spillR = monitor.width * (0.62 + 0.20 * wake)
        let squash = (7.0 + 5.0 * wake) / spillR
        var spill = ctx
        spill.scaleBy(x: 1, y: squash)
        let sc = CGPoint(x: monitor.midX, y: (monitor.midY + 3) / squash)
        spill.fill(Path(ellipseIn: CGRect(x: sc.x - spillR, y: sc.y - spillR,
                                          width: spillR * 2, height: spillR * 2)),
                   with: .radialGradient(Gradient(stops: [
                    .init(color: .warmWhite.opacity(0.075 + 0.035 * level + 0.075 * wake), location: 0),
                    .init(color: .warmWhite.opacity(0.030 + 0.030 * wake), location: 0.42),
                    .init(color: .warmWhite.opacity(0.008 + 0.010 * wake), location: 0.72),
                    .init(color: .warmWhite.opacity(0), location: 1),
                   ]), center: sc, startRadius: 0, endRadius: spillR))
        let screen = 0.26 + 0.26 * wake
        ctx.fill(Path(roundedRect: monitor, cornerRadius: 1.25), with: .linearGradient(
            Gradient(colors: [.warmWhite.opacity(screen), .warmWhite.opacity(screen * 0.4)]),
            startPoint: CGPoint(x: monitor.minX, y: monitor.midY),
            endPoint: CGPoint(x: monitor.maxX, y: monitor.midY)))
    }

    /// The listener answers the level, but barely: a point or two of radius and
    /// a little more light. This has to read as someone present in the room, not
    /// as a VU meter, so every coefficient here is deliberately tiny.
    private func drawListener(_ ctx: GraphicsContext, at me: CGPoint, level: Double,
                              stage: Stage, light: Double) {
        var ctx = ctx
        ctx.opacity = stage.opacity
        let s = stage.scale
        // The listener is drawn a little bigger and brighter as the room comes
        // up, so the person in the chair is lit by it like everything else.
        let ring = (9.6 + 0.8 * level + 0.9 * light) * s
        let pool = (5.4 + 1.5 * level + 1.2 * light) * s
        let dot = (1.9 + 0.30 * level + 0.25 * light) * s

        var rest = Path()
        rest.addArc(center: me, radius: ring,
                    startAngle: .degrees(21.25), endAngle: .degrees(158.75), clockwise: false)
        ctx.stroke(rest, with: .linearGradient(Gradient(stops: [
            .init(color: .warmWhite.opacity(0.06), location: 0),
            .init(color: .warmWhite.opacity(0.34 + 0.10 * level), location: 0.5),
            .init(color: .warmWhite.opacity(0.06), location: 1),
        ]), startPoint: CGPoint(x: me.x - ring, y: me.y), endPoint: CGPoint(x: me.x + ring, y: me.y)),
        style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: me.x - pool, y: me.y - pool,
                                        width: pool * 2, height: pool * 2)),
                 with: .radialGradient(
                    Gradient(colors: [.warmWhite.opacity(0.16 + 0.12 * level), .clear]),
                    center: me, startRadius: 0, endRadius: pool))
        ctx.fill(Path(ellipseIn: CGRect(x: me.x - dot, y: me.y - dot,
                                        width: dot * 2, height: dot * 2)),
                 with: .color(.warmWhite.opacity(0.55 + 0.12 * level)))
    }
}

// MARK: - staging

/// One element's window-open state: it fades up and settles into place with a
/// small overshoot. Canvas drawing cannot use `.animation`, so this is computed
/// straight from elapsed time and applied as opacity + a scale transform.
private struct Stage {
    var opacity: Double
    var scale: CGFloat
    static let settled = Stage(opacity: 1, scale: 1)
}

/// `since` is seconds since the room appeared; `slot` is the element's place in
/// the 90 ms cascade (desk → front → back → listener). Infinity means settled.
private func staged(_ since: TimeInterval, slot: Int) -> Stage {
    guard since.isFinite else { return .settled }
    let p = clamp01((since - 0.09 * Double(slot)) / 0.46)
    // Opacity runs ahead of the scale on its own curve: the element is legible
    // early and then settles into place, instead of both landing at once.
    return Stage(opacity: easeOutCubic(min(p * 1.25, 1)),
                 scale: 0.88 + 0.12 * easeOutBack(p))
}

// MARK: - easing
//
// A Canvas cannot use `.animation`, so every transition in this file is
// computed from elapsed time and shaped by hand. These are the only shapes
// used, and which one is chosen is deliberate:
//
//   easeOutCubic    light arriving — fast then settling. The default here.
//   easeInOutCubic  something travelling a distance: leaves and stops calmly.
//   easeInCubic     something leaving: it lets go slowly, then goes.
//   easeOutBack     a small overshoot for an element landing in place.
//   easeInOutSine   the gentlest possible traverse; used for the slow sweep.
//   smoothstep      a gate that opens and closes without a corner.
//   bump            a swell out and back, zero-slope at both ends.
//
// Nothing in the drawing is allowed to be linear.

private func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

private func easeOutCubic(_ x: Double) -> Double {
    let v = clamp01(x); return 1 - pow(1 - v, 3)
}

private func easeInCubic(_ x: Double) -> Double {
    let v = clamp01(x); return v * v * v
}

private func easeInOutCubic(_ x: Double) -> Double {
    let v = clamp01(x)
    return v < 0.5 ? 4 * v * v * v : 1 - pow(-2 * v + 2, 3) / 2
}

private func easeInOutSine(_ x: Double) -> Double {
    -(cos(.pi * clamp01(x)) - 1) / 2
}

/// Ease-out with a soft overshoot — the back constant is well under the
/// textbook 1.70158, because at this scale a real overshoot reads as a bounce.
private func easeOutBack(_ x: Double) -> Double {
    let c1 = 1.15, c3 = c1 + 1
    let v = clamp01(x)
    return 1 + c3 * pow(v - 1, 3) + c1 * pow(v - 1, 2)
}

private func smoothstep(_ x: Double) -> Double {
    let v = clamp01(x); return v * v * (3 - 2 * v)
}

/// Out and back: 0 → 1 → 0 with zero slope at every end, so a one-shot swell
/// neither kicks on nor cuts off.
private func bump(_ x: Double) -> Double {
    let s = sin(.pi * clamp01(x)); return s * s
}

/// Shortest signed angle, so taking a fraction of a turn never goes the long
/// way round the circle.
private func shortestAngle(_ a: Double) -> Double {
    var x = a.truncatingRemainder(dividingBy: 2 * .pi)
    if x > .pi { x -= 2 * .pi }
    if x < -.pi { x += 2 * .pi }
    return x
}

// MARK: - Meridian light

/// Which cabinet a pair is. Silhouette is the whole point: hard box vs round
/// matte pill. The room is fixed — Opticons at the desk, Era 100s at the back
/// wall, forever — so each case can carry its own placement constants.
private enum Cabinet {
    case opticon2, era100

    /// Glyph size, in points, at the shipped ~292×208 canvas.
    ///
    /// Each footprint preserves the manufacturer's width/depth ratio. The Era
    /// gets a small optical enlargement so its top controls survive at 1×.
    ///
    /// Clearance at the shipped canvas, with toe-in applied: the front pair's
    /// rotated bounding radius is ~20 pt at x≈47, so ~27 pt from the left edge
    /// and ~9 pt from the desk; the rears are ~11 pt boxes, ~22 pt off the
    /// bottom edge and nowhere near the listener at mid-room.
    var depth: CGFloat { self == .opticon2 ? 34.0 : 24.8 }
    var width: CGFloat { self == .opticon2 ? depth * 195.0 / 297.0 : depth * 120.0 / 130.5 }

    /// Base radius of the cabinet's pool of light — the eclipse. Comfortably
    /// wider than the box so the falloff has somewhere to happen.
    var pool: CGFloat { self == .opticon2 ? 38.0 : 30.0 }

    /// Roughly the silhouette's outer radius: where a pulse should start from
    /// so it leaves the cabinet's edge rather than its middle.
    var reach: CGFloat { self == .opticon2 ? 17.0 : 11.0 }

    /// Where the cabinet points with NO toe-in at all: the front pair fires
    /// straight down the room from the desk, the rears straight up it from the
    /// back wall. Screen space, so +Y is toward the bottom of the canvas.
    var restAim: Double { self == .opticon2 ? .pi / 2 : -.pi / 2 }

    /// How much of the way from `restAim` to the true aim-at-the-listener angle
    /// the BODY is actually turned. Rotating by the full aim looks like the
    /// speakers have been swivelled hard at the chair, which nobody does. At
    /// the shipped canvas the geometry gives roughly a 49° full aim at the
    /// front and 66° at the back, so:
    ///   • 0.30 front → ~15° toe-in, which is what people actually do to a
    ///     pair of bookshelves either side of a monitor.
    ///   • 0.12 back  → ~8°, i.e. all but square to the wall; rear surrounds
    ///     get set down on a shelf and left there.
    /// Tune these two numbers and nothing else moves — the wave arcs always
    /// leave along the true aim, so the sound still travels to the listener.
    var toeInFraction: Double { self == .opticon2 ? 0.30 : 0.12 }

    /// Arrival-ring stagger: the desk pair wakes first, the back wall 80 ms
    /// later, so starting the stream sweeps through the room.
    var arrivalDelay: Double { self == .opticon2 ? 0 : 0.08 }
}

/// The Meridian ramp in one function: `d` is how far the light has travelled
/// (0 = at the source, 1 = dissolved). Warm-white #F2EDE3 → luminous #4C8DFF.
/// The 0.62 exponent keeps it warm a beat longer than linear, which is what
/// makes the icon's core read as light rather than as a colored line.
private func meridian(_ d: Double, _ alpha: Double) -> Color {
    let m = pow(min(max(d, 0), 1), 0.62)
    return Color(red: 0.949 + (0.298 - 0.949) * m,
                 green: 0.929 + (0.553 - 0.929) * m,
                 blue: 0.890 + (1.000 - 0.890) * m)
        .opacity(max(alpha, 0))
}

/// Shading that makes a wave arc read as diffused light instead of a drawn
/// line: brightest where it faces the listener, dissolved at both ends, so the
/// stroke never shows a start or a stop.
private func arcShading(center: CGPoint, radius: Double, base: Angle,
                        spread: Angle, color: Color) -> GraphicsContext.Shading {
    let a0 = base.radians - spread.radians
    let a1 = base.radians + spread.radians
    let p0 = CGPoint(x: center.x + radius * cos(a0), y: center.y + radius * sin(a0))
    let p1 = CGPoint(x: center.x + radius * cos(a1), y: center.y + radius * sin(a1))
    return .linearGradient(Gradient(stops: [
        .init(color: color.opacity(0), location: 0.0),
        .init(color: color.opacity(0.30), location: 0.18),
        .init(color: color, location: 0.5),
        .init(color: color.opacity(0.30), location: 0.82),
        .init(color: color.opacity(0), location: 1.0),
    ]), startPoint: p0, endPoint: p1)
}

// MARK: - level smoothing

/// Tiny reference-type EMA the Canvas draw closure can step per frame,
/// smoothing the store's ~15 Hz level updates into a continuous signal.
final class LevelEMA {
    var v = 0.0
    /// Fast up, slower down: a beat lands in a frame or two and then falls
    /// away, which is what the eye reads as "with the music".
    func step(toward target: Double, dt: Double) -> Double {
        let tau = target > v ? 0.025 : 0.16
        v += (target - v) * (1 - exp(-dt / tau)); return v
    }
}

/// Previous-frame timestamp holder so the EMAs know the real frame delta.
final class FrameDateBox { var date: Date? }

// MARK: - rows

struct PairRow: View {
    @Environment(DALIStore.self) private var store
    let speaker: RoomSpeaker
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            StateDot(speaker: speaker)
            Text(title)
                .font(.bodyMedium)
                .foregroundStyle(speaker.enabled ? Color.paper : Color.paper35)
                .frame(width: 92, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { store.toggle(speaker) }
                .help(speaker.available ? speaker.name : "\(speaker.name) is unavailable")

            HSlider(value: Binding(
                get: { speaker.relVolume },
                set: { store.setRelVolume($0, for: speaker) }),
                    active: speaker.enabled)
            let shownVolume = Int(speaker.relVolume)
            Text("\(shownVolume)")
                .font(.serif(12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.paper60)
                .frame(width: 24, alignment: .trailing)
                .contentTransition(.numericText(value: Double(shownVolume)))
                .animation(.snappy(duration: 0.2), value: shownVolume)
        }
        .opacity(speaker.enabled ? 1 : 0.6)
        .rowHover()
    }
}

// SPACE (deleted 2026-08-01). There used to be a third row here that trimmed
// the two pairs against each other by ear. It should never have existed.
//
// Both speakers negotiate AirPlay 2 and both lock to the same PTP grandmaster;
// an AirPlay 2 receiver is responsible for compensating its OWN output latency
// against the presentation timestamp, which is the entire point of the protocol.
// Measured live with music playing, the engine reported for the same instant:
//
//   Kitchen: clock - pts = 1 ms, timing=PTP, offset=0 ms   (Sonos Era 100)
//   Living Room: clock - pts = 1 ms, timing=PTP, offset=0 ms   (DALI / Bluesound)
//
// Identical to the millisecond. There is no gap to close. Every audible "delay
// between the speakers" the founder reported was the offset THIS CONTROL was
// applying — worst at the ends, which is exactly backwards from how a
// correction behaves and was the clue we kept mis-reading as "not enough
// range". Correct alignment is zero, so the control is gone rather than
// defaulted to zero: a slider whose only correct position is the middle is a
// trap, not a feature.
//
// The manual per-speaker Timing nudge in Settings > Room > Fine tuning remains
// as the escape hatch if a future device really does need a trim.

struct SourceHint: View {
    @Environment(DALIStore.self) private var store

    var body: some View {
        let items = visibleItems
        if items.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 9))
                Text(hint)
                    .font(.badge)
            }
            .foregroundStyle(Color.paper35)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 26)
        } else {
            // What the room is actually hearing: a held video first, then the
            // rest. Two rows at most; the room gives up the height.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.prefix(2).enumerated()), id: \.element.id) { i, item in
                    NowPlayingRow(item: item, primary: i == 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(DS.spring, value: items.map(\.id))
        }
    }

    /// Everything playing — or, with one app picked as the source, only what
    /// that app is playing, since nothing else reaches the room.
    private var visibleItems: [NowItem] {
        let all = store.nowPlaying.items
        if case .app(_, let name) = store.source {
            return all.filter { name.localizedCaseInsensitiveContains($0.app) }
        }
        return all
    }

    private var hint: String {
        if store.mode == .mirror {
            // Say what is actually selected. With one app picked, "all Mac
            // audio" was simply untrue, and the footer capsule is small enough
            // that nobody reads it as the correction.
            switch (store.source, store.phase == .streaming) {
            case (.app(_, let name), true):  return "\(name)'s audio is going to the room"
            case (.app(_, let name), false): return "Only \(name) will play in the room"
            case (.spotify, true):           return "Spotify Connect is playing in the room"
            case (.spotify, false):          return "Pick DALI as the device in Spotify"
            case (.system, true):            return "Everything your Mac plays is going to the room"
            case (.system, false):           return "Everything your Mac plays goes to the room"
            }
        }
        return store.phase == .streaming
            ? "Playing from your library, the sliders balance the rooms"
            : "Pick music and it plays in sync on every speaker"
    }
}

/// One thing that is playing. Title in paper, source in the badge register, a
/// quiet LIVE for a stream, and — only when the extension is holding this
/// picture back — the sync mark: two bars in step, blue, and nothing louder.
struct NowPlayingRow: View {
    @Environment(DALIStore.self) private var store
    let item: NowItem
    let primary: Bool

    var body: some View {
        HStack(spacing: 7) {
            if let art = store.nowPlaying.artwork(item.artURL) {
                // The cover, when there is one: Spotify's, Music's, or the
                // page's own og:image for a video.
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: primary ? 22 : 16, height: primary ? 22 : 16)
                    .clipShape(RoundedRectangle(cornerRadius: primary ? 5 : 4, style: .continuous))
                    .opacity(primary ? 1 : 0.7)
            } else {
                Image(systemName: item.kind == .video ? "play.rectangle" : "music.note")
                    .font(.system(size: 9))
                    .foregroundStyle(primary ? Color.paper60 : Color.paper35)
            }
            Text(item.title)
                .font(.bodySmall)
                .foregroundStyle(primary ? Color.paper : Color.paper60)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(item.source)
                .font(.badge)
                .foregroundStyle(Color.paper35)
                .fixedSize()
            if item.live {
                Text("LIVE")
                    .font(.badge)
                    .tracking(0.8)
                    .foregroundStyle(Color.paper60)
                    .fixedSize()
            }
            Spacer(minLength: 4)
            if item.held {
                Image(systemName: "equal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentBlue.opacity(0.7))
                    .help("The picture is held back to match the room")
                    .transition(.opacity)
            }
        }
        .frame(height: primary ? 26 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(item.title)
    }
}

/// Pair row health: off is faint, live is blue, connecting stays calm blue,
/// trouble is amber so a dead speaker is not mistaken for healthy.
struct StateDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let speaker: RoomSpeaker

    var body: some View {
        let dot = Circle()
            .fill(dotColor)
            .frame(width: 7, height: 7)
            .frame(width: 8)
            .animation(.easeInOut(duration: 0.3), value: speaker.enabled)
            .animation(.easeInOut(duration: 0.3), value: speaker.health)
        // Connecting is the one state with something happening behind it, so
        // it breathes — same colour as live (recovery is calm, never a
        // warning), but plainly not settled yet. Live and off hold still.
        if speaker.enabled, speaker.health == .connecting, !reduceMotion {
            dot.phaseAnimator([1.0, 0.35]) { view, o in
                view.opacity(o)
            } animation: { _ in .easeInOut(duration: 0.9) }
        } else {
            dot
        }
    }

    private var dotColor: Color {
        guard speaker.enabled else { return .paper35 }
        switch speaker.health {
        case .live, .connecting: return .accentBlue
        case .trouble: return .amber
        case .off: return .paper35
        }
    }
}

/// Shared horizontal slider, macOS-feel:
/// grab the thumb -> relative drag (no jump); click the track -> jump there.
struct HSlider: View {
    @Binding var value: Double   // 0...100
    var active = true
    @State private var hovering = false
    @State private var dragging = false
    @State private var grabOffset: Double?   // nil = not dragging, -1 = track jump

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = value / 100
            let thumb: CGFloat = dragging ? 15 : (hovering ? 13 : 11)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.ink.opacity(0.5)).frame(height: 5)
                Capsule().fill(Color.accentBlue.opacity(active ? 1 : 0.3))
                    .frame(width: max(5, w * frac), height: 5)
                Circle()
                    .fill(Color.paper.opacity(active ? 1 : 0.4))
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(dragging ? 0.45 : 0), radius: 3, y: 1)
                    .position(x: min(max(w * frac, 7), w - 7), y: geo.size.height / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if grabOffset == nil {
                            let thumbX = w * value / 100
                            // Grabbing near the thumb keeps your point of contact;
                            // clicking elsewhere on the track jumps the value there.
                            grabOffset = abs(g.startLocation.x - thumbX) <= 14
                                ? Double(thumbX - g.startLocation.x) : -1
                        }
                        dragging = true
                        let x: Double
                        if let off = grabOffset, off != -1 {
                            x = g.location.x + off
                        } else {
                            x = g.location.x
                        }
                        value = min(max(x / w, 0), 1) * 100
                    }
                    .onEnded { _ in grabOffset = nil; dragging = false }
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
            // Grab tracks instantly; release settles with a small overshoot.
            // Drives the thumb size AND its shadow (both keyed on `dragging`).
            .animation(dragging ? .easeOut(duration: 0.1)
                                : .spring(response: 0.3, dampingFraction: 0.55),
                       value: dragging)
        }
        .frame(height: 24)   // generous hit target
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int(value.rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(100, value + 5)
            case .decrement: value = max(0, value - 5)
            @unknown default: break
            }
        }
        .focusable()
        .onKeyPress(.leftArrow) { value = max(0, value - 1); return .handled }
        .onKeyPress(.rightArrow) { value = min(100, value + 1); return .handled }
    }
}
