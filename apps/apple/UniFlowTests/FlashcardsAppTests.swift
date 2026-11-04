import SwiftUI
import UIKit
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Eigene Karteikarten ohne PC (M8): Stand der Seite (Anlegen mit Stapelwahl, Stapelliste je Modul, Wiederholen nur
/// im gewaehlten Stapel mit Aufdecken und Richtig/Falsch, Bearbeiten ohne Lernstandverlust, Loeschen), Pruefpunkte 269
/// (keine doppelte Bewertung) und 270 (neuer Stand nach Konto- oder Hochschulwechsel), Tarif Free/Plus (UFGate,
/// Startargument -UFPlan) und Trennung je Container. Geschlossene Stapel seit 04.11.2026
/// (docs/KARTEIKARTEN-STAPEL-2026-11-04.md). Lokales Backend im Temp-Ordner mit fester Uhr, nur erfundene Kurse,
/// Dateien und Karten, kein Netz.
@MainActor
final class FlashcardsAppTests: XCTestCase {

    /// Zaehlt Anfragen je Pfad und haelt auf Wunsch die naechste Bewertung an, bis der Test sie freigibt
    final class Recorder: APITransport, @unchecked Sendable {
        let inner: APITransport
        private let lock = NSLock()
        private var log: [(method: String, path: String, status: Int)] = []
        private var holdReview = false
        private var held: CheckedContinuation<Void, Never>?

        init(_ inner: APITransport) { self.inner = inner }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let hold: Bool = lock.withLock {
                guard holdReview, path.hasSuffix("/review") else { return false }
                holdReview = false
                return true
            }
            if hold { await withCheckedContinuation { c in lock.withLock { held = c } } }
            let r = try await inner.send(request)
            lock.withLock { log.append((request.httpMethod ?? "GET", path, r.1.statusCode)) }
            return r
        }

        func holdNextReview() { lock.withLock { holdReview = true } }
        var isHolding: Bool { lock.withLock { held != nil } }
        func release() { lock.withLock { held?.resume(); held = nil } }
        func count(_ method: String, _ path: String) -> Int { lock.withLock { log.filter { $0.method == method && $0.path == path }.count } }
        func count(suffix: String) -> Int { lock.withLock { log.filter { $0.path.hasSuffix(suffix) }.count } }
        var calls: [(method: String, path: String, status: Int)] { lock.withLock { log } }
    }

    private final class MemorySecrets: AccountSecretStore {
        var values: [String: String] = [:]
        func get(_ key: String) -> String? { values[key] }
        func set(_ value: String, for key: String) { values[key] = value }
        func delete(_ key: String) { values[key] = nil }
    }

    private struct AuthorizedChecker: AppleCredentialChecking {
        func state(forUserID id: String) async -> AppleCredentialState { .authorized }
    }

    private let clock = UniFlowClock.fixed(berlin: "2026-10-26T09:00:00")!

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-karten-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Lokales Backend mit zwei erfundenen Faechern (je ein Kurs mit Fach und eine Datei) und einem Kurs ohne Fach
    private func seededAPI(cards: [(question: String, answer: String, file: String?)] = []) async throws -> (APIClient, Recorder, LocalBackendHost) {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true), clock: clock)
        let backend = try await host.backend()
        try await backend.context.database.transaction { c in
            for (id, title) in [("k-la", "Lineare Algebra Test"), ("k-an", "Analysis Beispiel")] {
                try c.execute("INSERT INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                              [.text(id), .text(title), .text("WiSe 2026/27"), .text(title), .text("vorlesung"), .text("2026-10-01T08:00:00")])
            }
            try c.execute("INSERT INTO courses(id, title, semester, kind, created_at) VALUES ('k-frei', 'Freies Seminar Beispiel', 'WiSe 2026/27', 'sonstiges', '2026-10-01T08:00:00')")
            for (id, course, name) in [("f-la", "k-la", "LA_Skript.pdf"), ("f-an", "k-an", "Analysis_Blatt_01.pdf"), ("f-frei", "k-frei", "Seminar.pdf")] {
                try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind) VALUES (?,?,?,?, 'neu', 'pdf')",
                              [.text(id), .text(course), .text(name), .integer(1_792_000_000)])
            }
        }
        let recorder = Recorder(LocalTransport(host: host))
        let api = APIClient(base: APIClient.localBase, transport: recorder)
        for c in cards {
            var body: [String: JSONValue] = ["cards": [["question": .string(c.question), "answer": .string(c.answer)]]]
            if let f = c.file { body["file_id"] = .string(f) }
            _ = try await api.value("/api/flashcards", method: "POST", body: .object(body))
        }
        return (api, recorder, host)
    }

    private func cards(_ api: APIClient) async throws -> [JSONValue] { try await api.value("/api/flashcards").items }

    /// den ersten Stapel waehlen (alle Karten ohne Datei liegen in "Ohne Modul")
    private func selectFirst(_ deck: FlashcardDeck) {
        deck.select(deck.stacks.first?.i("id"))
    }

    // MARK: Stand der Seite (ohne Oberflaeche)

    /// Karten landen ohne Stapelwahl im Stapel ihres Dokuments bzw. in "Ohne Modul"; die Stapelliste gruppiert je
    /// Modul; nach dem Anlegen ist der Stapel der Karte gewaehlt und nur seine Karten sind faellig
    func testCreatePutsCardsIntoStacksAndSelectsTheStack() async throws {
        let (api, _, _) = try await seededAPI()
        let deck = FlashcardDeck(api: api)
        try await deck.load()
        XCTAssertTrue(deck.loaded)
        XCTAssertEqual(deck.all, [])
        XCTAssertEqual(Set(deck.modules.compactMap { $0.s("name") }), ["Lineare Algebra Test", "Analysis Beispiel"], "Module aus der Bibliothek")
        XCTAssertEqual(deck.documents(module: 0).count, 3)
        let la = try XCTUnwrap(deck.modules.first { $0.s("name") == "Lineare Algebra Test" }?.i("id"))
        XCTAssertEqual(deck.documents(module: la).map { $0.s("id") ?? "" }, ["f-la"])

        try await deck.create(question: "  Was ist eine Basis?  ", answer: "Linear unabhängiges Erzeugendensystem\n", fileID: "f-la")
        try await deck.create(question: "Ableitung von x²?", answer: "2x", fileID: "f-an")
        try await deck.create(question: "Freie Frage", answer: "Freie Antwort", fileID: nil)
        try await deck.create(question: "Seminarfrage", answer: "ohne Fach", fileID: "f-frei")
        // leere Frage oder Antwort: Fehler, nichts gespeichert
        do {
            try await deck.create(question: "   ", answer: "x", fileID: nil)
            XCTFail("leere Frage darf nicht gespeichert werden")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Frage und Antwort sind nötig.")
        }
        let stored = try await cards(api)
        XCTAssertEqual(stored.count, 4)
        XCTAssertEqual(stored.last?.s("question"), "Was ist eine Basis?", "ohne Leerraum aussen")
        XCTAssertEqual(stored.last?.s("answer"), "Linear unabhängiges Erzeugendensystem")
        XCTAssertEqual(stored.last?.s("subject"), "Lineare Algebra Test", "Fach aus dem Kurs der Datei")
        XCTAssertEqual(stored.last?.s("file_name"), "LA_Skript.pdf")
        XCTAssertEqual(stored.last?.s("stack_name"), "LA_Skript.pdf", "Stapel des Dokuments")
        XCTAssertEqual(deck.all.count, 4)
        XCTAssertEqual(deck.dueAll.count, 4, "neue Karten sind sofort faellig (Zaehler ueber alle Stapel)")
        XCTAssertTrue(stored.allSatisfy { $0.i("stack_id") != nil }, "jede Karte hat einen Stapel")
        // Stapelliste je Modul in der Reihenfolge der Module, "Ohne Modul" zuletzt (dort auch der Seminar-Stapel ohne Fach)
        let order = deck.modules.compactMap { $0.s("name") }
        XCTAssertEqual(deck.stackGroups.map(\.title), order + ["Ohne Modul"])
        XCTAssertEqual(Set(deck.stackGroups.last?.stacks.compactMap { $0.s("name") } ?? []), ["Seminar.pdf", "Ohne Modul"])
        XCTAssertEqual(deck.stackGroups.first { $0.title == "Lineare Algebra Test" }?.stacks.map { $0.s("name") ?? "" }, ["LA_Skript.pdf"])
        XCTAssertEqual(deck.fileTitle(stored.last!), "LA_Skript.pdf")
        XCTAssertEqual(deck.stackTitle(stored.last!), "LA_Skript.pdf")
        XCTAssertNil(deck.fileTitle(stored.first { $0.s("question") == "Freie Frage" }!))
        // nach dem Anlegen ist der Stapel der Karte gewaehlt: nur seine Karten sind faellig und in der Liste
        XCTAssertEqual(deck.stack?.s("name"), "Seminar.pdf")
        XCTAssertEqual(deck.cards.map { $0.s("question") ?? "" }, ["Seminarfrage"])
        XCTAssertEqual(deck.due.count, 1, "Heute faellig nur im Stapel")
        XCTAssertEqual(FlashcardDeck.stackLine(deck.stack!), "Ohne Modul · 1 Karte · Heute fällig (1) · noch nicht geübt")
        // Vorgabe beim Anlegen: zuletzt benutzter Stapel des Moduls
        XCTAssertEqual(deck.lastUsedStack(subject: "Lineare Algebra Test")?.s("name"), "LA_Skript.pdf")
        XCTAssertNil(deck.lastUsedStack(subject: "Gibt es nicht"))
        deck.select(nil)
        XCTAssertEqual(deck.due, [], "ohne gewaehlten Stapel wird nichts abgefragt")
    }

    /// Geschlossene Stapel: die Wiederholung mischt nie; Bearbeiten (Frage, Antwort, Modul, Stapel) laesst Fach und
    /// Termin, auch in einer laufenden Wiederholung; Stapel umbenennen, verschieben und loeschen mit Umzug
    func testReviewStaysInOneStackAndEditKeepsTheBox() async throws {
        let (api, rec, _) = try await seededAPI(cards: [("LA 1", "a", "f-la"), ("LA 2", "b", "f-la"), ("Frei", "c", nil)])
        let deck = FlashcardDeck(api: api)
        try await deck.load()
        XCTAssertEqual(deck.stacks.count, 2)
        let la = try XCTUnwrap(deck.stacks.first { $0.s("name") == "LA_Skript.pdf" }?.i("id"))
        let free = try XCTUnwrap(deck.stacks.first { $0.s("name") == "Ohne Modul" }?.i("id"))
        deck.select(la)
        XCTAssertEqual(Set(deck.due.compactMap { $0.s("question") }), ["LA 1", "LA 2"])
        deck.startReview()
        XCTAssertEqual(deck.queue.count, 2, "nur dieser Stapel wird abgefragt")
        XCTAssertTrue(deck.queue.allSatisfy { $0.i("stack_id") == la })
        // Bearbeiten waehrend der Wiederholung: neuer Text, Karte bleibt an ihrer Stelle, Fach bleibt
        let current = try XCTUnwrap(deck.current)
        deck.reveal()
        _ = try await deck.rate(correct: true)
        let saved = try await deck.update(current, question: " LA 1 neu ", answer: "a neu", subject: "Lineare Algebra Test", stackID: la)
        XCTAssertEqual(saved.s("question"), "LA 1 neu")
        XCTAssertEqual(saved.i("box"), 2, "Bearbeiten setzt das Fach nicht zurueck")
        XCTAssertEqual(saved.s("due"), "2026-10-28")
        XCTAssertTrue(deck.inSession)
        XCTAssertEqual(deck.queue.first?.s("question"), "LA 1 neu")
        XCTAssertEqual(rec.count(suffix: "/review"), 1)
        // in den anderen Stapel verschieben: Fach des Ziels, Lernstand bleibt
        let moved = try await deck.update(current, question: "LA 1 neu", answer: "a neu", subject: nil, stackID: free)
        XCTAssertEqual(moved.i("stack_id"), free)
        XCTAssertTrue(moved["subject"]?.isNull == true)
        XCTAssertEqual(moved.i("box"), 2)
        deck.select(free)
        XCTAssertEqual(Set(deck.cards.compactMap { $0.s("question") }), ["LA 1 neu", "Frei"])
        XCTAssertFalse(deck.inSession, "Stapelwechsel beendet die Wiederholung")
        // leere Angaben: Fehler, nichts gespeichert
        do {
            _ = try await deck.update(current, question: " ", answer: "x", subject: nil, stackID: free)
            XCTFail("leere Frage darf nicht gespeichert werden")
        } catch { XCTAssertEqual(error.localizedDescription, "Frage und Antwort sind nötig.") }
        // Stapel umbenennen und verschieben (Karten folgen), neuer Stapel, loeschen mit Umzug
        try await deck.updateStack(free, name: "Klausur", subject: "Analysis Beispiel")
        XCTAssertEqual(deck.stack?.s("name"), "Klausur")
        XCTAssertTrue(deck.cards.allSatisfy { $0.s("subject") == "Analysis Beispiel" })
        XCTAssertEqual(deck.lastUsedStack(subject: "Analysis Beispiel")?.i("id"), free)
        let extra = try await deck.createStack(name: " Neu ", subject: "Analysis Beispiel")
        XCTAssertEqual(deck.stacks.first { $0.i("id") == extra }?.s("name"), "Neu")
        try await deck.deleteStack(free, moveTo: extra)
        XCTAssertEqual(deck.selected, extra, "Auswahl folgt den Karten")
        XCTAssertEqual(Set(deck.cards.compactMap { $0.s("question") }), ["LA 1 neu", "Frei"])
        XCTAssertEqual(deck.cards.first { $0.s("question") == "LA 1 neu" }?.i("box"), 2)
        try await deck.deleteStack(extra)
        XCTAssertNil(deck.selected)
        XCTAssertEqual(deck.all.map { $0.s("question") ?? "" }, ["LA 1"], "die bearbeitete Karte war die neueste (LA 2)")
        XCTAssertEqual(deck.stacks.count, 1)
        do {
            try await deck.createStack(name: "  ", subject: nil)
            XCTFail("Stapel ohne Namen")
        } catch { XCTAssertEqual(error.localizedDescription, "Der Stapel braucht einen Namen.") }
    }

    /// Lehrwoche und Art je Stapel (Ergaenzung 04.11.2026): Vorgabe eigene/Allgemein, aus dem Dokument die Einordnung
    /// (Blatt -> Übung, Woche aus dem Namen), Filter "Alle · Allgemein · W1 … Wn" nur mit vorkommenden Wochen, Etikett
    func testStackWeekAndKindWithFilter() async throws {
        let (api, _, host) = try await seededAPI(cards: [("Frei", "a", nil)])
        let backend = try await host.backend()
        try await backend.context.database.execute("INSERT INTO files(id, course_id, name, chdate, status, kind) VALUES ('f-blatt', 'k-an', 'Analysis_Blatt_03.pdf', 1792000000, 'neu', 'pdf')")
        let deck = FlashcardDeck(api: api)
        try await deck.load()
        XCTAssertEqual(deck.weeks, [], "ohne Lehrwochen keine Filterzeile")
        XCTAssertEqual(FlashcardDeck.badge(deck.stacks[0]), "Eigene · Allgemein")
        let sheet = try await deck.createStack(name: "Blatt 3", subject: "Analysis Beispiel", fileID: "f-blatt")
        let folien = try await deck.createStack(name: "Folien", subject: "Lineare Algebra Test", week: .some(5), kind: "vorlesung")
        let s3 = try XCTUnwrap(deck.stacks.first { $0.i("id") == sheet })
        XCTAssertEqual(s3.s("kind"), "uebung", "Einordnung des Dokuments")
        XCTAssertEqual(s3.i("week"), 3, "Lehrwoche aus dem Dateinamen")
        XCTAssertEqual(FlashcardDeck.badge(s3), "Übung · W3")
        XCTAssertEqual(FlashcardDeck.badge(deck.stacks.first { $0.i("id") == folien }!), "Vorlesung · W5")
        XCTAssertEqual(deck.weeks, [3, 5])
        XCTAssertEqual(deck.stacks(week: 3).map { $0.i("id") ?? 0 }, [sheet])
        XCTAssertEqual(deck.stacks(week: FlashcardDeck.generalWeek).compactMap { $0.s("name") }, ["Ohne Modul"])
        XCTAssertEqual(deck.stacks(week: nil).count, 3)
        XCTAssertEqual(deck.stackGroups(week: 5).map(\.title), ["Lineare Algebra Test"])
        XCTAssertTrue(deck.stackGroups(week: 9).isEmpty)
        try await deck.updateStack(folien, name: "Folien", subject: "Lineare Algebra Test", week: .some(nil), kind: "eigene")
        XCTAssertEqual(FlashcardDeck.badge(deck.stacks.first { $0.i("id") == folien }!), "Eigene · Allgemein")
        XCTAssertEqual(deck.weeks, [3])
        XCTAssertEqual(FlashcardStackDialog.weekOptions(deck, current: 20).map(\.0).suffix(2), [16, 20])
        XCTAssertEqual(FlashcardStackDialog.weekOptions(deck, current: 0).first?.1, "Allgemein")
    }

    /// Dialog "Karte anlegen": Stapelvorgabe ist der uebergebene passende Stapel, sonst der zuletzt benutzte des
    /// Moduls, sonst "Neuer Stapel …" mit dem Titel des Dokuments bzw. "Allgemein"/"Ohne Modul" als Namen
    func testCreateDialogDefaultsToTheLastUsedStackOfTheModule() async throws {
        let (api, _, _) = try await seededAPI(cards: [("LA 1", "a", "f-la"), ("Frei", "c", nil)])
        let deck = FlashcardDeck(api: api)
        try await deck.load()
        let la = try XCTUnwrap(deck.stacks.first { $0.s("name") == "LA_Skript.pdf" })
        let klausur = try await deck.createStack(name: "Klausur", subject: "Lineare Algebra Test")
        XCTAssertEqual(deck.lastUsedStack(subject: "Lineare Algebra Test")?.i("id"), klausur, "neuester Stapel ohne Uebung")
        deck.select(la.i("id"))
        deck.startReview()
        deck.reveal()
        let rated = try await deck.rate(correct: true)
        XCTAssertTrue(rated)
        try await deck.load()
        XCTAssertEqual(deck.lastUsedStack(subject: "Lineare Algebra Test")?.i("id"), la.i("id"), "zuletzt geuebt geht vor")
        XCTAssertEqual(deck.stacks(subject: "Lineare Algebra Test").compactMap { $0.i("id") }, [la.i("id")!, klausur])
        XCTAssertEqual(FlashcardDeck.stackLine(deck.stacks.first { $0.i("id") == la.i("id") }!),
                       "Lineare Algebra Test · 1 Karte · Heute fällig (0) · zuletzt geübt am 26.10.2026")
        XCTAssertEqual(FlashcardCreateDialog.defaultStack(known: la, subject: "Lineare Algebra Test", deck: deck).stack, la.i("id"))
        XCTAssertEqual(FlashcardCreateDialog.defaultStack(known: la, subject: nil, deck: deck).stack,
                       deck.stacks.first { $0.s("name") == "Ohne Modul" }?.i("id"), "Stapel eines anderen Fachs passt nicht: zuletzt benutzter des Fachs")
        XCTAssertEqual(FlashcardCreateDialog.defaultStack(known: nil, subject: "Analysis Beispiel", deck: deck).stack, FlashcardDeck.newStack)
        XCTAssertEqual(FlashcardCreateDialog.suggestedName(fileID: "f-an", subject: "Analysis Beispiel", deck: deck), "Analysis_Blatt_01.pdf")
        XCTAssertEqual(FlashcardCreateDialog.suggestedName(fileID: "", subject: "Analysis Beispiel", deck: deck), "Allgemein")
        XCTAssertEqual(FlashcardCreateDialog.suggestedName(fileID: "", subject: nil, deck: deck), "Ohne Modul")
        // neuer Stapel beim Anlegen: entsteht mit dem Fach des Moduls, die Karte liegt darin und er ist gewaehlt
        try await deck.create(question: "Neu", answer: "x", fileID: nil, newStackName: "Kapitel 3", subject: "Analysis Beispiel")
        XCTAssertEqual(deck.stack?.s("name"), "Kapitel 3")
        XCTAssertEqual(deck.stack?.s("subject"), "Analysis Beispiel")
        XCTAssertEqual(deck.cards.map { $0.s("question") ?? "" }, ["Neu"])
        // vorhandener Stapel per Kennung
        try await deck.create(question: "Noch eine", answer: "y", fileID: nil, stackID: klausur)
        XCTAssertEqual(deck.selected, klausur)
        XCTAssertEqual(deck.cards.map { $0.s("question") ?? "" }, ["Noch eine"])
    }

    /// Pruefpunkt 269: zwei schnelle Tipps auf "Richtig" bewerten die Karte einmal; ohne Aufdecken keine Bewertung
    func testReviewRatesEachCardOnceEvenWithDoubleTap() async throws {
        let (api, rec, _) = try await seededAPI(cards: [("Frage A", "Antwort A", nil), ("Frage B", "Antwort B", nil)])
        let deck = FlashcardDeck(api: api)
        try await deck.load()
        selectFirst(deck)
        deck.startReview()
        XCTAssertTrue(deck.inSession)
        XCTAssertEqual(deck.queue.count, 2)
        let first = try XCTUnwrap(deck.current)
        let rated = try await deck.rate(correct: true)
        XCTAssertFalse(rated, "erst aufdecken")
        XCTAssertEqual(rec.count(suffix: "/review"), 0)
        deck.reveal()
        async let a = deck.rate(correct: true)
        async let b = deck.rate(correct: true)
        let results = try await [a, b]
        XCTAssertEqual(results.filter { $0 }.count, 1, "genau eine Bewertung: \(results)")
        XCTAssertEqual(rec.count(suffix: "/review"), 1, "\(rec.calls)")
        XCTAssertEqual(deck.position, 1)
        XCTAssertFalse(deck.revealed, "naechste Karte verdeckt")
        let box = try await cards(api).first { $0.i("id") == first.i("id") }?.i("box")
        XCTAssertEqual(box, 2, "einmal ein Fach weiter, nicht zwei")
        // zweite Karte falsch -> Fach 1, Wiederholung geschafft
        deck.reveal()
        let second = try await deck.rate(correct: false)
        XCTAssertTrue(second)
        XCTAssertTrue(deck.finished)
        XCTAssertEqual(deck.right, 1)
        XCTAssertEqual(deck.wrong, 1)
        // nach dem Ende bewertet nichts mehr
        let after = try await deck.rate(correct: true)
        XCTAssertFalse(after)
        XCTAssertEqual(rec.count(suffix: "/review"), 2)
        try await deck.load()
        XCTAssertEqual(deck.due, [], "richtig: in 2 Tagen, falsch: morgen")
        XCTAssertEqual(deck.nextDue, "2026-10-27")
    }

    /// Fehler beim Bewerten: die Karte bleibt aufgedeckt stehen und laesst sich erneut bewerten
    func testFailedReviewKeepsTheCard() async throws {
        let (api, _, host) = try await seededAPI(cards: [("Frage A", "Antwort A", nil)])
        let deck = FlashcardDeck(api: api)
        try await deck.load()
        selectFirst(deck)
        deck.startReview()
        deck.reveal()
        let id = try XCTUnwrap(deck.current?.i("id"))
        // Karte inzwischen weg (z. B. anderes Fenster): 404, nichts rueckt weiter
        let backend = try await host.backend()
        try await backend.context.database.execute("DELETE FROM flashcards WHERE id=?", [.integer(Int64(id))])
        do {
            _ = try await deck.rate(correct: true)
            XCTFail("404 muss als Fehler ankommen")
        } catch {}
        XCTAssertEqual(deck.position, 0)
        XCTAssertTrue(deck.revealed)
        XCTAssertFalse(deck.rating)
    }

    /// Pruefpunkt 270: wechselt die Datenquelle (anderes Konto oder andere Hochschule), beginnt der Stapel von vorn;
    /// eine Bewertung, deren Antwort erst danach ankommt, aendert den neuen Stapel nicht
    func testDeckStartsOverWhenTheSourceChanges() async throws {
        let (apiA, recA, _) = try await seededAPI(cards: [("Frage aus A", "Antwort A", nil)])
        let (apiB, _, _) = try await seededAPI(cards: [("Frage aus B 1", "B1", nil), ("Frage aus B 2", "B2", nil)])
        let deck = FlashcardDeck()
        deck.attach(apiA)
        try await deck.load()
        selectFirst(deck)
        deck.startReview()
        deck.reveal()
        recA.holdNextReview()
        let pending = Task { try await deck.rate(correct: true) }
        for _ in 0..<200 where !recA.isHolding { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(recA.isHolding)
        XCTAssertTrue(deck.rating)
        deck.attach(apiB)
        XCTAssertTrue(deck.api === apiB)
        XCTAssertFalse(deck.inSession)
        XCTAssertEqual(deck.all, [])
        XCTAssertEqual(deck.stacks, [])
        XCTAssertNil(deck.selected)
        XCTAssertEqual(deck.queue, [])
        XCTAssertFalse(deck.revealed)
        XCTAssertFalse(deck.rating, "Knoepfe des neuen Stapels nicht gesperrt")
        recA.release()
        let result = try await pending.value
        XCTAssertFalse(result, "Antwort der alten Quelle zaehlt nicht")
        XCTAssertFalse(deck.inSession)
        XCTAssertEqual(deck.position, 0)
        try await deck.load()
        XCTAssertEqual(deck.all.map { $0.s("question") ?? "" }, ["Frage aus B 2", "Frage aus B 1"])
        XCTAssertEqual(deck.dueAll.count, 2)
        // gleiche Quelle noch einmal: nichts wird zurueckgesetzt
        selectFirst(deck)
        deck.startReview()
        deck.attach(apiB)
        XCTAssertTrue(deck.inSession)
    }

    func testDeleteRemovesCardAlsoFromRunningReview() async throws {
        let (api, rec, _) = try await seededAPI(cards: [("Frage 1", "A1", nil), ("Frage 2", "A2", nil)])
        let deck = FlashcardDeck(api: api)
        try await deck.load()
        selectFirst(deck)
        deck.startReview()
        let current = try XCTUnwrap(deck.current)
        try await deck.delete(current)
        XCTAssertEqual(rec.count("DELETE", "/api/flashcards/\(current.i("id") ?? 0)"), 1)
        XCTAssertEqual(deck.queue.count, 1)
        XCTAssertNotEqual(deck.current?.i("id"), current.i("id"))
        let left = try await cards(api)
        XCTAssertEqual(left.count, 1)
        // schon geloescht: 404 als Fehler (Regel G6), kein stiller Erfolg
        do {
            try await deck.delete(current)
            XCTFail("zweites Loeschen muss scheitern")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Karteikarte nicht gefunden")
        }
    }

    // MARK: Trennung je Container

    /// Karten liegen in der Datenbank des Containers (Apple-Nutzer, Hochschule): die Uni Hildesheim und ein anderes
    /// Konto sehen sie nicht, zurueck an der LUH sind sie mit ihrem Lernstand wieder da
    func testCardsArePerContainer() async throws {
        let bed = try ContainerTestBed(name: "karten", clock: clock)
        addTeardownBlock { @MainActor in await bed.tearDown() }
        let m = bed.manager()
        let a = bed.account(.luh)
        let luh = try bed.open(m, a)
        let deck = FlashcardDeck()
        deck.attach(luh.api)
        try await deck.load()
        try await deck.create(question: "Nur an der LUH", answer: "ja", fileID: nil)
        deck.startReview()
        deck.reveal()
        try await deck.rate(correct: true)
        let rated = try await cards(luh.api)
        XCTAssertEqual(rated.first?.i("box"), 2)

        a.chooseUniversity(.hildesheim)
        let hi = try bed.open(m, a)
        XCTAssertNotEqual(hi.layout.identifier, luh.layout.identifier)
        deck.attach(hi.api)
        XCTAssertFalse(deck.inSession)
        try await deck.load()
        XCTAssertEqual(deck.all, [], "andere Hochschule: eigener Stapel")
        try await deck.create(question: "Nur in Hildesheim", answer: "ja", fileID: nil)

        // anderes Konto auf demselben iPad
        let other = AccountStore(secrets: MemorySecrets(), defaults: bed.defaults, checker: AuthorizedChecker(), observeRevocation: false)
        other.signIn(userID: "009876.erfunden-bob.\(UUID().uuidString.prefix(8))", name: nil, email: nil)
        other.markPlanShown()
        other.chooseUniversity(.luh)
        let bob = try bed.open(m, other)
        let otherID = bob.key.userID
        addTeardownBlock { @MainActor in
            for layout in DataContainerLayout.all(base: bed.containers, userID: otherID) {
                let s = ActiveContainer.defaultsSuite(layout.identifier)
                UserDefaults(suiteName: s)?.removePersistentDomain(forName: s)
                await WKWebsiteDataStore(forIdentifier: layout.identifier).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
                try? await WKWebsiteDataStore.remove(forIdentifier: layout.identifier)
            }
        }
        let bobs = try await cards(bob.api)
        XCTAssertEqual(bobs, [], "anderes Konto: keine fremden Karten")

        a.chooseUniversity(.luh)
        let back = try bed.open(m, a)
        XCTAssertEqual(back.layout.identifier, luh.layout.identifier)
        let mine = try await cards(back.api)
        XCTAssertEqual(mine.map { $0.s("question") ?? "" }, ["Nur an der LUH"])
        XCTAssertEqual(mine.first?.i("box"), 2, "Lernstand bleibt im Container")
    }

    // MARK: Frei üben (Trainer)

    /// Gewusst / nicht gewusst zaehlen, speichern last_result und lassen Fach und Termin (Leitner) unberuehrt;
    /// "Vorherige" nimmt die letzte Antwort samt gespeichertem Urteil zurueck; Doppeltipps zaehlen einmal
    func testTrainerCountsAnswersAndPreviousUndoes() async throws {
        let (api, rec, _) = try await seededAPI(cards: [("Begriff A", "Definition A", nil), ("Begriff B", "Definition B", "f-la"),
                                                        ("Begriff C", "Definition C", nil)])
        let deck = FlashcardDeck(api: api)
        try await deck.load()
        let before = try await cards(api)
        let trainer = FlashcardTrainer(api: api)
        trainer.start(with: deck.all)
        XCTAssertEqual(trainer.cards.compactMap { $0.s("question") }, ["Begriff A", "Begriff B", "Begriff C"], "Original: aelteste zuerst")
        XCTAssertEqual(trainer.progressText, "1/3")
        trainer.flip()
        XCTAssertTrue(trainer.showsDefinition)
        // Doppeltipp auf "Gewusst": eine Antwort
        async let a = trainer.answer(known: true)
        async let b = trainer.answer(known: true)
        let results = try await [a, b]
        XCTAssertEqual(results.filter { $0 }.count, 1, "\(results)")
        XCTAssertEqual(rec.count(suffix: "/api/flashcards/1"), 1, "\(rec.calls)")
        XCTAssertEqual(trainer.known, 1)
        XCTAssertEqual(trainer.unknown, 0)
        XCTAssertEqual(trainer.position, 1)
        XCTAssertFalse(trainer.flipped, "naechste Karte vorn")
        XCTAssertEqual(trainer.progressText, "2/3")
        let wrong = try await trainer.answer(known: false)
        XCTAssertTrue(wrong)
        XCTAssertEqual(trainer.unknown, 1)
        XCTAssertEqual(trainer.progressText, "3/3")
        var stored = try await cards(api)
        XCTAssertEqual(stored.reversed().map { $0.s("last_result") ?? "-" }, ["right", "wrong", "-"])
        XCTAssertEqual(stored.map { $0.i("box") }, before.map { $0.i("box") }, "Fach bleibt")
        XCTAssertEqual(stored.map { $0.s("due") }, before.map { $0.s("due") }, "Termin bleibt")
        XCTAssertEqual(rec.count(suffix: "/review"), 0, "der Trainer bewertet nicht fuer die Wiederholung")
        // Vorherige: Karte B wieder vorn, Zaehler zurueck, Urteil wieder leer
        XCTAssertTrue(trainer.canGoBack)
        let undone = try await trainer.previous()
        XCTAssertTrue(undone)
        XCTAssertEqual(trainer.current?.s("question"), "Begriff B")
        XCTAssertEqual(trainer.unknown, 0)
        XCTAssertEqual(trainer.known, 1)
        XCTAssertEqual(trainer.progressText, "2/3")
        stored = try await cards(api)
        XCTAssertTrue(stored.first { $0.s("question") == "Begriff B" }?["last_result"]?.isNull == true)
        // zweimal zurueck: auch A wieder ungelernt; danach nichts mehr zurueckzunehmen
        _ = try await trainer.previous()
        XCTAssertEqual(trainer.current?.s("question"), "Begriff A")
        XCTAssertEqual(trainer.known, 0)
        XCTAssertFalse(trainer.canGoBack)
        let none = try await trainer.previous()
        XCTAssertFalse(none)
        // zu Ende: geschafft, nur die nicht gewussten noch einmal
        _ = try await trainer.answer(known: false)
        _ = try await trainer.answer(known: true)
        _ = try await trainer.answer(known: false)
        XCTAssertTrue(trainer.finished)
        XCTAssertEqual(trainer.progressText, "3/3")
        XCTAssertNil(trainer.current)
        let after = try await trainer.answer(known: true)
        XCTAssertFalse(after, "nach dem Ende zaehlt nichts")
        trainer.practiceUnknown()
        XCTAssertEqual(trainer.cards.compactMap { $0.s("question") }, ["Begriff A", "Begriff C"])
        XCTAssertEqual(trainer.known + trainer.unknown, 0)
        // Filter "Falsch" sieht die gespeicherten Urteile nach Neu starten
        var o = trainer.options
        o.progress = [.wrong]
        trainer.apply(o)
        XCTAssertEqual(trainer.cards.compactMap { $0.s("question") }, ["Begriff A", "Begriff C"])
        o.progress = [.right]
        trainer.apply(o)
        XCTAssertEqual(trainer.cards.compactMap { $0.s("question") }, ["Begriff B"])
    }

    /// Lesezeichen und Verstecken: gespeichert, versteckte Karte verlaesst den Durchgang und erscheint nur mit
    /// "Versteckte Karten"; wieder gezeigt ist sie wieder in "Heute fällig"
    func testTrainerBookmarkAndHide() async throws {
        let (api, _, _) = try await seededAPI(cards: [("Begriff A", "Definition A", nil), ("Begriff B", "Definition B", nil)])
        let deck = FlashcardDeck(api: api)
        try await deck.load()
        selectFirst(deck)
        let trainer = FlashcardTrainer(api: api)
        trainer.start(with: deck.cards)
        try await trainer.toggleBookmark()
        XCTAssertEqual(trainer.current?.i("bookmarked"), 1)
        XCTAssertEqual(trainer.current?.s("question"), "Begriff A", "Lesezeichen laesst die Karte stehen")
        try await trainer.toggleHidden()
        XCTAssertEqual(trainer.cards.count, 1, "versteckt: raus aus dem Durchgang")
        XCTAssertEqual(trainer.current?.s("question"), "Begriff B")
        XCTAssertEqual(trainer.progressText, "1/1")
        let stored = try await cards(api)
        let a = try XCTUnwrap(stored.first { $0.s("question") == "Begriff A" })
        XCTAssertEqual(a.i("hidden"), 1)
        XCTAssertEqual(a.i("bookmarked"), 1)
        trainer.restart()
        XCTAssertEqual(trainer.cards.compactMap { $0.s("question") }, ["Begriff B"], "Neu starten ohne versteckte")
        var o = trainer.options
        o.scope = .bookmarked
        o.progress = [.hidden]
        trainer.apply(o)
        XCTAssertEqual(trainer.cards.compactMap { $0.s("question") }, ["Begriff A"])
        try await trainer.toggleHidden()
        XCTAssertTrue(trainer.empty, "wieder gezeigt: passt nicht mehr zu 'Versteckte Karten'")
        try await deck.load()
        XCTAssertEqual(deck.due.count, 2, "wieder gezeigt: wieder in Heute fällig")
        try await deck.setFlag(deck.all.first { $0.s("question") == "Begriff B" }!, "bookmarked", true)
        XCTAssertEqual(deck.all.filter { $0.i("bookmarked") == 1 }.count, 2)
    }

    /// Versteckte Karten sind nie faellig: nicht in "Heute fällig" und nicht in der Wiederholung, aber in der Liste;
    /// der naechste Termin zaehlt sie nicht mit
    func testHiddenCardIsNotDue() async throws {
        let (api, _, _) = try await seededAPI(cards: [("Sichtbare Frage", "a", nil), ("Versteckte Frage", "b", nil)])
        let deck = FlashcardDeck(api: api)
        try await deck.load()
        selectFirst(deck)
        let hidden = try XCTUnwrap(deck.all.first { $0.s("question") == "Versteckte Frage" })
        try await deck.setFlag(hidden, "hidden", true)
        XCTAssertEqual(deck.due.compactMap { $0.s("question") }, ["Sichtbare Frage"])
        XCTAssertEqual(deck.stack?.i("due"), 1, "Zaehler des Stapels ohne versteckte Karten")
        XCTAssertEqual(deck.all.count, 2, "Liste zeigt die versteckte Karte")
        deck.startReview()
        XCTAssertEqual(deck.queue.compactMap { $0.s("question") }, ["Sichtbare Frage"])
        deck.endSession()
        // versteckte Karte mit altem Termin: kein "naechster Termin" in der Vergangenheit
        let visible = try XCTUnwrap(deck.all.first { $0.s("question") == "Sichtbare Frage" }?.i("id"))
        _ = try await api.value("/api/flashcards/\(visible)/review", method: "POST", body: ["correct": true])
        try await deck.load()
        XCTAssertEqual(deck.due, [])
        XCTAssertEqual(deck.nextDue, "2026-10-28", "nur die sichtbare Karte zaehlt")
        let counter = try await api.value("/api/flashcards?due=true").items
        XCTAssertEqual(counter.count, 0, "Zaehler (Tests-Seite) ohne versteckte Karten")
    }

    /// Pruefpunkt 270 fuer den Trainer: neue Datenquelle beendet den Durchgang, spaete Antworten zaehlen nicht
    func testTrainerStartsOverWhenTheSourceChanges() async throws {
        let (apiA, recA, _) = try await seededAPI(cards: [("Frage aus A", "Antwort A", nil)])
        let (apiB, _, _) = try await seededAPI()
        let trainer = FlashcardTrainer()
        trainer.attach(apiA)
        trainer.start(with: try await cards(apiA))
        trainer.attach(apiB)
        XCTAssertFalse(trainer.active)
        XCTAssertTrue(trainer.source.isEmpty)
        let r = try await trainer.answer(known: true)
        XCTAssertFalse(r)
        XCTAssertEqual(recA.count(suffix: "/api/flashcards/1"), 0)
    }

    // MARK: Tarif

    /// Startargument -UFPlan (nur Debug): fester Tarif ohne StoreKit, Karteikarten nur mit Plus
    func testUFPlanLaunchArgumentGatesFlashcards() async throws {
        let saved = UserDefaults.standard.object(forKey: "UFPlan")
        defer { if let saved { UserDefaults.standard.set(saved, forKey: "UFPlan") } else { UserDefaults.standard.removeObject(forKey: "UFPlan") } }
        let ent = Entitlements(observe: false)
        UserDefaults.standard.set("plus", forKey: "UFPlan")
        await ent.refresh()
        XCTAssertEqual(ent.plan, .plus)
        XCTAssertTrue(ent.allows(.flashcards))
        UserDefaults.standard.set("free", forKey: "UFPlan")
        await ent.refresh()
        XCTAssertEqual(ent.plan, .free)
        XCTAssertEqual(ent.access(.flashcards), .locked(.plus))
        XCTAssertFalse(UFLockedCard.message(.flashcards, access: ent.access(.flashcards)).contains("Bald"))
        // Pro Connect und Pro AI (Schluessel wie in plans.json) enthalten alles aus Plus
        for (arg, plan) in [("pro_connect", UFPlan.proConnect), ("pro_ai", .proAI)] {
            UserDefaults.standard.set(arg, forKey: "UFPlan")
            await ent.refresh()
            XCTAssertEqual(ent.plan, plan, arg)
            XCTAssertTrue(ent.allows(.flashcards), arg)
            XCTAssertNil(ent.pendingPlan, arg)
        }
    }

    // MARK: Seite im Fenster (Bedienungshilfen wie AuditRunde0910AppTests)

    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private struct Hosted {
        let view: UIView
        let toast: UFToastCenter
        let session: Session
        let overlay: UFOverlay
    }

    private func show<V: View>(_ view: V, api: APIClient) throws -> Hosted {
        XCTAssertTrue(Self.accessibilityAutomation(true))
        addTeardownBlock { Self.accessibilityAutomation(false) }
        let overlay = UFOverlay(), toast = UFToastCenter()
        let suite = "uniflow-karten-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let session = Session(local: api, defaults: defaults)
        let root = view
            .modifier(UFModalHost(overlay: overlay))
            .environmentObject(session)
            .environmentObject(UFRouter())
            .environmentObject(ShellState())
            .environmentObject(overlay)
            .environmentObject(toast)
            .environmentObject(StudIPSync())
            .environmentObject(AccountStore(secrets: MemorySecrets(), defaults: defaults, checker: AuthorizedChecker(), observeRevocation: false))
        let frame = CGRect(x: 0, y: 0, width: 1180, height: 1400)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let hosting = UIHostingController(rootView: root)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return Hosted(view: hosting.view, toast: toast, session: session, overlay: overlay)
    }

    @discardableResult
    private func pump(timeout: Double = 10, until done: () -> Bool = { false }) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return done()
    }

    private func elements(in view: UIView) -> [NSObject] {
        view.layoutIfNeeded()
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
            if let o = element as? NSObject {
                if o.accessibilityLabel?.isEmpty == false || o.accessibilityValue?.isEmpty == false { out.append(o) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } }
                }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(view, depth: 0)
        return out
    }

    private func texts(_ view: UIView) -> [String] {
        elements(in: view).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
    }

    private func shows(_ view: UIView, _ text: String) -> Bool { texts(view).contains { $0.contains(text) } }

    private func tap(_ label: String, in view: UIView, exact: Bool = true) -> Bool {
        for e in elements(in: view) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, exact ? l == label : l.contains(label) else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    /// Warten, bis der Knopf da ist, dann genau einmal tippen (ein `pump { tap }` tippt nach dem Umbau der Seite ein
    /// zweites Mal: Dialoge gingen doppelt auf)
    private func tapSoon(_ label: String, in view: UIView) -> Bool {
        // erst die Ausblendung eines vorigen Dialogs abwarten: seine Felder stehen sonst noch im Fenster (type traf sie)
        pump(timeout: 0.7)
        return pump { self.elements(in: view).contains { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel == label } } && tap(label, in: view)
    }

    private func isEnabledButton(_ label: String, in view: UIView) -> Bool? {
        elements(in: view).first { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel == label }
            .map { !$0.accessibilityTraits.contains(.notEnabled) }
    }

    /// Text in das n-te Eingabefeld (TextField mit axis: .vertical ist eine UITextView) wie mit der Tastatur
    private func type(_ text: String, field index: Int, in view: UIView) -> Bool {
        var fields: [UIView] = []
        func visit(_ v: UIView) {
            if v is UITextView || v is UITextField { fields.append(v); return }
            v.subviews.forEach(visit)
        }
        visit(view.window ?? view)
        guard index < fields.count, let input = fields[index] as? UIKeyInput else { return false }
        _ = fields[index].becomeFirstResponder()
        // ans Ende (vorbelegte Felder beim Bearbeiten): wie Tippen hinter dem Text
        if let t = fields[index] as? UITextInput { t.selectedTextRange = t.textRange(from: t.endOfDocument, to: t.endOfDocument) }
        input.insertText(text)
        pump(timeout: 0.2)                                          // die Bindung (@State) uebernimmt den Text erst im naechsten Durchlauf
        return true
    }

    private func dump(_ view: UIView) -> String { texts(view).joined(separator: " | ") }

    /// Seite wie in MainView (die Sperre UFGate(.flashcards) steht in der Seite) mit festem Tarif
    private func gated(_ plan: UFPlan) -> some View {
        CardsPage(entitlements: Entitlements(observe: false, plan: plan))
    }

    /// Free (auch nach der Probe, Entscheidung 04.11.2026): eigene Stapel und Karten bleiben sichtbar, nur lesend – oben
    /// der Hinweis mit dem Weg zur Tarifwahl, kein Anlegen, Bearbeiten, Loeschen, Wiederholen oder Ueben
    func testFreeShowsTheCardsReadOnly() throws {
        let (api, rec, _) = try awaiting { try await self.seededAPI(cards: [("Geheime Frage", "Antwort", nil)]) }
        let page = try show(gated(.free), api: api)
        XCTAssertTrue(pump { self.shows(page.view, "Mit Plus übst und bearbeitest du deine Karten wieder.") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Tarife ansehen"), dump(page.view))
        XCTAssertTrue(shows(page.view, "Stapel öffnen: Ohne Modul"), "Stapel bleiben sichtbar: \(dump(page.view))")
        XCTAssertGreaterThanOrEqual(rec.count("GET", "/api/flashcards"), 1, "Lesen bleibt frei")
        for hidden in ["Karte anlegen", "Neuer Stapel", "Stapel bearbeiten: Ohne Modul", "Stapel löschen: Ohne Modul"] {
            XCTAssertFalse(shows(page.view, hidden), "\(hidden): \(dump(page.view))")
        }
        XCTAssertFalse(shows(page.view, "Enthalten ab StudiNow Plus"), "mit Karten keine grosse Sperrkarte")
        XCTAssertTrue(tap("Stapel öffnen: Ohne Modul", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Geheime Frage") }, "Karten lesbar: \(dump(page.view))")
        for hidden in ["Wiederholen", "Frei üben", "Üben", "Karte bearbeiten: Geheime Frage", "Karte löschen: Geheime Frage", "Lesezeichen setzen: Geheime Frage"] {
            XCTAssertFalse(texts(page.view).contains(hidden), "\(hidden): \(dump(page.view))")
        }
        XCTAssertTrue(shows(page.view, "Alle Stapel"), "zurueck zur Liste")
        XCTAssertEqual(rec.count("POST", "/api/flashcards/1/review"), 0)
    }

    /// Free ohne eigene Karten: die Sperrkarte mit dem Weg zu Plus statt "Lege deine erste Karte an"
    func testFreeWithoutCardsShowsTheLockCard() throws {
        let (api, _, _) = try awaiting { try await self.seededAPI() }
        let page = try show(gated(.free), api: api)
        XCTAssertTrue(pump { self.shows(page.view, "Mit StudiNow Plus freischalten") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Eigene Karteikarten mit Wiederholung"), dump(page.view))
        XCTAssertTrue(shows(page.view, "Enthalten ab StudiNow Plus"), dump(page.view))
        XCTAssertFalse(shows(page.view, "Erste Karte anlegen"))
        XCTAssertFalse(shows(page.view, "Karte anlegen"))
        XCTAssertFalse(shows(page.view, "bald"))
    }

    /// Probe laeuft: alles wie Plus; Probe vorbei: Lesemodus mit denselben Karten
    func testTrialFullThenReadOnlyAfterTheTrial() throws {
        let (api, _, _) = try awaiting { try await self.seededAPI(cards: [("Probefrage", "Antwort", nil)]) }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let running = Entitlements(observe: false)
        running.useLocalTrial(startedAt: t0, now: t0)
        let inTrial = try show(CardsPage(entitlements: running), api: api)
        XCTAssertTrue(pump { self.shows(inTrial.view, "Karte anlegen") }, dump(inTrial.view))
        XCTAssertTrue(shows(inTrial.view, "Neuer Stapel"))
        XCTAssertFalse(shows(inTrial.view, "Mit Plus übst"))
        inTrial.view.window?.isHidden = true
        let over = Entitlements(observe: false)
        over.useLocalTrial(startedAt: t0, now: t0.addingTimeInterval(7 * 86_400))
        let after = try show(CardsPage(entitlements: over), api: api)
        XCTAssertTrue(pump { self.shows(after.view, "Mit Plus übst und bearbeitest du deine Karten wieder.") }, dump(after.view))
        XCTAssertTrue(shows(after.view, "Stapel öffnen: Ohne Modul"), "Karten aus der Probe bleiben: \(dump(after.view))")
        XCTAssertFalse(shows(after.view, "Karte anlegen"))
    }

    func testPlusEmptyStateThenCreateACard() throws {
        let (api, _, _) = try awaiting { try await self.seededAPI() }
        let page = try show(gated(.plus), api: api)
        XCTAssertTrue(pump { self.shows(page.view, "Noch keine Karteikarten") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "vorn die Frage, hinten die Antwort"))
        XCTAssertFalse(shows(page.view, "Heute fällig"), "leer: kein Wiederholen")
        XCTAssertTrue(tap("Erste Karte anlegen", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Modul (optional)") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Dokument (optional)"))
        XCTAssertTrue(shows(page.view, "Stapel"), "Stapelwahl ist Pflicht: \(dump(page.view))")
        XCTAssertTrue(shows(page.view, "Name des neuen Stapels"), "ohne Stapel: Neuer Stapel … mit Namensvorgabe: \(dump(page.view))")
        XCTAssertEqual(isEnabledButton("Anlegen", in: page.view), false, "ohne Frage und Antwort gesperrt")
        XCTAssertTrue(type("Was ist ein Eigenwert?", field: 0, in: page.view))
        XCTAssertTrue(type("Ein λ mit Av = λv für ein v ≠ 0", field: 1, in: page.view))
        XCTAssertTrue(pump { self.isEnabledButton("Anlegen", in: page.view) == true }, dump(page.view))
        XCTAssertTrue(tap("Anlegen", in: page.view))
        XCTAssertTrue(pump { page.toast.message == "Karte angelegt" }, page.toast.message ?? "-")
        XCTAssertTrue(pump { self.shows(page.view, "Heute fällig (1)") }, "Stapel der neuen Karte ist gewaehlt: \(dump(page.view))")
        XCTAssertTrue(shows(page.view, "Was ist ein Eigenwert?"))
        XCTAssertTrue(shows(page.view, "Ohne Modul"), "Name des neuen Stapels")
        XCTAssertTrue(shows(page.view, "Nur dieser Stapel wird abgefragt"))
        XCTAssertTrue(page.overlay.modals.isEmpty, "Dialog geschlossen")
        let stored = try awaiting { try await self.cards(api) }
        XCTAssertEqual(stored.map { $0.s("question") ?? "" }, ["Was ist ein Eigenwert?"])
        XCTAssertEqual(stored.first?.s("answer"), "Ein λ mit Av = λv für ein v ≠ 0")
        XCTAssertEqual(stored.first?.s("stack_name"), "Ohne Modul")
        // zurueck zur Stapelliste: der Stapel mit Modul, Zahl der Karten, faellig und zuletzt geuebt
        XCTAssertTrue(tap("Alle Stapel", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Stapel öffnen: Ohne Modul") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Ohne Modul · 1 Karte · Heute fällig (1) · noch nicht geübt"), dump(page.view))
    }

    func testReviewWithRevealRightAndWrong() throws {
        let (api, rec, _) = try awaiting {
            try await self.seededAPI(cards: [("Erste Frage", "Erste Antwort", "f-la"), ("Zweite Frage", "Zweite Antwort", nil)])
        }
        let page = try show(gated(.plus), api: api)
        // Stapelliste je Modul: der Dateistapel unter dem Modul, der freie unter "Ohne Modul"; je "Heute fällig (1)"
        XCTAssertTrue(pump { self.shows(page.view, "Stapel öffnen: LA_Skript.pdf") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Lineare Algebra Test · 1 Karte · Heute fällig (1) · noch nicht geübt"), "Stapelzeile: \(dump(page.view))")
        XCTAssertTrue(shows(page.view, "Stapel öffnen: Ohne Modul"))
        XCTAssertTrue(shows(page.view, "2 heute fällig"))
        XCTAssertFalse(shows(page.view, "Wiederholen"), "ohne gewaehlten Stapel keine Wiederholung")
        XCTAssertTrue(tap("Stapel öffnen: LA_Skript.pdf", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Heute fällig (1)") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Karten im Stapel"))
        XCTAssertTrue(shows(page.view, "Nur dieser Stapel wird abgefragt"))
        XCTAssertTrue(shows(page.view, "heute fällig"))
        XCTAssertFalse(shows(page.view, "Zweite Frage"), "Karten des anderen Stapels bleiben draussen")
        XCTAssertTrue(tap("Wiederholen", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Karte 1 von 1") }, "nie gemischt: \(dump(page.view))")
        XCTAssertTrue(shows(page.view, "Frage: Erste Frage"), dump(page.view))
        XCTAssertFalse(shows(page.view, "Antwort: Erste Antwort"), "verdeckt")
        XCTAssertFalse(tap("Richtig", in: page.view), "vor dem Aufdecken kein Bewerten")
        XCTAssertTrue(tap("Antwort zeigen", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Antwort: Erste Antwort") }, dump(page.view))
        XCTAssertTrue(tap("Richtig", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Wiederholung geschafft") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "1 Karte aus „LA_Skript.pdf“ wiederholt: 1 richtig, 0 falsch."), dump(page.view))
        XCTAssertTrue(tap("Fertig", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Heute fällig (0)") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Die nächste Wiederholung ist am 28.10.2026."), dump(page.view))
        // der andere Stapel: Tippen auf die Karte deckt auf, Falsch
        XCTAssertTrue(tap("Alle Stapel", in: page.view), dump(page.view))
        XCTAssertTrue(tapSoon("Stapel öffnen: Ohne Modul", in: page.view), dump(page.view))
        XCTAssertTrue(tapSoon("Wiederholen", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Frage: Zweite Frage") }, dump(page.view))
        XCTAssertTrue(tap("Frage: Zweite Frage", in: page.view), "Tippen auf die Karte deckt auf")
        XCTAssertTrue(pump { self.shows(page.view, "Antwort: Zweite Antwort") }, dump(page.view))
        XCTAssertTrue(tap("Falsch", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Wiederholung geschafft") }, dump(page.view))
        XCTAssertEqual(rec.count(suffix: "/review"), 2)
        let stored = try awaiting { try await self.cards(api) }
        XCTAssertEqual(stored.map { $0.i("box") ?? 0 }, [1, 2])
        XCTAssertEqual(stored.map { $0.s("due") ?? "" }, ["2026-10-27", "2026-10-28"])
    }

    func testHiddenCardIsNotInDueTodayOnThePage() throws {
        let (api, _, _) = try awaiting {
            try await self.seededAPI(cards: [("Sichtbare Frage", "Antwort A", nil), ("Versteckte Frage", "Antwort B", nil)])
        }
        try awaiting {
            let stored = try await self.cards(api)
            let id = try XCTUnwrap(stored.first { $0.s("question") == "Versteckte Frage" }?.i("id"))
            _ = try await api.value("/api/flashcards/\(id)", method: "PATCH", body: ["hidden": true])
        }
        let page = try show(gated(.plus), api: api)
        XCTAssertTrue(tapSoon("Stapel öffnen: Ohne Modul", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Heute fällig (1)") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Versteckte Frage"), "in der Liste: \(dump(page.view))")
        XCTAssertTrue(shows(page.view, "versteckt, nicht in „Heute fällig“"), dump(page.view))
        XCTAssertTrue(tap("Wiederholen", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Karte 1 von 1") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Frage: Sichtbare Frage"), dump(page.view))
    }

    func testDeleteAsksFirst() throws {
        let (api, rec, _) = try awaiting { try await self.seededAPI(cards: [("Zu löschende Frage", "Antwort", nil)]) }
        let page = try show(gated(.plus), api: api)
        XCTAssertTrue(tapSoon("Stapel öffnen: Ohne Modul", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Zu löschende Frage") }, dump(page.view))
        XCTAssertTrue(tap("Karte löschen: Zu löschende Frage", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Karte löschen?") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "lässt sich nicht rückgängig machen"))
        XCTAssertTrue(tap("Abbrechen", in: page.view))
        XCTAssertTrue(pump { page.overlay.modals.isEmpty })
        XCTAssertEqual(rec.count(suffix: "/api/flashcards/1"), 0, "Abbrechen loescht nichts")
        XCTAssertEqual(try awaiting { try await self.cards(api) }.count, 1)
        XCTAssertTrue(tap("Karte löschen: Zu löschende Frage", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Karte löschen?") })
        XCTAssertTrue(tap("Löschen", in: page.view))
        XCTAssertTrue(pump { page.toast.message == "Karte gelöscht" }, page.toast.message ?? "-")
        XCTAssertTrue(pump { self.shows(page.view, "Noch keine Karte in diesem Stapel.") }, "der Stapel bleibt, leer: \(dump(page.view))")
        XCTAssertEqual(try awaiting { try await self.cards(api) }, [])
        // Stapel loeschen: Rueckfrage, Abbrechen loescht nichts, dann weg -> leere Seite
        XCTAssertTrue(tap("Alle Stapel", in: page.view))
        XCTAssertTrue(tapSoon("Stapel löschen: Ohne Modul", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Stapel löschen?") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Der Stapel ist leer und wird gelöscht."))
        XCTAssertTrue(tap("Abbrechen", in: page.view))
        XCTAssertTrue(pump { page.overlay.modals.isEmpty })
        XCTAssertEqual(rec.count("DELETE", "/api/flashcard-stacks/1"), 0)
        XCTAssertTrue(tap("Stapel löschen: Ohne Modul", in: page.view))
        XCTAssertTrue(tapSoon("Löschen", in: page.view), dump(page.view))
        XCTAssertTrue(pump { page.toast.message == "Stapel gelöscht" }, page.toast.message ?? "-")
        XCTAssertTrue(pump { self.shows(page.view, "Noch keine Karteikarten") }, dump(page.view))
        XCTAssertEqual(rec.count("DELETE", "/api/flashcard-stacks/1"), 1)
    }

    /// "Bearbeiten" aus der Liste, aus der Wiederholung und aus dem Trainer: derselbe Dialog, der Lernstand bleibt
    func testEditFromListReviewAndTrainerOnThePage() throws {
        let (api, rec, _) = try awaiting { try await self.seededAPI(cards: [("Alte Frage", "Alte Antwort", nil)]) }
        let page = try show(gated(.plus), api: api)
        XCTAssertTrue(tapSoon("Stapel öffnen: Ohne Modul", in: page.view), dump(page.view))
        XCTAssertTrue(tapSoon("Karte bearbeiten: Alte Frage", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Karte bearbeiten") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Fach 1 und Termin der Wiederholung bleiben beim Bearbeiten erhalten."), dump(page.view))
        XCTAssertFalse(shows(page.view, "Dokument (optional)"), "beim Bearbeiten kein Dokumentfeld")
        XCTAssertTrue(type(" (neu)", field: 0, in: page.view))
        XCTAssertTrue(pump { self.isEnabledButton("Speichern", in: page.view) == true }, dump(page.view))
        XCTAssertTrue(tap("Speichern", in: page.view))
        XCTAssertTrue(pump { page.toast.message == "Karte gespeichert" }, page.toast.message ?? "-")
        XCTAssertTrue(pump { self.shows(page.view, "Alte Frage (neu)") }, dump(page.view))
        XCTAssertEqual(rec.count("PATCH", "/api/flashcards/1"), 1)
        XCTAssertEqual(rec.count(suffix: "/review"), 0)
        var stored = try awaiting { try await self.cards(api) }
        XCTAssertEqual(stored.first?.s("question"), "Alte Frage (neu)")
        XCTAssertEqual(stored.first?.i("box"), 1)
        // aus der Wiederholung: "Bearbeiten" im Kopf, Abbrechen laesst die Karte stehen
        XCTAssertTrue(tap("Wiederholen", in: page.view), dump(page.view))
        XCTAssertTrue(tapSoon("Bearbeiten", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Karte bearbeiten") }, dump(page.view))
        XCTAssertTrue(type(" 2", field: 1, in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Alte Antwort 2") }, "Eingabe angekommen: \(dump(page.view))")
        XCTAssertTrue(tap("Speichern", in: page.view))
        XCTAssertTrue(pump { page.toast.message == "Karte gespeichert" && page.overlay.modals.isEmpty }, page.toast.message ?? "-")
        XCTAssertTrue(pump { self.shows(page.view, "Karte 1 von 1") }, "Wiederholung laeuft weiter: \(dump(page.view))")
        XCTAssertTrue(tap("Antwort zeigen", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Antwort: Alte Antwort 2") }, dump(page.view))
        XCTAssertTrue(tap("Beenden", in: page.view))
        // aus dem Trainer: Symbol "Bearbeiten" auf der Karte, der neue Text erscheint sofort
        XCTAssertTrue(tapSoon("Üben", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Begriff: Alte Frage (neu)") }, dump(page.view))
        XCTAssertTrue(tapSoon("Bearbeiten", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Karte bearbeiten") }, dump(page.view))
        XCTAssertTrue(type(" 3", field: 0, in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Alte Frage (neu) 3") }, "Eingabe angekommen: \(dump(page.view))")
        XCTAssertTrue(tap("Speichern", in: page.view))
        XCTAssertTrue(pump { page.toast.message == "Karte gespeichert" && page.overlay.modals.isEmpty }, page.toast.message ?? "-")
        XCTAssertTrue(pump { self.shows(page.view, "Begriff: Alte Frage (neu) 3") }, "Trainer uebernimmt den Text: \(dump(page.view))")
        XCTAssertTrue(shows(page.view, "Karte 1 von 1"))
        stored = try awaiting { try await self.cards(api) }
        XCTAssertEqual(stored.first?.s("question"), "Alte Frage (neu) 3")
        XCTAssertEqual(stored.first?.i("box"), 1, "dreimal bearbeitet, Fach bleibt")
        XCTAssertEqual(rec.count(suffix: "/review"), 0)
    }

    /// Stapel auf der Seite: neuer Stapel mit Modul, umbenennen, Loeschen mit Umzug der Karten (Lernstand bleibt)
    func testStackDialogsOnThePage() throws {
        let (api, rec, _) = try awaiting { try await self.seededAPI(cards: [("Frage A", "a", nil), ("Frage B", "b", "f-la")]) }
        let page = try show(gated(.plus), api: api)
        XCTAssertTrue(pump { self.shows(page.view, "Stapel öffnen: Ohne Modul") }, dump(page.view))
        XCTAssertFalse(shows(page.view, "Lehrwoche"), "ohne Lehrwochen keine Filterzeile")
        XCTAssertTrue(tapSoon("Neuer Stapel", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Neuer Stapel") && self.shows(page.view, "Name") }, dump(page.view))
        XCTAssertEqual(isEnabledButton("Anlegen", in: page.view), false, "ohne Namen gesperrt")
        XCTAssertTrue(type("Klausur", field: 0, in: page.view))
        XCTAssertTrue(pump { self.isEnabledButton("Anlegen", in: page.view) == true }, dump(page.view))
        XCTAssertTrue(tap("Anlegen", in: page.view))
        XCTAssertTrue(pump { page.toast.message == "Stapel angelegt" }, page.toast.message ?? "-")
        XCTAssertTrue(pump { self.shows(page.view, "Stapel öffnen: Klausur") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Eigene · Allgemein · Ohne Modul · 0 Karten · Heute fällig (0) · noch nicht geübt"), "Etikett und Zeile: \(dump(page.view))")
        XCTAssertEqual(rec.count("POST", "/api/flashcard-stacks"), 1)
        // umbenennen
        XCTAssertTrue(tapSoon("Stapel bearbeiten: Klausur", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Stapel bearbeiten") }, dump(page.view))
        XCTAssertTrue(type(" 2", field: 0, in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Klausur 2") }, "Eingabe angekommen: \(dump(page.view))")
        XCTAssertTrue(tap("Speichern", in: page.view))
        XCTAssertTrue(pump { page.toast.message == "Stapel gespeichert" && page.overlay.modals.isEmpty }, page.toast.message ?? "-")
        XCTAssertTrue(pump { self.shows(page.view, "Stapel öffnen: Klausur 2") }, dump(page.view))
        // loeschen eines Stapels mit Karten: Rueckfrage mit Wahl
        XCTAssertTrue(tapSoon("Stapel löschen: Ohne Modul", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Was soll mit der Karte geschehen?") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Die Karten und ihr Lernstand werden gelöscht."), dump(page.view))
        XCTAssertTrue(tap("Abbrechen", in: page.view))
        XCTAssertTrue(pump { page.overlay.modals.isEmpty })
        XCTAssertEqual(try awaiting { try await self.cards(api) }.count, 2, "Abbrechen loescht nichts")
        // Umzug ohne Oberflaeche (Auswahlmenue), der Lernstand bleibt
        try awaiting {
            let deck = FlashcardDeck(api: api)
            try await deck.load()
            let from = try XCTUnwrap(deck.stacks.first { $0.s("name") == "Ohne Modul" }?.i("id"))
            let to = try XCTUnwrap(deck.stacks.first { $0.s("name") == "Klausur 2" }?.i("id"))
            try await deck.deleteStack(from, moveTo: to)
            XCTAssertEqual(deck.stacks.first { $0.i("id") == to }?.i("cards"), 1)
        }
        XCTAssertEqual(rec.count("DELETE", "/api/flashcard-stacks/1"), 1)
    }

    /// Pruefpunkt 270 auf der Seite: neue Datenquelle (Konto- oder Hochschulwechsel) -> Stapel von vorn
    func testPageStartsOverWhenTheSourceChanges() throws {
        let (apiA, _, _) = try awaiting { try await self.seededAPI(cards: [("Frage aus A", "Antwort A", nil)]) }
        let (apiB, _, _) = try awaiting { try await self.seededAPI(cards: [("Frage aus B", "Antwort B", nil), ("Noch eine aus B", "B2", nil)]) }
        let page = try show(gated(.plus), api: apiA)
        XCTAssertTrue(tapSoon("Stapel öffnen: Ohne Modul", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Heute fällig (1)") }, dump(page.view))
        XCTAssertTrue(tap("Wiederholen", in: page.view))
        XCTAssertTrue(tap("Antwort zeigen", in: page.view) || tapSoon("Antwort zeigen", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Antwort: Antwort A") }, dump(page.view))
        page.session.useLocal(apiB)
        XCTAssertTrue(pump { self.shows(page.view, "Heute fällig (2)") }, "Stapelliste von B: \(dump(page.view))")
        XCTAssertFalse(shows(page.view, "Karte 1 von"), "keine laufende Wiederholung aus A")
        XCTAssertFalse(shows(page.view, "Frage aus A"))
        XCTAssertTrue(tap("Stapel öffnen: Ohne Modul", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Frage aus B") }, dump(page.view))
        XCTAssertEqual(try awaiting { try await self.cards(apiA) }.first?.i("box"), 1, "in A nichts bewertet")
    }

    /// Seite: "Frei üben" -> grosse Karte, Umdrehen, Gewusst / Nicht gewusst mit Zaehlern, Vorherige, Optionen
    func testTrainerOnThePage() throws {
        let (api, rec, _) = try awaiting {
            try await self.seededAPI(cards: [("Erster Begriff", "Erste Definition", nil), ("Zweiter Begriff", "Zweite Definition", nil)])
        }
        let page = try show(gated(.plus), api: api)
        XCTAssertTrue(tapSoon("Stapel öffnen: Ohne Modul", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Frei üben") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Ändert den Wiederholungsplan nicht"), dump(page.view))
        XCTAssertTrue(tap("Üben", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Begriff: Erster Begriff") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Nicht gewusst: 0"), dump(page.view))
        XCTAssertTrue(shows(page.view, "Gewusst: 0"))
        XCTAssertTrue(shows(page.view, "Karte 1 von 2"))
        XCTAssertEqual(isEnabledButton("Vorherige", in: page.view), false, "noch nichts zurueckzunehmen")
        XCTAssertTrue(tap("Begriff: Erster Begriff", in: page.view), "Tippen dreht die Karte")
        XCTAssertTrue(pump { self.shows(page.view, "Definition: Erste Definition") }, dump(page.view))
        XCTAssertTrue(tap("Gewusst", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Gewusst: 1") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Begriff: Zweiter Begriff"), "naechste Karte vorn: \(dump(page.view))")
        XCTAssertTrue(shows(page.view, "Karte 2 von 2"))
        XCTAssertTrue(pump { self.isEnabledButton("Vorherige", in: page.view) == true }, dump(page.view))
        XCTAssertTrue(tap("Vorherige", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Gewusst: 0") && self.shows(page.view, "Begriff: Erster Begriff") }, dump(page.view))
        XCTAssertTrue(tap("Nicht gewusst", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Nicht gewusst: 1") }, dump(page.view))
        XCTAssertTrue(tap("Gewusst", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Durchgang geschafft") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "2 Karten geübt: 1 gewusst, 1 nicht gewusst."), dump(page.view))
        XCTAssertEqual(rec.count(suffix: "/review"), 0, "Wiederholungsplan unberuehrt")
        // Optionen: nur Falsch, zuerst die Definition
        XCTAssertTrue(tap("Optionen", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Filter anwenden") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Lesezeichen (0)"))
        XCTAssertTrue(shows(page.view, "Versteckte Karten (0)"))
        XCTAssertTrue(tap("Richtig (1)", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "1 Karte passt.") }, dump(page.view))
        XCTAssertTrue(tap("Noch nicht gelernt (0)", in: page.view))
        XCTAssertTrue(tap("Definition", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "1 Karte passt.") }, dump(page.view))
        XCTAssertTrue(tap("Filter anwenden", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Definition: Erste Definition") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Karte 1 von 1"))
        XCTAssertTrue(tap("Üben beenden", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Heute fällig (2)") }, dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "1 richtig · 1 falsch · 0 noch nicht gelernt") }, "neu geladen: \(dump(page.view))")
    }

    /// Ergebnis einer async-Aufgabe aus einem synchronen Test (die Seitentests pumpen die RunLoop)
    private func awaiting<T>(_ body: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        let done = expectation(description: "async")
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(result).get()
    }
}
