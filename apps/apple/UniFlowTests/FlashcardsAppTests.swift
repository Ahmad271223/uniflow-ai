import SwiftUI
import UIKit
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Eigene Karteikarten ohne PC (M8): Stapel der Seite (Anlegen, Liste je Modul, Wiederholen mit Aufdecken und
/// Richtig/Falsch, Loeschen), Pruefpunkte 269 (keine doppelte Bewertung) und 270 (neuer Stapel nach Konto- oder
/// Hochschulwechsel), Tarif Free/Plus (UFGate, Startargument -UFPlan) und Trennung je Container. Lokales Backend im
/// Temp-Ordner mit fester Uhr, nur erfundene Kurse, Dateien und Karten, kein Netz.
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

    // MARK: Stapel (ohne Oberflaeche)

    func testCreateGroupsByModuleAndDueToday() async throws {
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
        XCTAssertEqual(deck.all.count, 4)
        XCTAssertEqual(deck.due.count, 4, "neue Karten sind sofort faellig")
        // Liste je Modul in der Reihenfolge der Module, "Ohne Modul" zuletzt
        let order = deck.modules.compactMap { $0.s("name") }
        XCTAssertEqual(deck.groups.map(\.title), order + ["Ohne Modul"])
        XCTAssertEqual(deck.groups.last?.cards.map { $0.s("question") ?? "" }, ["Seminarfrage", "Freie Frage"])
        XCTAssertEqual(deck.fileTitle(stored.last!), "LA_Skript.pdf")
        XCTAssertEqual(deck.groupTitle(stored.last!), "Lineare Algebra Test")
        XCTAssertNil(deck.fileTitle(stored.first { $0.s("question") == "Freie Frage" }!))
    }

    /// Pruefpunkt 269: zwei schnelle Tipps auf "Richtig" bewerten die Karte einmal; ohne Aufdecken keine Bewertung
    func testReviewRatesEachCardOnceEvenWithDoubleTap() async throws {
        let (api, rec, _) = try await seededAPI(cards: [("Frage A", "Antwort A", nil), ("Frage B", "Antwort B", "f-la")])
        let deck = FlashcardDeck(api: api)
        try await deck.load()
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
        XCTAssertEqual(deck.due.count, 2)
        // gleiche Quelle noch einmal: nichts wird zurueckgesetzt
        deck.startReview()
        deck.attach(apiB)
        XCTAssertTrue(deck.inSession)
    }

    func testDeleteRemovesCardAlsoFromRunningReview() async throws {
        let (api, rec, _) = try await seededAPI(cards: [("Frage 1", "A1", nil), ("Frage 2", "A2", nil)])
        let deck = FlashcardDeck(api: api)
        try await deck.load()
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
        input.insertText(text)
        return true
    }

    private func dump(_ view: UIView) -> String { texts(view).joined(separator: " | ") }

    /// Seite wie in MainView (die Sperre UFGate(.flashcards) steht in der Seite) mit festem Tarif
    private func gated(_ plan: UFPlan) -> some View {
        CardsPage(entitlements: Entitlements(observe: false, plan: plan))
    }

    func testFreeShowsTheLockCardAndLoadsNoCards() throws {
        let (api, rec, _) = try awaiting { try await self.seededAPI(cards: [("Geheime Frage", "Antwort", nil)]) }
        let page = try show(gated(.free), api: api)
        XCTAssertTrue(pump { self.shows(page.view, "Mit Studora Plus freischalten") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Karteikarten"), "Seitenkopf bleibt: \(dump(page.view))")
        XCTAssertTrue(shows(page.view, "Eigene Karteikarten mit Wiederholung"), dump(page.view))
        XCTAssertTrue(shows(page.view, "Enthalten ab Studora Plus"), dump(page.view))
        XCTAssertFalse(shows(page.view, "Karte anlegen"))
        XCTAssertFalse(shows(page.view, "Geheime Frage"))
        XCTAssertFalse(shows(page.view, "bald"))
        XCTAssertEqual(rec.count("GET", "/api/flashcards"), 0, "ohne Plus keine Abfrage der Karten")
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
        XCTAssertEqual(isEnabledButton("Anlegen", in: page.view), false, "ohne Frage und Antwort gesperrt")
        XCTAssertTrue(type("Was ist ein Eigenwert?", field: 0, in: page.view))
        XCTAssertTrue(type("Ein λ mit Av = λv für ein v ≠ 0", field: 1, in: page.view))
        XCTAssertTrue(pump { self.isEnabledButton("Anlegen", in: page.view) == true }, dump(page.view))
        XCTAssertTrue(tap("Anlegen", in: page.view))
        XCTAssertTrue(pump { page.toast.message == "Karte angelegt" }, page.toast.message ?? "-")
        XCTAssertTrue(pump { self.shows(page.view, "Heute fällig (1)") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Was ist ein Eigenwert?"))
        XCTAssertTrue(shows(page.view, "Ohne Modul"))
        XCTAssertTrue(page.overlay.modals.isEmpty, "Dialog geschlossen")
        let stored = try awaiting { try await self.cards(api) }
        XCTAssertEqual(stored.map { $0.s("question") ?? "" }, ["Was ist ein Eigenwert?"])
        XCTAssertEqual(stored.first?.s("answer"), "Ein λ mit Av = λv für ein v ≠ 0")
    }

    func testReviewWithRevealRightAndWrong() throws {
        let (api, rec, _) = try awaiting {
            try await self.seededAPI(cards: [("Erste Frage", "Erste Antwort", "f-la"), ("Zweite Frage", "Zweite Antwort", nil)])
        }
        let page = try show(gated(.plus), api: api)
        XCTAssertTrue(pump { self.shows(page.view, "Heute fällig (2)") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Alle Karten"))
        XCTAssertTrue(shows(page.view, "Lineare Algebra Test"), "Liste je Modul: \(dump(page.view))")
        XCTAssertTrue(shows(page.view, "Ohne Modul"))
        XCTAssertTrue(shows(page.view, "heute fällig"))
        XCTAssertTrue(tap("Wiederholen", in: page.view), dump(page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Karte 1 von 2") }, dump(page.view))
        // neueste zuerst wie am PC: die zweite Karte
        XCTAssertTrue(shows(page.view, "Frage: Zweite Frage"), dump(page.view))
        XCTAssertFalse(shows(page.view, "Antwort: Zweite Antwort"), "verdeckt")
        XCTAssertFalse(tap("Richtig", in: page.view), "vor dem Aufdecken kein Bewerten")
        XCTAssertTrue(tap("Antwort zeigen", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Antwort: Zweite Antwort") }, dump(page.view))
        XCTAssertTrue(tap("Richtig", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Karte 2 von 2") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Frage: Erste Frage"))
        XCTAssertTrue(shows(page.view, "Lineare Algebra Test"))
        XCTAssertTrue(tap("Frage: Erste Frage", in: page.view), "Tippen auf die Karte deckt auf")
        XCTAssertTrue(pump { self.shows(page.view, "Antwort: Erste Antwort") }, dump(page.view))
        XCTAssertTrue(tap("Falsch", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Wiederholung geschafft") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "2 Karten wiederholt: 1 richtig, 1 falsch."), dump(page.view))
        XCTAssertEqual(rec.count(suffix: "/review"), 2)
        XCTAssertTrue(tap("Fertig", in: page.view))
        XCTAssertTrue(pump { self.shows(page.view, "Heute fällig (0)") }, dump(page.view))
        XCTAssertTrue(shows(page.view, "Die nächste Wiederholung ist am 27.10.2026."), dump(page.view))
        let stored = try awaiting { try await self.cards(api) }
        XCTAssertEqual(stored.map { $0.i("box") ?? 0 }, [2, 1])
        XCTAssertEqual(stored.map { $0.s("due") ?? "" }, ["2026-10-28", "2026-10-27"])
    }

    func testDeleteAsksFirst() throws {
        let (api, rec, _) = try awaiting { try await self.seededAPI(cards: [("Zu löschende Frage", "Antwort", nil)]) }
        let page = try show(gated(.plus), api: api)
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
        XCTAssertTrue(pump { self.shows(page.view, "Noch keine Karteikarten") }, dump(page.view))
        XCTAssertEqual(try awaiting { try await self.cards(api) }, [])
    }

    /// Pruefpunkt 270 auf der Seite: neue Datenquelle (Konto- oder Hochschulwechsel) -> Stapel von vorn
    func testPageStartsOverWhenTheSourceChanges() throws {
        let (apiA, _, _) = try awaiting { try await self.seededAPI(cards: [("Frage aus A", "Antwort A", nil)]) }
        let (apiB, _, _) = try awaiting { try await self.seededAPI(cards: [("Frage aus B", "Antwort B", nil), ("Noch eine aus B", "B2", nil)]) }
        let page = try show(gated(.plus), api: apiA)
        XCTAssertTrue(pump { self.shows(page.view, "Heute fällig (1)") }, dump(page.view))
        XCTAssertTrue(tap("Wiederholen", in: page.view))
        XCTAssertTrue(tap("Antwort zeigen", in: page.view) || pump { self.tap("Antwort zeigen", in: page.view) })
        XCTAssertTrue(pump { self.shows(page.view, "Antwort: Antwort A") }, dump(page.view))
        page.session.useLocal(apiB)
        XCTAssertTrue(pump { self.shows(page.view, "Heute fällig (2)") }, dump(page.view))
        XCTAssertFalse(shows(page.view, "Karte 1 von"), "keine laufende Wiederholung aus A")
        XCTAssertFalse(shows(page.view, "Frage aus A"))
        XCTAssertTrue(shows(page.view, "Frage aus B"))
        XCTAssertEqual(try awaiting { try await self.cards(apiA) }.first?.i("box"), 1, "in A nichts bewertet")
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
