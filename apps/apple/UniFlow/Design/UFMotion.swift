import SwiftUI
import UIKit

// Bewegung im Designsystem (Auftrag des Inhabers 03.11.2026). Vorbild sind die Muster aus motion-primitives
// (animated-group/in-view, sliding-number, transition-panel, disclosure, text-shimmer), hier eigenstaendig in SwiftUI
// umgesetzt: kurze Dauern (0.18-0.35 s), Federn ohne Ueberschwingen, nichts wartet auf eine Animation.
// "Bewegung reduzieren" (Bedienungshilfen): keine Lage- oder Groessenaenderung, hoechstens eine Ueberblendung.
// Unter XCTest ist alle Bewegung aus, damit Tests und gerenderte Bilder sofort den Endzustand sehen.

enum UFMotion {
    /// Dauern in Sekunden
    static let quick: Double = 0.18
    static let base: Double = 0.26
    static let slow: Double = 0.34
    /// Versatz zwischen zwei Karten beim gestaffelten Erscheinen; ab der achten Karte kein weiterer Versatz
    static let stagger: Double = 0.04
    static let staggerCap = 8

    /// unter XCTest (App als Testwirt) keine Bewegung
    static let isTesting: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
    }()

    /// Bewegung erlaubt: nicht unter XCTest und ohne "Bewegung reduzieren"
    static var moves: Bool { !isTesting && !UIAccessibility.isReduceMotionEnabled }

    /// Feder ohne Ueberschwingen (bounce 0) fuer Lage und Hoehe
    static let springCurve = Animation.spring(duration: base, bounce: 0)
    /// Ueberblendung (auch bei "Bewegung reduzieren")
    static let fadeCurve = Animation.easeInOut(duration: quick)

    /// Animation fuer Aufklappen, Reiter und Zahlen; nil unter XCTest. Bei "Bewegung reduzieren" nur eine kurze
    /// Ueberblendung, wenn `fadeWhenReduced` gesetzt ist (sonst springt die Ansicht wie bisher)
    static func animation(reduce: Bool, fadeWhenReduced: Bool = true) -> Animation? {
        if isTesting { return nil }
        if reduce { return fadeWhenReduced ? fadeCurve : nil }
        return springCurve
    }

    /// Auf- und Zuklappen wie accordion/disclosure: Hoehe und Deckkraft mit der Feder. Bei "Bewegung reduzieren"
    /// ohne Animation (die Hoehenaenderung waere Bewegung)
    static func toggle(_ change: () -> Void) {
        if moves { withAnimation(springCurve, change) } else { change() }
    }

    /// Uebergang fuer aufklappende Inhalte: von oben einblenden, beim Zuklappen schneller ausblenden
    static var reveal: AnyTransition {
        guard moves else { return .identity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: -6)),
                           removal: .opacity.animation(.easeOut(duration: 0.12)))
    }

    /// Verzoegerung der i-ten Karte beim gestaffelten Erscheinen
    static func delay(_ index: Int) -> Double { Double(min(max(index, 0), staggerCap)) * stagger }
}

// MARK: - Gestaffeltes Erscheinen (animated-group / in-view)

/// Merkt sich, welche Gruppen (Seiten) in dieser Sitzung schon erschienen sind: Karten staffeln sich nur beim ersten
/// Erscheinen, nicht bei jedem Neuladen oder Zurueckkehren (nur vom Hauptthread aus benutzt)
enum UFAppearOnce {
    private static var seen: Set<String> = []

    static func hasAppeared(_ group: String) -> Bool { seen.contains(group) }

    /// erst nach dem Erscheinen der ganzen Gruppe als gesehen merken (alle Karten derselben Darstellung staffeln sich)
    static func markSoon(_ group: String) {
        guard !seen.contains(group) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { seen.insert(group) }
    }

    /// nur fuer Tests
    static func mark(_ group: String) { seen.insert(group) }
    static func reset() { seen.removeAll() }
}

private struct UFAppearModifier: ViewModifier {
    let group: String
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown: Bool

    init(group: String, index: Int) {
        self.group = group
        self.index = index
        _shown = State(initialValue: UFMotion.isTesting || UFAppearOnce.hasAppeared(group))
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduce ? 0 : 10)                            // reduziert: nur Ueberblendung
            .onAppear {
                guard !shown else { return }
                UFAppearOnce.markSoon(group)
                let curve = reduce ? UFMotion.fadeCurve : Animation.spring(duration: UFMotion.slow, bounce: 0)
                withAnimation(curve.delay(UFMotion.delay(index))) { shown = true }
            }
    }
}

// MARK: - Zahlen (animated-number / sliding-number)

private struct UFNumberModifier<V: Equatable>: ViewModifier {
    let value: V
    let numeric: Double?
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content
            // Ziffern rollen weich zur neuen Zahl; reduziert nur Ueberblendung
            .contentTransition(reduce ? .opacity : (numeric.map { .numericText(value: $0) } ?? .numericText()))
            .animation(UFMotion.animation(reduce: reduce), value: value)
    }
}

// MARK: - Reiterwechsel (transition-panel)

private struct UFTabPanelModifier<V: Hashable>: ViewModifier {
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        // der alte Reiter verschwindet sofort (kein Doppelinhalt, kein Springen), der neue blendet leicht steigend ein
        ZStack(alignment: .topLeading) {
            content
                .id(value)
                .transition(.asymmetric(insertion: reduce ? .opacity : .opacity.combined(with: .offset(y: 6)), removal: .identity))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(UFMotion.animation(reduce: reduce), value: value)
    }
}

// MARK: - Druck-Rueckmeldung

/// Karte oder Knopf gibt beim Druecken leicht nach (0.98); das Aussehen bleibt sonst unveraendert. Bei "Bewegung
/// reduzieren" ohne Groessenaenderung
struct UFPressStyle: ButtonStyle {
    var scale: CGFloat = 0.98
    @Environment(\.accessibilityReduceMotion) private var reduce

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduce ? scale : 1)
            .animation(reduce || UFMotion.isTesting ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Schimmer fuer Lade-Texte (text-shimmer)

/// Lade-Text mit dezentem Lichtstreif, der von links nach rechts ueber die Schrift wandert. Bei "Bewegung
/// reduzieren" und unter XCTest ruhiger Text
struct UFShimmerText: View {
    let text: String
    var size: CGFloat = 13.12
    var weight: CGFloat = 400
    var color: Color = UF.muted
    var highlight: Color = UF.text
    /// Dauer eines Durchlaufs
    var duration: Double = 1.8
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var phase: CGFloat = 0

    init(_ text: String, size: CGFloat = 13.12, weight: CGFloat = 400, color: Color = UF.muted, highlight: Color = UF.text) {
        self.text = text
        self.size = size
        self.weight = weight
        self.color = color
        self.highlight = highlight
    }

    var body: some View {
        let label = Text(text).ufFont(size, weight)
        if reduce || UFMotion.isTesting {
            label.foregroundStyle(color)
        } else {
            label.foregroundStyle(color)
                .overlay {
                    // gleiche Schrift in der Hervorhebungsfarbe, nur innerhalb eines schmalen, wandernden Bandes sichtbar
                    label.foregroundStyle(highlight)
                        .mask {
                            GeometryReader { g in
                                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.85), location: 0.5),
                                                       .init(color: .clear, location: 1)],
                                               startPoint: .leading, endPoint: .trailing)
                                    .frame(width: max(g.size.width * 0.45, 40))
                                    .offset(x: phase * (g.size.width * 1.45 + 40) - max(g.size.width * 0.45, 40))
                            }
                        }
                        .accessibilityHidden(true)
                }
                .onAppear {
                    phase = 0
                    withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) { phase = 1 }
                }
        }
    }
}

// MARK: - Bausteine fuer die Seiten

extension View {
    /// Karte erscheint beim ersten Anzeigen der Gruppe leicht gestaffelt (Deckkraft und 10 pt von unten)
    func ufAppear(_ group: String, index: Int) -> some View {
        modifier(UFAppearModifier(group: group, index: index))
    }

    /// Zahl oder Kennzahl wechselt mit rollenden Ziffern; `numeric` gibt die Richtung vor (aufwaerts/abwaerts)
    func ufNumber<V: Equatable>(_ value: V, numeric: Double? = nil) -> some View {
        modifier(UFNumberModifier(value: value, numeric: numeric))
    }

    /// Inhalt eines Reiters: beim Wechsel sanft einblenden
    func ufTabPanel<V: Hashable>(_ value: V) -> some View {
        modifier(UFTabPanelModifier(value: value))
    }

    /// Aufklappender Inhalt (mit `UFMotion.toggle` umgeschaltet)
    func ufReveal() -> some View {
        transition(UFMotion.reveal)
    }
}
