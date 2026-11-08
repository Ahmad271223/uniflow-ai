import XCTest
@testable import UniFlowCore

/// Audit 08.11.2026, Paket 41 (PDF-Editor, Datensicherheit): Szenarien, die ohne iPad im Kern pruefbar sind.
/// Bericht: docs/audit/AUDIT-2026-11-08-PAKET-41.md
final class AuditPaket41Tests: XCTestCase {

    private func ids(_ page: JSONValue?) -> Set<String> {
        Set(page?["objects"]?.array?.compactMap { $0["id"]?.string } ?? [])
    }

    // MARK: P41-02 Gleichzeitiges Bearbeiten derselben Seite auf zwei Geraeten, beide offline

    /// iPad und zweites Geraet haben dieselbe Seite (a, b) bestaetigt. Offline loescht das iPad a und schreibt c, das
    /// zweite Geraet loescht b und schreibt d. Nach dem Wiederverbinden (zuerst das zweite Geraet, dann das iPad, dann
    /// noch einmal das zweite) steht auf dem Server und auf beiden Geraeten genau c und d: keine fremde Loeschung kommt
    /// zurueck, kein neuer Strich fehlt.
    func testOfflineEditsOnBothDevicesMergeWithoutResurrectionOrLoss() async {
        let server = MockServer()
        let ipad = makeEngine(server, MemoryBlobStore())
        let other = makeEngine(server, MemoryBlobStore())
        _ = await ipad.open(pdfPageCount: 1)
        await ipad.updatePage("p1", page(["a", "b"]))
        await ipad.syncNow()
        _ = await other.open(pdfPageCount: 1)
        let start = await other.page("p1")
        XCTAssertEqual(ids(start), ["a", "b"])

        await server.setOnline(false)
        await ipad.updatePage("p1", page(["b", "c"]))
        await ipad.syncNow()
        await other.updatePage("p1", page(["a", "d"]))
        await other.syncNow()
        let offline = await ipad.status
        XCTAssertTrue(offline.isSafeLocally, "offline lokal gesichert")

        await server.setOnline(true)
        await other.syncNow()
        await ipad.syncNow()
        await other.refreshFromServer()

        let onServer = await server.objectIDs(page: "p1")
        XCTAssertEqual(Set(onServer), ["c", "d"], "Server: beide neuen Striche, keine geloeschten")
        for (name, engine) in [("iPad", ipad), ("zweites Geraet", other)] {
            let local = await engine.page("p1")
            XCTAssertEqual(ids(local), ["c", "d"], name)
            let unsent = await engine.unsentPageKeys
            XCTAssertEqual(unsent, [], "\(name): nichts mehr ungesendet")
        }
    }

    /// Dasselbe mit Neustart des iPads zwischen Offline-Bearbeitung und Wiederverbinden (Journal auf der Platte statt
    /// im Speicher der Engine): die Basis fuer die drei-Wege-Zusammenfuehrung ueberlebt den Neustart.
    func testOfflineEditSurvivesRestartAndStillMergesThreeWay() async {
        let server = MockServer()
        let disk = MemoryBlobStore()
        let first = makeEngine(server, disk)
        _ = await first.open(pdfPageCount: 1)
        await first.updatePage("p1", page(["a", "b"]))
        await first.syncNow()

        await server.setOnline(false)
        await first.updatePage("p1", page(["b", "c"]))      // a geloescht, c neu, nur im Journal
        await first.shutdown()
        await server.externalEdit { doc in                  // Browser: b geloescht, d neu
            doc.pages["p1"] = page(["a", "d"])
        }
        await server.setOnline(true)

        let restarted = makeEngine(server, disk)
        let opened = await restarted.open(pdfPageCount: 1)
        XCTAssertEqual(opened.restoredUnsentPages, 1)
        await restarted.syncNow()
        let onServer = await server.objectIDs(page: "p1")
        XCTAssertEqual(Set(onServer), ["c", "d"])
        let local = await restarted.page("p1")
        XCTAssertEqual(ids(local), ["c", "d"])
    }
}
