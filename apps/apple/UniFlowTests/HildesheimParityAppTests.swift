import UIKit
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Hildesheim-Gleichheit (docs/HILDESHEIM-PARITAET.md): jede LUH-Funktion mit erfundenen Daten der Uni Hildesheim
/// (Debug-Stub-Ordner, Learnweb mit Schluessel, LSF ueber die Sitzung; kein Netz) bis in die Endpunkte der Seiten:
/// Dokumente nach Fach und Lehrwoche, Module, Stundenplan mit Ausfall, Noten, Uebersicht, Suche, Lernplan, neue
/// Fassung mit erhaltenen Notizen, Editor-Inhalt, Statusleiste, Abmelden und Daten loeschen.
@MainActor
final class HildesheimParityAppTests: XCTestCase {
    private var bed: ContainerTestBed!
    /// Montag, 26.10.2026, 10:00 in Berlin (WiSe 2026/27 -> learnweb2026)
    private let clock = UniFlowClock.fixed(berlin: "2026-10-26T10:00:00")!
    private let base = "https://www.uni-hildesheim.de/learnweb2026"
    private let token = "TestSchluessel0123456789abcdef"

    override func setUp() async throws {
        try await super.setUp()
        bed = try ContainerTestBed(name: "paritaet", clock: clock)
    }

    override func tearDown() async throws {
        await bed.tearDown()
        try await super.tearDown()
    }

    /// Zweiseitige PDF mit Text (Suche, Seitenzuordnung einer neuen Fassung)
    private func makePDF(_ pages: [String]) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            for p in pages {
                ctx.beginPage()
                (p as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
            }
        }
    }

    /// Learnweb und LSF aus dem Stub-Ordner, LSF nur mit der Sitzung aus der Webansicht; `override` ersetzt einzelne
    /// Antworten (neue Fassung einer Datei)
    private func install(override: @escaping @Sendable (UniStubProtocol.Seen) -> UniStubProtocol.Reply? = { _ in nil }) {
        let dir = ContainerTestBed.stubDirectory
        UniStubProtocol.install { r in
            if let o = override(r) { return o }
            if r.url.host == "lsf.uni-hildesheim.de", !r.cookie.contains("JSESSIONID=lsf-sitzung-test") {
                return .redirect(302, to: "https://www.uni-hildesheim.de/sso/login?service=lsf")
            }
            let reply = DebugStubTransport(directory: dir).reply(r.url, body: r.body)
            return UniStubProtocol.Reply(status: reply.status, headers: reply.headers, body: reply.body)
        }
    }

    private func hildesheim() async throws -> (ContainerManager, ActiveContainer, HildesheimConnection, AccountStore) {
        let m = bed.manager()
        let a = bed.account(.hildesheim)
        let c = try bed.open(m, a)
        let h = try XCTUnwrap(m.hildesheim)
        h.syncsAfterSignIn = false
        await m.websiteDataStore(for: c).httpCookieStore.setCookie(bed.cookie("JSESSIONID", "lsf-sitzung-test", domain: "lsf.uni-hildesheim.de"))
        XCTAssertTrue(h.learnwebSignedIn(token: try XCTUnwrap(LearnwebToken(token)), base: base))
        h.lsfSignedIn()
        return (m, c, h, a)
    }

    /// Learnweb-Kursinhalt aus dem Stub mit anderer Aenderungszeit der Datei "Sitzung 1" (neue Fassung)
    nonisolated private static func contents(stamp: Int) -> UniStubProtocol.Reply {
        let dir = ContainerTestBed.stubDirectory
        var text = String(decoding: (try? Data(contentsOf: dir.appendingPathComponent("learnweb-contents-35.json"))) ?? Data(), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"timemodified\": 1791885600", with: "\"timemodified\": \(stamp)")
        return UniStubProtocol.Reply(status: 200, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
    }

    private func day(_ c: ActiveContainer, _ date: String) async throws -> [(String, String)] {
        let d = try await c.api.value("/api/timetable/day?date=\(date)")
        return (d["events"]?.array ?? []).map { ($0["start"]?.string ?? "", $0["status"]?.string ?? "") }
    }

    private func fileID(_ c: ActiveContainer, named name: String) async throws -> String {
        let lib = try await c.api.value("/api/library")
        return try XCTUnwrap((lib["files"]?.array ?? []).first { $0["name"]?.string == name }?["id"]?.string, name)
    }

    func testEveryLUHFunctionWorksForHildesheim() async throws {
        let (m, c, h, _) = try await hildesheim()
        install()
        let first = await h.run()
        let report = try XCTUnwrap(first)
        XCTAssertTrue(report.ok, report.messages.joined(separator: "; "))
        XCTAssertEqual(report.completed, ["Learnweb", "LSF-Stundenplan", "Notenspiegel"])
        XCTAssertEqual(report.newFiles.count, 4)

        // Dokumente: Dateien aus dem Learnweb nach Fach (Modul) und Lehrwoche (Abschnitt "1" -> Woche 1)
        let lib = try await c.api.value("/api/library")
        let names = (lib["files"]?.array ?? []).compactMap { $0["name"]?.string }.sorted()
        XCTAssertEqual(names, ["Aufgaben_Bildung_und_Ungleichheit.pdf", "Folien_Sitzung_1_Grundbegriffe.pdf", "Folien_Sitzung_2_Geschichte.pdf", "Seminarplan.pdf"])
        let folders = (lib["files"]?.array ?? []).compactMap { $0["studip_folder"]?.string }
        XCTAssertTrue(folders.contains("Woche 1") && folders.contains("Woche 2"), "\(folders)")
        let courses = (try await c.api.value("/api/courses").array ?? []).filter { $0["id"]?.string != "__user__" }
        XCTAssertEqual(Set(courses.compactMap { $0["subject"]?.string }), ["Einführung in die Erziehungswissenschaft", "Bildungssoziologie"])
        let modules = try await c.api.value("/api/modules").array ?? []
        XCTAssertEqual(Set(modules.compactMap { $0["name"]?.string }), ["Einführung in die Erziehungswissenschaft", "Bildungssoziologie"])
        let ew = try XCTUnwrap(modules.first { $0["name"]?.string == "Einführung in die Erziehungswissenschaft" })
        XCTAssertEqual(ew["file_count"]?.int, 3)
        let detail = try await c.api.value("/api/modules/\(ew["id"]?.int ?? 0)")
        let weeks = detail.list("weeks")
        XCTAssertFalse(weeks.isEmpty, "Moduldetail nach Lehrwoche")
        XCTAssertEqual(detail.list("files").count, 3)
        XCTAssertTrue(detail.list("files").contains { $0.s("name") == "Folien_Sitzung_1_Grundbegriffe.pdf" && $0.s("doc_type") == "vorlesung" }, "Folien = Vorlesung wie an der LUH")

        // Stundenplan aus dem LSF: Dienstag 10:00 und Donnerstag 14:00 (nicht am Montag aus DTSTART), Ausfall Heiligabend
        let week = try await c.api.value("/api/timetable/week?start=2026-10-26")
        let starts = week.list("days").map { $0.list("events").map { $0.s("start") ?? "" } }
        XCTAssertEqual(starts.prefix(5).map { $0 }, [[], ["10:00"], [], ["14:00"], []], "\(starts)")
        let eve = try await day(c, "2026-12-24").map(\.1)
        XCTAssertEqual(eve, ["ausfall"])
        let dec22 = try await day(c, "2026-12-22").map(\.1)
        XCTAssertEqual(dec22, ["ausfall"])
        let nov3 = try await day(c, "2026-11-03").map(\.1)
        XCTAssertEqual(nov3, ["teilnahme"])

        // Noten aus dem LSF: nur die Leistungstabelle, Notenschnitt nach LP
        let grades = try await c.api.value("/api/grades")
        XCTAssertEqual(grades["grades"]?.array?.count, 3, "zwei benotete, eine angemeldete")
        XCTAssertEqual(grades["average"], 1.94)
        XCTAssertEqual(grades["passed"], 2)
        let dump = try await c.host.backend().context.database.rows("SELECT * FROM grades")
        XCTAssertFalse(JSONValue.array(dump.map(JSONValue.object)).jsonString().contains("Beispiel"), "Stammdaten nie gespeichert")

        // Uebersicht: neue Dateien mit der Quelle der Hochschule, Termine des Tages
        let dash = try await c.api.value("/api/dashboard")
        XCTAssertEqual(dash["new_total"], 4)
        XCTAssertEqual(UFSourceText.newFiles(.hildesheim), "Neu aus Learnweb")
        XCTAssertEqual(UFDataMode.current(api: c.api, studip: m.studip), .local(.otherSources), "Karten Learnweb/LSF statt Stud.IP")
        XCTAssertTrue(UFNavItem.visible(local: true, gradesOnDevice: true).contains { $0.id == "services" })
        XCTAssertEqual(TimetableImportDialog.sources(local: true, offersStudIP: false).map(\.id), ["ics", "manual"], "Stundenplan kommt vom LSF, ICS und eigene Termine bleiben")

        // Suche: Text aus einer Learnweb-PDF
        let search = try await c.api.value("/api/search?q=sozialisation")
        XCTAssertEqual(search["pages"]?.array?.compactMap { $0["file_id"]?.string }.count, 1, "\(search)")
        let byModule = try await c.api.value("/api/search?q=bildungssozio")
        XCTAssertEqual(byModule["modules"]?.array?.compactMap { $0["name"]?.string }, ["Bildungssoziologie"])

        // Lernplan: Pakete aus den Learnweb-Materialien neben den LSF-Terminen
        _ = try await c.api.value("/api/calendar/generate", method: "POST", body: ["start": "2026-10-26"])
        let cal = try await c.api.value("/api/calendar?start=2026-10-26&end=2026-11-01")
        let packages = cal.list("days").map { $0.list("packages").count }.reduce(0, +)
        XCTAssertGreaterThan(packages, 0, "\(cal)")
        let overview = try await c.api.value("/api/dashboard")
        XCTAssertNotNil(overview["today"])

        // Editor: Inhalt der Datei kommt aus dem Container (Learnweb/files/...)
        let sitzung1 = try await fileID(c, named: "Folien_Sitzung_1_Grundbegriffe.pdf")
        let (pdf, http) = try await c.api.data("/api/files/\(sitzung1)/content")
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertTrue(String(decoding: pdf.prefix(5), as: UTF8.self).hasPrefix("%PDF"))

        // Statusleiste: Stand je Quelle und Meldungen des Laufs
        XCTAssertEqual(HildesheimConnection.statusText(.learnweb, h.learnweb, now: clock.now), "Learnweb: 10:00 ok")
        XCTAssertEqual(HildesheimConnection.statusText(.lsf, h.lsf, now: clock.now), "LSF: 10:00 ok")
        XCTAssertEqual(h.messages.count, 3, "\(h.messages)")
        XCTAssertEqual(FirstSyncProgress.hildesheim(learnweb: h.learnweb, lsf: h.lsf, messages: h.messages).map(\.state), [.done, .done, .done])
    }

    /// Neue Fassung einer Learnweb-Datei mit Notizen: alte Fassung bleibt, Notizen auf den passenden Seiten (S7 wie
    /// beim Stud.IP-Abgleich, dieselbe `UniDownloads`-Fassung)
    func testNewLearnwebVersionKeepsNotes() async throws {
        let (_, c, h, _) = try await hildesheim()
        let v1 = makePDF(["Sitzung 1 Grundbegriffe Seite eins", "Diskussionsfragen Seite zwei"])
        let v2 = makePDF(["Sitzung 1 Grundbegriffe Seite eins", "Neue Seite in der Mitte", "Diskussionsfragen Seite zwei"])
        let contents1 = Self.contents(stamp: 1791885600), contents2 = Self.contents(stamp: 1792490400)
        install { r in
            if r.url.path.contains("/webservice/pluginfile.php/502/") { return UniStubProtocol.Reply(status: 200, headers: ["Content-Type": "application/pdf"], body: v1) }
            if r.bodyText.contains("courseid=35") { return contents1 }
            return nil
        }
        _ = await h.run()
        let id = try await fileID(c, named: "Folien_Sitzung_1_Grundbegriffe.pdf")
        let notes: JSONValue = ["version": 2, "pageOrder": [["key": "p1", "type": "pdf", "index": 1], ["key": "p2", "type": "pdf", "index": 2]],
                                "pages": ["p1": ["objects": []],
                                          "p2": ["objects": [["id": "a", "type": "stroke", "points": [10, 10, 90, 90], "color": "#000000", "width": 2]]]]]
        _ = try await c.api.value("/api/files/\(id)/annotations?base_version=0", method: "PUT", body: notes)

        install { r in
            if r.url.path.contains("/webservice/pluginfile.php/502/") { return UniStubProtocol.Reply(status: 200, headers: ["Content-Type": "application/pdf"], body: v2) }
            if r.bodyText.contains("courseid=35") { return contents2 }
            return nil
        }
        let again = await h.run()
        let second = try XCTUnwrap(again)
        XCTAssertEqual(second.newFiles, [id], "nur die geaenderte Datei neu geladen")
        let versions = try await c.api.value("/api/files/\(id)/versions")
        XCTAssertEqual(versions["versions"]?.array?.count, 1, "alte Fassung aufbewahrt")
        let (pdf, _) = try await c.api.data("/api/files/\(id)/content")
        XCTAssertEqual(pdf.count, v2.count, "neue Fassung im Editor")
        let ann = try await c.api.value("/api/files/\(id)/annotations")["data"]
        let order = ann?["pageOrder"]?.array?.compactMap { $0["key"]?.string } ?? []
        XCTAssertEqual(order.count, 3, "drei Seiten in der neuen Fassung: \(order)")
        let strokes = (ann?["pages"]?.array == nil ? ann?["pages"] : nil)
        let moved = strokes?.object?.values.contains { ($0["objects"]?.array?.count ?? 0) == 1 } ?? false
        XCTAssertTrue(moved, "Notiz der Seite 'Diskussionsfragen' auf der passenden Seite der neuen Fassung: \(String(describing: ann))")
    }

    func testSignOutKeepsDataAndDeleteRemovesOnlyHildesheim() async throws {
        let (m, c, h, a) = try await hildesheim()
        install()
        _ = await h.run()
        let before = try await c.api.value("/api/library")["files"]?.array?.count
        XCTAssertEqual(before, 4)
        await h.signOut()
        XCTAssertFalse(h.anyConnected)
        let kept = try await c.api.value("/api/library")["files"]?.array?.count
        XCTAssertEqual(kept, 4, "Abmelden behaelt Dateien, Stundenplan und Noten")
        let keptDay = try await day(c, "2026-11-03").count
        XCTAssertEqual(keptDay, 1)
        // "Daten dieser Hochschule löschen": danach ein leerer Speicher derselben Hochschule
        await m.deleteUniversityData(c.key)
        let fresh = try XCTUnwrap(m.active)
        let empty = try await fresh.api.value("/api/library")["files"]?.array?.count
        XCTAssertEqual(empty, 0)
        let emptyDay = try await day(fresh, "2026-11-03").count
        XCTAssertEqual(emptyDay, 0)
        XCTAssertEqual(a.stage, .universityLogin, "Konto unveraendert; die Anmeldeseiten kommen beim ersten Start einmal")
    }
}
