import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Dokumente & Notizen und "Mein Regal" auf dem iPhone (402 x 874, schmal): Liste statt Kacheln, Suche mit Knopf
/// "Filter" (Blatt mit Bereich, Art, Modul, Sortierung), kurze Brotkrumen "‹ Eltern", Menues als Blatt, Regal als
/// senkrechte Liste je Modul und Woche. Gegenprobe iPad quer: Mappen-Karten, Werkzeugzeile mit Chips, Buecher im Fluss.
/// Schein-Transport (lokale Datenquelle), erfundene Dateien.
@MainActor
final class IPhoneLearnLibraryTests: IPhoneLearnTestCase {

    private func transport() -> Canned {
        let t = Canned()
        t.answer("/api/library", [
            "modules": [["id": 1, "name": "Testanalysis I", "color": "#175ee8"], ["id": 2, "name": "Testphysik mit einem sehr langen Modulnamen", "color": "#1f9682"]],
            "folders": [["id": 7, "name": "Eigene Zusammenfassungen", "color": "#8b5cf6", "parent_id": .null, "module_id": .null]],
            "files": [
                ["id": "f-1", "title": "VL01 Mengen und Abbildungen", "name": "VL01.pdf", "module_id": 1, "subject": "Testanalysis I", "kind": "pdf",
                 "doc_type": "vorlesung", "chdate": 1_761_000_000, "course_id": "k-an"],
                ["id": "f-2", "title": "VL02 Folgen", "name": "VL02.pdf", "module_id": 1, "subject": "Testanalysis I", "kind": "pdf",
                 "doc_type": "vorlesung", "chdate": 1_761_100_000, "favorite": 1, "course_id": "k-an", "edited_at": "2026-10-30T10:00:00",
                 "last_opened": "2026-10-30T10:00:00"],
                ["id": "f-3", "title": "Übungsblatt 2", "name": "Blatt02.pdf", "module_id": 1, "subject": "Testanalysis I", "kind": "pdf",
                 "doc_type": "uebung", "chdate": 1_761_200_000, "course_id": "k-an"],
                ["id": "f-4", "title": "Skript Mechanik", "name": "Mechanik.pdf", "module_id": 2, "subject": "Testphysik", "kind": "pdf",
                 "doc_type": "skript", "chdate": 1_761_300_000, "course_id": "k-ph"],
                ["id": "n-1", "title": "Meine Notizen zur Analysis", "name": "Notizen", "kind": "notebook", "course_id": "__user__",
                 "folder_id": .null, "edited_at": "2026-11-01T09:00:00"]],
            "trash": []])
        t.answer("/api/courses", [])
        t.answer("/api/index/shelf", LibraryShelfAppTests.shelf)
        return t
    }

    private func page(section: String? = nil, path: String? = nil) -> LibraryPage { LibraryPage(section: section, path: path, q: nil) }

    /// Stammebene: Ordner als Liste, Suche und "Filter"; das Filterblatt waehlt eine Art
    func testRootIsAListAndFiltersAreASheet() throws {
        let env = try hostPhone(page(), api: local(transport()))
        XCTAssertTrue(env.wait { self.shows(env, "Testanalysis I") && self.button(env, "Filter") != nil }, dump(env))
        let a = frame(element(env, label: "Testanalysis I", prefix: true)), b = frame(element(env, label: "Testphysik", prefix: true))
        XCTAssertGreaterThan(b.minY, a.minY + 20, "Ordner untereinander")
        XCTAssertNil(element(env, label: "Vorlesungen"), "Art-Chips stehen im Filterblatt")
        XCTAssertNotNil(button(env, "Mehr zu Eigene Zusammenfassungen"), "Menue des eigenen Ordners")
        assertFitsOnAllPhones(env, "bibliothek-start")
        shoot(env, "iphone-bibliothek-start")
        XCTAssertTrue(tap(env, "Filter"))
        XCTAssertTrue(waitSheet(env, showing: "Sortierung"), dump(env))
        XCTAssertNotNil(button(env, "Papierkorb"))
        assertFits(env, "bibliothek-filter")
        shoot(env, "iphone-bibliothek-filter")
        XCTAssertTrue(tap(env, "Übungen"))
        XCTAssertTrue(tap(env, "Fertig"))
        XCTAssertTrue(env.wait { !self.sheetOpen(env) && self.shows(env, "Übungsblatt 2") }, dump(env))
        XCTAssertFalse(shows(env, "VL01 Mengen"), "nur Uebungen")
        XCTAssertTrue(shows(env, "Filter, 1 aktiv"), dump(env))
        LibraryPage.filter = "all"
    }

    /// Modulordner: kurze Brotkrumen "‹ Dokumente & Notizen" und Titel, Dokumente als Zeilen, Menue als Blatt
    func testFolderHasCompactCrumbAndRowMenuSheet() throws {
        let env = try hostPhone(page(path: "m1/vorlesung"), api: local(transport()))
        XCTAssertTrue(env.wait { self.shows(env, "VL01 Mengen und Abbildungen") }, dump(env))
        XCTAssertNotNil(button(env, "Zurück zu Testanalysis I"), dump(env))
        XCTAssertTrue(shows(env, "Vorlesungen"))
        XCTAssertTrue(shows(env, "Vorlesung · Testanalysis I"), "zweite Zeile: Art · Fach · Datum: \(dump(env))")
        assertFitsOnAllPhones(env, "bibliothek-ordner")
        shoot(env, "iphone-bibliothek-ordner")
        XCTAssertTrue(tap(env, "Mehr zu VL02 Folgen"))
        XCTAssertTrue(waitSheet(env, showing: "In Ordner verschieben"), dump(env))
        assertFits(env, "bibliothek-menue")
        shoot(env, "iphone-bibliothek-menue")
    }

    /// Regal schmal: je Woche die Buecher untereinander in voller Breite
    func testShelfIsAVerticalList() throws {
        let env = try hostPhone(page(section: "shelf"), api: local(transport()))
        XCTAssertTrue(env.wait { self.element(env, label: "VL02 Folgen", prefix: true) != nil }, dump(env))
        let a = frame(element(env, label: "VL02 Folgen", prefix: true)), b = frame(element(env, label: "Hörsaalübung 2,", prefix: true))
        XCTAssertGreaterThan(a.width, Self.phone.width - 100, "Buch in voller Breite: \(a)")
        XCTAssertGreaterThan(b.minY, a.maxY, "Buecher untereinander")
        XCTAssertEqual(a.minX, b.minX, accuracy: 1)
        assertFitsOnAllPhones(env, "regal")
        shoot(env, "iphone-regal")
    }

    /// iPad quer unveraendert: Werkzeugzeile mit Art-Chips, kein Filterknopf; Regal mit schmalen Buechern nebeneinander
    func testPadKeepsToolbarAndShelfFlow() throws {
        let env = try hostPad(page(), api: local(transport()))
        XCTAssertTrue(env.wait { self.shows(env, "Testanalysis I") }, dump(env))
        XCTAssertNil(button(env, "Filter"))
        XCTAssertNotNil(element(env, label: "Vorlesungen"), dump(env))
        let shelf = try hostPad(page(section: "shelf"), api: local(transport()))
        XCTAssertTrue(shelf.wait { self.element(shelf, label: "VL02 Folgen", prefix: true) != nil }, dump(shelf))
        XCTAssertLessThan(frame(element(shelf, label: "VL02 Folgen", prefix: true)).width, 260, "Buch im Fluss, nicht volle Breite")
    }
}
