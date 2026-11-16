import PencilKit
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Schriftbild zum Vergleichen (`PencilLab`, Auftrag 17.11.2026): ohne Auswahl aendert sich nichts; die Varianten
/// schreiben wirklich anders, schon waehrend des Strichs, und nichts wird nach dem Absetzen ersetzt.
extension EditorStrichBleibtTests {
    private func raeumeSchriftbildAuf() {
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: PencilLab.key)
            UserDefaults.standard.removeObject(forKey: PencilLab.visibleKey)
            NotificationCenter.default.post(name: PencilLab.changed, object: nil)
        }
    }

    /// Ohne Auswahl aendert sich nichts: Stufen, Tinten und Grenzen wie bisher; die Auswahl ist nicht zu sehen.
    func testSchriftbildStandardAendertNichts() throws {
        raeumeSchriftbildAuf()
        XCTAssertEqual(PencilLab.current, .standard)
        XCTAssertFalse(PencilLab.visible, "ohne Freischaltung keine Auswahl in den Einstellungen")
        XCTAssertEqual(EditorToolState.Tool.fineliner.widths, [0.5, 0.8, 1.5, 2.5, 4])
        XCTAssertEqual(EditorToolState.Tool.pen.widths, [0.88, 2, 3.5, 6, 10])
        XCTAssertEqual(EditorToolState.Tool.pen.inkType, .pen)
        XCTAssertEqual(EditorToolState.widthLimits(.fineliner).lowerBound, 0.5, accuracy: 0.001)
        let suite = "uniflow.tests.schriftbild.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let tools = EditorToolState(defaults: defaults)
        tools.setWidth(0.25, for: .fineliner)
        XCTAssertEqual(tools.inkingTool(.fineliner)?.width ?? 0, 0.5, accuracy: 0.001, "Standard: der Fineliner bleibt bei 0,5")
        XCTAssertEqual(tools.inkingTool(.pen)?.inkType, .pen)
        // freigeschaltet: die Auswahl erscheint
        UserDefaults.standard.set(true, forKey: PencilLab.visibleKey)
        XCTAssertTrue(PencilLab.visible)
    }

    /// "Feiner Fineliner": zwei duennere Stufen, PencilKit schreibt damit wirklich duenner (echter Strich, ohne dass
    /// danach etwas ersetzt wird). "Stift als Fueller": der Stift schreibt mit Fueller-Tinte. Zurueck auf "Wie bisher"
    /// gelten wieder die alten Grenzen.
    func testSchriftbildVariantenSchreibenWirklichAnders() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        raeumeSchriftbildAuf()
        let fx = try await makeFixture(pages: 2)
        let store = try await openStore(fx)
        let shown = show(store, pencilOnly: false)
        defer { hide(shown) }
        let editor = shown.editor
        let overlay = try await waitForOverlay(editor, page: 0)
        let canvas = overlay.canvas
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var row = 0
        func schreibe() async throws -> PKStroke {
            let a = overlay.content.convert(CGPoint(x: 100, y: 110 + CGFloat(row) * 40), to: nil)
            row += 1
            var pts: [CGPoint] = []
            for k in 0...40 { pts.append(CGPoint(x: a.x + CGFloat(k) * 5, y: a.y)) }
            let n0 = canvas.drawing.strokes.count
            try await TestFinger.strich(pts, in: shown.window, step: 0.008)
            let until = Uhr.now() + 3
            while Uhr.now() < until, canvas.drawing.strokes.count == n0 { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertEqual(canvas.drawing.strokes.count, n0 + 1, "Strich angenommen")
            return try XCTUnwrap(canvas.drawing.strokes.last)
        }
        func waehle(_ lab: PencilLab) async throws {
            UserDefaults.standard.set(lab.rawValue, forKey: PencilLab.key)
            NotificationCenter.default.post(name: PencilLab.changed, object: nil)      // wie die Auswahl in den Einstellungen
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        let log0 = ZeichnungSpion.log.count

        // Wie bisher: Fineliner auf der duennsten Stufe
        editor.tools.setWidth(0.5, for: .fineliner)
        editor.tools.select(.fineliner)
        try await Task.sleep(nanoseconds: 150_000_000)
        let normal = Self.dicke(try await schreibe())

        // Feiner Fineliner: neue duennste Stufe, ohne das Werkzeug neu zu waehlen
        try await waehle(.fine)
        XCTAssertEqual(EditorToolState.Tool.fineliner.widths.first, 0.25)
        XCTAssertEqual(EditorToolState.Tool.fineliner.widths.count, 7)
        editor.tools.setWidth(0.25, for: .fineliner)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.width ?? 0, 0.25, accuracy: 0.001, "die Zeichenflaeche hat die duenne Breite")
        let feinStrich = try await schreibe()
        let fein = Self.dicke(feinStrich)
        XCTAssertEqual(feinStrich.ink.inkType, .monoline)
        XCTAssertLessThan(fein, normal * 0.7, "wirklich duenner geschrieben (\(fein) statt \(normal) pt)")
        XCTAssertGreaterThan(fein, 0.2, "und zu sehen")

        // Stift als Fueller
        try await waehle(.fountain)
        editor.tools.setWidth(0.88, for: .pen)
        editor.tools.select(.pen)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .fountainPen)
        let fuellerStrich = try await schreibe()
        XCTAssertEqual(fuellerStrich.ink.inkType, .fountainPen)
        let fueller = Self.dicke(fuellerStrich)

        // zurueck: wie bisher, auch fuer die gemerkte duenne Breite
        try await waehle(.standard)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .pen, "der Stift schreibt wieder mit seiner Tinte")
        let stift = Self.dicke(try await schreibe())
        editor.tools.select(.fineliner)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.width ?? 0, 0.5, accuracy: 0.001, "Fineliner wieder ab 0,5")

        // nichts wurde nach dem Absetzen ersetzt, alles gespeichert, die vorhandenen Striche haben ihre Tinte behalten
        let sets = ZeichnungSpion.log[log0...].filter { $0.canvas == ObjectIdentifier(canvas) && !$0.own }
        XCTAssertEqual(sets.count, 0, "keine Variante setzt die Zeichnung neu")
        XCTAssertEqual(canvas.drawing.strokes.map { $0.ink.inkType }, [.monoline, .monoline, .fountainPen, .pen])
        await store.flush()
        let saved = await store.objects(forPageKey: "p1").filter { $0["type"]?.string == "stroke" }
        XCTAssertEqual(saved.count, 4)
        print(String(format: "[Strich] Schriftbild, gezeichnete Dicke bei gleichmaessigem Druck: Fineliner wie bisher (0,5) %.2f pt = %.2f mm; Feiner Fineliner (0,25) %.2f pt = %.2f mm; Stift als Fueller (duennste Stufe) %.2f pt = %.2f mm; Stift wie bisher (0,88) %.2f pt = %.2f mm; vom Programm neu gesetzt %d Mal",
                     normal, normal * 0.3528, fein, fein * 0.3528, fueller, fueller * 0.3528, stift, stift * 0.3528, sets.count))
        await store.close()
        // nach dem Neuoeffnen sind die Striche unveraendert da (duenne Breite uebersteht Speichern und Laden)
        let again = try await openStore(fx)
        let reloaded = await again.drawing(forPageKey: "p1")
        XCTAssertEqual(reloaded.strokes.count, 4)
        if reloaded.strokes.count == 4 {
            XCTAssertEqual(Self.dicke(reloaded.strokes[1]), fein, accuracy: 0.05, "der feine Strich ist nach dem Laden gleich duenn")
        }
        await again.close()
    }
}
