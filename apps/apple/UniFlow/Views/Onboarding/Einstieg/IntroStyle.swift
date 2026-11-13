import SwiftUI

// Neuer Einstieg (Inhaber 13.11.2026: "ähnlich, aber eigen"): Willkommen mit Anmeldung -> kurzer Rundgang -> Hochschule
// und Uni-Anmeldung -> drei Fragen im Gespraech -> Probe und Tarife -> erster Lernplan. Eigene Bildsprache von StudiNow:
// die Farben des App-Icons (Nachtblau, Violett, Tuerkis) nur auf grossen Buehnen, sonst die ruhigen UF-Flaechen; der
// Begleiter ist das StudiNow-Logo selbst (kein Maskottchen). Jede Ansicht ist ein eigener kleiner Typ
// (ViewTypeDepthAppTests).

/// Farben und Masse des Einstiegs
enum IntroStyle {
    /// Farben des App-Icons (StudiNowLogo): Nachtblau oben, Violett links unten, Tuerkis rechts unten
    static let night = Color(hex: 0x0c1450)
    static let violet = Color(hex: 0x7a35dc)
    static let teal = Color(hex: 0x17c3b2)
    /// Text auf der Buehne (immer weiss, auch im hellen Erscheinungsbild)
    static let onStage = Color.white
    static let onStage2 = Color.white.opacity(0.78)

    /// groesste Breite des Inhalts einer Seite
    static let column: CGFloat = 640
    static let bubbleRadius: CGFloat = 18
    static let stageRadius: CGFloat = 28
    /// Hoehe der grossen Knoepfe (Weiter, Los geht's)
    static let ctaHeight: CGFloat = 52
}

/// Buehne in den Farben des App-Icons: Nachtblau, darueber ein violettes und ein tuerkises Leuchten
struct IntroStage: View {
    var radius: CGFloat = IntroStyle.stageRadius

    var body: some View {
        GeometryReader { geo in
            let s = max(geo.size.width, geo.size.height)
            ZStack {
                LinearGradient(colors: [IntroStyle.night, Color(hex: 0x1d1f7a)], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [IntroStyle.violet.opacity(0.85), .clear], center: .bottomLeading, startRadius: 0, endRadius: s * 0.75)
                RadialGradient(colors: [IntroStyle.teal.opacity(0.7), .clear], center: .bottomTrailing, startRadius: 0, endRadius: s * 0.6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Der Begleiter: das StudiNow-Logo im Kreis mit leichtem Leuchten (spricht in den Sprechblasen)
struct IntroBuddy: View {
    var size: CGFloat = 44

    var body: some View {
        UFLogoImage(size: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1.5))
            .shadow(color: IntroStyle.violet.opacity(0.35), radius: size * 0.3, y: size * 0.08)
            .accessibilityHidden(true)
    }
}

/// Sprechblase des Begleiters (links, Flaeche) bzw. Antwort (rechts, Akzent)
struct IntroBubble: View {
    let text: String
    var mine = false
    var large = false

    var body: some View {
        Text(text)
            .ufFont(large ? 19 : 15.5, mine ? 550 : 500)
            .foregroundStyle(mine ? Color.white : UF.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, large ? 14 : 10.5)
            .padding(.horizontal, large ? 18 : 14.5)
            .background(shape.fill(mine ? AnyShapeStyle(UF.accentFill) : AnyShapeStyle(UF.surface)))
            .overlay(shape.strokeBorder(mine ? .clear : UF.line, lineWidth: 1))
            .ufShadow(mine ? .none : .sm)
    }

    /// abgerundet, die Ecke zum Sprecher hin kleiner (wie eine Nachricht)
    private var shape: UnevenRoundedRectangle {
        let r = IntroStyle.bubbleRadius
        return mine
            ? UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: 5, topTrailingRadius: r, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: r, bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
    }
}

/// Begleiter mit Sprechblase in einer Zeile
struct IntroSays: View {
    let text: String
    var large = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IntroBuddy(size: large ? 52 : 40)
            IntroBubble(text: text, large: large)
            Spacer(minLength: 24)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Fortschritt in Abschnitten (Rundgang, Fragen): gefuellt bis `index`, der laufende Abschnitt halb
struct IntroSteps: View {
    let count: Int
    let index: Int
    var onStage = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i <= index ? fill : track)
                    .frame(height: 5)
            }
        }
        .animation(UFMotion.animation(reduce: !UFMotion.moves), value: index)
        .accessibilityElement()
        .accessibilityLabel("Schritt \(index + 1) von \(count)")
    }

    private var fill: Color { onStage ? .white : UF.accent }
    private var track: Color { onStage ? .white.opacity(0.25) : UF.line }
}

/// Kopfzeile einer Seite: zurueck, Fortschritt, Ueberspringen
struct IntroTopBar: View {
    let count: Int
    let index: Int
    var onBack: (() -> Void)?
    var skipTitle = "Überspringen"
    var onSkip: (() -> Void)?

    var body: some View {
        HStack(spacing: 16) {
            Group {
                if let onBack {
                    UFButton(nil, icon: "arrow-left", kind: .ghost, action: onBack)
                        .accessibilityLabel("Zurück")
                        .accessibilityIdentifier("intro.back")
                } else {
                    Color.clear
                }
            }
            .frame(width: 44, height: 44)
            IntroSteps(count: count, index: index).frame(maxWidth: 420)
            Group {
                if let onSkip {
                    Button(skipTitle, action: onSkip)
                        .ufFont(14.5, 550).foregroundStyle(UF.text2)
                        .buttonStyle(.plain)
                        .ufHitArea()
                        .accessibilityIdentifier("intro.skip")
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 110, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
    }
}

/// Grosser Hauptknopf des Einstiegs (Weiter, Los geht's): volle Breite der Spalte, hoechstens 380 pt
struct IntroCTA: View {
    let title: String
    var icon: String? = "arrow-right"
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                if let icon { UFIcon(icon, size: 17) }
            }
            .ufFont(16.5, 650)
            .foregroundStyle(.white)
            .frame(maxWidth: 380, minHeight: IntroStyle.ctaHeight)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(UF.accentFill))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(UFPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityLabel(title)
    }
}

/// Weisse "Glas"-Kachel fuer die Bilder auf der Buehne und im Rundgang (kleine App-Ausschnitte, erfundene Beispiele)
struct IntroTile<Content: View>: View {
    var width: CGFloat?
    @ViewBuilder let content: Content

    init(width: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(14)
            .frame(width: width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(UF.surface))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(UF.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
    }
}

/// Kleine Kopfzeile einer Kachel: Symbol im Farbkreis, Titel
struct IntroTileHead: View {
    let icon: String
    let title: String
    var tint: Color = UF.accent

    var body: some View {
        HStack(spacing: 8) {
            UFIcon(icon, size: 14).foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.opacity(0.14)))
            Text(title).ufFont(13.12, 650).foregroundStyle(UF.text)
        }
    }
}

/// Auswahlzeile (Fragen, Tarife): Symbol, Titel, Unterzeile, Kreis rechts
struct IntroChoiceRow: View {
    let icon: String
    let title: String
    var detail: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                UFIcon(icon, size: 18).foregroundStyle(selected ? UF.accentText : UF.text2)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(selected ? UF.accentSoft : UF.surface2))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).ufFont(15.5, 600).foregroundStyle(UF.text)
                    if let detail { Text(detail).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                Circle().strokeBorder(selected ? UF.accent : UF.lineStrong, lineWidth: selected ? 6.5 : 1.5)
                    .frame(width: 22, height: 22)
            }
            .padding(.vertical, 12).padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? UF.accentSoft.opacity(0.6) : UF.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? UF.accent : UF.line, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
