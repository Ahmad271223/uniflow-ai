import PDFKit
import UIKit
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// "Eine Klausur stand nur in einer Folie, keine Erinnerung" (Meldung des Inhabers 17.11.2026), App-Seite: Erinnerungen
/// ueberstehen einen Start im Hintergrund, ein neu erkannter Klausurtermin wird einmal gemeldet (auch am Tag selbst),
/// Folien als Bild werden nur im Vordergrund erkannt, die Karte oben auf der Uebersicht zeigt heute, morgen und neu
/// Erkanntes, und das Nachlesen vieler Folien haelt den Hauptthread frei. Mitteilungen gehen an einen Mitschreiber;
/// Container im Temp-Ordner; Nutzer, Kurse, Folien erfunden und im Test erzeugt.
@MainActor
final class KlausurAusFolienAppTests: XCTestCase {

    final class Notifier: DueNotifying {
        var state: DueNotificationStatus = .allowed
        var requests = 0
        var pending: [String: DueReminders.Reminder] = [:]
        var posted: [DueReminders.Reminder] = []
        var removed: [String] = []

        func status() async -> DueNotificationStatus { state }
        func requestPermission() async -> Bool { requests += 1; return state == .allowed }
        func pendingIdentifiers() async -> [String] { Array(pending.keys) }
        func schedule(_ r: DueReminders.Reminder) async { pending[r.identifier] = r }
        func post(_ r: DueReminders.Reminder) async { posted.append(r) }
        func remove(_ identifiers: [String]) {
            removed += identifiers
            for i in identifiers { pending[i] = nil }
        }
    }

    /// Texterkennung mit festen Texten je Seite (statt Vision)
    final class OCR: PageOCR, @unchecked Sendable {
        private let lock = NSLock()
        private let texts: [Int: String]
        private var seen: [Int] = []
        init(_ texts: [Int: String]) { self.texts = texts }
        var pages: [Int] { lock.withLock { seen } }
        func recognize(pdf url: URL, pages: [Int]) async throws -> [Int: String] {
            lock.withLock {
                seen += pages
                return texts.filter { pages.contains($0.key) }
            }
        }
    }

    private final class MemorySecrets: AccountSecretStore {
        var values: [String: String] = [:]
        func get(_ key: String) -> String? { values[key] }
        func set(_ value: String, for key: String) { values[key] = value }
        func delete(_ key: String) { values[key] = nil }
    }

    private struct Authorized: AppleCredentialChecking {
        func state(forUserID id: String) async -> AppleCredentialState { .authorized }
    }

    private var appSupport: URL!
    private var suite = ""
    private var defaults: UserDefaults!
    private let user = "001234.erfunden-folie.\(UUID().uuidString.prefix(8))"
    /// Dienstag, 10.11.2026; die Klausur ist am Dienstag, 17.11.2026
    private var clock = UniFlowClock.fixed(berlin: "2026-11-10T10:00:00")!
    private var stores: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        appSupport = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-folie-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        suite = "uniflow.tests.folie.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        for layout in DataContainerLayout.all(base: base, userID: user) {
            let s = ActiveContainer.defaultsSuite(layout.identifier)
            UserDefaults(suiteName: s)?.removePersistentDomain(forName: s)
            stores.append(layout.identifier)
        }
        for id in Set(stores) { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: appSupport)
        try await super.tearDown()
    }

    private var base: URL { appSupport.appendingPathComponent("UniFlowContainers", isDirectory: true) }

    private func container() throws -> (ContainerManager, ActiveContainer) {
        let m = ContainerManager(base: base, legacy: LegacyDataMigration.Sources(support: appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                                                studip: appSupport.appendingPathComponent("StudIP", isDirectory: true)),
                                 keychain: UniversityKeychain(service: "de.uniflow.ai.university.test.\(UUID().uuidString)"),
                                 cookieService: "de.uniflow.ai.studip.test.\(UUID().uuidString)", defaults: defaults, clock: clock, publishesCurrent: false)
        let a = AccountStore(secrets: MemorySecrets(), defaults: defaults, checker: Authorized(), observeRevocation: false)
        a.signIn(userID: user, name: nil, email: nil)
        a.markPlanShown()
        a.chooseUniversity(.luh)
        m.sync(account: a)
        let c = try XCTUnwrap(m.active)
        stores.append(c.websiteDataStoreID)
        return (m, c)
    }

    private func scheduler(_ n: Notifier, enabled: Bool = true, plus: Bool = true) -> DueReminderScheduler {
        defaults.set(enabled, forKey: DueReminderScheduler.enabledKey)
        let s = DueReminderScheduler(notifier: n, defaults: defaults)
        let fixed = clock.now
        s.now = { fixed }
        s.allowed = { plus }
        s.ocrAllowed = { true }
        s.inBackground = { false }
        return s
    }

    private func unix(_ local: String) -> Int64 { Int64(UniFlowClock.fixed(berlin: local)!.now.timeIntervalSince1970) }

    private func seedCourse(_ c: ActiveContainer) async throws -> SQLiteDatabase {
        let d = try await c.host.backend().context.database
        try await d.execute("INSERT INTO modules(id, name, color) VALUES (1, 'Statistik I', '#2563eb')")
        try await d.execute("INSERT INTO courses(id, title, active, module_id) VALUES ('k1', 'Statistik I', 1, 1)")
        return d
    }

    private func addFile(_ d: SQLiteDatabase, id: String, name: String, pages: [String]?, chdate: String = "2026-11-09T12:00") async throws {
        try await d.execute("INSERT INTO files(id, course_id, name, chdate, local_path, kind) VALUES (?, 'k1', ?, ?, ?, 'pdf')",
                            [.text(id), .text(name), .integer(unix(chdate)), .text("StudIP/\(name)")])
        for (i, t) in (pages ?? []).enumerated() {
            try await d.execute("INSERT INTO page_texts(file_id, page, text, chdate, search) VALUES (?,?,?,?,?)",
                                [.text(id), .integer(Int64(i + 1)), .text(t), .integer(unix(chdate)), .text(ScriptSearch.searchForm(t))])
        }
    }

    /// Folien-PDF mit Textebene: je Seite ein Text (im Test erzeugt, erfunden)
    static func slidesPDF(_ pages: [String]) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 960, height: 540)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            for text in pages {
                ctx.beginPage()
                (text as NSString).draw(in: bounds.insetBy(dx: 60, dy: 50), withAttributes: [.font: UIFont.systemFont(ofSize: 30)])
            }
        }
    }

    // MARK: 4. Erinnerungen

    /// Start durch iOS im Hintergrund, bevor ein Fenster die Container anhaengt: ein Lauf nimmt nichts zurueck.
    /// Vorher nahm er alle geplanten Erinnerungen zurueck ("kein Container").
    func testRunBeforeAttachKeepsPlannedReminders() async throws {
        let n = Notifier()
        let old = DueReminders.Reminder(identifier: "de.uniflow.ai.due.C.due-1.d1", fireAt: clock.now.addingTimeInterval(86400),
                                        title: "Morgen: Klausur", body: "", route: nil, itemID: "due-1")
        n.pending[old.identifier] = old
        let s = scheduler(n)
        await s.refresh(recompute: true)
        XCTAssertEqual(Array(n.pending.keys), [old.identifier], "nichts zurueckgenommen")
        XCTAssertEqual(n.removed, [])
        // angehaengt und kein Container offen (abgemeldet): dann wirklich zuruecknehmen
        let m = ContainerManager(base: base, legacy: LegacyDataMigration.Sources(support: appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                                                studip: appSupport.appendingPathComponent("StudIP", isDirectory: true)),
                                 keychain: UniversityKeychain(service: "de.uniflow.ai.university.test.\(UUID().uuidString)"),
                                 cookieService: "de.uniflow.ai.studip.test.\(UUID().uuidString)", defaults: defaults, clock: clock, publishesCurrent: false)
        s.attach(m)
        await s.settle()
        XCTAssertEqual(n.pending.count, 0)
    }

    /// Klausur nur in einer Folie: nach dem Abgleich einmal "Neuer Klausurtermin erkannt", Erinnerungen 7 Tage, 3 Tage,
    /// 1 Tag vorher und 2 Stunden vorher; ein weiterer Abgleich meldet nicht erneut
    func testExamFromSlideIsAnnouncedOnceAndPlanned() async throws {
        let (m, c) = try container()
        let d = try await seedCourse(c)
        let n = Notifier()
        let s = scheduler(n)
        s.attach(m)
        await s.settle()
        XCTAssertEqual(n.posted.count, 0)
        try await addFile(d, id: "f5", name: "VL05_Schaetzer.pdf", pages: ["Statistik I", "Organisatorisches\nKlausur\n17.11.2026, 10:00 Uhr\nAudimax"])
        await s.refresh(recompute: true)                                     // wie nach einem Abgleich
        XCTAssertEqual(n.posted.map(\.title), ["Neuer Klausurtermin erkannt: Klausur am Di, 17.11. 10:00"])
        XCTAssertEqual(n.posted.first?.body, "Statistik I · erkannt in VL05_Schaetzer.pdf, S. 2 · Bitte prüfen.")
        XCTAssertEqual(n.posted.first?.route, "#/doc/f5?page=2")
        XCTAssertEqual(n.pending.values.sorted { $0.fireAt < $1.fireAt }.map(\.title),
                       ["In 3 Tagen: Klausur", "Morgen: Klausur", "In 2 Stunden: Klausur"], "7 Tage vorher ist am 10.11. um 10 Uhr schon vorbei")
        await s.refresh(recompute: true)
        await s.refresh(recompute: false)
        XCTAssertEqual(n.posted.count, 1, "nicht bei jedem Abgleich erneut")
        // die Karte oben zeigt ihn weiter als neu erkannt, bis er gesehen ist
        let rows = DueSoon.rows(try await c.api.value("/api/due").list("items"))
        XCTAssertEqual(rows.map { $0.s("title") }, ["Klausur"])
        XCTAssertEqual(rows.first?["is_new"], true)
        XCTAssertEqual(DueSoon.origin(rows[0]), "erkannt in VL05_Schaetzer.pdf, S. 2 – bitte prüfen")
        XCTAssertEqual(DueOpen.route(rows[0]), "#/doc/f5?page=2")
    }

    /// Klausur in mehr als 7 Tagen: auch "In 7 Tagen" ist geplant, nichts doppelt
    func testSevenDayReminderForExams() async throws {
        let (m, c) = try container()
        let d = try await seedCourse(c)
        try await addFile(d, id: "f1", name: "VL01.pdf", pages: ["Klausurtermin: 16.02.2027", "Abgabe Blatt 4: 30.11.2026"])
        let n = Notifier()
        let s = scheduler(n)
        s.attach(m)
        await s.settle()
        let exam = n.pending.values.filter { $0.title.hasSuffix("Klausur") }.sorted { $0.fireAt < $1.fireAt }.map(\.title)
        XCTAssertEqual(exam, ["In 7 Tagen: Klausur", "In 3 Tagen: Klausur", "Morgen: Klausur", "Heute: Klausur"])
        XCTAssertEqual(n.pending.values.filter { $0.title.contains("Abgabe") }.count, 3, "Abgaben wie bisher")
        XCTAssertEqual(n.pending.count, 7)
    }

    /// Erst am Tag selbst erkannt, alle Zeitpunkte vorbei: die Mitteilung "neu erkannt" kommt trotzdem
    func testExamFoundOnTheDayItselfStillNotifies() async throws {
        clock = UniFlowClock.fixed(berlin: "2026-11-17T09:10:00")!
        let (m, c) = try container()
        let d = try await seedCourse(c)
        try await addFile(d, id: "f5", name: "VL05.pdf", pages: ["Kurzklausur am 17.11. in der Vorlesung"], chdate: "2026-11-12T12:00")
        let n = Notifier()
        let s = scheduler(n)
        s.attach(m)
        await s.settle()
        XCTAssertEqual(n.pending.count, 0, "Morgen 8:00 ist vorbei")
        XCTAssertEqual(n.posted.map(\.title), ["Neuer Klausurtermin erkannt: Kurzklausur heute (Di, 17.11.)"])
        let rows = DueSoon.rows(try await c.api.value("/api/due").list("items"))
        XCTAssertEqual(rows.map { DueSoon.badge($0).text }, ["Heute"])
    }

    /// Schalter aus (Vorgabe) oder Tarif ohne Erinnerungen: keine Mitteilung, kein System-Dialog; die Uebersicht zeigt den
    /// Termin als neu erkannt und sagt, warum keine Erinnerung kommt
    func testWithoutSwitchNothingIsPostedButTheCardShowsIt() async throws {
        let (m, c) = try container()
        let d = try await seedCourse(c)
        try await addFile(d, id: "f5", name: "VL05.pdf", pages: ["Klausur: 17.11.2026"])
        let n = Notifier()
        n.state = .notDetermined
        let s = scheduler(n, enabled: false)
        s.attach(m)
        await s.settle()
        XCTAssertEqual(n.posted.count, 0)
        XCTAssertEqual(n.pending.count, 0)
        XCTAssertEqual(n.requests, 0, "nie ungefragt den System-Dialog")
        let state = await s.reminderState()
        XCTAssertEqual(state, .off)
        let rows = DueSoon.rows(try await c.api.value("/api/due").list("items"))
        XCTAssertEqual(rows.first?["is_new"], true)
        XCTAssertTrue(try XCTUnwrap(DueSoon.hint(.off)).contains("ausgeschaltet"))
        // Tarif ohne Erinnerungen und iOS-Erlaubnis fehlt
        let free = await scheduler(Notifier(), plus: false).reminderState()
        XCTAssertEqual(free, .locked)
        let denied = Notifier()
        denied.state = .denied
        let off = await scheduler(denied).reminderState()
        XCTAssertEqual(off, .denied)
        XCTAssertNil(DueSoon.hint(.on))
        XCTAssertTrue(try XCTUnwrap(DueSoon.hint(.denied)).contains("Mitteilungen"))
        XCTAssertTrue(try XCTUnwrap(DueSoon.hint(.locked)).contains("StudiNow Plus"))
    }

    // MARK: 1. Folien als Bild

    /// Seiten ohne Textebene: Texterkennung nur im Vordergrund und nicht im Stromsparmodus, in Portionen, jede Seite einmal
    func testImageSlidesAreRecognisedOnlyInForeground() async throws {
        let (m, c) = try container()
        let d = try await seedCourse(c)
        let backend = try await c.host.backend()
        let ocr = OCR([3: "Zwischenklausur am 17.11.2026 im Audimax"])
        backend.context.ocr.set(ocr)
        // PDF ohne Textebene (leere Seiten) auf der Platte, nie geoeffnet
        let folder = c.layout.root.appendingPathComponent("StudIP", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.slidesPDF(["", "", "", ""]).write(to: folder.appendingPathComponent("bild.pdf"))
        try await addFile(d, id: "f-bild", name: "bild.pdf", pages: nil)
        let n = Notifier()
        let s = scheduler(n)
        s.ocrAllowed = { false }                                             // im Hintergrund bzw. Stromsparmodus
        s.attach(m)
        await s.settle()
        XCTAssertEqual(ocr.pages, [], "im Hintergrund keine Texterkennung")
        let texts = try await d.rows("SELECT page FROM page_texts WHERE file_id='f-bild'")
        XCTAssertEqual(texts.count, 4, "die Seitentexte sind nachgelesen (leer)")
        XCTAssertEqual(n.posted.count, 0)
        s.ocrAllowed = { true }                                              // App im Vordergrund
        await s.refresh(recompute: true)
        XCTAssertEqual(ocr.pages, [1, 2, 3, 4])
        XCTAssertEqual(n.posted.map(\.title), ["Neuer Klausurtermin erkannt: Zwischenklausur am Di, 17.11."])
        XCTAssertEqual(n.posted.first?.body, "Statistik I · erkannt in bild.pdf, S. 3 · Bitte prüfen.")
        await s.refresh(recompute: true)
        XCTAssertEqual(ocr.pages.count, 4, "nichts doppelt gelesen")
    }

    // MARK: 3. Karte oben auf der Uebersicht

    func testSoonCardRowsBadgesAndTexts() {
        func item(_ id: String, kind: String, days: Int, new: Bool? = nil, detected: Bool = true, confirmed: Bool = false, hidden: Bool = false) -> JSONValue {
            var o: [String: JSONValue] = ["id": .string(id), "kind": .string(kind), "days_left": .number(Double(days)),
                                          "in_days": .string(DueStore.inDays(days)), "detected": .bool(detected), "confirmed": .bool(confirmed),
                                          "hidden": .bool(hidden), "origin": "erkannt in VL05.pdf, S. 12", "title": "Klausur"]
            if let new { o["is_new"] = .bool(new) }
            return .object(o)
        }
        let items = [item("a", kind: "klausur", days: 0), item("b", kind: "test", days: 1), item("c", kind: "abgabe", days: 0),
                     item("d", kind: "klausur", days: 9), item("e", kind: "klausur", days: 9, new: true),
                     item("f", kind: "klausur", days: 1, hidden: true), item("g", kind: "klausur", days: 1, detected: false, confirmed: true)]
        let rows = DueSoon.rows(items)
        XCTAssertEqual(rows.compactMap { $0.s("id") }, ["a", "b", "e", "g"], "Abgaben, spaetere bekannte und ausgeblendete nicht")
        XCTAssertEqual(rows.map { DueSoon.badge($0).text }, ["Heute", "Morgen", "in 9 Tagen", "Morgen"])
        XCTAssertEqual(DueSoon.badge(rows[0]).tone, .bad)
        XCTAssertEqual(DueSoon.origin(rows[0]), "erkannt in VL05.pdf, S. 12 – bitte prüfen")
        XCTAssertEqual(DueSoon.origin(item("x", kind: "klausur", days: 0, confirmed: true)), "erkannt in VL05.pdf, S. 12 – von dir bestätigt")
        XCTAssertEqual(DueSoon.origin(rows[3]), "erkannt in VL05.pdf, S. 12", "nicht erkannte Quellen ohne Zusatz")
        XCTAssertEqual(DueSoon.title(rows), "Klausuren und Tests: bald und neu erkannt")
        XCTAssertEqual(DueSoon.title([rows[0]]), "Klausur oder Test: heute und morgen")
        XCTAssertEqual(DueSoon.title([rows[2]]), "Neu erkannt: Klausur oder Test")
        XCTAssertEqual(DueSoon.rows([]), [])
        // nur in einem Dokument erkannte Klausur in "Nächste Klausuren": oeffnet die Seite, Quelle mit "bitte prüfen"
        let exam: JSONValue = ["detected_only": true, "file_id": "f5", "page": 12, "module_id": 1, "source_label": "erkannt in VL05.pdf, S. 12"]
        XCTAssertEqual(UFExam.target(exam), .doc("f5", page: 12))
        XCTAssertEqual(UFExam.sourceText(exam), "erkannt in VL05.pdf, S. 12 – bitte prüfen")
        XCTAssertEqual(UFExam.target(["module_id": 1, "source_label": "aus Stud.IP-Terminen"]), .module(1))
        XCTAssertEqual(UFExam.target(["date": "2026-11-17"]), .timetable(date: "2026-11-17"), "nie in den ausgeblendeten Lernkalender")
    }

    // MARK: 3. Stundenplan

    /// Klausur-Pin einer nur in einer Folie erkannten Klausur: nennt den Satz der Fundstelle und die Quelle, fuehrt zur
    /// Seite und laesst "Stimmt" / "Stimmt nicht" zu; eine Kurzklausur bleibt der Chip "erkannt" mit denselben Wegen
    func testTimetablePinOfDetectedExamCarriesSourceAndDecision() {
        let due: JSONValue = ["id": "due-1", "detected": true, "kind": "klausur", "title": "Klausur", "kind_label": "Klausur",
                              "snippet": "Klausur 17.11.2026, 10:00 Uhr", "origin": "erkannt in VL05.pdf, S. 12", "file_id": "f5", "page": 12,
                              "module_id": 1, "confirmed": false, "time": "10:00"]
        let quiz: JSONValue = ["id": "due-2", "detected": true, "kind": "klausur", "title": "Kurzklausur", "kind_label": "Kurzklausur",
                               "snippet": "Kurzklausur am 17.11.", "origin": "erkannt in VL06.pdf, S. 3", "file_id": "f6", "page": 3,
                               "module_id": 2, "confirmed": false, "note": "Im Text steht Mittwoch, der 17.11. ist aber ein Dienstag."]
        let exam: JSONValue = ["id": "exam-m1-2026-11-17", "title": "Klausur Statistik I", "kind_label": "Klausur", "module_id": 1, "time": "10:00",
                               "detected_only": true, "due_id": "due-1", "file_id": "f5", "page": 12, "source_label": "erkannt in VL05.pdf, S. 12"]
        let hints = UFHint.all(["date": "2026-11-17", "exams": [exam], "deadlines": [due, quiz]])
        XCTAssertEqual(hints.map(\.category), [.exam, .detected], "die erkannte Klausur steht nur als Klausur-Pin da")
        let pin = hints[0]
        XCTAssertEqual(pin.detectedItem?.s("id"), "due-1")
        XCTAssertEqual(pin.snippet, "„Klausur 17.11.2026, 10:00 Uhr“")
        XCTAssertEqual(pin.source, "erkannt in VL05.pdf, S. 12 (automatisch erkannt)")
        XCTAssertEqual(pin.detectedItem.flatMap(DueOpen.route), "#/doc/f5?page=12")
        XCTAssertEqual(UFDayExtraChips.text(pin, compact: true), "10:00 Klausur")
        let chip = hints[1]
        XCTAssertEqual(chip.kindText, "Klausur / Prüfung")
        XCTAssertTrue(UFDayExtraChips.isDetectedExam(chip), "als Klausur-Pin gezeigt, nicht in der Modulfarbe")
        XCTAssertFalse(UFDayExtraChips.isDetectedExam(UFHint.deadline(["id": "d3", "detected": true, "kind": "abgabe", "title": "Abgabe"], date: "2026-11-17")))
        XCTAssertEqual(chip.detectedItem?.s("note"), "Im Text steht Mittwoch, der 17.11. ist aber ein Dienstag.")
        XCTAssertEqual(chip.detectedItem.flatMap(DueOpen.route), "#/doc/f6?page=3")
        // Klausur aus einer anderen Quelle (Stud.IP-Termin): kein erkannter Termin am Pin
        let studip: JSONValue = ["id": "exam-m3-2026-11-17", "title": "Klausur Analysis", "module_id": 3, "source_label": "aus Stud.IP-Terminen"]
        XCTAssertNil(UFHint.all(["date": "2026-11-17", "exams": [studip]]).first?.detectedItem)
    }

    // MARK: Leistung

    /// 200 Foliensaetze mit je 60 Seiten, nie geoeffnet: ein Lauf liest alle nach (PDFKit im lokalen Backend), der
    /// Hauptthread bleibt dabei frei. Messwerte in der Ausgabe.
    func testReadingTwoHundredSlideDecksKeepsMainThreadFree() async throws {
        let (m, c) = try container()
        let d = try await seedCourse(c)
        let folder = c.layout.root.appendingPathComponent("StudIP", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var pages = (1...60).map { "Vorlesung Statistik I – Folie \($0)\nSchätzer, Konfidenzintervalle und Hypothesentests mit etwas Text je Folie." }
        pages[36] = "Organisatorisches\nKlausur\n17.11.2026, 10:00 Uhr\nAudimax"
        let deck = Self.slidesPDF(pages), plain = Self.slidesPDF(pages.enumerated().map { $0.offset == 36 ? "Zusammenfassung der Vorlesung und Ausblick auf die nächste Woche" : $0.element })
        let stamp = unix("2026-11-09T12:00")
        try await d.transaction { conn in
            for i in 0..<200 {
                let name = "VL\(i).pdf"
                try (i == 123 ? deck : plain).write(to: folder.appendingPathComponent(name))
                try conn.execute("INSERT INTO files(id, course_id, name, chdate, local_path, kind) VALUES (?, 'k1', ?, ?, ?, 'pdf')",
                                 [.text("f\(i)"), .text(name), .integer(stamp - Int64(i)), .text("StudIP/\(name)")])
            }
        }
        let n = Notifier()
        let s = scheduler(n)
        // Takt auf dem Hauptthread: laengste Luecke zwischen zwei Schlaegen
        var longest = 0.0, last = Date(), beating = true
        let beat = Task { @MainActor in
            while beating {
                try? await Task.sleep(nanoseconds: 4_000_000)
                let now = Date()
                longest = max(longest, now.timeIntervalSince(last))
                last = now
            }
        }
        let start = Date()
        s.attach(m)
        await s.settle()
        let seconds = Date().timeIntervalSince(start)
        beating = false
        await beat.value
        let read = try await d.rows("SELECT COUNT(DISTINCT file_id) AS n, COUNT(*) AS p FROM page_texts")
        XCTAssertEqual(read.first?["n"]?.int, 200, "alle in einem Lauf")
        XCTAssertEqual(read.first?["p"]?.int, 12_000)
        XCTAssertEqual(n.posted.map(\.title), ["Neuer Klausurtermin erkannt: Klausur am Di, 17.11. 10:00"])
        print(String(format: "Nachlesen: 200 PDFs x 60 Seiten in %.1f s, laengste Luecke auf dem Hauptthread %.0f ms", seconds, longest * 1000))
        XCTAssertLessThan(seconds, 240)
        XCTAssertLessThan(longest, 1.0, "Hauptthread frei")
        // Anteile eines Laufs ohne Neues (Messwerte in der Ausgabe)
        for (label, path, method) in [("Nachlesen", "/api/due/backfill?limit=20", "POST"), ("Erkennen", "/api/due/refresh", "POST"),
                                      ("Liste", "/api/due", "GET"), ("Texterkennung", "/api/due/ocr?pages=12", "POST")] {
            let t = Date()
            _ = try await c.api.value(path, method: method)
            print(String(format: "  Anteil %@: %.2f s", label, Date().timeIntervalSince(t)))
        }
        // zweiter Lauf: nichts mehr zu lesen
        let again = Date()
        await s.refresh(recompute: true)
        print(String(format: "Zweiter Lauf ohne Neues: %.2f s", Date().timeIntervalSince(again)))
        XCTAssertEqual(n.posted.count, 1)
    }
}
