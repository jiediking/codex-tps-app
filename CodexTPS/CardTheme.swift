import SwiftUI

struct CardPalette {
    let ink: Color
    let detail: Color
    let activeInk: Color
    let activeDetail: Color
    let recentInk: Color
    let recentDetail: Color
    let activeDot: Color
    let pin: Color
    let warning: Color
    let divider: Color
    var activeWash: LinearGradient? = nil
}

struct CardTheme: Identifiable {
    enum Material {
        case graphite, iceBlue, sunlitLeaf
    }

    let id: String
    let name: String
    let material: Material
    let swatch: Color
    let palette: CardPalette

    var colorScheme: ColorScheme { material == .graphite ? .dark : .light }
    var bottomPadding: CGFloat { material == .sunlitLeaf ? MeadowBreeze.height + 2 : 24 }

    static let graphite = CardTheme(
        id: "graphite", name: "Graphite", material: .graphite, swatch: Color(rgb: 0x171d24),
        palette: CardPalette(
            ink: Color(rgb: 0xf4f7fb), detail: Color(rgb: 0xaeb7c2),
            activeInk: Color(rgb: 0x8ee0ec), activeDetail: Color(rgb: 0x8ee0ec),
            recentInk: Color(rgb: 0xbfc5ce), recentDetail: Color(rgb: 0xbfc5ce),
            activeDot: Color(rgb: 0xffc341), pin: Color(rgb: 0xffc341),
            warning: Color(rgb: 0xffa585), divider: Color(rgb: 0x748292).opacity(0.84),
            activeWash: LinearGradient(
                colors: [Color(rgb: 0x193541), Color(rgb: 0x102733)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
    )

    static let iceBlue = CardTheme(
        id: "ice-blue", name: "Ice Blue", material: .iceBlue, swatch: Color(rgb: 0xc4dfef),
        palette: CardPalette(
            ink: Color(red: 0.04, green: 0.16, blue: 0.27), detail: Color(red: 0.27, green: 0.38, blue: 0.47),
            activeInk: Color(rgb: 0x1648a3), activeDetail: Color(rgb: 0x285485),
            recentInk: Color(rgb: 0x475565), recentDetail: Color(rgb: 0x4b5964),
            activeDot: Color(red: 1.00, green: 0.74, blue: 0.19), pin: Color(red: 0.60, green: 0.38, blue: 0.04),
            warning: Color(red: 0.64, green: 0.26, blue: 0.12),
            divider: Color(red: 0.20, green: 0.46, blue: 0.63).opacity(0.34),
            activeWash: LinearGradient(
                colors: [Color(rgb: 0x6eaadc).opacity(0.28), Color(rgb: 0x4b95cf).opacity(0.22)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
    )

    static let sunlitLeaf = CardTheme(
        id: "sunlit-leaf", name: "Sunlit Leaf", material: .sunlitLeaf, swatch: Color(rgb: 0xc3dda0),
        palette: CardPalette(
            ink: Color(rgb: 0x173e2b), detail: Color(rgb: 0x41574b),
            activeInk: Color(rgb: 0x074d32), activeDetail: Color(rgb: 0x165737),
            recentInk: Color(rgb: 0x5a636b), recentDetail: Color(rgb: 0x5a636b),
            activeDot: Color(rgb: 0xe7b43d), pin: Color(rgb: 0x896011),
            warning: Color(rgb: 0x8a3d1d), divider: Color(rgb: 0x689159).opacity(0.31),
            activeWash: LinearGradient(
                colors: [Color(rgb: 0xa8cc78).opacity(0.22), Color(rgb: 0x80b578).opacity(0.20)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
    )

    static let builtIn = [graphite, iceBlue, sunlitLeaf]

    static func restoring(_ id: String?) -> CardTheme {
        builtIn.first { $0.id == id } ?? graphite
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                  green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}
