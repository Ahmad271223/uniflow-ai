import Foundation
import XCTest
@testable import UniFlowCore

/// Fund vom 16.11.2026: Wird ein Dokument geschlossen (`SyncEngine.shutdown`), waehrend eine Speicher-Runde unterwegs
/// ist, darf diese Runde danach NICHTS mehr ins Journal schreiben. Vorher arbeitete sie ihr Ergebnis noch ein
/// (Bestaetigung bzw. Zusammenfuehren nach einem Konflikt) und legte ihren alten Stand ueber Dateien, die ein neu
/// geoeffnetes Dokument inzwischen weitergeschrieben hatte.
/// Die Tests brauchen weder das Tempo (`UploadPacing`) noch die Seiten-Ablage: nur Engine, Journal und einen Dienst,
/// der eine Anfrage anhalten kann.
final class RundeNachSchliessenTests: XCTestCase {

    private func journalFiles(_ store: MemoryBlobStore) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for path in store.paths where path.hasPrefix("docs/") && !path.contains("/damaged/") { out[path] = try store.read(path) }
        return out
    }

    private func ids(_ e: SyncEngine, _ key: String) async -> [String] {
        ((await e.page(key))?["objects"]?.array ?? []).compactMap { $0["id"]?.string }
    }

    /// Alte Sitzung: Speichern unterwegs (angehalten). Inzwischen speichert ein anderes Geraet, das Dokument wird
    /// geschlossen, neu geoeffnet und auf zwei Seiten weitergeschrieben. Dann erst endet die alte Anfrage - mit einem
    /// Konflikt, den die alte Sitzung frueher zusammenfuehrte und ins Journal schrieb.
    func testLaufendeRundeMitKonfliktSchreibtNachDemSchliessenNichtsInsJournal() async throws {
        let server = MockServer(), store = MemoryBlobStore()
        let alt = makeEngine(server, store)
        _ = await alt.open(pdfPageCount: 2)
        await alt.updatePage("p1", page(["a1"]))
        await alt.updatePage("p2", page(["b1"]))
        await alt.syncNow()
        let seeded = await alt.status
        XCTAssertEqual(seeded, .saved)

        await server.holdNext()
        await alt.updatePage("p1", page(["a1", "alt"]))
        let running = Task { await alt.syncNow() }
        let held = await waitUntil { await server.isHoldingPut }
        XCTAssertTrue(held, "die Anfrage der alten Sitzung ist unterwegs")
        await server.externalEdit { $0.pages["p2"] = page(["b1", "fremd"]) }
        await alt.shutdown()                                       // Dokument geschlossen, Anfrage noch unterwegs

        let neu = makeEngine(server, store)
        _ = await neu.open(pdfPageCount: 2)
        let p1 = await ids(neu, "p1"), p2 = await ids(neu, "p2")
        XCTAssertEqual(p1, ["a1", "alt"], "der ungesendete Strich der alten Sitzung steht im Journal")
        XCTAssertEqual(p2, ["b1", "fremd"], "der fremde Strich ist eingearbeitet")
        await neu.updatePage("p1", page(["a1", "alt", "neu-1"]))
        await neu.updatePage("p2", page(["b1", "fremd", "neu-2"]))
        await neu.syncNow()
        let quiet = await waitUntil { await neu.status == .saved }
        XCTAssertTrue(quiet, "die neue Sitzung hat alles gespeichert und ist zur Ruhe gekommen")
        let before = try journalFiles(store)
        let serverBefore = await server.allObjectIDs().sorted()

        await server.releaseHeldPut()                              // jetzt endet die alte Anfrage (Konflikt)
        await running.value
        try await Task.sleep(nanoseconds: 80_000_000)
        let after = try journalFiles(store)
        XCTAssertEqual(after.keys.sorted(), before.keys.sorted(), "die geschlossene Sitzung legt keine Datei an und entfernt keine")
        for (path, data) in before { XCTAssertEqual(after[path], data, "\(path): von der geschlossenen Sitzung ueberschrieben") }
        let serverAfter = await server.allObjectIDs().sorted()
        XCTAssertEqual(serverAfter, serverBefore, "die geschlossene Sitzung speichert nach dem Konflikt nicht noch einmal")

        // und beim naechsten Oeffnen ist jeder Strich da
        await neu.shutdown()
        let dritte = makeEngine(server, store)
        _ = await dritte.open(pdfPageCount: 2)
        let end1 = await ids(dritte, "p1"), end2 = await ids(dritte, "p2")
        XCTAssertEqual(end1, ["a1", "alt", "neu-1"])
        XCTAssertEqual(end2, ["b1", "fremd", "neu-2"])
        XCTAssertEqual(serverAfter, ["a1", "alt", "b1", "fremd", "neu-1", "neu-2"])
        await dritte.shutdown()
    }

    /// Dieselbe Lage ohne fremde Aenderung: Die alte Anfrage wird gespeichert, ihre Bestaetigung kommt aber erst nach
    /// dem Schliessen. Auch sie wird nicht mehr ins Journal geschrieben (die Bestaetigungen und die Seitenliste der
    /// neuen Sitzung bleiben, wie sie sind); kein Strich fehlt.
    func testLaufendeRundeMitErfolgSchreibtNachDemSchliessenKeineBestaetigung() async throws {
        let server = MockServer(), store = MemoryBlobStore()
        let alt = makeEngine(server, store)
        _ = await alt.open(pdfPageCount: 2)
        await alt.updatePage("p1", page(["a1"]))
        await alt.syncNow()
        await server.holdNext()
        await alt.updatePage("p1", page(["a1", "alt"]))
        let running = Task { await alt.syncNow() }
        let held = await waitUntil { await server.isHoldingPut }
        XCTAssertTrue(held)
        await alt.shutdown()

        // neu geoeffnet, waehrend die alte Anfrage noch unterwegs ist: weiterschreiben (nur ins Journal, der Dienst
        // antwortet der neuen Sitzung gerade nicht)
        await server.setOnline(false)
        let neu = makeEngine(server, store)
        _ = await neu.open(pdfPageCount: 2)
        await neu.updatePage("p1", page(["a1", "alt", "neu-1"]))
        await neu.shutdown()
        try await Task.sleep(nanoseconds: 30_000_000)
        let before = try journalFiles(store)

        await server.releaseHeldPut()                              // die alte Anfrage wird gespeichert (laeuft weiter, auch offline)
        await running.value
        try await Task.sleep(nanoseconds: 80_000_000)
        let after = try journalFiles(store)
        for (path, data) in before { XCTAssertEqual(after[path], data, "\(path): von der geschlossenen Sitzung ueberschrieben") }
        XCTAssertEqual(after.keys.sorted(), before.keys.sorted())

        await server.setOnline(true)
        let dritte = makeEngine(server, store)
        _ = await dritte.open(pdfPageCount: 2)
        await dritte.syncNow()
        let saved = await waitUntil { await dritte.status == .saved }
        XCTAssertTrue(saved)
        let end = await ids(dritte, "p1"), onServer = await server.objectIDs(page: "p1")
        XCTAssertEqual(end, ["a1", "alt", "neu-1"])
        XCTAssertEqual(onServer, ["a1", "alt", "neu-1"])
        await dritte.shutdown()
    }

    /// Der eigentliche Verlust-Fall: Die alte Anfrage ist unterwegs, ein anderes Geraet speichert, das Dokument wird
    /// geschlossen, neu geoeffnet, ein Strich kommt dazu (steht im Journal, noch nicht beim Dienst - z. B. ohne Netz
    /// oder weil die App gleich danach beendet wird). Dann endet die alte Anfrage mit einem Konflikt. Frueher fuehrte
    /// die alte Sitzung zusammen und schrieb IHRE Seite (ohne den neuen Strich) ueber die Seitendatei: der Strich war
    /// weg. Jetzt bleibt er.
    func testStrichDerNeuenSitzungGehtNichtVerlorenWennDieAlteRundeSpaeterEndet() async throws {
        let server = MockServer(), store = MemoryBlobStore()
        let alt = makeEngine(server, store)
        _ = await alt.open(pdfPageCount: 2)
        await alt.updatePage("p1", page(["a1"]))
        await alt.syncNow()
        await server.holdNext()
        await alt.updatePage("p1", page(["a1", "alt"]))
        let running = Task { await alt.syncNow() }
        let held = await waitUntil { await server.isHoldingPut }
        XCTAssertTrue(held)
        await server.externalEdit { $0.pages["p2"] = page(["fremd"]) }   // die alte Anfrage bekommt dadurch einen Konflikt
        await alt.shutdown()

        await server.setOnline(false)                              // die neue Sitzung erreicht den Dienst nicht
        let neu = makeEngine(server, store)
        _ = await neu.open(pdfPageCount: 2)
        await neu.updatePage("p1", page(["a1", "alt", "neu-1"]))
        let inJournal = try XCTUnwrap(try LocalJournal(store: store, documentID: "doc1").load())
        XCTAssertEqual(inJournal.pages["p1"]?.page["objects"]?.array?.count, 3, "der neue Strich steht im Journal")
        await neu.shutdown()                                       // App beendet, bevor hochgeladen wurde

        await server.releaseHeldPut()                              // alte Anfrage endet: Konflikt
        await running.value
        try await Task.sleep(nanoseconds: 80_000_000)
        let afterOld = try XCTUnwrap(try LocalJournal(store: store, documentID: "doc1").load())
        XCTAssertEqual((afterOld.pages["p1"]?.page["objects"]?.array ?? []).compactMap { $0["id"]?.string }, ["a1", "alt", "neu-1"],
                       "die geschlossene Sitzung hat die Seite nicht mit ihrem alten Stand ueberschrieben")

        await server.setOnline(true)
        let dritte = makeEngine(server, store)
        _ = await dritte.open(pdfPageCount: 2)
        await dritte.syncNow()
        let saved = await waitUntil { await dritte.status == .saved }
        XCTAssertTrue(saved)
        let end = await ids(dritte, "p1"), onServer = await server.objectIDs(page: "p1"), other = await server.objectIDs(page: "p2")
        XCTAssertEqual(end, ["a1", "alt", "neu-1"], "kein Strich verloren")
        XCTAssertEqual(onServer, ["a1", "alt", "neu-1"])
        XCTAssertEqual(other, ["fremd"], "der fremde Strich bleibt")
        await dritte.shutdown()
    }

    /// Unveraendert: Ein ausdrueckliches Sichern NACH dem Schliessen laeuft ganz durch (so nutzt es ein vorhandener
    /// Test, und so bleibt nichts liegen, wenn eine Ansicht spaet noch sichert).
    func testAusdruecklichesSichernNachDemSchliessenLaeuftWeiter() async {
        let server = MockServer(), store = MemoryBlobStore()
        let e = makeEngine(server, store)
        _ = await e.open(pdfPageCount: 1)
        await server.setOnline(false)
        await e.updatePage("p1", page(["a1"]))
        await e.shutdown()
        await server.setOnline(true)
        await e.syncNow()
        let onServer = await server.objectIDs(page: "p1"), status = await e.status
        XCTAssertEqual(onServer, ["a1"])
        XCTAssertEqual(status, .saved)
    }
}
