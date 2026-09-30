// DALI — the room plan's drawing primitives. Pure functions of a
// GraphicsContext: no state, no clocks. RoomCanvas decides what is drawn when
// (and what is cached); this file only knows how things look.
//
// The plan is the actual room seen from above: desk and monitor at the
// top with the DALI Opticon 2s either side, the listener in the middle, the
// Sonos Era 100s in the back corners. Footprints are the real products'
// (Opticon 2 MK2 195 × 297 mm, Era 100 120 × 130.5 mm).

import SwiftUI

enum RoomLayout {
    static let frontL = CGPoint(x: 0.14, y: 0.21)
    static let frontR = CGPoint(x: 0.86, y: 0.21)
    static let backL  = CGPoint(x: 0.12, y: 0.85)
    static let backR  = CGPoint(x: 0.88, y: 0.85)
    static let listener = CGPoint(x: 0.5, y: 0.60)
    static let desk = CGRect(x: 0.29, y: 0.06, width: 0.42, height: 0.19)

    static func positions(_ cabinet: Cabinet, in size: CGSize) -> [CGPoint] {
        let unit = cabinet == .opticon2 ? [frontL, frontR] : [backL, backR]
        return unit.map { $0.scaled(to: size) }
    }
}

extension CGPoint {
    func scaled(to size: CGSize) -> CGPoint { CGPoint(x: x * size.width, y: y * size.height) }
}

/// Which cabinet a pair is. Silhouette is the point: hard box vs round pill.
enum Cabinet: CaseIterable {
    case opticon2, era100

    var depth: CGFloat { self == .opticon2 ? 34.0 : 24.8 }
    var width: CGFloat { self == .opticon2 ? depth * 195.0 / 297.0 : depth * 120.0 / 130.5 }
    /// Radius of the pool of light the cabinet sits in.
    var pool: CGFloat { self == .opticon2 ? 36.0 : 28.0 }
    /// Roughly the silhouette's outer radius: pulses leave from here.
    var reach: CGFloat { self == .opticon2 ? 17.0 : 11.0 }
    /// Heading with no toe-in: fronts fire down the room, rears up it.
    var restAim: Double { self == .opticon2 ? .pi / 2 : -.pi / 2 }
    /// How much of the way toward the listener the box is turned (~15° front,
    /// ~8° back — what people actually do). The waves always leave on the
    /// true aim, so the sound still reaches the chair.
    var toeIn: Double { self == .opticon2 ? 0.30 : 0.12 }
    /// The back wall wakes a beat after the desk, so light sweeps the room.
    var delay: Double { self == .opticon2 ? 0 : 0.08 }
}

enum RoomArt {
    /// Deep shadow tone for cabinet bodies — a step under `ink`.
    static let shadow = Color(red: 0x08 / 255, green: 0x09 / 255, blue: 0x0B / 255)

    // MARK: static furniture (cached)

    /// Desk, monitor and the listener's mark: everything that never
    /// changes. Drawn once per canvas size into an image.
    static func drawFurniture(_ ctx: GraphicsContext, size: CGSize) {
        // A trace of neutral light near the floor; keep the room itself near-black.
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
            Gradient(stops: [
                // Zero at the very edge, so the glow never meets the pair
                // rows below as a seam.
                .init(color: .warmWhite.opacity(0), location: 0),
                .init(color: .warmWhite.opacity(0.018), location: 0.14),
                .init(color: .warmWhite.opacity(0.008), location: 0.42),
                .init(color: .warmWhite.opacity(0), location: 0.8),
            ]),
            startPoint: CGPoint(x: size.width / 2, y: size.height),
            endPoint: CGPoint(x: size.width / 2, y: 0)))

        let d = RoomLayout.desk
        let desk = CGRect(x: d.minX * size.width, y: d.minY * size.height,
                          width: d.width * size.width, height: d.height * size.height)
        let shape = Path(roundedRect: desk, cornerRadius: 5, style: .continuous)
        ctx.fill(shape, with: .color(.white.opacity(0.012)))
        // The near edge catches the room light; the far edge dissolves.
        ctx.stroke(shape, with: .linearGradient(Gradient(stops: [
            .init(color: .warmWhite.opacity(0.10), location: 0),
            .init(color: .warmWhite.opacity(0.03), location: 0.5),
            .init(color: .warmWhite.opacity(0), location: 1),
        ]), startPoint: CGPoint(x: desk.midX, y: desk.maxY),
            endPoint: CGPoint(x: desk.midX, y: desk.minY)), lineWidth: 0.75)

        // Monitor: a thin lit bar, with its light spilling toward the room.
        let monitor = CGRect(x: desk.midX - desk.width * 0.30, y: desk.minY + desk.height * 0.28,
                             width: desk.width * 0.60, height: 2.5)
        let spillR = monitor.width * 0.62
        let squash = 8.0 / spillR
        var spill = ctx
        spill.scaleBy(x: 1, y: squash)
        let sc = CGPoint(x: monitor.midX, y: (monitor.midY + 3) / squash)
        spill.fill(Path(ellipseIn: CGRect(x: sc.x - spillR, y: sc.y - spillR,
                                          width: spillR * 2, height: spillR * 2)),
                   with: .radialGradient(Gradient(stops: [
                    .init(color: .warmWhite.opacity(0.08), location: 0),
                    .init(color: .warmWhite.opacity(0.03), location: 0.45),
                    .init(color: .warmWhite.opacity(0), location: 1),
                   ]), center: sc, startRadius: 0, endRadius: spillR))
        ctx.fill(Path(roundedRect: monitor, cornerRadius: 1.25), with: .linearGradient(
            Gradient(colors: [.warmWhite.opacity(0.34), .warmWhite.opacity(0.16)]),
            startPoint: CGPoint(x: monitor.minX, y: monitor.midY),
            endPoint: CGPoint(x: monitor.maxX, y: monitor.midY)))

        // The listener: an open arc facing the desk and a still point.
        let me = RoomLayout.listener.scaled(to: size)
        var seat = Path()
        seat.addArc(center: me, radius: 10, startAngle: .degrees(22), endAngle: .degrees(158),
                    clockwise: false)
        ctx.stroke(seat, with: .linearGradient(Gradient(stops: [
            .init(color: .warmWhite.opacity(0.06), location: 0),
            .init(color: .warmWhite.opacity(0.36), location: 0.5),
            .init(color: .warmWhite.opacity(0.06), location: 1),
        ]), startPoint: CGPoint(x: me.x - 10, y: me.y), endPoint: CGPoint(x: me.x + 10, y: me.y)),
                   style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: me.x - 2, y: me.y - 2, width: 4, height: 4)),
                 with: .color(.warmWhite.opacity(0.6)))
    }

    // MARK: cabinets (cached, two looks each)

    /// Both cabinets of a pair, in place, at a fixed light level. RoomCanvas
    /// caches this at `lit` 0 and 1 and cross-fades the two.
    static func drawPair(_ ctx: GraphicsContext, _ cabinet: Cabinet, size: CGSize, lit: Double) {
        let me = RoomLayout.listener.scaled(to: size)
        for p in RoomLayout.positions(cabinet, in: size) {
            let aim = atan2(me.y - p.y, me.x - p.x)
            let facing = cabinet.restAim + shortestAngle(aim - cabinet.restAim) * cabinet.toeIn
            var g = ctx
            g.translateBy(x: p.x, y: p.y)
            g.rotate(by: .radians(facing - .pi / 2))
            switch cabinet {
            case .opticon2: drawOpticon2(g, lit: lit)
            case .era100: drawEra100(g, lit: lit)
            }
        }
    }

    /// Opticon 2 MK2 from above: satin cabinet, lacquered top, fabric grille
    /// on the front edge. Local space: +Y is the front baffle.
    private static func drawOpticon2(_ ctx: GraphicsContext, lit: Double) {
        let d = Cabinet.opticon2.depth
        let hw = Cabinet.opticon2.width / 2
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

        ctx.fill(body, with: .linearGradient(Gradient(colors: [.ink, shadow]),
                                             startPoint: CGPoint(x: 0, y: fy),
                                             endPoint: CGPoint(x: 0, y: by)))
        var top = ctx
        top.clip(to: body)
        let key = 0.085 + 0.075 * lit
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

        if lit > 0.01 {
            ctx.stroke(body, with: .linearGradient(Gradient(stops: [
                .init(color: .warmWhite.opacity(0.10 * lit), location: 0),
                .init(color: .warmWhite.opacity(0.025 * lit), location: 0.22),
                .init(color: .warmWhite.opacity(0), location: 0.46),
            ]), startPoint: CGPoint(x: 0, y: fy), endPoint: CGPoint(x: 0, y: by)), lineWidth: 3.6)
        }
        strokeRim(ctx, body, front: fy, back: by, alpha: rimAlpha(lit), width: 1.1)

        let grille = Path(roundedRect: CGRect(x: -fx + 1.1, y: fy - 3.9, width: 2 * fx - 2.2, height: 3.0),
                          cornerRadius: 0.8)
        ctx.fill(grille, with: .color(shadow.opacity(0.9)))
        var weave = Path()
        for i in 0..<9 {
            let x = -fx + 2.3 + CGFloat(i) * (2 * fx - 4.6) / 8
            weave.move(to: CGPoint(x: x, y: fy - 3.3))
            weave.addLine(to: CGPoint(x: x, y: fy - 1.5))
        }
        ctx.stroke(weave, with: .color(.paper.opacity(0.10 + 0.07 * lit)), lineWidth: 0.45)
        var seam = Path()
        seam.move(to: CGPoint(x: -fx + 1.5, y: fy - 4.4))
        seam.addLine(to: CGPoint(x: fx - 1.5, y: fy - 4.4))
        ctx.stroke(seam, with: .color(.paper.opacity(0.14 + 0.10 * lit)), lineWidth: 0.55)
    }

    /// Sonos Era 100 from above: near-round matte top, recessed volume
    /// trough, small playback marks.
    private static func drawEra100(_ ctx: GraphicsContext, lit: Double) {
        let w = Cabinet.era100.width, d = Cabinet.era100.depth
        let body = Path(roundedRect: CGRect(x: -w / 2, y: -d / 2, width: w, height: d),
                        cornerRadius: w / 2, style: .continuous)
        let fy = d / 2, by = -d / 2

        ctx.fill(body, with: .linearGradient(Gradient(colors: [.ink, shadow]),
                                             startPoint: CGPoint(x: 0, y: fy),
                                             endPoint: CGPoint(x: 0, y: by)))
        var top = ctx
        top.clip(to: body)
        let sc = CGPoint(x: -w * 0.19, y: d * 0.17)
        let sr = w * 0.82
        let key = 0.14 + 0.05 * lit
        top.fill(Path(ellipseIn: CGRect(x: sc.x - sr, y: sc.y - sr * 0.88, width: sr * 2, height: sr * 1.76)),
                 with: .radialGradient(Gradient(stops: [
                    .init(color: .warmWhite.opacity(key), location: 0),
                    .init(color: .warmWhite.opacity(key * 0.55), location: 0.42),
                    .init(color: .warmWhite.opacity(key * 0.16), location: 0.74),
                    .init(color: .warmWhite.opacity(0), location: 1),
                 ]), center: sc, startRadius: 0, endRadius: sr))
        top.fill(body, with: .linearGradient(Gradient(stops: [
            .init(color: .warmWhite.opacity(key * 0.34), location: 0),
            .init(color: .warmWhite.opacity(key * 0.12), location: 0.55),
            .init(color: .warmWhite.opacity(0), location: 1),
        ]), startPoint: CGPoint(x: -w * 0.5, y: fy), endPoint: CGPoint(x: w * 0.5, y: by)))

        if lit > 0.01 {
            ctx.stroke(body, with: .linearGradient(Gradient(stops: [
                .init(color: .warmWhite.opacity(0.14 * lit), location: 0),
                .init(color: .warmWhite.opacity(0.035 * lit), location: 0.30),
                .init(color: .warmWhite.opacity(0), location: 0.58),
            ]), startPoint: CGPoint(x: 0, y: fy), endPoint: CGPoint(x: 0, y: by)), lineWidth: 3.6)
        }
        strokeRim(ctx, body, front: fy, back: by, alpha: rimAlpha(lit), width: 1.2)

        let trough = CGRect(x: -w * 0.30, y: -d * 0.21, width: w * 0.60, height: 2.0)
        ctx.fill(Path(roundedRect: trough, cornerRadius: 1), with: .color(shadow.opacity(0.92)))
        let detail = 0.26 + 0.10 * lit
        var lip = Path()
        lip.move(to: CGPoint(x: trough.minX + 1, y: trough.maxY))
        lip.addLine(to: CGPoint(x: trough.maxX - 1, y: trough.maxY))
        ctx.stroke(lip, with: .color(.paper.opacity(detail * 0.52)), lineWidth: 0.45)
        var play = Path()
        play.move(to: CGPoint(x: -0.6, y: 1.0))
        play.addLine(to: CGPoint(x: 0.9, y: 1.9))
        play.addLine(to: CGPoint(x: -0.6, y: 2.8))
        play.closeSubpath()
        ctx.fill(play, with: .color(.paper.opacity(detail)))
        for x: CGFloat in [-4.2, 4.2] {
            ctx.fill(Path(ellipseIn: CGRect(x: x - 0.35, y: 1.6, width: 0.7, height: 0.7)),
                     with: .color(.paper.opacity(detail * 0.7)))
        }
    }

    /// A rim, not an outline: bright on the room-facing edge, gone by the back.
    private static func strokeRim(_ ctx: GraphicsContext, _ shape: Path, front: CGFloat,
                                  back: CGFloat, alpha: Double, width: CGFloat) {
        ctx.stroke(shape, with: .linearGradient(Gradient(stops: [
            .init(color: .warmWhite.opacity(alpha), location: 0),
            .init(color: .warmWhite.opacity(alpha * 0.34), location: 0.30),
            .init(color: .warmWhite.opacity(alpha * 0.08), location: 0.58),
            .init(color: .warmWhite.opacity(0), location: 0.86),
        ]), startPoint: CGPoint(x: 0, y: front), endPoint: CGPoint(x: 0, y: back)), lineWidth: width)
    }

    private static func rimAlpha(_ lit: Double) -> Double { 0.22 + (0.46 - 0.22) * lit }

    // MARK: live light (per frame)

    /// The pool a live cabinet sits in: a corona peaking just outside the
    /// silhouette, pushed a little along its aim.
    static func drawPool(_ ctx: GraphicsContext, at p: CGPoint, aim: Double, cabinet: Cabinet,
                         light: Double, energy: Double) {
        let a = (0.065 * light + 0.08 * energy)
        guard a > 0.003 else { return }
        let r = cabinet.pool * (0.75 + 0.25 * light) + 30 * energy
        let c = CGPoint(x: p.x + cos(aim) * r * 0.14, y: p.y + sin(aim) * r * 0.14)
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                 with: .radialGradient(Gradient(stops: [
                    .init(color: meridian(0.00, a * 0.9), location: 0.00),
                    .init(color: meridian(0.10, a), location: 0.14),
                    .init(color: meridian(0.35, a * 0.5), location: 0.32),
                    .init(color: meridian(0.60, a * 0.18), location: 0.58),
                    .init(color: meridian(1.00, 0), location: 1.00),
                 ]), center: c, startRadius: 0, endRadius: r))
    }

    /// A one-shot wake leaving a cabinet: a pair going live, or a beat.
    static func drawPulse(_ ctx: GraphicsContext, at p: CGPoint, aim: Double, progress: Double,
                          from r0: CGFloat, to r1: CGFloat, alpha: Double) {
        let e = easeOutCubic(progress)
        let a = alpha * smoothstep(progress / 0.04) * pow(1 - progress, 1.4)
        guard a > 0.004 else { return }
        let r = r0 + (r1 - r0) * e
        let base = Angle(radians: aim)
        let spread = Angle.degrees(100)
        var arc = Path()
        arc.addArc(center: p, radius: r, startAngle: base - spread, endAngle: base + spread, clockwise: false)
        ctx.stroke(arc, with: arcShading(center: p, radius: r, base: base, spread: spread,
                                         color: meridian(e, a * 0.5)),
                   style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
        ctx.stroke(arc, with: arcShading(center: p, radius: r, base: base, spread: spread,
                                         color: meridian(e, a)),
                   style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
    }

    /// The room's glow around the listener. Dark when nothing streams.
    static func drawRoomGlow(_ ctx: GraphicsContext, size: CGSize, light: Double, level: Double, bass: Double) {
        guard light > 0.01 else { return }
        let me = RoomLayout.listener.scaled(to: size)
        let r = size.height * (0.6 + 0.12 * level + 0.06 * bass)
        ctx.fill(Path(ellipseIn: CGRect(x: me.x - r, y: me.y - r, width: r * 2, height: r * 2)),
                 with: .radialGradient(Gradient(colors: [
                    .warmWhite.opacity((0.012 + 0.016 * level) * light), .clear,
                 ]), center: me, startRadius: 0, endRadius: r))
    }
}

// MARK: - light ramp, shading, easing

/// Warm light at the source fades to neutral silver at the edge.
func meridian(_ d: Double, _ alpha: Double) -> Color {
    let m = pow(min(max(d, 0), 1), 0.62)
    return Color(red: 0.949 + (0.72 - 0.949) * m,
                 green: 0.929 + (0.72 - 0.929) * m,
                 blue: 0.890 + (0.72 - 0.890) * m)
        .opacity(max(alpha, 0))
}

/// Brightest where the arc faces the listener, dissolved at both ends, so a
/// stroke never shows where it starts or stops.
private func arcShading(center: CGPoint, radius: Double, base: Angle, spread: Angle,
                        color: Color) -> GraphicsContext.Shading {
    let a0 = base.radians - spread.radians, a1 = base.radians + spread.radians
    return .linearGradient(Gradient(stops: [
        .init(color: color.opacity(0), location: 0),
        .init(color: color.opacity(0.3), location: 0.18),
        .init(color: color, location: 0.5),
        .init(color: color.opacity(0.3), location: 0.82),
        .init(color: color.opacity(0), location: 1),
    ]), startPoint: CGPoint(x: center.x + radius * cos(a0), y: center.y + radius * sin(a0)),
        endPoint: CGPoint(x: center.x + radius * cos(a1), y: center.y + radius * sin(a1)))
}

func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
func easeOutCubic(_ x: Double) -> Double { let v = clamp01(x); return 1 - pow(1 - v, 3) }
func easeInOutCubic(_ x: Double) -> Double {
    let v = clamp01(x); return v < 0.5 ? 4 * v * v * v : 1 - pow(-2 * v + 2, 3) / 2
}
func smoothstep(_ x: Double) -> Double { let v = clamp01(x); return v * v * (3 - 2 * v) }

/// Shortest signed angle, so a fraction of a turn never goes the long way.
func shortestAngle(_ a: Double) -> Double {
    var x = a.truncatingRemainder(dividingBy: 2 * .pi)
    if x > .pi { x -= 2 * .pi }
    if x < -.pi { x += 2 * .pi }
    return x
}
