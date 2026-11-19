import SwiftUI
import UIKit
import XCTest
@testable import UniFlow

/// Leiste oben in der Kopfzeile ("Oben fest", 18.11.2026): Dauerlast am iPad Air 4 (Hauptfaden 100 %, Wischen ruckelt;
/// "Unten fest" fluessig). Die Leiste waehlte mit `ViewThatFits` zwischen drei echten Werkzeugreihen und baute sie bei
/// Layout-Durchgaengen neu. Jetzt waehlt sie zwischen leeren Flaechen mit berechneter Breite und baut nur eine Reihe.
@MainActor
final class EditorToolbarLayoutAppTests: XCTestCase {
    private func tools(presets: Int) -> EditorToolState {
        let d = UserDefaults(suiteName: "toolbar-layout-\(UUID().uuidString)")!
        let t = EditorToolState(defaults: d, key: "t")
        for i in 0..<presets { _ = t.addPreset(from: [EditorToolState.Tool.pen, .marker, .fineliner, .fountain][i]) }
        return t
    }

    private func bar(_ t: EditorToolState, inkOnly: Bool = false) -> EditorToolbar {
        EditorToolbar(tools: t, mode: EditorToolbarMode(visible: true, inkOnly: inkOnly), undo: {}, redo: {}, embedded: true)
    }

    private func width<V: View>(_ v: V) -> CGFloat {
        UIHostingController(rootView: v).sizeThatFits(in: CGSize(width: 4000, height: 200)).width
    }

    /// berechnete Breite = gemessene Breite der Reihe (sonst waehlte die Leiste falsch: abgeschnitten oder zu frueh eingeklappt)
    func testComputedRowWidthMatchesMeasuredRow() {
        for presets in [0, 1, 3] {
            for inkOnly in [false, true] {
                let t = tools(presets: presets)
                XCTAssertEqual(t.presets.count, presets)
                for collapsed in [false, true] {
                    let measured = width(bar(t, inkOnly: inkOnly).toolRow(collapsed: collapsed).fixedSize())
                    let computed = EditorToolbar.rowWidth(collapsed: collapsed, presets: presets, inkOnly: inkOnly, embedded: true)
                    XCTAssertEqual(computed, measured, accuracy: 0.5, "Stifte \(presets), nur Tinte \(inkOnly), eingeklappt \(collapsed)")
                }
            }
        }
    }

    /// Breite der ganzen Leiste in der Kopfzeile wie vorher: breit genug -> alle Werkzeuge, enger -> eingeklappt, sehr eng -> wischen
    func testChoosesFullCollapsedOrScrolling() {
        let t = tools(presets: 2)
        let full = EditorToolbar.rowWidth(collapsed: false, presets: 2, inkOnly: false, embedded: true)
        let compact = EditorToolbar.rowWidth(collapsed: true, presets: 2, inkOnly: false, embedded: true)
        let wide = width(bar(t))
        XCTAssertGreaterThan(wide, full, "volle Reihe plus Farbe, Rueckgaengig, Wiederholen")
        let trailing = wide - full
        for (room, expect) in [(full + trailing + 50, full), (compact + trailing + 10, compact), (trailing + 120, 120)] {
            let size = UIHostingController(rootView: bar(t)).sizeThatFits(in: CGSize(width: room, height: 44))
            XCTAssertEqual(size.width - trailing, expect, accuracy: 1, "Platz \(room)")
        }
    }

    /// Neuberechnung der Dokumentansicht (z. B. Seitenwechsel beim Wischen) baut nur die sichtbare Werkzeugreihe: vorher
    /// je Neuberechnung alle drei Reihen (voll, eingeklappt, wischbar) samt Popovern, gemessen im Simulator mit 6 Reitern:
    /// Wischen 28,8 % CPU oben gegen 9,1 % unten; jetzt 8,9 %
    func testParentUpdateBuildsOnlyTheShownRow() {
        let t = tools(presets: 2)
        let tick = Tick()
        let host = UIHostingController(rootView: Parent(tick: tick, tools: t))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1100, height: 44))
        window.rootViewController = host
        window.isHidden = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        EditorToolbar.toolButtonBuilds = 0
        let updates = 20
        for _ in 0..<updates {
            tick.n += 1
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        window.isHidden = true
        let perUpdate = Double(EditorToolbar.toolButtonBuilds) / Double(updates)
        let shown = EditorToolState.Tool.canvasTools.count + EditorToolState.Tool.objectTools.count
        XCTAssertGreaterThan(perUpdate, 0, "Messung greift")
        XCTAssertLessThanOrEqual(perUpdate, Double(shown), "Knoepfe je Neuberechnung: \(perUpdate)")
    }

    private final class Tick: ObservableObject { @Published var n = 0 }

    /// wie `DocumentView`: neue Leiste bei jeder Neuberechnung (Closures sind nie gleich)
    private struct Parent: View {
        @ObservedObject var tick: Tick
        let tools: EditorToolState
        var body: some View {
            HStack(spacing: 0) {
                EditorToolbar(tools: tools, mode: EditorToolbarMode(visible: true), undo: { _ = tick.n }, redo: {}, embedded: true)
                Spacer(minLength: 4)
                Text("\(tick.n)")
            }
            .frame(width: 1100, height: 44)
        }
    }

    /// Ruhe bei jeder Breite: steht die Leiste, baut sie nichts mehr neu (auch eingeklappt und wischbar; Kopfzeile mit
    /// mehreren Reitern laesst der Leiste weniger Platz)
    func testIdleAtEveryWidthBuildsNothing() {
        let t = tools(presets: 2)
        var worst: (CGFloat, Int) = (0, 0)
        for w in stride(from: CGFloat(260), through: 1000, by: 37) {
            let host = UIHostingController(rootView: HStack(spacing: 0) { bar(t); Spacer(minLength: 4) }.frame(width: w, height: 44))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: w, height: 44))
            window.rootViewController = host
            window.isHidden = false
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))     // einschwingen
            EditorToolbar.toolButtonBuilds = 0
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if EditorToolbar.toolButtonBuilds > worst.1 { worst = (w, EditorToolbar.toolButtonBuilds) }
            window.isHidden = true
        }
        XCTAssertEqual(worst.1, 0, "Leiste baut in Ruhe weiter Knoepfe (Breite \(worst.0)): \(worst.1)")
    }
}
