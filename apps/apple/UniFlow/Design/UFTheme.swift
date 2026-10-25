import SwiftUI
import UIKit

// Design-Tokens 1:1 aus app/static/style.css (:root und :root[data-theme="dark"]).
// Auf dem iPad entspricht 1 CSS-Pixel genau 1 Punkt; rem = 16 pt. Schrift: die Web-App nutzt
// "Inter, Segoe UI, system-ui, -apple-system" – auf dem iPad ist das die Systemschrift (SF Pro).

extension Color {
    /// Farbe mit getrenntem Wert fuer hell/dunkel (folgt dem Erscheinungsbild bzw. der App-Einstellung).
    init(light: UInt32, dark: UInt32, alpha: Double = 1) {
        self.init(UIColor { trait in
            let v = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                           blue: CGFloat(v & 0xff) / 255, alpha: alpha)
        })
    }

    /// feste Farbe; Modulfarben als Zeichenkette ("#rrggbb") deckt `Color(hex: String?)` in RemoteData.swift ab
    init(hex: UInt32) { self.init(light: hex, dark: hex) }
}

enum UF {
    // MARK: Farben (--bg, --surface, …)
    static let bg = Color(light: 0xf6f7fb, dark: 0x0f1117)
    static let surface = Color(light: 0xffffff, dark: 0x171a23)
    static let surface2 = Color(light: 0xf1f3f9, dark: 0x1f2330)
    static let line = Color(light: 0xe5e8f0, dark: 0x262b3a)
    static let lineStrong = Color(light: 0xd3d8e4, dark: 0x333a4d)
    static let text = Color(light: 0x171a26, dark: 0xe8eaf2)
    static let text2 = Color(light: 0x4b5168, dark: 0xb3b9cc)
    static let muted = Color(light: 0x7a8199, dark: 0x7f879d)
    static let accent = Color(light: 0x4f5bd5, dark: 0x7b86f0)
    static let accentStrong = Color(light: 0x3f4bc2, dark: 0x6a76e8)
    static let accentSoft = Color(light: 0xeceefc, dark: 0x232848)
    static let accentText = Color(light: 0x3a45b4, dark: 0xa9b1ff)
    static let ok = Color(light: 0x1f9d5b, dark: 0x3fbf7c)
    static let okSoft = Color(light: 0xe3f6ec, dark: 0x173327)
    static let warn = Color(light: 0xd9851e, dark: 0xe9a04a)
    static let warnSoft = Color(light: 0xfdf0dc, dark: 0x3a2a14)
    static let bad = Color(light: 0xd64545, dark: 0xef6b6b)
    static let badSoft = Color(light: 0xfbe5e5, dark: 0x3d1d1d)
    static let info = Color(light: 0x2f7fd1, dark: 0x5aa0e8)
    static let infoSoft = Color(light: 0xe4effb, dark: 0x172a40)
    /// Verlauf des Logos: linear-gradient(135deg, var(--accent), #8b5cf6)
    static let logoGradient = LinearGradient(colors: [accent, Color(hex: 0x8b5cf6)], startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: Radien, Masse
    static let rSm: CGFloat = 8          // --r-sm
    static let r: CGFloat = 12           // --r
    static let rLg: CGFloat = 16         // --r-lg
    static let sidebar: CGFloat = 248    // --sidebar
    static let sidebarMin: CGFloat = 68  // --sidebar-min
    static let header: CGFloat = 56      // --header
    static let transition = Animation.easeInOut(duration: 0.16)   // --t: .16s ease

    // MARK: Schrift (body 14.5px/1.5, h1 1.45rem, h2 1.1rem, h3 .95rem, h4 .85rem, .small .82rem, .tiny .74rem; Gewicht 650)
    static let body = Font.system(size: 14.5)
    static let h1 = Font.system(size: 23.2, weight: .semibold)
    static let h2 = Font.system(size: 17.6, weight: .semibold)
    static let h3 = Font.system(size: 15.2, weight: .semibold)
    static let h4 = Font.system(size: 13.6, weight: .semibold)
    static let small = Font.system(size: 13.12)
    static let tiny = Font.system(size: 11.84)
    static let lineSpacingBody: CGFloat = 14.5 * 0.5   // line-height 1.5
}

// MARK: Schatten (--sh-sm, --sh, --sh-lg). CSS-Unschaerfe b entspricht etwa SwiftUI-Radius b/2.
enum UFShadow {
    case sm, md, lg
}

extension View {
    func ufShadow(_ s: UFShadow) -> some View {
        modifier(UFShadowModifier(kind: s))
    }
}

private struct UFShadowModifier: ViewModifier {
    let kind: UFShadow
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let base = dark ? Color.black : Color(red: 20 / 255, green: 24 / 255, blue: 40 / 255)
        let p: (opacity: Double, radius: CGFloat, y: CGFloat) = switch kind {
        case .sm: (dark ? 0.4 : 0.05, 1, 1)
        case .md: (dark ? 0.4 : 0.06, 8, 4)
        case .lg: (dark ? 0.6 : 0.14, 20, 16)
        }
        return content.shadow(color: base.opacity(p.opacity), radius: p.radius, x: 0, y: p.y)
    }
}

// MARK: Icons – dieselben SVGs wie im Web (Assets.xcassets/Icons, erzeugt mit tools/gen-ios-icons.mjs)

/// `icon(name, size)` aus app/static/icons.js: 24er-Raster, Strichstaerke 2, folgt der Vordergrundfarbe.
/// Unbekannte Namen fallen wie im Web auf "file" zurueck.
struct UFIcon: View {
    let name: String
    var size: CGFloat = 18

    init(_ name: String, size: CGFloat = 18) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image(UFIconNames.all.contains(name) ? "uf-\(name)" : "uf-file")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
