import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Studienverlauf (04.11.2026, docs/STUDIENVERLAUF-2026-11-04.md): Seite mit Kopf (Ring "84 von 180 LP", Hinweise,
/// Satz zur Pruefungsordnung), Board quer bzw. Liste hochkant mit allen Status, Filter, Blatt mit den Moduldetails
/// (Fakten, Versuche, Modultexte zum Aufklappen, Unterlagen, Quelle), Blatt Einstellungen (POST-Rumpf), Zustaende
/// ohne Plan (laden, QIS fehlt, Katalogsuche mit Nachfrage, kein Katalog mit Link, Pruefungsordnung bestaetigen) und
/// die Breitenpruefung bei 1180 x 820 und 820 x 1180. Alles gegen einen Schein-Transport mit erfundenen Antworten,
/// kein Netz. Mit UF_SCREENSHOT_DIR (xcodebuild: TEST_RUNNER_UF_SCREENSHOT_DIR) schreibt `testScreenshots` Bilder
/// hell/dunkel, quer/hochkant.
@MainActor
final class StudyPlanBoardAppTests: XCTestCase {

    /// Schein-Transport: feste Antworten je Pfad, merkt sich Methode, Pfad und Rumpf jeder Anfrage
    final class Transport: APITransport, @unchecked Sendable {
        private let lock = NSLock()
        private var canned: [String: JSONValue] = [:]
        private var status: [String: Int] = [:]
        private var hang: Set<String> = []
        private var log: [(method: String, path: String, body: JSONValue?)] = []
        /// nach einer Anfrage ("POST /api/...") gilt fuer `key` eine neue Antwort (wie der Kern nach dem Speichern)
        private var then: [String: (key: String, value: JSONValue)] = [:]

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let body = request.httpBody.flatMap { try? JSONValue.parse($0) }
            let method = request.httpMethod ?? "GET"
            let (answer, code, hangs): (JSONValue?, Int, Bool) = lock.withLock {
                log.append((method, path, body))
                if let t = then[method + " " + path] { canned[t.key] = t.value }
                return (canned[method + " " + path] ?? canned[path], status[method + " " + path] ?? status[path] ?? 200, hang.contains(path))
            }
            if hangs { try await Task.sleep(nanoseconds: 60_000_000_000) }
            let data = (answer ?? ["detail": .string("Testfehler")]).serialized()
            return (data, HTTPURLResponse(url: request.url!, statusCode: answer == nil ? 404 : code, httpVersion: nil, headerFields: nil)!)
        }

        func answer(_ path: String, _ v: JSONValue) { lock.withLock { canned[path] = v } }
        func answer(_ path: String, after trigger: String, _ v: JSONValue) { lock.withLock { then[trigger] = (path, v) } }

        /// Plan, in dem der Kern ein Modul ins Semester `term` gelegt hat (eigene Lage, LP je Semester nachgezogen)
        static func moved(_ plan: JSONValue, _ id: String, to term: String) -> JSONValue {
            guard var o = plan.object, var sems = o["semesters"]?.array else { return plan }
            var module: JSONValue?
            for (i, s) in sems.enumerated() {
                guard var so = s.object, var ms = so["modules"]?.array, let k = ms.firstIndex(where: { $0["id"]?.string == id }) else { continue }
                module = ms.remove(at: k)
                so["modules"] = .array(ms)
                so["lp"] = .number((so["lp"]?.double ?? 0) - (module?["lp"]?.double ?? 0))
                sems[i] = .object(so)
            }
            guard var m = module?.object, let i = sems.firstIndex(where: { $0["term"]?.string == term }), var so = sems[i].object else { return plan }
            m["placed"] = true
            m["moved_from"] = .null
            m["reason"] = .null
            so["modules"] = .array((so["modules"]?.array ?? []) + [.object(m)])
            so["lp"] = .number((so["lp"]?.double ?? 0) + (m["lp"]?.double ?? 0))
            sems[i] = .object(so)
            o["semesters"] = .array(sems)
            var pl = o["placements"]?.object ?? [:]
            pl[id] = .string(term)
            o["placements"] = .object(pl)
            return .object(o)
        }
        func fail(_ key: String, _ code: Int, _ v: JSONValue) { lock.withLock { canned[key] = v; status[key] = code } }
        func hangs(_ path: String) { lock.withLock { _ = hang.insert(path) } }
        func count(_ method: String, _ path: String) -> Int { lock.withLock { log.filter { $0.method == method && $0.path == path }.count } }
        func bodies(_ method: String, _ path: String) -> [JSONValue] {
            lock.withLock { log.filter { $0.method == method && $0.path == path }.compactMap(\.body) }
        }
    }

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    // MARK: Daten (erfunden)

    static func mod(_ id: String, _ title: String, lp: Double = 5, kind: String = "pflicht", turnus: String = "WS", status: String,
                    attempt: Int? = nil, grade: String? = nil, moved: String? = nil, reason: String? = nil, area: String = "grundlagen",
                    last: Bool? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "title": .string(title), "lp": .number(lp), "kind": .string(kind),
                                      "turnus": .string(turnus), "status": .string(status), "area": .string(area)]
        if let attempt { o["attempt"] = .number(Double(attempt)) }
        if let grade { o["grade"] = .string(grade) }
        if let moved { o["moved_from"] = .string(moved) }
        if let reason { o["reason"] = .string(reason) }
        if let last { o["last_attempt"] = .bool(last) }
        return .object(o)
    }

    static let plan: JSONValue = [
        "available": true, "program": "Technische Informatik", "degree": "B.Sc.", "po": "2022", "catalog_term": "WS 2025/26",
        "lp_done": 84, "lp_total": 180, "current_term": "WiSe 26/27",
        "notes": ["Letzter Versuch in Mathematik I", "1 Modul nachzuholen"],
        "disclaimer": "Verbindlich ist die Prüfungsordnung deiner Hochschule.",
        "semesters": [
            ["term": "WiSe 25/26", "fachsemester": 1, "lp": 30, "modules": [
                mod("programmieren-1", "Programmieren I", status: "bestanden", attempt: 1, grade: "1,7", area: "informatik"),
                mod("mathematik-1", "Mathematik I", lp: 10, status: "nicht_bestanden", attempt: 2, area: "mathematik", last: true),
                mod("digitale-systeme", "Grundlagen digitaler Systeme", status: "bestanden", attempt: 1, grade: "2,3", area: "technik"),
                mod("et-1", "Elektrotechnische Grundlagen der Informatik", lp: 10, status: "bestanden", attempt: 1, grade: "3,0", area: "technik"),
            ]],
            ["term": "SoSe 26", "fachsemester": 2, "lp": 30, "modules": [
                mod("programmieren-2", "Programmieren II", turnus: "SS", status: "bestanden", grade: "2,0", area: "informatik"),
                mod("mathematik-2", "Mathematik II", lp: 10, turnus: "SS", status: "bestanden", grade: "3,3", area: "mathematik"),
                mod("rechnerstrukturen", "Rechnerstrukturen", turnus: "SS", status: "bestanden", grade: "2,7", area: "technik"),
                mod("theoretische-informatik", "Grundlagen der Theoretischen Informatik", lp: 10, turnus: "SS", status: "bestanden", grade: "2,3", area: "informatik"),
            ]],
            ["term": "WiSe 26/27", "fachsemester": 3, "lp": 40, "modules": [
                mod("mathematik-1-n", "Mathematik I", lp: 10, status: "geplant", attempt: 3, moved: "WiSe 25/26",
                    reason: "Nicht bestanden im 2. Versuch – nächster Termin im Wintersemester", area: "mathematik", last: true),
                mod("algorithmen", "Algorithmen und Datenstrukturen", status: "angemeldet", area: "informatik"),
                mod("datenbanken", "Grundlagen der Datenbanksysteme", status: "angemeldet", area: "informatik"),
                mod("computergrafik", "Computergrafik I", kind: "wahlpflicht", turnus: "WS+SS", status: "angemeldet", area: "wahl"),
                mod("signale", "Signale und Systeme", lp: 10, status: "offen", area: "technik"),
            ]],
            ["term": "SoSe 27", "fachsemester": 4, "lp": 30, "modules": [
                mod("betriebssysteme", "Betriebssysteme", turnus: "SS", status: "offen", area: "informatik"),
                mod("softwaretechnik", "Softwaretechnik", turnus: "SS", status: "geplant", moved: "WiSe 26/27",
                    reason: "Voraussetzung Mathematik I fehlt noch", area: "informatik"),
                mod("robotik", "Robotik I", kind: "wahlpflicht", turnus: "SS", status: "offen", area: "wahl"),
                mod("schluessel", "Schlüsselkompetenzen", kind: "wahl", turnus: "unbekannt", status: "offen", area: "schluessel"),
            ]],
            ["term": "WiSe 27/28", "fachsemester": 5, "lp": 30, "modules": [
                mod("rechnernetze", "Rechnernetze", status: "offen", area: "informatik"),
                mod("labor", "Labor Technische Informatik", lp: 10, status: "offen", area: "technik"),
            ]],
            ["term": "SoSe 28", "fachsemester": 6, "lp": 27, "modules": [
                mod("bachelorarbeit", "Bachelorarbeit", lp: 15, kind: "abschluss", turnus: "WS+SS", status: "offen", area: "abschluss"),
            ]],
        ],
    ]

    static let detailMathe: JSONValue = [
        "id": "mathematik-1", "title": "Mathematik I", "code": "MAT-1", "lp": 10, "semester": 1, "turnus": "WS", "kind": "pflicht",
        "area": "mathematik", "area_name": "Mathematische Grundlagen", "exam": "Klausur 120 min", "coursework": "Übungsaufgaben (50 %)",
        "prerequisites": [], "language": "deutsch", "workload_h": 300,
        "texts": ["content": "Folgen und Reihen, Differential- und Integralrechnung einer Veränderlichen, lineare Algebra.",
                  "goals": "Die Studierenden rechnen sicher mit Grenzwerten und Matrizen.",
                  "literature": "Erfundenes Lehrbuch, 3. Auflage"],
        "own": ["status": "nicht_bestanden", "last_attempt": true, "attempts": [
            ["attempt": 1, "semester": "WiSe 25/26", "grade": "5,0", "status": "nicht bestanden", "date": "2026-02-20"],
            ["attempt": 2, "semester": "SoSe 26", "grade": "5,0", "status": "nicht bestanden", "date": "2026-07-28"],
        ]],
        "materials": [
            ["kind": "course", "id": "c3", "module_id": 3, "title": "Mathematik I für Ingenieure", "sub": "Stud.IP-Kurs"],
            ["kind": "file", "id": "f-12", "title": "Übungsblatt 4.pdf", "sub": "Übungsblätter"],
        ],
        "source": ["url": "https://modkat.example/modkat-TIBSc22-WS_2025_26.pdf", "page": 12],
    ]

    static let detailSoftware: JSONValue = [
        "id": "softwaretechnik", "title": "Softwaretechnik", "lp": 5, "semester": 4, "turnus": "SS", "kind": "pflicht",
        "exam": "Klausur 90 min", "coursework": .null, "prerequisites": ["programmieren-2", ["id": "mathematik-1", "title": "Mathematik I"]],
        "language": "deutsch", "workload_h": 150, "own": ["status": "geplant", "moved_from": "WiSe 26/27", "reason": "Voraussetzung Mathematik I fehlt noch"],
        "materials": [], "source": ["url": "https://modkat.example/modkat-TIBSc22-WS_2025_26.pdf", "page": 31],
    ]

    static let settings: JSONValue = [
        "po": "2022", "po_options": ["2017", "2022"], "start_term": "WiSe 25/26",
        "term_options": ["WiSe 26/27", "SoSe 26", "WiSe 25/26", "SoSe 25"],
        "electives": ["computergrafik"], "elective_lp_required": 15,
        "elective_options": [
            ["id": "computergrafik", "title": "Computergrafik I", "lp": 5, "area": "Wahlpflicht Informatik"],
            ["id": "robotik", "title": "Robotik I", "lp": 5, "area": "Wahlpflicht Technik"],
            ["id": "bildverarbeitung", "title": "Digitale Bildverarbeitung", "lp": 5, "area": "Wahlpflicht Informatik"],
            ["id": "eingebettete", "title": "Eingebettete Systeme", "lp": 5, "area": "Wahlpflicht Technik"],
        ],
    ]

    private func transport(plan: JSONValue = plan) -> Transport {
        let t = Transport()
        t.answer("/api/study-plan", plan)
        t.answer("/api/study-plan/module/mathematik-1", Self.detailMathe)
        t.answer("/api/study-plan/module/mathematik-1-n", Self.detailMathe)
        t.answer("/api/study-plan/module/softwaretechnik", Self.detailSoftware)
        t.answer("GET /api/study-plan/settings", Self.settings)
        t.answer("POST /api/study-plan/settings", ["ok": true])
        t.answer("/api/study-catalog/status", ["state": "ready"])
        return t
    }

    private func api(_ t: Transport) -> APIClient { APIClient(base: URL(string: "http://erfunden.test/")!, transport: t) }

    // MARK: Hilfen

    private func host(_ t: Transport, size: CGSize = CGSize(width: 1180, height: 820), sidebar: Bool = false,
                      type: DynamicTypeSize = .large, page: StudyPlanPage = StudyPlanPage()) throws -> HostedEnvironment {
        // quer wie in der App: links die Seitenleiste (248 pt), rechts die Seite
        let view = HStack(spacing: 0) {
            if sidebar { Rectangle().fill(UF.surface).frame(width: UF.sidebar).overlay(alignment: .trailing) { Rectangle().fill(UF.line).frame(width: 1) } }
            page
        }
        .environment(\.dynamicTypeSize, type)
        return try hostWithEnvironment(view, api: api(t), size: size)
    }

    /// alle Elemente mit Namen oder Kennung (auch in einem vorgestellten Blatt)
    private func elements(_ root: UIView) -> [NSObject] {
        root.layoutIfNeeded()
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ e: Any, depth: Int) {
            guard depth < 60 else { return }
            if let o = e as? NSObject {
                guard seen.insert(ObjectIdentifier(o)).inserted else { return }
                let id = (o as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? ""
                if o.accessibilityLabel?.isEmpty == false || !id.isEmpty { out.append(o) }
                for c in o.accessibilityElements ?? [] { visit(c, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 600) { if let c = o.accessibilityElement(at: i) { visit(c, depth: depth + 1) } } }
            }
            if let v = e as? UIView, !v.isHidden { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return out
    }

    private func labels(_ root: UIView) -> [String] { elements(root).compactMap(\.accessibilityLabel).filter { !$0.isEmpty } }

    private func find(_ root: UIView, label: String, exact: Bool = false) -> NSObject? {
        elements(root).first { e in
            guard let l = e.accessibilityLabel else { return false }
            return exact ? l == label : l.hasPrefix(label)
        }
    }

    private func find(_ root: UIView, id: String) -> NSObject? {
        elements(root).first { ($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier == id }
    }

    @discardableResult
    private func tap(_ root: UIView, _ label: String, exact: Bool = false) -> Bool {
        guard let e = find(root, label: label, exact: exact) else { return false }
        return e.accessibilityActivate()
    }

    /// Ansicht des vorgestellten Blatts (nil: keins offen)
    private func sheet(_ env: HostedEnvironment) -> UIView? {
        guard let p = env.hosting.presentedViewController, !p.isBeingDismissed else { return nil }
        return p.view
    }

    /// Koepfe der ersten beiden Semester auf gleicher Hoehe (Board) oder untereinander (Liste)
    private func sideBySide(_ root: UIView) -> Bool {
        guard let a = find(root, label: "WiSe 25/26,"), let b = find(root, label: "SoSe 26,") else { return false }
        return abs(a.accessibilityFrame.minY - b.accessibilityFrame.minY) < 2 && b.accessibilityFrame.minX > a.accessibilityFrame.maxX
    }

    /// Breitenbefunde ohne die Huelle des Systemblatts (Abdunkelung und Schatten reichen absichtlich ueber den Rand)
    private func overflows(_ env: HostedEnvironment) -> [String] {
        LayoutWidthAuditTests.overflows(in: env.window).map(\.text)
            .filter { !$0.contains("UIDimmingView") && !$0.contains("_UIRoundedRectShadowView") }
    }

    private func dump(_ v: UIView?) -> String { v.map { labels($0).joined(separator: "\n") } ?? "(keine Ansicht)" }

    // MARK: Modell

    func testModelReadsPlanStatusesAndTexts() throws {
        let p = StudyPlan(Self.plan)
        XCTAssertTrue(p.available)
        XCTAssertEqual(p.programLine, "Technische Informatik B.Sc.")
        XCTAssertEqual(p.subLine, "PO 2022 · Katalog WS 2025/26")
        XCTAssertEqual(StudyPlanText.progress(p.lpDone, p.lpTotal), "84 von 180 LP")
        XCTAssertEqual(p.semesters.count, 6)
        XCTAssertEqual(p.currentSemester?.term, "WiSe 26/27")
        XCTAssertEqual(p.semesters.map(\.overloaded), [false, false, true, false, false, false], "nur ueber 36 LP warnt")
        XCTAssertEqual(p.notes.map(\.tone), [.bad, .warn])
        let byID = Dictionary(uniqueKeysWithValues: p.modules.map { ($0.id, $0) })
        XCTAssertEqual(byID["programmieren-1"]?.status, .passed)
        XCTAssertEqual(byID["algorithmen"]?.status, .registered)
        XCTAssertEqual(byID["mathematik-1"]?.status, .failed)
        XCTAssertEqual(byID["mathematik-1-n"]?.status, .moved)
        XCTAssertEqual(byID["signale"]?.status, .open)
        XCTAssertEqual(StudyPlanText.status(try XCTUnwrap(byID["programmieren-1"])), "Bestanden · 1,7")
        XCTAssertEqual(StudyPlanText.status(try XCTUnwrap(byID["mathematik-1"])), "Nicht bestanden · Versuch 2")
        XCTAssertEqual(StudyPlanText.status(try XCTUnwrap(byID["mathematik-1-n"])), "Verschoben · aus WiSe 25/26")
        XCTAssertEqual(StudyPlanText.status(try XCTUnwrap(byID["signale"])), "Offen")
        XCTAssertEqual(StudyPlanText.accessibility(try XCTUnwrap(byID["computergrafik"])),
                       "Computergrafik I, 5 Leistungspunkte, Wahlpflicht, jedes Semester, Angemeldet")
        XCTAssertNil(StudyPlanText.turnus("unbekannt"))
        // Rohwerte in anderer Schreibweise
        XCTAssertEqual(StudyPlanStatus.from("Nicht bestanden", movedFrom: nil), .failed)
        XCTAssertEqual(StudyPlanStatus.from("BESTANDEN", movedFrom: "x"), .passed, "bestanden schlaegt verschoben")
        XCTAssertEqual(StudyPlanStatus.from("nachholen", movedFrom: nil), .moved)
        // Sprung von der Modulseite: id oder Titel (Umlaute, Gross/Klein)
        XCTAssertEqual(p.module(matching: "mathematik-1")?.id, "mathematik-1")
        XCTAssertEqual(p.module(matching: "GRUNDLAGEN DIGITALER SYSTEME")?.id, "digitale-systeme")
        XCTAssertEqual(p.module(matching: "Schlusselkompetenzen")?.id, "schluessel")
        XCTAssertNil(p.module(matching: "Kochen"))
        // Zustaende ohne Plan
        XCTAssertEqual(StudyPlan(["available": false, "reason": "no_qis"]).gap, .noQIS)
        XCTAssertEqual(StudyPlan(["available": false, "reason": "catalog_loading"]).gap, .catalogLoading)
        XCTAssertEqual(StudyPlan(["available": false, "reason": "no_catalog"]).gap, .noCatalog)
        XCTAssertEqual(StudyPlan(["available": false, "reason": "x", "message": "Kaputt"]).gap, .other("Kaputt"))
        // Katalogstatus
        let st = StudyCatalogStatus(["state": "downloading", "progress": 40])
        XCTAssertTrue(st.busy)
        XCTAssertEqual(st.progress, 0.4)
        XCTAssertEqual(st.text, "Modulkatalog wird geladen …")
        XCTAssertTrue(StudyCatalogStatus(["state": "library"]).ready)
        // Link pruefen, Quelle mit Seite
        XCTAssertNotNil(StudyPlanText.catalogURL("  https://www.uni.example/mhb.pdf "))
        XCTAssertNil(StudyPlanText.catalogURL("javascript:alert(1)"))
        XCTAssertNil(StudyPlanText.catalogURL("modulhandbuch"))
        XCTAssertEqual(StudyPlanText.sourceURL("https://modkat.example/a.pdf", page: 12)?.absoluteString, "https://modkat.example/a.pdf#page=12")
        XCTAssertNil(StudyPlanText.sourceURL("file:///etc/passwd", page: 1))
        XCTAssertEqual(StudyPlanText.recentTerms(today: Fmt.date("2026-11-04")!, count: 4), ["WiSe 26/27", "SoSe 26", "WiSe 25/26", "SoSe 25"])
        XCTAssertEqual(StudyPlanText.recentTerms(today: Fmt.date("2027-02-01")!, count: 2), ["WiSe 26/27", "SoSe 26"])
        XCTAssertEqual(StudyPlanText.lp(2.5), "2,5 LP")
        // Board quer beginnt beim Semester vor dem aktuellen bzw. vor dem gesuchten Modul
        XCTAssertNil(StudyPlanPage.boardLead(p, semesters: p.semesters, focus: nil), "3. Semester passt ohne Rollen")
        XCTAssertEqual(StudyPlanPage.boardLead(p, semesters: p.semesters, focus: "Bachelorarbeit"), "WiSe 27/28")
        XCTAssertEqual(StudyPlanPage.boardLead(p, semesters: p.semesters, focus: "Betriebssysteme"), "WiSe 26/27")
        XCTAssertNil(StudyPlanPage.boardLead(p, semesters: p.semesters, focus: "programmieren-1"))
    }

    func testModelReadsDetailAndSettingsBody() throws {
        let d = StudyModuleDetail(Self.detailMathe)
        XCTAssertEqual(d.title, "Mathematik I")
        XCTAssertEqual(d.status, .failed)
        XCTAssertTrue(d.lastAttempt)
        XCTAssertEqual(d.attempts.count, 2)
        XCTAssertEqual(d.sections.map(\.title), ["Inhalte", "Lernziele", "Literatur"])
        XCTAssertEqual(d.materials.map(\.route), [.module(3), .doc("f-12")])
        XCTAssertEqual(d.sourceURL?.absoluteString, "https://modkat.example/modkat-TIBSc22-WS_2025_26.pdf#page=12")
        let sw = StudyModuleDetail(Self.detailSoftware, titles: ["programmieren-2": "Programmieren II"])
        XCTAssertEqual(sw.prerequisites.map(\.title), ["Programmieren II", "Mathematik I"])
        XCTAssertEqual(sw.status, .moved)
        XCTAssertNil(sw.coursework)
        let s = StudyPlanSettings(Self.settings)
        XCTAssertEqual(s.chosenLP(["computergrafik", "robotik"]), 10)
        XCTAssertEqual(s.body(po: "2017", startTerm: "SoSe 26", electives: ["robotik", "computergrafik"]),
                       ["po": "2017", "start_term": "SoSe 26", "electives": ["computergrafik", "robotik"]])
        XCTAssertEqual(StudyPlanSettingsSheet.counter(5, 15), "5 von 15 LP gewählt")
        XCTAssertEqual(StudyPlanSettingsSheet.counter(5, nil), "5 LP gewählt")
    }

    /// Antworten des echten Kerns (packages/shared-contracts/fixtures/study-plan-engine/endpoints.json, gleich am
    /// PC-Server): jede Antwort laesst sich lesen, die wichtigen Felder kommen an
    func testModelReadsCoreEndpointFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("packages/shared-contracts/fixtures/study-plan-engine/endpoints.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("Fixture fehlt: \(url.path)") }
        let steps = try JSONValue.parse(data).list("steps")
        var plans = 0, details = 0, settings = 0
        for s in steps where s.i("status") == 200 {
            let r = s["response"] ?? .null
            switch (s.s("method"), s.s("path") ?? "") {
            case ("GET", "/api/study-plan"):
                let p = StudyPlan(r)
                plans += 1
                if p.available {
                    XCTAssertFalse(p.semesters.isEmpty)
                    XCTAssertGreaterThan(p.lpTotal, 0)
                    XCTAssertEqual(p.semesters.filter(\.current).count, 1, "genau ein aktuelles Semester")
                    XCTAssertFalse(p.programLine.isEmpty)
                    XCTAssertTrue(p.notes.allSatisfy { !$0.text.isEmpty })
                } else {
                    XCTAssertNotNil(p.gap)
                }
            case ("GET", let path) where path.hasPrefix("/api/study-plan/module/"):
                let d = StudyModuleDetail(r)
                details += 1
                XCTAssertFalse(d.title.isEmpty)
                XCTAssertNotNil(d.sourceURL, path)
                if path.hasSuffix("/programmieren-2") {
                    XCTAssertEqual(d.status, .failed)
                    XCTAssertEqual(d.prerequisites.map(\.title), ["Programmieren I"])
                    XCTAssertTrue(d.materials.contains { $0.kind == "file" && $0.route == .doc("f3") }, "\(d.materials)")
                    XCTAssertTrue(d.materials.contains { $0.kind == "course" && $0.route == .module(1) }, "\(d.materials)")
                    XCTAssertEqual(d.sections.count, 3)
                }
            case (_, "/api/study-plan/settings"):
                let st = StudyPlanSettings(r)
                settings += 1
                XCTAssertFalse(st.termOptions.isEmpty)
            default: break
            }
        }
        XCTAssertGreaterThan(plans, 0)
        XCTAssertGreaterThan(details, 0)
        XCTAssertGreaterThan(settings, 0)
        // ohne Katalog, QIS verbunden: "kein Katalog" mit dem Studiengang aus QIS; ohne QIS: QIS verbinden
        let withQIS = StudyPlan(["available": false, "reason": "no_catalog", "program": .null, "qis_program": "Technische Informatik (PO-Version 2017)"])
        XCTAssertEqual(withQIS.gap, .noCatalog)
        XCTAssertEqual(withQIS.programLine, "Technische Informatik (PO-Version 2017)")
        XCTAssertEqual(StudyPlan(["available": false, "reason": "no_catalog", "program": .null, "qis_program": .null]).gap, .noQIS)
        XCTAssertEqual(StudyPlan(["available": false, "reason": "no_catalog_po", "po": "2017"]).gap, .noCatalog)
    }

    // MARK: Zustaende

    func testLoadingState() throws {
        let t = transport()
        t.hangs("/api/study-plan")
        let env = try host(t)
        XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.contains(StudyPlanText.loading) } }, dump(env.view))
        XCTAssertFalse(labels(env.view).contains("Einstellungen"), "ohne Plan keine Einstellungen")
    }

    func testNoQISShowsConnectAndRoutesToServices() throws {
        let env = try host(transport(plan: ["available": false, "reason": "no_qis"]))
        XCTAssertTrue(env.wait { self.labels(env.view).contains(StudyPlanText.noQIS) }, dump(env.view))
        XCTAssertFalse(labels(env.view).contains("Einstellungen"))
        XCTAssertTrue(tap(env.view, "Zu Uni & Noten"))
        XCTAssertTrue(env.wait { env.router.route == .services })
    }

    func testCatalogSearchPollsStatusThenShowsPlan() throws {
        let t = transport(plan: ["available": false, "reason": "catalog_loading", "program": "Technische Informatik", "degree": "B.Sc.", "po": "2022"])
        t.answer("/api/study-catalog/status", ["state": "downloading", "message": "Lade modkat-TIBSc22-WS_2025_26.pdf …", "progress": 0.4])
        let env = try host(t, page: StudyPlanPage(pollInterval: 0.3))
        XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.contains("Lade modkat-TIBSc22-WS_2025_26.pdf") } }, dump(env.view))
        let l = labels(env.view)
        XCTAssertTrue(l.contains("Modulkatalog wird vorbereitet"), l.joined(separator: "\n"))
        XCTAssertTrue(l.contains { $0.contains("Technische Informatik B.Sc. · PO 2022") })
        XCTAssertEqual(find(env.view, label: "Fortschritt", exact: true)?.accessibilityValue, "40 Prozent")
        // fertig: die Seite fragt nach und zeigt den Plan
        t.answer("/api/study-plan", Self.plan)
        t.answer("/api/study-catalog/status", ["state": "library"])
        XCTAssertTrue(env.wait { self.labels(env.view).contains("84 von 180 LP") }, dump(env.view))
        XCTAssertGreaterThanOrEqual(t.count("GET", "/api/study-catalog/status"), 2)
    }

    func testCatalogErrorOffersRetry() throws {
        let t = transport(plan: ["available": false, "reason": "catalog_loading"])
        t.answer("/api/study-catalog/status", ["state": "error", "message": "Die PDF ist nicht erreichbar."])
        let env = try host(t)
        XCTAssertTrue(env.wait { self.labels(env.view).contains("Modulkatalog nicht geladen") }, dump(env.view))
        XCTAssertTrue(labels(env.view).contains { $0.contains("Die PDF ist nicht erreichbar.") })
        XCTAssertTrue(labels(env.view).contains("Erneut versuchen"))
    }

    func testNoCatalogPostsLinkWithSettings() throws {
        let t = transport(plan: ["available": false, "reason": "no_catalog", "program": "Mechatronik", "degree": "B.Sc.", "po": "2019"])
        t.answer("/api/study-catalog/status", ["state": "not_found"])
        var env = try host(t, page: StudyPlanPage(initialLink: "modulhandbuch bitte"))
        XCTAssertTrue(env.wait { self.labels(env.view).contains(StudyPlanText.noCatalog) }, dump(env.view))
        XCTAssertTrue(labels(env.view).contains { $0.contains("Mechatronik B.Sc. · PO 2019") })
        XCTAssertNotNil(find(env.view, label: StudyPlanText.linkField, exact: true), "Feld mit Namen fuer VoiceOver")
        // ungueltig: Hinweis, keine Anfrage
        XCTAssertTrue(tap(env.view, "Link speichern"))
        XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.contains(StudyPlanText.linkInvalid) } }, dump(env.view))
        XCTAssertEqual(t.count("POST", "/api/study-plan/settings"), 0)
        // gueltig: Einstellungen lesen und mit catalog_url zuruecksenden
        env = try host(t, page: StudyPlanPage(initialLink: " https://www.uni.example/mhb-mechatronik.pdf "))
        XCTAssertTrue(env.wait { self.labels(env.view).contains(StudyPlanText.noCatalog) })
        XCTAssertTrue(tap(env.view, "Link speichern"))
        XCTAssertTrue(env.wait { t.count("POST", "/api/study-plan/settings") == 1 })
        XCTAssertEqual(t.bodies("POST", "/api/study-plan/settings").last,
                       ["po": "2022", "start_term": "WiSe 25/26", "electives": ["computergrafik"],
                        "catalog_url": "https://www.uni.example/mhb-mechatronik.pdf"])
        XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.contains(StudyPlanText.linkSaved) } }, dump(env.view))
    }

    func testPOConfirmationCard() throws {
        var p = Self.plan
        p["suggested_po"] = "2022"
        p["po_confirmed"] = false
        p["qis_program"] = "Technische Informatik (PO-Version 2017)"
        let t = transport(plan: p)
        let env = try host(t)
        XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.hasPrefix("Deine Prüfungsordnung: PO 2022?") } }, dump(env.view))
        XCTAssertTrue(labels(env.view).contains { $0.contains("QIS nennt „Technische Informatik (PO-Version 2017)“") })
        XCTAssertTrue(labels(env.view).contains("Ändern"))
        XCTAssertTrue(tap(env.view, "Ja, PO 2022"))
        XCTAssertTrue(env.wait { t.count("POST", "/api/study-plan/settings") == 1 })
        XCTAssertEqual(t.bodies("POST", "/api/study-plan/settings").last?["po"], "2022")
        XCTAssertEqual(t.bodies("POST", "/api/study-plan/settings").last?["electives"], ["computergrafik"], "Rest bleibt")
        XCTAssertTrue(env.wait { t.count("GET", "/api/study-plan") >= 2 }, "Plan neu gelesen")
        // "Ändern" oeffnet die Einstellungen
        XCTAssertTrue(tap(env.view, "Ändern", exact: true))
        XCTAssertTrue(env.wait { self.sheet(env).map { self.labels($0).contains("Studienverlauf einstellen") } ?? false }, dump(sheet(env)))
    }

    // MARK: Plan

    func testBoardShowsHeaderStatusesAndCurrentTerm() throws {
        let env = try host(transport(), sidebar: true)
        XCTAssertTrue(env.wait { self.labels(env.view).contains("84 von 180 LP") }, dump(env.view))
        let l = labels(env.view)
        XCTAssertTrue(l.contains("Technische Informatik B.Sc."), l.joined(separator: "\n"))
        XCTAssertTrue(l.contains("PO 2022 · Katalog WS 2025/26"))
        XCTAssertTrue(l.contains("Hinweise: Letzter Versuch in Mathematik I, 1 Modul nachzuholen"))
        XCTAssertTrue(l.contains { $0.contains(StudyPlanText.disclaimer) })
        XCTAssertTrue(sideBySide(env.view), "quer: Board mit Spalten nebeneinander")
        // Semesterkoepfe: Fachsemester, LP, Warnung, aktuelles Semester
        XCTAssertTrue(l.contains("WiSe 25/26, 1. Fachsemester, 30 Leistungspunkte"))
        XCTAssertTrue(l.contains("WiSe 26/27, 3. Fachsemester, 40 Leistungspunkte, mehr als der Richtwert, aktuelles Semester"))
        // jeder Status
        let expected = [
            "Programmieren I, 5 Leistungspunkte, Pflicht, Wintersemester, Bestanden, 1,7",
            "Mathematik I, 10 Leistungspunkte, Pflicht, Wintersemester, Nicht bestanden, Versuch 2, letzter Versuch",
            "Algorithmen und Datenstrukturen, 5 Leistungspunkte, Pflicht, Wintersemester, Angemeldet",
            "Mathematik I, 10 Leistungspunkte, Pflicht, Wintersemester, Verschoben, aus WiSe 25/26, Nicht bestanden im 2. Versuch – nächster Termin im Wintersemester, letzter Versuch",
            "Signale und Systeme, 10 Leistungspunkte, Pflicht, Wintersemester, Offen",
            "Schlüsselkompetenzen, 5 Leistungspunkte, Wahl, Offen",
            "Bachelorarbeit, 15 Leistungspunkte, Abschluss, jedes Semester, Offen",
        ]
        for e in expected {
            // spaete Spalten liegen ausserhalb des Bildes, stehen aber im Baum
            XCTAssertTrue(l.contains(e), "fehlt: \(e)\n" + l.joined(separator: "\n"))
        }
    }

    func testFilterOpenAndPassed() throws {
        let env = try host(transport())
        XCTAssertTrue(env.wait { self.labels(env.view).contains("Offen (13)") }, dump(env.view))
        XCTAssertTrue(labels(env.view).contains("Alle (20)"))
        XCTAssertTrue(labels(env.view).contains("Bestanden (7)"))
        XCTAssertTrue(tap(env.view, "Offen (13)", exact: true))
        XCTAssertTrue(env.wait { !self.labels(env.view).contains { $0.hasPrefix("Programmieren I,") } }, dump(env.view))
        XCTAssertTrue(labels(env.view).contains { $0.hasPrefix("Signale und Systeme,") })
        XCTAssertFalse(labels(env.view).contains { $0.hasPrefix("SoSe 26,") }, "Semester ohne offene Module entfaellt")
        XCTAssertTrue(tap(env.view, "Bestanden (7)", exact: true))
        XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.hasPrefix("Programmieren I,") } })
        XCTAssertFalse(labels(env.view).contains { $0.hasPrefix("Signale und Systeme,") })
    }

    func testPortraitShowsListSections() throws {
        let env = try host(transport(), size: CGSize(width: 820, height: 1180))
        XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.hasPrefix("SoSe 26,") } }, dump(env.view))
        XCTAssertFalse(sideBySide(env.view), "hochkant: Abschnitte untereinander")
        XCTAssertTrue(labels(env.view).contains { $0.hasPrefix("Programmieren I,") })
    }

    // MARK: Moduldetail

    func testDetailSheetShowsFactsAttemptsTextsMaterialsAndSource() throws {
        let t = transport()
        let env = try host(t)
        XCTAssertTrue(env.wait { self.find(env.view, label: "Mathematik I, 10 Leistungspunkte, Pflicht, Wintersemester, Nicht") != nil }, dump(env.view))
        XCTAssertTrue(tap(env.view, "Mathematik I, 10 Leistungspunkte, Pflicht, Wintersemester, Nicht"))
        XCTAssertTrue(env.wait { self.sheet(env).map { self.labels($0).contains("Leistungspunkte: 10 LP") } ?? false }, dump(sheet(env)))
        let s = try XCTUnwrap(sheet(env))
        let l = labels(s)
        for e in ["Empfohlen: 1. Fachsemester", "Turnus: Wintersemester", "Prüfungsleistung: Klausur 120 min",
                  "Studienleistung: Übungsaufgaben (50 %)", "Sprache: Deutsch", "Arbeitsaufwand: 300 Stunden",
                  "Nicht bestanden · Versuch 2", StudyPlanText.lastAttemptWarning, "Inhalte", "Lernziele", "Literatur",
                  "Kurs, Mathematik I für Ingenieure, Stud.IP-Kurs", "Datei, Übungsblatt 4.pdf, Übungsblätter",
                  "Im Modulkatalog ansehen (S. 12)", "Schließen"] {
            XCTAssertTrue(l.contains { $0.contains(e) }, "fehlt: \(e)\n" + l.joined(separator: "\n"))
        }
        XCTAssertTrue(l.contains { $0.contains("Versuch 1") && $0.contains("WiSe 25/26") && $0.contains("5,0") }, l.joined(separator: "\n"))
        // Inhalte offen, Lernziele zu; Antippen klappt auf
        XCTAssertTrue(l.contains { $0.contains("Folgen und Reihen") })
        XCTAssertFalse(l.contains { $0.contains("rechnen sicher mit Grenzwerten") })
        XCTAssertEqual(find(s, label: "Lernziele", exact: true)?.accessibilityValue, "zugeklappt")
        XCTAssertTrue(tap(s, "Lernziele", exact: true))
        XCTAssertTrue(env.wait { self.labels(s).contains { $0.contains("rechnen sicher mit Grenzwerten") } }, dump(s))
        XCTAssertEqual(t.count("GET", "/api/study-plan/module/mathematik-1"), 1)
        // Unterlage oeffnen: Blatt zu, Seite des Kurses
        XCTAssertTrue(tap(s, "Kurs, Mathematik I für Ingenieure"))
        XCTAssertTrue(env.wait { env.router.route == .module(3) })
        XCTAssertTrue(env.wait { self.sheet(env) == nil }, "Blatt geschlossen")
    }

    func testDetailPrerequisiteChipOpensThatModuleWithBack() throws {
        let env = try host(transport())
        XCTAssertTrue(env.wait { self.find(env.view, label: "Softwaretechnik,") != nil }, dump(env.view))
        XCTAssertTrue(tap(env.view, "Softwaretechnik,"))
        XCTAssertTrue(env.wait { self.sheet(env).map { self.labels($0).contains("Voraussetzung Mathematik I") } ?? false }, dump(sheet(env)))
        let s = try XCTUnwrap(sheet(env))
        XCTAssertTrue(labels(s).contains("Voraussetzung Programmieren II"), "Titel aus dem Plan")
        XCTAssertTrue(labels(s).contains("Verschoben · aus WiSe 26/27"))
        XCTAssertTrue(labels(s).contains { $0.contains(StudyPlanText.materialsEmpty) })
        XCTAssertTrue(labels(s).contains("Studienleistung: keine"))
        XCTAssertTrue(tap(s, "Voraussetzung Mathematik I", exact: true))
        XCTAssertTrue(env.wait { self.labels(s).contains("Prüfungsleistung: Klausur 120 min") }, dump(s))
        XCTAssertTrue(labels(s).contains("Zurück"))
        XCTAssertTrue(tap(s, "Zurück", exact: true))
        XCTAssertTrue(env.wait { self.labels(s).contains("Prüfungsleistung: Klausur 90 min") }, dump(s))
        XCTAssertFalse(labels(s).contains("Zurück"))
    }

    func testFocusOpensDetailForModuleTitle() throws {
        let env = try host(transport(), page: StudyPlanPage(focus: "Mathematik I"))
        XCTAssertTrue(env.wait { self.sheet(env).map { self.labels($0).contains("Leistungspunkte: 10 LP") } ?? false }, dump(sheet(env)))
    }

    // MARK: Einstellungen

    func testSettingsSheetPostsChoices() throws {
        let t = transport()
        let env = try host(t)
        XCTAssertTrue(env.wait { self.labels(env.view).contains("Einstellungen") }, dump(env.view))
        XCTAssertTrue(tap(env.view, "Einstellungen", exact: true))
        XCTAssertTrue(env.wait { self.sheet(env).map { self.labels($0).contains("5 von 15 LP gewählt") } ?? false }, dump(sheet(env)))
        let s = try XCTUnwrap(sheet(env))
        XCTAssertTrue(labels(s).contains("PO 2017"))
        XCTAssertTrue(labels(s).contains("1 von 4 Modulen"))
        XCTAssertTrue(find(s, label: "Computergrafik I, 5 Leistungspunkte", exact: true)?.accessibilityTraits.contains(.selected) == true)
        XCTAssertTrue(tap(s, "Robotik I, 5 Leistungspunkte", exact: true))
        XCTAssertTrue(tap(s, "Eingebettete Systeme, 5 Leistungspunkte", exact: true))
        XCTAssertTrue(env.wait { self.labels(s).contains("15 von 15 LP gewählt") }, dump(s))
        XCTAssertTrue(tap(s, "Computergrafik I, 5 Leistungspunkte", exact: true))
        XCTAssertTrue(env.wait { self.labels(s).contains("10 von 15 LP gewählt") }, dump(s))
        XCTAssertTrue(tap(s, "PO 2017", exact: true))
        env.pump(0.3)
        let before = t.count("GET", "/api/study-plan")
        XCTAssertTrue(tap(s, "Speichern", exact: true))
        XCTAssertTrue(env.wait { t.count("POST", "/api/study-plan/settings") == 1 })
        XCTAssertEqual(t.bodies("POST", "/api/study-plan/settings").last,
                       ["po": "2017", "start_term": "WiSe 25/26", "electives": ["robotik", "eingebettete"]])
        XCTAssertTrue(env.wait { t.count("GET", "/api/study-plan") > before }, "Plan neu gelesen")
        XCTAssertTrue(env.wait { self.sheet(env) == nil }, "Blatt zu")
    }

    func testSettingsSaveErrorStaysOpen() throws {
        let t = transport()
        t.fail("POST /api/study-plan/settings", 500, ["detail": "Speicher voll"])
        let env = try host(t)
        XCTAssertTrue(env.wait { self.labels(env.view).contains("Einstellungen") }, dump(env.view))
        XCTAssertTrue(tap(env.view, "Einstellungen", exact: true))
        XCTAssertTrue(env.wait { self.sheet(env).map { self.labels($0).contains("5 von 15 LP gewählt") } ?? false }, dump(sheet(env)))
        let s = try XCTUnwrap(sheet(env))
        XCTAssertTrue(tap(s, "Speichern", exact: true))
        XCTAssertTrue(env.wait { self.labels(s).contains { $0.hasPrefix("Speichern fehlgeschlagen") } }, dump(s))
        XCTAssertNotNil(sheet(env), "Blatt bleibt offen")
        XCTAssertEqual(t.count("POST", "/api/study-plan/settings"), 1)
    }

    // MARK: Breite

    /// kein Element ragt bei 1180 x 820 (mit Seitenleiste) und 820 x 1180 ueber das Fenster, auch nicht mit grosser
    /// Schrift und nicht im offenen Blatt
    func testNoOverflowAt1180x820And820x1180() throws {
        var report: [String] = []
        let cases: [(CGSize, Bool, DynamicTypeSize, String)] = [
            (CGSize(width: 1180, height: 820), true, .large, "quer"),
            (CGSize(width: 820, height: 1180), false, .large, "hoch"),
            (CGSize(width: 1180, height: 820), true, .accessibility2, "quer-gross"),
            (CGSize(width: 820, height: 1180), false, .accessibility2, "hoch-gross"),
            (CGSize(width: 590, height: 820), false, .large, "split"),
        ]
        for (size, sidebar, type, name) in cases {
            var p = Self.plan
            p["suggested_po"] = "2022"
            p["po_confirmed"] = false
            p["qis_program"] = "Technische Informatik (PO-Version 2017)"
            let env = try host(transport(plan: p), size: size, sidebar: sidebar, type: type)
            XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.hasPrefix("Programmieren I,") } }, "\(name): " + dump(env.view))
            env.pump(0.5)
            let found = overflows(env)
            if !found.isEmpty { report.append("\(name): " + found.prefix(20).joined(separator: "\n  ")) }
            // Blatt mit Details
            XCTAssertTrue(tap(env.view, "Mathematik I, 10 Leistungspunkte, Pflicht, Wintersemester, Nicht"))
            XCTAssertTrue(env.wait { self.sheet(env).map { self.labels($0).contains("Leistungspunkte: 10 LP") } ?? false }, "\(name)")
            env.pump(0.6)
            let inSheet = overflows(env)
            if !inSheet.isEmpty { report.append("\(name) Blatt: " + inSheet.prefix(20).joined(separator: "\n  ")) }
            env.hosting.dismiss(animated: false)
            env.pump(0.3)
        }
        let noCatalog: JSONValue = ["available": false, "reason": "no_catalog", "program": "Wirtschaftsingenieurwesen mit Schwerpunkt Elektrotechnik",
                                    "degree": "M.Sc.", "po": "2023"]
        let noQIS: JSONValue = ["available": false, "reason": "no_qis"]
        let gaps: [(JSONValue, String)] = [(noCatalog, "kein-katalog"), (noQIS, "ohne-qis")]
        for (plan, name) in gaps {
            for size in [CGSize(width: 1180, height: 820), CGSize(width: 820, height: 1180)] {
                let env = try host(transport(plan: plan), size: size, sidebar: size.width > 1000)
                XCTAssertTrue(env.wait { self.labels(env.view).contains { $0 == StudyPlanText.noCatalog || $0 == StudyPlanText.noQIS } }, name)
                env.pump(0.3)
                let found = overflows(env)
                if !found.isEmpty { report.append("\(name) \(Int(size.width)): " + found.prefix(20).joined(separator: "\n  ")) }
            }
        }
        XCTAssertTrue(report.isEmpty, "\n" + report.joined(separator: "\n\n"))
    }

    // MARK: Bilder

    func testScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("nur mit UF_SCREENSHOT_DIR")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let land = CGSize(width: 1180, height: 820), port = CGSize(width: 820, height: 1180)

        // Plan quer und hochkant (eigene Fenster, damit Board bzw. Liste gewaehlt werden)
        var env = try host(transport(), size: land, sidebar: true)
        _ = env.wait { self.labels(env.view).contains("84 von 180 LP") }
        shoot(env, "studienverlauf-01-board", to: dir, orientation: "landscape")
        env = try host(transport(), size: port)
        _ = env.wait { self.labels(env.view).contains("84 von 180 LP") }
        shoot(env, "studienverlauf-02-liste", to: dir, orientation: "portrait")
        // Detail
        for (size, o, sidebar) in [(land, "landscape", true), (port, "portrait", false)] {
            env = try host(transport(), size: size, sidebar: sidebar)
            _ = env.wait { self.find(env.view, label: "Mathematik I, 10 Leistungspunkte, Pflicht, Wintersemester, Nicht") != nil }
            tap(env.view, "Mathematik I, 10 Leistungspunkte, Pflicht, Wintersemester, Nicht")
            _ = env.wait { self.sheet(env).map { self.labels($0).contains("Leistungspunkte: 10 LP") } ?? false }
            shoot(env, "studienverlauf-03-detail", to: dir, orientation: o)
        }
        // Einstellungen
        env = try host(transport(), size: land, sidebar: true)
        _ = env.wait { self.labels(env.view).contains("Einstellungen") }
        tap(env.view, "Einstellungen", exact: true)
        _ = env.wait { self.sheet(env).map { self.labels($0).contains("5 von 15 LP gewählt") } ?? false }
        shoot(env, "studienverlauf-04-einstellungen", to: dir, orientation: "landscape")
        // Zustaende ohne Plan, Pruefungsordnung bestaetigen
        var po = Self.plan
        po["suggested_po"] = "2022"
        po["po_confirmed"] = false
        po["qis_program"] = "Technische Informatik (PO-Version 2017)"
        let loading = transport(plan: ["available": false, "reason": "catalog_loading", "program": "Technische Informatik", "degree": "B.Sc.", "po": "2022"])
        loading.answer("/api/study-catalog/status", ["state": "downloading", "message": "Lade Modulkatalog TIBSc22 (WS 2025/26) …", "progress": 0.4])
        let states: [(Transport, String, String)] = [
            (transport(plan: po), "studienverlauf-05-po", "Deine Prüfungsordnung"),
            (transport(plan: ["available": false, "reason": "no_qis"]), "studienverlauf-06-ohne-qis", StudyPlanText.noQIS),
            (loading, "studienverlauf-07-katalog-laedt", "Lade Modulkatalog"),
            (transport(plan: ["available": false, "reason": "no_catalog", "program": "Mechatronik", "degree": "B.Sc.", "po": "2019"]),
             "studienverlauf-08-kein-katalog", StudyPlanText.noCatalog),
        ]
        for (t, name, marker) in states {
            for (size, o, sidebar) in [(land, "landscape", true), (port, "portrait", false)] {
                env = try host(t, size: size, sidebar: sidebar, page: StudyPlanPage(pollInterval: 30))
                _ = env.wait { self.labels(env.view).contains { $0.contains(marker) } }
                shoot(env, name, to: dir, orientation: o)
            }
        }
        // grosse Schrift hochkant
        env = try host(transport(), size: port, type: .accessibility2)
        _ = env.wait { self.labels(env.view).contains("84 von 180 LP") }
        shoot(env, "studienverlauf-09-gross", to: dir, orientation: "portrait")
    }

    private func png(_ window: UIWindow) -> Data {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).pngData { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func shoot(_ env: HostedEnvironment, _ name: String, to dir: URL, orientation: String) {
        env.pump(0.8)
        for (style, tone) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
            env.window.overrideUserInterfaceStyle = style
            env.pump(0.8)
            let file = dir.appendingPathComponent("\(name)-\(tone)-\(orientation).png")
            do { try png(env.window).write(to: file) } catch { XCTFail("\(file.lastPathComponent): \(error)") }
        }
        env.window.overrideUserInterfaceStyle = .unspecified
    }

    /// Quelle des Notenspiegels in den Texten (05.11.2026): QIS an der LUH, LSF an der Uni Hildesheim,
    /// Campusmanagement (HISinOne) an der HsH; an der HsH nie "QIS"
    func testGradeSourceTextsPerUniversity() {
        XCTAssertEqual(StudyPlanText.gradeSource(hildesheim: false), "QIS")
        XCTAssertEqual(StudyPlanText.gradeSource(hildesheim: true), "LSF")
        XCTAssertEqual(StudyPlanText.gradeSource(hildesheim: false, hsh: true), "Campusmanagement")
        XCTAssertEqual(StudyPlanText.gradeSourceFrom(hildesheim: true), "aus dem LSF")
        XCTAssertEqual(StudyPlanText.gradeSourceIn(hildesheim: false), "in QIS")
        XCTAssertEqual(StudyPlanText.noQIS(hildesheim: false), StudyPlanText.noQIS)
        XCTAssertEqual(StudyPlanText.noQIS(hildesheim: true), "Verbinde das LSF, damit StudiNow deinen Studiengang kennt")
        let hsh = [StudyPlanText.noQIS(hildesheim: false, hsh: true), StudyPlanText.gradeSourceFrom(hildesheim: false, hsh: true),
                   StudyPlanText.gradeSourceIn(hildesheim: false, hsh: true)]
        XCTAssertEqual(hsh, ["Melde dich im Campusmanagement an, damit StudiNow deinen Studiengang kennt", "aus dem Campusmanagement", "im Campusmanagement"])
        XCTAssertFalse(hsh.contains { $0.contains("QIS") })
    }
}
