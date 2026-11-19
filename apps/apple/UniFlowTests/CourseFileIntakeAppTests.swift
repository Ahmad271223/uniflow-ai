import UniFlowCore
import XCTest
@testable import UniFlow

/// Datei-Eingang (18.11.2026): im App-Store-Build aus (Build-Einstellung `UF_INTAKE_OFFERED=NO`), im Test-Build
/// (`UF_INTAKE_OFFERED=YES`) erst nach Zustimmung; die Zustimmung nennt, was gesendet wird und was nie; geschickt wird
/// nur, was der Eingang noch nicht hat (`/api/intake/check` vor `/api/intake/file`).
final class CourseFileIntakeAppTests: XCTestCase {
    private var defaults: UserDefaults!
    private var offeredBefore = false
    private var dir: URL!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "intake-\(UUID().uuidString)")
        offeredBefore = CourseFileIntakeSetting.isOffered
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("intake-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        CourseFileIntakeSetting.isOffered = offeredBefore
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Schalter ueber den Build

    /// Nur ein ausdrueckliches YES schaltet ein; fehlt die Einstellung oder ist sie nicht aufgeloest, bleibt es aus
    func testBuildValueRule() {
        XCTAssertFalse(CourseFileIntakeSetting.offered(info: "NO"))
        XCTAssertFalse(CourseFileIntakeSetting.offered(info: "no"))
        XCTAssertFalse(CourseFileIntakeSetting.offered(info: ""))
        XCTAssertFalse(CourseFileIntakeSetting.offered(info: nil))
        XCTAssertFalse(CourseFileIntakeSetting.offered(info: "$(UF_INTAKE_OFFERED)"), "nicht aufgeloest: aus")
        XCTAssertFalse(CourseFileIntakeSetting.offered(info: "JA"))
        XCTAssertTrue(CourseFileIntakeSetting.offered(info: "YES"))
        XCTAssertTrue(CourseFileIntakeSetting.offered(info: " yes "))
        XCTAssertTrue(CourseFileIntakeSetting.offered(info: true))
    }

    /// Der normale Build (project.yml: Debug und Release "NO") bietet den Eingang nicht an. Schlaegt das fehl, wurde
    /// dieser Testlauf mit `UF_INTAKE_OFFERED=YES` gebaut - oder project.yml steht falsch.
    func testNormalBuildIsOff() {
        let value = Bundle.main.object(forInfoDictionaryKey: CourseFileIntakeSetting.infoKey) as? String
        XCTAssertEqual(value, "NO", "Info.plist UFIntakeOffered aus UF_INTAKE_OFFERED")
        XCTAssertFalse(CourseFileIntakeSetting.offered(info: value))
        XCTAssertFalse(offeredBefore, "Standard: aus")
    }

    /// Build-Wert NO: auch eine (fruehere) Zustimmung schaltet nichts ein
    func testBuildSwitchTurnsEverythingOff() {
        CourseFileIntakeSetting.isOffered = true
        CourseFileIntakeSetting.set(true, defaults)
        XCTAssertTrue(CourseFileIntakeSetting.isOn(defaults))
        CourseFileIntakeSetting.isOffered = false
        XCTAssertFalse(CourseFileIntakeSetting.isOn(defaults))
    }

    /// Entscheidung 18.11.2026 abends: ohne Eintrag AN (Grundlage in den Nutzungsbedingungen), Ausschalten wird gemerkt
    func testOnByDefaultAndOffIsRemembered() {
        CourseFileIntakeSetting.isOffered = true
        XCTAssertTrue(CourseFileIntakeSetting.isOn(defaults), "ohne Eintrag an")
        CourseFileIntakeSetting.set(false, defaults)
        XCTAssertFalse(CourseFileIntakeSetting.isOn(defaults), "ausgeschaltet bleibt aus")
        CourseFileIntakeSetting.isOffered = false
        defaults.removeObject(forKey: CourseFileIntakeSetting.key)
        XCTAssertFalse(CourseFileIntakeSetting.isOn(defaults), "Store-Build (nicht angeboten): nie an")
    }

    func testSwitchRemembersTime() {
        CourseFileIntakeSetting.isOffered = true
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        CourseFileIntakeSetting.set(true, defaults, now: now)
        XCTAssertTrue(CourseFileIntakeSetting.isOn(defaults))
        XCTAssertEqual(defaults.object(forKey: CourseFileIntakeSetting.consentKey) as? Date, now, "Zeitpunkt der Zustimmung gemerkt")
        CourseFileIntakeSetting.set(false, defaults)
        XCTAssertFalse(CourseFileIntakeSetting.isOn(defaults))
        XCTAssertNil(defaults.object(forKey: CourseFileIntakeSetting.consentKey))
    }

    // MARK: Zustimmung gegen das, was wirklich geht

    func testConsentNamesWhatIsNeverSent() {
        let all = CourseFileIntakeSetting.consentPoints.joined(separator: " ")
        for word in ["Name", "Konto", "Notizen", "eigene Dokumente", "Organisatorisches", "Matrikelnummern", "Noten", "WLAN",
                     "Ausschalten", "einmal", "nicht immer"] {
            XCTAssertTrue(all.contains(word), word)
        }
    }

    /// Jede Angabe der Karteikarte steht in der Zustimmung; kommt eine neue dazu, muss der Text mit
    func testConsentNamesEveryFieldThatIsSent() {
        let meta = CourseFileIntake.Meta(sha256: "x", program: nil, semester: nil, module: "M", docType: "skript", fileName: "f.pdf",
                                         courseTitle: nil, courseNumber: nil, week: nil, pages: nil)
        let named: [String: String] = ["program": "Studiengang", "semester": "Semester", "module": "Modul", "doc_type": "Art der Datei",
                                       "file_name": "Dateiname", "course_title": "Kursname", "course_number": "-nummer",
                                       "week": "Woche", "pages": "Seitenzahl",
                                       // Pruefsumme des Inhalts: nur zum Erkennen doppelter Dateien, keine Angabe ueber den Nutzer
                                       "sha256": "nur einmal"]
        XCTAssertEqual(Set(meta.json.object?.keys ?? [:].keys), Set(named.keys), "neue Angabe in der Karteikarte: Zustimmung anpassen")
        let all = CourseFileIntakeSetting.consentPoints.joined(separator: " ")
        for (field, word) in named { XCTAssertTrue(all.contains(word), "\(field): „\(word)“ fehlt in der Zustimmung") }
        XCTAssertTrue(all.contains("Hochschule"), "Hochschule geht mit (university)")
    }

    func testNeverRunsUnderTests() {
        XCTAssertTrue(StudIPSync.isUnderTest(), "unter XCTest schickt der Eingang nichts")
    }

    // MARK: Lauf: nichts ohne Build-Wert und Zustimmung, danach nur Neues

    /// Build-Wert NO: kein einziger Aufruf an den Dienst, auch mit Zustimmung, WLAN und Konto
    func testBuildValueNoSendsNothing() async throws {
        let b = try await backend()
        let fake = FakeIntake()
        CourseFileIntakeSetting.isOffered = false
        CourseFileIntakeSetting.set(true, defaults)
        let c = conditions(consented: CourseFileIntakeSetting.isOn(defaults))
        XCTAssertFalse(c.consented)
        let r = try await CourseFileIntakeRunner.send(b.context, transport: fake, when: c)
        XCTAssertNil(r)
        var offeredOnly = c
        offeredOnly.consented = true                      // selbst wenn die Zustimmung durchkaeme: Build-Wert NO
        try await assertNotRun(b, fake, offeredOnly)
        XCTAssertEqual(fake.calls, [], "nichts gesendet")
    }

    /// Build-Wert YES, aber vom Nutzer ausgeschaltet (oder ohne WLAN, Konto, in der Demo, unter Tests): nichts gesendet
    func testWithoutConsentOrConditionsNothingIsSent() async throws {
        let b = try await backend()
        let fake = FakeIntake()
        CourseFileIntakeSetting.isOffered = true
        XCTAssertTrue(CourseFileIntakeSetting.isOn(defaults), "ohne Eintrag von selbst an (18.11.2026)")
        CourseFileIntakeSetting.set(false, defaults)       // Nutzer schaltet aus (Widerspruch)
        try await assertNotRun(b, fake, conditions(consented: CourseFileIntakeSetting.isOn(defaults)))
        var all = conditions(consented: true)
        XCTAssertTrue(all.allowed)
        for change in [\CourseFileIntakeRunner.Conditions.onWiFi, \.signedIn] {
            var c = all; c[keyPath: change] = false
            try await assertNotRun(b, fake, c)
        }
        for change in [\CourseFileIntakeRunner.Conditions.demo, \.underTest] {
            var c = all; c[keyPath: change] = true
            try await assertNotRun(b, fake, c)
        }
        all.offered = false
        try await assertNotRun(b, fake, all)
        XCTAssertEqual(fake.calls, [], "nichts gesendet")
    }

    /// Nach Zustimmung: erst fragen (check), dann nur hochladen, was fehlt; der zweite Lauf schickt nichts mehr
    func testAfterConsentOnlyNewFilesGoUp() async throws {
        let b = try await backend()
        let fake = FakeIntake()
        let knownSha = try XCTUnwrap(ContentHash.file(dir.appendingPathComponent("blatt1.pdf")))
        fake.known = [knownSha]                           // diese Datei hat der Eingang schon
        CourseFileIntakeSetting.isOffered = true
        CourseFileIntakeSetting.set(true, defaults)
        let c = conditions(consented: CourseFileIntakeSetting.isOn(defaults))
        let first = try await CourseFileIntakeRunner.send(b.context, transport: fake, when: c)
        let r = try XCTUnwrap(first)

        XCTAssertEqual(fake.calls.first, "check", "erst fragen, dann schicken")
        XCTAssertEqual(fake.uploadedNames.sorted(), ["Altklausur WS 24.pdf", "VL01 Folgen.pdf"], "nur, was fehlt")
        XCTAssertFalse(fake.uploadedShas.contains(knownSha), "vorhandene Datei geht nicht hoch")
        for sha in fake.uploadedShas { XCTAssertTrue(fake.missingAnswered.contains(sha), "nur, was check als fehlend gemeldet hat") }
        XCTAssertEqual(r.uploaded, 2)
        XCTAssertEqual(r.skippedNameLists, 1, "Liste mit Matrikelnummern bleibt auf dem Gerät")
        XCTAssertFalse(fake.checkedNames.contains("Übung Blatt 2.pdf"), "Namensliste wird nicht einmal angefragt")
        XCTAssertFalse(fake.checkedNames.contains("Meine Notizen.pdf"), "eigenes Dokument nie")
        XCTAssertFalse(fake.checkedNames.contains("Organisatorisches.pdf"), "Organisatorisches nie")

        let before = fake.calls.count
        let second = try await CourseFileIntakeRunner.send(b.context, transport: fake, when: c)
        let again = try XCTUnwrap(second)
        XCTAssertEqual(again, CourseFileIntake.Report())
        XCTAssertEqual(fake.calls.count, before, "zweiter Lauf: nichts Neues, kein Aufruf")
    }

    // MARK: Hilfen

    private func assertNotRun(_ b: LocalBackend, _ fake: FakeIntake, _ c: CourseFileIntakeRunner.Conditions,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let r = try await CourseFileIntakeRunner.send(b.context, transport: fake, when: c)
        XCTAssertNil(r, "\(c)", file: file, line: line)
    }

    private func conditions(consented: Bool) -> CourseFileIntakeRunner.Conditions {
        .init(offered: CourseFileIntakeSetting.isOffered, consented: consented, underTest: false, demo: false, onWiFi: true, signedIn: true)
    }

    /// Seitentext = Dateiinhalt als Text (statt PDFKit)
    private struct TextTools: LocalDocumentTools {
        func pdfPageCount(_ data: Data) -> Int? { 1 }
        func pdfFromImage(_ data: Data) -> Data? { nil }
        func pdfPageTexts(_ url: URL) -> [String]? { (try? String(contentsOf: url, encoding: .utf8)).map { [$0] } }
    }

    /// Eingang zum Mitschreiben: kennt `known`, nimmt alles andere an
    private final class FakeIntake: CourseFileIntake.Transport, @unchecked Sendable {
        private let lock = NSLock()
        var known: Set<String> = []
        private(set) var calls: [String] = []
        private(set) var checkedNames: [String] = []
        private(set) var missingAnswered: Set<String> = []
        private(set) var uploadedNames: [String] = []
        private(set) var uploadedShas: [String] = []

        func check(_ metas: [CourseFileIntake.Meta]) async throws -> [String] {
            lock.withLock {
                calls.append("check")
                checkedNames += metas.map(\.fileName)
                let missing = metas.map(\.sha256).filter { !known.contains($0) }
                missingAnswered.formUnion(missing)
                return missing
            }
        }

        func upload(_ meta: CourseFileIntake.Meta, file: URL) async throws -> String {
            lock.withLock {
                calls.append("upload")
                uploadedNames.append(meta.fileName)
                uploadedShas.append(meta.sha256)
                known.insert(meta.sha256)
                return "stored"
            }
        }
    }

    private func backend() async throws -> LocalBackend {
        let files = LocalFiles(container: dir, dataDirectory: "", tools: TextTools())
        func put(_ name: String, _ text: String) throws { _ = try files.write(Data(text.utf8), to: name) }
        try put("vl1.pdf", "Folgen und Reihen")
        try put("blatt1.pdf", "Aufgabe 1: Zeigen Sie")
        try put("ak.pdf", "Klausur WS 24, Aufgabe 1")
        try put("orga.pdf", "Termine und Raeume")
        try put("liste.pdf", "Name Matrikelnummer\nA 1234567\nB 2345678\nC 3456789\nD 4567890\nE 5678901")
        try put("eigen.pdf", "Meine Mitschrift")

        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-18T10:00:00")!, files: files)
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, color, sort) VALUES (1, 'Analysis I', '#175ee8', 0)")
            try c.execute("""
                INSERT INTO courses(id, title, number, semester, subject, kind, active, module_id, created_at) VALUES
                ('c1', 'Analysis I (Vorlesung)', '4711', 'WS 2026/27', 'Analysis I', 'vorlesung', 1, 1, 't'),
                ('c2', 'Analysis I (Übung)', '4712', 'WS 2026/27', 'Analysis I', 'uebung', 1, 1, 't')
                """)
            try c.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('__user__', 'Eigene', 'sonstiges', 1, 't')")
            let rows: [(String, String, String, String)] = [
                ("f-vl", "c1", "VL01 Folgen.pdf", "vl1.pdf"),
                ("f-ub", "c2", "Blatt 1.pdf", "blatt1.pdf"),
                ("f-ak", "c1", "Altklausur WS 24.pdf", "ak.pdf"),
                ("f-orga", "c1", "Organisatorisches.pdf", "orga.pdf"),
                ("f-liste", "c2", "Übung Blatt 2.pdf", "liste.pdf"),
                ("f-eigen", "__user__", "Meine Notizen.pdf", "eigen.pdf"),
            ]
            for (i, (id, course, name, path)) in rows.enumerated() {
                try c.execute("INSERT INTO files(id, course_id, name, chdate, status, local_path) VALUES (?,?,?,?,?,?)",
                              [.text(id), .text(course), .text(name), .integer(Int64(100 - i)), .text("neu"), .text(path)])
            }
        }
        return b
    }
}
