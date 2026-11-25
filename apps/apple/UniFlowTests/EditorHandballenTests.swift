import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Handballen-Abwehr beim Scrollen und Zoomen (Meldung des Inhabers 25.11.2026, `PalmRejection.swift`): Solange der
/// Stift aufliegt und kurz danach, und solange eine sehr grosse Auflageflaeche aufliegt, sind die Scroll- und die
/// Zoom-Geste der PDF-Ansicht aus; hat die Hand die Seite kurz vorher bewegt, geht sie zurueck. Stift und Handballen
/// gibt es im Simulator nicht: Der Editor bekommt hier direkt gesagt, was aufliegt (`setHandTouches`), geprueft werden
/// die Gesten der Rollflaeche und die Stelle der Seite. Alle Daten sind erfunden.
@MainActor
final class EditorHandballenTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PencilTuning.palmRejection = true
        PencilTuning.palmByRadius = false
    }

    override func tearDown() {
        PencilTuning.palmRejection = true
        PencilTuning.palmByRadius = false
        super.tearDown()
    }

    // MARK: Regeln ohne Editor

    func testStiftSperrtBisKurzNachDemAbsetzen() {
        var s = PalmRejection.State()
        XCTAssertFalse(s.locked(at: 10), "nichts liegt auf")
        XCTAssertNil(s.nextCheck(at: 10))

        s.update(pencils: 1, palms: 0, at: 10)
        XCTAssertTrue(s.locked(at: 10), "Stift liegt auf")
        XCTAssertTrue(s.locked(at: 500), "auch nach langer Zeit, solange er aufliegt")
        XCTAssertEqual(s.nextCheck(at: 10), PalmRejection.recheck)

        s.update(pencils: 0, palms: 0, at: 12)
        XCTAssertTrue(s.locked(at: 12), "eben abgesetzt")
        XCTAssertTrue(s.locked(at: 12 + PalmRejection.quietAfterPencil - 0.01), "Ruhezeit laeuft")
        XCTAssertEqual(try XCTUnwrap(s.nextCheck(at: 12.2)), PalmRejection.quietAfterPencil - 0.2, accuracy: 0.0001)
        XCTAssertFalse(s.locked(at: 12 + PalmRejection.quietAfterPencil), "Ruhezeit vorbei")
        XCTAssertNil(s.nextCheck(at: 12 + PalmRejection.quietAfterPencil))

        // naechster Strich innerhalb der Ruhezeit: durchgehend gesperrt, die Ruhezeit beginnt beim letzten Absetzen neu
        s.update(pencils: 1, palms: 0, at: 12.2)
        s.update(pencils: 0, palms: 0, at: 12.4)
        XCTAssertTrue(s.locked(at: 12.4 + PalmRejection.quietAfterPencil - 0.01))
        XCTAssertFalse(s.locked(at: 12.4 + PalmRejection.quietAfterPencil))
    }

    func testHandballenSperrtSolangeErAufliegt() {
        var s = PalmRejection.State()
        s.update(pencils: 0, palms: 1, at: 3)
        XCTAssertTrue(s.locked(at: 3))
        XCTAssertTrue(s.locked(at: 60), "ohne Stift: solange der Handballen aufliegt")
        s.update(pencils: 0, palms: 0, at: 61)
        XCTAssertFalse(s.locked(at: 61), "Handballen weg, kein Stift war da: sofort offen")

        XCTAssertFalse(PalmRejection.isPalm(radius: 22), "Fingerkuppe")
        XCTAssertFalse(PalmRejection.isPalm(radius: PalmRejection.palmRadius - 0.1))
        XCTAssertTrue(PalmRejection.isPalm(radius: PalmRejection.palmRadius))
        XCTAssertTrue(PalmRejection.isPalm(radius: 90))
    }

    /// Meldung des Inhabers nach dem ersten Aufspielen (25.11.2026): "Zoomen geht nicht mehr". Zwei Finger beim Zoomen
    /// liegen auf seinem iPad mit bis zu 63 pt auf - die Auflage allein sperrt darum nichts mehr.
    func testGrosseAuflageAlleinSperrtNichtMehr() {
        XCTAssertFalse(PencilTuning.palmByRadius, "ausgeliefert: aus")
        for r: CGFloat in [21, 31, 42, 52, 63, 90] {
            XCTAssertFalse(PalmRejection.countsAsPalm(radius: r), "\(r) pt: Finger beim Zoomen und Wischen bleiben Finger")
        }
        PencilTuning.palmByRadius = true                     // nur zum Messen
        XCTAssertFalse(PalmRejection.countsAsPalm(radius: 42))
        XCTAssertTrue(PalmRejection.countsAsPalm(radius: 52))
    }

    func testSeiteGehtNurNachKurzemAuflegenZurueck() {
        XCTAssertFalse(PalmRejection.restoresSlip(handDownAt: nil, lockedAt: 5), "keine Hand")
        XCTAssertTrue(PalmRejection.restoresSlip(handDownAt: 5, lockedAt: 5.3))
        XCTAssertTrue(PalmRejection.restoresSlip(handDownAt: 5, lockedAt: 5 + PalmRejection.slipWindow))
        XCTAssertFalse(PalmRejection.restoresSlip(handDownAt: 5, lockedAt: 5 + PalmRejection.slipWindow + 0.05),
                       "wer schon laenger blaettert, behaelt seine Stelle")
    }

    // MARK: Editor

    private func makePDF(pages: Int) -> Data {
        let raw = NSMutableData()
        let size = CGSize(width: 595, height: 842)
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        for i in 1...pages {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
            "Mitschrift \(i)".draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        UIGraphicsEndPDFContext()
        return raw as Data
    }

    private func makeStore(pages: Int) async throws -> DocumentStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handballen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-25T10:00:00")!)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let fileID = "handballen-" + UUID().uuidString.prefix(8).lowercased()
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makePDF(pages: pages).write(to: pdfURL)
        let file = LibFile(id: fileID, name: "Mitschrift.pdf", title: "Mitschrift", kind: "pdf", module_id: nil, subject: "TM",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-25", has_notes: nil,
                           page_count: pages, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        store.saveTiming = SaveTiming(pause: 0.05, maxDelay: 0.5)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        return store
    }

    private func show(_ store: DocumentStore) -> PDFEditorController {
        let editor = PDFEditorController(store: store)
        editor.pencilOnly = true
        editor.ownNotesVisible = true
        editor.canEdit = true
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = editor
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            editor.setHandTouches(pencils: 0, palms: 0)
            editor.handUnlockCheck?.cancel()
            editor.showToolPicker(false)
            window.isHidden = true
            window.rootViewController = nil
        }
        return editor
    }

    private func pump(_ seconds: Double = 0.4) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    private func gestures(_ e: PDFEditorController) throws -> (scroll: UIScrollView, pan: UIPanGestureRecognizer, pinch: UIPinchGestureRecognizer) {
        let scroll = try XCTUnwrap(e.firstScrollView(in: e.pdfView))
        return (scroll, scroll.panGestureRecognizer, try XCTUnwrap(scroll.pinchGestureRecognizer))
    }

    func testStiftSperrtScrollenUndZoomenDerHand() async throws {
        let e = show(try await makeStore(pages: 3))
        await pump()
        let g = try gestures(e)
        XCTAssertTrue(e.handWatcher.view === e.pdfView, "Beobachter sitzt auf der PDF-Ansicht")
        XCTAssertEqual(e.pdfView.gestureRecognizers?.filter { $0 is HandWatcher }.count, 1, "genau einer")
        XCTAssertTrue(g.pan.isEnabled)
        XCTAssertTrue(g.pinch.isEnabled)
        XCTAssertFalse(e.handGesturesLocked)
        let locks = PalmRejection.locksMade

        // Stift setzt auf: die Hand scrollt und zoomt nicht mehr
        e.setHandTouches(pencils: 1, palms: 0)
        XCTAssertTrue(e.handGesturesLocked)
        XCTAssertFalse(g.pan.isEnabled, "kein Scrollen mit der Hand")
        XCTAssertFalse(g.pinch.isEnabled, "kein Zoomen mit der Hand")
        XCTAssertEqual(PalmRejection.locksMade, locks + 1)

        // abgesetzt: kurz danach noch gesperrt (zwischen zwei Strichen)
        e.setHandTouches(pencils: 0, palms: 0)
        XCTAssertFalse(g.pan.isEnabled)
        await pump(PalmRejection.quietAfterPencil * 0.4)
        XCTAssertFalse(g.pan.isEnabled, "Ruhezeit laeuft noch")
        XCTAssertFalse(g.pinch.isEnabled)

        // naechster Strich in der Ruhezeit: bleibt gesperrt, ohne neue Sperre
        e.setHandTouches(pencils: 1, palms: 0)
        e.setHandTouches(pencils: 0, palms: 0)
        XCTAssertEqual(PalmRejection.locksMade, locks + 1, "durchgehend eine Sperre")

        // Ruhezeit vorbei: die Hand blaettert wieder, von selbst
        await pump(PalmRejection.quietAfterPencil + 0.2)
        XCTAssertFalse(e.handGesturesLocked)
        XCTAssertTrue(g.pan.isEnabled, "Scrollen geht wieder")
        XCTAssertTrue(g.pinch.isEnabled, "Zoomen geht wieder")
        XCTAssertTrue(g.scroll.isScrollEnabled)
    }

    func testHandballenAlleinSperrtUndGibtSofortFrei() async throws {
        let e = show(try await makeStore(pages: 2))
        await pump()
        let g = try gestures(e)
        e.setHandTouches(pencils: 0, palms: 1)
        XCTAssertFalse(g.pan.isEnabled, "grosse Auflageflaeche ist kein Finger")
        XCTAssertFalse(g.pinch.isEnabled)
        e.setHandTouches(pencils: 0, palms: 0)
        XCTAssertTrue(g.pan.isEnabled, "ohne Stift keine Ruhezeit")
        XCTAssertTrue(g.pinch.isEnabled)
    }

    func testSeiteGehtZurueckWennDieHandSieKurzVorherBewegtHat() async throws {
        let e = show(try await makeStore(pages: 4))
        await pump()
        let g = try gestures(e)
        let scale = e.pdfView.scaleFactor
        g.scroll.setContentOffset(CGPoint(x: g.scroll.contentOffset.x, y: g.scroll.contentOffset.y + 300), animated: false)
        await pump(0.1)
        let start = g.scroll.contentOffset
        let restored = PalmRejection.slipsRestored

        // Hand legt sich auf, schiebt die Seite und zoomt dabei; 0,3 s spaeter setzt der Stift auf
        // (Zeiten in der Vergangenheit: die Ruhezeit danach laeuft ueber die echte Uhr)
        e.rememberHandStart(at: CACurrentMediaTime() - 0.3)
        e.pdfView.scaleFactor = scale * 1.3
        g.scroll.setContentOffset(CGPoint(x: start.x, y: start.y + 140), animated: false)
        XCTAssertNotEqual(g.scroll.contentOffset.y, start.y, accuracy: 20)
        e.setHandTouches(pencils: 1, palms: 0, gestureRunning: true)
        XCTAssertEqual(e.pdfView.scaleFactor, scale, accuracy: 0.001, "Zoom wie beim Auflegen der Hand")
        XCTAssertEqual(g.scroll.contentOffset.y, start.y, accuracy: 1, "Stelle wie beim Auflegen der Hand")
        XCTAssertEqual(g.scroll.contentOffset.x, start.x, accuracy: 1)
        XCTAssertEqual(PalmRejection.slipsRestored, restored + 1)
        XCTAssertFalse(g.pan.isEnabled)
        e.setHandTouches(pencils: 0, palms: 0)
        await pump(PalmRejection.quietAfterPencil + 0.2)
        XCTAssertTrue(g.pan.isEnabled)

        // wer schon laenger mit dem Finger blaettert und dann den Stift aufsetzt, behaelt seine Stelle
        e.rememberHandStart(at: CACurrentMediaTime() - PalmRejection.slipWindow - 0.5)
        let moved = CGPoint(x: start.x, y: start.y + 200)
        g.scroll.setContentOffset(moved, animated: false)
        e.setHandTouches(pencils: 1, palms: 0, gestureRunning: true)
        XCTAssertEqual(g.scroll.contentOffset.y, moved.y, accuracy: 1, "nach langem Blaettern kein Zuruecksetzen")
        XCTAssertEqual(PalmRejection.slipsRestored, restored + 1)
        XCTAssertFalse(g.pan.isEnabled, "aber gesperrt")

        // ohne laufende Geste aendert die Sperre nichts an der Stelle
        e.setHandTouches(pencils: 0, palms: 0)
        await pump(PalmRejection.quietAfterPencil + 0.2)
        e.rememberHandStart()
        let quiet = g.scroll.contentOffset
        e.setHandTouches(pencils: 1, palms: 0, gestureRunning: false)
        XCTAssertEqual(g.scroll.contentOffset.y, quiet.y, accuracy: 1)
        XCTAssertEqual(PalmRejection.slipsRestored, restored + 1)
    }

    func testFixierenUndHandballenAbwehrVertragenSich() async throws {
        let e = show(try await makeStore(pages: 2))
        await pump()
        let g = try gestures(e)

        // fixiert, dann Stift: nach dem Stift bleibt es fixiert
        e.freezeMode = .view
        XCTAssertFalse(g.pan.isEnabled)
        e.setHandTouches(pencils: 1, palms: 0)
        e.setHandTouches(pencils: 0, palms: 0)
        await pump(PalmRejection.quietAfterPencil + 0.2)
        XCTAssertFalse(e.handGesturesLocked)
        XCTAssertFalse(g.pan.isEnabled, "Ende der Abwehr loest das Fixieren nicht")
        XCTAssertFalse(g.pinch.isEnabled)
        XCTAssertFalse(g.scroll.isScrollEnabled)

        // waehrend der Stift aufliegt geloest: bleibt bis nach dem Stift gesperrt
        e.setHandTouches(pencils: 1, palms: 0)
        e.freezeMode = .off
        XCTAssertFalse(g.pan.isEnabled, "Loesen hebt die Abwehr nicht auf")
        XCTAssertFalse(g.pinch.isEnabled)
        e.setHandTouches(pencils: 0, palms: 0)
        await pump(PalmRejection.quietAfterPencil + 0.2)
        XCTAssertTrue(g.pan.isEnabled)
        XCTAssertTrue(g.pinch.isEnabled)
        XCTAssertTrue(g.scroll.isScrollEnabled)
    }

    func testSchalterAusWieBisher() async throws {
        PencilTuning.palmRejection = false
        let e = show(try await makeStore(pages: 2))
        await pump()
        let g = try gestures(e)
        e.setHandTouches(pencils: 1, palms: 1)
        XCTAssertFalse(e.handGesturesLocked)
        XCTAssertTrue(g.pan.isEnabled, "Gegenprobe: wie bis 1.0.7 scrollt die Hand auch beim Schreiben")
        XCTAssertTrue(g.pinch.isEnabled)
    }

    func testFingerZeichnetBleibtZweiFingerScrollenUndWirdEbensoGesperrt() async throws {
        let e = show(try await makeStore(pages: 2))
        await pump()
        e.pencilOnly = false
        let g = try gestures(e)
        XCTAssertEqual(g.pan.minimumNumberOfTouches, 2)
        XCTAssertTrue(g.pan.isEnabled)
        e.setHandTouches(pencils: 1, palms: 0)
        XCTAssertFalse(g.pan.isEnabled)
        e.pencilOnly = true                                  // Umschalten waehrend der Sperre hebt sie nicht auf
        XCTAssertFalse(g.pan.isEnabled)
        XCTAssertEqual(g.pan.minimumNumberOfTouches, 1)
    }

    func testStiftImEinenDokumentSperrtAuchDasDaneben() async throws {
        // geteilte Ansicht: zwei Editoren nebeneinander
        let left = show(try await makeStore(pages: 2))
        let right = show(try await makeStore(pages: 2))
        await pump()
        let l = try gestures(left), r = try gestures(right)
        XCTAssertTrue(l.pan.isEnabled)
        XCTAssertTrue(r.pan.isEnabled)

        left.handWatcher.pencilsForTesting = 1               // Stift schreibt links
        left.handTouchesChanged()
        XCTAssertFalse(l.pan.isEnabled)
        XCTAssertFalse(r.pan.isEnabled, "der Handballen liegt oft auf dem Dokument daneben")
        XCTAssertFalse(r.pinch.isEnabled)

        left.handWatcher.pencilsForTesting = 0
        left.handTouchesChanged()
        XCTAssertFalse(r.pan.isEnabled, "Ruhezeit gilt auch daneben")
        await pump(PalmRejection.quietAfterPencil + 0.2)
        XCTAssertTrue(l.pan.isEnabled)
        XCTAssertTrue(r.pan.isEnabled)
        XCTAssertTrue(r.pinch.isEnabled)
    }

    func testZaehlerStehenInDerDatei() throws {
        let before = StiftZaehler.value(.handGesperrt)
        StiftZaehler.bump(.handGesperrt)
        StiftZaehler.write()
        XCTAssertEqual(StiftZaehler.value(.handGesperrt), before + 1)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: StiftZaehler.fileURL)) as? [String: Any])
        XCTAssertNotNil(obj["handGesperrt"] as? Int)
        XCTAssertNotNil(obj["handRutscherZurueck"] as? Int)
    }
}
