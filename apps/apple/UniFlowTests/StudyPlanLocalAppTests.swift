import SwiftUI
import UIKit
import XCTest
import UniFlowCore
@testable import UniFlow

/// S6 im lokalen Modus ohne PC: Lernpaket ueber den Dialog "Neues Lernpaket" anlegen, im Lernkalender sehen, im
/// Lernpaket abhaken, Uebersicht zeigt es; "Plan erstellen" legt die Lernpakete in die freien Fenster neben die Termine
/// des Stundenplans. Erfundene Seed-Daten (Kurse, Stud.IP-Dateien, Stundenplan), Uhr eingefroren auf Montag,
/// 26.10.2026, 07:30 Europe/Berlin. Bedient wird ueber den Bedienungshilfen-Baum (Knoepfe ausloesen, Texte lesen).
@MainActor
final class StudyPlanLocalAppTests: XCTestCase {

    /// Merkt sich Methode, Pfad und Status jeder Anfrage an das lokale Backend
    final class RecordingTransport: APITransport, @unchecked Sendable {
        let inner: LocalTransport
        private let lock = NSLock()
        private var log: [(method: String, path: String, status: Int)] = []

        init(_ inner: LocalTransport) { self.inner = inner }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let r = try await inner.send(request)
            lock.withLock { log.append((request.httpMethod ?? "GET", request.url?.path ?? "", r.1.statusCode)) }
            return r
        }

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

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-s6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Unix-Zeit einer Berliner Ortszeit
    private func ts(_ local: String) -> SQLiteValue {
        .integer(Int64(UniFlowClock.fixed(berlin: local)!.now.timeIntervalSince1970))
    }

    /// Lokales Backend mit Seed: zwei Faecher (Vorlesung + Uebung, Physik) mit Dateien in den Lehrwochen 1 und 2
    /// (Vorlesungsbeginn 12.10.), eine Begruessung ohne Fach, Stundenplan mit Vorlesung und Uebung am Montag und
    /// Physik am Mittwoch. Einstellungen wie neu (4 Stunden, 2 Faecher, ohne Wochentest, 30 Minuten Fahrt).
    private func seededAPI() async throws -> (APIClient, RecordingTransport) {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-10-26T07:30:00")!)
        let backend = try await host.backend()
        let courses: [(String, String)] = [("k-ma", "Testmathematik I"), ("k-ma-ue", "Übung zu Testmathematik I"),
                                           ("k-ph", "Testphysik"), ("k-erst", "Begrüßung der Erstsemester")]
        let files: [(String, String, String, String?, String)] = [
            ("f-v1", "k-ma", "VL01.pdf", "Vorlesung", "2026-10-12T10:00"), ("f-u1", "k-ma-ue", "Blatt 1.pdf", "Übungsblätter", "2026-10-13T09:00"),
            ("f-p1", "k-ph", "Folien Einführung.pdf", nil, "2026-10-14T12:00"), ("f-w", "k-erst", "Willkommen.pdf", nil, "2026-10-12T08:00"),
            ("f-v2", "k-ma", "VL02.pdf", "Vorlesung", "2026-10-19T10:00"), ("f-u2", "k-ma-ue", "Blatt 2.pdf", "Übungsblätter", "2026-10-20T09:00"),
            ("f-p2", "k-ph", "Folien Kapitel 2.pdf", nil, "2026-10-21T12:00"),
        ]
        let rows = files.map { f in [SQLiteValue.text(f.0), .text(f.1), .text(f.2), f.3.map(SQLiteValue.text) ?? .null, ts(f.4)] }
        let events: [(String, String, Int, String, String)] = [
            ("Testmathematik I", "vorlesung", 0, "10:00", "11:30"), ("Übung zu Testmathematik I", "uebung", 0, "14:00", "15:30"),
            ("Testphysik", "vorlesung", 2, "08:15", "09:45"),
        ]
        try await backend.context.database.transaction { c in
            for (id, title) in courses {
                let (subject, kind) = StudyClassify.classify(title)
                try c.execute("INSERT INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                              [.text(id), .text(title), .text("WiSe 2026/27"), .text(subject), .text(kind), .text("2026-10-01T08:00:00")])
            }
            for r in rows {
                try c.execute("INSERT INTO files(id, course_id, name, studip_folder, chdate, status, kind) VALUES (?,?,?,?,?, 'neu', 'pdf')", r)
            }
            for e in events {
                try c.execute("INSERT INTO course_events(title, kind, weekday, start_time, end_time, rrule, attend, source, created_at) VALUES (?,?,?,?,?, 'weekly', 1, 'studip', ?)",
                              [.text(e.0), .text(e.1), .integer(Int64(e.2)), .text(e.3), .text(e.4), .text("2026-10-01T08:00:00")])
            }
        }
        let recorder = RecordingTransport(LocalTransport(host: host))
        return (APIClient(base: APIClient.localBase, transport: recorder), recorder)
    }

    // MARK: Fenster, Bedienungshilfen

    // Die Seiten-Tests laufen synchron: nur dann arbeitet die Hauptschleife die Aufgaben der Ansicht (.task, Antworten
    // des Backends, Aktionen der Knoepfe) ab, waehrend der Test wartet.

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

    /// SwiftUI baut den Bedienungshilfen-Baum nur, wenn ein Hilfsmittel aktiv ist (wie bei UI-Tests)
    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    /// Hostet eine Ansicht mit den Umgebungsobjekten der App (Dialoge und Drawer wie in der App ueber der Seite)
    private func show<V: View>(_ view: V, api: APIClient, overlay given: UFOverlay? = nil, router givenRouter: UFRouter? = nil) throws -> UIView {
        let overlay = given ?? UFOverlay(), router = givenRouter ?? UFRouter()
        let suite = "uniflow-s6-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let root = view
            .modifier(UFDrawerHost(overlay: overlay))
            .modifier(UFModalHost(overlay: overlay))
            .environmentObject(Session(local: api, defaults: defaults))
            .environmentObject(router)
            .environmentObject(ShellState())
            .environmentObject(overlay)
            .environmentObject(UFToastCenter())
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
        return hosting.view
    }

    /// Hauptschleife laufen lassen, bis die Bedingung gilt (hoechstens `timeout` Sekunden)
    @discardableResult
    private func pump(timeout: Double = 10, until done: () -> Bool = { false }) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return done()
    }

    private func settle(_ seconds: Double = 0.4) { pump(timeout: seconds) }

    /// Elemente des Bedienungshilfen-Baums
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

    /// Knopf mit dieser Beschriftung ausloesen (wie ein Tipp mit VoiceOver)
    private func tap(_ label: String, in view: UIView) -> Bool {
        for e in elements(in: view) where e.accessibilityLabel == label && e.accessibilityTraits.contains(.button) {
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    /// Textfeld (UITextField hinter SwiftUI.TextField) mit diesem Platzhalter
    private func textField(in view: UIView, placeholder: String) -> UITextField? {
        if let t = view as? UITextField, (t.placeholder ?? t.attributedPlaceholder?.string) == placeholder { return t }
        for s in view.subviews { if let t = textField(in: s, placeholder: placeholder) { return t } }
        return nil
    }

    // MARK: Abnahme S6

    /// "+ Lernpaket" im Lernkalender -> Dialog "Neues Lernpaket" (Modul, Titel) -> "Anlegen" -> das Paket steht im
    /// Lernkalender, im Lernpaket wird die Aufgabe abgehakt, die Uebersicht zeigt es unter "Heute für dich geplant"
    func testAddPackageViaDialogCheckOffAndDashboard() throws {
        let (api, recorder) = try awaiting { try await self.seededAPI() }
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { Self.accessibilityAutomation(false) }
        let overlay = UFOverlay(), router = UFRouter()
        let plan = try show(PlanView(params: (view: "week", date: "2026-10-26", module: nil)), api: api, overlay: overlay, router: router)
        XCTAssertTrue(pump { recorder.calls.contains { $0.path == "/api/calendar" } && recorder.calls.contains { $0.path == "/api/timetable/week" } })
        XCTAssertTrue(pump { self.shows(plan, "Lernkalender") && self.shows(plan, "Woche retten") })
        XCTAssertTrue(shows(plan, "Dein Wochenplan – perfekt auf Vorlesungen und Übungen abgestimmt."), "ohne Tests: \(texts(plan))")

        // "+ Lernpaket" -> "Neues Lernpaket" mit dem ersten Modul
        XCTAssertTrue(tap("Lernpaket", in: plan), "Knopf Lernpaket: \(texts(plan))")
        XCTAssertTrue(pump { self.shows(plan, "Neues Lernpaket") && self.shows(plan, "Testmathematik I") }, texts(plan).joined(separator: "\n"))
        let field = try XCTUnwrap(textField(in: plan, placeholder: "z. B. Kapitel 2 lernen"))
        XCTAssertTrue(field.becomeFirstResponder())
        field.insertText("Kapitel 2 lernen")
        settle()
        let before = recorder.calls.count
        XCTAssertTrue(tap("Anlegen", in: plan), texts(plan).joined(separator: "\n"))
        XCTAssertTrue(pump { recorder.calls.dropFirst(before).contains { $0.method == "POST" && $0.path == "/api/packages" } })
        XCTAssertEqual(recorder.calls.last { $0.method == "POST" && $0.path == "/api/packages" }?.status, 200)

        let cal = try awaiting { try await api.value("/api/calendar?start=2026-10-26&end=2026-10-26") }
        let pkg = try XCTUnwrap(cal.list("days").first?.list("packages").first)
        XCTAssertEqual(pkg.s("title"), "Kapitel 2 lernen")
        XCTAssertEqual(pkg.s("subject"), "Testmathematik I")
        XCTAssertEqual(pkg.i("planned_minutes"), 60)
        XCTAssertEqual(pkg.list("tasks").map { $0.s("type") ?? "" }, ["frei"])
        let pid = try XCTUnwrap(pkg.i("id")), tid = try XCTUnwrap(pkg.list("tasks").first?.i("id"))

        // nach dem Anlegen laedt der Lernkalender neu und zeigt das Paket
        XCTAssertTrue(pump { self.shows(plan, "Kapitel 2 lernen") }, texts(plan).joined(separator: "\n"))
        XCTAssertFalse(recorder.calls.contains { $0.status >= 400 }, "keine Fehlerantwort: \(recorder.calls)")

        // im Lernpaket abhaken
        let drawer = try show(PackageDrawer(id: pid), api: api)
        XCTAssertTrue(pump { self.shows(drawer, "Als erledigt markieren") }, texts(drawer).joined(separator: "\n"))
        XCTAssertTrue(tap("Als erledigt markieren", in: drawer))
        XCTAssertTrue(pump { recorder.calls.contains { $0.method == "POST" && $0.path == "/api/tasks/\(tid)/status" } })
        let done = try awaiting { try await api.value("/api/packages/\(pid)") }
        XCTAssertEqual(done.s("status"), "erledigt")
        XCTAssertEqual(done.list("tasks").first?.s("status"), "erledigt")
        XCTAssertTrue(pump { self.shows(drawer, "Als offen markieren") }, "Haken sichtbar: \(texts(drawer))")

        // Uebersicht: heute geplant, erledigt
        let dash = try show(DashboardView(api: api), api: api)
        XCTAssertTrue(pump { self.shows(dash, "Heute für dich geplant") && self.shows(dash, "Kapitel 2 lernen") }, texts(dash).joined(separator: "\n"))
        XCTAssertTrue(shows(dash, "1 / 1"), "Aufgaben erledigt: \(texts(dash))")
        XCTAssertTrue(shows(dash, "Testmathematik I"), texts(dash).joined(separator: "\n"))
        XCTAssertFalse(shows(dash, "Für heute ist nichts geplant."), texts(dash).joined(separator: "\n"))
        XCTAssertFalse(recorder.calls.contains { $0.status >= 400 }, "keine Fehlerantwort: \(recorder.calls)")
    }

    /// "Plan erstellen" im Lernkalender -> Dialog (ohne Wochentest) -> "Erstellen": Lernpakete in den freien Fenstern
    /// neben Vorlesung, Uebung und Fahrtzeit, kein Konflikt; Termine und Lernbloecke stehen im Stundenplan
    func testGeneratePlanFillsFreeWindowsNextToEvents() throws {
        let (api, recorder) = try awaiting { try await self.seededAPI() }
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { Self.accessibilityAutomation(false) }
        let overlay = UFOverlay()
        let plan = try show(PlanView(params: (view: "week", date: "2026-10-26", module: nil)), api: api, overlay: overlay)
        XCTAssertTrue(pump { self.shows(plan, "Plan erstellen") && recorder.calls.contains { $0.path == "/api/timetable/week" } })
        XCTAssertTrue(tap("Plan erstellen", in: plan))
        XCTAssertTrue(pump { self.shows(plan, "Lernplan erstellen") && recorder.calls.contains { $0.path == "/api/calendar/feasibility" } })
        settle()
        XCTAssertTrue(shows(plan, "Vorlesung → Übungen"), texts(plan).joined(separator: "\n"))
        XCTAssertFalse(shows(plan, "Wochentest"), "ohne PC keine Wochentests: \(texts(plan))")
        XCTAssertTrue(tap("Erstellen", in: plan), texts(plan).joined(separator: "\n"))
        XCTAssertTrue(pump { recorder.calls.contains { $0.method == "POST" && $0.path == "/api/calendar/generate" } })
        XCTAssertEqual(recorder.calls.last { $0.path == "/api/calendar/generate" }?.status, 200)

        let week = try awaiting { try await api.value("/api/timetable/week?start=2026-10-26") }
        var slotted: [(day: String, start: String, end: String, title: String)] = []
        for d in week.list("days") {
            // Termine, dazu 30 Minuten Fahrt vor dem ersten und nach dem letzten (wie free_windows)
            let evs = d.list("events").filter { $0.s("status") == "teilnahme" }.map { (UFTime.hm($0.s("start")), UFTime.hm($0.s("end"))) }
                .sorted { $0.0 < $1.0 }
            var busy = evs
            if let f = evs.first, let l = evs.last { busy += [(f.0 - 30, f.0), (l.1, l.1 + 30)] }
            for p in d.list("packages") {
                let a = UFTime.hm(p.s("start_time")), b = UFTime.hm(p.s("end_time"))
                XCTAssertNotNil(p.s("start_time"), "Paket ohne Uhrzeit: \(p)")
                for (s, e) in busy { XCTAssertFalse(a < e && b > s, "\(d.s("date") ?? ""): \(p.s("start_time") ?? "")–\(p.s("end_time") ?? "") im Termin") }
                slotted.append((d.s("date") ?? "", p.s("start_time") ?? "", p.s("end_time") ?? "", p.s("title") ?? ""))
            }
        }
        XCTAssertGreaterThanOrEqual(slotted.count, 4, "\(slotted)")
        let monday = slotted.filter { $0.day == "2026-10-26" }
        XCTAssertEqual(monday.count, 2, "Montag: zwei Fächer neben Vorlesung und Übung: \(slotted)")
        let conflicts = try awaiting { try await api.value("/api/timetable/conflicts") }
        XCTAssertEqual(conflicts.items.count, 0, "\(conflicts)")
        // ohne Wochentest geplant (Standard ohne PC)
        let open = try awaiting { try await api.value("/api/tasks/open") }
        XCTAssertFalse(open.items.contains { $0.s("type") == "test" })
        XCTAssertTrue(open.items.contains { $0.s("type") == "vorlesung" } && open.items.contains { $0.s("type") == "uebung" })

        // Stundenplan: Termine und Lernbloecke derselben Woche
        let tt = try show(TimetableView(date: "2026-10-26"), api: api)
        let lines = monday.map { "\($0.start)–\($0.end) · \($0.title)" }
        XCTAssertTrue(pump { self.shows(tt, "Testmathematik I") && lines.allSatisfy { l in self.shows(tt, l) } }, texts(tt).joined(separator: "\n"))
        XCTAssertTrue(shows(tt, "Übung zu Testmathematik I"), texts(tt).joined(separator: "\n"))
        XCTAssertFalse(recorder.calls.contains { $0.status >= 400 }, "keine Fehlerantwort: \(recorder.calls)")
    }

    /// Lernkombination ohne PC: Vorlagen und Felder ohne Wochentest, gespeichert wird tests_per_subject 0
    func testCombinationDialogWithoutWeeklyTests() throws {
        let (api, recorder) = try awaiting { try await self.seededAPI() }
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { Self.accessibilityAutomation(false) }
        _ = try awaiting { try await api.value("/api/settings", method: "PUT", body: ["tests_per_subject": "1"]) }
        var saved: Bool?
        let dialog = try show(ConfigDialog(api: api) { saved = $0 }, api: api)
        XCTAssertTrue(pump { self.shows(dialog, "Meinen Lernplan konfigurieren") && recorder.calls.contains { $0.path == "/api/settings" && $0.method == "GET" } })
        settle()
        XCTAssertTrue(shows(dialog, "Vorlesung + Übungen"), texts(dialog).joined(separator: "\n"))
        XCTAssertFalse(shows(dialog, "Wochentest"), "ohne PC keine Wochentests: \(texts(dialog))")
        XCTAssertFalse(shows(dialog, "Wiederholung"), texts(dialog).joined(separator: "\n"))
        XCTAssertTrue(tap("Speichern", in: dialog))
        XCTAssertTrue(pump { saved != nil })
        XCTAssertEqual(saved, true)
        let s = try awaiting { try await api.value("/api/settings") }
        XCTAssertEqual(s.i("tests_per_subject"), 0)
    }
}
