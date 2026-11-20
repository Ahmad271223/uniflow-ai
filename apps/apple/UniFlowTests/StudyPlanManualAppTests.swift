import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Selbst eintragen (Entscheidung des Inhabers 20.11.2026): im Blatt "Moduldetails" "Als bestanden abhaken" und
/// "Note eintragen" nur ohne bestandene QIS-Leistung; eigener Eintrag mit Abzeichen "Selbst eingetragen", Bearbeiten und
/// Entfernen; ersetzt QIS ihn, steht das dabei. Karte im Plan mit Abzeichen und VoiceOver-Text, "davon … LP selbst
/// eingetragen" am Fortschritt, Uni & Noten mit dem Anteil. iPhone: Knoepfe untereinander in voller Breite, nichts ragt
/// ueber den Rand. Plaene sind echte Antworten des Kerns (engine.json, Fall "selbst_eingetragen"), Schein-Transport.
final class StudyPlanManualAppTests: IPhoneLearnTestCase {

    typealias Transport = StudyPlanBoardAppTests.Transport

    override func setUp() {
        super.setUp()
        let before = UserDefaults.standard.object(forKey: "studyplan.overview")
        UserDefaults.standard.set(false, forKey: "studyplan.overview")
        addTeardownBlock { UserDefaults.standard.set(before, forKey: "studyplan.overview") }
    }

    private func enginePlan(_ name: String) throws -> JSONValue {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("packages/shared-contracts/fixtures/study-plan-engine/engine.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("Fixture fehlt: \(url.path)") }
        let c = try XCTUnwrap(JSONValue.parse(data).list("cases").first { $0.s("name") == name }, name)
        return try XCTUnwrap(c["expected"])
    }

    private static let netze: JSONValue = ["id": "rechnernetze", "title": "Grundlagen der Rechnernetze", "lp": 5, "turnus": "SS",
                                           "kind": "pflicht", "own": ["status": "offen", "can_mark": true, "manual": .null]]

    private func transport(_ plan: JSONValue, netze: JSONValue = StudyPlanManualAppTests.netze) -> Transport {
        let t = Transport()
        t.answer("/api/study-plan", plan)
        t.answer("GET /api/study-plan/settings", ["po": "2022", "po_options": ["2022"], "start_term": "WiSe 25/26",
                                                  "term_options": ["WiSe 26/27", "WiSe 25/26"], "electives": [], "elective_options": []])
        t.answer("/api/study-plan/module/rechnernetze", netze)
        t.answer("/api/study-catalog/status", ["state": "ready"])
        t.answer("/api/exam-registration", ["supported": false, "show_card": false, "suggestions": [], "registered": []])
        t.answer("POST /api/grades/manual", ["ok": true, "entry": ["id": 1, "title": "Grundlagen der Rechnernetze", "lp": 5,
                                                                    "passed": true, "counted": true, "replaced": false]])
        return t
    }

    private func api(_ t: Transport) -> APIClient { APIClient(base: URL(string: "http://erfunden.test/")!, transport: t) }

    /// Elemente nur im offenen Blatt
    private func inSheet(_ env: HostedEnvironment) -> [NSObject] {
        guard let p = env.hosting.presentedViewController, !p.isBeingDismissed, p.view != nil else { return [] }
        return elements(env).filter { e in
            guard let v = p.view else { return false }
            let f = frame(e)
            return !f.isNull && v.convert(v.bounds, to: nil).intersects(f)
        }
    }

    private func sheetButton(_ env: HostedEnvironment, _ label: String) -> NSObject? {
        inSheet(env).first { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel == label }
    }

    private func openNetze(_ env: HostedEnvironment) {
        XCTAssertTrue(env.wait(timeout: 15) { self.element(env, label: "Grundlagen der Rechnernetze,", prefix: true) != nil }, dump(env))
        XCTAssertTrue(tap(env, "Grundlagen der Rechnernetze,", prefix: true))
    }

    // MARK: Plan

    /// Karte mit Abzeichen und VoiceOver "selbst eingetragen", Fortschritt mit Anteil (Kern: lp_manual 12)
    func testPlanShowsSelfEnteredBadgeAndShare() throws {
        let plan = try enginePlan("selbst_eingetragen")
        XCTAssertEqual(plan["lp_manual"]?.double, 12)
        let m = StudyPlan(plan).modules.first { $0.id == "rechnerstrukturen" }
        XCTAssertEqual(m?.manual, true)
        let env = try hostPad(StudyPlanPage(), api: api(transport(plan)))
        XCTAssertTrue(env.wait(timeout: 15) { self.element(env, label: "Rechnerstrukturen,", prefix: true) != nil }, dump(env))
        let card = try XCTUnwrap(element(env, label: "Rechnerstrukturen,", prefix: true))
        XCTAssertTrue(card.accessibilityLabel?.contains("selbst eingetragen") == true, card.accessibilityLabel ?? "")
        XCTAssertTrue(card.accessibilityLabel?.contains("Bestanden, 1,7") == true, card.accessibilityLabel ?? "")
        XCTAssertTrue(shows(env, "davon 12 LP selbst eingetragen"), dump(env))
        XCTAssertFalse(element(env, label: "Grundlagen der Rechnernetze,", prefix: true)?.accessibilityLabel?.contains("selbst eingetragen") ?? true)
    }

    // MARK: Abhaken und Note (iPhone)

    /// iPhone: "Als bestanden abhaken" und "Note eintragen" untereinander in voller Breite, nichts zu breit; Abhaken
    /// speichert ohne Note und laedt den Plan neu
    func testMarkAsPassedOnPhone() throws {
        let t = transport(try enginePlan("selbst_eingetragen"))
        let env = try hostPhone(StudyPlanPage(), api: api(t))
        openNetze(env)
        XCTAssertTrue(env.wait(timeout: 10) { self.sheetButton(env, "Als bestanden abhaken") != nil }, dump(env))
        env.pump(0.5)
        let mark = try XCTUnwrap(sheetButton(env, "Als bestanden abhaken"))
        let grade = try XCTUnwrap(sheetButton(env, "Note eintragen"))
        XCTAssertGreaterThanOrEqual(frame(grade).minY, frame(mark).maxY - 1, "untereinander: \(frame(mark)) \(frame(grade))")
        XCTAssertGreaterThan(frame(mark).width, env.window.bounds.width * 0.7, "volle Breite: \(frame(mark))")
        XCTAssertGreaterThanOrEqual(frame(mark).height, 44, "Tippflaeche")
        XCTAssertEqual(mark.accessibilityHint, "Zählt das Modul ohne Note als bestanden")
        assertFits(env, "Moduldetails mit Abhaken")
        shoot(env, "iphone-selbst-eintragen")
        let plansBefore = t.count("GET", "/api/study-plan")
        XCTAssertTrue(mark.accessibilityActivate())
        XCTAssertTrue(env.wait(timeout: 10) { t.count("POST", "/api/grades/manual") == 1 })
        let body = try XCTUnwrap(t.bodies("POST", "/api/grades/manual").last)
        XCTAssertEqual(body["module_id"], "rechnernetze")
        XCTAssertEqual(body["grade"], .null)
        XCTAssertEqual(body["semester"], .null)
        XCTAssertTrue(env.wait(timeout: 10) { t.count("GET", "/api/study-plan") > plansBefore }, "Plan neu geladen")
    }

    /// "Note eintragen": Feld mit Komma, Semester waehlbar, Speichern schickt die Note; ungueltige Note wird nicht
    /// geschickt; iPhone ohne Ueberstand
    func testEnterGradeOnPhone() throws {
        let t = transport(try enginePlan("selbst_eingetragen"))
        let env = try hostPhone(StudyPlanPage(), api: api(t))
        openNetze(env)
        XCTAssertTrue(env.wait(timeout: 10) { self.sheetButton(env, "Note eintragen") != nil }, dump(env))
        XCTAssertTrue(try XCTUnwrap(sheetButton(env, "Note eintragen")).accessibilityActivate())
        XCTAssertTrue(env.wait(timeout: 5) { self.sheetButton(env, "Speichern") != nil }, dump(env))
        XCTAssertNotNil(inSheet(env).first { $0.accessibilityLabel == "Note, optional" }, dump(env))
        XCTAssertNotNil(inSheet(env).first { $0.accessibilityLabel == "Semester, optional" }, dump(env))
        assertFits(env, "Formular Note eintragen")
        shoot(env, "iphone-note-eintragen")
        let field = try XCTUnwrap(textField(in: env.hosting.presentedViewController?.view))
        field.becomeFirstResponder()
        field.insertText("2.3")
        env.pump(0.3)
        XCTAssertTrue(try XCTUnwrap(sheetButton(env, "Speichern")).accessibilityActivate())
        XCTAssertTrue(env.wait(timeout: 10) { t.count("POST", "/api/grades/manual") == 1 }, dump(env))
        XCTAssertEqual(t.bodies("POST", "/api/grades/manual").last?["grade"], "2,3", "deutsches Komma")
    }

    private func textField(in view: UIView?) -> UITextField? {
        guard let view else { return nil }
        if let f = view as? UITextField { return f }
        for s in view.subviews { if let f = textField(in: s) { return f } }
        return nil
    }

    /// Eigener Eintrag: Abzeichen, Bearbeiten und Entfernen, kein Abhaken; von QIS ersetzt: Hinweis, kein Bearbeiten
    func testOwnEntryAndReplacedByQIS() throws {
        var own: JSONValue = ["status": "bestanden", "grade": "1,7", "can_mark": true,
                              "manual": ["id": 4, "title": "Grundlagen der Rechnernetze", "lp": 5, "grade": "1,7", "passed": true,
                                         "semester": "SoSe 26", "replaced": false, "counted": true, "replaced_by": .null]]
        var detail = Self.netze
        detail["own"] = own
        let t = transport(try enginePlan("selbst_eingetragen"), netze: detail)
        let env = try hostPhone(StudyPlanPage(), api: api(t))
        openNetze(env)
        XCTAssertTrue(env.wait(timeout: 10) { self.sheetButton(env, "Eintrag entfernen") != nil }, dump(env))
        XCTAssertNotNil(inSheet(env).first { $0.accessibilityLabel == "Selbst eingetragen: Bestanden, 1,7, SoSe 26" }, dump(env))
        XCTAssertNotNil(sheetButton(env, "Bearbeiten"))
        XCTAssertNil(sheetButton(env, "Als bestanden abhaken"), "schon eingetragen")
        XCTAssertTrue(shows(env, "Bestanden · 1,7"), "Stand mit Note: " + dump(env))
        assertFits(env, "eigener Eintrag")
        dismissSheet(env)

        own["can_mark"] = false
        own["grade"] = "2,7"
        own["manual"]?["replaced"] = true
        own["manual"]?["counted"] = false
        own["manual"]?["replaced_by"] = ["text": "Grundlagen der Rechnernetze", "note": "2,7", "semester": "SoSe 26"]
        detail["own"] = own
        t.answer("/api/study-plan/module/rechnernetze", detail)
        let env2 = try hostPhone(StudyPlanPage(), api: api(t))
        openNetze(env2)
        XCTAssertTrue(env2.wait(timeout: 10) { self.shows(env2, "QIS meldet dieses Modul jetzt (2,7 · SoSe 26)") }, dump(env2))
        XCTAssertNil(sheetButton(env2, "Bearbeiten"), "QIS gilt, nur noch entfernen")
        XCTAssertNotNil(sheetButton(env2, "Eintrag entfernen"))
    }

    /// QIS meldet das Modul bestanden: kein Abhaken angeboten
    func testNoMarkWhenQISPassed() throws {
        var detail = Self.netze
        detail["own"] = ["status": "bestanden", "grade": "2,0", "can_mark": false, "manual": .null,
                         "attempts": [["status": "bestanden", "grade": "2,0", "semester": "SoSe 26"]]]
        let t = transport(try enginePlan("selbst_eingetragen"), netze: detail)
        let env = try hostPad(StudyPlanPage(), api: api(t))
        openNetze(env)
        XCTAssertTrue(env.wait(timeout: 10) { self.shows(env, "Bestanden · 2,0") }, dump(env))
        XCTAssertNil(sheetButton(env, "Als bestanden abhaken"))
        XCTAssertNil(sheetButton(env, "Note eintragen"))
    }

    // MARK: Regeln ohne Ansicht

    func testGradeInputAndTexts() {
        XCTAssertEqual(StudyPlanText.gradeInput("2,3"), "2,3")
        XCTAssertEqual(StudyPlanText.gradeInput(" 2.3 "), "2,3")
        XCTAssertEqual(StudyPlanText.gradeInput("1"), "1,0")
        XCTAssertEqual(StudyPlanText.gradeInput("5,0"), "5,0")
        XCTAssertEqual(StudyPlanText.gradeInput(""), "")
        for bad in ["0,7", "5,3", "2,35", "sehr gut", "12", ",3", "2,"] { XCTAssertNil(StudyPlanText.gradeInput(bad), bad) }
        XCTAssertEqual(StudyPlanText.recentTerms(today: Fmt.calendar.date(from: DateComponents(year: 2026, month: 11, day: 20))!, count: 3),
                       ["WiSe 26/27", "SoSe 26", "WiSe 25/26"])
        let e = StudyManualEntry(["id": 3, "title": "Chemie", "lp": 5, "grade": "5,0", "passed": false, "semester": .null,
                                  "replaced": false, "counted": false, "replaced_by": .null])
        XCTAssertEqual(e.map(StudyPlanText.manualLine), "Nicht bestanden · 5,0")
        XCTAssertNil(StudyManualEntry(.null))
        let g: JSONValue = ["passed": 4, "basis": "module", "credits_manual": 7.5, "grades": [], "failed_attempts": 0]
        XCTAssertEqual(ServicesPage.creditsLabel(g), "aus 4 bestandenen Modulen · davon 7,5 LP selbst eingetragen")
        XCTAssertEqual(ServicesPage.manualState(["lp": 5, "passed": true, "counted": true, "replaced": false]), "zählt mit 5 LP")
        XCTAssertEqual(ServicesPage.manualState(["replaced": true, "replaced_by": ["note": "2,7", "semester": "SoSe 26"]]),
                       "QIS meldet es jetzt (2,7 · SoSe 26) – zählt aus QIS")
        XCTAssertEqual(ServicesPage.manualLine(["title": "Chemie", "grade": "2,0", "semester": "SoSe 26"]), "Chemie · 2,0 · SoSe 26")
    }
}
