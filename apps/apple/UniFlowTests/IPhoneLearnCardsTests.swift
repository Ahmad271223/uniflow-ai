import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Karteikarten auf dem iPhone (402 x 874, schmal): Kacheln untereinander, Wochenfilter seitlich, Menue "…" als Blatt,
/// Ueben mit grosser Karte und "Nicht gewusst"/"Gewusst" ganz unten, Wiederholung mit Aufdecken, Lesemodus (Free).
/// Gegenprobe iPad quer: Kacheln nebeneinander, Menue an der Kachel. Lokales Backend im Temp-Ordner, erfundene Karten.
@MainActor
final class IPhoneLearnCardsTests: IPhoneLearnTestCase {

    private let clock = UniFlowClock.fixed(berlin: "2026-10-26T09:00:00")!

    /// Lokales Backend mit zwei erfundenen Faechern und drei Stapeln: "Eigenwerte" (heute faellig), "Basen" (alle
    /// Karten schon gelernt, also nichts faellig) und "Folgen" (Woche 2)
    private func api() throws -> APIClient {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-iphone-karten-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let host = LocalBackendHost(directory: dir.appendingPathComponent("db", isDirectory: true), clock: clock)
        return try awaiting {
            let backend = try await host.backend()
            try await backend.context.database.transaction { c in
                for (id, title) in [("k-la", "Lineare Algebra Test"), ("k-an", "Analysis Beispiel")] {
                    try c.execute("INSERT INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                                  [.text(id), .text(title), .text("WiSe 2026/27"), .text(title), .text("vorlesung"), .text("2026-10-01T08:00:00")])
                }
            }
            let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
            func stack(_ name: String, _ subject: String, week: Int?, kind: String) async throws -> Int {
                var b: [String: JSONValue] = ["name": .string(name), "subject": .string(subject), "kind": .string(kind)]
                b["week"] = week.map { .number(Double($0)) } ?? .null
                let r = try await api.value("/api/flashcard-stacks", method: "POST", body: .object(b))
                return try XCTUnwrap(r.i("id"))
            }
            func cards(_ stackID: Int, _ pairs: [(String, String)], learned: Bool) async throws {
                for p in pairs {
                    _ = try await api.value("/api/flashcards", method: "POST",
                                            body: ["cards": [["question": .string(p.0), "answer": .string(p.1)]], "stack_id": .number(Double(stackID))])
                    if learned, let id = try await api.value("/api/flashcards").items.first?.i("id") {
                        _ = try await api.value("/api/flashcards/\(id)/review", method: "POST", body: ["correct": true])
                    }
                }
            }
            let la = "Lineare Algebra Test", an = "Analysis Beispiel"
            try await cards(try await stack("Eigenwerte und Eigenvektoren", la, week: 3, kind: "vorlesung"),
                            [("Was ist ein Eigenwert?", "Ein λ mit Av = λv für ein v ≠ 0."), ("Charakteristisches Polynom?", "det(A − λE)"),
                             ("Spur und Eigenwerte?", "Die Spur ist die Summe der Eigenwerte.")], learned: false)
            try await cards(try await stack("Übungsblatt 3 – Basen", la, week: 3, kind: "uebung"),
                            [("Ist {(1,0),(1,1)} eine Basis?", "Ja, linear unabhängig und erzeugend."), ("Dimension von R³?", "3"),
                             ("Basisergänzung?", "Jede linear unabhängige Menge lässt sich zu einer Basis ergänzen.")], learned: true)
            try await cards(try await stack("Folgen und Grenzwerte", an, week: 2, kind: "vorlesung"),
                            [("Konvergent heißt?", "Es gibt einen Grenzwert."), ("Cauchy-Folge?", "Glieder kommen sich beliebig nahe.")], learned: false)
            return api
        }
    }

    private func page(_ plan: UFPlan = .plus) -> CardsPage { CardsPage(entitlements: Entitlements(observe: false, plan: plan)) }

    /// Kacheln untereinander in voller Breite; Menue "…" als Blatt mit Bearbeiten, Teilen, Loeschen
    func testTilesStackAndMenuOpensAsSheet() throws {
        let env = try hostPhone(page(), api: try api())
        XCTAssertTrue(env.wait { self.shows(env, "Stapel öffnen: Folgen und Grenzwerte") }, dump(env))
        let a = frame(element(env, label: "Stapel öffnen: Eigenwerte und Eigenvektoren"))
        let b = frame(element(env, label: "Stapel öffnen: Übungsblatt 3 – Basen"))
        XCTAssertEqual(a.minX, b.minX, accuracy: 1, "untereinander")
        XCTAssertTrue(b.minY >= a.maxY || a.minY >= b.maxY, "eine Kachel je Reihe: \(a) \(b)")
        XCTAssertGreaterThan(a.width, Self.phone.width - 90, "Kachel fast in voller Breite: \(a)")
        XCTAssertTrue(shows(env, "Lehrwoche"), "Wochenfilter")
        assertFitsOnAllPhones(env, "karten-liste")
        shoot(env, "iphone-karten-liste")
        XCTAssertTrue(tap(env, "Aktionen für Stapel: Folgen und Grenzwerte"))
        XCTAssertTrue(waitSheet(env, showing: "Stapel bearbeiten: Folgen und Grenzwerte"), dump(env))
        XCTAssertNotNil(button(env, "Stapel löschen: Folgen und Grenzwerte"))
        shoot(env, "iphone-karten-menue")
        XCTAssertTrue(tap(env, "Stapel bearbeiten: Folgen und Grenzwerte"))
        XCTAssertTrue(env.wait { self.sheetOpen(env) && self.shows(env, "Stapel bearbeiten") && !self.shows(env, "Stapel löschen: Folgen") }, dump(env))
        assertFits(env, "karten-stapel-dialog")
        shoot(env, "iphone-karten-stapel-dialog")
    }

    /// Stapel teilen schmal: aus dem Menue-Blatt "In der Community teilen" -> Rueckfrage als neues Blatt
    func testShareStackAsksInASheet() throws {
        let env = try hostPhone(page(), api: try api())
        XCTAssertTrue(env.wait { self.button(env, "Aktionen für Stapel: Folgen und Grenzwerte") != nil }, dump(env))
        XCTAssertTrue(tap(env, "Aktionen für Stapel: Folgen und Grenzwerte"))
        XCTAssertTrue(waitSheet(env, showing: "Stapel bearbeiten: Folgen und Grenzwerte"), dump(env))
        guard button(env, "Stapel teilen: Folgen und Grenzwerte") != nil else { throw XCTSkip("Teilen hier nicht verfuegbar (kein Community-Dienst)") }
        XCTAssertTrue(tap(env, "Stapel teilen: Folgen und Grenzwerte"))
        XCTAssertTrue(env.wait { self.sheetOpen(env) && self.shows(env, "Stapel teilen?") }, dump(env))
        XCTAssertTrue(shows(env, "Dein Lernstand wird nicht geteilt"), dump(env))
        assertFits(env, "karten-teilen")
        shoot(env, "iphone-karten-teilen")
        XCTAssertTrue(tap(env, "Abbrechen"))
        XCTAssertTrue(env.wait { !self.sheetOpen(env) }, "Abbrechen schliesst das Blatt")
    }

    /// Frei ueben: Karte fuellt die Hoehe, "Nicht gewusst"/"Gewusst" ganz unten unter der Karte, Weiter nach Antwort
    func testPracticeCardFillsHeightAnswersAtTheBottom() throws {
        let env = try hostPhone(page(), api: try api())
        XCTAssertTrue(env.wait { self.button(env, "Üben: Übungsblatt 3 – Basen") != nil }, dump(env))
        XCTAssertTrue(tap(env, "Üben: Übungsblatt 3 – Basen"))
        XCTAssertTrue(env.wait { self.shows(env, "Frei üben") && self.shows(env, "Karte 1 von 3") }, dump(env))
        env.pump(0.5)
        let card = frame(element(env, label: "Begriff:", prefix: true))
        let known = frame(button(env, "Gewusst")), unknown = frame(button(env, "Nicht gewusst"))
        XCTAssertGreaterThan(card.height, 300, "grosse Karte: \(card)")
        XCTAssertGreaterThan(known.minY, card.maxY, "Antworten unter der Karte")
        XCTAssertGreaterThan(known.maxY, Self.phone.height - 140, "Antworten in Daumennaehe: \(known)")
        XCTAssertEqual(known.minY, unknown.minY, accuracy: 1, "nebeneinander")
        XCTAssertLessThan(known.maxY, Self.phone.height + 1, "ohne Scrollen sichtbar")
        XCTAssertNotNil(button(env, "Erneut fragen"))
        assertFitsOnAllPhones(env, "karten-ueben")
        shoot(env, "iphone-karten-ueben")
        XCTAssertTrue(tap(env, "Gewusst"))
        XCTAssertTrue(env.wait { self.shows(env, "Karte 2 von 3") }, dump(env))
        XCTAssertTrue(tap(env, "Üben beenden"))
        XCTAssertTrue(env.wait { self.shows(env, "Karteikarten") }, dump(env))
    }

    /// Wiederholung "Heute fällig": aufdecken, dann Falsch/Richtig unten; Hinweis zum Wischen
    func testReviewRevealsAndRatesAtTheBottom() throws {
        let env = try hostPhone(page(), api: try api())
        XCTAssertTrue(env.wait { self.button(env, "Üben: Eigenwerte und Eigenvektoren") != nil }, dump(env))
        XCTAssertTrue(tap(env, "Üben: Eigenwerte und Eigenvektoren"))
        XCTAssertTrue(env.wait { self.button(env, "Antwort zeigen") != nil }, dump(env))
        shoot(env, "iphone-karten-wiederholung-frage")
        XCTAssertTrue(tap(env, "Antwort zeigen"))
        XCTAssertTrue(env.wait { self.button(env, "Richtig") != nil }, dump(env))
        XCTAssertGreaterThan(frame(button(env, "Richtig")).maxY, Self.phone.height - 200, "Bewertung unten")
        assertFits(env, "karten-wiederholung")
        shoot(env, "iphone-karten-wiederholung-antwort")
    }

    /// Free: Lesemodus mit Hinweis und Weg zu den Tarifen, nichts zu breit
    func testFreeShowsReadOnlyHint() throws {
        let env = try hostPhone(page(.free), api: try api())
        XCTAssertTrue(env.wait { self.shows(env, UFFlashcardAccess.readOnlyHint) }, dump(env))
        XCTAssertNotNil(button(env, "Tarife ansehen"))
        assertFitsOnAllPhones(env, "karten-free")
        shoot(env, "iphone-karten-free")
    }

    /// iPad quer unveraendert: Kacheln nebeneinander, Menue "…" an der Kachel (kein Blatt)
    func testPadKeepsGridAndInlineMenu() throws {
        let env = try hostPad(page(), api: try api())
        XCTAssertTrue(env.wait { self.shows(env, "Stapel öffnen: Folgen und Grenzwerte") }, dump(env))
        let a = frame(element(env, label: "Stapel öffnen: Eigenwerte und Eigenvektoren"))
        let b = frame(element(env, label: "Stapel öffnen: Übungsblatt 3 – Basen"))
        XCTAssertEqual(a.minY, b.minY, accuracy: 1, "nebeneinander")
        XCTAssertTrue(tap(env, "Aktionen für Stapel: Folgen und Grenzwerte"))
        XCTAssertTrue(env.wait { self.shows(env, "Stapel bearbeiten: Folgen und Grenzwerte") }, dump(env))
        XCTAssertFalse(sheetOpen(env), "breit kein Blatt")
    }
}
