import Foundation
import XCTest
@testable import UniFlowCore

// "Neu" nur 24 Stunden (Auftrag des Inhabers 17.11.2026: "wenn etwas laenger als 24 Std in der App ist, automatisch
// nicht mehr neu"). Eine Regel fuer alle Stellen (`LocalLibrary.newFileSQL`): nie geoeffnet, vor hoechstens 24
// Stunden eingetragen (`first_seen`) und nach dem ersten Einlesen des Kurses dazugekommen (`courses.first_listed_at`,
// eigene Tests in `NeuNachErstemEinlesenTests`). Uebersicht, Modulkarte, Moduldetail, Kurse, Bibliothek, Dateizeilen im
// Modul und am Termin muessen dasselbe sagen; `seen_by_user` und der Lernstand `status` bleiben unveraendert.
final class Neu24StundenTests: XCTestCase {
    /// Dienstag, 17.11.2026 13:20:05 (Berlin)
    private let now = "2026-11-17T13:20:05"

    private func backend(at local: String? = nil) async throws -> LocalBackend {
        let files = LocalFiles(container: try tempContainer(self), dataDirectory: "", tools: CountingTools())
        return try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: UniFlowClock.fixed(berlin: local ?? now)!, files: files)
    }

    /// Ein Kurs "Testanalysis" (Vorlesung) mit den genannten Dateien: (Kennung, first_seen, seen_by_user). Die
    /// Dateiliste des Kurses wurde am 1.11. zum ersten Mal eingelesen: alles hier kam danach dazu.
    private func seed(_ b: LocalBackend, _ files: [(id: String, firstSeen: String?, seen: Int)]) async throws {
        let db = b.context.database
        try await db.execute("""
            INSERT INTO courses(id, title, subject, kind, active, semester, first_listed_at)
            VALUES ('k1','Testanalysis','Testanalysis','vorlesung',1,'WiSe 2026/27','2026-11-01T08:00:00')
            """)
        for f in files {
            try await db.execute("""
                INSERT INTO files(id, course_id, name, size, mime, chdate, first_seen, status, seen_by_user, kind)
                VALUES (?,'k1',?,10,'application/pdf',1794000000,?,'neu',?,'pdf')
                """, [.text(f.id), .text("Vorlesung \(f.id).pdf"), f.firstSeen.map(SQLiteValue.text) ?? .null, .integer(Int64(f.seen))])
        }
    }

    private func get(_ b: LocalBackend, _ path: String) async throws -> JSONValue {
        let r = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device" + path)!, headers: [:], body: nil))
        XCTAssertEqual(r.status, 200, path)
        return try JSONValue.parse(r.body)
    }

    /// 23 h alt, 25 h alt, 23 h alt aber geoeffnet, ohne first_seen
    private let four: [(id: String, firstSeen: String?, seen: Int)] = [
        ("jung", "2026-11-16T14:20:05", 0), ("alt", "2026-11-16T12:20:05", 0),
        ("offen", "2026-11-16T14:20:05", 1), ("ohne", nil, 0),
    ]

    /// Kennungen der Dateien mit `is_new` 1 in der Bibliothek
    private func libraryNew(_ b: LocalBackend) async throws -> [String] {
        newIDs(try await get(b, "/api/library")["files"]?.array ?? [])
    }

    /// Dateien eines Kurses in "Fruehere Semester" mit `is_new` 1
    private func courseNew(_ b: LocalBackend) async throws -> [String] {
        newIDs(try await get(b, "/api/older-semesters/courses/k1/files").array ?? [])
    }

    /// `new_total` der Uebersicht
    private func total(_ b: LocalBackend) async throws -> Int? {
        try await get(b, "/api/dashboard")["new_total"]?.int
    }

    private func newIDs(_ files: [JSONValue]) -> [String] {
        files.filter { $0["is_new"]?.int == 1 }.compactMap { $0["id"]?.string }.sorted()
    }

    // MARK: Regel

    func testGrenzeIstVierundzwanzigStundenMitDerUhrDesKerns() throws {
        XCTAssertEqual(LocalLibrary.newFileHours, 24)
        XCTAssertEqual(LocalLibrary.newSince(UniFlowClock.fixed(berlin: now)!), "2026-11-16T13:20:05")
        // wirkliche 24 Stunden ueber die Zeitumstellung (25.10.2026, 3 Uhr -> 2 Uhr): 14:30 Winterzeit - 24 h = 15:30 Sommerzeit
        XCTAssertEqual(LocalLibrary.newSince(UniFlowClock.fixed(berlin: "2026-10-25T14:30:05")!), "2026-10-24T15:30:05")
        XCTAssertEqual(LocalLibrary.newFileSQL(since: "2026-11-16T13:20:05"),
                       "(f.seen_by_user=0 AND f.first_seen IS NOT NULL AND f.first_seen>='2026-11-16T13:20:05' "
                       + "AND (f.id LIKE 'demo-%' OR f.first_seen>(SELECT k.first_listed_at FROM courses k WHERE k.id=f.course_id)))")
        XCTAssertEqual(LocalLibrary.newFileSQL(UniFlowClock.fixed(berlin: now)!), LocalLibrary.newFileSQL(since: "2026-11-16T13:20:05"))
    }

    func testNurNieGeoeffneteDateienDerLetzten24StundenSindNeu() async throws {
        let b = try await backend()
        try await seed(b, four)
        let lib = try await get(b, "/api/library")
        let files = lib["files"]?.array ?? []
        XCTAssertEqual(files.count, 4)
        XCTAssertEqual(newIDs(files), ["jung"], "23 h alt und nie geoeffnet: neu; 25 h alt, geoeffnet, ohne first_seen: nicht neu")
        XCTAssertTrue(files.allSatisfy { $0["is_new"]?.int != nil }, "jede Datei traegt is_new (1/0)")
    }

    func testGenauAnDerGrenze() async throws {
        let b = try await backend()
        try await seed(b, [("genau", "2026-11-16T13:20:05", 0), ("sekunde", "2026-11-16T13:20:04", 0), ("leer", "", 0)])
        let new = try await libraryNew(b)
        XCTAssertEqual(new, ["genau"],
                       "genau 24 Stunden: noch neu; eine Sekunde aelter oder leeres first_seen: nicht mehr")
    }

    // MARK: alle Stellen gleich

    func testUebersichtModulKursBibliothekUndZeilenSagenDasselbe() async throws {
        let b = try await backend()
        try await seed(b, four)
        // Uebersicht
        let dash = try await get(b, "/api/dashboard")
        XCTAssertEqual(dash["new_total"]?.int, 1)
        XCTAssertEqual(dash["new_files"]?.array?.compactMap { $0["id"]?.string }, ["jung"])
        // Modulkarte (Uebersicht und "Meine Module")
        let card = try XCTUnwrap(dash["modules"]?.array?.first)
        XCTAssertEqual(card["new_count"]?.int, 1)
        XCTAssertEqual(card["file_count"]?.int, 4)
        let mods = try await get(b, "/api/modules")
        XCTAssertEqual(mods.array?.first?["new_count"]?.int, 1)
        // Moduldetail: Zaehler und Dateizeilen (auch in den Wochen)
        let mid = try XCTUnwrap(card["id"]?.int)
        let detail = try await get(b, "/api/modules/\(mid)")
        XCTAssertEqual(detail["new_count"]?.int, 1)
        XCTAssertEqual(newIDs(detail["files"]?.array ?? []), ["jung"])
        let inWeeks = (detail["weeks"]?.array ?? []).flatMap { w in
            LocalModules.groupKeys.flatMap { w[$0]?.array ?? [] }
        }
        XCTAssertEqual(inWeeks.count, 4)
        XCTAssertEqual(newIDs(inWeeks), ["jung"])
        XCTAssertTrue(inWeeks.allSatisfy { $0["is_new"]?.int != nil })
        // Kurse
        let courses = try await get(b, "/api/courses")
        let course = try XCTUnwrap(courses.array?.first { $0["id"]?.string == "k1" })
        XCTAssertEqual(course["new_count"]?.int, 1)
        XCTAssertEqual(course["file_count"]?.int, 4)
        // Bibliothek
        let inLibrary = try await libraryNew(b)
        XCTAssertEqual(inLibrary, ["jung"])
        // fruehere Semester (Dateien eines Kurses)
        let inCourse = try await courseNew(b)
        XCTAssertEqual(inCourse, ["jung"])
    }

    func testUnterlagenAmTerminTragenIsNew() async throws {
        let b = try await backend()
        try await seed(b, four)
        let clock = UniFlowClock.fixed(berlin: now)!
        let mats = try await b.context.database.transaction { c -> [JSONValue] in
            try LocalModules.ensureModules(c, clock: clock)
            let mid = try XCTUnwrap(try c.scalar("SELECT module_id FROM courses WHERE id='k1'"))
            return try LocalModules.eventMaterials(c, event: ["module_id": mid.json ?? .null], day: BerlinClock.parseISODate("2026-11-17")!, clock: clock)
        }
        XCTAssertEqual(mats.count, 4)
        XCTAssertEqual(newIDs(mats), ["jung"])
        XCTAssertTrue(mats.allSatisfy { $0["is_new"]?.int != nil })
    }

    // MARK: verschwindet von selbst, nichts wird umgeschrieben

    func testNachVierundzwanzigStundenVerschwindetNeuOhneZutun() async throws {
        let container = try tempContainer(self)
        let path = container.appendingPathComponent("uniflow.sqlite").path
        let files = LocalFiles(container: container, dataDirectory: "", tools: CountingTools())
        let early = try await LocalBackend.open(path: path, clock: UniFlowClock.fixed(berlin: "2026-11-17T12:00:00")!, files: files)
        try await seed(early, [("a", "2026-11-16T12:30:00", 0)])
        let first = try await total(early)
        XCTAssertEqual(first, 1, "23,5 Stunden alt: neu")
        let before = try await tableRows(early.context.database, "SELECT id, status, seen_by_user, first_seen FROM files")
        // eine Stunde spaeter, dieselbe Datenbank: niemand hat etwas getan
        let late = try await LocalBackend.open(path: path, clock: UniFlowClock.fixed(berlin: "2026-11-17T13:00:00")!, files: files)
        let dash = try await get(late, "/api/dashboard")
        XCTAssertEqual(dash["new_total"]?.int, 0)
        XCTAssertEqual(dash["new_files"]?.array?.count, 0)
        XCTAssertEqual(dash["modules"]?.array?.first?["new_count"]?.int, 0)
        let lateNew = try await libraryNew(late)
        XCTAssertEqual(lateNew, [])
        // Lernstand und "gesehen" bleiben, wie sie sind: nichts wird als gelesen markiert
        let after = try await tableRows(late.context.database, "SELECT id, status, seen_by_user, first_seen FROM files")
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.array?.first?["status"]?.string, "neu")
        XCTAssertEqual(after.array?.first?["seen_by_user"]?.int, 0)
        let lib = try await get(late, "/api/library")
        XCTAssertEqual(lib["files"]?.array?.first?["status"]?.string, "neu", "der Lernstand wird weiter geliefert")
        XCTAssertEqual(lib["files"]?.array?.first?["seen_by_user"]?.int, 0)
    }

    func testOeffnenUndGesehenNehmenNeuSofortWeg() async throws {
        let b = try await backend()
        try await seed(b, [("a", "2026-11-17T10:00:00", 0), ("b", "2026-11-17T11:00:00", 0)])
        let start = try await total(b)
        XCTAssertEqual(start, 2)
        let r = await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device/api/files/a/opened")!,
                                            headers: ["Content-Type": "application/json"], body: Data("{}".utf8)))
        XCTAssertEqual(r.status, 200)
        let afterOpen = try await libraryNew(b)
        XCTAssertEqual(afterOpen, ["b"])
        let m = await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device/api/files/mark-seen")!, headers: [:], body: nil))
        XCTAssertEqual(m.status, 200)
        let afterSeen = try await total(b), libraryAfterSeen = try await libraryNew(b)
        XCTAssertEqual(afterSeen, 0)
        XCTAssertEqual(libraryAfterSeen, [])
    }

    func testDateienInaktiverKurseZaehlenNichtAberTragenIsNew() async throws {
        let b = try await backend()
        try await seed(b, [("a", "2026-11-17T10:00:00", 0)])
        try await b.context.database.execute("UPDATE courses SET active=0, active_custom=1 WHERE id='k1'")
        let counted = try await total(b), inCourse = try await courseNew(b)
        XCTAssertEqual(counted, 0)
        XCTAssertEqual(inCourse, ["a"])
    }
}
