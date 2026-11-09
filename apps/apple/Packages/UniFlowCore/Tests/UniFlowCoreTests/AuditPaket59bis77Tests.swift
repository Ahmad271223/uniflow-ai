import XCTest
@testable import UniFlowCore

/// Audit 09.11.2026, Pakete 59-77 (Speichern, Offline, Wiederherstellung), Bericht
/// docs/audit/AUDIT-2026-11-09-PAKET-59-61-70-71-76-77.md. Hier der Kern der Behebung P60-F1: die beim Absetzen
/// gesicherte Zeichnung (`LocalJournal` `ink/`) und `SyncEngine.isSavedLocally`.
final class AuditPaket59bis77Tests: XCTestCase {

    private let ns = DataSourceNamespace.server(host: "example.org", port: nil)

    func testInkDraftRoundTripReplaceAndRemove() throws {
        let store = MemoryBlobStore()
        let j = LocalJournal(store: store, documentID: "datei-1", namespace: ns)
        XCTAssertTrue(j.inkDrafts().drafts.isEmpty)
        try j.writeInkDraft("p1", Data([1, 2, 3]))
        try j.writeInkDraft("p1", Data([4, 5]))                        // ersetzt die vorige
        let long = String(repeating: "ä", count: 200)                     // Dateiname gekuerzt, Schluessel in der Datei
        try j.writeInkDraft(long, Data(repeating: 7, count: 100_000))
        let read = LocalJournal(store: store, documentID: "datei-1", namespace: ns).inkDrafts()
        XCTAssertEqual(read.drafts["p1"], Data([4, 5]))
        XCTAssertEqual(read.drafts[long]?.count, 100_000)
        XCTAssertEqual(read.damaged, [])
        try j.removeInkDraft("p1")
        XCTAssertEqual(Set(j.inkDrafts().drafts.keys), [long])
        // fremdes Dokument und fremde Datenquelle sehen nichts
        XCTAssertTrue(LocalJournal(store: store, documentID: "datei-2", namespace: ns).inkDrafts().drafts.isEmpty)
        XCTAssertTrue(LocalJournal(store: store, documentID: "datei-1", namespace: .local).inkDrafts().drafts.isEmpty)
    }

    /// Eine beschaedigte Datei wird gemeldet und bleibt liegen; die Seiten des Journals liest `load()` wie bisher.
    func testDamagedInkDraftIsReportedKeptAndDoesNotDisturbTheJournal() throws {
        let store = MemoryBlobStore()
        let j = LocalJournal(store: store, documentID: "datei-1", namespace: ns)
        try j.writePage("p1", JournalPage(page: ["objects": []], localRev: 1))
        try j.writeInkDraft("p2", Data([9]))
        let dir = LocalJournal.directory(documentID: "datei-1", namespace: ns)
        try store.write(Data("kaputt".utf8), to: dir + "/ink/p3.ink")
        let read = j.inkDrafts()
        XCTAssertEqual(Set(read.drafts.keys), ["p2"])
        XCTAssertEqual(read.damaged, ["ink/p3.ink"])
        XCTAssertNotNil(try store.read(dir + "/ink/p3.ink"), "nie verworfen")
        let snap = try XCTUnwrap(try j.load())
        XCTAssertEqual(Set(snap.pages.keys), ["p1"])
        XCTAssertEqual(snap.damaged, [])
    }

    /// Erst wenn die Seite wirklich auf der Platte steht, darf die Zeichnung aus `ink/` weg: scheitert das Schreiben
    /// (voller Speicher), meldet die Engine die Seite als nicht gesichert, bis die Wiederholung gelingt.
    func testIsSavedLocallyOnlyAfterTheJournalWriteSucceeded() async throws {
        let blobs = MemoryBlobStore()
        let engine = SyncEngine(documentID: "datei-1", transport: MockServer(),
                                journal: LocalJournal(store: blobs, documentID: "datei-1", namespace: ns))
        _ = await engine.open(pdfPageCount: 1)
        blobs.setFailAllWrites(true)
        await engine.updatePage("p1", ["objects": [["id": "a", "type": "stroke"]]])
        let failed = await engine.isSavedLocally("p1")
        XCTAssertFalse(failed)
        blobs.setFailAllWrites(false)
        await engine.updatePage("p1", ["objects": [["id": "a", "type": "stroke"], ["id": "b", "type": "stroke"]]])
        let saved = await engine.isSavedLocally("p1")
        XCTAssertTrue(saved)
    }

    // MARK: P73-F6 / P72-F4: das iPad meldet beim Abgleich, welche Felder es geaendert hat

    /// Nach dem ersten Senden (Basis = gesendeter Stand) und nach einer Zeile aus dem Dienst (Basis = deren Stand)
    /// traegt der naechste Eintrag `changed` mit genau den lokal geaenderten Feldern; `data` bleibt die ganze Zeile
    /// (fuer Wiederherstellen/Neuanlage im Dienst). Gleich wie `app/sync_client.py` (`tests/test_audit_paket_59_77.py`).
    func testPushMarksOnlyTheFieldsChangedSinceTheBase() async throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.withConnection { try Migrations.migrate($0) }
        try await db.transaction { c in
            try DeviceSyncSchema.ensure(c)
            let core = DeviceSyncCore(device: "ipad-1")
            try c.execute("INSERT INTO study_packages(date, title) VALUES ('2026-11-10', 'Blatt 3')")
            try c.execute("INSERT INTO study_tasks(package_id, type, title, est_minutes, status) VALUES (?, 'lesen', 'Kapitel 3', 30, 'geplant')",
                          [.integer(c.lastInsertRowID)])
            let (first, _) = try core.collect(c)
            XCTAssertTrue(first.allSatisfy { $0.body["changed"] == nil }, "neue Zeilen: ganze Zeile")
            var results: [JSONValue] = [], mapping: [JSONValue] = []
            for (n, it) in first.enumerated() where ["study_packages", "study_tasks"].contains(it.table) {
                let id = JSONValue.number(Double(100 + n))
                results.append(["entity": .string(it.table), "local_id": it.body["local_id"] ?? .null, "id": id, "status": "created", "version": 1])
                mapping.append(["entity": .string(it.table), "local_id": it.body["local_id"] ?? .null, "id": id])
            }
            try core.handleResults(c, first, [], ["results": .array(results), "mapping": .array(mapping), "conflicts": []])

            try c.execute("UPDATE study_tasks SET est_minutes=45")
            let task = try XCTUnwrap(try core.collect(c).0.first { $0.table == "study_tasks" })
            XCTAssertEqual(task.body["changed"], ["est_minutes"])
            XCTAssertEqual(task.body["data"]?["title"], "Kapitel 3", "data bleibt die ganze Zeile")
            try core.handleResults(c, [task], [], ["results": [["entity": "study_tasks", "id": task.body["id"] ?? .null, "status": "applied", "version": 2]],
                                                  "mapping": [], "conflicts": []])

            // Zeile aus dem Dienst (anderes Geraet hat abgehakt) wird Basis; danach nur die eigene Aenderung
            let remoteTask = try XCTUnwrap(task.body["id"])
            let pkg = try XCTUnwrap(task.body["data"]?["package_id"])
            _ = try core.applyRow(c, "study_tasks", ["id": remoteTask, "package_id": pkg, "type": "lesen", "title": "Kapitel 3",
                                                     "est_minutes": 45, "status": "erledigt", "sync_version": 3,
                                                     "sync_updated_at": "2026-11-09T10:00:00.000Z", "sync_device": "windows"])
            XCTAssertEqual(try c.rows("SELECT status FROM study_tasks").first?["status"]?.string, "erledigt")
            try c.execute("UPDATE study_tasks SET title='Kapitel 3 und 4'")
            let next = try XCTUnwrap(try core.collect(c).0.first { $0.table == "study_tasks" })
            XCTAssertEqual(next.body["changed"], ["title"])
        }
    }
}
