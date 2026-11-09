import CoreGraphics
import Foundation
import SwiftUI

/// Schreibhand und geteilte Ansicht ("Daneben öffnen"): welche Seite die Spalte daneben bekommt, und das Tauschen der
/// Seiten an der Kopfzeile (UniFlowTests/SplitSidesAppTests.swift).
///
/// Einstellung "Schreibhand" (`uniflow.hand`, "right" | "left", Standard "right"): "Seitenleiste und Skript in der
/// geteilten Ansicht liegen auf der Seite der freien Hand".
enum SplitSides {
    /// Schluessel der getauschten Paare (Hauptdokument|Spalte daneben, durch Zeilenumbruch getrennt)
    static let swappedKey = "uniflow.splitSwapped"
    /// so viele getauschte Paare bleiben gemerkt (die aeltesten fallen heraus)
    static let maxSwapped = 100

    /// Seite der freien Hand: Rechtshaender links, Linkshaender rechts; ein unbekannter Wert gilt wie der Standard
    static func freeHandLeft(hand: String) -> Bool { hand != "left" }

    /// Was in der Spalte daneben liegt
    enum Role: Equatable {
        /// zum Lesen (Skript, Loesung): Seite der freien Hand
        case reference
        /// zum Schreiben (leeres Blatt, Uebungsblatt neben der Folie): Seite der Schreibhand
        case writing
    }

    /// Uebungsblatt, Loesung oder Klausur (wie `isExercise` in views-doc.js)
    static func isExercise(_ f: LibFile) -> Bool {
        if ["uebung", "loesung", "klausur"].contains(f.doc_type ?? "") { return true }
        let text = (f.name + " " + (f.studip_folder ?? "")).lowercased()
        return ["übung", "uebung", "blatt", "aufgabe"].contains { text.contains($0) }
    }

    /// Rolle der Spalte daneben; `side` nil = Loesung zum Ansehen. Zum Schreiben ist sie, wenn sie ein Blatt (Notizbuch)
    /// oder eine Uebung ist und das Hauptdokument keins von beiden (z. B. das Skript); sonst zum Lesen. Bis Build 27
    /// lag jede Spalte daneben auf der Seite der freien Hand - das leere Blatt neben der Folie damit unter der falschen Hand.
    static func role(side: LibFile?, primary: LibFile) -> Role {
        guard let side else { return .reference }
        let writes = { (f: LibFile) in f.isNotebook || isExercise(f) }
        return writes(side) && !writes(primary) ? .writing : .reference
    }

    /// Spalte daneben links (true) oder rechts; `swapped` = an der Kopfzeile getauscht
    static func sidePaneLeft(hand: String, role: Role, swapped: Bool = false) -> Bool {
        let free = freeHandLeft(hand: hand)
        let left = role == .reference ? free : !free
        return swapped ? !left : left
    }

    // MARK: Seiten tauschen

    /// Kennung des Paars; `side` = Datei daneben oder "loesung:<id>"
    static func pairKey(primary: String, side: String) -> String { primary + "|" + side }

    static func isSwapped(_ stored: String, key: String) -> Bool {
        stored.split(separator: "\n").contains { $0 == key }
    }

    /// gemerkte Paare nach einem Tausch (getauscht -> zurueck, sonst neu ans Ende)
    static func toggling(_ stored: String, key: String) -> String {
        var keys = stored.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if let i = keys.firstIndex(of: key) { keys.remove(at: i) } else { keys.append(key) }
        return keys.suffix(maxSwapped).joined(separator: "\n")
    }

    /// Loslassen beim Ziehen an der Kopfzeile: nur ueber der anderen Haelfte wird getauscht
    static func dropSwaps(sidePaneLeft: Bool, x: CGFloat, width: CGFloat) -> Bool {
        guard width > 0 else { return false }
        return sidePaneLeft ? x > width / 2 : x < width / 2
    }

    /// Text unter "Lösung daneben ansehen" (die Loesung liegt auf der Seite der freien Hand)
    static func solutionHint(hand: String) -> String {
        freeHandLeft(hand: hand) ? "Links die Lösung, rechts deine Folie auf derselben Seite."
                                 : "Links deine Folie, rechts die Lösung auf derselben Seite."
    }
}

// MARK: - Bedienung in der geteilten Ansicht

/// Seiten tauschen an der Kopfzeile der Spalte daneben (`UFPaneHeader` liest es aus der Umgebung; ohne Wert keine Geste)
struct UFPaneSwap {
    /// Ziehen laeuft (`active`), Lage im Koordinatenraum "split" (nil = gedrueckt, noch nicht bewegt); `active` false = vorbei
    var moved: (_ active: Bool, _ x: CGFloat?) -> Void
    /// losgelassen an `x`
    var ended: (_ x: CGFloat) -> Void
    /// sofort tauschen (VoiceOver, Menue)
    var swapNow: () -> Void

    static let actionName = "Seiten tauschen"
    static let hint = "Kopfzeile gedrückt halten und zur anderen Seite ziehen, um die Seiten zu tauschen."
}

private struct UFPaneSwapKey: EnvironmentKey {
    static let defaultValue: UFPaneSwap? = nil
}

extension EnvironmentValues {
    var ufPaneSwap: UFPaneSwap? {
        get { self[UFPaneSwapKey.self] }
        set { self[UFPaneSwapKey.self] = newValue }
    }
}

/// Lange druecken, dann ziehen - nur auf der Kopfzeile (kein Zeichenbereich: der Stift zeichnet dort nie)
struct UFPaneSwapGesture: ViewModifier {
    let swap: UFPaneSwap?
    /// nil = keine Geste; sonst gedrueckt, mit Lage (nil = noch nicht bewegt)
    @GestureState private var drag: CGFloat?? = nil

    func body(content: Content) -> some View {
        if let swap {
            content
                .contentShape(Rectangle())
                .gesture(
                    LongPressGesture(minimumDuration: 0.35)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: NamedCoordinateSpace.named("split")))
                        .updating($drag) { v, state, _ in
                            if case .second(true, let d) = v { state = .some(d?.location.x) }
                        }
                        .onEnded { v in
                            if case .second(true, let d) = v, let d { swap.ended(d.location.x) }
                        }
                )
                .onChange(of: drag) { _, d in
                    if let d { swap.moved(true, d) } else { swap.moved(false, nil) }
                }
                .accessibilityAction(named: UFPaneSwap.actionName, swap.swapNow)
                .accessibilityHint(UFPaneSwap.hint)
        } else {
            content
        }
    }
}

/// Hinweis beim Ziehen: die andere Haelfte leuchtet, der Text sagt, was beim Loslassen geschieht
struct SplitSwapHint: View {
    /// Spalte daneben liegt links
    let sideLeft: Bool
    /// Lage des Fingers (nil = noch nicht bewegt)
    let x: CGFloat?
    let width: CGFloat

    var body: some View {
        let over = x.map { SplitSides.dropSwaps(sidePaneLeft: sideLeft, x: $0, width: width) } ?? false
        HStack(spacing: 0) {
            if !sideLeft { target(over) }
            Color.clear
            if sideLeft { target(over) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func target(_ over: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(UF.accent.opacity(over ? 0.18 : 0.07))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(UF.accent, style: StrokeStyle(lineWidth: 2, dash: over ? [] : [8, 6])))
            .overlay {
                Label(over ? "Loslassen: Seiten tauschen" : "Hierher ziehen zum Tauschen", systemImage: "arrow.left.arrow.right")
                    .font(.headline).foregroundStyle(UF.text)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(8)
            .frame(width: width / 2)
            .accessibilityIdentifier("doc.split.swapHint")
    }
}

/// Spalte daneben (mit Griff) links oder rechts neben dem Hauptdokument. Die Unteransichten bleiben dieselben, wenn die
/// Seite wechselt (ein HStack mit zwei `if`-Zweigen legte das zweite Dokument beim Tauschen neu an: Seite und Zoom weg).
/// Letzte Unteransicht = Hauptdokument (fuellt den Rest), davor Ansichten fester Breite in der Reihenfolge von links.
struct SplitRow: Layout {
    var sideLeft: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let main = subviews.last else { return }
        let fixed = Array(subviews.dropLast())
        let size = ProposedViewSize(width: bounds.width, height: bounds.height)
        let widths = fixed.map { $0.sizeThatFits(size).width }
        let rest = max(0, bounds.width - widths.reduce(0, +))
        let pairs = Array(zip(fixed, widths))
        let ordered = sideLeft ? pairs + [(main, rest)] : [(main, rest)] + pairs.reversed()
        var x = bounds.minX
        for (view, w) in ordered {
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w
        }
    }
}
