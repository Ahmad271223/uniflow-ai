import SwiftUI
import UIKit

/// Breite der KI-Hilfe neben dem Dokument (Meldung des Inhabers 11.11.2026: "KI-Seite größer kleiner ziehen"). Ein Griff
/// am inneren Rand der Leiste zieht sie breiter oder schmaler (Finger, Pencil, Maus mit Zeiger fuer die Breite);
/// Doppeltippen auf den Griff stellt die Standardbreite wieder her. Die Breite bleibt je Geraet gemerkt (UserDefaults,
/// `key`, in Punkten; 0 = Standard) und passt sich beim Drehen bzw. bei einer anderen Fensterbreite den Grenzen an.
/// Reine Regeln: UniFlowTests/TutorPanelWidthAppTests.swift.
enum TutorPanelWidth {
    /// Schluessel in UserDefaults (je Geraet, wie `uniflow.splitFraction` der geteilten Ansicht)
    static let key = "uniflow.tutorWidth"
    /// schmalste Leiste: Reiter, Umfang und Eingabefeld bleiben lesbar
    static let minWidth: CGFloat = 280
    /// breiteste Leiste als Anteil der Fensterbreite
    static let maxFraction: CGFloat = 0.6
    /// so viel bleibt mindestens fuer das Dokument (neben Seitenleiste und Spalte daneben)
    static let minDocument: CGFloat = 240
    /// Schritt fuer VoiceOver (Wischen nach oben/unten am Griff)
    static let step: CGFloat = 40

    /// Standardbreite wie bisher: genug zum Lesen, das Dokument behaelt den Grossteil
    static func standard(_ total: CGFloat) -> CGFloat { min(400, max(300, total * 0.32)) }

    /// Groesste Breite: 60 % des Fensters, aber das Dokument behaelt `minDocument` neben den anderen festen Spalten
    /// (`reserved`: Seitenleiste, Spalte daneben); nie unter `minWidth`
    static func maxWidth(total: CGFloat, reserved: CGFloat = 0) -> CGFloat {
        max(minWidth, min(total * maxFraction, total - reserved - minDocument))
    }

    /// Breite in den Grenzen
    static func clamp(_ width: CGFloat, total: CGFloat, reserved: CGFloat = 0) -> CGFloat {
        min(maxWidth(total: total, reserved: reserved), max(minWidth, width))
    }

    /// Angezeigte Breite: die gemerkte (in den Grenzen des Fensters) oder ohne Wert die Standardbreite
    static func width(stored: Double, total: CGFloat, reserved: CGFloat = 0) -> CGFloat {
        clamp(stored > 0 ? CGFloat(stored) : standard(total), total: total, reserved: reserved)
    }

    /// Breite beim Ziehen: Leiste links waechst mit dem Griff nach rechts, Leiste rechts mit dem Griff nach links
    static func dragged(from start: CGFloat, translation: CGFloat, panelOnLeft: Bool, total: CGFloat, reserved: CGFloat = 0) -> CGFloat {
        clamp(start + (panelOnLeft ? translation : -translation), total: total, reserved: reserved)
    }

    /// Wert zum Merken: ganze Punkte
    static func storedValue(_ width: CGFloat) -> Double { Double(width.rounded()) }

    /// VoiceOver: einen Schritt breiter bzw. schmaler
    static func adjusted(_ width: CGFloat, wider: Bool, total: CGFloat, reserved: CGFloat = 0) -> CGFloat {
        clamp(width + (wider ? step : -step), total: total, reserved: reserved)
    }

    /// gemerkte Breite (0 = Standard)
    static func stored(in defaults: UserDefaults = .standard) -> Double { defaults.double(forKey: key) }

    /// Breite merken; nil = Standardbreite (Doppeltippen)
    static func save(_ width: CGFloat?, in defaults: UserDefaults = .standard) {
        if let width { defaults.set(storedValue(width), forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    static let label = "Breite der KI-Hilfe"
    static let hint = "Ziehen ändert die Breite, Doppeltippen stellt die Standardbreite her."
    static let resetAction = "Standardbreite"

    static func valueText(_ width: CGFloat) -> String { "\(Int(width.rounded())) Punkt" }
}

/// Rand zwischen Dokument und KI-Hilfe mit Griff zum Ziehen. Sieht aus wie bisher (eine Linie, `Divider`) mit einem
/// kleinen Griff wie in der geteilten Ansicht; die Flaeche zum Greifen ist breiter als die Linie und nimmt dem Dokument
/// keinen Platz weg.
struct TutorResizeHandle: View {
    /// Leiste links vom Griff (Rechtshaender: Leiste auf der Seite der freien Hand)
    let panelOnLeft: Bool
    /// Fensterbreite und Breite der anderen festen Spalten
    let total: CGFloat
    var reserved: CGFloat = 0
    /// gemerkte Breite (`TutorPanelWidth.key`, 0 = Standard)
    @Binding var stored: Double
    /// Breite beim Start des Ziehens
    @State private var start: CGFloat?

    private var width: CGFloat { TutorPanelWidth.width(stored: stored, total: total, reserved: reserved) }

    var body: some View {
        Divider()
            .overlay {
                ZStack {
                    Color.clear
                    Capsule().fill(start == nil ? UF.lineStrong : UF.accent).frame(width: 5, height: 44)
                }
                .frame(width: 22)
                .background(TutorResizePointer())
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { g in
                            let from = start ?? width
                            if start == nil { start = from }
                            let w = TutorPanelWidth.dragged(from: from, translation: g.translation.width, panelOnLeft: panelOnLeft,
                                                            total: total, reserved: reserved)
                            stored = TutorPanelWidth.storedValue(w)
                        }
                        .onEnded { _ in start = nil }
                )
                .onTapGesture(count: 2) { reset() }
                .accessibilityElement()
                .accessibilityLabel(TutorPanelWidth.label)
                .accessibilityValue(TutorPanelWidth.valueText(width))
                .accessibilityHint(TutorPanelWidth.hint)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: stored = TutorPanelWidth.storedValue(TutorPanelWidth.adjusted(width, wider: true, total: total, reserved: reserved))
                    case .decrement: stored = TutorPanelWidth.storedValue(TutorPanelWidth.adjusted(width, wider: false, total: total, reserved: reserved))
                    @unknown default: break
                    }
                }
                .accessibilityAction(named: TutorPanelWidth.resetAction) { reset() }
                .accessibilityIdentifier("tutor.resize")
            }
            .zIndex(1)                                   // Griff liegt ueber Dokument und Leiste (Beruehrung, Zeiger)
    }

    private func reset() {
        withAnimation(.easeInOut(duration: 0.2)) { stored = 0 }
    }
}

/// Zeiger ueber dem Griff (Maus, Trackpad; am Mac): senkrechter Strich mit Pfeilen nach links und rechts
private struct TutorResizePointer: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.addInteraction(UIPointerInteraction(delegate: context.coordinator))
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIPointerInteractionDelegate {
        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
            let style = UIPointerStyle(shape: .verticalBeam(length: 22), constrainedAxes: [])
            style.accessories = [.arrow(.left), .arrow(.right)]
            return style
        }
    }
}
