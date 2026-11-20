import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import UniFlow

/// Meldung des Inhabers 20.11.2026 (iPad A16, 1.0.7): "Wenn man etwas umkreist (Lasso) und verschieben will oder das
/// Umkreiste kopiert und woanders einfuegt, haengt es kurz, und unten kommt ein halber Bildschirm, irgendein
/// blaeuliches Fenster auf - ab und zu."
///
/// Im Simulator nachgestellt (echte Beruehrung ueber `TestFinger`, Apples Lasso aus der Leiste): Nach dem Einkreisen
/// nimmt die Auswahl von PencilKit den Fokus. Diese Auswahl ist (seit Apples Schreibwerkzeugen) ein Texteingabefeld
/// (`UITextInput`) ohne eigene Eingabeansicht - also zeigt iPadOS die Bildschirmtastatur (das "blaeuliche Fenster").
/// Kommt die Beruehrung vom Pencil, haelt Scribble sie meist zurueck, mit dem Finger (Auswahl ziehen, "Einfügen" im
/// Menue antippen) kommt sie: "ab und zu". Die Tastatur schiebt die Dokumentansicht zusammen, PDF-Seiten und
/// Zeichenflaechen werden neu ausgelegt: das kurze Haengen. Abhilfe: `InkSelectionKeyboard`.
extension EditorStrichBleibtTests {

    /// Laengste Pause des Hauptthreads (Abstand zweier Bilder) zwischen `start` und `stop`
    @MainActor
    final class Bildtakt: NSObject {
        private var link: CADisplayLink?
        private var last: CFTimeInterval = 0
        private(set) var laengste: CFTimeInterval = 0
        func start() {
            last = CACurrentMediaTime()
            laengste = 0
            let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        @objc private func tick(_ l: CADisplayLink) {
            let now = CACurrentMediaTime()
            laengste = max(laengste, now - last)
            last = now
        }
        /// laengste Pause in Millisekunden
        func stop() -> Double {
            if let link { tick(link) }
            link?.invalidate()
            link = nil
            return laengste * 1000
        }
    }

    /// Was nach Lasso, Verschieben, Kopieren und Einfuegen zu sehen war und wie lange der Hauptthread stand (ms)
    struct LassoErgebnis {
        var lasso = 0.0, verschieben = 0.0, kopieren = 0.0, einfuegen = 0.0
        var ausgewaehlt = false
        var verschoben = false
        var eingefuegt = 0
        /// Meldungen "Tastatur erscheint" (mit Rahmen)
        var tastatur: [String] = []
        /// Blaetter, Fenster ueber der App, Fokus mit Bildschirmtastatur (je Schritt)
        var fremdes: [String] = []
    }

    /// Schlinge um die ersten fuenf Zeilen von `volleSeite` (200 Striche), Auswahl mit dem Finger ziehen, Kopieren,
    /// Einfuegen. Lasso und Ziehen als echte Beruehrung; Kopieren/Einfuegen ueber die Responder-Kette wie das Menue von
    /// PencilKit.
    static func lassoLauf(_ editor: PDFEditorController, overlay: PageInkView, window: UIWindow) async throws -> LassoErgebnis {
        var r = LassoErgebnis()
        let canvas = overlay.canvas
        var tastatur: [String] = []
        let tokens = [UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { n in
                let f = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
                tastatur.append("\(name.rawValue) \(f.integral)")
            }
        }
        defer { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
        func pruefe(_ schritt: String) {
            let fokus = UIResponder.uf_current
            print("[Lasso] \(schritt): Fokus \(fokus.map { String(describing: type(of: $0)) } ?? "-"), \(canvas.drawing.strokes.count) Striche")
            // Bildschirmtastatur: der Fokus nimmt Text an und hat keine eigene Eingabeansicht
            if fokus is UIKeyInput, fokus?.inputView == nil {
                r.fremdes.append("\(schritt): Fokus \(fokus.map { String(describing: type(of: $0)) } ?? "-") ohne Eingabeansicht")
            }
            var p = window.rootViewController?.presentedViewController
            while let vc = p {
                r.fremdes.append("\(schritt): Blatt \(type(of: vc))")
                p = vc.presentedViewController
            }
        }

        editor.tools.select(.lasso)
        try await Task.sleep(nanoseconds: 400_000_000)
        guard let lassoFlaeche = TestFinger.selectionView(in: canvas) else { throw MessFehler("keine Lasso-Flaeche von PencilKit") }
        let frei = freieFlaeche(overlay, in: window)
        let box = CGRect(x: 22, y: 26, width: 560, height: 113).intersection(frei)
        var bahn: [CGPoint] = []
        let ecken = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY),
                     CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.minX, y: box.minY + 2)]
        for i in 0..<(ecken.count - 1) {
            let a = ecken[i], b = ecken[i + 1]
            let n = max(2, Int(hypot(b.x - a.x, b.y - a.y) / 8))
            for k in 0..<n { bahn.append(CGPoint(x: a.x + (b.x - a.x) * CGFloat(k) / CGFloat(n), y: a.y + (b.y - a.y) * CGFloat(k) / CGFloat(n))) }
        }
        bahn.append(ecken[ecken.count - 1])
        let takt = Bildtakt()

        // 1. Einkreisen
        takt.start()
        try await TestFinger.strich(bahn.map { overlay.content.convert($0, to: nil) }, in: window, step: 0.008, ziel: lassoFlaeche)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        r.lasso = takt.stop()
        r.ausgewaehlt = (UIResponder.uf_current as? UIView)?.isDescendant(of: canvas) == true
        pruefe("Lasso")

        // 2. Auswahl mit dem Finger ziehen
        let vorher = canvas.drawing
        takt.start()
        let mitte = overlay.content.convert(CGPoint(x: box.midX, y: box.midY), to: nil)
        let finger = TestFinger(at: mitte, in: window, ziel: lassoFlaeche)
        for i in 1...30 {
            try await Task.sleep(nanoseconds: 16_000_000)
            finger.move(to: CGPoint(x: mitte.x + CGFloat(i) * 2, y: mitte.y + CGFloat(i) * 8))
        }
        try await Task.sleep(nanoseconds: 16_000_000)
        finger.lift()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        r.verschieben = takt.stop()
        r.verschoben = InkUndoStep.between(vorher, canvas.drawing).added.count >= 150
        pruefe("Verschieben")

        // 3. Kopieren und 4. Einfuegen (wie "Kopieren"/"Einfügen" im Menue von PencilKit)
        takt.start()
        UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.copy(_:)), to: nil, from: nil, for: nil)
        try await Task.sleep(nanoseconds: 800_000_000)
        r.kopieren = takt.stop()
        pruefe("Kopieren")
        let n0 = canvas.drawing.strokes.count
        takt.start()
        UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.paste(_:)), to: nil, from: nil, for: nil)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        r.einfuegen = takt.stop()
        r.eingefuegt = canvas.drawing.strokes.count - n0
        pruefe("Einfügen")
        r.tastatur = tastatur
        print("[Lasso] laengste Pause des Hauptthreads: Lasso \(Int(r.lasso)) ms, Verschieben \(Int(r.verschieben)) ms, "
              + "Kopieren \(Int(r.kopieren)) ms, Einfuegen \(Int(r.einfuegen)) ms; eingefuegt \(r.eingefuegt) Striche; "
              + "Tastatur \(r.tastatur); Fremdes \(r.fremdes)")
        return r
    }

    /// Editor allein: 200 von 800 Strichen einkreisen, ziehen, kopieren, einfuegen - keine Tastatur, kein Blatt, kein
    /// Fokus mit Tastatur, und der Hauptthread steht nie lange.
    func testLassoVerschiebenKopierenEinfuegenOhneTastatur() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let fx = try await makeFixture(pages: 2)
        var store = try await openStore(fx)
        store.canvasChanged(pageKey: "p1", drawing: Self.volleSeite(strokes: 800))
        await store.flush()
        await store.close()
        store = try await openStore(fx)
        let shown = show(store, pencilOnly: false)
        defer { hide(shown) }
        let overlay = try await waitForOverlay(shown.editor, page: 0)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let r = try await Self.lassoLauf(shown.editor, overlay: overlay, window: shown.window)
        XCTAssertTrue(r.ausgewaehlt, "Messaufbau: das Lasso von PencilKit hat ausgewaehlt")
        XCTAssertTrue(r.verschoben, "Messaufbau: die Auswahl wurde verschoben")
        XCTAssertGreaterThanOrEqual(r.eingefuegt, 150, "Messaufbau: die Kopie wurde eingefuegt")
        XCTAssertEqual(r.tastatur, [], "keine Bildschirmtastatur nach Lasso, Verschieben, Kopieren, Einfuegen")
        XCTAssertEqual(r.fremdes, [], "kein Blatt, kein Fokus mit Tastatur")
        // Obergrenzen im Simulator (ein iPad A16 rechnet langsamer als der Mac)
        XCTAssertLessThan(r.lasso, 150, "Lasso: Hauptthread steht nicht lange")
        XCTAssertLessThan(r.verschieben, 150, "Verschieben: Hauptthread steht nicht lange")
        XCTAssertLessThan(r.kopieren, 150, "Kopieren: Hauptthread steht nicht lange")
        XCTAssertLessThan(r.einfuegen, 150, "Einfuegen: Hauptthread steht nicht lange")
        await store.flush()
        let saved = await store.objects(forPageKey: "p1").filter { $0["type"]?.string == "stroke" }.count
        XCTAssertEqual(saved, 800 + r.eingefuegt, "verschoben und eingefuegt ist gespeichert")
        await store.close()
    }

    /// Editor mit einer Seite aus 800 Strichen (wie `testLassoVerschiebenKopierenEinfuegenOhneTastatur`)
    private func volleSeiteImEditor() async throws -> (Shown, PageInkView, DocumentStore) {
        let fx = try await makeFixture(pages: 2)
        var store = try await openStore(fx)
        store.canvasChanged(pageKey: "p1", drawing: Self.volleSeite(strokes: 800))
        await store.flush()
        await store.close()
        store = try await openStore(fx)
        let shown = show(store, pencilOnly: false)
        let overlay = try await waitForOverlay(shown.editor, page: 0)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        return (shown, overlay, store)
    }

    /// Gegenprobe im selben Lauf: erst wie bis 1.0.7 (`PencilTuning.inkSelectionWithoutKeyboard = false`), dann mit der
    /// Abhilfe. Vorher kommt die Tastatur (der Test erkennt den Fehler), nachher nicht. Dazu die Kosten des Editors
    /// selbst je Aenderung (Sichern der Seite, Rueckgaengig-Schritt) auf der Seite mit gut 1000 Strichen.
    func testLassoGegenprobeTastaturVorherNachher() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        defer { PencilTuning.inkSelectionWithoutKeyboard = true }
        var ergebnisse: [LassoErgebnis] = []
        for mitAbhilfe in [false, true] {
            PencilTuning.inkSelectionWithoutKeyboard = mitAbhilfe
            let (shown, overlay, store) = try await volleSeiteImEditor()
            print("[Lasso] Gegenprobe \(mitAbhilfe ? "nachher (ohne Tastatur)" : "vorher (wie 1.0.7)"):")
            let r = try await Self.lassoLauf(shown.editor, overlay: overlay, window: shown.window)
            ergebnisse.append(r)
            // Kosten des Editors je Aenderung der Zeichnung (Hauptthread): ganze Seite sichern und Rueckgaengig-Schritt
            let d = overlay.canvas.drawing
            let t0 = CACurrentMediaTime()
            _ = d.dataRepresentation()
            let t1 = CACurrentMediaTime()
            _ = InkUndoStep.between(d, d)
            let t2 = CACurrentMediaTime()
            print("[Lasso] Editor je Aenderung bei \(d.strokes.count) Strichen: Seite sichern \(Int((t1 - t0) * 1000)) ms, "
                  + "Rueckgaengig-Schritt \(Int((t2 - t1) * 1000)) ms; Entwurf gesamt \(Int(store.inkDraftSeconds * 1000)) ms in \(store.inkDraftWrites) Sicherungen")
            if mitAbhilfe { await store.flush() }
            await store.close()
            // Tastatur zu, bevor der naechste Durchgang beginnt
            UIResponder.uf_current?.resignFirstResponder()
            hide(shown)
            try await Task.sleep(nanoseconds: 800_000_000)
        }
        XCTAssertEqual(ergebnisse[1].tastatur, [], "mit Abhilfe keine Tastatur")
        XCTAssertEqual(ergebnisse[1].fremdes, [], "mit Abhilfe kein Fokus mit Tastatur")
        // Gegenprobe (wie bis 1.0.7 kommt die Tastatur): zeigt nur ein Simulator mit Bildschirmtastatur. Mit
        // Hardware-Tastatur (Simulator-Einstellung, im Gesamtlauf 20.11.2026 auf dem iPad Air M3) kommt sie auch ohne
        // Abhilfe nicht - dann ist die Gegenprobe nicht aussagekraeftig, die Pruefung oben gilt weiter
        if ergebnisse[0].tastatur.isEmpty {
            throw XCTSkip("Gegenprobe ohne Bildschirmtastatur im Simulator nicht aussagekräftig")
        }
        XCTAssertGreaterThanOrEqual(ergebnisse[1].eingefuegt, 150, "mit Abhilfe: Kopie eingefuegt")
    }

    /// "Schwebend" (Apples Werkzeugpalette): auch dort keine Tastatur, Kopieren und Einfuegen wirken auf die Handschrift
    func testLassoMitSchwebenderPaletteOhneTastatur() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let (shown, overlay, store) = try await volleSeiteImEditor()
        defer { hide(shown) }
        shown.editor.toolbarPlacement = .floating
        try await Task.sleep(nanoseconds: 600_000_000)
        let r = try await Self.lassoLauf(shown.editor, overlay: overlay, window: shown.window)
        print("[Lasso] schwebende Palette sichtbar: \(shown.editor.floatingPalette?.isVisible ?? false)")
        XCTAssertTrue(r.ausgewaehlt, "Messaufbau: das Lasso von PencilKit hat ausgewaehlt")
        XCTAssertEqual(r.tastatur, [], "keine Bildschirmtastatur")
        XCTAssertEqual(r.fremdes, [], "kein Blatt, kein Fokus mit Tastatur")
        XCTAssertGreaterThanOrEqual(r.eingefuegt, 150, "Kopie eingefuegt")
        shown.editor.toolbarPlacement = .standard
        await store.close()
    }

    /// Ganze Dokumentansicht wie in der App (Leiste oben, SwiftUI drumherum): erst hier schob die Tastatur das Dokument
    /// zusammen. Keine Tastatur, das Dokument behaelt seine Hoehe, der Hauptthread steht nie lange.
    func testLassoImDokumentOhneTastaturUndOhneHaenger() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let fx = try await makeFixture(pages: 2)
        // Die Dokumentansicht oeffnet ihren Store am Standardort: PDF und Stand dorthin, Handschrift ueber diesen Store
        let src = AppPaths.pdf(fx.file.id, namespace: fx.api.namespace, root: fx.root)
        let pdf = AppPaths.pdf(fx.file.id, namespace: fx.api.namespace)
        try FileManager.default.createDirectory(at: pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
        for (a, b) in [(src, pdf), (src.appendingPathExtension("stand"), pdf.appendingPathExtension("stand"))] {
            try? FileManager.default.removeItem(at: b)
            try FileManager.default.copyItem(at: a, to: b)
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: pdf)
            try? FileManager.default.removeItem(at: pdf.appendingPathExtension("stand"))
        }
        let prep = DocumentStore(file: fx.file, api: fx.api)
        await prep.load()
        prep.canvasChanged(pageKey: "p1", drawing: Self.volleSeite(strokes: 800))
        await prep.flush()
        await prep.close()

        let plan = Entitlements.shared.plan
        Entitlements.shared.setPlanForTesting(.plus)
        defer { Entitlements.shared.setPlanForTesting(plan) }
        // der Finger schreibt (im Simulator statt des Pencil): Schalter "Nur Stift" der Dokumentansicht aus
        let nurStift = UserDefaults.standard.object(forKey: "uniflow.pencilOnly")
        UserDefaults.standard.set(false, forKey: "uniflow.pencilOnly")
        defer { UserDefaults.standard.set(nurStift, forKey: "uniflow.pencilOnly") }
        let env = try hostWithEnvironment(NavigationStack { DocumentView(file: fx.file, api: fx.api) }, api: fx.api,
                                          size: CGSize(width: 820, height: 1180))   // wie der Bildschirm (iPad A16 hochkant)
        func editor(_ vc: UIViewController?) -> PDFEditorController? {
            guard let vc else { return nil }
            if let e = vc as? PDFEditorController { return e }
            for c in vc.children { if let e = editor(c) { return e } }
            return nil
        }
        var found: PDFEditorController?
        let end = Uhr.now() + 20
        while Uhr.now() < end, found == nil {
            found = editor(env.window.rootViewController)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let e = try XCTUnwrap(found, "Editor in der Dokumentansicht")
        let overlay = try await waitForOverlay(e, page: 0)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(overlay.canvas.drawing.strokes.count, 800, "Messaufbau: Handschrift geladen")
        let hoehe = e.view.bounds.height
        var kleinste = hoehe
        let wache = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated { kleinste = min(kleinste, e.view.bounds.height) }
        }
        defer { wache.invalidate() }
        let r = try await Self.lassoLauf(e, overlay: overlay, window: env.window)
        print("[Lasso] Dokumenthoehe \(Int(hoehe)) pt, kleinste waehrend des Laufs \(Int(kleinste)) pt")
        XCTAssertTrue(r.ausgewaehlt, "Messaufbau: das Lasso von PencilKit hat ausgewaehlt")
        XCTAssertTrue(r.verschoben, "Messaufbau: die Auswahl wurde verschoben")
        XCTAssertGreaterThanOrEqual(r.eingefuegt, 150, "Messaufbau: die Kopie wurde eingefuegt")
        XCTAssertEqual(r.tastatur, [], "keine Bildschirmtastatur")
        XCTAssertEqual(r.fremdes, [], "kein Blatt, kein Fokus mit Tastatur")
        XCTAssertEqual(kleinste, hoehe, accuracy: 1, "das Dokument wird nicht zusammengeschoben")
        XCTAssertLessThan(r.lasso, 250, "Lasso: Hauptthread steht nicht lange")
        XCTAssertLessThan(r.verschieben, 250, "Verschieben: Hauptthread steht nicht lange")
        XCTAssertLessThan(r.einfuegen, 250, "Einfuegen: Hauptthread steht nicht lange")
    }
}
