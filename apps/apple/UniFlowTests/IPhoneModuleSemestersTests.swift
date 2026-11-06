import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Module je Semester auf dem iPhone (Wunsch des Inhabers 05.11.2026, `SyncOrder`, docs/IPHONE-2026-11-04.md): oben der
/// Hinweis zum Abgleich ("Aktuelles Semester ist da · ältere Semester …"), dann das aktuelle Semester aufgeklappt mit
/// Ueberschrift (umbrechend, Zahl darunter), darunter "Frühere Semester" je Semester zugeklappt; Antippen klappt auf
/// und zeigt die Module mit Stand der Dateien. Nichts ragt auf 390, 402 und 440 pt ueber den Rand. Daten: erfundene
/// Antworten von GET /api/modules und /api/module-semesters, kein Netz.
final class IPhoneModuleSemestersTests: IPhoneLearnTestCase {

    private func transport() -> Canned {
        let t = Canned()
        t.answer("/api/modules", [
            ["id": 1, "name": "Grundlagen der Informatik und Programmierung", "color": "#4f5bd5", "active": 1],
            ["id": 2, "name": "Mathematik für Ingenieurinnen und Ingenieure II", "color": "#2e9e5b", "active": 1],
            ["id": 3, "name": "Regelungstechnik", "color": "#e5322d", "active": 1],
        ])
        t.answer("/api/module-semesters", [
            "current": ["label": "Wintersemester 2026/27"],
            "upcoming": [],
            "older": [
                ["label": "Sommersemester 2026", "count": 2, "files": 10, "downloaded": 4, "loaded": false,
                 "items": [["name": "Regelungstechnik", "module_id": 3, "color": "#e5322d", "course_ids": ["c6"], "courses": 1,
                            "files": 6, "downloaded": 4, "loaded": false],
                           ["name": "Werkstoffkunde für den Maschinenbau mit sehr langem Titel", "module_id": .null, "color": .null,
                            "course_ids": ["c9"], "courses": 1, "files": 4, "downloaded": 0, "loaded": false]]],
                ["label": "Wintersemester 2025/26", "count": 1, "files": 0, "downloaded": 0, "loaded": true,
                 "items": [["name": "Einführung in die Elektrotechnik", "module_id": .null, "color": .null, "course_ids": ["c2"],
                            "courses": 1, "files": 0, "downloaded": 0, "loaded": true]]],
            ],
            "status": ["hint": "Aktuelles Semester ist da · ältere Semester werden im Hintergrund geladen (1 von 2)",
                       "current": ["ready": true], "older": ["running": true]],
        ])
        return t
    }

    private func terms(_ env: HostedEnvironment) -> [NSObject] { elements(env).filter { identifier($0) == "module-semester.term" } }

    func testCurrentExpandedOlderCollapsedWithHint() throws {
        // develop 06.11.2026: der Ladehinweis erscheint nur mit laufendem Abgleich, nicht bei abgemeldetem Stud.IP (Demo-
        // Hinweis-Fix); hier eine Hochschule ohne Stud.IP (HsH), deren Abgleich den Hinweis liefert
        let env = try hostPhone(ModulesPage().environmentObject(StudIPSync(university: .hsh)), api: remote(transport()))
        XCTAssertTrue(env.wait(timeout: 15) { self.element(env, id: "module-semester-hint") != nil }, dump(env))
        // Hinweis zum Abgleich oben, aktuelles Semester mit Ueberschrift und seinen Modulen
        XCTAssertTrue(shows(env, "Aktuelles Semester ist da"), dump(env))
        let head = try XCTUnwrap(element(env, id: "module-semester-head"), dump(env))
        XCTAssertTrue((head.accessibilityLabel ?? "").contains("Aktuelles Semester · Wintersemester 2026/27"), head.accessibilityLabel ?? "")
        XCTAssertTrue((head.accessibilityLabel ?? "").contains("2 Module"), "Regelungstechnik gehoert zum Sommersemester")
        XCTAssertGreaterThan(frame(head).minY, frame(element(env, id: "module-semester-hint")).maxY - 1, "Hinweis ueber dem Semester")
        XCTAssertTrue(shows(env, "Grundlagen der Informatik und Programmierung"))
        // fruehere Semester zugeklappt: Zahl der Module und Stand der Dateien, keine Module sichtbar
        XCTAssertTrue(shows(env, "Frühere Semester"))
        XCTAssertEqual(terms(env).count, 2, dump(env))
        let summer = try XCTUnwrap(terms(env).first { ($0.accessibilityLabel ?? "").hasPrefix("Sommersemester 2026") })
        XCTAssertTrue((summer.accessibilityLabel ?? "").contains("2 Module · 4 von 10 Dateien geladen"), summer.accessibilityLabel ?? "")
        XCTAssertTrue((summer.accessibilityLabel ?? "").hasSuffix("zugeklappt"))
        XCTAssertFalse(shows(env, "Werkstoffkunde"), "zugeklappt")
        XCTAssertGreaterThan(frame(summer).minY, frame(head).maxY, "fruehere Semester unter dem aktuellen")
        XCTAssertGreaterThanOrEqual(frame(summer).height, 44, "Daumen")
        assertFitsOnAllPhones(env, "Module je Semester")
        shoot(env, "iphone-module-semester")

        // Antippen klappt auf: Module mit Stand, lange Namen umbrechend, nichts ueber den Rand
        XCTAssertTrue(summer.accessibilityActivate())
        XCTAssertTrue(env.wait { self.shows(env, "Werkstoffkunde für den Maschinenbau mit sehr langem Titel") }, dump(env))
        XCTAssertTrue(shows(env, "1 Veranstaltung · 4 von 6 Dateien geladen"))
        XCTAssertTrue(terms(env).contains { ($0.accessibilityLabel ?? "").hasPrefix("Sommersemester 2026") && ($0.accessibilityLabel ?? "").hasSuffix("aufgeklappt") })
        XCTAssertFalse(shows(env, "Einführung in die Elektrotechnik"), "anderes Semester bleibt zu")
        assertFitsOnAllPhones(env, "Früheres Semester offen")
        shoot(env, "iphone-module-semester-offen")
    }

    /// Ueberschrift des Semesters: iPhone Titel und Zahl untereinander (langer Titel bricht um), iPad nebeneinander
    func testSemesterHeadStacksOnPhone() throws {
        let long = "Aktuelles Semester · Wintersemester 2026/27 (Vorlesungszeit bis Februar)"
        let phone = try hostPhone(ModuleSemesterHead(title: long, count: 7).padding(16), api: remote(Canned()), size: Self.phoneSmall)
        let p = try XCTUnwrap(element(phone, id: "module-semester-head"))
        XCTAssertEqual(p.accessibilityLabel?.contains(long), true, "Titel ganz, nicht gekuerzt: \(p.accessibilityLabel ?? "")")
        assertFits(phone, "Semesterkopf")
        let pad = try hostPad(ModuleSemesterHead(title: "Aktuelles Semester · WiSe 2026/27", count: 7).padding(16), api: remote(Canned()))
        let q = try XCTUnwrap(element(pad, id: "module-semester-head"))
        XCTAssertGreaterThan(frame(p).height, frame(q).height + 15, "iPhone untereinander und umbrochen, iPad eine Zeile: \(frame(p)) / \(frame(q))")
    }
}
