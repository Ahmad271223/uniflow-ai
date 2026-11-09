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
}
