import SwiftUI
import UniFlowCore

// Gestaltung der Community: verspielt, aber modern und einfach (Auftrag des Inhabers 03.11.2026,
// docs/DESIGN-COMMUNITY-VERSPIELT-2026-11-03.md). Jede Community traegt die Farbe ihres Moduls (Fachfarbe), jede Person
// eine feste Pastellfarbe aus ihrem Pseudonym, jede Art eines Blatts ein eigenes weiches Etikett mit Symbol. Schrift auf
// Tonflaechen nutzt immer die dunklere Textstufe (hell >= 4,5:1, dunkel die helle Stufe). Bewegung nur als kurze
// Rueckmeldung (Like-Stern, gestaffeltes Erscheinen), mit "Bewegung reduzieren" ohne Lageaenderung.

// MARK: - Farben

/// Pastellpaare: Flaeche (`bg`), Schrift/Symbol darauf (`fg`, Kontrast >= 4,5:1 in hell und dunkel) und ein satter
/// Ton fuer Fuellungen (`solid`, z. B. der gefuellte Stern)
struct CommunityPair: Equatable {
    let bg: Color
    let fg: Color
    let solid: Color
}

enum CommunityPalette {
    static let sky = CommunityPair(bg: Color(light: 0xe2eefc, dark: 0x182a40), fg: Color(light: 0x1d5ea6, dark: 0x93c2f5), solid: Color(light: 0x3b82d6, dark: 0x6aa8ec))
    static let mint = CommunityPair(bg: Color(light: 0xdcf4e6, dark: 0x163226), fg: Color(light: 0x146c43, dark: 0x86dcb0), solid: Color(light: 0x2a9d62, dark: 0x4cc58a))
    static let peach = CommunityPair(bg: Color(light: 0xfde9d9, dark: 0x3a2616), fg: Color(light: 0x974708, dark: 0xf4b682), solid: Color(light: 0xea7a2c, dark: 0xf09a5a))
    static let lavender = CommunityPair(bg: Color(light: 0xebe6fc, dark: 0x262043), fg: Color(light: 0x5537ad, dark: 0xbcaaf7), solid: Color(light: 0x7c5ce0, dark: 0x9d86f0))
    static let rose = CommunityPair(bg: Color(light: 0xfde4ea, dark: 0x3b1e27), fg: Color(light: 0xa12346, dark: 0xf6a5bb), solid: Color(light: 0xe0486f, dark: 0xee7393))
    static let teal = CommunityPair(bg: Color(light: 0xd8f2f0, dark: 0x123130), fg: Color(light: 0x0d6964, dark: 0x74d6cd), solid: Color(light: 0x14a39a, dark: 0x3cc2b8))
    static let butter = CommunityPair(bg: Color(light: 0xfcf1c9, dark: 0x352e14), fg: Color(light: 0x765800, dark: 0xebd27a), solid: Color(light: 0xf2b316, dark: 0xf0c24a))
    static let lilac = CommunityPair(bg: Color(light: 0xf7e2f4, dark: 0x351f38), fg: Color(light: 0x8a2a82, dark: 0xeaa6e1), solid: Color(light: 0xc24bb6, dark: 0xd77ccd))

    /// Reihenfolge der Personenfarben (Pseudonym -> fester Platz)
    static let people = [sky, mint, peach, lavender, rose, teal, butter, lilac]

    /// eigene Person: Akzent der App
    static let own = CommunityPair(bg: UF.accentSoft, fg: UF.accentText, solid: UF.accentFill)

    /// Farbe einer Person aus ihrem Pseudonym: auf jedem Geraet und bei jedem Start gleich (kein `hashValue`)
    static func person(_ name: String) -> CommunityPair {
        people[Int(stableHash(name.trimmingCharacters(in: .whitespaces).lowercased()) % UInt64(people.count))]
    }

    /// FNV-1a ueber UTF-8: stabil ueber Starts hinweg
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}

/// Farbe einer Community: die Fachfarbe des Moduls (aus dem Abgleich), sonst eine feste Farbe derselben Palette aus dem
/// Schluessel; Lerngruppen im Akzent der App
@MainActor
enum CommunityTint {
    /// Schluessel der Community -> "#rrggbb" aus den eigenen Modulen
    private(set) static var known: [String: String] = [:]

    static func hex(_ key: String) -> String {
        if let h = known[key] { return h }
        let p = ModuleColors.palette
        return p[Int(CommunityPalette.stableHash(key) % UInt64(p.count))]
    }

    static func color(_ space: CommunitySpace) -> Color {
        space.kind == .group ? UF.accent : Color(hex: hex(space.key))
    }

    /// Schrift und Symbole in der Fachfarbe auf heller bzw. dunkler Flaeche: Richtung Textfarbe gemischt, damit auch
    /// helle Fachfarben (Oliv, Ocker) lesbar bleiben
    static func ink(_ c: Color) -> Color { Color.mix(c, 0.72, UF.text) }

    /// blasse Flaeche in der Fachfarbe
    static func wash(_ c: Color, _ p: Double = 0.14) -> Color { Color.mix(c, p, UF.surface) }

    static func remember(_ key: String, hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7 else { return }
        known[key] = hex.lowercased()
    }

    /// Fachfarben der eigenen Module (eine Abfrage `/api/modules`): Modulname -> Schluessel wie die Community
    static func load(api: APIClient, university: String) async {
        guard let list = try? await api.value("/api/modules") else { return }
        for m in list.items {
            guard let name = m.s("name"), let key = CommunityKeys.courseKey(university: university, courseName: name) else { continue }
            remember(key, hex: m.s("color"))
        }
    }
}

extension CommunityChannelKind {
    /// eigenes weiches Paar je Art (Etikett, Vorschauflaeche)
    var pair: CommunityPair {
        switch self {
        case .vorlesung: return CommunityPalette.sky
        case .hoersaaluebung: return CommunityPalette.lavender
        case .uebung: return CommunityPalette.mint
        case .gruppenuebung: return CommunityPalette.teal
        case .tutorium: return CommunityPalette.peach
        case .klausur: return CommunityPalette.rose
        case .notizen: return CommunityPalette.butter
        }
    }
}

// MARK: - Personen

/// Initialen im Kreis in der festen Pastellfarbe der Person (eigene Person im Akzent)
struct CommunityAvatar: View {
    let name: String
    var size: CGFloat = 28
    var own = false
    /// Rand in der Flaechenfarbe (fuer ueberlappende Reihen)
    var ring = false

    var body: some View {
        let ini = ShellState.initials(of: name)
        let pair = own ? CommunityPalette.own : CommunityPalette.person(name)
        Text(ini.isEmpty ? "?" : ini)
            .font(.uf(size * 0.38, 650))
            .foregroundStyle(pair.fg)
            .frame(width: size, height: size)
            .background(Circle().fill(pair.bg))
            .overlay { if ring { Circle().strokeBorder(UF.surface, lineWidth: max(1.5, size * 0.08)) } }
            .accessibilityHidden(true)
    }
}

/// Bis zu drei Personen leicht ueberlappend, danach "+N"
struct CommunityAvatarStack: View {
    let names: [String]
    var size: CGFloat = 22
    var limit = 3

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(names.prefix(limit).enumerated()), id: \.offset) { _, n in
                CommunityAvatar(name: n, size: size, ring: true)
            }
            if names.count > limit {
                Text("+\(names.count - limit)").font(.uf(size * 0.4, 650)).foregroundStyle(UF.text2)
                    .frame(width: size, height: size)
                    .background(Circle().fill(UF.surface2))
                    .overlay(Circle().strokeBorder(UF.surface, lineWidth: max(1.5, size * 0.08)))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Etikett der Art

/// Weiches Etikett mit Symbol: jede Art hat ihre Farbe (Vorlesung himmelblau, Uebung mint, Klausur rosa …)
struct CommunityKindTag: View {
    let kind: CommunityChannelKind
    /// auf einer Vorschau: leicht abgehoben
    var floating = false

    var body: some View {
        HStack(spacing: 4) {
            UFIcon(kind.icon, size: 11)
            Text(kind.title)
        }
        .ufFont(11.52, 620)
        .lineLimit(1)
        .foregroundStyle(kind.pair.fg)
        .padding(.vertical, 3).padding(.horizontal, 8)
        .background(Capsule().fill(kind.pair.bg))
        .overlay { if floating { Capsule().strokeBorder(UF.surface.opacity(0.9), lineWidth: 1.5) } }
        .accessibilityHidden(true)
    }
}

// MARK: - Leerzustand mit kleiner Bildkomposition

/// Kleine Komposition aus Symbolen statt eines einzelnen grauen Symbols: grosser Kreis in der Farbe der Community,
/// zwei kleine Begleiter in Pastell, ein Funken. Rein dekorativ (VoiceOver liest nur den Text).
struct CommunityEmptyArt: View {
    let icon: String
    var companions: [String] = ["note", "star"]
    var tint: Color = UF.accent

    var body: some View {
        ZStack {
            Circle().fill(CommunityTint.wash(tint, 0.16)).frame(width: 68, height: 68)
            UFIcon(icon, size: 28).foregroundStyle(CommunityTint.ink(tint))
            if let first = companions.first {
                bubble(first, CommunityPalette.peach).offset(x: -40, y: 18).rotationEffect(.degrees(-8))
            }
            if companions.count > 1 {
                bubble(companions[1], CommunityPalette.butter).offset(x: 40, y: -20).rotationEffect(.degrees(10))
            }
            Circle().fill(CommunityPalette.mint.solid.opacity(0.55)).frame(width: 7, height: 7).offset(x: 30, y: 30)
            Circle().fill(CommunityPalette.lavender.solid.opacity(0.5)).frame(width: 5, height: 5).offset(x: -30, y: -28)
        }
        .frame(width: 140, height: 84)
        .accessibilityHidden(true)
    }

    private func bubble(_ name: String, _ pair: CommunityPair) -> some View {
        UFIcon(name, size: 15).foregroundStyle(pair.fg)
            .frame(width: 34, height: 34)
            .background(Circle().fill(pair.bg))
            .overlay(Circle().strokeBorder(UF.surface, lineWidth: 3))
    }
}

/// Leerzustand: Komposition, kurzer Titel, ein Satz, hoechstens eine Handlung
struct CommunityEmptyState<Action: View>: View {
    let icon: String
    var companions: [String] = ["note", "star"]
    var tint: Color = UF.accent
    var title: String?
    let text: String
    @ViewBuilder var action: Action

    init(icon: String, companions: [String] = ["note", "star"], tint: Color = UF.accent, title: String? = nil, text: String,
         @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.icon = icon
        self.companions = companions
        self.tint = tint
        self.title = title
        self.text = text
        self.action = action()
    }

    var body: some View {
        VStack(spacing: 10) {
            CommunityEmptyArt(icon: icon, companions: companions, tint: tint)
            VStack(spacing: 4) {
                if let title {
                    Text(title).ufFont(15.2, 650).foregroundStyle(UF.text).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(text).ufFont(13.6, lh: 1.5).foregroundStyle(UF.text2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 420)
            action.padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22).padding(.horizontal, 16)
    }
}

// MARK: - Gefaellt mir: Stern mit kleinem Funkenflug

/// Stern wie `UFIcon("star")` (gleiche Form), gefuellt, wenn gemocht. Beim Moegen springt er kurz auf und sechs Funken
/// fliegen heraus (0,45 s); "Bewegung reduzieren" und Tests: nur der Farbwechsel
struct CommunityLikeStar: View {
    let liked: Bool
    var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var pops = 0

    private struct Burst {
        var scale: CGFloat = 1
        var radius: CGFloat = 0
        var opacity: Double = 0
    }

    var body: some View {
        ZStack {
            if liked {
                StarShape().fill(CommunityPalette.butter.solid)
                    .frame(width: size * 20 / 24, height: size * 19.02 / 24)
                    .offset(y: -size * 0.49 / 24)
            }
            UFIcon("star", size: size)
                .foregroundStyle(liked ? AnyShapeStyle(CommunityPalette.butter.fg) : AnyShapeStyle(.foreground))
        }
        .frame(width: size, height: size)
        .keyframeAnimator(initialValue: Burst(), trigger: pops) { content, v in
            content
                .scaleEffect(v.scale)
                .overlay {
                    ForEach(0..<6, id: \.self) { i in
                        let a = Double(i) / 6 * 2 * .pi - .pi / 2
                        Circle().fill(i.isMultiple(of: 2) ? CommunityPalette.butter.solid : CommunityPalette.rose.solid)
                            .frame(width: 3.5, height: 3.5)
                            .offset(x: cos(a) * v.radius, y: sin(a) * v.radius)
                            .opacity(v.opacity)
                    }
                }
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                CubicKeyframe(1.35, duration: 0.12)
                SpringKeyframe(1, duration: 0.33, spring: .bouncy)
            }
            KeyframeTrack(\.radius) {
                LinearKeyframe(size * 0.45, duration: 0.01)
                CubicKeyframe(size * 1.05, duration: 0.42)
            }
            KeyframeTrack(\.opacity) {
                LinearKeyframe(1, duration: 0.01)
                LinearKeyframe(1, duration: 0.16)
                LinearKeyframe(0, duration: 0.26)
            }
        }
        .onChange(of: liked) { _, now in
            if now && !reduce && UFMotion.moves { pops += 1 }
        }
        .sensoryFeedback(trigger: liked) { _, now in now ? .impact(flexibility: .soft, intensity: 0.6) : nil }
        .accessibilityHidden(true)
    }
}

/// Stern im 24er-Raster von `uf-star` (m12 2 3.09 6.26L22 9.27l-5 4.87 1.18 6.88L12 17.77l-6.18 3.25L7 14.14 2 9.27l6.91-1.01z)
struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let pts: [(CGFloat, CGFloat)] = [(12, 2), (15.09, 8.26), (22, 9.27), (17, 14.14), (18.18, 21.02), (12, 17.77),
                                         (5.82, 21.02), (7, 14.14), (2, 9.27), (8.91, 8.26)]
        let sx = rect.width / 20, sy = rect.height / 19.02         // Ausdehnung des Sterns: x 2…22, y 2…21,02
        var p = Path()
        for (i, (x, y)) in pts.enumerated() {
            let q = CGPoint(x: rect.minX + (x - 2) * sx, y: rect.minY + (y - 2) * sy)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        p.closeSubpath()
        return p
    }
}
