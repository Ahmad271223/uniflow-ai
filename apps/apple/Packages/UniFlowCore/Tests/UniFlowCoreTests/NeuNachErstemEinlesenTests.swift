import Foundation
import XCTest
@testable import UniFlowCore

// "Neu" erst nach dem ersten Einlesen (Auftrag des Inhabers 17.11.2026, "Ja, so bauen"): Was beim allerersten Einlesen
// eines Kurses schon da war, gilt gar nicht als neu; neu ist nur, was spaeter dazukommt (und dann hoechstens 24
// Stunden, ungeoeffnet). Je Kurs merkt sich die Datenbank einmal, wann seine Dateiliste zum ersten Mal vollstaendig
// eingelesen wurde (`courses.first_listed_at`, `UniStore.markFirstListing` ueber `SyncPending.markListed`).
// Die Tests fahren Abgleiche wie die App: je Kurs `UniStore.upsertCourse`, `UniStore.storeFiles` und - nur bei
// vollstaendiger Liste - `SyncPending.markListed` in einer Transaktion (Stud.IP: StudIPSync, Learnweb: HildesheimSync).
final class NeuNachErstemEinlesenTests: XCTestCase {
    private typealias Listing = (id: String, title: String, files: [String], complete: Bool)

    private var path = ""
    private var files: LocalFiles!

    override func setUpWithError() throws {
        let container = try tempContainer(self)
        path = container.appendingPathComponent("uniflow.sqlite").path
        files = LocalFiles(container: container, dataDirectory: "", tools: CountingTools())
    }

    /// Dieselbe Datenbank zu einem anderen Zeitpunkt (eingefrorene Uhr)
    private func backend(at local: String) async throws -> LocalBackend {
        try await LocalBackend.open(path: path, clock: UniFlowClock.fixed(berlin: local)!, files: files)
    }

    private func course(_ id: String, _ title: String, _ files: [String], complete: Bool = true) -> Listing {
        (id, title, files, complete)
    }

    /// Ein Abgleich zum Zeitpunkt `now`: je Kurs die Liste schreiben; `complete: false` = mitten im Kurs abgebrochen
    /// (Zeilen stehen, die Liste gilt nicht als eingelesen)
    private func sync(at now: String, _ courses: [Listing]) async throws {
        let b = try await backend(at: now)
        for c in courses {
            try await b.context.database.transaction { conn in
                try UniStore.upsertCourse(conn, UniStore.CourseRow(id: c.id, title: c.title, number: nil, semester: "WiSe 2026/27"), now: now)
                let rows = c.files.map {
                    UniStore.FileRow(id: $0, name: "\($0).pdf", size: 10, mime: "application/pdf", chdate: 1_794_000_000,
                                     downloadURL: "https://studip.test/\($0)", folder: "")
                }
                _ = try UniStore.storeFiles(conn, courseID: c.id, rows, now: now, fileExists: { _ in false })
                if c.complete { try SyncPending.markListed(conn, courseID: c.id, now: now) }
            }
        }
        try await b.context.database.transaction {
            try UniStore.logSync($0, startedAt: now, finishedAt: now, ok: true, newFiles: 0, message: "Test")
        }
    }

    private func get(_ b: LocalBackend, _ path: String) async throws -> JSONValue {
        let r = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device" + path)!, headers: [:], body: nil))
        XCTAssertEqual(r.status, 200, path)
        return try JSONValue.parse(r.body)
    }

    private func newIDs(_ files: [JSONValue]) -> [String] {
        files.filter { $0["is_new"]?.int == 1 }.compactMap { $0["id"]?.string }.sorted()
    }

    /// Was zu einem Zeitpunkt als neu gilt, an allen Stellen: Uebersicht (Zahl und Liste), Modulkarten, Moduldetail
    /// (Zaehler und Dateizeilen), Kurse, Bibliothek. Alle Stellen muessen dieselben Dateien nennen.
    private func newEverywhere(at now: String, file: StaticString = #filePath, line: UInt = #line) async throws -> [String] {
        let b = try await backend(at: now)
        let dash = try await get(b, "/api/dashboard")
        let listed = (dash["new_files"]?.array ?? []).compactMap { $0["id"]?.string }.sorted()
        XCTAssertEqual(dash["new_total"]?.int, listed.count, "Uebersicht: Zahl und Liste", file: file, line: line)
        let library = newIDs(try await get(b, "/api/library")["files"]?.array ?? [])
        XCTAssertEqual(library, listed, "Bibliothek wie die Uebersicht", file: file, line: line)
        var cards = 0, details = 0, rows: [String] = []
        for m in try await get(b, "/api/modules").array ?? [] {
            cards += m["new_count"]?.int ?? 0
            let d = try await get(b, "/api/modules/\(m["id"]?.int ?? 0)")
            details += d["new_count"]?.int ?? 0
            rows += newIDs(d["files"]?.array ?? [])
        }
        XCTAssertEqual(cards, listed.count, "Modulkarten", file: file, line: line)
        XCTAssertEqual(details, listed.count, "Moduldetail", file: file, line: line)
        XCTAssertEqual(rows.sorted(), listed, "Dateizeilen im Modul", file: file, line: line)
        let courses = (try await get(b, "/api/courses").array ?? []).reduce(0) { $0 + ($1["new_count"]?.int ?? 0) }
        XCTAssertEqual(courses, listed.count, "Kurse", file: file, line: line)
        return listed
    }

    private func firstListed(_ id: String) async throws -> String? {
        let b = try await backend(at: "2026-11-17T23:59:00")
        return try await b.context.database.scalar("SELECT first_listed_at FROM courses WHERE id=?", [.text(id)])?.string
    }

    private func names(_ prefix: String, _ range: ClosedRange<Int>) -> [String] { range.map { "\(prefix)\($0)" } }

    // MARK: erster und zweiter Abgleich

    func testErstesEinlesenMitFuenfzigDateienZeigtNichtsNeues() async throws {
        try await sync(at: "2026-11-17T09:00:00", [course("k1", "Testanalysis", names("a", 1...50))])
        let new = try await newEverywhere(at: "2026-11-17T09:05:00")
        XCTAssertEqual(new, [], "was beim ersten Einlesen schon da war, ist nicht neu")
        let listed = try await firstListed("k1")
        XCTAssertEqual(listed, "2026-11-17T09:00:00")
        // nichts wird dafuer umgeschrieben: alle 50 bleiben ungesehen mit Lernstand "neu"
        let b = try await backend(at: "2026-11-17T09:05:00")
        let untouched = try await b.context.database.scalar("SELECT COUNT(*) FROM files WHERE seen_by_user=0 AND status='neu' AND first_seen='2026-11-17T09:00:00'")
        XCTAssertEqual(untouched?.int, 50)
    }

    func testZweiterAbgleichBringtZweiNeueUndNach25StundenKeine() async throws {
        try await sync(at: "2026-11-17T09:00:00", [course("k1", "Testanalysis", names("a", 1...50))])
        try await sync(at: "2026-11-17T12:00:00", [course("k1", "Testanalysis", names("a", 1...52))])
        let new = try await newEverywhere(at: "2026-11-17T12:05:00")
        XCTAssertEqual(new, ["a51", "a52"])
        let listed = try await firstListed("k1")
        XCTAssertEqual(listed, "2026-11-17T09:00:00", "der Zeitpunkt wird genau einmal gesetzt")
        // Dateien eines Kurses (Fruehere Semester) und Unterlagen am Termin tragen dasselbe
        let b = try await backend(at: "2026-11-17T12:05:00")
        let inCourse = newIDs(try await get(b, "/api/older-semesters/courses/k1/files").array ?? [])
        XCTAssertEqual(inCourse, ["a51", "a52"])
        let stillNew = try await newEverywhere(at: "2026-11-18T11:59:00")
        XCTAssertEqual(stillNew, ["a51", "a52"], "23 Stunden 59 Minuten: noch neu")
        let later = try await newEverywhere(at: "2026-11-18T13:00:00")
        XCTAssertEqual(later, [], "25 Stunden spaeter verschwindet Neu von selbst")
    }

    // MARK: anfangs leerer Kurs, spaeter belegter Kurs

    func testAnfangsLeererKursErsteDateiSpaeterIstNeu() async throws {
        try await sync(at: "2026-11-17T09:00:00", [course("k1", "Testanalysis", [])])
        let listed = try await firstListed("k1")
        XCTAssertEqual(listed, "2026-11-17T09:00:00", "auch eine leere Liste gilt als eingelesen")
        let empty = try await newEverywhere(at: "2026-11-17T09:05:00")
        XCTAssertEqual(empty, [])
        try await sync(at: "2026-11-17T15:00:00", [course("k1", "Testanalysis", ["erste"])])
        let new = try await newEverywhere(at: "2026-11-17T15:05:00")
        XCTAssertEqual(new, ["erste"], "die erste Datei, die spaeter kommt, muss neu sein")
    }

    func testZweiterKursKommtSpaeterSeineAltdateienSindNichtNeu() async throws {
        try await sync(at: "2026-11-17T09:00:00", [course("k1", "Testanalysis", names("a", 1...3))])
        // spaeter belegt (oder zweite Quelle, oder "Fruehere Semester laden"): der Kurs bringt fuenf Altdateien mit
        try await sync(at: "2026-11-17T12:00:00", [course("k1", "Testanalysis", names("a", 1...3)),
                                                   course("k2", "Testphysik", names("p", 1...5))])
        let afterJoin = try await newEverywhere(at: "2026-11-17T12:05:00")
        XCTAssertEqual(afterJoin, [], "Altdateien des neuen Kurses sind nicht neu")
        let joined = try await firstListed("k2")
        XCTAssertEqual(joined, "2026-11-17T12:00:00")
        try await sync(at: "2026-11-17T16:00:00", [course("k1", "Testanalysis", names("a", 1...3)),
                                                   course("k2", "Testphysik", names("p", 1...6))])
        let new = try await newEverywhere(at: "2026-11-17T16:05:00")
        XCTAssertEqual(new, ["p6"], "was danach im neuen Kurs dazukommt, ist neu")
    }

    // MARK: abgebrochener erster Abgleich

    func testAbgebrochenerErsterAbgleichResteSindSchonDaGewesen() async throws {
        // Lauf 1 bricht mitten im Kurs ab: zwei Zeilen stehen, die Liste gilt nicht als eingelesen
        try await sync(at: "2026-11-17T09:00:00", [course("k1", "Testanalysis", ["a1", "a2"], complete: false)])
        let open = try await firstListed("k1")
        XCTAssertNil(open, "Zeitpunkt erst, wenn die Liste des Kurses ganz geschrieben ist")
        let during = try await newEverywhere(at: "2026-11-17T09:05:00")
        XCTAssertEqual(during, [], "ohne eingelesene Liste ist nichts neu")
        // Lauf 2 liest die Liste ganz: die Reste (a3, a4) waren "schon da"
        try await sync(at: "2026-11-17T10:00:00", [course("k1", "Testanalysis", names("a", 1...4))])
        let listed = try await firstListed("k1")
        XCTAssertEqual(listed, "2026-11-17T10:00:00")
        let afterFull = try await newEverywhere(at: "2026-11-17T10:05:00")
        XCTAssertEqual(afterFull, [])
        // Lauf 3 bringt wirklich Neues
        try await sync(at: "2026-11-17T14:00:00", [course("k1", "Testanalysis", names("a", 1...5))])
        let new = try await newEverywhere(at: "2026-11-17T14:05:00")
        XCTAssertEqual(new, ["a5"])
    }

    // MARK: bestehende Installation (Datenbank ohne die Spalte)

    /// Stand einer aelteren App-Version: Kurse, Dateien und Abgleichprotokoll, aber `courses.first_listed_at` fehlt
    private func oldInstallation() async throws {
        let b = try await backend(at: "2026-11-10T08:00:00")
        let db = b.context.database
        try await db.execute("ALTER TABLE courses DROP COLUMN first_listed_at")
        for (id, title) in [("k1", "Testanalysis"), ("k2", "Testphysik"), ("k3", "Testchemie"), ("k4", "Testlogik")] {
            try await db.execute("INSERT INTO courses(id, title, subject, kind, active, semester, created_at) VALUES (?,?,?,'vorlesung',1,'WiSe 2026/27','2026-11-16T20:00:00')",
                                 [.text(id), .text(title), .text(title)])
        }
        func file(_ id: String, _ course: String, _ firstSeen: String) async throws {
            try await db.execute("INSERT INTO files(id, course_id, name, size, chdate, first_seen, status, seen_by_user, kind) VALUES (?,?,?,10,1794000000,?,'neu',0,'pdf')",
                                 [.text(id), .text(course), .text("\(id).pdf"), .text(firstSeen)])
        }
        // k1: erster Abgleich gestern Abend (300 Dateien, vor 17 Stunden), zweiter heute frueh (2 Dateien)
        for i in 1...300 { try await file("alt\(i)", "k1", "2026-11-16T20:00:00") }
        for i in 1...2 { try await file("frisch\(i)", "k1", "2026-11-17T08:00:00") }
        // k2: keine Dateien. k3: Dateien von heute Mittag, der Abgleich dazu ist gescheitert (kein fertiger Lauf danach)
        for i in 1...40 { try await file("chemie\(i)", "k3", "2026-11-17T12:00:00") }
        // k4: Dateien ohne Zeitpunkt (sehr alte Zeilen)
        try await db.execute("INSERT INTO files(id, course_id, name, status, seen_by_user) VALUES ('uralt', 'k4', 'uralt.pdf', 'neu', 0)")
        for (start, end, ok) in [("2026-11-16T20:00:00", "2026-11-16T20:10:00", 1), ("2026-11-17T08:00:00", "2026-11-17T08:02:00", 1),
                                 ("2026-11-17T12:00:00", "2026-11-17T12:01:00", 0)] {
            try await db.execute("INSERT INTO sync_log(started_at, finished_at, ok, new_files, message) VALUES (?,?,?,0,'Test')",
                                 [.text(start), .text(end), .integer(Int64(ok))])
        }
    }

    func testUpdateBestehenderDatenbankKeineFlutUndWirklichNeuesBleibtNeu() async throws {
        try await oldInstallation()
        // Update: die App oeffnet die Datenbank am 17.11. um 13:20:05, die Migration legt die Spalte an und traegt nach
        let now = "2026-11-17T13:20:05"
        let new = try await newEverywhere(at: now)
        XCTAssertEqual(new, ["frisch1", "frisch2"], "keine Flut: nur was der zweite Abgleich brachte, bleibt neu (nicht 342)")
        let b = try await backend(at: now)
        let rows = try await b.context.database.rows("SELECT id, first_listed_at FROM courses ORDER BY id")
        let listed = Dictionary(uniqueKeysWithValues: rows.compactMap { r in r["id"]?.string.map { ($0, r["first_listed_at"]?.string) } })
        XCTAssertEqual(listed["k1"], "2026-11-16T20:10:00", "Ende des ersten erfolgreichen Abgleichs nach der ersten Datei")
        XCTAssertEqual(listed["k2"], now, "ohne Dateien: Zeitpunkt der Umstellung")
        XCTAssertEqual(listed["k3"], now, "kein fertiger Abgleich danach: Zeitpunkt der Umstellung")
        XCTAssertEqual(listed["k4"], now, "Dateien ohne Zeitpunkt: Zeitpunkt der Umstellung")
        XCTAssertEqual(listed["__user__"], .some(nil), "eigene Dokumente: nie neu aus der Hochschule")
        // nichts an den Dateien geaendert
        let untouched = try await b.context.database.scalar("SELECT COUNT(*) FROM files WHERE seen_by_user=0 AND status='neu'")
        XCTAssertEqual(untouched?.int, 343)
        // naechster Abgleich: eine Datei im bisher leeren Kurs und eine im Kurs ohne fertigen Lauf sind neu
        try await sync(at: "2026-11-17T14:00:00", [course("k2", "Testphysik", ["physik1"]),
                                                   course("k3", "Testchemie", names("chemie", 1...41))])
        let next = try await newEverywhere(at: "2026-11-17T14:05:00")
        XCTAssertEqual(next, ["chemie41", "frisch1", "frisch2", "physik1"])
        // die Umstellung laeuft genau einmal: ein spaeterer Start aendert die Zeitpunkte nicht
        let again = try await backend(at: "2026-11-19T09:00:00")
        let k2 = try await again.context.database.scalar("SELECT first_listed_at FROM courses WHERE id='k2'")?.string
        XCTAssertEqual(k2, now)
    }

    /// Aeltere App-Versionen kennen die Spalte nicht: ihre Anweisungen (Kurs anlegen mit Spaltenliste, Dateien
    /// schreiben, lesen) laufen auf der neuen Datenbank weiter - die Aenderung ist rein zusaetzlich
    func testSpalteIstReinZusaetzlich() async throws {
        let b = try await backend(at: "2026-11-17T09:00:00")
        let db = b.context.database
        let info = try await db.rows("PRAGMA table_info(courses)")
        let column = try XCTUnwrap(info.first { $0["name"]?.string == "first_listed_at" })
        XCTAssertEqual(column["type"]?.string, "TEXT")
        XCTAssertEqual(column["notnull"]?.int, 0, "darf leer sein")
        XCTAssertEqual(column["dflt_value"], .some(.null))
        XCTAssertEqual(info.last?["name"]?.string, "first_listed_at", "hinten angehaengt")
        // so schreibt Version 1.0.4/1.0.5 einen Kurs (`upsert_course` ohne die neue Spalte)
        try await db.execute("""
            INSERT INTO courses(id, title, number, semester, semester_end, semester_ends_at, subject, kind, created_at) VALUES ('alt','Altkurs',NULL,'WiSe 2026/27',NULL,NULL,'Altkurs','vorlesung','2026-11-17T09:00:00')
            ON CONFLICT(id) DO UPDATE SET title=excluded.title
            """)
        let stored = try await db.scalar("SELECT first_listed_at FROM courses WHERE id='alt'")
        XCTAssertEqual(stored, .some(.null))
        let user = try await db.scalar("PRAGMA user_version")?.int
        XCTAssertEqual(user, Int(Migrations.deviceSteps.map(\.version).max() ?? 0), "keine neue Geraete-Version: aeltere Apps oeffnen die Datenbank weiter")
    }

    // MARK: Demo und eigene Dokumente

    func testDemoDateienBleibenNeu() async throws {
        let now = "2026-11-17T09:00:00"
        let b = try await backend(at: now)
        let clock = UniFlowClock.fixed(berlin: now)!, local = files!
        _ = try await b.context.database.transaction { try DemoContent.install($0, files: local, clock: clock) }
        let new = try await newEverywhere(at: "2026-11-17T09:05:00")
        XCTAssertEqual(new, DemoContent.files.map(\.id).sorted(), "Demo-Karte \"Neue Dateien (Demo)\" ist nicht leer")
        let later = try await newEverywhere(at: "2026-11-18T10:00:00")
        XCTAssertEqual(later, [], "auch Demo-Dateien nur 24 Stunden")
    }

    func testEigeneDokumenteSindNieNeu() async throws {
        let b = try await backend(at: "2026-11-17T09:00:00")
        // selbst mit "ungesehen" (so schreibt die App eigene Dokumente nie): eigene Dokumente kommen nicht aus der Hochschule
        try await b.context.database.execute("""
            INSERT INTO files(id, course_id, name, first_seen, status, seen_by_user, kind) VALUES ('u1','__user__','Mein Heft','2026-11-17T09:00:00','neu',0,'notebook')
            """)
        let new = try await newEverywhere(at: "2026-11-17T09:05:00")
        XCTAssertEqual(new, [])
        // und die App legt sie ohnehin als gesehen an (Import in die Bibliothek, Notizbuch)
        let form = [("kind", "notebook"), ("title", "Heft")].map { "--b\r\nContent-Disposition: form-data; name=\"\($0.0)\"\r\n\r\n\($0.1)\r\n" }
            .joined() + "--b--\r\n"
        let made = await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device/api/notebooks")!,
                                               headers: ["Content-Type": "multipart/form-data; boundary=b"], body: Data(form.utf8)))
        XCTAssertEqual(made.status, 200)
        let seen = try await b.context.database.scalar("SELECT MIN(seen_by_user) FROM files WHERE course_id='__user__' AND id<>'u1'")
        XCTAssertEqual(seen?.int, 1)
    }
}
