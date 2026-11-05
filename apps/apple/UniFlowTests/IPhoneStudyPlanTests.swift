import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Studienverlauf auf dem iPhone (docs/IPHONE-2026-11-04.md, docs/STUDIENVERLAUF-2026-11-04.md): Semesterliste mit
/// offenen Plaetzen, Auswahl als Blatt von unten (halb/ganz), "Verschieben nach …" aus dem Blatt "Moduldetails" und
/// ueber die VoiceOver-Aktion (ebenfalls Blatt von unten), Gesamtansicht mit allen Semestern auf einem Bildschirm
/// (Inhaber 05.11.2026: "alles auf einmal sehen auch auf dem Handy") bei 390, 402 und 440 pt, Tippen oeffnet das
/// Detail, Ablegen verschiebt. Gegenprobe: iPad hochkant behaelt zwei Reihen. Plaene sind echte Antworten des Kerns
/// (fixtures/study-plan-engine/engine.json), Schein-Transport, kein Netz.
final class IPhoneStudyPlanTests: IPhoneLearnTestCase {

    typealias Transport = StudyPlanBoardAppTests.Transport

    override func setUp() {
        super.setUp()
        let before = UserDefaults.standard.object(forKey: "studyplan.overview")
        UserDefaults.standard.set(false, forKey: "studyplan.overview")
        addTeardownBlock { UserDefaults.standard.set(before, forKey: "studyplan.overview") }
    }

    // MARK: Daten

    private func enginePlan(_ name: String) throws -> JSONValue {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("packages/shared-contracts/fixtures/study-plan-engine/engine.json")
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
        t.answer("/api/study-plan/module/rechnernetze", ["id": "rechnernetze", "title": "Grundlagen der Rechnernetze", "lp": 5,
                                                         "turnus": "SS", "kind": "pflicht", "own": ["status": "offen"]])
        t.answer("/api/study-catalog/status", ["state": "ready"])
        t.answer("/api/exam-registration", ["supported": false, "show_card": false, "suggestions": [], "registered": []])
        return t
    }

    private func api(_ t: Transport) -> APIClient { APIClient(base: URL(string: "http://erfunden.test/")!, transport: t) }

    private func lastPost(_ t: Transport) -> JSONValue? { t.bodies("POST", "/api/study-plan/settings").last }

    /// oberstes Blatt und seine Lage im Fenster
    private func sheetFrame(_ env: HostedEnvironment) -> CGRect {
        guard let p = env.hosting.presentedViewController, !p.isBeingDismissed,
              let v = p.presentationController?.presentedView ?? p.view else { return .null }
        return v.convert(v.bounds, to: nil)
    }

    /// Elemente nur im offenen Blatt (die Seite darunter hat Kopfzeilen mit denselben Semesternamen)
    private func inSheet(_ env: HostedEnvironment) -> [NSObject] {
        guard let p = env.hosting.presentedViewController, !p.isBeingDismissed, let root = p.view else { return [] }
        root.layoutIfNeeded()
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: Any, depth: Int) {
            guard depth < 80 else { return }
            if let o = element as? NSObject {
                guard seen.insert(ObjectIdentifier(o)).inserted else { return }
                if o.accessibilityLabel?.isEmpty == false { out.append(o) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 600) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } } }
            }
            if let v = element as? UIView, !v.isHidden { for sub in v.subviews { visit(sub, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return out
    }

    private func sheetElement(_ env: HostedEnvironment, _ label: String) -> NSObject? {
        inSheet(env).first { ($0.accessibilityLabel ?? "").hasPrefix(label) }
    }

    @discardableResult
    private func tapInSheet(_ env: HostedEnvironment, _ label: String) -> Bool {
        guard let e = sheetElement(env, label), e.accessibilityActivate() else { return false }
        env.pump(0.2)
        return true
    }

    private func sheetDump(_ env: HostedEnvironment) -> String { inSheet(env).compactMap(\.accessibilityLabel).joined(separator: " | ") }

    private func perform(_ env: HostedEnvironment, _ label: String, action name: String) -> Bool {
        guard let e = element(env, label: label, prefix: true),
              let a = e.accessibilityCustomActions?.first(where: { $0.name == name }) else { return false }
        if let h = a.actionHandler { return h(a) }
        return false
    }

    // MARK: Liste mit Plaetzen und Auswahl

    /// Hochkant und quer: Semesterliste (nie Spalten), offene Plaetze antippbar; die Auswahl kommt als Blatt von unten
    /// halb hoch, waehlt in das Semester des Platzes; nichts ragt ueber den Rand
    func testListWithSlotsAndChooserAsBottomSheet() throws {
        let t = transport(try enginePlan("wahlbereiche_offen"))
        let env = try hostPhone(StudyPlanPage(), api: api(t))
        XCTAssertTrue(env.wait(timeout: 15) { self.element(env, label: "Offener Platz, Seminare", prefix: true) != nil }, dump(env))
        // Semesterliste: die Semester stehen untereinander (kein Board mit Spalten)
        let a = try XCTUnwrap(element(env, label: "WiSe 25/26,", prefix: true), dump(env))
        let b = try XCTUnwrap(element(env, label: "SoSe 26,", prefix: true), dump(env))
        XCTAssertEqual(frame(a).minX, frame(b).minX, accuracy: 1, "untereinander")
        XCTAssertGreaterThan(frame(b).minY, frame(a).maxY)
        XCTAssertNotNil(element(env, label: "Gesamtansicht"), "Umschalter da")
        assertFitsOnAllPhones(env, "Studienverlauf mit Plätzen")
        shoot(env, "iphone-studienverlauf-plaetze")

        XCTAssertTrue(tap(env, "Offener Platz, Seminare", prefix: true))
        XCTAssertTrue(env.wait(timeout: 10) { self.sheetElement(env, "Seminar Datenbanken,") != nil }, sheetDump(env))
        env.pump(0.6)
        let f = sheetFrame(env)
        XCTAssertGreaterThan(f.minY, env.window.bounds.height * 0.3, "Blatt von unten, halb hoch: \(f)")
        assertFits(env, "Auswahl")
        shoot(env, "iphone-studienverlauf-auswahl")
        XCTAssertTrue(tapInSheet(env, "Seminar Datenbanken,"))
        XCTAssertTrue(env.wait { self.inSheet(env).contains { ($0.accessibilityLabel ?? "").hasPrefix("In ") && ($0.accessibilityLabel ?? "").hasSuffix(" wählen") } },
                      sheetDump(env))
        let choose = try XCTUnwrap(inSheet(env).first { ($0.accessibilityLabel ?? "").hasPrefix("In ") && ($0.accessibilityLabel ?? "").hasSuffix(" wählen") })
        XCTAssertTrue(choose.accessibilityActivate())
        XCTAssertTrue(env.wait { t.count("POST", "/api/study-plan/settings") == 1 })
        XCTAssertTrue(lastPost(t)?["electives"]?.array?.contains("seminar-b") == true, "\(String(describing: lastPost(t)))")
    }

    // MARK: Verschieben

    /// "Verschieben nach …" aus dem Blatt "Moduldetails": danach das Blatt mit den Semestern (von unten, auch nach
    /// der Regelstudienzeit), Antippen verschiebt
    func testMoveFromModuleSheet() throws {
        let t = transport(try enginePlan("selbst_verschoben"))
        let env = try hostPhone(StudyPlanPage(), api: api(t))
        XCTAssertTrue(env.wait(timeout: 15) { self.element(env, label: "Grundlagen der Rechnernetze,", prefix: true) != nil }, dump(env))
        XCTAssertTrue(tap(env, "Grundlagen der Rechnernetze,", prefix: true))
        XCTAssertTrue(env.wait(timeout: 10) { self.sheetElement(env, "Verschieben nach …") != nil }, sheetDump(env))
        env.pump(0.4)
        assertFits(env, "Moduldetails")
        XCTAssertTrue(tapInSheet(env, "Verschieben nach …"))
        XCTAssertTrue(env.wait(timeout: 10) { self.sheetElement(env, "SoSe 27, 4. Fachsemester") != nil }, sheetDump(env))
        env.pump(0.6)
        XCTAssertGreaterThan(sheetFrame(env).minY, env.window.bounds.height * 0.3, "Blatt von unten: \(sheetFrame(env))")
        XCTAssertNotNil(sheetElement(env, "WiSe 30/31, 11. Fachsemester"), "auch nach der Regelstudienzeit")
        assertFits(env, "Verschieben nach")
        shoot(env, "iphone-studienverlauf-verschieben")
        XCTAssertNotNil(sheetElement(env, "WiSe 26/27, 3. Fachsemester, aktuelle Lage"), "hier liegt es jetzt")
        XCTAssertTrue(tapInSheet(env, "SoSe 28"))
        XCTAssertTrue(env.wait { t.count("POST", "/api/study-plan/settings") == 1 })
        XCTAssertEqual(lastPost(t)?["placements"]?["rechnernetze"], "SoSe 28")
    }

    /// VoiceOver-Aktion (wie das Menue der Karte): "Verschieben nach …" oeffnet dasselbe Blatt
    func testMoveViaCardAction() throws {
        let t = transport(try enginePlan("selbst_verschoben"))
        let env = try hostPhone(StudyPlanPage(), api: api(t))
        let card = "Signale und Systeme, 6 Leistungspunkte"
        XCTAssertTrue(env.wait(timeout: 15) { self.element(env, label: card, prefix: true) != nil }, dump(env))
        XCTAssertTrue(perform(env, card, action: "Verschieben nach …"))
        XCTAssertTrue(env.wait(timeout: 10) { self.sheetElement(env, "SoSe 27, 4. Fachsemester") != nil }, sheetDump(env))
        XCTAssertTrue(tapInSheet(env, "SoSe 28"))
        XCTAssertTrue(env.wait { t.count("POST", "/api/study-plan/settings") == 1 })
        XCTAssertEqual(lastPost(t)?["placements"]?["signale-systeme"], "SoSe 28")
    }

    // MARK: Gesamtansicht

    /// Alle Semester auf einem Bildschirm: jedes Modul und jedes Semester sichtbar, nichts unter dem unteren oder
    /// ueber dem seitlichen Rand, Chips mindestens 14 pt hoch und Spalten mindestens 60 pt breit; Tippen oeffnet das
    /// Detail als Blatt, Ablegen auf ein anderes Semester verschiebt
    func testOverviewShowsAllSemestersOnOneScreen() throws {
        for name in ["selbst_verschoben", "namensvarianten"] {
            for size in [Self.phoneSmall, Self.phone, Self.phoneMax] {
                UserDefaults.standard.set(true, forKey: "studyplan.overview")
                let t = transport(try enginePlan(name))
                let hub = StudyPlanDropHub()
                let env = try hostPhone(StudyPlanPage(dropHub: hub), api: api(t), size: size)
                let plan = StudyPlan(try enginePlan(name))
                let first = try XCTUnwrap(plan.modules.first)
                XCTAssertTrue(env.wait(timeout: 15) { self.element(env, label: first.title + ",", prefix: true) != nil && !self.shows(env, "Bereiche und Wahl") },
                              "\(name) \(size): " + dump(env))
                env.pump(0.6)
                let bounds = env.window.bounds.insetBy(dx: -1, dy: -1)
                for m in plan.modules {
                    let e = try XCTUnwrap(element(env, label: m.title + ",", prefix: true), "\(name) \(size): \(m.id) fehlt")
                    XCTAssertTrue(bounds.contains(frame(e)), "\(name) \(size) \(m.id): \(frame(e))")
                    XCTAssertGreaterThanOrEqual(frame(e).height, 14, "\(name) \(size) \(m.id)")
                }
                for s in plan.semesters {
                    let col = try XCTUnwrap(element(env, label: s.term + ",", prefix: true), "\(name) \(size): \(s.term) fehlt")
                    XCTAssertTrue(bounds.contains(frame(col)), "\(name) \(size) \(s.term): \(frame(col))")
                    XCTAssertGreaterThanOrEqual(frame(col).width, 52)
                }
                assertFits(env, "Gesamtansicht \(name) @ \(Int(size.width))")
                if size == Self.phone { shoot(env, "iphone-studienverlauf-gesamt-\(name)") }
                // Tippen: Detail
                XCTAssertTrue(tap(env, first.title + ",", prefix: true), dump(env))
                XCTAssertTrue(env.wait(timeout: 10) { self.sheetOpen(env) }, "\(name) \(size): Detail")
                dismissSheet(env)
                if name == "selbst_verschoben" && size == Self.phone {
                    Task { await hub.drop(["labor"], on: "SoSe 28") }
                    XCTAssertTrue(env.wait { t.count("POST", "/api/study-plan/settings") == 1 })
                    XCTAssertEqual(lastPost(t)?["placements"]?["labor"], "SoSe 28")
                }
            }
        }
    }

    /// Reihen der Gesamtansicht: iPhone hochkant mehrere Reihen nach Platz, iPad unveraendert (quer eine, hochkant zwei)
    func testOverviewRowsPerDevice() throws {
        let plan = StudyPlan(try enginePlan("namensvarianten"))
        func rows(_ size: CGSize, compact: Bool) -> Int {
            StudyPlanOverview(plan: plan, semesters: plan.semesters, size: size, compact: compact) { _ in }.rows
        }
        XCTAssertEqual(rows(CGSize(width: 1128, height: 600), compact: false), 1, "iPad quer")
        XCTAssertEqual(rows(CGSize(width: 768, height: 960), compact: false), 2, "iPad hochkant")
        XCTAssertEqual(rows(CGSize(width: 820, height: 300), compact: true), 1, "iPhone quer")
        for w in [358.0, 370, 408] {
            let r = rows(CGSize(width: w, height: 620), compact: true)
            XCTAssertTrue((2...4).contains(r), "iPhone hochkant \(w): \(r)")
            let m = StudyPlanOverview.metrics(plan.semesters, size: CGSize(width: w, height: 620), rows: r)
            XCTAssertGreaterThanOrEqual(m.column, 80, "Spalte lesbar bei \(w)")
            XCTAssertGreaterThanOrEqual(m.chip, 18, "Chip antippbar bei \(w)")
        }
    }
}
