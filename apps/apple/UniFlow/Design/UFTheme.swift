import SwiftUI
import UIKit

// Design-Tokens 1:1 aus app/static/style.css (:root und :root[data-theme="dark"]).
// Auf dem iPad entspricht 1 CSS-Pixel genau 1 Punkt; rem = 16 pt. Schrift: siehe UFTypeface (Inter wie im Web,
// sonst die Systemschrift).

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
    static let body = Font.uf(14.5)
    static let h1 = Font.uf(23.2, 650)
    static let h2 = Font.uf(17.6, 650)
    static let h3 = Font.uf(15.2, 650)
    static let h4 = Font.uf(13.6, 650)
    static let small = Font.uf(13.12)
    static let tiny = Font.uf(11.84)
    static let lineSpacingBody: CGFloat = 14.5 * 0.5   // line-height 1.5
}

// MARK: Schrift mit CSS-Zeilenhoehe

/// Schrift wie im Browser: Die Web-App laedt "Inter" von Google Fonts (eine variable Datei, angemeldet mit den
/// Gewichten 400/500/600/700) und faellt sonst auf die Systemschrift zurueck (--font: "Inter", …, system-ui).
/// Die App bringt dieselbe Datei mit (Resources/Fonts/Inter-Variable.ttf, UIAppFonts). Wie im Browser:
/// - Gewicht nach CSS-Schriftabgleich auf die angemeldeten Gewichte (550 -> 600, 650 -> 700)
/// - optische Groesse = Schriftgroesse (font-optical-sizing: auto), Achse 14…32
/// Gemessen (Testsatz in 14,5 pt): Safari 531,0 pt, Inter mit diesen Einstellungen 530,6 pt.
/// Ohne Inter (z. B. Datei fehlt): SF mit dem genauen Gewicht ueber die variable Achse "wght".
enum UFTypeface {
    static let interFamily = "Inter"
    static let hasInter: Bool = !UIFont.fontNames(forFamilyName: interFamily).isEmpty
    private static let wghtTag = 0x77676874
    private static let opszTag = 0x6F70737A

    /// CSS-Schriftabgleich fuer die geladenen Schnitte 400/500/600/700
    static func snapped(_ css: CGFloat) -> CGFloat {
        let faces: [CGFloat] = [400, 500, 600, 700]
        if css >= 400 && css <= 500 { return faces.filter { $0 >= css && $0 <= 500 }.first ?? 400 }
        if css > 500 { return faces.first { $0 >= css } ?? 700 }
        return 400
    }

    private static var cache: [String: UIFont] = [:]
    private static let lock = NSLock()

    static func font(_ size: CGFloat, _ css: CGFloat) -> UIFont {
        let key = "\(size)|\(css)"
        lock.lock(); defer { lock.unlock() }
        if let f = cache[key] { return f }
        let variation = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        var f: UIFont
        if hasInter {
            let d = UIFontDescriptor(fontAttributes: [.family: interFamily])
                .addingAttributes([variation: [wghtTag: snapped(css), opszTag: min(32, max(14, size))]])
            f = UIFont(descriptor: d, size: size)
        } else {
            let base = UIFont.systemFont(ofSize: size, weight: UFWeight.ui(css))
            f = UIFont(descriptor: base.fontDescriptor.addingAttributes([variation: [wghtTag: css]]), size: size)
        }
        cache[key] = f
        return f
    }
}

extension UFTypeface {
    /// Breite einer Textzeile ohne Umbruch (fuer Min-Content-Breiten wie im Browser)
    static func width(_ s: String, _ size: CGFloat, _ css: CGFloat = 400) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font(size, css)]).width)
    }
}

enum UFWeight {
    /// CSS-Schriftgewicht -> UIFont-Gewicht (nur fuer die Auswahl des Grundschnitts)
    static func ui(_ css: CGFloat) -> UIFont.Weight {
        let stops: [(CGFloat, CGFloat)] = [(100, -0.8), (200, -0.6), (300, -0.4), (400, 0), (500, 0.23), (600, 0.3), (700, 0.4), (800, 0.56), (900, 0.62)]
        let c = min(900, max(100, css))
        for i in 1..<stops.count where c <= stops[i].0 {
            let (a, b) = (stops[i - 1], stops[i])
            return UIFont.Weight(a.1 + (b.1 - a.1) * (c - a.0) / (b.0 - a.0))
        }
        return .black
    }
}

extension Font {
    /// Schrift der Web-App mit CSS-Gewicht, z. B. `.uf(17.6, 650)` fuer h2
    static func uf(_ size: CGFloat, _ weight: CGFloat = 400) -> Font {
        Font(UFTypeface.font(size, weight))
    }
}

extension View {
    /// Schrift wie im Web inklusive `line-height` (body: 1.5). SwiftUI setzt nur die Zeilenhoehe der Schrift
    /// (SF: etwa 1.19 x Groesse); der Rest kommt als Abstand oben/unten und als Zeilenabstand dazu, damit
    /// Karten, Zeilen und Listen dieselbe Hoehe wie im Browser haben. `em`: letter-spacing in em (h1-h4: -.01).
    func ufFont(_ size: CGFloat, _ weight: CGFloat = 400, lh: CGFloat = 1.5, em: CGFloat = 0) -> some View {
        let extra = max(0, size * lh - UFTypeface.font(size, weight).lineHeight)
        return self.font(.uf(size, weight))
            .tracking(em * size)
            .lineSpacing(extra)
            .padding(.vertical, extra / 2)
    }
}

// MARK: Rahmen wie im CSS-Box-Modell

extension View {
    /// border-bottom: 1px solid var(--line) – die Linie nimmt wie im Browser 1 pt Hoehe ein
    func ufBorderBottom(_ show: Bool = true, color: Color = UF.line) -> some View {
        padding(.bottom, show ? 1 : 0)
            .overlay(alignment: .bottom) { if show { Rectangle().fill(color).frame(height: 1) } }
    }
}

/// Rahmenbreite, die im Browser zum Innenabstand dazukommt (border-box: Inhalt + padding + border);
/// strokeBorder in SwiftUI liegt dagegen innerhalb des Innenabstands.
let ufB: CGFloat = 1

// MARK: Schatten (--sh-sm, --sh, --sh-lg). CSS-Unschaerfe b entspricht etwa SwiftUI-Radius b/2.
enum UFShadow {
    case none, sm, md, lg
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
        case .none: (0, 0, 0)
        case .sm: (dark ? 0.4 : 0.05, 1, 1)
        case .md: (dark ? 0.4 : 0.06, 8, 4)
        case .lg: (dark ? 0.6 : 0.14, 20, 16)
        }
        // compositingGroup: Schatten der ganzen Flaeche wie box-shadow, nicht je Kindelement
        return content.compositingGroup().shadow(color: base.opacity(p.opacity), radius: p.radius, x: 0, y: p.y)
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
