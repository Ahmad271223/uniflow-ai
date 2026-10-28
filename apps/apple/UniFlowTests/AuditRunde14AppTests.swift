import PDFKit
import UIKit
import XCTest
import UniFlowCore
@testable import UniFlow

// Externer Pruefbericht, Apple Nr. 501-570: Teile in der App (PDF-Anzeige, Bilder, Anmeldung, Loesungsvorschau,
// Einstellungen, lokales Backend). Kernteile in UniFlowCoreTests (`AuditRunde14Tests`); Ergebnis:
// docs/audit/RUNDE-14-501-570.md. Alle Daten sind erfunden.

/// Antwortet erst nach `release()` (fuer Ablaeufe, bei denen etwas waehrend des Ladens passiert)
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let go: Bool = lock.withLock {
                if isOpen { return true }
                waiting.append(c)
                return false
            }
            if go { c.resume() }
        }
    }

    func release() {
        let w: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        w.forEach { $0.resume() }
    }
}

/// Antworten je Pfad (ohne Abfrage) und Aufruf (0-basiert je Pfad); zaehlt die Anfragen
private final class CountingTransport: APITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String: Int] = [:]
    private let reply: @Sendable (String, Int) async -> (Int, Data, String)

    init(_ reply: @escaping @Sendable (String, Int) async -> (Int, Data, String)) { self.reply = reply }

    func count(_ path: String) -> Int { lock.withLock { calls[path] ?? 0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        let n: Int = lock.withLock {
            let n = calls[url.path] ?? 0
            calls[url.path] = n + 1
            return n
        }
        let (status, body, type) = await reply(url.path, n)
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!)
    }
}

@MainActor
final class AuditRunde14AppTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-runde14-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func until(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < end else { XCTFail("Zeitueberschreitung: \(what)"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func pdf(pages: Int, size: CGSize = CGSize(width: 595, height: 842)) -> PDFDocument {
        let raw = NSMutableData()
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        for _ in 0..<pages { UIGraphicsBeginPDFPage() }
        UIGraphicsEndPDFContext()
        return PDFDocument(data: raw as Data)!
    }

    private func image(_ color: UIColor, size: CGSize = CGSize(width: 4, height: 4)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in color.setFill(); ctx.fill(CGRect(origin: .zero, size: size)) }
    }

    private func imageViews(_ v: UIView) -> [UIImageView] { v.subviews.compactMap { $0 as? UIImageView } }

    // MARK: 501, 502 Bilder der Notizen

    /// 501 (Haertung): Die Anzeigesignatur kannte nur die Schluessel der Bilder. Heute ersetzt der Store ein geladenes
    /// Bild nie (`loadImage` laedt nur fehlende), getroffen war also kein Aufrufer; jetzt zaehlt die Identitaet des
    /// Bildes, ein ersetztes Bild wird gezeigt. Bilder, die die Seite nicht zeigt, bauen sie nicht neu auf.
    func testReplacedImageUnderSameKeyIsShownAndForeignImagesChangeNothing() {
        let src = "/api/files/f1/assets/bild.png"
        let objects: [JSONValue] = [["id": "i1", "type": "image", "src": .string(src), "x": 10, "y": 10, "width": 40, "height": 40]]
        let view = PageObjectsView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
        let red = image(.red), blue = image(.blue)
        view.show(template: nil, placeholder: nil, objects: objects, images: [src: red])
        XCTAssertTrue(imageViews(view).first?.image === red)
        view.show(template: nil, placeholder: nil, objects: objects, images: [src: blue])
        XCTAssertTrue(imageViews(view).first?.image === blue, "ersetztes Bild unter demselben Schluessel")
        let shownView = imageViews(view).first
        view.show(template: nil, placeholder: nil, objects: objects, images: [src: blue, "/api/files/f1/assets/andere.png": red])
        XCTAssertTrue(imageViews(view).first === shownView, "ein Bild einer anderen Seite baut nichts neu auf")
    }

    /// 502 (Fehler belegt): Wurde dasselbe Bild auf einer zweiten Seite angefragt, waehrend es noch lud, kehrte
    /// `loadImage` ohne Rueckruf zurueck; die zweite Seite zeigte bis zum naechsten Neuladen nur den grauen Platzhalter
    /// (Gegenprobe mit dem alten `loadImage`: zweiter Rueckruf 0-mal). Jetzt warten beide, geladen wird einmal.
    func testSecondPageAskingForTheSameImageWhileItLoadsGetsItToo() async throws {
        let gate = Gate()
        let png = image(.green).pngData()!
        let transport = CountingTransport { _, _ in
            await gate.wait()
            return (200, png, "image/png")
        }
        let file = LibFile(id: "runde14-bild", name: "Blatt.pdf", title: "Blatt", kind: "pdf", module_id: nil, subject: nil, doc_type: nil,
                           ai_title: nil, sub_label: nil, downloaded_at: "2026-10-25", has_notes: nil, page_count: 2, studip_folder: nil)
        let store = DocumentStore(file: file, api: APIClient(base: URL(string: "https://server.test/")!, transport: transport),
                                  root: try tempDir(), lease: nil)
        let src = "/api/files/runde14-bild/assets/bild.png"
        var first = 0, second = 0
        store.loadImage(src) { first += 1 }
        try await until("Anfrage unterwegs") { transport.count("/api/files/runde14-bild/assets/bild.png") == 1 }
        store.loadImage(src) { second += 1 }                     // Seite 2 mit demselben Bild
        gate.release()
        try await until("Bild geladen") { store.images[src] != nil }
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1, "auch die zweite Seite erfaehrt, dass das Bild da ist")
        XCTAssertEqual(transport.count("/api/files/runde14-bild/assets/bild.png"), 1, "nur einmal geladen")
        store.loadImage(src) { XCTFail("schon da: kein Laden, kein Rueckruf") }
    }

    /// 502: Der Rueckruf zeichnet den zuletzt gezeigten Inhalt (vorher den Stand beim Anstossen des Ladens: eine
    /// inzwischen angezeigte Aenderung der Seite verschwand wieder, bis die Seite neu geladen wurde)
    func testLoadedImageIsShownWithTheLatestPageContent() {
        let src = "/api/files/f1/assets/bild.png"
        let old: [JSONValue] = [["id": "i1", "type": "image", "src": .string(src), "x": 10, "y": 10, "width": 40, "height": 40]]
        let new = old + [["id": "t1", "type": "text", "text": "neu dazugekommen", "x": 10, "y": 100]]
        let view = PageObjectsView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
        view.show(template: "lined", placeholder: nil, objects: old, images: [:])
        XCTAssertNil(imageViews(view).first?.image, "noch nicht geladen: Platzhalter")
        view.show(template: "lined", placeholder: nil, objects: new, images: [:])
        let green = image(.green)
        view.update(images: [src: green])
        XCTAssertTrue(imageViews(view).first?.image === green)
        let texts = view.subviews.flatMap(\.subviews).compactMap { ($0 as? UILabel)?.attributedText?.string }
        XCTAssertEqual(texts, ["neu dazugekommen"], "der neuere Inhalt bleibt")
    }

    // MARK: 503-509 Seitenliste und Anzeige

    /// 503-505, 507 (504/505 behoben): Eintraege ohne Schluessel, doppelte Schluessel und PDF-Seiten, die es nicht
    /// gibt (0, negativ, ueber der Seitenzahl, keine Zahl), fehlten still. PDFKit liefert dafuer nil, keine Ausnahme
    /// (503). Jetzt gezaehlt, im Editor gemeldet, gespeichert bleiben sie. Unbekannte Seitentypen erscheinen wie im
    /// Web-Editor als Leerseite mit Vorlage (507), werden nie geteilt.
    func testHiddenPageEntriesAreCountedAndNamed() throws {
        let doc = AnnotationDocument(root: try JSONValue.parse(#"""
            {"version": 2, "pages": {"p1": {"objects": []}},
             "pageOrder": [{"key": "p1", "type": "pdf", "index": 1},
                           {"type": "blank", "w": 595, "h": 842},
                           {"key": "p1", "type": "pdf", "index": 2},
                           {"key": "p0", "type": "pdf", "index": 0},
                           {"key": "pm", "type": "pdf", "index": -3},
                           {"key": "p9", "type": "pdf", "index": 9},
                           {"key": "px", "type": "pdf", "index": "2"},
                           {"key": "pg", "type": "pdf", "index": 1e300},
                           {"key": "p2", "type": "pdf", "index": 2},
                           {"key": "v1", "type": "video", "template": "grid", "w": 400, "h": 300}]}
            """#))
        let layout = DisplayLayout.build(original: pdf(pages: 2), document: doc)
        XCTAssertEqual(layout.entries.map(\.key), ["p1", "p2", "v1"])
        XCTAssertEqual(layout.hidden, 7)
        XCTAssertEqual(layout.pdf.pageCount, 3)
        XCTAssertEqual(layout.entries[2].kind, "video")
        XCTAssertEqual(layout.entries[2].template, "grid")
        XCTAssertEqual(layout.pdf.page(at: 2)?.bounds(for: .cropBox).size, CGSize(width: 400, height: 300))
        XCTAssertEqual(DocumentStore.pageNotice(hidden: layout.hidden),
                       "7 Seiten der Seitenliste lassen sich hier nicht anzeigen (PDF-Seite fehlt oder doppelt) – sie bleiben gespeichert.")
        XCTAssertEqual(DocumentStore.pageNotice(hidden: 1),
                       "1 Seite der Seitenliste lässt sich hier nicht anzeigen (PDF-Seite fehlt oder doppelt) – sie bleibt gespeichert.")
        XCTAssertNil(DocumentStore.pageNotice(hidden: 0))
        XCTAssertEqual(DisplayLayout.build(original: pdf(pages: 2), document: .empty()).hidden, 0)
        // die gespeicherte Seitenliste bleibt vollstaendig, unbekannte Typen gehen nicht ins Loesungspaket
        XCTAssertEqual(doc.pageOrder.count, 10)
        XCTAssertEqual(SolutionBuilder.candidates(doc).first { $0.key == "v1" }?.shareable, false)
    }

    /// 508: Drehungen ausserhalb der 90-Grad-Schritte (aus fremden oder beschaedigten Daten): Anzeige auf ein
    /// Vielfaches von 90 abgerundet wie `SolutionGeometry.normalized` (Loesungspaket, Seitengroesse), dieselbe Regel;
    /// Text oder sehr grosse Zahlen zaehlen als 0. Das iPad schreibt nur normierte Werte (`rotatePage`).
    func testUnusualRotationsUseOneRule() throws {
        let values: [(String, Int)] = [("45", 0), ("-90", 270), ("450", 90), ("90.5", 90), ("-135", 270), ("\"90\"", 0), ("1e300", 0), ("720", 0)]
        let order = values.enumerated().map { i, v in #"{"key": "b\#(i)", "type": "blank", "w": 100, "h": 200, "rotation": \#(v.0)}"# }
        let doc = AnnotationDocument(root: try JSONValue.parse(#"{"version": 2, "pages": {}, "pageOrder": [\#(order.joined(separator: ","))]}"#))
        let layout = DisplayLayout.build(original: PDFDocument(), document: doc)
        XCTAssertEqual(layout.entries.map(\.rotation), values.map(\.1))
        for (i, entry) in layout.entries.enumerated() {
            XCTAssertEqual(layout.pdf.page(at: i)?.rotation, entry.rotation)
            XCTAssertEqual(SolutionGeometry.normalized(doc.pageOrder[i]["rotation"]?.int ?? 0), entry.rotation, values[i].0)
        }
    }

    /// 509: Groesse fuer eine neue Leerseite nach mehrfachem Drehen und Umordnen: immer die Seite ohne ihre eigene
    /// Drehung (wie `baseW`/`baseH` im Web), auch bei /Rotate der PDF und einer CropBox
    func testBaseSizeAfterRepeatedRotationAndReordering() throws {
        let original = pdf(pages: 2, size: CGSize(width: 600, height: 800))
        original.page(at: 1)?.rotation = 90                        // /Rotate 90 in der PDF
        original.page(at: 1)?.setBounds(CGRect(x: 0, y: 0, width: 500, height: 700), for: .cropBox)
        var rotation = 0
        for turn in 1...7 {
            rotation = DisplayLayout.normalized(rotation + 90)     // wie DocumentStore.rotatePage
            // umgeordnet: Seite 2 vor Seite 1
            let doc = AnnotationDocument(root: .object([
                "version": 2, "pages": [:],
                "pageOrder": [["key": "p2", "type": "pdf", "index": 2, "rotation": .number(Double(rotation))],
                              ["key": "p1", "type": "pdf", "index": 1, "rotation": .number(Double(rotation))]],
            ]))
            let layout = DisplayLayout.build(original: original, document: doc)
            XCTAssertEqual(layout.baseSize(at: 0), CGSize(width: 700, height: 500), "Drehung \(turn)")
            XCTAssertEqual(layout.baseSize(at: 1), CGSize(width: 600, height: 800), "Drehung \(turn)")
        }
    }

    // MARK: 511-515 Anmeldung

    /// Schluesselbund im Arbeitsspeicher, dessen Schreiben scheitern und dessen Eintraege sich nicht loeschen lassen
    private final class FlakySecrets: AccountSecretStore {
        var values: [String: String] = [:]
        var failingWrites = false
        var stuck: Set<String> = []
        func get(_ key: String) -> String? { values[key] }
        func set(_ value: String, for key: String) { if !failingWrites { values[key] = value } }
        func delete(_ key: String) { if !stuck.contains(key) { values[key] = nil } }
    }

    /// Wie ein Absturz: nach `budget` Schreibzugriffen kommt keiner mehr an
    private final class CrashingSecrets: AccountSecretStore {
        var values: [String: String] = [:]
        var budget = Int.max
        func get(_ key: String) -> String? { values[key] }
        func set(_ value: String, for key: String) { guard budget > 0 else { return }; budget -= 1; values[key] = value }
        func delete(_ key: String) { guard budget > 0 else { return }; budget -= 1; values[key] = nil }
    }

    private struct Authorized: AppleCredentialChecking {
        func state(forUserID id: String) async -> AppleCredentialState { .authorized }
    }

    private func defaults() -> UserDefaults {
        let suite = "uniflow.tests.runde14.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    private func account(_ s: AccountSecretStore, _ d: UserDefaults) -> AccountStore {
        AccountStore(secrets: s, defaults: d, checker: Authorized(), observeRevocation: false, allowsDebugAccount: true)
    }

    /// 511 (Fehler belegt): Neuinstallation, der alte Eintrag laesst sich nicht loeschen. Vorher wurde der Merker
    /// trotzdem gesetzt, beim zweiten Start galt der Eintrag der geloeschten App als Anmeldung. Jetzt gilt er nie,
    /// bis er weg ist.
    func testReinstallLeftoverThatCannotBeDeletedNeverCountsAsSignIn() {
        let secrets = FlakySecrets(), d = defaults()
        secrets.values[AccountStore.Keys.user] = "001.alt"
        secrets.stuck = [AccountStore.Keys.user]
        XCTAssertNil(account(secrets, d).account)
        XCTAssertNil(account(secrets, d).account, "zweiter Start: weiterhin keine Anmeldung")
        XCTAssertEqual(account(secrets, d).stage, .welcome)
        secrets.stuck = []
        XCTAssertNil(account(secrets, d).account, "jetzt geloescht")
        XCTAssertNil(secrets.values[AccountStore.Keys.user])
        XCTAssertFalse(d.bool(forKey: AccountStore.Keys.cleanupPending))
        let s = account(secrets, d)
        s.signIn(userID: "001.neu", name: "Ada", email: nil)
        XCTAssertEqual(account(secrets, d).account?.userID, "001.neu")
    }

    /// 512 (Fehler belegt): Nahm der Schluesselbund die Anmeldung nicht an, war man nur bis zum naechsten Start
    /// angemeldet (ohne Hinweis). Jetzt gilt sie nicht, und die Begruessung sagt es.
    func testSignInThatCannotBeStoredIsRefusedVisibly() {
        let secrets = FlakySecrets(), d = defaults()
        let s = account(secrets, d)
        secrets.failingWrites = true
        s.signIn(userID: "001.abc", name: "Ada", email: "ada@example.com")
        XCTAssertNil(s.account)
        XCTAssertEqual(s.stage, .welcome)
        XCTAssertEqual(s.lastError, "Die Anmeldung ließ sich auf diesem iPad nicht speichern. Bitte versuche es erneut.")
        secrets.failingWrites = false
        s.signIn(userID: "001.abc", name: "Ada", email: "ada@example.com")
        XCTAssertNil(s.lastError)
        XCTAssertEqual(account(secrets, d).account, AccountStore.Account(userID: "001.abc", name: "Ada", email: "ada@example.com"))
    }

    /// 513 (Fehler belegt): Kennung, Name und E-Mail standen in drei Eintraegen; ein Abbruch nach dem ersten
    /// hinterliess eine Kennung ohne Namen, und Apple liefert den Namen nur bei der ersten Zustimmung (Gegenprobe mit
    /// dem alten Speichern: nach einem Schreibzugriff Konto ohne Namen). Jetzt ein Eintrag: nach dem Neustart entweder
    /// keine oder die vollstaendige Anmeldung.
    func testInterruptedSignInNeverLeavesAnAccountWithoutItsName() {
        for budget in 0...6 {
            let secrets = CrashingSecrets(), d = defaults()
            let s = account(secrets, d)
            secrets.budget = budget
            s.signIn(userID: "001.abc", name: "Ada Lovelace", email: "ada@example.com")
            let restarted = account(secrets, d).account
            if let restarted {
                XCTAssertEqual(restarted, AccountStore.Account(userID: "001.abc", name: "Ada Lovelace", email: "ada@example.com"), "nach \(budget) Zugriffen")
            }
        }
        // Eintraege von vor dem gemeinsamen Eintrag werden weiter gelesen
        let old = FlakySecrets(), d = defaults()
        _ = account(old, d)
        old.values = [AccountStore.Keys.user: "001.alt", AccountStore.Keys.name: "Grace", AccountStore.Keys.email: "g@example.com"]
        XCTAssertEqual(account(old, d).account, AccountStore.Account(userID: "001.alt", name: "Grace", email: "g@example.com"))
    }

    /// 514 (Fehler belegt): Abmelden, waehrend der Schluesselbund den Eintrag nicht loeschen konnte: nach einem
    /// Neustart war das Konto wieder angemeldet. Jetzt nicht, und der naechste Start entfernt den Rest.
    func testSignOutThatLeavesKeychainEntriesStaysSignedOutAfterRestart() {
        let secrets = FlakySecrets(), d = defaults()
        let s = account(secrets, d)
        s.signIn(userID: "001.abc", name: "Ada", email: nil)
        secrets.stuck = [AccountStore.Keys.account]
        XCTAssertFalse(s.signOut())
        XCTAssertNil(account(secrets, d).account, "nach dem Neustart abgemeldet")
        secrets.stuck = []
        XCTAssertNil(account(secrets, d).account)
        XCTAssertTrue(secrets.values.isEmpty, "Rest beim naechsten Start entfernt")
    }

    /// 515 (Fehler belegt): "Konto löschen" meldete Reste nur ueber einen Rueckruf je Schritt (ein zweiter
    /// ueberschrieb den ersten), ein Rest im Schluesselbund (Anmeldung, Server-PIN) gar nicht. Jetzt meldet jeder
    /// Schritt, was blieb, die Begruessung zeigt alles.
    func testAccountDeletionReportsEveryLeftover() async {
        let secrets = FlakySecrets(), d = defaults()
        let s = account(secrets, d)
        s.signIn(userID: "001.abc", name: "Ada", email: nil)
        s.markPlanShown()
        secrets.stuck = [AccountStore.Keys.account]
        await s.deleteAccount(also: [
            { "Nicht alles ließ sich löschen (Dateien und Notizen). Bitte versuche es erneut." },
            { nil },
            { "Die Server-PIN ließ sich nicht aus dem Schlüsselbund entfernen." },
        ])
        XCTAssertEqual(s.notice, .deleted)
        XCTAssertEqual(s.stage, .welcome)
        XCTAssertEqual(s.deletionProblem, [
            "Nicht alles ließ sich löschen (Dateien und Notizen). Bitte versuche es erneut.",
            "Die Server-PIN ließ sich nicht aus dem Schlüsselbund entfernen.",
            AccountStore.keychainLeft,
        ].joined(separator: "\n"))
        XCTAssertNil(account(secrets, d).account, "auch mit dem Rest nicht mehr angemeldet")
        // ohne Reste: kein Hinweis
        secrets.stuck = []
        let t = account(secrets, d)
        t.signIn(userID: "001.abc", name: nil, email: nil)
        await t.deleteAccount(also: [{ nil }])
        XCTAssertNil(t.deletionProblem)
    }

    // MARK: 516-520 Loesungsebenen und Anzeige

    /// 516: Die Pixelpruefung kann nicht ueberlaufen: Seiten ueber 8192 Pixel scheitern vorher
    func testImagePixelLimitCannotOverflow() {
        XCTAssertFalse(ForeignSolutionLayer.fitsLimits(width: Int.max, height: Int.max))
        XCTAssertFalse(ForeignSolutionLayer.fitsLimits(width: Int.max / 2 + 1, height: 2))
        XCTAssertFalse(ForeignSolutionLayer.fitsLimits(width: 8_192, height: 8_192), "67 MP ueber der Grenze")
        XCTAssertTrue(ForeignSolutionLayer.fitsLimits(width: 4_096, height: 4_096))
        XCTAssertTrue(ForeignSolutionLayer.fitsLimits(width: 8_192, height: 2_048))
    }

    private func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    /// 517 (Messung): Viele Bilder an der Grenze je Bild (8192 x 2048, einfarbig, je rund 0,2 MB) auf einer Seite:
    /// `UIImage(data:)` dekodiert erst beim Zeichnen und nur in der Zielgroesse; Vorschau und eigene Schicht belegen
    /// zusammen wenig zusaetzlichen Speicher (gemessen mit 120 Bildern: +14 MB, Vorschau 8,6 s abseits des Hauptthreads)
    func testManyLargeImagesStayWithinMemory() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8_192, height: 2_048), format: format).image { ctx in
            UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 8_192, height: 2_048))
        }.pngData()!
        var images: [String: SolutionImage] = [:]
        var objects: [JSONValue] = []
        for i in 0..<40 {
            let src = "/api/files/x/assets/b\(i).png"
            images[src] = SolutionImage(mime: "image/png", data: png)
            objects.append(["id": .string("i\(i)"), "type": "image", "src": .string(src), "x": .number(Double(i * 10)), "y": 10, "width": 400, "height": 100])
        }
        let before = footprint()
        let ui = try ForeignSolutionLayer.uiImages(images)
        let page = SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 595, height: 842, rotation: 0, objects: objects)
        _ = SolutionPreview.image(page, images: ui, width: 120)
        let view = ForeignLayerView(solutionID: "x", page: page, images: ui, targetRotation: 0, label: "x")
        _ = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 421)).image { ctx in
            ctx.cgContext.scaleBy(x: 0.5, y: 0.5)
            view.layer.render(in: ctx.cgContext)
        }
        let grown = (footprint() - before) >> 20
        print("Messung 517: +\(grown) MB fuer 40 Bilder 8192 x 2048")
        XCTAssertLessThan(grown, 400, "40 x 67 MB voll dekodiert waeren 2,6 GB")
    }

    /// 518 (Haertung): Vorschaubreite und Faktor begrenzt; 0, negativ, NaN, unendlich und 1e9 ergeben ein kleines,
    /// gueltiges Bild (die App uebergibt eine feste Breite), ebenso eine sehr schmale, hohe Seite
    func testPreviewWidthIsBounded() {
        let page = SolutionPage(key: "b1", kind: .blank, pdfIndex: nil, width: 595, height: 842, rotation: 0, template: "lined", objects: [])
        for w in [CGFloat(0), -5, .nan, .infinity, -.infinity, 1e9, 120] {
            let img = SolutionPreview.image(page, images: [:], width: w, scale: .infinity)
            XCTAssertTrue((1...2_048).contains(img.size.width), "\(w): \(img.size)")
            XCTAssertTrue(img.size.height.isFinite && img.size.height >= 1, "\(w): \(img.size)")
            XCTAssertLessThanOrEqual(img.scale, 3)
        }
        XCTAssertEqual(SolutionPreview.image(page, images: [:], width: 120).size.width, 120, "uebliche Breite unveraendert")
        let tall = SolutionPage(key: "b2", kind: .blank, pdfIndex: nil, width: 1, height: 14_400, rotation: 0, objects: [])
        XCTAssertLessThanOrEqual(SolutionPreview.image(tall, images: [:], width: 2_048, scale: 1).size.height, 8_192)
    }

    /// 519 (Messung): Ein Textobjekt mit einer Million Zeichen: Groesse und Anzeige bleiben unter einer Sekunde
    /// (gemessen 0,15 s), die Hoehe ist auf `maxCoordinate` begrenzt
    func testVeryLongTextStaysFast() {
        let text = String(repeating: "Lorem ipsum dolor sit amet ", count: 1_000_000 / 27)
        let o: JSONValue = ["id": "t", "type": "text", "text": .string(text), "x": 10, "y": 10, "width": 220, "fontSize": 14]
        let start = Date()
        let size = ObjectGeometry.textSize(o, ObjectGeometry.attributedText(o))
        let view = PageObjectsView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
        view.show(template: nil, placeholder: nil, objects: [o], images: [:])
        _ = UIGraphicsImageRenderer(size: CGSize(width: 595, height: 842)).image { ctx in view.layer.render(in: ctx.cgContext) }
        let seconds = Date().timeIntervalSince(start)
        print("Messung 519: \(seconds) s")
        XCTAssertLessThanOrEqual(size.height, CGFloat(ObjectGeometry.maxCoordinate) + 2 * ObjectGeometry.textPadding)
        XCTAssertLessThan(seconds, 5)
    }

    /// 520 (Messung): Signatur einer Seite mit 3000 Formen: unveraendertes `show` ohne Neuaufbau (gemessen 27 ms je
    /// Aufruf im Simulator), Neuaufbau 48 ms
    func testSignatureOfLargePagesIsCheap() {
        let objects: [JSONValue] = (0..<3_000).map { i in
            ["id": .string("f\(i)"), "type": "shape", "shape": "rect", "x": .number(Double(i % 500)), "y": .number(Double(i % 800)),
             "width": 20, "height": 10, "stroke": "#d64545", "strokeWidth": 2]
        }
        let view = PageObjectsView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
        view.show(template: "lined", placeholder: nil, objects: objects, images: [:])
        let layers = view.layer.sublayers?.count ?? 0
        let first = view.layer.sublayers?.last
        let start = Date()
        for _ in 0..<5 { view.show(template: "lined", placeholder: nil, objects: objects, images: [:]) }
        let each = Date().timeIntervalSince(start) / 5
        print("Messung 520: \(each) s je unveraendertem show")
        XCTAssertTrue(view.layer.sublayers?.last === first, "kein Neuaufbau")
        XCTAssertEqual(view.layer.sublayers?.count, layers)
        XCTAssertLessThan(each, 0.5)
    }

    // MARK: 560 Start der Datenbank

    /// 560: Laesst sich die Datenbank nicht oeffnen (hier: an Stelle des Ordners liegt eine Datei), antwortet jede
    /// Anfrage schnell mit 503 und Meldung; gleichzeitige Anfragen teilen sich einen Versuch, eine spaetere versucht
    /// es erneut und gelingt, sobald die Ursache weg ist. 200 Anfragen hintereinander dauern Millisekunden je Stueck.
    func testFailedDatabaseStartIsCheapAndRecovers() async throws {
        let root = try tempDir()
        let blocker = root.appendingPathComponent("db")
        try Data("keine Datenbank".utf8).write(to: blocker)
        let host = LocalBackendHost(directory: blocker.appendingPathComponent("inner", isDirectory: true),
                                    clock: .fixed(berlin: "2026-10-25T14:30:05")!)
        let start = Date()
        for _ in 0..<200 {
            let r = await host.handle(LocalRequest(method: "GET", path: "/api/settings"))
            XCTAssertEqual(r.status, 503)
        }
        let seconds = Date().timeIntervalSince(start)
        XCTAssertLessThan(seconds, 10)
        let parallel = await withTaskGroup(of: Int.self) { group -> [Int] in
            for _ in 0..<20 { group.addTask { await host.handle(LocalRequest(method: "GET", path: "/api/settings")).status } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(Set(parallel), [503])
        let message = await host.handle(LocalRequest(method: "GET", path: "/api/settings")).json?["detail"]?.string ?? ""
        XCTAssertTrue(message.hasPrefix("Lokale Datenbank nicht verfügbar: "), message)
        try FileManager.default.removeItem(at: blocker)
        let ok = await host.handle(LocalRequest(method: "GET", path: "/api/settings"))
        XCTAssertEqual(ok.status, 200, "naechster Versuch gelingt")
        print("Messung 560: 200 gescheiterte Starts in \(seconds) s")
    }

    // MARK: 561-566 Einstellungen laden

    private static let term = Data(#"{"name": "WiSe", "start": "2026-10-12", "end": "2027-01-30", "active": 1}"#.utf8)

    /// 564 (Fehler belegt): Ein aelterer Ladevorgang, der nach einem neueren fertig wird, ueberschrieb dessen Stand
    /// (Gegenprobe ohne die Pruefung der Ladenummer: "alt" statt "neu"). Jetzt gilt der zuletzt begonnene.
    func testOlderSettingsLoadNeverOverwritesANewerOne() async throws {
        let gate = Gate()
        let transport = CountingTransport { path, n in
            switch path {
            case "/api/settings":
                if n == 0 { await gate.wait(); return (200, Data(#"{"user_name": "alt"}"#.utf8), "application/json") }
                return (200, Data(#"{"user_name": "neu"}"#.utf8), "application/json")
            case "/api/terms": return (200, Self.term, "application/json")
            default: return (200, Data("[]".utf8), "application/json")
            }
        }
        let api = APIClient(base: APIClient.localBase, transport: transport)
        let loader = SettingsLoader()
        let older = Task { await loader.load(api: api, ownServer: false) }
        try await until("erste Anfrage unterwegs") { transport.count("/api/settings") == 1 }
        await loader.load(api: api, ownServer: false)
        XCTAssertEqual(loader.local?.s["user_name"], "neu")
        gate.release()
        await older.value
        XCTAssertEqual(loader.local?.s["user_name"], "neu", "der aeltere Ladevorgang ueberschreibt nichts")
        XCTAssertNil(loader.stale)
    }

    /// 561-563, 565 (Fehler belegt): Scheiterte `/api/modules` oder `/api/courses`, zeigte der Reiter "0 aktiv" und
    /// alle Kurse "ohne Modul"; scheiterte das Neuladen, sah der alte Stand aktuell aus. Jetzt: ohne Stand eine
    /// Meldung statt leerer Listen, mit Stand bleibt er und ist als nicht aktualisiert gekennzeichnet.
    func testFailedSettingsLoadIsReportedAndKeepsTheLastState() async throws {
        final class Failures: @unchecked Sendable { var paths: Set<String> = [] }
        let failures = Failures()
        failures.paths = ["/api/modules"]
        let transport = CountingTransport { path, _ in
            if failures.paths.contains(path) {
                return (500, Data(#"{"detail": "Fehler der lokalen Datenbank (Code 13). Bitte versuche es erneut."}"#.utf8), "application/json")
            }
            switch path {
            case "/api/settings": return (200, Data(#"{"user_name": "Testperson"}"#.utf8), "application/json")
            case "/api/terms": return (200, Self.term, "application/json")
            case "/api/modules": return (200, Data(#"[{"id": 1, "name": "Testmathematik", "active": 1}]"#.utf8), "application/json")
            default: return (200, Data(#"[{"id": "c1", "title": "Testkurs", "module_id": 1}]"#.utf8), "application/json")
            }
        }
        let api = APIClient(base: APIClient.localBase, transport: transport)
        let loader = SettingsLoader()
        await loader.load(api: api, ownServer: false)
        XCTAssertNil(loader.local, "keine leere Modulliste")
        XCTAssertEqual(loader.stale, "Fehler der lokalen Datenbank (Code 13). Bitte versuche es erneut.")

        failures.paths = []
        await loader.load(api: api, ownServer: false)
        XCTAssertEqual(loader.local?.mods.count, 1)
        XCTAssertEqual(loader.local?.courses.count, 1)
        XCTAssertNil(loader.stale)

        failures.paths = ["/api/courses"]
        await loader.load(api: api, ownServer: false)
        XCTAssertEqual(loader.local?.mods.count, 1, "letzter Stand bleibt")
        XCTAssertEqual(loader.local?.courses.count, 1)
        XCTAssertNotNil(loader.stale, "als nicht aktualisiert gekennzeichnet")
    }
}
