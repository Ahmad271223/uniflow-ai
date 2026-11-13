import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Wahlbereiche und eigene Lage im Studienverlauf (Inhaber 05.11.2026, docs/STUDIENVERLAUF-2026-11-04.md): offene
/// Plaetze je Semester ("Seminare (5 LP)", "Studium Generale (4 LP)", "Schwerpunkt wählen"), Auswahl mit den erlaubten
/// Modulen, eigener Eintrag, Schwerpunkt, Stand je Bereich, Verschieben ueber das Menue/VoiceOver und durch Ziehen auf
/// dem Board, "Nicht belegen", "Zurück in den Plan", "Plan zurücksetzen", Hinweise (Turnus, Voraussetzung, ueber 36 LP)
/// und die Breitenpruefung. Plaene sind echte Antworten des Kerns (fixtures/study-plan-engine/engine.json).
@MainActor
final class StudyPlanChoiceAppTests: XCTestCase {

    typealias Transport = StudyPlanBoardAppTests.Transport

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    // MARK: Daten

    /// erwarteter Plan eines Falls aus engine.json
    private func enginePlan(_ name: String) throws -> JSONValue {
        let url = ContainerTestBed.repoURL("packages/shared-contracts/fixtures/study-plan-engine/engine.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("Fixture fehlt: \(url.path)") }
        let c = try XCTUnwrap(JSONValue.parse(data).list("cases").first { $0.s("name") == name }, name)
        return try XCTUnwrap(c["expected"])
    }

    private func transport(_ plan: JSONValue) -> Transport {
        let t = Transport()
        t.answer("/api/study-plan", plan)
        t.answer("GET /api/study-plan/settings", ["po": "2022", "po_options": ["2022"], "start_term": "WiSe 25/26",
                                                  "term_options": ["WiSe 26/27", "WiSe 25/26"], "electives": [], "elective_options": []])
        t.answer("POST /api/study-plan/settings", ["ok": true])
        t.answer("/api/study-plan/module/seminar-b", ["id": "seminar-b", "title": "Seminar Datenbanken", "lp": 5, "turnus": "SS",
                                                      "kind": "wahlpflicht", "exam": "Klausur 90 min",
                                                      "texts": ["content": "Anfragen, Transaktionen und Indexe an Beispielen."]])
        t.answer("/api/study-catalog/status", ["state": "ready"])
        t.answer("/api/exam-registration", ["supported": false, "show_card": false, "suggestions": [], "registered": []])
        return t
    }

    private func host(_ t: Transport, size: CGSize = CGSize(width: 1180, height: 820), type: DynamicTypeSize = .large,
                      page: StudyPlanPage = StudyPlanPage()) throws -> HostedEnvironment {
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: t)
        return try hostWithEnvironment(page.environment(\.dynamicTypeSize, type), api: api, size: size)
    }

    // MARK: Hilfen

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

    @discardableResult
    private func tap(_ root: UIView, _ label: String, exact: Bool = false) -> Bool {
        guard let e = find(root, label: label, exact: exact) else { return false }
        return e.accessibilityActivate()
    }

    /// benannte VoiceOver-Aktion eines Elements ausloesen (wie "Verschieben nach …" im Rotor)
    @discardableResult
    private func perform(_ root: UIView, _ label: String, action name: String) -> Bool {
        guard let e = find(root, label: label), let a = e.accessibilityCustomActions?.first(where: { $0.name == name }) else { return false }
        if let h = a.actionHandler { return h(a) }
        guard let target = a.target else { return false }
        _ = (target as AnyObject).perform(a.selector, with: a)
        return true
    }

    private func sheet(_ env: HostedEnvironment) -> UIView? {
        guard let p = env.hosting.presentedViewController, !p.isBeingDismissed else { return nil }
        return p.view
    }

    private func dump(_ v: UIView?) -> String { v.map { labels($0).joined(separator: "\n") } ?? "(keine Ansicht)" }

    private func lastPost(_ t: Transport) -> JSONValue? { t.bodies("POST", "/api/study-plan/settings").last }

    // MARK: Modell

    func testModelReadsSlotsAreasGroupsAndEditBodies() throws {
        let p = StudyPlan(try enginePlan("wahlbereiche_offen"))
        let sem5 = try XCTUnwrap(p.semesters.first { $0.term == "WiSe 27/28" })
        XCTAssertEqual(sem5.slots.map(\.title), ["Seminare", "Studium Generale", "Schwerpunkt wählen"])
        XCTAssertEqual(sem5.lpSlots, 24)
        XCTAssertEqual(StudyPlanText.slotTitle(sem5.slots[1]), "Studium Generale (4 LP)")
        XCTAssertEqual(StudyPlanText.slotLine(sem5.slots[0], plan: p), "0 von 1 Modulen gewählt")
        XCTAssertEqual(StudyPlanText.slotLine(sem5.slots[1], plan: p), "noch 4 von 4 LP offen")
        XCTAssertEqual(StudyPlanText.slotLine(sem5.slots[2], plan: p), "Eine von 3 Richtungen wählen")
        XCTAssertEqual(p.groups.first?.options, ["allgemeine-et", "schwerpunkt-robotik", "schwerpunkt-daten"])
        XCTAssertEqual(p.choices(for: sem5.slots[0]).map(\.id), ["seminar-a", "seminar-b"])
        XCTAssertEqual(Set(p.choices(for: nil).map(\.id)).count, 7)
        // Semester zum Verschieben: ab jetzt bis vier nach dem letzten (auch nach der Regelstudienzeit)
        XCTAssertEqual(p.moveTerms.first, "WiSe 26/27")
        XCTAssertEqual(p.moveTerms.last, "SoSe 30")
        XCTAssertEqual(p.fachsemester(of: "SoSe 30"), 10)
        // Rumpf je Aenderung
        let o = try XCTUnwrap(p.options.first { $0.id == "seminar-b" })
        XCTAssertEqual(StudyPlanEdit.choose(p, option: o, term: "WiSe 27/28"),
                       ["electives": ["seminar-b"], "placements": ["seminar-b": "WiSe 27/28"]])
        XCTAssertEqual(StudyPlanEdit.track(p, group: "schwerpunkt", area: "schwerpunkt-robotik"), ["tracks": ["schwerpunkt": "schwerpunkt-robotik"]])
        XCTAssertEqual(StudyPlanEdit.addCustom(p, title: " Spanisch A1 ", lp: 4, area: "studium-generale", fachsemester: 5),
                       ["custom": [["title": "Spanisch A1", "lp": 4, "area": "studium-generale", "semester": 5]]])
        XCTAssertEqual(StudyPlanEdit.reset, ["placements": .null, "excluded": .null])

        let moved = StudyPlan(try enginePlan("selbst_verschoben"))
        let rn = try XCTUnwrap(moved.modules.first { $0.id == "rechnernetze" })
        XCTAssertTrue(rn.placed)
        XCTAssertEqual(rn.hints, ["Laut Katalog nur im Sommersemester angeboten", "Voraussetzung Grundlagen der Betriebssysteme liegt nicht davor"])
        XCTAssertFalse(try XCTUnwrap(moved.modules.first { $0.id == "programmieren-1" }).movable, "Bestanden bleibt im QIS-Semester")
        XCTAssertEqual(moved.excluded.map(\.id), ["stochastik"])
        XCTAssertEqual(StudyPlanEdit.drop(moved, module: rn), ["excluded": ["stochastik", "rechnernetze"],
                                                                "placements": ["et-2": "SoSe 25", "mathematik-3": "SoSe 27", "theoretische-informatik": "WiSe 27/28"]])
        XCTAssertEqual(StudyPlanEdit.move(moved, id: "signale-systeme", to: "WiSe 26/27")["placements"]?["signale-systeme"], "WiSe 26/27")
        XCTAssertEqual(StudyPlanText.turnusWarning("SS", term: "WiSe 26/27"), "Laut Katalog nur im Sommersemester angeboten")
        XCTAssertNil(StudyPlanText.turnusWarning("WS+SS", term: "WiSe 26/27"))
        // Rueckmeldung: vorgezogen, frei im Ausgangssemester
        let from = moved.semesters.first { $0.term == "SoSe 28" }
        XCTAssertEqual(StudyPlanText.moveMessage(title: "Regelungstechnik", from: from, to: "WiSe 26/27", after: moved),
                       "Regelungstechnik vorgezogen nach WiSe 26/27 – im 6. Semester sind jetzt 7 LP frei")
        XCTAssertEqual(StudyPlanText.moveMessage(title: "Labor", from: moved.semesters.first { $0.term == "WiSe 27/28" }, to: "SoSe 28", after: moved),
                       "Labor verschoben nach SoSe 28 – im 5. Semester sind jetzt 0 LP frei")
    }

    // MARK: Plaetze und Bereiche

    func testBoardShowsSlotsAreasAndTrack() throws {
        let t = transport(try enginePlan("wahlbereiche_offen"))
        let env = try host(t)
        XCTAssertTrue(env.wait { self.find(env.view, label: "Offener Platz, Wahlpflicht: Seminare, 5 Leistungspunkte, 0 von 1 Modulen gewählt", exact: true) != nil },
                      dump(env.view))
        let l = labels(env.view)
        XCTAssertTrue(l.contains("Offener Platz, Wahlfach, Studium Generale · 4 Leistungspunkte, noch 4 von 4 LP offen"), l.joined(separator: "\n"))
        XCTAssertTrue(l.contains("Offener Platz, Schwerpunkt wählen, 15 Leistungspunkte, Eine von 3 Richtungen wählen"))
        XCTAssertTrue(l.contains("Seminare, Wahlpflicht, 0 von 5 LP · 0 von 1 Modulen"), "Stand je Bereich")
        XCTAssertTrue(l.contains("Schwerpunkt wählen"), "Gruppe im Bereichskasten")
        XCTAssertTrue(l.contains("WiSe 27/28, 5. Fachsemester, 10 Leistungspunkte, dazu 24 Leistungspunkte offene Wahl"), "Semesterkopf")
        XCTAssertTrue(l.contains("Modul hinzufügen"))
        XCTAssertFalse(l.contains("Plan zurücksetzen"), "nichts selbst verschoben")
    }

    /// Volle Bereiche (Fund 05.11.2026, INFBSc22: "Proseminar" blieb bei "noch 0 von 5 LP offen" stehen): kein Platz
    /// fuer einen gedeckten Bereich; bei LP und Zahl zeigt der Platz den offenen Teil; Bereich nur mit Zahl im Kasten
    func testFullAreaHasNoOpenSlotOnBoard() throws {
        let full = StudyPlan(try enginePlan("proseminar_bereich_voll_fachsemester"))
        XCTAssertFalse(full.semesters.flatMap(\.slots).contains { $0.area == "akademisches-arbeiten" })
        for sl in full.semesters.flatMap(\.slots) {
            XCTAssertFalse(StudyPlanText.slotLine(sl, plan: full).hasPrefix("noch 0 von"), sl.title)
        }
        let count = StudyPlan(try enginePlan("zahl_bereich_voll"))
        let labor = try XCTUnwrap(count.semesters.flatMap(\.slots).first { $0.area == "labore" })
        XCTAssertEqual(StudyPlanText.slotLine(labor, plan: count), "1 von 2 Modulen gewählt", "6 LP gedeckt, Zahl offen")
        let seminare = try XCTUnwrap(count.area("seminare"))
        XCTAssertEqual(StudyPlanText.areaProgress(seminare).value, 1)
        XCTAssertFalse(StudyPlanText.areaProgress(seminare).done, "geplant, noch nicht bestanden")
        XCTAssertFalse(StudyPlanText.areaProgress(try XCTUnwrap(count.area("labore"))).done)

        let env = try host(transport(try enginePlan("proseminar_bereich_voll_fachsemester")))
        XCTAssertTrue(env.wait { self.find(env.view, label: "Akademisches Arbeiten, Wahlpflicht, 5 von 5 LP", exact: true) != nil },
                      dump(env.view))
        let l = labels(env.view)
        XCTAssertFalse(l.contains { $0.hasPrefix("Offener Platz, Wahlpflicht: Akademisches Arbeiten") }, l.joined(separator: "\n"))
        XCTAssertTrue(l.contains("Offener Platz, Wahlpflicht: Vertiefung, 5 Leistungspunkte, noch 10 von 10 LP offen"),
                      l.joined(separator: "\n"))
        let env2 = try host(transport(try enginePlan("zahl_bereich_voll")))
        XCTAssertTrue(env2.wait { self.find(env2.view, label: "Offener Platz, Wahlpflicht: Labore, Labor · 3 Leistungspunkte, 1 von 2 Modulen gewählt",
                                            exact: true) != nil }, dump(env2.view))
        let l2 = labels(env2.view)
        XCTAssertTrue(l2.contains("Seminare, Wahlpflicht, 3 LP · 1 von 1 Modulen"), "Bereich nur mit Zahl im Kasten")
        XCTAssertFalse(l2.contains { $0.hasPrefix("Offener Platz, Wahlpflicht: Seminare") })
    }

    // MARK: Meldung des Inhabers 11.11.2026

    /// Wahl statt Pflicht: kein Wahlmodul als Pflichtkarte, je offenem Platz ein Kasten "Wahlpflicht: <Bereich>" bzw.
    /// "Wahlfach" mit "Aus der Liste wählen", der die Module des Bereichs mit LP und Turnus zeigt
    func testChoiceShowsAsBoxNotAsMandatory() throws {
        let p = StudyPlan(try enginePlan("wahl_statt_pflicht"))
        XCTAssertFalse(p.modules.contains { $0.id.hasPrefix("angebot-") || $0.id == "vertiefung-b" }, "Wahl erscheint nicht als Pflicht")
        let slot = try XCTUnwrap(p.semesters.flatMap(\.slots).first { $0.area == "vertiefung" })
        XCTAssertEqual(StudyPlanText.slotHeading(slot, plan: p), "Wahlpflicht: Vertiefung")
        XCTAssertEqual(StudyPlanText.slotButton(slot), "Aus der Liste wählen")
        XCTAssertEqual(Set(p.choices(for: slot).map(\.id)), ["vertiefung-b", "vertiefung-c", "vertiefung-d", "vertiefung-e"])
        let sg = try XCTUnwrap(StudyPlan(try enginePlan("wahlbereiche_offen")).semesters.flatMap(\.slots).first { $0.area == "studium-generale" })
        XCTAssertEqual(StudyPlanText.slotHeading(sg, plan: StudyPlan(try enginePlan("wahlbereiche_offen"))), "Wahlfach")

        let t = transport(try enginePlan("wahl_statt_pflicht"))
        let env = try host(t)
        XCTAssertTrue(env.wait { self.find(env.view, label: "Offener Platz, Wahlpflicht: Vertiefung, 5 Leistungspunkte") != nil }, dump(env.view))
        XCTAssertTrue(find(env.view, label: "Offener Platz, Wahlpflicht: Vertiefung, 5 Leistungspunkte")?.accessibilityHint?
            .hasPrefix("Aus der Liste wählen") == true, "Knopf im Kasten")
        XCTAssertFalse(labels(env.view).contains { $0.hasPrefix("Angebot 1,") }, "kein Pflichtmodul aus dem Wahlangebot")
        XCTAssertTrue(tap(env.view, "Offener Platz, Wahlpflicht: Vertiefung"))
        XCTAssertTrue(env.wait { self.sheet(env).map { self.find($0, label: "Vertiefung Compilerbau,") != nil } ?? false }, dump(sheet(env)))
        let s = try XCTUnwrap(sheet(env))
        XCTAssertTrue(labels(s).contains { $0.hasPrefix("Vertiefung Compilerbau, 5 Leistungspunkte, Wahlpflicht, Sommersemester") })
        XCTAssertTrue(labels(s).contains("Wahlpflicht: Vertiefung"), "Titel des Blatts")
        XCTAssertNil(find(s, label: "Angebot 1,"), "nur Module des Bereichs")
    }

    /// Bereits gemachtes Wahlfach aus QIS steht mit Stand im Plan und fuellt seinen Platz; der Rest bleibt "nicht zugeordnet"
    func testElectiveFromQISIsShownWithStatus() throws {
        let p = StudyPlan(try enginePlan("wahlfach_aus_qis"))
        let e = try XCTUnwrap(p.modules.first { $0.qis })
        XCTAssertEqual(e.title, "Englisch B2")
        XCTAssertEqual(e.status, .passed)
        XCTAssertFalse(e.movable, "Stand und Semester kommen aus QIS")
        XCTAssertFalse(p.semesters.flatMap(\.slots).contains { $0.area == "studium-generale" }, "Platz gefuellt")
        let env = try host(transport(try enginePlan("wahlfach_aus_qis")))
        XCTAssertTrue(env.wait { self.find(env.view, label: "Englisch B2, 4 Leistungspunkte, Wahl, Bestanden, 1,7, aus QIS, nicht im Modulkatalog",
                                          exact: true) != nil }, dump(env.view))
    }

    /// Versuche ehrlich: dritter Versuch ohne Hoechstzahl neutral, ohne Nummer aus QIS keine Nummer, letzter Versuch nur
    /// mit Grund
    func testAttemptsTextsAreNeutral() throws {
        let third = StudyPlan(try enginePlan("dritter_versuch"))
        let m1 = try XCTUnwrap(third.modules.first { $0.id == "mathematik-1" })
        XCTAssertFalse(m1.lastAttempt)
        XCTAssertEqual(StudyPlanText.status(m1), "Angemeldet · 3. Versuch")
        XCTAssertFalse(StudyPlanText.accessibility(m1).contains("letzter Versuch"))
        let ss = try XCTUnwrap(third.modules.first { $0.id == "signale-systeme" })
        XCTAssertEqual(StudyPlanText.status(ss), "Endgültig nicht bestanden")
        let bare = StudyPlan(try enginePlan("versuche_ohne_nummer"))
        XCTAssertEqual(StudyPlanText.status(try XCTUnwrap(bare.modules.first { $0.id == "mathematik-1" })), "Angemeldet",
                       "ohne Versuchsspalte keine geratene Nummer")
        XCTAssertTrue(try XCTUnwrap(bare.modules.first { $0.id == "signale-systeme" }).lastAttempt, "QIS meldet den letzten Versuch")
        let mx = StudyPlan(try enginePlan("versuche_hoechstzahl"))
        XCTAssertTrue(try XCTUnwrap(mx.modules.first { $0.id == "mathematik-1" }).lastAttempt)
        XCTAssertEqual(StudyPlanText.attemptsRule(maxAttempts: nil),
                       "Wie viele Versuche du hast, regelt deine Prüfungsordnung – StudiNow kennt die Zahl für diesen Studiengang nicht.")
        XCTAssertEqual(StudyPlanText.attemptsRule(maxAttempts: 3), "Laut Prüfungsordnung höchstens 3 Versuche.")
        let env = try host(transport(try enginePlan("dritter_versuch")))
        XCTAssertTrue(env.wait { self.find(env.view, label: "Mathematik I, 8 Leistungspunkte, Pflicht, Wintersemester, Angemeldet, 3. Versuch",
                                          exact: true) != nil }, dump(env.view))
        XCTAssertFalse(labels(env.view).contains("Letzter Versuch"))
    }

    func testSlotChooserChoosesModuleIntoSlotSemester() throws {
        let t = transport(try enginePlan("wahlbereiche_offen"))
        let env = try host(t)
        XCTAssertTrue(env.wait { self.find(env.view, label: "Offener Platz, Wahlpflicht: Seminare") != nil }, dump(env.view))
        XCTAssertTrue(tap(env.view, "Offener Platz, Wahlpflicht: Seminare"))
        XCTAssertTrue(env.wait { self.sheet(env).map { self.find($0, label: "Seminar Datenbanken,") != nil } ?? false }, dump(sheet(env)))
        let s = try XCTUnwrap(sheet(env))
        XCTAssertTrue(labels(s).contains { $0.hasPrefix("Seminar Eingebettete Systeme, 5 Leistungspunkte, Wahlpflicht, Wintersemester") })
        XCTAssertNil(find(s, label: "Robotik I,"), "nur Module des Platzes")
        XCTAssertTrue(tap(s, "Seminar Datenbanken,"))
        XCTAssertTrue(env.wait { self.labels(s).contains("Laut Katalog nur im Sommersemester angeboten") }, dump(s))
        XCTAssertTrue(env.wait { self.labels(s).contains { $0.contains("Anfragen, Transaktionen") } }, "Kurztext aus dem Detail")
        XCTAssertTrue(tap(s, "In WiSe 27/28 wählen", exact: true))
        XCTAssertTrue(env.wait { t.count("POST", "/api/study-plan/settings") == 1 })
        XCTAssertEqual(lastPost(t), ["electives": ["seminar-b"], "placements": ["seminar-b": "WiSe 27/28"]])
        XCTAssertTrue(env.wait { self.find(env.view, label: "Seminar Datenbanken eingeplant in WiSe 27/28.") != nil }, dump(env.view))
    }

    func testTrackAndCustomEntry() throws {
        let t = transport(try enginePlan("wahlbereiche_offen"))
        let env = try host(t)
        XCTAssertTrue(env.wait { self.find(env.view, label: "Offener Platz, Schwerpunkt wählen") != nil }, dump(env.view))
        XCTAssertTrue(tap(env.view, "Offener Platz, Schwerpunkt wählen"))
        XCTAssertTrue(env.wait { self.sheet(env).map { self.find($0, label: "Schwerpunkt Robotik", exact: true) != nil } ?? false }, dump(sheet(env)))
        let s = try XCTUnwrap(sheet(env))
        XCTAssertTrue(tap(s, "Schwerpunkt Robotik", exact: true))
        XCTAssertTrue(env.wait { t.count("POST", "/api/study-plan/settings") == 1 })
        XCTAssertEqual(lastPost(t), ["tracks": ["schwerpunkt": "schwerpunkt-robotik"]])
        XCTAssertTrue(env.wait { self.sheet(env) == nil })
        env.pump(0.4)
        // eigener Eintrag im Platz Studium Generale
        XCTAssertTrue(tap(env.view, "Offener Platz, Wahlfach, Studium Generale"))
        XCTAssertTrue(env.wait { self.sheet(env).map { self.find($0, label: "Titel des eigenen Eintrags") != nil } ?? false }, dump(sheet(env)))
        let c = try XCTUnwrap(sheet(env))
        env.pump(0.6)
        let c2 = try XCTUnwrap(sheet(env))
        let fields = textFields(in: c2)
        XCTAssertEqual(fields.count, 3, "Suche, Titel, LP")
        let tf = try XCTUnwrap(fields.count == 3 ? fields[1] : nil)
        _ = tf.becomeFirstResponder()
        (tf as? UIKeyInput)?.insertText("Spanisch A1")
        env.pump(0.3)
        XCTAssertTrue(tap(c, "Hinzufügen", exact: true))
        XCTAssertTrue(env.wait { t.count("POST", "/api/study-plan/settings") == 2 }, dump(c))
        XCTAssertEqual(lastPost(t), ["custom": [["title": "Spanisch A1", "lp": 5, "area": "studium-generale", "semester": 5]]])
    }

    /// Textfelder des Blatts von oben nach unten
    private func textFields(in v: UIView) -> [UIView] {
        var out: [UIView] = []
        func visit(_ x: UIView) {
            if x is UITextField || x is UITextView { out.append(x); return }
            x.subviews.forEach(visit)
        }
        visit(v)
        return out.sorted { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
    }

    // MARK: Verschieben

    func testMoveViaMenuActionShowsHintsAndConfirmation() throws {
        let plan = try enginePlan("selbst_verschoben")
        let t = transport(plan)
        t.answer("/api/study-plan", after: "POST /api/study-plan/settings", Transport.moved(plan, "signale-systeme", to: "WiSe 26/27"))
        let env = try host(t)
        let card = "Signale und Systeme, 6 Leistungspunkte, Pflicht, Wintersemester, Verschoben"
        XCTAssertTrue(env.wait { self.find(env.view, label: card) != nil }, dump(env.view))
        let l = labels(env.view)
        XCTAssertTrue(l.contains { $0.hasPrefix("Grundlagen der Rechnernetze,") && $0.contains("selbst eingeplant, Laut Katalog nur im Sommersemester angeboten") },
                      l.joined(separator: "\n"))
        XCTAssertTrue(l.contains("SoSe 27, 4. Fachsemester, 38 Leistungspunkte, mehr als der Richtwert"), "Warnung ueber 36 LP")
        XCTAssertTrue(l.contains("Plan zurücksetzen"))
        XCTAssertFalse(perform(env.view, "Programmieren I,", action: "Verschieben nach …"), "Bestanden: nicht verschiebbar")
        XCTAssertTrue(perform(env.view, card, action: "Verschieben nach …"))
        XCTAssertTrue(env.wait { self.sheet(env).map { self.find($0, label: "SoSe 27, 4. Fachsemester") != nil } ?? false }, dump(sheet(env)))
        let s = try XCTUnwrap(sheet(env))
        XCTAssertTrue(labels(s).contains("WiSe 27/28, 5. Fachsemester, aktuelle Lage"))
        XCTAssertTrue(labels(s).contains("SoSe 27, 4. Fachsemester, danach 44 Leistungspunkte, Laut Katalog nur im Wintersemester angeboten"))
        XCTAssertNotNil(find(s, label: "WiSe 30/31, 11. Fachsemester"), "auch nach der Regelstudienzeit")
        XCTAssertTrue(tap(s, "WiSe 26/27, 3. Fachsemester"))
        XCTAssertTrue(env.wait { t.count("POST", "/api/study-plan/settings") == 1 })
        XCTAssertEqual(lastPost(t)?["placements"]?["signale-systeme"], "WiSe 26/27")
        XCTAssertEqual(lastPost(t)?["placements"]?["rechnernetze"], "WiSe 26/27", "andere eigene Lagen bleiben")
        XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.contains("vorgezogen") && $0.contains("im 5. Semester sind jetzt") } }, dump(env.view))
    }

    func testMoveViaDragOnBoard() throws {
        let plan = try enginePlan("selbst_verschoben")
        let t = transport(plan)
        t.answer("/api/study-plan", after: "POST /api/study-plan/settings", Transport.moved(plan, "labor", to: "SoSe 28"))
        let hub = StudyPlanDropHub()
        let env = try host(t, page: StudyPlanPage(dropHub: hub))
        XCTAssertTrue(env.wait { self.find(env.view, label: "Labor Technische Informatik,") != nil }, dump(env.view))
        // Ablegen auf der Spalte SoSe 28 (wie nach dem Ziehen der Karte)
        var ok = false
        Task { ok = await hub.drop(["labor"], on: "SoSe 28") }
        XCTAssertTrue(env.wait { t.count("POST", "/api/study-plan/settings") == 1 })
        XCTAssertTrue(ok)
        XCTAssertEqual(lastPost(t)?["placements"]?["labor"], "SoSe 28")
        XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.hasPrefix("Labor Technische Informatik verschoben nach SoSe 28 – im 5. Semester") } },
                      dump(env.view))
        // Bestandenes und dasselbe Semester: nichts
        var none = true
        Task { none = await hub.drop(["programmieren-1"], on: "SoSe 28") }
        env.pump(0.4)
        XCTAssertFalse(none)
        XCTAssertEqual(t.count("POST", "/api/study-plan/settings"), 1)
    }

    func testDropRestoreAndResetWithConfirmation() throws {
        let t = transport(try enginePlan("selbst_verschoben"))
        let env = try host(t)
        let card = "Labor Technische Informatik,"
        XCTAssertTrue(env.wait { self.find(env.view, label: card) != nil }, dump(env.view))
        XCTAssertTrue(perform(env.view, card, action: "Nicht belegen"))
        XCTAssertTrue(env.wait { t.count("POST", "/api/study-plan/settings") == 1 })
        XCTAssertEqual(lastPost(t), ["excluded": ["stochastik", "labor"]])
        // ausgeschlossenes Modul zurueck in den Plan
        XCTAssertTrue(tap(env.view, "Stochastik für Ingenieure zurück in den Plan", exact: true))
        XCTAssertTrue(env.wait { t.count("POST", "/api/study-plan/settings") == 2 })
        XCTAssertEqual(lastPost(t), ["excluded": []])
        // Ins empfohlene Semester
        XCTAssertTrue(perform(env.view, "Grundlagen der Rechnernetze,", action: "Ins empfohlene Semester"))
        XCTAssertTrue(env.wait { t.count("POST", "/api/study-plan/settings") == 3 })
        XCTAssertNil(lastPost(t)?["placements"]?["rechnernetze"])
        // Plan zuruecksetzen mit Rueckfrage
        XCTAssertTrue(tap(env.view, "Plan zurücksetzen", exact: true))
        XCTAssertTrue(env.wait { self.sheet(env).map { self.find($0, label: "Zurücksetzen", exact: true) != nil } ?? false }, dump(sheet(env)))
        XCTAssertEqual(t.count("POST", "/api/study-plan/settings"), 3, "erst nach Bestaetigung")
        XCTAssertTrue(tap(try XCTUnwrap(sheet(env)), "Zurücksetzen", exact: true))
        XCTAssertTrue(env.wait { t.count("POST", "/api/study-plan/settings") == 4 }, dump(sheet(env)))
        XCTAssertEqual(lastPost(t), ["placements": .null, "excluded": .null])
    }

    func testDetailOffersMoveAndDrop() throws {
        let t = transport(try enginePlan("selbst_verschoben"))
        t.answer("/api/study-plan/module/rechnernetze", ["id": "rechnernetze", "title": "Grundlagen der Rechnernetze", "lp": 5, "turnus": "SS",
                                                         "kind": "pflicht", "own": ["status": "offen"]])
        let env = try host(t)
        XCTAssertTrue(env.wait { self.find(env.view, label: "Grundlagen der Rechnernetze,") != nil }, dump(env.view))
        XCTAssertTrue(tap(env.view, "Grundlagen der Rechnernetze,"))
        XCTAssertTrue(env.wait { self.sheet(env).map { self.find($0, label: "Verschieben nach …", exact: true) != nil } ?? false }, dump(sheet(env)))
        let s = try XCTUnwrap(sheet(env))
        XCTAssertTrue(labels(s).contains("Ins empfohlene Semester"))
        XCTAssertTrue(labels(s).contains("Nicht belegen"))
        XCTAssertTrue(tap(s, "Verschieben nach …", exact: true))
        XCTAssertTrue(env.wait { self.sheet(env).map { self.find($0, label: "SoSe 27, 4. Fachsemester") != nil } ?? false }, dump(sheet(env)))
    }

    // MARK: Tauschen

    func testReplaceChosenElectiveWithAnotherOfItsArea() throws {
        let t = transport(try enginePlan("schwerpunkt_gewaehlt"))
        let env = try host(t)
        let card = "Robotik I, 5 Leistungspunkte, Wahlpflicht"
        XCTAssertTrue(env.wait { self.find(env.view, label: card) != nil }, dump(env.view))
        XCTAssertTrue(labels(env.view).contains { $0.hasPrefix("Schwerpunkt Robotik, Wahlpflicht, 15 von 15 LP") }, dump(env.view))
        XCTAssertTrue(perform(env.view, card, action: "Anderes Modul wählen"))
        XCTAssertTrue(env.wait { self.sheet(env).map { self.find($0, label: "Robotik II,") != nil } ?? false }, dump(sheet(env)))
        let s = try XCTUnwrap(sheet(env))
        XCTAssertNil(find(s, label: "Seminar Eingebettete Systeme,"), "nur Module der Bereiche des alten Moduls")
        XCTAssertTrue(tap(s, "Robotik II,"))
        XCTAssertTrue(env.wait { self.find(s, label: "In WiSe 27/28 wählen", exact: true) != nil }, dump(s))
        XCTAssertTrue(tap(s, "In WiSe 27/28 wählen", exact: true))
        XCTAssertTrue(env.wait { t.count("POST", "/api/study-plan/settings") == 1 })
        XCTAssertEqual(lastPost(t), ["electives": ["seminar-b", "ki", "robotik-2"], "placements": ["robotik-2": "WiSe 27/28"]])
    }

    // MARK: Gesamtansicht

    func testOverviewShowsEverythingAtOnceAndKeepsMoving() throws {
        UserDefaults.standard.set(false, forKey: "studyplan.overview")
        defer { UserDefaults.standard.set(false, forKey: "studyplan.overview") }
        for size in [CGSize(width: 1180, height: 820), CGSize(width: 820, height: 1180)] {
            let t = transport(try enginePlan("selbst_verschoben"))
            let hub = StudyPlanDropHub()
            let env = try host(t, size: size, page: StudyPlanPage(dropHub: hub))
            XCTAssertTrue(env.wait { self.find(env.view, label: "Gesamtansicht", exact: true) != nil }, dump(env.view))
            if UserDefaults.standard.bool(forKey: "studyplan.overview") == false {
                XCTAssertTrue(tap(env.view, "Gesamtansicht", exact: true))
            }
            XCTAssertTrue(env.wait { !self.labels(env.view).contains("Bereiche und Wahl") && self.find(env.view, label: "Labor Technische Informatik,") != nil },
                          dump(env.view))
            env.pump(0.5)
            XCTAssertTrue(UserDefaults.standard.bool(forKey: "studyplan.overview"), "Wahl gemerkt")
            // alle Module und Plaetze sichtbar, nichts unter dem Fensterrand
            let plan = StudyPlan(try enginePlan("selbst_verschoben"))
            let bounds = env.window.bounds
            for m in plan.modules {
                let e = try XCTUnwrap(find(env.view, label: m.title + ","), "\(m.id) fehlt")
                XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(e.accessibilityFrame), "\(size) \(m.id): \(e.accessibilityFrame)")
            }
            XCTAssertEqual(plan.semesters.filter { s in self.find(env.view, label: s.term + ",") != nil }.count, plan.semesters.count)
            let found = LayoutWidthAuditTests.overflows(in: env.window).map(\.text)
            XCTAssertTrue(found.isEmpty, "\(size): " + found.prefix(10).joined(separator: "\n"))
            // Verschieben in der Gesamtansicht (Ablegen) und Detail per Tippen
            Task { await hub.drop(["labor"], on: "SoSe 28") }
            XCTAssertTrue(env.wait { t.count("POST", "/api/study-plan/settings") == 1 })
            XCTAssertEqual(lastPost(t)?["placements"]?["labor"], "SoSe 28")
            XCTAssertTrue(tap(env.view, "Grundlagen der Rechnernetze,"))
            XCTAssertTrue(env.wait { self.sheet(env) != nil })
            env.hosting.dismiss(animated: false)
            env.pump(0.3)
        }
    }

    // MARK: Breite

    func testNoOverflowWithSlotsAndSheets() throws {
        var report: [String] = []
        let cases: [(CGSize, DynamicTypeSize, String)] = [
            (CGSize(width: 1180, height: 820), .large, "quer"), (CGSize(width: 820, height: 1180), .large, "hoch"),
            (CGSize(width: 1180, height: 820), .accessibility2, "quer-gross"), (CGSize(width: 820, height: 1180), .accessibility2, "hoch-gross"),
        ]
        for (size, type, name) in cases {
            let env = try host(transport(try enginePlan("wahlbereiche_offen")), size: size, type: type)
            XCTAssertTrue(env.wait { self.find(env.view, label: "Offener Platz, Wahlpflicht: Seminare") != nil }, "\(name): " + dump(env.view))
            env.pump(0.5)
            let found = LayoutWidthAuditTests.overflows(in: env.window).map(\.text)
            if !found.isEmpty { report.append("\(name): " + found.prefix(15).joined(separator: "\n  ")) }
            XCTAssertTrue(tap(env.view, "Offener Platz, Wahlpflicht: Seminare"))
            XCTAssertTrue(env.wait { self.sheet(env).map { self.find($0, label: "Seminar Datenbanken,") != nil } ?? false }, name)
            env.pump(0.6)
            let inSheet = LayoutWidthAuditTests.overflows(in: env.window).map(\.text)
                .filter { !$0.contains("UIDimmingView") && !$0.contains("_UIRoundedRectShadowView")
                && !$0.contains("UIDropShadowRimPartView") }   // Schattenrand des Blatts auf dem Mac (Systemrahmen)
            if !inSheet.isEmpty { report.append("\(name) Auswahl: " + inSheet.prefix(15).joined(separator: "\n  ")) }
            env.hosting.dismiss(animated: false)
            env.pump(0.3)
        }
        XCTAssertTrue(report.isEmpty, "\n" + report.joined(separator: "\n\n"))
    }
}
