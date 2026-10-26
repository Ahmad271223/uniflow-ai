import CryptoKit
import PDFKit
import PencilKit
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

// Ende-zu-Ende-Test "Loesung teilen" mit einer ECHTEN PDF (z. B. einem Uebungsblatt aus Stud.IP), ohne PC-Server
// (docs/LOESUNGEN-TEILEN.md). Laeuft nur mit Umgebungsvariablen, sonst XCTSkip. Die PDFs werden nur zur Laufzeit
// gelesen; sie und ihre Inhalte gehoeren nie ins Repository:
//   UF_E2E_PDF        echte PDF, die A und B beide besitzen (Pflicht)
//   UF_E2E_WRONG_PDF  zweite echte PDF fuer die Gegenprobe (Punkt 7, sonst uebersprungen)
//   UF_E2E_OUT        Ordner fuer die Ergebnisse (Paket, Strichgrenzen, Bilder, bericht.json)
// xcodebuild reicht Variablen mit dem Praefix TEST_RUNNER_ an den Testprozess durch
// (TEST_RUNNER_UF_E2E_PDF=... erscheint hier als UF_E2E_PDF).
//
// Zwei getrennte lokale Benutzer A und B: eigene App-Container im Temp-Ordner, darin je ein Datencontainer (erfundener
// Apple-Nutzer, LUH) wie in der App (`ContainerManager`) mit eigener Datenbank, eigenem Journal und eigener
// Loesungsablage, Tarif Plus ueber den Testsetzer der Berechtigung.
//   1. A: PDF wie eine Stud.IP-Datei ueber den Download-Ablauf des Abgleichs (`UniDownloads.load`, Ablage im
//      Stud.IP-Ordner des Containers), im echten Editor im Fenster oeffnen, Strich auf Seite 1 ueber die Canvas, warten
//      bis gespeichert.
//   2. A: "Loesung teilen" mit Seite 1 ueber SolutionSharing (Weg des Dialogs) -> .uniflowsolution, Strichgrenzen.
//   3. Paket ohne PDF-Bytes und deutlich kleiner als die PDF.
//   4. B: dieselbe PDF als eigene PDF importieren (POST /api/notebooks), eigener Strich, Notizen und Journal sichern.
//   5. B: Loesung ueber DocumentStore.importSolution -> fremde Ebene auf Seite 1, Lage wie bei A (0,5 pt), Ebenen
//      umschalten, scrollen und zoomen.
//   6. B: eigene Notizen und Journal byte-gleich; B schreibt weiter, ohne dass Fremdes in seine Notizen kommt.
//   7. Gegenprobe mit der zweiten PDF: nicht angezeigt, klare Meldung, nichts gespeichert.
//   8. Bilder der Editor-Fenster (drawHierarchy) und bericht.json.

/// Fehler je Punkt des Ablaufs fuer bericht.json (XCTest meldet jeden Fehler ueber `record(_:)`).
private final class E2EIssueLog: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var issues: [Int: [String]] = [:]

    func begin(_ step: Int) {
        lock.lock()
        current = step
        if issues[step] == nil { issues[step] = [] }
        lock.unlock()
    }

    func add(_ text: String) {
        lock.lock()
        issues[current, default: []].append(text)
        lock.unlock()
    }

    func issues(_ step: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return issues[step] ?? []
    }

    func reset() {
        lock.lock()
        current = 0
        issues = [:]
        lock.unlock()
    }
}

private let e2eIssueLog = E2EIssueLog()

private struct E2EError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

/// Ein Benutzer auf seinem eigenen "Geraet": App-Container im Temp-Ordner, darin der Datencontainer (Apple-Nutzer,
/// LUH; `DataContainerLayout` wie in der App) mit Datenbank, Journal, PDF-Zwischenspeicher, Stud.IP-Ordner und
/// Loesungsablage; Tarif ueber eine eigene Berechtigung.
@MainActor
private final class E2EUser {
    let label: String
    /// App-Container im Temp-Ordner (Documents fuer "Oeffnen in")
    let container: URL
    /// Datencontainer dieses Nutzers an der LUH
    let layout: DataContainerLayout
    let host: LocalBackendHost
    let api: APIClient
    let entitlements: Entitlements
    let solutions: SolutionLibrary

    init(label: String, container: URL, clock: UniFlowClock) throws {
        self.label = label
        self.container = container
        layout = DataContainerLayout(base: container.appendingPathComponent("Library/Application Support/UniFlowContainers", isDirectory: true),
                                     key: DataContainerKey(userID: "001234.erfunden.e2e\(label)", university: .luh))
        try layout.prepare(clock: clock)
        host = LocalBackendHost(directory: layout.databaseDirectory, clock: clock, files: .container(layout), university: .luh)
        api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        // Tarif Plus ueber den Testsetzer (kein StoreKit): Schreiben und "Community" (Loesungen teilen und ansehen)
        entitlements = Entitlements(observe: false, plan: .free)
        entitlements.setPlanForTesting(.plus)
        solutions = SolutionLibrary(root: layout.solutions)
    }

    /// AppPaths.support dieses Geraets (Journal, PDF-Zwischenspeicher, Datenbank): der Datencontainer
    var support: URL { layout.root }
    var studipRoot: URL { layout.studip }
    var journal: URL { layout.journal }
    /// Dateien, die von aussen kommen (wie "Oeffnen in" bzw. die Dateien-App: Kopie im eigenen Container)
    var inbox: URL { container.appendingPathComponent("Documents/Inbox", isDirectory: true) }
}

/// Stand der eigenen Notizen eines Dokuments: Antworten des Backends (in kanonischer Form mit sortierten
/// Schluesseln und roh), gespeicherte Zeilen der Datenbank (Bytes wie abgelegt), Dokument im Store, Journal.
private struct E2ENotes {
    /// GET /api/files/{id}/annotations, kanonisch
    var notes: Data
    /// GET /api/files/{id}/annotations/versions, kanonisch
    var versions: Data
    /// Zeilen aus `annotations` und `annotation_versions` mit den gespeicherten Daten
    var stored: Data
    /// GET annotations wie geliefert (Reihenfolge der Schluessel kann je Antwort wechseln)
    var raw: Data
    var doc: Data
    var journal: [String: Data]
}

/// Zustand ueber die Punkte hinweg.
@MainActor
private final class E2EState {
    var fileA = ""
    var fingerprint = ""
    var storeA: DocumentStore?
    var editorA: PDFEditorController?
    var windowA: UIWindow?
    var keyA = "p1"
    var strokeA: JSONValue?
    var packageURL: URL?
    var packageData = Data()
    var solutionID = ""
    var displayName = "Testperson A"

    var fileB = ""
    var storeB: DocumentStore?
    var editorB: PDFEditorController?
    var windowB: UIWindow?
    var strokeIDsB: [String] = []
    var beforeImport: E2ENotes?

    var storeWrong: DocumentStore?
    var windowWrong: UIWindow?

    var results: [[String: Any]] = []
    var values: [Int: [String: Any]] = [:]
    var images: [String] = []
}

@MainActor
final class RealSheetSolutionE2ETests: XCTestCase {
    let cipher = CryptoKitSolutionCipher()

    private static let clock = UniFlowClock.fixed(berlin: "2026-10-26T10:00:00")!
    /// Gleiches Fenster fuer A und B (iPad hochkant), damit auch die Lage im Fenster vergleichbar ist
    private static let windowFrame = CGRect(x: 0, y: 0, width: 834, height: 1194)
    /// Strich von A blau, Striche von B rot: im Bild und in den Daten eindeutig zu unterscheiden
    private static let colorA = UIColor(red: 0.05, green: 0.35, blue: 0.95, alpha: 1)
    private static let colorB = UIColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)

    private var windows: [UIWindow] = []

    nonisolated override func record(_ issue: XCTIssue) {
        e2eIssueLog.add(issue.compactDescription)
        super.record(issue)
    }

    // MARK: Ablauf

    func testRealSheetShareAndViewWithTwoSeparateUsers() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let pdfPath = env["UF_E2E_PDF"], !pdfPath.isEmpty else {
            throw XCTSkip("Ende-zu-Ende-Test mit echter PDF nur mit Umgebungsvariablen (TEST_RUNNER_UF_E2E_PDF=…)")
        }
        let wrongPath = env["UF_E2E_WRONG_PDF"].flatMap { $0.isEmpty ? nil : $0 }
        let outPath = env["UF_E2E_OUT"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSTemporaryDirectory() + "uniflow-e2e-out")
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        e2eIssueLog.reset()

        let realPDF = URL(fileURLWithPath: pdfPath)
        let pdfBytes = try Data(contentsOf: realPDF)                // nur zur Laufzeit gelesen
        XCTAssertTrue(pdfBytes.starts(with: Array("%PDF".utf8)), "UF_E2E_PDF ist keine PDF")
        let pdfDoc = try XCTUnwrap(PDFDocument(data: pdfBytes), "UF_E2E_PDF laesst sich nicht oeffnen")

        let a = try E2EUser(label: "A", container: try tempDir("A"), clock: Self.clock)
        let b = try E2EUser(label: "B", container: try tempDir("B"), clock: Self.clock)
        let s = E2EState()
        // die Ablage der App selbst (aktiver Container, <Container>/solutions) darf der Test nie beruehren
        let appLibraryBefore = (SolutionSharing.library.allEntries().count, SolutionSharing.library.sharedEntries().count)

        await step(1, "A: echte PDF ueber den S3-Weg, Editor im Fenster, Strich auf Seite 1, gespeichert", s) {
            try await self.step1(a, s, realPDF: realPDF, pdfBytes: pdfBytes, out: out)
        }
        await step(2, "A: Lösung teilen mit Seite 1 ueber SolutionSharing -> .uniflowsolution, Strichgrenzen", s) {
            try await self.step2(a, s, out: out)
        }
        await step(3, "Paket ohne PDF-Bytes, deutlich kleiner als die PDF", s) {
            try self.step3(s, pdfBytes: pdfBytes)
        }
        await step(4, "B: dieselbe PDF als eigene PDF importieren, eigener Strich, Notizen und Journal sichern", s) {
            try await self.step4(b, s, realPDF: realPDF, pdfBytes: pdfBytes, out: out)
        }
        await step(5, "B: Lösung importieren -> fremde Ebene auf Seite 1, Lage wie bei A, Ebenen umschalten, scrollen", s) {
            try await self.step5(b, s, out: out)
        }
        await step(6, "B: eigene Notizen und Journal byte-gleich, weiter schreiben ohne fremde Objekte", s) {
            try await self.step6(b, s, out: out)
        }
        await step(7, "Gegenprobe: zweite echte PDF, Lösung nicht angezeigt, klare Meldung, nichts gespeichert", s) {
            guard let wrongPath else {
                s.values[7, default: [:]]["uebersprungen"] = "UF_E2E_WRONG_PDF nicht gesetzt"
                return
            }
            try await self.step7(b, s, wrongPDF: URL(fileURLWithPath: wrongPath), pdfBytes: pdfBytes, out: out)
        }
        await step(8, "Bilder (drawHierarchy der Editor-Fenster) und Ergebnisdateien", s) {
            for name in s.images + ["A-loesung.uniflowsolution", "A-strich.json"] {
                let url = out.appendingPathComponent(name)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(name) fehlt")
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                XCTAssertGreaterThan(size, 0, "\(name) leer")
                s.values[8, default: [:]][name] = size
            }
            for required in ["A-seite1.png", "B-seite1-eigen-und-fremd.png"] {
                XCTAssertTrue(s.images.contains(required), "\(required) nicht erzeugt")
            }
        }

        // aufraeumen: Dokumente schliessen (sichert Ausstehendes), Fenster weg; die Container loescht der Teardown
        e2eIssueLog.begin(9)
        for store in [s.storeA, s.storeB, s.storeWrong].compactMap({ $0 }) { await store.close() }
        windows.forEach { $0.isHidden = true; $0.rootViewController = nil }
        windows = []
        let appLibraryAfter = (SolutionSharing.library.allEntries().count, SolutionSharing.library.sharedEntries().count)
        XCTAssertTrue(appLibraryBefore == appLibraryAfter, "Ablage der App selbst unberuehrt")

        let closing = e2eIssueLog.issues(9)
        let passed = closing.isEmpty && s.results.allSatisfy { ($0["ergebnis"] as? String) != "fehlgeschlagen" }
        let report: [String: Any] = [
            "test": "UniFlowTests/RealSheetSolutionE2ETests/testRealSheetShareAndViewWithTwoSeparateUsers",
            "zeit": ISO8601DateFormatter().string(from: Date()),
            "simulator": [env["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.model, UIDevice.current.systemName,
                          UIDevice.current.systemVersion].joined(separator: " "),
            "pdf": ["bytes": pdfBytes.count, "seiten": pdfDoc.pageCount, "sha256Anfang": String(cipher.sha256Hex(pdfBytes).prefix(12)),
                    "zweitePDF": wrongPath != nil],
            "gesamt": passed ? "bestanden" : "fehlgeschlagen",
            "punkte": s.results,
            "ablageDerAppUnberuehrt": appLibraryBefore == appLibraryAfter,
            "abschlussFehler": closing,
            "echt": Self.realParts,
            "nachgebildet": Self.simulatedParts,
            "dateien": (s.images + ["A-loesung.uniflowsolution", "A-strich.json", "bericht.json"]).map { out.appendingPathComponent($0).path },
        ]
        try writeJSON(report, to: out.appendingPathComponent("bericht.json"))
        print("E2E-Bericht: \(out.appendingPathComponent("bericht.json").path) – \(passed ? "bestanden" : "fehlgeschlagen")")
    }

    static let realParts = [
        "echte PDF-Datei (UF_E2E_PDF) mit unveraenderten Bytes, nur zur Laufzeit gelesen; Fingerabdruck und Schluessel aus diesen Bytes",
        "zwei getrennte Benutzer: je eigener App-Container mit eigenem Datencontainer (Apple-Nutzer, LUH; DataContainerLayout wie in der App), eigene SQLite-Datenbank (LocalBackendHost/LocalTransport), eigenes Journal, eigene Loesungsablage; kein PC-Server, kein Netz",
        "Datenweg des Abgleichs fuer A: StudIPLibrary.storeCourses/storeFiles, UniDownloads.load (Zwischendatei, Pruefungen, Ablage im Stud.IP-Ordner des Containers, Inhalts-Hash, markDownloaded mit Seitentexten), GET /api/library, GET /api/files/{id}/content in den PDF-Zwischenspeicher",
        "PDF-Import fuer B wie \"PDF importieren\": POST /api/notebooks (multipart, kind pdf)",
        "DocumentStore mit SyncEngine: Speichern 0,25 s nach dem Strich in Journal und lokale Datenbank (PUT annotations)",
        "PDFEditorController als rootViewController eines UIWindow; PDFKit setzt die Seiten-Overlays selbst ein; echte PKCanvasView mit dem Editor als Delegate",
        "Lösung teilen ueber dieselben Aufrufe wie der Dialog: DocumentStore.solutionSource, SolutionSharing.draft (Vorauswahl), SolutionSharing.shareFile; AES-256-GCM und HKDF-SHA256 aus CryptoKit",
        "Empfang ueber DocumentStore.importSolution und DocumentStore.solutionLayers, Anzeige als ForeignLayerView in der fremden Schicht des Overlays",
        "Scrollen und Zoomen ueber PDFView/UIScrollView im Fenster; Bilder per drawHierarchy des Fensters",
    ]

    static let simulatedParts = [
        "Apple Pencil: der Strich ist ein PKStroke, der auf die echte Canvas gesetzt wird; Beginn und Ende des Werkzeugs meldet der Test an den Delegate, canvasViewDrawingDidChange kommt von PencilKit selbst oder, falls PencilKit beim Setzen nichts meldet, vom Test (Feld pencilKitMeldetAenderung)",
        "Stud.IP: keine Anmeldung, kein Abruf; Kurs- und Dateieintrag sind erfunden (E2E-Blatt.pdf), der Abruf in die Zwischendatei von UniDownloads ist durch eine Kopie der echten Datei ersetzt",
        "kein SwiftUI-Dialog \"Lösung teilen\" und kein Teilen-Blatt des Systems (ActivityView); gewaehlt wird die Vorauswahl des Dialogs (Seite 1)",
        "keine Dateien-App und kein AirDrop: das Paket wird in den Container von B kopiert (wie \"Öffnen in\") und von dort importiert",
        "kein Menue \"Ebenen\": umgeschaltet wird ueber dieselben Eigenschaften, die DocumentView setzt (ownNotesVisible, foreignLayers, SolutionLibrary.setVisible)",
        "die Meldung bei der falschen PDF setzt der Test so zusammen wie DocumentView.importSolution (Text aus SolutionError.fingerprintMismatch)",
        "A und B laufen im selben Prozess auf demselben Simulator nacheinander (getrennte Ordner und Datenbanken), nicht auf zwei Geraeten; Tarif Plus ueber Entitlements.setPlanForTesting statt StoreKit",
    ]

    // MARK: Punkte

    private func step1(_ a: E2EUser, _ s: E2EState, realPDF: URL, pdfBytes: Data, out: URL) async throws {
        XCTAssertTrue(a.entitlements.notes.canEdit, "Plus: Schreiben erlaubt")
        let id = try await adoptAsStudIPFile(a, pdf: realPDF, size: pdfBytes.count)
        s.fileA = id
        let meta = try await a.api.value("/api/files/\(id)")
        XCTAssertEqual(meta["exists"], true, "Datei im Stud.IP-Ordner")
        let file = try await libraryFile(a.api, id)
        XCTAssertTrue(file.isPDF)
        let store = DocumentStore(file: file, api: a.api, root: a.support)
        s.storeA = store
        await store.load()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(try store.originalPDFData(), pdfBytes, "Original-PDF ueber den S3-Weg unveraendert")
        let fp = await store.originalFingerprint()
        s.fingerprint = try XCTUnwrap(fp)
        XCTAssertEqual(s.fingerprint, cipher.sha256Hex(pdfBytes))
        let key = try XCTUnwrap(store.pageKey(forPageIndex: 0))
        s.keyA = key

        let (editor, window) = showEditor(store, for: a)
        s.editorA = editor
        s.windowA = window
        let overlay = try await waitForOverlay(editor)
        XCTAssertEqual(overlay.pageKey, key)
        XCTAssertTrue(overlay.canvas.isUserInteractionEnabled, "Canvas nimmt Eingaben an (Plus, Notizen eingeblendet)")
        let size = overlay.geometry.pageSize
        // angezeigte Drehung der Seite 1 (/Rotate der PDF, keine eigene Drehung)
        let rotation = store.layout?.pdf.page(at: 0)?.rotation ?? 0

        let stroke = penStroke(curve(size, from: (0.22, 0.34), to: (0.52, 0.38), bump: 0.025), color: Self.colorA)
        let byPencilKit = pencilStroke(editor, on: overlay, stroke)
        // warten bis gespeichert, wie im Editor ohne ausdrueckliches Sichern (0,25 s nach dem Strich)
        let saved = await waitUntil(15) {
            let strokes = ((try? await self.pageObjects(a.api, id, page: key)) ?? []).filter { $0["type"]?.string == "stroke" }
            return strokes.count == 1 && store.status == .saved
        }
        XCTAssertTrue(saved, "Strich in der Datenbank von A gespeichert, Status: \(store.status.label)")
        let strokes = try await pageObjects(a.api, id, page: key).filter { $0["type"]?.string == "stroke" }
        XCTAssertEqual(strokes.count, 1)
        let object = try XCTUnwrap(strokes.first)
        s.strokeA = object
        XCTAssertEqual(object["color"]?.string, Self.colorA.uniflowRGBA.hex)
        XCTAssertFalse(fileSnapshot(a.journal).isEmpty, "Journal von A vorhanden")
        XCTAssertTrue(editor.undoManager?.canUndo == true, "Rueckgaengig-Schritt angelegt (canvasViewDrawingDidChange lief)")

        // Lage bei A: Mittellinie des Strichs auf der Canvas (Seitenpunkte) und im Notizmodell
        let drawn = try XCTUnwrap(overlay.canvas.drawing.strokes.last)
        let pk = centerline(drawn)
        let model = try objectBounds(object)
        let inWindow = overlay.canvas.convert(pk, to: window)
        try writeJSON([
            "pdfSeite": 1, "seitenSchluessel": key,
            "koordinaten": "Punkte der angezeigten Seite, Ursprung oben links, ohne Zoom (wie das Notizmodell)",
            "seitenGroesse": ["w": Double(size.width), "h": Double(size.height)],
            "drehung": rotation,
            "strich": ["id": object["id"]?.string ?? "", "farbe": object["color"]?.string ?? "", "breite": object["width"]?.double ?? 0,
                       "punkte": (object["points"]?.array?.count ?? 0) / 2],
            "grenzenNotizmodell": rectJSON(model),
            "grenzenPencilKit": rectJSON(pk),
            "renderBoundsPencilKit": rectJSON(drawn.renderBounds),
            "fensterA": rectJSON(inWindow),
            "fensterGroesse": ["w": Double(Self.windowFrame.width), "h": Double(Self.windowFrame.height)],
        ], to: out.appendingPathComponent("A-strich.json"))
        for (k, d) in [("minX", model.minX - pk.minX), ("minY", model.minY - pk.minY), ("maxX", model.maxX - pk.maxX), ("maxY", model.maxY - pk.maxY)] {
            XCTAssertEqual(Double(d), 0, accuracy: 0.02, "Notizmodell = Canvas, \(k)")
        }

        try await Task.sleep(nanoseconds: 1_200_000_000)            // PDFKit zeichnet seine Kacheln nach
        let shot = snapshot(window)
        try save(shot, "A-seite1.png", out: out, s)
        let blue = countPixels(shot, in: inWindow.insetBy(dx: -3, dy: -3), Self.isBlue)
        s.values[1] = [
            "dateiID": id, "localPath": meta["local_path"]?.string ?? "", "pdfSeiten": store.pdf?.pageCount ?? 0,
            "seitenGroesse": "\(Int(size.width)) x \(Int(size.height))", "drehung": rotation,
            "strichID": object["id"]?.string ?? "", "pencilKitMeldetAenderung": byPencilKit, "status": store.status.label,
            "blauePixelImBild": blue,
        ]
        XCTAssertGreaterThan(blue, 20, "Strich von A im Bild des Fensters (drawHierarchy)")
    }

    private func step2(_ a: E2EUser, _ s: E2EState, out: URL) async throws {
        let store = try XCTUnwrap(s.storeA)
        // wie SolutionShareSheet.load: nur mit "Community" (Plus)
        XCTAssertTrue(a.entitlements.allows(.community), "Plus: Lösung teilen erlaubt")
        let source = try await store.solutionSource(loadImage: ShareExport.serverImageLoader(a.api))
        let draft = try await Task.detached(priority: .userInitiated) { try SolutionSharing.draft(source) }.value
        let preview = try XCTUnwrap(draft.content, draft.unavailable ?? "keine Vorschau")
        XCTAssertEqual(draft.selection, [s.keyA], "Vorauswahl: Seite 1 (die einzige mit eigenen Notizen)")
        XCTAssertTrue(draft.problems.isEmpty)
        XCTAssertTrue(draft.canShare(draft.selection))
        XCTAssertFalse(draft.showsNoOwnNotes(draft.selection))
        // Vorschau ohne Original (Miniatur des Dialogs, gleiche Zeichenroutine), als Bild abgelegt
        if let page = preview.pages.first(where: { $0.key == s.keyA }) {
            let image = SolutionPreview.image(page, images: [:], width: 595, scale: 1)
            try save(image, "A-vorschau-ohne-original.png", out: out, s)
        }

        let url = try await SolutionSharing.shareFile(source, keys: Array(draft.selection), displayName: s.displayName, library: a.solutions)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(url.pathExtension, SolutionPackage.fileExtension)
        let copy = out.appendingPathComponent("A-loesung.uniflowsolution")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: url, to: copy)
        s.packageURL = copy
        s.packageData = try Data(contentsOf: copy)
        let package = try SolutionPackage.decode(s.packageData)
        s.solutionID = package.header.solutionID
        XCTAssertEqual(package.header.fingerprint, s.fingerprint)
        XCTAssertEqual(package.header.pageCount, 1, "nur Seite 1")
        XCTAssertEqual(package.header.displayName, s.displayName)
        XCTAssertEqual(a.solutions.sharedEntries().map(\.solutionID), [s.solutionID], "unter „Meine geteilten Lösungen“")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("A-strich.json").path))
        s.values[2] = ["dateiname": url.lastPathComponent, "bytes": s.packageData.count, "loesungsID": s.solutionID,
                       "auswahl": Array(draft.selection), "anzeigename": s.displayName]
    }

    private func step3(_ s: E2EState, pdfBytes: Data) throws {
        let blob = s.packageData
        XCTAssertFalse(blob.isEmpty, "Paket vorhanden")
        guard !blob.isEmpty else { return }
        let content = try SolutionPackage.decode(blob).open(originalPDF: pdfBytes, cipher: cipher)
        let plain = content.json.serialized(sortedKeys: true)
        XCTAssertEqual(content.pages.map(\.key), [s.keyA])
        XCTAssertEqual(content.pages.first?.objects, s.strokeA.map { [$0] }, "nur der eigene Strich, 1:1")
        for marker in ["%PDF", "%%EOF", "JVBERi0"] {
            XCTAssertNil(blob.range(of: Data(marker.utf8)), "Paket enthaelt \(marker)")
        }
        for marker in ["%PDF", "%%EOF", "JVBERi0", "endobj", "/MediaBox", "xref", "pkdrawing"] {
            XCTAssertNil(plain.range(of: Data(marker.utf8)), "Klartext enthaelt \(marker)")
        }
        // jede 64-Byte-Folge der PDF (an jeder Position) gegen Paket und Klartext, dazu Base64 der PDF
        let rawInPackage = windowsFound(pdfBytes, in: blob)
        let rawInPlain = windowsFound(pdfBytes, in: plain)
        XCTAssertEqual(rawInPackage, [], "64-Byte-Folgen der PDF im Paket")
        XCTAssertEqual(rawInPlain, [], "64-Byte-Folgen der PDF im Klartext")
        var base64Hits = 0
        for shift in 0..<3 {
            let b64 = Data(pdfBytes.dropFirst(shift).base64EncodedString().utf8)
            base64Hits += windowsFound(b64, in: blob, stride: 4).count
        }
        XCTAssertEqual(base64Hits, 0, "Base64 der PDF im Paket")
        let ratio = Double(blob.count) / Double(pdfBytes.count)
        XCTAssertLessThan(ratio, 0.1, "Paket deutlich kleiner als die PDF: \(blob.count) zu \(pdfBytes.count) Byte")
        s.values[3] = ["paketBytes": blob.count, "pdfBytes": pdfBytes.count, "verhaeltnis": round4(ratio),
                       "klartextBytes": plain.count, "gepruefte64ByteFolgen": max(0, pdfBytes.count - 63),
                       "funde": rawInPackage.count + rawInPlain.count + base64Hits]
    }

    private func step4(_ b: E2EUser, _ s: E2EState, realPDF: URL, pdfBytes: Data, out: URL) async throws {
        XCTAssertTrue(b.entitlements.notes.canEdit)
        let id = try await importOwnPDF(b, from: realPDF, name: "E2E-Blatt.pdf")
        s.fileB = id
        let file = try await libraryFile(b.api, id)
        XCTAssertTrue(file.isPDF)
        let store = DocumentStore(file: file, api: b.api, root: b.support)
        s.storeB = store
        await store.load()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(try store.originalPDFData(), pdfBytes, "eigene Kopie von B: gleiche Bytes")
        let fp = await store.originalFingerprint()
        XCTAssertEqual(fp, s.fingerprint, "gleicher Fingerabdruck wie bei A")
        XCTAssertNotEqual(b.container, try XCTUnwrap(s.storeA).originalPDFURL.deletingLastPathComponent(), "getrennte Geraete")

        let (editor, window) = showEditor(store, for: b)
        s.editorB = editor
        s.windowB = window
        let overlay = try await waitForOverlay(editor)
        let key = overlay.pageKey
        let size = overlay.geometry.pageSize
        let byPencilKit = pencilStroke(editor, on: overlay, penStroke(curve(size, from: (0.25, 0.62), to: (0.55, 0.60), bump: -0.02),
                                                                         color: Self.colorB))
        let saved = await waitUntil(15) {
            let strokes = ((try? await self.pageObjects(b.api, id, page: key)) ?? []).filter { $0["type"]?.string == "stroke" }
            return strokes.count == 1 && store.status == .saved
        }
        XCTAssertTrue(saved, "eigener Strich von B gespeichert, Status: \(store.status.label)")
        s.strokeIDsB = try await pageObjects(b.api, id, page: key).compactMap { $0["id"]?.string }
        XCTAssertEqual(s.strokeIDsB.count, 1)
        XCTAssertFalse(s.strokeIDsB.contains(s.strokeA?["id"]?.string ?? "-"), "B hat einen eigenen Strich")
        // eigene Notizen von B byteweise sichern: Antworten des Backends, Dokument im Store, alle Journal-Dateien
        let before = try await settled(store, b, id)
        s.beforeImport = before
        XCTAssertFalse(before.journal.isEmpty)
        s.values[4] = ["dateiID": id, "fingerabdruckGleich": fp == s.fingerprint, "pencilKitMeldetAenderung": byPencilKit,
                       "annotationsBytes": before.notes.count, "journalDateien": before.journal.count, "strichIDs": s.strokeIDsB]
    }

    private func step5(_ b: E2EUser, _ s: E2EState, out: URL) async throws {
        let store = try XCTUnwrap(s.storeB)
        let editor = try XCTUnwrap(s.editorB)
        let window = try XCTUnwrap(s.windowB)
        let packageURL = try XCTUnwrap(s.packageURL)
        XCTAssertTrue(b.entitlements.allows(.community), "Plus: Lösungen ansehen erlaubt")
        // Zwischenstaende der eigenen Notizen (ohne Sichern), um eine Abweichung einem Schritt zuordnen zu koennen
        let notesBefore = try XCTUnwrap(s.beforeImport).notes
        var unchanged: [String: Bool] = [:]
        func checkpoint(_ name: String) async throws {
            try await Task.sleep(nanoseconds: 500_000_000)
            unchanged[name] = try await notesBytes(b.api, s.fileB).annotations == notesBefore
        }
        try await checkpoint("vorImport")
        // empfangene Datei im Container von B (wie "Oeffnen in")
        try FileManager.default.createDirectory(at: b.inbox, withIntermediateDirectories: true)
        let received = b.inbox.appendingPathComponent("E2E-Blatt – Lösung.uniflowsolution")
        try? FileManager.default.removeItem(at: received)
        try FileManager.default.copyItem(at: packageURL, to: received)

        let result = try await store.importSolution(received, library: b.solutions)
        guard case .shown(let entry) = result else { throw E2EError("Import nicht angezeigt: \(result)") }
        XCTAssertEqual(entry.solutionID, s.solutionID)
        // wie DocumentView.reloadSolutionLayers
        let load = await store.solutionLayers(library: b.solutions)
        XCTAssertEqual(load.problems.map(\.text), [])
        XCTAssertEqual(load.layers.map(\.id), [s.solutionID])
        let layer = try XCTUnwrap(load.layers.first)
        XCTAssertEqual(layer.byPDFIndex[1]?.objects, s.strokeA.map { [$0] }, "fremde Ebene = Strich von A")
        editor.foreignLayers = load.layers
        try await Task.sleep(nanoseconds: 300_000_000)
        let overlay = try await waitForOverlay(editor)
        let views = overlay.foreignLayerViews
        XCTAssertEqual(views.count, 1, "genau eine fremde Ebene auf Seite 1")
        let view = try XCTUnwrap(views.first)
        let expectedLabel = ForeignSolutionLayer.label(displayName: s.displayName, createdAt: layer.createdAt)
        XCTAssertEqual(view.accessibilityLabel, expectedLabel)
        XCTAssertTrue(expectedLabel.hasPrefix("Lösung von \(s.displayName) ("), expectedLabel)
        XCTAssertFalse(overlay.foreignView.isHidden)
        XCTAssertTrue(view.window === window, "im Fenster")
        XCTAssertEqual(view.strokeCount, 1)
        // Reihenfolge: fremde Schicht ueber der PDF, unter eigenen Objekten und der Canvas
        let order = overlay.content.subviews
        XCTAssertLessThan(order.firstIndex(of: overlay.foreignView) ?? 99, order.firstIndex(of: overlay.canvas) ?? -1)

        // Lage: Grenzen in Seitenpunkten wie in A-strich.json (0,5 pt)
        let saved = try readJSON(packageURL.deletingLastPathComponent().appendingPathComponent("A-strich.json"))
        let wantModel = try XCTUnwrap(saved["grenzenNotizmodell"] as? [String: Any])
        let wantPK = try XCTUnwrap(saved["grenzenPencilKit"] as? [String: Any])
        let wantWindow = try XCTUnwrap(saved["fensterA"] as? [String: Any])
        let shown = displayedBounds(view, in: overlay.foreignView.layer)
        XCTAssertGreaterThan(shown.layers, 0)
        assertBounds(shown.rect, wantModel, 0.5, "fremder Strich (Seitenpunkte) gegen Notizmodell von A")
        assertBounds(shown.rect, wantPK, 0.5, "fremder Strich (Seitenpunkte) gegen Canvas von A")
        XCTAssertTrue(view.mapping.isIdentity, "gleiche Drehung wie bei A")
        let inWindow = displayedBounds(view, in: window.layer).rect
        assertBounds(inWindow, wantWindow, 1.0, "fremder Strich im Fenster von B gegen Strich im Fenster von A")
        let modelRect = rect(wantModel)
        let pdfPage = try XCTUnwrap(editor.pdfView.document?.page(at: 0))
        assertBounds(inWindow, rectJSON(pdfWindowRect(modelRect, page: pdfPage, in: editor.pdfView, window: window)), 1.0,
                     "fremder Strich im Fenster auf der PDF-Seite (PDFKit)")
        let ownRect = try ownStrokeWindowRect(overlay, window: window)
        try await checkpoint("nachImport")

        // Bilder und Pixelprobe: beide Ebenen, nur fremde, nur eigene
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let both = snapshot(window)
        try save(both, "B-seite1-eigen-und-fremd.png", out: out, s)
        let probe = inWindow.insetBy(dx: -3, dy: -3), ownProbe = ownRect.insetBy(dx: -3, dy: -3)
        let blueBoth = countPixels(both, in: probe, Self.isBlue), redBoth = countPixels(both, in: ownProbe, Self.isRed)

        editor.ownNotesVisible = false                              // Menue "Ebenen": "Meine Notizen" aus
        XCTAssertTrue(store.ownNotesReadOnly)
        XCTAssertTrue(overlay.canvas.isHidden)
        XCTAssertFalse(overlay.canvas.isUserInteractionEnabled)
        XCTAssertEqual(overlay.foreignLayerViews.count, 1, "fremde Ebene bleibt sichtbar")
        try await Task.sleep(nanoseconds: 600_000_000)
        let foreignOnly = snapshot(window)
        try save(foreignOnly, "B-seite1-nur-fremd.png", out: out, s)
        let blueForeignOnly = countPixels(foreignOnly, in: probe, Self.isBlue), redForeignOnly = countPixels(foreignOnly, in: ownProbe, Self.isRed)
        editor.ownNotesVisible = true                               // wieder an
        XCTAssertFalse(store.ownNotesReadOnly)
        XCTAssertFalse(overlay.canvas.isHidden)

        try b.solutions.setVisible(s.solutionID, false)             // Menue "Ebenen": Loesung ausblenden
        var hidden = load.layers
        hidden[0].visible = false
        editor.foreignLayers = hidden
        XCTAssertTrue(overlay.foreignLayerViews.isEmpty, "fremde Ebene ausgeblendet")
        XCTAssertEqual(b.solutions.allEntries().first?.visible, false)
        try await Task.sleep(nanoseconds: 600_000_000)
        let ownOnly = snapshot(window)
        try save(ownOnly, "B-seite1-fremd-aus.png", out: out, s)
        let blueOwnOnly = countPixels(ownOnly, in: probe, Self.isBlue), redOwnOnly = countPixels(ownOnly, in: ownProbe, Self.isRed)
        try b.solutions.setVisible(s.solutionID, true)              // wieder an, neu geladen wie nach einer Aenderung
        let reloaded = await store.solutionLayers(library: b.solutions)
        XCTAssertEqual(reloaded.layers.map(\.visible), [true])
        editor.foreignLayers = reloaded.layers
        XCTAssertEqual(overlay.foreignLayerViews.count, 1)

        try await checkpoint("nachUmschalten")
        XCTAssertGreaterThan(blueBoth, 20, "fremde Ebene im Bild")
        XCTAssertGreaterThan(blueForeignOnly, 20, "fremde Ebene im Bild bei ausgeblendeten eigenen Notizen")
        XCTAssertLessThan(blueOwnOnly * 4, max(blueBoth, 1), "fremde Ebene aus: Tinte weg")
        XCTAssertGreaterThan(redBoth, 20, "eigener Strich von B im Bild")
        XCTAssertGreaterThan(redOwnOnly, 20, "eigener Strich bleibt bei ausgeblendeter Loesung")
        XCTAssertLessThan(redForeignOnly * 4, max(redBoth, 1), "eigene Notizen aus: eigener Strich weg")
        // gleiche Strichbreite wie bei A: gleiches Fenster, gleicher Zoom, gleiche Lage -> etwa gleich viele blaue Pixel
        let blueA = try XCTUnwrap(s.values[1]?["blauePixelImBild"] as? Int)
        XCTAssertEqual(Double(blueForeignOnly) / Double(max(blueA, 1)), 1, accuracy: 0.15,
                       "fremder Strich bei B so breit wie bei A: \(blueForeignOnly) zu \(blueA) blaue Pixel")

        // Scrollen und Zoomen im Fenster: PDFKit gibt Overlays ab und setzt sie wieder ein
        let pages = editor.pdfView.document?.pageCount ?? 1
        // Seite 1 beim Scrollen ausserhalb des sichtbaren Fensters; ob PDFKit ihr Overlay dabei abgibt, entscheidet
        // PDFKit selbst (bei wenigen Seiten bleibt es oft eingesetzt)
        var page1Released = false, page1OutOfView = false
        func notePage1() {
            page1Released = page1Released || overlay.window == nil
            if overlay.window != nil { page1OutOfView = page1OutOfView || !window.bounds.intersects(overlay.convert(overlay.bounds, to: window)) }
        }
        if pages > 1 {
            editor.goToPage(pages - 1)
            try await Task.sleep(nanoseconds: 900_000_000)
            notePage1()
        }
        if let scroll = firstScrollView(editor.pdfView) {
            let bottom = max(0, scroll.contentSize.height - scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            try await Task.sleep(nanoseconds: 700_000_000)
            notePage1()
            scroll.setContentOffset(.zero, animated: false)
            try await Task.sleep(nanoseconds: 700_000_000)
        }
        // 2-fach-Zoom und Scrollen: die fremde Ebene liegt im Fenster weiter auf der PDF-Seite (nicht nur in den
        // Koordinaten ihrer eigenen Schicht)
        editor.pdfView.scaleFactor = editor.pdfView.scaleFactor * 2
        try await Task.sleep(nanoseconds: 900_000_000)
        let zoomedOverlay = try await waitForOverlay(editor)
        let zoomedView = try XCTUnwrap(zoomedOverlay.foreignLayerViews.first, "fremde Ebene nach dem Zoom")
        let zoomed = displayedBounds(zoomedView, in: window.layer).rect
        assertBounds(zoomed, rectJSON(pdfWindowRect(modelRect, page: pdfPage, in: editor.pdfView, window: window)), 1.0,
                     "2-fach-Zoom: fremder Strich im Fenster auf der PDF-Seite")
        XCTAssertEqual(Double(zoomed.width / max(inWindow.width, 0.001)), 2, accuracy: 0.05, "2-fach-Zoom: Strich doppelt so breit")
        XCTAssertEqual(Double(zoomed.height / max(inWindow.height, 0.001)), 2, accuracy: 0.1, "2-fach-Zoom: Strich doppelt so hoch")
        var scrolled = CGRect.null, centered = CGRect.null, scrolledBy = CGPoint.zero, blueZoomed = 0
        if let scroll = firstScrollView(editor.pdfView) {
            let start = scroll.contentOffset
            let maxX = max(0, scroll.contentSize.width - scroll.bounds.width)
            let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: min(start.x + 120, maxX), y: min(start.y + 160, maxY)), animated: false)
            try await Task.sleep(nanoseconds: 700_000_000)
            scrolledBy = CGPoint(x: scroll.contentOffset.x - start.x, y: scroll.contentOffset.y - start.y)
            XCTAssertGreaterThan(hypot(scrolledBy.x, scrolledBy.y), 50, "im 2-fach-Zoom gescrollt")
            let scrolledOverlay = try await waitForOverlay(editor)
            let scrolledView = try XCTUnwrap(scrolledOverlay.foreignLayerViews.first, "fremde Ebene nach dem Scrollen im Zoom")
            scrolled = displayedBounds(scrolledView, in: window.layer).rect
            assertBounds(scrolled, rectJSON(pdfWindowRect(modelRect, page: pdfPage, in: editor.pdfView, window: window)), 1.0,
                         "2-fach-Zoom nach dem Scrollen: fremder Strich im Fenster auf der PDF-Seite")
            XCTAssertEqual(Double(scrolled.minX), Double(zoomed.minX - scrolledBy.x), accuracy: 1.0, "verschoben um das Scrollen (x)")
            XCTAssertEqual(Double(scrolled.minY), Double(zoomed.minY - scrolledBy.y), accuracy: 1.0, "verschoben um das Scrollen (y)")
            // Strich in die Fenstermitte scrollen und im Bild an der erwarteten Fensterstelle suchen
            let center = CGPoint(x: min(max(0, scroll.contentOffset.x + scrolled.midX - window.bounds.midX), maxX),
                                 y: min(max(0, scroll.contentOffset.y + scrolled.midY - window.bounds.midY), maxY))
            scroll.setContentOffset(center, animated: false)
            try await Task.sleep(nanoseconds: 700_000_000)
            let centeredOverlay = try await waitForOverlay(editor)
            let centeredView = try XCTUnwrap(centeredOverlay.foreignLayerViews.first, "fremde Ebene nach dem Scrollen zur Mitte")
            centered = displayedBounds(centeredView, in: window.layer).rect
            assertBounds(centered, rectJSON(pdfWindowRect(modelRect, page: pdfPage, in: editor.pdfView, window: window)), 1.0,
                         "2-fach-Zoom, Strich in der Fenstermitte: auf der PDF-Seite")
            XCTAssertTrue(window.bounds.contains(centered.insetBy(dx: -3, dy: -3)), "Strich ganz im Fenster: \(centered)")
            try await Task.sleep(nanoseconds: 600_000_000)
            let shot = snapshot(window)
            try save(shot, "B-seite1-zoom2-mitte.png", out: out, s)
            blueZoomed = countPixels(shot, in: centered.insetBy(dx: -3, dy: -3), Self.isBlue)
            XCTAssertGreaterThan(blueZoomed, 20, "fremder Strich im Bild an der erwarteten Fensterstelle (2-fach, gescrollt)")
            // doppelt so lang und doppelt so breit wie bei A ohne Zoom: etwa viermal so viele blaue Pixel
            XCTAssertEqual(Double(blueZoomed) / Double(4 * max(blueA, 1)), 1, accuracy: 0.2,
                           "2-fach-Zoom: \(blueZoomed) blaue Pixel statt etwa \(4 * blueA)")
        }
        editor.fitWidth()
        editor.goToPage(0)
        try await Task.sleep(nanoseconds: 900_000_000)
        let back = try await waitForOverlay(editor)
        try await checkpoint("nachScrollen")
        if pages > 1 { XCTAssertTrue(page1Released || page1OutOfView, "Seite 1 war beim Scrollen nicht ausserhalb des Fensters") }
        XCTAssertEqual(back.foreignLayerViews.count, 1, "nach dem Scrollen wieder da")
        if let again = back.foreignLayerViews.first {
            assertBounds(displayedBounds(again, in: back.foreignView.layer).rect, wantModel, 0.5, "nach dem Scrollen gleiche Lage")
        }
        s.values[5] = [
            "ergebnis": "shown", "beschriftung": expectedLabel, "grenzenSeite": rectJSON(shown.rect), "grenzenFenster": rectJSON(inWindow),
            "erwartetNotizmodellA": wantModel, "pdfSeiten": pages,
            "pixel": ["blauBeide": blueBoth, "blauNurFremd": blueForeignOnly, "blauFremdAus": blueOwnOnly,
                      "rotBeide": redBoth, "rotNurFremd": redForeignOnly, "rotFremdAus": redOwnOnly],
            "fensterZoom2": rectJSON(zoomed), "fensterZoom2Gescrollt": rectJSON(scrolled), "fensterZoom2Mitte": rectJSON(centered),
            "blauePixelZoom2Mitte": blueZoomed,
            "gescrolltUm": ["x": round4(Double(scrolledBy.x)), "y": round4(Double(scrolledBy.y))], "blauePixelA": blueA,
            "overlayNachScrollenNeu": back !== overlay, "seite1OverlayVonPDFKitAbgegeben": page1Released,
            "seite1AusserhalbDesFensters": page1Released || page1OutOfView, "notizenUnveraendert": unchanged,
        ]
    }

    private func step6(_ b: E2EUser, _ s: E2EState, out: URL) async throws {
        let store = try XCTUnwrap(s.storeB)
        let editor = try XCTUnwrap(s.editorB)
        let window = try XCTUnwrap(s.windowB)
        let before = try XCTUnwrap(s.beforeImport)
        let after = try await settled(store, b, s.fileB)
        XCTAssertEqual(after.stored, before.stored, "gespeicherte Notizen von B (Datenbank) byte-gleich nach Import, Umschalten und Scrollen")
        XCTAssertEqual(after.notes, before.notes, "GET annotations von B (kanonisch) byte-gleich")
        XCTAssertEqual(after.versions, before.versions, "Versionsliste von B unveraendert")
        XCTAssertEqual(after.doc, before.doc, "eigenes Dokument im Store byte-gleich")
        XCTAssertEqual(after.journal, before.journal, "Journal von B byte-gleich; neu: "
                       + Set(after.journal.keys).subtracting(before.journal.keys).sorted().joined(separator: ", "))

        // B schreibt weiter
        let overlay = try await waitForOverlay(editor)
        let size = overlay.geometry.pageSize
        pencilStroke(editor, on: overlay, penStroke(curve(size, from: (0.30, 0.70), to: (0.60, 0.72), bump: 0.015), color: Self.colorB))
        let key = overlay.pageKey
        let saved = await waitUntil(15) {
            let strokes = ((try? await self.pageObjects(b.api, s.fileB, page: key)) ?? []).filter { $0["type"]?.string == "stroke" }
            return strokes.count == 2 && store.status == .saved
        }
        XCTAssertTrue(saved, "zweiter Strich von B gespeichert, Status: \(store.status.label)")
        let objects = try await pageObjects(b.api, s.fileB, page: key)
        let ids = objects.compactMap { $0["id"]?.string }
        XCTAssertEqual(objects.count, 2, "nur die zwei eigenen Striche")
        XCTAssertTrue(Set(ids).isSuperset(of: s.strokeIDsB))
        let foreignID = s.strokeA?["id"]?.string ?? "?"
        XCTAssertFalse(ids.contains(foreignID), "Strich von A nicht in den Notizen von B")
        let colorA = Self.colorA.uniflowRGBA.hex
        XCTAssertTrue(objects.allSatisfy { $0["color"]?.string == Self.colorB.uniflowRGBA.hex }, "nur rote Striche von B")
        let notes = try await notesBytes(b.api, s.fileB).annotations
        let stored = try await storedNotes(b, s.fileB)
        for needle in [foreignID, colorA, s.displayName, s.solutionID] {
            XCTAssertNil(notes.range(of: Data(needle.utf8)), "\(needle) in den Notizen von B")
            XCTAssertNil(stored.range(of: Data(needle.utf8)), "\(needle) in der Datenbank von B")
            for (path, data) in fileSnapshot(b.journal) where data.range(of: Data(needle.utf8)) != nil {
                XCTFail("\(needle) im Journal von B: \(path)")
            }
        }
        XCTAssertEqual(overlay.foreignLayerViews.count, 1, "fremde Ebene weiter angezeigt")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try save(snapshot(window), "B-seite1-nach-weiterschreiben.png", out: out, s)
        s.values[6] = ["datenbankGleich": after.stored == before.stored, "annotationsKanonischGleich": after.notes == before.notes,
                       "annotationsRohGleich": after.raw == before.raw,
                       "hinweisRoh": "Die Rohantwort von GET annotations kann bei gleichem Inhalt die Reihenfolge der JSON-Schluessel wechseln; verglichen werden deshalb die gespeicherten Bytes der Datenbank und die kanonische Form.",
                       "journalGleich": after.journal == before.journal,
                       "dokumentGleich": after.doc == before.doc, "journalDateien": after.journal.count,
                       "strichIDsDanach": ids, "fremdeIDInNotizen": ids.contains(foreignID)]
    }

    private func step7(_ b: E2EUser, _ s: E2EState, wrongPDF: URL, pdfBytes: Data, out: URL) async throws {
        let wrongBytes = try Data(contentsOf: wrongPDF)             // nur zur Laufzeit gelesen
        let wrongFP = cipher.sha256Hex(wrongBytes)
        XCTAssertNotEqual(wrongFP, s.fingerprint, "zweite PDF ist eine andere Datei")
        // das erste Dokument von B schliessen (sichert nichts Neues), danach zaehlt nur das Dokument der zweiten PDF
        if let first = s.storeB { await first.close() }
        s.windowB?.isHidden = true
        let id = try await importOwnPDF(b, from: wrongPDF, name: "E2E-Blatt-andere.pdf")
        let store = DocumentStore(file: try await libraryFile(b.api, id), api: b.api, root: b.support)
        s.storeWrong = store
        await store.load()
        XCTAssertNil(store.errorMessage)
        let fp = await store.originalFingerprint()
        XCTAssertEqual(fp, wrongFP)
        let (editor, window) = showEditor(store, for: b)
        s.windowWrong = window
        let overlay = try await waitForOverlay(editor)
        let received = b.inbox.appendingPathComponent("E2E-Blatt – Lösung.uniflowsolution")
        let before = try await settled(store, b, id)
        let receivedBefore = fileSnapshot(b.solutions.root)
        let entriesBefore = b.solutions.allEntries()

        let result = try await store.importSolution(received, library: b.solutions)
        guard case .otherPDF(let entry) = result else { throw E2EError("falsche PDF nicht erkannt: \(result)") }
        XCTAssertEqual(entry.fingerprint, s.fingerprint)
        XCTAssertNotEqual(entry.fingerprint, wrongFP)
        // Meldung wie DocumentView.importSolution
        let label = ForeignSolutionLayer.label(displayName: entry.displayName, createdAt: entry.createdAt)
        let message = "\(label): \(SolutionError.fingerprintMismatch.description) Sie ist gespeichert und erscheint, sobald du die passende PDF öffnest."
        XCTAssertTrue(message.contains("gehört zu einer anderen PDF-Datei"), message)
        let load = await store.solutionLayers(library: b.solutions)
        XCTAssertTrue(load.layers.isEmpty, "nicht angezeigt")
        XCTAssertTrue(load.problems.isEmpty, "keine Ebene, kein Problem bei dieser PDF")
        editor.foreignLayers = load.layers
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(overlay.foreignLayerViews.isEmpty, "keine fremde Ebene auf Seite 1")
        // auch mit dem Paket direkt: andere PDF laesst sich nicht oeffnen
        let package = try SolutionPackage.decode(s.packageData)
        XCTAssertThrowsError(try package.open(originalPDF: wrongBytes, cipher: cipher)) {
            XCTAssertEqual($0 as? SolutionError, .fingerprintMismatch)
        }
        XCTAssertThrowsError(try cipher.open(package.ciphertext, keyMaterial: wrongBytes, salt: package.header.salt,
                                             info: SolutionPackage.keyInfo(solutionID: package.header.solutionID),
                                             nonce: package.header.nonce, aad: package.authenticatedHeader),
                             "Schluessel aus der zweiten PDF oeffnet das Paket nicht")
        // nichts gespeichert: Notizen, Versionen und Journal des Dokuments unveraendert, nichts der zweiten PDF
        // zugeordnet, das verschluesselte Paket in der Ablage byte-gleich. (Die App legt eine Loesung zu einer anderen
        // PDF bewusst in der Ablage ab, "erscheint beim passenden Dokument"; B hat sie dort schon aus Punkt 5.)
        let after = try await settled(store, b, id)
        XCTAssertEqual(after.stored, before.stored, "gespeicherte Notizen der zweiten PDF (Datenbank) unveraendert")
        XCTAssertEqual(after.notes, before.notes, "GET annotations der zweiten PDF unveraendert")
        XCTAssertEqual(after.versions, before.versions)
        XCTAssertEqual(after.doc, before.doc)
        XCTAssertEqual(after.journal, before.journal, "Journal von B unveraendert")
        XCTAssertTrue(b.solutions.entries(fingerprint: wrongFP).isEmpty, "nichts der zweiten PDF zugeordnet")
        let entriesAfter = b.solutions.allEntries()
        XCTAssertEqual(entriesAfter.map(\.solutionID), entriesBefore.map(\.solutionID), "keine weitere Loesung abgelegt")
        XCTAssertEqual(entriesAfter.map(\.fingerprint), entriesBefore.map(\.fingerprint), "weiter nur der ersten PDF zugeordnet")
        XCTAssertEqual(entriesAfter.map(\.visible), entriesBefore.map(\.visible))
        let libraryAfter = fileSnapshot(b.solutions.root)
        let packageFile = "/received/" + SolutionLibrary.fileName(s.solutionID)
        XCTAssertNotNil(receivedBefore[packageFile])
        XCTAssertEqual(libraryAfter[packageFile], receivedBefore[packageFile], "verschluesseltes Paket byte-gleich")
        XCTAssertEqual(Set(libraryAfter.keys), Set(receivedBefore.keys), "keine neue Datei in der Ablage")
        let changedFiles = libraryAfter.keys.filter { libraryAfter[$0] != receivedBefore[$0] }.sorted()
        let receivedAtChanged = entriesAfter.map(\.receivedAt) != entriesBefore.map(\.receivedAt)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        try save(snapshot(window), "B-falsche-pdf-seite1.png", out: out, s)
        s.values[7] = ["ergebnis": "otherPDF", "meldung": message, "angezeigteEbenen": load.layers.count,
                       "datenbankGleich": after.stored == before.stored, "notizenGleich": after.notes == before.notes,
                       "journalGleich": after.journal == before.journal, "paketInAblageGleich": libraryAfter[packageFile] == receivedBefore[packageFile],
                       "geaenderteDateienInAblage": changedFiles, "empfangszeitNeuGesetzt": receivedAtChanged]
    }

    // MARK: Punkt ausfuehren und bewerten

    private func step(_ n: Int, _ title: String, _ s: E2EState, _ body: () async throws -> Void) async {
        e2eIssueLog.begin(n)
        do {
            try await body()
        } catch {
            XCTFail("Punkt \(n) abgebrochen: \(error)")
        }
        let issues = e2eIssueLog.issues(n)
        let skipped = s.values[n]?["uebersprungen"] != nil
        s.results.append(["punkt": n, "titel": title, "ergebnis": issues.isEmpty ? (skipped ? "uebersprungen" : "bestanden") : "fehlgeschlagen",
                          "fehler": issues, "werte": s.values[n] ?? [:]])
    }

    // MARK: Datenwege

    /// A: PDF wie eine Stud.IP-Datei ueber den Weg des Abgleichs (`StudIPSync.run`): Kurs und Dateiliste in die
    /// Datenbank (`StudIPLibrary.storeCourses`, `storeFiles`), dann derselbe Download-Ablauf wie in der App
    /// (`UniDownloads.load`: Zwischendatei, hier eine Kopie der echten PDF statt des Downloads, Pruefungen, Platz im
    /// Stud.IP-Ordner des Containers, Inhalts-Hash, `markDownloaded` mit Seitentexten) mit dem Pfad relativ zum Container.
    private func adoptAsStudIPFile(_ user: E2EUser, pdf: URL, size: Int) async throws -> String {
        let course = StudIPCourse(id: "e2ekurs", title: "E2E-Testkurs Lösung teilen", number: "E2E-1", semesterTitle: "WiSe 2026/27",
                                  semesterStart: "2026-10-01T00:00:00+02:00")
        let file = StudIPFile(id: "e2eblatt", courseID: course.id, name: "E2E-Blatt.pdf", size: size, mimeType: "application/pdf",
                              changed: "2026-10-20T10:00:00+02:00", folderPath: "Übungsblätter")
        let db = try await user.host.backend().context.database
        let files = try XCTUnwrap(user.host.files)
        let now = Self.clock.nowISO, base = StudIPSync.base
        try await db.transaction { try StudIPLibrary.storeCourses($0, [course], startedAt: now) }
        let wanted = try await db.transaction { try StudIPLibrary.storeFiles($0, [file], startedAt: now, base: base, localFiles: files) }
        XCTAssertEqual(wanted.map(\.id), [file.id], "neue Datei: der Abgleich wuerde sie laden")
        let downloads = UniDownloads(folder: user.studipRoot, files: files, container: user.layout, source: "Stud.IP")
        try downloads.begin()
        defer { downloads.end() }
        let rel = StudIPImport.relativePath(for: file)
        let stored = try await downloads.load(StudIPLibrary.fileRow(file, base: base), to: rel, db: db, clock: Self.clock) { part in
            try FileManager.default.copyItem(at: pdf, to: part)
        }
        XCTAssertEqual(stored, "StudIP/" + rel, "Pfad relativ zum Container, im Stud.IP-Ordner")
        let sha = try await db.scalar("SELECT content_sha256 FROM files WHERE id=?", [.text(file.id)])?.string
        XCTAssertEqual(sha, ContentHash.file(pdf), "Inhalts-Hash wie beim Download")
        return file.id
    }

    /// B: wie "PDF importieren" (Views.swift `importPDF`): Datei aus dem eigenen Container lesen, als PDF pruefen,
    /// `POST /api/notebooks` mit kind=pdf und Titel ohne Endung.
    private func importOwnPDF(_ user: E2EUser, from source: URL, name: String) async throws -> String {
        let docs = user.container.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let url = docs.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: source, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertTrue(data.starts(with: Array("%PDF".utf8)))
        let title = url.deletingPathExtension().lastPathComponent
        let created = try await user.api.upload("/api/notebooks", fields: ["kind": "pdf", "title": title], fileField: "upload",
                                                fileName: url.lastPathComponent, mimeType: "application/pdf", data: data)
        XCTAssertEqual(created["course_id"], "__user__")
        return try XCTUnwrap(created["id"]?.string)
    }

    private func libraryFile(_ api: APIClient, _ id: String) async throws -> LibFile {
        let lib = try await api.json("/api/library", as: LibraryResponse.self)
        return try XCTUnwrap(lib.files.first { $0.id == id }, "Datei \(id) in der Bibliothek")
    }

    private func pageObjects(_ api: APIClient, _ id: String, page: String) async throws -> [JSONValue] {
        let v = try await api.value("/api/files/\(id)/annotations")
        return v["data"]?["pages"]?[page]?["objects"]?.array ?? []
    }

    /// Eigene Notizen so, wie das lokale Backend sie ausliefert, und die Versionsliste. `annotations` und `versions`
    /// in kanonischer Form (sortierte Schluessel), `raw` wie geliefert.
    private func notesBytes(_ api: APIClient, _ id: String) async throws -> (annotations: Data, versions: Data, raw: Data) {
        let (notes, h1) = try await api.data("/api/files/\(id)/annotations")
        XCTAssertEqual(h1.statusCode, 200)
        let (versions, h2) = try await api.data("/api/files/\(id)/annotations/versions")
        XCTAssertEqual(h2.statusCode, 200)
        return (try JSONValue.parse(notes).serialized(sortedKeys: true), try JSONValue.parse(versions).serialized(sortedKeys: true), notes)
    }

    /// Gespeicherte Notizen in der Datenbank des Benutzers: aktuelle Zeile und alle Versionen, mit den Daten so, wie
    /// sie abgelegt sind.
    private func storedNotes(_ user: E2EUser, _ id: String) async throws -> Data {
        let db = try await user.host.backend().context.database
        let current = try await db.rows("SELECT file_id, data, updated_at, version FROM annotations WHERE file_id=?", [.text(id)])
        let versions = try await db.rows("SELECT version, created_at, data FROM annotation_versions WHERE file_id=? ORDER BY version", [.text(id)])
        return JSONValue.object(["annotations": .array(current.map(JSONValue.object)),
                                 "versions": .array(versions.map(JSONValue.object))]).serialized(sortedKeys: true)
    }

    /// Stand nach dem Abarbeiten aller ausstehenden Aufgaben: Backend-Antworten, Dokument im Store, Journal.
    private func settled(_ store: DocumentStore, _ user: E2EUser, _ fileID: String) async throws -> E2ENotes {
        await store.flush()
        try? await Task.sleep(nanoseconds: 400_000_000)
        await store.flush()
        let doc = (await store.pageStructureDocument()).root.serialized(sortedKeys: true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let n = try await notesBytes(user.api, fileID)
        return E2ENotes(notes: n.annotations, versions: n.versions, stored: try await storedNotes(user, fileID), raw: n.raw, doc: doc,
                        journal: fileSnapshot(user.journal))
    }

    /// Alle Dateien unter einem Ordner (relativer Pfad -> Bytes).
    private func fileSnapshot(_ root: URL) -> [String: Data] {
        let dir = root.resolvingSymlinksInPath()
        var out: [String: Data] = [:]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            out[String(url.resolvingSymlinksInPath().path.dropFirst(dir.path.count))] = try? Data(contentsOf: url)
        }
        return out
    }

    // MARK: Editor im Fenster

    /// Editor wie `PDFEditorView.makeUIViewController` (Tarif vor dem Anzeigen) als Inhalt eines eigenen Fensters.
    private func showEditor(_ store: DocumentStore, for user: E2EUser) -> (PDFEditorController, UIWindow) {
        let editor = PDFEditorController(store: store)
        editor.pencilOnly = true
        editor.ownNotesVisible = true
        editor.canEdit = user.entitlements.notes.canEdit
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: Self.windowFrame)
        window.frame = Self.windowFrame
        window.rootViewController = editor
        window.makeKeyAndVisible()
        windows.append(window)
        return (editor, window)
    }

    /// Overlay, das PDFKit fuer diese Anzeige-Seite in die PDFView eingesetzt hat (aktueller Seitenaufbau).
    private func installedOverlay(_ editor: PDFEditorController, page: Int) -> PageInkView? {
        func find(_ v: UIView) -> PageInkView? {
            if let o = v as? PageInkView { return o.pageIndex == page && o.generation == editor.shownLayoutVersion ? o : nil }
            for sub in v.subviews { if let f = find(sub) { return f } }
            return nil
        }
        return find(editor.pdfView)
    }

    private func waitForOverlay(_ editor: PDFEditorController, page: Int = 0, timeout: Double = 15) async throws -> PageInkView {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let o = installedOverlay(editor, page: page), o.loaded, o.window != nil, o.bounds.width > 0 { return o }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw E2EError("PDFKit hat kein geladenes Overlay fuer Seite \(page + 1) ins Fenster gesetzt")
    }

    private func firstScrollView(_ v: UIView) -> UIScrollView? {
        if let s = v as? UIScrollView, !(v is PKCanvasView) { return s }
        for sub in v.subviews { if let s = firstScrollView(sub) { return s } }
        return nil
    }

    // MARK: Stift

    /// Strich wie mit dem Apple Pencil: PencilKit meldet dem Editor (Delegate der Canvas) Beginn, Aenderung der
    /// Zeichnung und Ende. Der Strich ist ein PKStroke, der auf die echte Canvas im Fenster gesetzt wird; meldet
    /// PencilKit die Aenderung beim Setzen nicht selbst, ruft der Test `canvasViewDrawingDidChange` auf.
    /// Rueckgabe: PencilKit hat `canvasViewDrawingDidChange` selbst aufgerufen.
    @discardableResult
    private func pencilStroke(_ editor: PDFEditorController, on overlay: PageInkView, _ stroke: PKStroke) -> Bool {
        let canvas = overlay.canvas
        editor.canvasViewDidBeginUsingTool(canvas)
        var drawing = canvas.drawing
        drawing.strokes.append(stroke)
        canvas.drawing = drawing
        // waehrend der Stift aufliegt, merkt sich der Editor bei jeder gemeldeten Aenderung einen offenen Schritt
        let reported = overlay.undoPending
        if !reported { editor.canvasViewDrawingDidChange(canvas) }
        editor.canvasViewDidEndUsingTool(canvas)
        return reported
    }

    private func penStroke(_ points: [CGPoint], color: UIColor, width: CGFloat = 3) -> PKStroke {
        let pts = points.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.008, size: CGSize(width: width, height: width), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
    }

    /// Leicht gebogene Linie in Seitenpunkten, Angaben relativ zur Seitengroesse.
    private func curve(_ size: CGSize, from a: (CGFloat, CGFloat), to b: (CGFloat, CGFloat), bump: CGFloat, count: Int = 40) -> [CGPoint] {
        (0..<count).map { i in
            let t = CGFloat(i) / CGFloat(count - 1)
            return CGPoint(x: (a.0 + (b.0 - a.0) * t) * size.width,
                           y: (a.1 + (b.1 - a.1) * t) * size.height - bump * size.height * sin(.pi * t))
        }
    }

    // MARK: Geometrie

    private func pointBounds(_ points: [CGPoint]) -> CGRect {
        guard let f = points.first else { return .null }
        var minX = f.x, minY = f.y, maxX = f.x, maxY = f.y
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Mittellinie eines PencilKit-Strichs in Canvas-Punkten (= Seitenpunkte), abgetastet wie beim Speichern.
    private func centerline(_ s: PKStroke) -> CGRect {
        pointBounds(s.path.interpolatedPoints(by: .distance(1.5)).map { $0.location.applying(s.transform) })
    }

    /// Grenzen der Punkte eines Strichobjekts im Notizmodell (Seitenpunkte). Striche aus PencilKit stehen ohne
    /// Verschiebung, Drehung und Skalierung im Modell; das wird hier geprueft statt umgerechnet.
    private func objectBounds(_ o: JSONValue) throws -> CGRect {
        XCTAssertEqual(o["x"]?.double ?? 0, 0)
        XCTAssertEqual(o["y"]?.double ?? 0, 0)
        XCTAssertEqual(o["rotation"]?.double ?? 0, 0)
        XCTAssertEqual(o["scaleX"]?.double ?? 1, 1)
        XCTAssertEqual(o["scaleY"]?.double ?? 1, 1)
        let c = (o["points"]?.array ?? []).compactMap(\.double)
        guard c.count >= 4 else { throw E2EError("Strich ohne Punkte") }
        return pointBounds(stride(from: 0, to: c.count - 1, by: 2).map { CGPoint(x: c[$0], y: c[$0 + 1]) })
    }

    /// Angezeigte Mittellinie der Striche einer fremden Ebene in den Koordinaten von `target` (Seitenpunkte: die
    /// fremde Schicht des Overlays; Fensterpunkte: das Fenster). Gemessen an den PencilKit-Strichen der fremden
    /// Canvas (`ForeignLayerView.ink`), ueber alle Transformationen dazwischen (Drehungsabbildung, Zoom des Overlays).
    private func displayedBounds(_ view: ForeignLayerView, in target: CALayer) -> (rect: CGRect, layers: Int) {
        var rect = CGRect.null
        for s in view.ink.drawing.strokes { rect = rect.union(view.ink.layer.convert(centerline(s), to: target)) }
        return (rect, view.ink.drawing.strokes.count)
    }

    /// Rechteck in Punkten der angezeigten Seite (Ursprung oben links, ohne Zoom) ueber PDFKit ins Fenster: so liegt
    /// es auf der PDF-Seite selbst, unabhaengig vom Overlay (nur Seiten ohne Drehung)
    private func pdfWindowRect(_ r: CGRect, page: PDFPage, in pdfView: PDFView, window: UIWindow) -> CGRect {
        XCTAssertEqual(page.rotation, 0, "Pruefung gegen die PDF-Seite nur ohne /Rotate")
        let box = page.bounds(for: pdfView.displayBox)
        let inPage = CGRect(x: box.minX + r.minX, y: box.maxY - r.maxY, width: r.width, height: r.height)
        return pdfView.convert(pdfView.convert(inPage, from: page), to: window)
    }

    /// Fensterlage des zuletzt gezeichneten eigenen Strichs (Mittellinie) auf der Canvas.
    private func ownStrokeWindowRect(_ overlay: PageInkView, window: UIWindow) throws -> CGRect {
        let last = try XCTUnwrap(overlay.canvas.drawing.strokes.last, "eigener Strich auf der Canvas")
        return overlay.canvas.convert(centerline(last), to: window)
    }

    private func assertBounds(_ got: CGRect, _ want: [String: Any], _ tolerance: Double, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        for (k, v) in [("minX", got.minX), ("minY", got.minY), ("maxX", got.maxX), ("maxY", got.maxY)] {
            let expected = (want[k] as? NSNumber)?.doubleValue ?? .nan
            XCTAssertEqual(Double(v), expected, accuracy: tolerance, "\(what): \(k) \(Double(v)) statt \(expected)", file: file, line: line)
        }
    }

    // MARK: Pruefung auf PDF-Bytes

    /// Positionen der `length`-Byte-Folgen von `source` (jede `stride`-te Position), die irgendwo in `blob` vorkommen.
    private func windowsFound(_ source: Data, in blob: Data, length: Int = 64, stride step: Int = 1) -> [Int] {
        guard blob.count >= length, source.count >= length else { return [] }
        let b = [UInt8](blob), p = [UInt8](source)
        var set = Set<Data>()
        for i in 0...(b.count - length) { set.insert(Data(b[i..<(i + length)])) }
        var hits: [Int] = []
        for i in Swift.stride(from: 0, through: p.count - length, by: step) where set.contains(Data(p[i..<(i + length)])) {
            hits.append(i)
            if hits.count >= 10 { break }
        }
        return hits
    }

    // MARK: Bilder

    /// Bild des ganzen Editor-Fensters, wie es auf dem Bildschirm steht (drawHierarchy, nach dem naechsten Zeichnen).
    private func snapshot(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func save(_ image: UIImage, _ name: String, out: URL, _ s: E2EState) throws {
        let data = try XCTUnwrap(image.pngData(), "PNG \(name)")
        try data.write(to: out.appendingPathComponent(name), options: .atomic)
        if !s.images.contains(name) { s.images.append(name) }
    }

    nonisolated private static func isBlue(_ r: Int, _ g: Int, _ b: Int) -> Bool { b > 170 && r < 110 && g < 170 && b - r > 80 }
    nonisolated private static func isRed(_ r: Int, _ g: Int, _ b: Int) -> Bool { r > 170 && g < 110 && b < 110 }

    /// Bildpunkte in einem Rechteck (Fensterpunkte), die `match` erfuellen.
    private func countPixels(_ image: UIImage, in rect: CGRect, _ match: (Int, Int, Int) -> Bool) -> Int {
        guard let cg = image.cgImage, !rect.isNull else { return 0 }
        let scale = image.scale
        let px = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !px.isNull, px.width >= 1, px.height >= 1, let crop = cg.cropping(to: px) else { return 0 }
        let w = crop.width, h = crop.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }
        var n = 0
        for i in Swift.stride(from: 0, to: buffer.count, by: 4) where match(Int(buffer[i]), Int(buffer[i + 1]), Int(buffer[i + 2])) { n += 1 }
        return n
    }

    // MARK: Hilfen

    private func tempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-e2e-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Container mit den Kopien der echten PDF nach dem Test entfernen
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func waitUntil(_ timeout: Double = 10, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await condition()
    }

    private func round4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }

    private func rectJSON(_ r: CGRect) -> [String: Double] {
        guard !r.isNull else { return [:] }
        return ["minX": round4(Double(r.minX)), "minY": round4(Double(r.minY)), "maxX": round4(Double(r.maxX)), "maxY": round4(Double(r.maxY))]
    }

    /// Umkehrung von `rectJSON` (Werte aus A-strich.json)
    private func rect(_ d: [String: Any]) -> CGRect {
        func v(_ k: String) -> CGFloat { CGFloat((d[k] as? NSNumber)?.doubleValue ?? .nan) }
        return CGRect(x: v("minX"), y: v("minY"), width: v("maxX") - v("minX"), height: v("maxY") - v("minY"))
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], url.lastPathComponent)
    }
}
