import AppKit
import SwiftUI

struct WaterMotion {
    static let speed: CGFloat = 12
    static let duration: TimeInterval = 4.9
    static let distance = speed * duration

    let backgroundOffset: CGFloat
    let foregroundOffset: CGFloat
    let foregroundOpacity: Double

    init(elapsed: TimeInterval) {
        let phase = elapsed.truncatingRemainder(dividingBy: Self.duration) / Self.duration
        let alternate = (phase + 0.5).truncatingRemainder(dividingBy: 1)
        backgroundOffset = (alternate - 0.5) * Self.distance
        foregroundOffset = (phase - 0.5) * Self.distance
        foregroundOpacity = (1 - cos(2 * .pi * phase)) / 2
    }
}

struct CardSurface: ViewModifier {
    let theme: CardTheme
    let scale: CGFloat
    let bottomPadding: CGFloat
    let animate: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 25 * scale)
        content
            .background {
                ZStack(alignment: .bottom) {
                    switch theme.material {
                    case .graphite:
                        LinearGradient(colors: [Color(rgb: 0x181e26), Color(rgb: 0x11161c)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    case .iceBlue:
                        GlassMaterial()
                        LinearGradient(
                            colors: [
                                Color(red: 0.84, green: 0.93, blue: 0.97).opacity(0.95),
                                Color(red: 0.75, green: 0.87, blue: 0.94).opacity(0.93)
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        WaterReflections(animate: animate)
                            .frame(height: 22 * scale)
                            .padding(.bottom, 2 * scale)
                    case .sunlitLeaf:
                        SunlitSurface(scale: scale)
                        MeadowGrass(animate: animate)
                            .frame(height: min(MeadowBreeze.height, bottomPadding - 2) * scale)
                    }
                }
                .clipShape(shape)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .overlay {
                ZStack {
                    switch theme.material {
                    case .graphite:
                        shape.strokeBorder(Color(rgb: 0x788697).opacity(0.88), lineWidth: 0.75 * scale)
                    case .iceBlue:
                        shape.strokeBorder(.white.opacity(0.88), lineWidth: scale)
                        shape.inset(by: 2.25 * scale).strokeBorder(.white.opacity(0.56), lineWidth: 0.65 * scale)
                    case .sunlitLeaf:
                        shape.strokeBorder(Color(rgb: 0xffffe8).opacity(0.92), lineWidth: scale)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .preferredColorScheme(theme.colorScheme)
    }
}

private struct SunlitSurface: View {
    let scale: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(rgb: 0xf5f9df), Color(rgb: 0xd6ecbd)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(rgb: 0xfffadd).opacity(0.80), .clear],
                           center: UnitPoint(x: 0.065, y: 0.08), startRadius: 3 * scale, endRadius: 122 * scale)
            RadialGradient(colors: [Color(rgb: 0xfff3bc).opacity(0.70), Color(rgb: 0xffefad).opacity(0.18), .clear],
                           center: UnitPoint(x: 0.35, y: -0.1), startRadius: 16 * scale, endRadius: 180 * scale)
            Canvas { context, size in
                let surface = Path(CGRect(origin: .zero, size: size))
                let rays: [(center: CGFloat, width: CGFloat, color: UInt32, opacity: Double)] = [
                    (41, 56, 0xfff3c2, 0.52), (121, 27, 0xffffea, 0.43), (168, 61, 0xfff2b6, 0.34)
                ]
                for ray in rays {
                    let color = Color(rgb: ray.color)
                    let gradient = Gradient(stops: [
                        .init(color: color.opacity(0), location: 0),
                        .init(color: color.opacity(ray.opacity * 0.40), location: 0.19),
                        .init(color: color.opacity(ray.opacity), location: 0.44),
                        .init(color: color.opacity(ray.opacity * 0.38), location: 0.72),
                        .init(color: color.opacity(0), location: 1)
                    ])
                    let x = ray.center * scale
                    let y = -9 * scale
                    let dx = ray.width * scale * 0.87
                    let dy = ray.width * scale * 0.49
                    context.fill(surface, with: .linearGradient(gradient,
                        startPoint: CGPoint(x: x - dx, y: y + dy), endPoint: CGPoint(x: x + dx, y: y - dy)))
                }
            }
            .mask(LinearGradient(stops: [.init(color: .white, location: 0.06), .init(color: .clear, location: 0.60)],
                                 startPoint: .top, endPoint: .bottom))
            LinearGradient(colors: [.clear, Color(rgb: 0xb8d894).opacity(0.46)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 32 * scale)
        }
    }
}

private struct GlassMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .aqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct WaterReflections: View {
    private static let texture = NSImage(named: "WaterReflections")

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animate: Bool

    var body: some View {
        let moving = animate && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { timeline in
            let motion = WaterMotion(elapsed: moving ? timeline.date.timeIntervalSinceReferenceDate : 0)
            GeometryReader { geometry in
                if let texture = Self.texture {
                    let water = Image(nsImage: texture)
                        .resizable()
                        .frame(width: geometry.size.width + WaterMotion.distance, height: geometry.size.height)
                    ZStack {
                        water.offset(x: motion.backgroundOffset)
                        // Each copy returns to the start while the other is visible.
                        water.offset(x: motion.foregroundOffset).opacity(motion.foregroundOpacity)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                }
            }
        }
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.64), location: 0.35),
                .init(color: .white, location: 0.80),
                .init(color: .white.opacity(0.7), location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
    }
}
