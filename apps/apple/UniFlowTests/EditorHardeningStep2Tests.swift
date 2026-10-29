import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Editor, Schritt 2 (Haertungen, docs/PENCILKIT-ANALYSE-PLAN.md P0-3 bis P0-6) im echten Weg: `DocumentStore` mit
/// lokalem Backend (SQLite) im Temp-Ordner, Datei wie nach dem ersten Oeffnen aus Stud.IP angemeldet.
///
/// - P0-3 Obergrenze beim Sichern: ohne Schreibpause spaetestens nach 2 s ins Journal, ohne Upload-Runde.
/// - P0-4 Formatschutz: Notizen mit `version` > 2 nur ansehen, nie speichern.
/// - P0-5 Herkunftsstempel `origin` beim ersten Speichern.
/// - P0-6 Dasselbe Dokument in zwei Fenstern: das zweite nur ansehen bzw. Uebernahme, wenn das erste nicht zu sehen ist.
/// Jede Pruefung hat eine Gegenprobe. Zeitgrenzen sind nur Haenger-Grenzen; alle Daten sind erfunden.
@MainActor
final class EditorHardeningStep2Tests: XCTestCase {

    // MARK: Aufbau

    struct Fixture {
        let root: URL
        let host: LocalBackendHost
        let api: APIClient
        let file: LibFile
        let pdf: Data
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-schritt2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Datei im lokalen Backend (Kurs, Datei, Stand der PDF im Zwischenspeicher wie nach dem ersten Oeffnen)
    private func makeFixture(pages: Int = 3, root existing: URL? = nil, host existingHost: LocalBackendHost? = nil) async throws -> Fixture {
        let root = try existing ?? tempDir()
        let host = existingHost ?? LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true),
                                                    clock: .fixed(berlin: "2026-10-28T09:00:00")!)
        let backend = try await host.backend()
        let fileID = "schritt2-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT OR IGNORE INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-test"), .text("Testkurs"), .text("WiSe 2026/27"), .text("Testkurs"), .text("vorlesung"),
                           .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-test"), .text("Testblatt.pdf"), .integer(1_792_000_000), .text("2026-10-28T08:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdf = Skript.pdf(pages: pages, .schlicht)
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf.write(to: pdfURL)
        let meta = try await api.value("/api/files/\(fileID)")
        try DocumentStore.stamp(meta).write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Testblatt.pdf", title: "Testblatt", kind: "pdf", module_id: nil, subject: "Testkurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-10-28T08:00:00", has_notes: nil,
                           page_count: pages, studip_folder: nil)
        return Fixture(root: root, host: host, api: api, file: file, pdf: pdf)
    }

    private func openStore(_ fx: Fixture, timing: SaveTiming = .standard) async -> DocumentStore {
        let store = DocumentStore(file: fx.file, api: fx.api, root: fx.root)
        store.saveTiming = timing
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        return store
    }

    /// Stand im lokalen Backend: Version und Text, wie er gespeichert ist
    private func stored(_ fx: Fixture) async throws -> (version: Int, text: String?) {
        let backend = try await fx.host.backend()
        let row = try await backend.context.database.rows("SELECT version, data FROM annotations WHERE file_id=?", [.text(fx.file.id)]).first
        return (row?["version"]?.int ?? 0, row?["data"]?.string)
    }

    private func storedDocument(_ fx: Fixture) async throws -> AnnotationDocument? {
        guard let text = try await stored(fx).text else { return nil }
        return AnnotationDocument(root: try JSONValue.parse(Data(text.utf8)))
    }

    /// Journal so, wie ein Neustart es laese (Dateien auf der Platte)
    private func journal(_ fx: Fixture) throws -> JournalSnapshot? {
        let store = FileBlobStore(root: DataContainerLayout.Folder.journal.url(in: fx.root))
        return try LocalJournal(store: store, documentID: fx.file.id, namespace: fx.api.namespace).load()
    }

    /// Alle Dateien im Journal-Ordner mit Inhalt (bytegleich vorher/nachher)
    private func journalFiles(_ fx: Fixture) -> [String: Data] {
        let dir = DataContainerLayout.Folder.journal.url(in: fx.root).resolvingSymlinksInPath()
        var out: [String: Data] = [:]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            out[String(url.resolvingSymlinksInPath().path.dropFirst(dir.path.count))] = try? Data(contentsOf: url)
        }
        return out
    }

    private func engine(_ store: DocumentStore) throws -> SyncEngine {
        try XCTUnwrap(Mirror(reflecting: store).children.first { $0.label == "engine" }?.value as? SyncEngine)
    }

    /// Stift-Strich Nummer n auf Seite 1 (eigene Erstellzeit, nebeneinander)
    private func stroke(_ n: Int) -> PKStroke {
        let x = 40 + CGFloat(n % 20) * 25, y = 100 + CGFloat(n / 20) * 30
        return Handschrift.line(from: CGPoint(x: x, y: y), to: CGPoint(x: x + 18, y: y + 4),
                                created: Date(timeIntervalSinceReferenceDate: 797_000_000 + Double(n)))
    }

    private func strokes(_ doc: AnnotationDocument?, _ key: String = "p1") -> Int {
        (doc?.objects(page: key) ?? []).filter { $0["type"]?.string == "stroke" }.count
    }

    private func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    // MARK: P0-3 Obergrenze beim Sichern

    /// Dauerschreiben im Takt von 100 ms, die Pause-Verarbeitung ist ausgeschaltet (30 s), damit nur die Obergrenze
    /// (2 s) greifen kann: die Striche stehen im Journal, waehrend noch geschrieben wird, und keine Upload-Runde laeuft.
    /// Nach dem Schliessen ist alles gespeichert. Gegenprobe ohne Obergrenze: in 4 s Dauerschreiben nichts im Journal.
    func testWritingWithoutPauseReachesTheJournalWithinTheCap() async throws {
        let fx = try await makeFixture()
        let store = await openStore(fx, timing: SaveTiming(pause: 30, maxDelay: 2))
        try await Task.sleep(nanoseconds: 500_000_000)                // Netzueberwachung meldet sich beim Start
        let sync = try engine(store)
        let putsBefore = await sync.stats.puts
        var drawing = PKDrawing()
        let start = now()
        var journaledAt: Double?
        var written = 0
        while now() - start < 20 {                                       // Haenger-Grenze
            drawing.strokes.append(stroke(written))
            written += 1
            store.canvasChanged(pageKey: "p1", drawing: drawing)
            try await Task.sleep(nanoseconds: 100_000_000)
            if journaledAt == nil, strokes(try journal(fx).map { AnnotationDocument(rootMeta: $0.rootMeta, pages: $0.pages.mapValues(\.page)) }) > 0 {
                journaledAt = now() - start
            }
            if let j = journaledAt, now() - start > j + 0.5 { break }   // noch etwas weiterschreiben
        }
        let elapsed = now() - start
        let journaled = try XCTUnwrap(journaledAt, "Striche nicht im Journal, obwohl \(Int(elapsed)) s geschrieben wurde")
        print("[EditorMessung] Schritt 2 Obergrenze | erster Journal-Eintrag nach = \(String(format: "%.2f", journaled)) s, Striche \(written)")
        XCTAssertLessThan(journaled, elapsed, "im Journal, waehrend noch geschrieben wurde")
        XCTAssertGreaterThanOrEqual(store.forcedSaves, 1, "die Obergrenze hat gegriffen")
        let putsWriting = await sync.stats.puts - putsBefore
        XCTAssertEqual(putsWriting, 0, "keine Upload-Runde waehrend des Schreibens")
        await store.close()
        let checked1 = try await storedDocument(fx)
        XCTAssertEqual(strokes(checked1), written, "nach dem Schliessen alles gespeichert")

        // Gegenprobe: ohne Obergrenze steht waehrend 4 s Dauerschreiben nichts im Journal (so war es vor P0-3)
        let other = try await makeFixture(root: fx.root, host: fx.host)
        let plain = await openStore(other, timing: SaveTiming(pause: 30, maxDelay: nil))
        var d = PKDrawing()
        let t0 = now()
        var n = 0
        while now() - t0 < 4 {
            d.strokes.append(stroke(n))
            n += 1
            plain.canvasChanged(pageKey: "p1", drawing: d)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let early = try journal(other).map { AnnotationDocument(rootMeta: $0.rootMeta, pages: $0.pages.mapValues(\.page)) }
        XCTAssertEqual(strokes(early), 0, "Gegenprobe: ohne Obergrenze bleibt alles nur im Speicher")
        XCTAssertEqual(plain.forcedSaves, 0)
        await plain.close()
        let checked2 = try await storedDocument(other)
        XCTAssertEqual(strokes(checked2), n)
    }

    /// Mit den echten Zeiten (Pause 0,25 s, Obergrenze 2 s) und Strichen im Takt von 100 ms: waehrend des Schreibens
    /// erreicht der Stand das Journal; nach der Pause genau eine Runde. Unter Last koennen auch Pausen ueber 0,25 s
    /// entstehen, dann sichert schon die Pause-Verarbeitung; die Zahlen stehen im Protokoll.
    func testRealTimingAt100msCadenceKeepsTheJournalCurrent() async throws {
        let fx = try await makeFixture()
        let store = await openStore(fx)
        try await Task.sleep(nanoseconds: 500_000_000)
        let sync = try engine(store)
        let putsBefore = await sync.stats.puts, writesBefore = await sync.stats.pageWrites
        var drawing = PKDrawing()
        let start = now()
        var n = 0
        var firstJournal: Double?
        while now() - start < 6 {
            drawing.strokes.append(stroke(n))
            n += 1
            store.canvasChanged(pageKey: "p1", drawing: drawing)
            try await Task.sleep(nanoseconds: 100_000_000)
            if firstJournal == nil, strokes(try journal(fx).map { AnnotationDocument(rootMeta: $0.rootMeta, pages: $0.pages.mapValues(\.page)) }) > 0 {
                firstJournal = now() - start
            }
        }
        let putsWriting = await sync.stats.puts - putsBefore
        let writes = await sync.stats.pageWrites - writesBefore
        print("[EditorMessung] Schritt 2 Takt 100 ms | erster Journal-Eintrag nach = \(firstJournal.map { String(format: "%.2f", $0) } ?? "-") s, Journal-Schreibvorgaenge = \(writes), Obergrenze gegriffen = \(store.forcedSaves), PUTs waehrend des Schreibens = \(putsWriting)")
        XCTAssertNotNil(firstJournal, "waehrend 6 s Schreiben nichts im Journal")
        let saved = await waitUntilSaved(store, timeout: 30)
        XCTAssertTrue(saved, "nach der Pause gespeichert")
        let checked3 = try await storedDocument(fx)
        XCTAssertEqual(strokes(checked3), n)
        await store.close()
    }

    /// Wettlauf (Befund im Messtest Dauerschreiben 50 x 300, 29.10.2026): die Schreibpause faellt in eine laufende
    /// Verarbeitung durch die Obergrenze (volle Seite, die Umrechnung dauert). Vorher kehrte die Pause sofort zurueck und
    /// gab das Halten frei; danach setzte die Obergrenze es wieder, der letzte Strich blieb nur im Speicher, keine
    /// Upload-Runde, nie "Gespeichert". Obergrenze kuerzer als die Pause, damit sie zuerst greift.
    func testPauseDuringCapProcessingStillSavesAndUploads() async throws {
        let fx = try await makeFixture()
        let store = await openStore(fx, timing: SaveTiming(pause: 0.08, maxDelay: 0.03))
        try await Task.sleep(nanoseconds: 500_000_000)                // Netzueberwachung meldet sich beim Start
        let sync = try engine(store)
        let putsBefore = await sync.stats.puts
        var drawing = Handschrift.page(0, strokes: 3000)                 // Umrechnung dauert deutlich laenger als 0,1 s
        store.canvasChanged(pageKey: "p1", drawing: drawing)
        // die Obergrenze rechnet jetzt die volle Seite um; ein weiterer Strich, dessen Pause in diese Umrechnung faellt
        try await Task.sleep(nanoseconds: 100_000_000)
        drawing.strokes.append(Handschrift.extraStroke(0))
        store.canvasChanged(pageKey: "p1", drawing: drawing)
        let saved = await waitUntilSaved(store, timeout: 60)
        XCTAssertGreaterThanOrEqual(store.forcedSaves, 1, "die Obergrenze hat gegriffen")
        XCTAssertTrue(saved, "nach der Schreibpause gespeichert")
        let puts = await sync.stats.puts - putsBefore
        XCTAssertGreaterThanOrEqual(puts, 1, "nach der Schreibpause hochgeladen")
        let uploaded = try await storedDocument(fx)
        XCTAssertEqual(strokes(uploaded), 3001, "auch der letzte Strich ist hochgeladen, ohne zu schliessen")
        await store.close()
    }

    private func waitUntilSaved(_ store: DocumentStore, timeout: Double) async -> Bool {
        let end = now() + timeout
        while now() < end {
            if store.status == .saved, await store.info().unsentPages == 0 { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    // MARK: P0-4 Formatschutz

    private func putRaw(_ fx: Fixture, _ root: JSONValue, base: Int) async throws {
        let (data, http) = try await fx.api.data("/api/files/\(fx.file.id)/annotations?base_version=\(base)", method: "PUT",
                                                  body: root.serialized())
        XCTAssertEqual(http.statusCode, 200, String(decoding: data, as: UTF8.self))
    }

    /// Notizen in Version 3 (gespeichert von einer neueren App): nur ansehen mit Hinweis, kein Weg schreibt. Der Stand
    /// im Backend und das Journal bleiben bytegleich. Gegenprobe: dasselbe Dokument in Version 2 ist beschreibbar.
    func testNewerFormatOpensViewOnlyAndIsNeverSaved() async throws {
        let fx = try await makeFixture()
        var doc = AnnotationDocument.empty()
        doc.root["version"] = 3
        doc.root["zukunft"] = ["neu": true]
        doc.pages = ["p1": .object(["objects": .array([])])]
        try await putRaw(fx, doc.root, base: 0)
        let before = try await stored(fx)

        let store = await openStore(fx)
        XCTAssertEqual(store.newerFormatVersion, 3)
        XCTAssertFalse(store.isWritable)
        XCTAssertEqual(store.viewOnlyLabel, "Neueres Notizformat – nur ansehen")
        XCTAssertEqual(store.notice, DocumentStore.newerFormatNotice)
        XCTAssertTrue(store.notice?.contains("Studora") ?? false)
        let journalBefore = journalFiles(fx)
        var d = PKDrawing()
        d.strokes.append(stroke(0))
        store.canvasChanged(pageKey: "p1", drawing: d)
        await store.addText("Text", pageKey: "p1")
        await store.toggleBookmark(pageKey: "p1", title: "Seite 1")
        await store.rotatePage(key: "p1")
        let change = await store.applyPageStructure { doc in PageOrder.insertBlank(&doc, after: "p1", template: "blank") }
        XCTAssertNil(change)
        await store.close()
        let after = try await stored(fx)
        XCTAssertEqual(after.version, before.version, "nie gespeichert")
        XCTAssertEqual(after.text, before.text, "Stand bytegleich")
        XCTAssertEqual(journalFiles(fx), journalBefore, "Journal unveraendert")

        // Gegenprobe: Version 2 ist beschreibbar
        let other = try await makeFixture(root: fx.root, host: fx.host)
        let normal = await openStore(other)
        XCTAssertNil(normal.newerFormatVersion)
        XCTAssertTrue(normal.isWritable)
        normal.canvasChanged(pageKey: "p1", drawing: d)
        await normal.close()
        let checked4 = try await storedDocument(other)
        XCTAssertEqual(strokes(checked4), 1)
    }

    /// Waehrend das Dokument offen ist, speichert ein anderes Geraet Version 3: der naechste Upload bekommt 409, der
    /// Store schaltet auf nur ansehen, ueber den neueren Stand wird nie gespeichert; der schon geschriebene Strich bleibt
    /// im Journal.
    func testNewerFormatArrivingWhileOpenStopsSavingAndKeepsTheStroke() async throws {
        let fx = try await makeFixture()
        let store = await openStore(fx)
        XCTAssertTrue(store.isWritable)
        var newer = AnnotationDocument.empty()
        newer.root["version"] = 3
        newer.pages = ["p2": .object(["objects": .array([])])]
        try await putRaw(fx, newer.root, base: 0)                         // anderes Geraet, neuere App
        let afterOther = try await stored(fx)

        var d = PKDrawing()
        d.strokes.append(stroke(0))
        store.canvasChanged(pageKey: "p1", drawing: d)
        await store.flush()
        let end = now() + 20
        while store.newerFormatVersion == nil, now() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(store.newerFormatVersion, 3, "Store weiss es")
        XCTAssertFalse(store.isWritable)
        XCTAssertTrue(store.notice?.contains("neueren Version von Studora") ?? false, store.notice ?? "")
        let current = try await stored(fx)
        XCTAssertEqual(current.version, afterOther.version, "nicht ueber Version 3 gespeichert")
        XCTAssertEqual(current.text, afterOther.text)
        let j = try journal(fx)
        XCTAssertEqual(j?.pages["p1"]?.page["objects"]?.array?.count, 1, "Strich bleibt im Journal")
        d.strokes.append(stroke(1))
        store.canvasChanged(pageKey: "p1", drawing: d)                    // nur ansehen: nicht mehr angenommen
        await store.close()
        XCTAssertEqual(try journal(fx)?.pages["p1"]?.page["objects"]?.array?.count, 1)
    }

    // MARK: P0-5 Herkunftsstempel

    /// Erstes Speichern setzt `origin` (Inhalts-Hash der angezeigten PDF, Seitenzahl, Fassung 1); nur Oeffnen schreibt
    /// nichts (Gegenprobe). Nach dem erneuten Oeffnen ist das Dokument beschreibbar (die Pruefung beim Oeffnen passt),
    /// der Stempel bleibt beim naechsten Strich unveraendert.
    func testFirstSaveStampsTheOriginAndReopeningStaysWritable() async throws {
        let fx = try await makeFixture(pages: 4)
        let opened = await openStore(fx)
        try await Task.sleep(nanoseconds: 300_000_000)
        let untouched = try await stored(fx)
        XCTAssertNil(untouched.text, "Gegenprobe: Oeffnen allein speichert nichts")
        var d = PKDrawing()
        d.strokes.append(stroke(0))
        opened.canvasChanged(pageKey: "p1", drawing: d)
        await opened.close()
        let raw5 = try await storedDocument(fx)
        let doc = try XCTUnwrap(raw5)
        let sha = try XCTUnwrap(ContentHash.file(AppPaths.pdf(fx.file.id, namespace: fx.api.namespace, root: fx.root)))
        XCTAssertEqual(sha, SolutionSHA256.hex(fx.pdf), "Hash der Original-Bytes")
        XCTAssertEqual(doc.root["origin"], ["sha256": .string(sha), "pages": 4, "version": 1])
        XCTAssertEqual(strokes(doc), 1)

        let again = await openStore(fx)
        XCTAssertFalse(again.outdatedByNewVersion, "Stempel passt zur angezeigten PDF")
        XCTAssertTrue(again.isWritable)
        d.strokes.append(stroke(1))
        again.canvasChanged(pageKey: "p1", drawing: d)
        await again.close()
        let raw6 = try await storedDocument(fx)
        let second = try XCTUnwrap(raw6)
        XCTAssertEqual(second.root["origin"], doc.root["origin"], "Stempel unveraendert")
        XCTAssertEqual(strokes(second), 2)
    }

    /// Hat die Quelle seit dem Oeffnen eine neue Fassung (anderer Stand), wird kein Stempel gesetzt: die Notizen
    /// gehoerten sonst mit dem Hash der alten PDF zur neuen und das Dokument waere beim naechsten Oeffnen nur zum
    /// Ansehen. Der Strich wird trotzdem gespeichert. Ein vorhandener Stempel bleibt unveraendert.
    func testNoStampWhenTheSourceChangedAndExistingStampIsKept() async throws {
        let fx = try await makeFixture()
        let store = await openStore(fx)
        let backend = try await fx.host.backend()
        let id = fx.file.id
        try await backend.context.database.transaction { c in
            try c.execute("UPDATE files SET downloaded_at=? WHERE id=?", [.text("2026-10-28T10:00:00"), .text(id)])
        }
        var d = PKDrawing()
        d.strokes.append(stroke(0))
        store.canvasChanged(pageKey: "p1", drawing: d)
        await store.close()
        let raw7 = try await storedDocument(fx)
        let doc = try XCTUnwrap(raw7)
        XCTAssertNil(doc.root["origin"], "kein Stempel nach einer neuen Fassung der Quelle")
        XCTAssertEqual(strokes(doc), 1)

        // vorhandener Stempel (passender Hash, andere Fassungsnummer) bleibt
        let other = try await makeFixture(root: fx.root, host: fx.host)
        let sha = try XCTUnwrap(ContentHash.file(AppPaths.pdf(other.file.id, namespace: other.api.namespace, root: other.root)))
        var stamped = AnnotationDocument.empty()
        stamped.root["origin"] = ["sha256": .string(sha), "pages": 3, "version": 7]
        try await putRaw(other, stamped.root, base: 0)
        let kept = await openStore(other)
        XCTAssertTrue(kept.isWritable)
        kept.canvasChanged(pageKey: "p1", drawing: d)
        await kept.close()
        let checked8 = try await storedDocument(other)
        XCTAssertEqual(checked8?.root["origin"]?["version"], 7)
    }

    // MARK: P0-6 Zwei Fenster

    /// Zwei Fenster in einem Prozess: A ist offen und zu sehen, B oeffnet dasselbe Dokument nur zum Ansehen (Hinweis,
    /// Editor ohne Schreiben, A's Striche sichtbar). Was B versucht, erreicht weder Journal noch Backend; A schreibt
    /// weiter. Gegenprobe am Ende: ohne das Verzeichnis offener Dokumente ueberschreibt B die Seite von A im Journal.
    func testSecondWindowWhileTheFirstIsShownOnlyViews() async throws {
        let fx = try await makeFixture()
        let a = await openStore(fx)
        var da = PKDrawing()
        da.strokes.append(stroke(0))
        a.canvasChanged(pageKey: "p1", drawing: da)
        _ = await a.pageStructureDocument()                               // im Journal (Upload noch ausstehend)

        let b = await openStore(fx)
        XCTAssertTrue(b.openElsewhere)
        XCTAssertFalse(b.isWritable)
        XCTAssertEqual(b.viewOnlyLabel, "In einem anderen Fenster offen – nur ansehen")
        XCTAssertTrue(b.notice?.contains("anderen Fenster") ?? false, b.notice ?? "")
        XCTAssertTrue(OpenDocuments.shared.holder(a.openKey) === a)
        let checked9 = await b.pageStructureDocument()
        XCTAssertEqual(strokes(checked9), 1, "B zeigt A's Strich")

        // A fertig hochladen lassen, damit spaeter nichts mehr von A kommt und jede Aenderung von B waere
        await a.pause()

        // beide Fenster mit Editor
        let windows = [show(a, canEdit: a.isWritable), show(b, canEdit: b.isWritable)]
        defer { windows.forEach { $0.window.isHidden = true; $0.window.rootViewController = nil } }
        XCTAssertTrue(windows[0].editor.writable)
        XCTAssertFalse(windows[1].editor.writable, "B: Editor ohne Schreiben")
        let journalBefore = journalFiles(fx)
        let backendBefore = try await stored(fx)
        var db = PKDrawing()
        db.strokes.append(stroke(50))
        b.canvasChanged(pageKey: "p1", drawing: db)
        await b.addText("aus B", pageKey: "p1")
        await b.close()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(journalFiles(fx), journalBefore, "B schreibt nichts ins Journal")
        let backendAfterB = try await stored(fx)
        XCTAssertEqual(backendAfterB.version, backendBefore.version, "B laedt nichts hoch")

        da.strokes.append(stroke(1))
        a.canvasChanged(pageKey: "p1", drawing: da)
        await a.close()
        let checked10 = try await storedDocument(fx)
        XCTAssertEqual(strokes(checked10), 2, "A schreibt weiter")
        XCTAssertNil(OpenDocuments.shared.holder(a.openKey), "nach dem Schliessen frei")

        // Gegenprobe ohne Verzeichnis: zwei schreibende Stores auf einem Journal
        let other = try await makeFixture(root: fx.root, host: fx.host)
        let first = await openStore(other)
        OpenDocuments.shared.release(first.openKey, by: first)            // so, als gaebe es kein Verzeichnis
        let second = await openStore(other)
        XCTAssertTrue(second.isWritable)
        var d1 = PKDrawing()
        d1.strokes.append(stroke(0))
        first.canvasChanged(pageKey: "p1", drawing: d1)
        _ = await first.pageStructureDocument()
        var d2 = PKDrawing()
        d2.strokes.append(stroke(60))
        second.canvasChanged(pageKey: "p1", drawing: d2)
        _ = await second.pageStructureDocument()
        let page = try XCTUnwrap(try journal(other)?.pages["p1"]?.page)
        XCTAssertEqual(page["objects"]?.array?.count, 1, "Gegenprobe: das zweite Fenster hat die Seite des ersten ersetzt")
        await first.close()
        await second.close()
    }

    /// A ist nicht mehr zu sehen (Fenster im Hintergrund oder Dokument weggeschaltet) und hat noch einen
    /// ungesicherten Strich: B uebernimmt. A sichert ihn vorher ins Journal und schreibt danach nichts mehr; B zeigt
    /// ihn, schreibt weiter, und am Ende sind beide Striche gespeichert.
    func testHiddenWindowHandsOverAndItsPendingStrokeIsKept() async throws {
        let fx = try await makeFixture()
        let a = await openStore(fx, timing: SaveTiming(pause: 30, maxDelay: nil))    // Strich bleibt ausstehend
        var da = PKDrawing()
        da.strokes.append(stroke(0))
        a.canvasChanged(pageKey: "p1", drawing: da)
        a.setShown(false)

        let b = await openStore(fx)
        XCTAssertFalse(b.openElsewhere)
        XCTAssertTrue(b.isWritable, "B uebernimmt")
        XCTAssertTrue(a.handedOver)
        XCTAssertFalse(a.isWritable)
        XCTAssertTrue(a.notice?.contains("anderen Fenster") ?? false)
        XCTAssertTrue(OpenDocuments.shared.holder(b.openKey) === b)
        let checked11 = await b.pageStructureDocument()
        XCTAssertEqual(strokes(checked11), 1, "A's ausstehender Strich ist bei B")

        var db = PKDrawing(strokes: da.strokes)
        db.strokes.append(stroke(1))
        b.canvasChanged(pageKey: "p1", drawing: db)
        da.strokes.append(stroke(2))
        a.canvasChanged(pageKey: "p1", drawing: da)                       // A nimmt nichts mehr an
        await a.close()
        await b.close()
        let doc = try await storedDocument(fx)
        XCTAssertEqual(strokes(doc), 2)
        let ids = Set((doc?.objects(page: "p1") ?? []).compactMap { $0["id"]?.string })
        XCTAssertEqual(ids.count, 2)
    }

    /// Geschlossen gibt frei; ein anderer Container (andere Hochschule) ist unabhaengig.
    func testClosedWindowFreesTheDocumentAndContainersAreSeparate() async throws {
        let fx = try await makeFixture()
        let a = await openStore(fx)
        await a.close()
        let b = await openStore(fx)
        XCTAssertTrue(b.isWritable, "nach dem Schliessen frei")
        // gleiche Datei-ID in einem anderen Container
        let otherRoot = try tempDir()
        let elsewhere = DocumentStore(file: fx.file, api: fx.api, root: otherRoot)
        XCTAssertNotEqual(elsewhere.openKey, b.openKey)
        XCTAssertFalse(OpenDocuments.shared.holder(elsewhere.openKey) === b)
        await b.close()
    }

    // MARK: Editor im Fenster

    struct Shown {
        let editor: PDFEditorController
        let window: UIWindow
    }

    private func show(_ store: DocumentStore, canEdit: Bool) -> Shown {
        let editor = PDFEditorController(store: store)
        editor.canEdit = canEdit
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = scene?.screen.bounds ?? CGRect(x: 0, y: 0, width: 834, height: 1210)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = editor
        window.makeKeyAndVisible()
        return Shown(editor: editor, window: window)
    }
}
