import SwiftUI

struct MeadowGrass: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animate: Bool

    var body: some View {
        let moving = animate && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / Double(MeadowBreeze.frameRate), paused: !moving)) { tick in
            let elapsed = moving ? tick.date.timeIntervalSinceReferenceDate : 0
            Canvas { graphics, size in
                graphics.withCGContext { context in
                    MeadowBreeze.draw(in: context, size: size, frame: MeadowBreeze.frame(at: elapsed))
                }
            }
        }
    }
}

enum MeadowBreeze {
    static let duration: TimeInterval = 8
    static let frameRate = 30
    static let height: CGFloat = 40.5

    private static let width: CGFloat = 360
    private static let frameCount = Int(duration * Double(frameRate))
    private static let blades = makeBlades()
    private static let frames = makeBendFrames()

    static func frame(at elapsed: TimeInterval) -> Int {
        guard elapsed.isFinite else { return 0 }
        let remainder = elapsed.truncatingRemainder(dividingBy: duration)
        let phase = remainder < 0 ? remainder + duration : remainder
        return min(frameCount - 1, Int(phase * Double(frameRate)))
    }

    static func draw(in context: CGContext, size: CGSize, frame: Int) {
        guard size.width > 0, size.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: size.width / width, y: -size.height / height)
        context.drawLinearGradient(ground, start: .zero, end: CGPoint(x: 0, y: 10.3), options: [])
        for tuft in middleTufts {
            context.saveGState()
            context.translateBy(x: tuft.center, y: 0)
            context.scaleBy(x: 1.9, y: 0.58)
            context.drawRadialGradient(haze, startCenter: .zero, startRadius: 0, endCenter: .zero,
                                       endRadius: tuft.span, options: [])
            context.restoreGState()
        }
        let time = Double(frame) / Double(frameRate)
        for (blade, bend) in zip(blades, frames[frame]) {
            paint(blade, bend: bend, time: time, in: context)
        }
        context.restoreGState()
    }

    private struct Tuft {
        let center: Double
        let span: Double
        let stature: Double
        let lean: Double
        let phase: Double
        let count: Int
    }

    private struct Blade {
        let root: CGPoint
        let length: Double
        let width: Double
        let lean: Double
        let curve: Double
        let curl: Double
        let response: Double
        let stiffness: Double
        let damping: Double
        let phase: Double
        let color: UInt32
        let opacity: Double
        let isStem: Bool
        let isBroad: Bool
        let hasRimLight: Bool
    }

    private struct Bend {
        var angle = 0.0
        var velocity = 0.0
        var tip = 0.0
    }

    private static let rearTufts: [Tuft] = [
        .init(center: -5, span: 20, stature: 20, lean: -0.36, phase: 1, count: 10),
        .init(center: 22, span: 23, stature: 23, lean: 0.18, phase: 2.3, count: 11),
        .init(center: 68, span: 19, stature: 20, lean: 0.23, phase: 7.3, count: 8),
        .init(center: 110, span: 35, stature: 26, lean: -0.22, phase: 3.1, count: 15),
        .init(center: 162, span: 22, stature: 17, lean: 0.17, phase: 11, count: 10),
        .init(center: 202, span: 31, stature: 28, lean: -0.30, phase: 3.0, count: 11),
        .init(center: 242, span: 16, stature: 19, lean: 0.21, phase: 5.5, count: 7),
        .init(center: 272, span: 21, stature: 25, lean: -0.11, phase: 12.2, count: 8),
        .init(center: 305, span: 21, stature: 20, lean: 0.16, phase: 11, count: 10),
        .init(center: 349, span: 22, stature: 23, lean: -0.18, phase: 4.62, count: 11)
    ]

    private static let middleTufts: [Tuft] = [
        .init(center: 6, span: 19, stature: 24, lean: -0.30, phase: 0.1, count: 9),
        .init(center: 34, span: 17, stature: 28, lean: -0.09, phase: 0.6, count: 13),
        .init(center: 80, span: 20, stature: 16, lean: 0.34, phase: 8.1, count: 9),
        .init(center: 119, span: 25, stature: 25, lean: -0.36, phase: 7, count: 15),
        .init(center: 153, span: 16, stature: 15, lean: 0.24, phase: 0.3, count: 7),
        .init(center: 184, span: 28, stature: 23, lean: 0.12, phase: 2.6, count: 17),
        .init(center: 232, span: 18, stature: 20, lean: -0.21, phase: 6.1, count: 9),
        .init(center: 266, span: 27, stature: 26, lean: -0.27, phase: 7.4, count: 14),
        .init(center: 293, span: 20, stature: 17, lean: 0.19, phase: 3.6, count: 11),
        .init(center: 325, span: 15, stature: 18, lean: 0.05, phase: 5.1, count: 9),
        .init(center: 360, span: 23, stature: 25, lean: -0.18, phase: 9.8, count: 9)
    ]

    private static let foregroundTufts: [Tuft] = [
        .init(center: 13, span: 12, stature: 15, lean: 0.42, phase: 3.3, count: 8),
        .init(center: 57, span: 21, stature: 16, lean: -0.28, phase: 8.3, count: 10),
        .init(center: 94, span: 20, stature: 21, lean: 0.10, phase: 2.7, count: 8),
        .init(center: 135, span: 18, stature: 15, lean: -0.29, phase: 6.2, count: 11),
        .init(center: 169, span: 19, stature: 21, lean: 0.12, phase: 3.1, count: 11),
        .init(center: 215, span: 21, stature: 18, lean: 0.20, phase: 0, count: 10),
        .init(center: 249, span: 18, stature: 17, lean: -0.21, phase: 3.4, count: 9),
        .init(center: 286, span: 22, stature: 20, lean: 0.09, phase: 8.2, count: 8),
        .init(center: 320, span: 17, stature: 13, lean: -0.07, phase: 0, count: 8),
        .init(center: 348, span: 12, stature: 15, lean: 0.32, phase: 4.3, count: 5)
    ]

    private static func makeBlades() -> [Blade] {
        let layers: [([Tuft], [UInt32])] = [
            (rearTufts, [0xa6bd71, 0xb3c884, 0x97b56e, 0xbcc988, 0xadc498, 0x9cb876]),
            (middleTufts, [0x6d9c56, 0x8aae5c, 0x96bb6b, 0x71a46a, 0x9abd70, 0xaec782, 0x79a760]),
            (foregroundTufts, [0x62984f, 0x759951, 0x86b160, 0x7ba66e, 0xa3bf72, 0xa7bb64, 0x6a965f])
        ]
        var seed: UInt64 = 1442
        func sample(_ lower: Double = 0, _ upper: Double = 1) -> Double {
            seed = seed &* 2862933555777941757 &+ 3037000493
            let fraction = Double((seed >> 40) & 0xffffff) / Double(0x1000000)
            return lower + (upper - lower) * fraction
        }

        var meadow: [Blade] = []
        for (depth, layer) in layers.enumerated() {
            let (tufts, colors) = layer
            for tuft in tufts {
                for index in 0..<tuft.count {
                    let offset = (sample() + sample() - 1) * tuft.span * 1.4
                    let kind = sample()
                    let stem = kind < 0.20
                    let broad = kind > (depth == 0 ? 0.86 : 0.66)
                    let stature = tuft.stature * (0.57 + pow(sample(), 1.52) * 0.48) *
                        (1 - 0.33 * min(1, abs(offset) / tuft.span))
                    let length = (index == 0 ? tuft.stature + sample(0.2, 2.7) : stature) *
                        (stem ? sample(1.05, 1.34) : sample(0.78, 1.14))
                    let lean = tuft.lean + offset / tuft.span * 0.30 + sample(-0.26, 0.26)
                    let color = colors[Int(sample() * Double(colors.count))]
                    let root = CGPoint(x: tuft.center + offset, y: 2.6 - Double(depth) * 2.15 + sample(-1.1, 1.1))
                    let bladeWidth = stem ? sample(0.29, 0.78) : (broad ? sample(2.4, 4.3) : sample(0.94, 2.13))
                    meadow.append(Blade(
                        root: root, length: min(35.5, length * 1.14), width: bladeWidth * 1.12,
                        lean: lean, curve: sample(-1.0, 0.94) + lean * 0.60, curl: sample(-0.60, 0.68),
                        response: sample(0.58, 1.28) * (depth == 0 ? 0.76 : 1.0),
                        stiffness: sample(3.5, 7.2), damping: sample(0.68, 0.96), phase: tuft.phase + sample(-0.56, 0.64),
                        color: color, opacity: sample(0.54, 0.82) * (depth == 0 ? 0.66 : 0.96),
                        isStem: stem, isBroad: broad, hasRimLight: depth > 0 && sample() > 0.67
                    ))
                }
            }
        }
        return meadow
    }

    // Integrate a warm-up cycle once, then sample the same periodic motion at any render time.
    private static func makeBendFrames() -> [[Bend]] {
        let substeps = 4
        let step = 1 / Double(frameRate * substeps)
        var bends = Array(repeating: Bend(), count: blades.count)
        var timeline: [[Bend]] = []
        timeline.reserveCapacity(frameCount)
        for tick in -frameCount * substeps ..< frameCount * substeps {
            if tick >= 0 && tick.isMultiple(of: substeps) { timeline.append(bends) }
            let time = Double(tick) * step
            for index in blades.indices {
                let blade = blades[index]
                var bend = bends[index]
                let target = wind(at: time, blade: blade) * blade.response
                let stiffness = blade.stiffness
                let acceleration = stiffness * stiffness * (target - bend.angle) -
                    2 * stiffness * blade.damping * bend.velocity
                bend.velocity += step * acceleration
                bend.angle += step * bend.velocity
                let tipLag = 0.11 + 0.13 * (0.5 + 0.5 * sin(blade.phase * 0.77))
                bend.tip += (bend.angle - bend.tip) * (1 - exp(-step / tipLag))
                bends[index] = bend
            }
        }
        return timeline
    }

    private static func wind(at time: TimeInterval, blade: Blade) -> Double {
        let x = blade.root.x
        let phase = blade.phase
        let tuftLag = 0.09 * sin(phase * 0.81) + 0.07 * cos(phase * 1.47 + x * 0.022)
        let depthLag = 0.043 * blade.root.y
        let firstCrest = 0.97 + 0.0082 * x + 0.23 * sin(x * 0.019 + 0.31) + tuftLag + depthLag
        let firstRise = 0.49 + 0.14 * (0.5 + 0.5 * cos(x * 0.022 + 0.83))
        let firstRelease = 0.72 + 0.28 * (0.5 + 0.5 * sin(x * 0.029 - 0.61))
        let exposure = 0.85 + 0.13 * sin(x * 0.036 + 0.27) + 0.065 * cos(x * 0.076 + phase * 0.31)

        let secondCrest = 4.25 + 0.0067 * x + 0.25 * cos(x * 0.020 - 0.72) + tuftLag * 1.5 - depthLag
        let secondReach = 0.46 + 0.54 * exp(-pow((x - 216) / 134, 2))
        let secondRelease = 0.82 + 0.19 * (0.5 + 0.5 * cos(x * 0.017))
        var air = 0.025 + 0.013 * sin(time * 2 * .pi / duration - x * 0.032 + phase * 0.29) +
            0.010 * sin(time * 6 * .pi / duration + x * 0.022 + phase * 0.73)
        for cycle in -1...1 {
            let t = time - Double(cycle) * duration
            air += 0.67 * exposure * pulse(t - firstCrest, rise: firstRise, release: firstRelease)
            air += 0.42 * secondReach * pulse(t - secondCrest, rise: 0.60, release: secondRelease)
        }
        return air
    }

    private static func pulse(_ elapsed: Double, rise: Double, release: Double) -> Double {
        let unit = elapsed / (elapsed < 0 ? rise : release)
        return exp(-unit * unit)
    }

    // Integrate the tangent over the blade so its root and length stay fixed as its tip bends.
    private static func paint(_ blade: Blade, bend: Bend, time: TimeInterval, in context: CGContext) {
        let segments = blade.isStem ? 9 : 12
        let step = blade.length / Double(segments)
        let sunlight = (blade.isBroad ? 0.12 : 0.09) + max(0, 1 - blade.root.x / width) * 0.08 +
            0.044 * abs(sin(bend.angle * 3.55 + blade.phase))
        let flutter = sin(time * 8 * .pi / duration + blade.phase) * (0.009 + abs(bend.velocity) * 0.025)
        func tangent(_ s: Double) -> Double {
            blade.lean + (blade.curve + bend.tip * 1.40) * s * s + blade.curl * s * s * s + bend.angle * 0.45 * s
        }

        var point = blade.root
        var leading: [CGPoint] = []
        var trailing: [CGPoint] = []
        var highlights: [CGPoint] = []
        leading.reserveCapacity(segments + 1)
        trailing.reserveCapacity(segments + 1)
        for index in 0...segments {
            let s = Double(index) / Double(segments)
            if index > 0 {
                let midpoint = s - 0.5 / Double(segments)
                let angle = tangent(midpoint) + flutter * midpoint * midpoint * midpoint
                point.x += sin(angle) * step
                point.y += cos(angle) * step
            }
            let width = blade.width * (blade.isStem ? pow(1 - s, 0.44) :
                pow(1 - s, 0.93) * (0.51 + 0.93 * sin(s * .pi * 1.09)))
            let twist = 0.82 + 0.18 * cos(blade.phase + s * 4.4 + bend.angle * 3.4)
            let dx = cos(tangent(s)) * width * twist
            let dy = -sin(tangent(s)) * width * twist
            leading.append(CGPoint(x: point.x - dx * 0.53, y: point.y - dy * 0.53))
            trailing.append(CGPoint(x: point.x + dx * 0.47, y: point.y + dy * 0.47))
            if blade.hasRimLight && index >= 4 {
                highlights.append(CGPoint(x: point.x - dx * 0.25, y: point.y - dy * 0.25))
            }
        }
        context.setFillColor(color(blade.color, alpha: blade.opacity, sunlight: sunlight))
        context.beginPath()
        context.addLines(between: leading)
        for point in trailing.reversed() { context.addLine(to: point) }
        context.closePath()
        context.fillPath()
        if blade.hasRimLight {
            context.setStrokeColor(color(0xf3ebac, alpha: blade.isBroad ? 0.37 : 0.25))
            context.setLineWidth(blade.isBroad ? 0.49 : 0.29)
            context.setLineCap(.round)
            context.beginPath()
            context.addLines(between: highlights)
            context.strokePath()
        }
    }

    private static func color(_ rgb: UInt32, alpha: CGFloat, sunlight: Double = 0) -> CGColor {
        func channel(_ shift: Int, lit: Double) -> Double {
            let base = Double((rgb >> shift) & 255)
            return (base + (lit - base) * sunlight) / 255
        }
        return CGColor(srgbRed: channel(16, lit: 246), green: channel(8, lit: 227),
                       blue: channel(0, lit: 163), alpha: alpha)
    }

    private static let ground = CGGradient(colorsSpace: nil, colors: [
        color(0x9bb972, alpha: 0.28), color(0xadc888, alpha: 0)
    ] as CFArray, locations: nil)!
    private static let haze = CGGradient(colorsSpace: nil, colors: [
        color(0x88a75c, alpha: 0.31), color(0xb6c97b, alpha: 0.12), color(0xc2d898, alpha: 0)
    ] as CFArray, locations: nil)!
}
