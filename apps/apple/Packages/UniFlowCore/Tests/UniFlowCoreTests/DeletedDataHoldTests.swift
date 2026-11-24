import Foundation
import XCTest
@testable import UniFlowCore

/// "Konto löschen" mit 30 Tagen Aufbewahrung auf dem Geraet (24.11.2026, `DeletedDataHold`). Nur Temp-Ordner,
/// erfundene Nutzer und Dateien.
final class DeletedDataHoldTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_795_000_000)
    private let user = "001234.erfunden-ada.0001"
    private let other = "009876.erfunden-bob.0002"

    private func tempBase() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-hold-\(UUID().uuidString)", isDirectory: true)
        let base = dir.appendingPathComponent("UniFlowContainers", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return base
    }

    private func clock(days: Double) -> UniFlowClock { .fixed(start.addingTimeInterval(days * 24 * 3600)) }

    /// Container mit Kennzeichnung und einer Notiz-Datei
    private func filled(_ base: URL, _ userID: String, _ uni: UniversityKey, note: String) throws -> DataContainerLayout {
        let layout = DataContainerLayout(base: base, key: DataContainerKey(userID: userID, university: uni))
        try layout.prepare(clock: clock(days: 0))
        try FileManager.default.createDirectory(at: layout.journal, withIntermediateDirectories: true)
        try Data(note.utf8).write(to: layout.journal.appendingPathComponent("notiz.txt"))
        return layout
    }

    private func note(_ layout: DataContainerLayout) -> String? {
        FileManager.default.contents(atPath: layout.journal.appendingPathComponent("notiz.txt").path).map { String(decoding: $0, as: UTF8.self) }
    }

    func testAreaLiesBesideTheContainersAndIsExcludedFromBackup() throws {
        let base = try tempBase()
        let area = DeletedDataHold.area(besides: base)
        XCTAssertEqual(area.lastPathComponent, "UniFlowDeleted")
        XCTAssertEqual(area.deletingLastPathComponent().standardizedFileURL, base.deletingLastPathComponent().standardizedFileURL)

        let luh = try filled(base, user, .luh, note: "ADA")
        try DataContainerLayout.setExcludedFromBackup(luh.root, false)      // wie ContainerManager.protect
        let hold = try XCTUnwrap(DeletedDataHold.store([luh], owner: luh.ownerScope, in: area, clock: clock(days: 0)))
        XCTAssertEqual(try area.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let moved = hold.containerFolder(hold.manifest.containers[0])
        XCTAssertEqual(try moved.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true,
                       "der Container war ausdruecklich im Backup, im Bereich nicht mehr")
    }

    /// Ablegen: der Container ist sofort weg (die App sieht ihn nicht mehr), seine Daten liegen 30 Tage im Bereich
    func testStoreMovesTheContainersAwayAndKeepsThemThirtyDays() throws {
        let base = try tempBase()
        let area = DeletedDataHold.area(besides: base)
        let luh = try filled(base, user, .luh, note: "ADA-luh")
        let hi = try filled(base, user, .hildesheim, note: "ADA-hi")
        let hsh = DataContainerLayout(base: base, key: DataContainerKey(userID: user, university: .hsh))   // nie angelegt

        let hold = try XCTUnwrap(DeletedDataHold.store([luh, hi, hsh], owner: luh.ownerScope, in: area,
                                                       settings: [luh.identifier: ["kurs": "Analysis"]], clock: clock(days: 0)))
        XCTAssertFalse(luh.exists())
        XCTAssertFalse(hi.exists())
        XCTAssertEqual(Set(hold.manifest.containers.map(\.university)), ["luh", "hildesheim"], "ohne Ordner kein Eintrag")
        XCTAssertEqual(hold.owner, luh.ownerScope)
        XCTAssertFalse(hold.folder.path.contains(user), "nie die Apple-ID im Dateisystem")
        XCTAssertEqual(hold.expiresAt?.timeIntervalSince(try XCTUnwrap(hold.deletedAt)), 30 * 24 * 3600)

        XCTAssertEqual(DeletedDataHold.all(in: area, owner: luh.ownerScope, clock: clock(days: 29.9)).count, 1)
        XCTAssertTrue(DeletedDataHold.all(in: area, owner: luh.ownerScope, clock: clock(days: 30)).isEmpty, "nach 30 Tagen nicht mehr angeboten")
        XCTAssertTrue(DeletedDataHold.all(in: area, owner: DataContainerKey.userScope(other), clock: clock(days: 1)).isEmpty,
                      "ein anderes Konto sieht den Eintrag nicht")
    }

    func testNothingToStoreGivesNoEntry() throws {
        let base = try tempBase()
        let layout = DataContainerLayout(base: base, key: DataContainerKey(userID: user, university: .luh))
        XCTAssertNil(try DeletedDataHold.store([layout], owner: layout.ownerScope, in: DeletedDataHold.area(besides: base)))
    }

    /// Nach 30 Tagen endgueltig weg; juengere Eintraege und die anderer Konten bleiben bis zu ihrer Frist
    func testPurgeRemovesOnlyExpiredEntries() throws {
        let base = try tempBase()
        let area = DeletedDataHold.area(besides: base)
        let old = try filled(base, user, .luh, note: "alt")
        let oldHold = try XCTUnwrap(DeletedDataHold.store([old], owner: old.ownerScope, in: area, clock: clock(days: 0)))
        let young = try filled(base, other, .luh, note: "jung")
        let youngHold = try XCTUnwrap(DeletedDataHold.store([young], owner: young.ownerScope, in: area, clock: clock(days: 10)))

        XCTAssertEqual(DeletedDataHold.purgeExpired(in: area, clock: clock(days: 29)), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldHold.folder.path))
        XCTAssertEqual(DeletedDataHold.purgeExpired(in: area, clock: clock(days: 30)), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldHold.folder.path), "endgueltig geloescht")
        XCTAssertTrue(FileManager.default.fileExists(atPath: youngHold.folder.path))
        XCTAssertEqual(DeletedDataHold.purgeExpired(in: area, clock: clock(days: 40)), 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: area.path).isEmpty)
    }

    /// Ein abgebrochenes Ablegen (Ordner ohne Kennzeichnung) bleibt nicht fuer immer liegen
    func testPurgeRemovesUnmarkedLeftoversAfterTheRetention() throws {
        let base = try tempBase()
        let area = DeletedDataHold.area(besides: base)
        let leftover = area.appendingPathComponent("rest", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        XCTAssertEqual(DeletedDataHold.purgeExpired(in: area, clock: .system), 0, "eben erst entstanden")
        XCTAssertEqual(DeletedDataHold.purgeExpired(in: area, clock: .fixed(Date().addingTimeInterval(31 * 24 * 3600))), 1)
    }

    func testDiscardDeletesTheEntryAtOnce() throws {
        let base = try tempBase()
        let area = DeletedDataHold.area(besides: base)
        let luh = try filled(base, user, .luh, note: "ADA")
        let hold = try XCTUnwrap(DeletedDataHold.store([luh], owner: luh.ownerScope, in: area, clock: clock(days: 0)))
        try hold.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: hold.folder.path))
        XCTAssertTrue(DeletedDataHold.all(in: area, owner: luh.ownerScope, clock: clock(days: 1)).isEmpty)
    }

    /// Zurueckholen: Notizen und Einstellungen sind wieder da, der Eintrag verschwindet
    func testRestoreBringsBackContainersAndSettings() throws {
        let base = try tempBase()
        let area = DeletedDataHold.area(besides: base)
        let luh = try filled(base, user, .luh, note: "ADA-luh")
        let hi = try filled(base, user, .hildesheim, note: "ADA-hi")
        let hold = try XCTUnwrap(DeletedDataHold.store([luh, hi], owner: luh.ownerScope, in: area,
                                                       settings: [luh.identifier: ["kurs": "Analysis"]], clock: clock(days: 0)))

        let back = try hold.restore(into: base, clock: clock(days: 5))
        XCTAssertEqual(Set(back.map(\.identifier)), [luh.identifier, hi.identifier])
        XCTAssertEqual(back.first { $0.identifier == luh.identifier }?.settings["kurs"] as? String, "Analysis")
        XCTAssertTrue(back.first { $0.identifier == hi.identifier }?.settings.isEmpty ?? false)
        XCTAssertEqual(note(luh), "ADA-luh")
        XCTAssertEqual(note(hi), "ADA-hi")
        XCTAssertNoThrow(try luh.verifyPresent(), "Kennzeichnung kam mit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: hold.folder.path))
        XCTAssertTrue(DeletedDataHold.all(in: area, owner: luh.ownerScope, clock: clock(days: 5)).isEmpty)
    }

    /// Hat die neue Anmeldung schon einen leeren Container angelegt, geht der beim Zurueckholen nicht verloren: er kommt
    /// seinerseits fuer 30 Tage in den Bereich
    func testRestoreKeepsAContainerCreatedSinceTheNewSignIn() throws {
        let base = try tempBase()
        let area = DeletedDataHold.area(besides: base)
        let luh = try filled(base, user, .luh, note: "ALT")
        let hold = try XCTUnwrap(DeletedDataHold.store([luh], owner: luh.ownerScope, in: area, clock: clock(days: 0)))
        _ = try filled(base, user, .luh, note: "NEU")

        _ = try hold.restore(into: base, clock: clock(days: 2))
        XCTAssertEqual(note(luh), "ALT")
        let swapped = DeletedDataHold.all(in: area, owner: luh.ownerScope, clock: clock(days: 2))
        XCTAssertEqual(swapped.count, 1)
        let c = try XCTUnwrap(swapped.first?.manifest.containers.first)
        let kept = swapped[0].containerFolder(c).appendingPathComponent("journal/notiz.txt")
        XCTAssertEqual(FileManager.default.contents(atPath: kept.path).map { String(decoding: $0, as: UTF8.self) }, "NEU")
    }
}
