import SwiftUI
import UIKit
import Vision
import XCTest
import UniFlowCore
@testable import UniFlow

/// S4 im lokalen Modus ohne PC: "Meine Module" und das Moduldetail laden aus der Datenbank des Geraets (Seed mit
/// erfundenen Kursen und Dateien, Fach und Art wie beim Abgleich aus `StudyClassify.classify`).
@MainActor
final class LocalModulesAppTests: XCTestCase {

    /// Merkt sich Pfad und Status jeder Anfrage an das lokale Backend
    final class RecordingTransport: APITransport, @unchecked Sendable {
        let inner: LocalTransport
        private let lock = NSLock()
        private var log: [(path: String, status: Int)] = []

        init(_ inner: LocalTransport) { self.inner = inner }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let r = try await inner.send(request)
            lock.withLock { log.append((request.url?.path ?? "", r.1.statusCode)) }
            return r
        }

        var calls: [(path: String, status: Int)] { lock.withLock { log } }
    }

    /// Konto ohne Schluesselbund und ohne Apple (die Einstellungen zeigen kurz "Zugang & Darstellung")
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-s4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Unix-Zeit einer Berliner Ortszeit
    private func ts(_ local: String) -> SQLiteValue {
        .integer(Int64(UniFlowClock.fixed(berlin: local)!.now.timeIntervalSince1970))
    }

    /// Lokales Backend mit Seed: zwei Faecher (Vorlesung + Uebung), Dateien in drei Lehrwochen, eine Altklausur,
    /// eine Datei vor dem Vorlesungsbeginn, eine Begruessung (kein Fach)
    private func seededAPI() async throws -> (APIClient, RecordingTransport) {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-20T10:00:00")!)
        let backend = try await host.backend()
        let courses: [(String, String)] = [("k-a-v", "Testmathematik I"), ("k-a-gu", "Gruppenübung Testmathematik I"),
                                           ("k-b-v", "Grundlagen der Beispieltechnik"), ("k-b-u", "Übung zu Grundlagen der Beispieltechnik"),
                                           ("k-c-v", "Probeinformatik"), ("k-erst", "Begrüßung der Erstsemester")]
        let files: [(String, String, String, String?, String)] = [
            ("f-1", "k-a-v", "VL01.pdf", "Vorlesung", "2026-10-13T10:00"), ("f-2", "k-a-gu", "GU01.pdf", "Gruppenübung", "2026-10-14T10:00"),
            ("f-3", "k-a-v", "VL02.pdf", "Vorlesung", "2026-10-20T10:00"), ("f-4", "k-a-gu", "Blatt3_Loesung.pdf", "Gruppenübung/Lösungen", "2026-10-27T10:00"),
            ("f-5", "k-a-v", "Probeklausur.pdf", "Alte Klausuren/WS 25/26", "2026-11-10T10:00"),
            ("f-6", "k-a-v", "Skript.pdf", "Skript", "2026-10-02T10:00"),
            ("f-7", "k-b-v", "Folien_VL01.pdf", nil, "2026-10-12T09:00"), ("f-8", "k-b-u", "Übungsblatt 1.pdf", "Übungen", "2026-10-15T09:00"),
            ("f-9", "k-c-v", "02A.pdf", "Vorlesung", "2026-10-13T12:00"), ("f-10", "k-erst", "Willkommen.pdf", nil, "2026-10-05T10:00"),
        ]
        let rows = files.map { f in [SQLiteValue.text(f.0), .text(f.1), .text(f.2), f.3.map(SQLiteValue.text) ?? .null, ts(f.4)] }
        try await backend.context.database.transaction { c in
            for (id, title) in courses {
                let (subject, kind) = StudyClassify.classify(title)
                try c.execute("INSERT INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                              [.text(id), .text(title), .text("WiSe 2026/27"), .text(subject), .text(kind), .text("2026-10-01T08:00:00")])
            }
            for r in rows {
                try c.execute("INSERT INTO files(id, course_id, name, studip_folder, chdate, status, kind) VALUES (?,?,?,?,?, 'neu', 'pdf')", r)
            }
        }
        let recorder = RecordingTransport(LocalTransport(host: host))
        return (APIClient(base: APIClient.localBase, transport: recorder), recorder)
    }

    // MARK: Daten der Seiten

    func testModulesAndDetailFromSeed() async throws {
        let (api, _) = try await seededAPI()
        let mods = try await api.value("/api/modules").items                 // wie ModulesPage.load()
        XCTAssertEqual(mods.map { $0.s("name") ?? "" }, ["Testmathematik I", "Grundlagen der Beispieltechnik", "Probeinformatik"],
                       "Fächer in der Reihenfolge des Abgleichs; Begrüßung ohne Fach")
        let math = try XCTUnwrap(mods.first)
        XCTAssertEqual(math.i("courses"), 2)
        XCTAssertEqual(math.i("file_count"), 6)
        XCTAssertEqual(math.i("weeks"), 3)
        XCTAssertEqual(math.s("color"), "#4f6df5")

        let d = try await api.value("/api/modules/\(math.i("id") ?? 0)")     // wie ModulePage.load()
        XCTAssertEqual(d["module"]?.s("name"), "Testmathematik I")
        let weeks = d.list("weeks")
        XCTAssertEqual(weeks.map { $0.s("label") ?? "" }, ["Vor Vorlesungsbeginn", "Woche 1 · 12.10. – 18.10.", "Woche 2 · 19.10. – 25.10.",
                                                         "Woche 3 · 26.10. – 01.11.", "Klausuren & Altklausuren"])
        let week1 = weeks[1]
        XCTAssertEqual(week1.list("vorlesungen").map { $0.s("id") ?? "" }, ["f-1"])
        XCTAssertEqual(week1.list("uebungen").first?.s("sub_label"), "Gruppenübung")
        XCTAssertEqual(weeks[3].list("loesungen").first?.s("sub_label"), "Lösung")
        XCTAssertEqual(weeks[4].list("klausuren").first?.s("sub_label"), "Altklausur")
        XCTAssertEqual(weeks[0].list("skripte").first?.s("id"), "f-6", "vor dem Vorlesungsbeginn, nicht bei den Altklausuren")
        // Aktuelle Lehrwoche wie im Kopf des Moduldetails
        XCTAssertEqual(weeks.filter { ($0.i("week") ?? 0) >= 1 }.last?.s("label"), "Woche 3 · 26.10. – 01.11.")
        XCTAssertEqual(d.list("courses").map { $0.s("kind") ?? "" }, ["gruppenuebung", "vorlesung"])
        // Tabs: Dateien nach Typ
        XCTAssertEqual(d.list("files").filter { $0.s("doc_type") == "vorlesung" }.count, 2)

        // Modul zuordnen und anlegen wie die Einstellungen (Module & Wochentests)
        let created = try await api.value("/api/modules", method: "POST", body: ["name": "Eigenes Fach"])
        XCTAssertEqual(created.s("name"), "Eigenes Fach")
        _ = try await api.value("/api/courses/k-c-v/module", method: "POST", body: ["module_id": .number(Double(created.i("id") ?? 0))])
        let moved = try await api.value("/api/modules/\(created.i("id") ?? 0)")
        XCTAssertEqual(moved.list("courses").map { $0.s("id") ?? "" }, ["k-c-v"])
        XCTAssertEqual(moved.list("weeks").first?.s("label"), "Woche 2 · 19.10. – 25.10.", "02A.pdf: Lehrwoche 2 aus dem Namen")
    }

    // MARK: Seiten im Fenster

    /// Hostet eine Seite mit den Umgebungsobjekten der App in einem Fenster, das hoch genug fuer die ganze Seite ist,
    /// wartet auf die Anfragen und liefert die sichtbaren Texte. Gewartet wird mit `Task.sleep`, nicht mit
    /// `RunLoop.run`: Der Test laeuft auf dem MainActor, und eine verschachtelte RunLoop arbeitet dessen Aufgaben (das
    /// `.task` der Seite, das Uebernehmen der Antwort) nicht ab, die Seite bliebe beim Ladezustand. Der
    /// Bedienungshilfen-Baum von SwiftUI bleibt in Unit-Tests leer (ohne VoiceOver); darum Texterkennung (Vision) auf
    /// dem gezeichneten Fenster.
    private func render<V: View>(_ view: V, api: APIClient, recorder: RecordingTransport,
                                 until done: ([(path: String, status: Int)]) -> Bool) async throws -> [String] {
        let suite = "uniflow-s4-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let root = view
            .environmentObject(Session(local: api, defaults: defaults))
            .environmentObject(UFRouter())
            .environmentObject(ShellState())
            .environmentObject(UFOverlay())
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
        defer { window.isHidden = true }
        let end = Date().addingTimeInterval(10)
        while !done(recorder.calls) && Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 500_000_000)                         // Antwort in die Ansicht uebernehmen
        hosting.view.layoutIfNeeded()
        return try recognizedTexts(hosting.view)
    }

    /// Zeilen, die die Texterkennung im gezeichneten Fenster findet. Gezeichnet mit dreifacher Aufloesung und in
    /// ueberlappenden Streifen erkannt: Auf dem ganzen Fenster auf einmal liest Vision die kleine Schrift (12 pt) oft
    /// falsch.
    private func recognizedTexts(_ view: UIView) throws -> [String] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let cg = try XCTUnwrap(image.cgImage)
        let stripe = 360 * 3, overlap = 90 * 3
        var lines: [String] = []
        var y = 0
        while y < cg.height {
            let part = try XCTUnwrap(cg.cropping(to: CGRect(x: 0, y: y, width: cg.width, height: min(stripe, cg.height - y))))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["de-DE"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: part).perform([request])
            lines += (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            y += stripe - overlap
        }
        return lines
    }

    /// Steht der Text sichtbar da? Die Texterkennung liest Einzelheiten unterschiedlich ("·" als "." oder "•", "–" als
    /// "-", "I" als "|" oder "l", "ö" als "o", selten ein Buchstabe falsch). Darum zaehlen Leerraum, Gross-/
    /// Kleinschreibung und Akzente nicht, diese Zeichen gelten jeweils als gleich, und je angefangene 10 Zeichen ist ein
    /// Fehler erlaubt (Editierabstand zum besten Ausschnitt aller Zeilen). Gilt ebenso fuer "steht nicht da".
    private func shows(_ texts: [String], _ text: String) -> Bool {
        func norm(_ s: String) -> [Character] {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE")).compactMap { c -> Character? in
                if c.isWhitespace { return nil }
                if "·•∙".contains(c) { return "." }
                if "–—".contains(c) { return "-" }
                if "l|!".contains(c) { return "i" }
                return c
            }
        }
        let pattern = norm(text), all = norm(texts.joined(separator: " "))
        guard !pattern.isEmpty else { return true }
        // kleinster Editierabstand des Musters zu einem Ausschnitt des Textes (Sellers)
        var column = Array(0...pattern.count)
        var best = column[pattern.count]
        for c in all {
            var diagonal = column[0]
            column[0] = 0
            for i in 1...pattern.count {
                let above = column[i]
                column[i] = min(above + 1, column[i - 1] + 1, diagonal + (pattern[i - 1] == c ? 0 : 1))
                diagonal = above
            }
            best = min(best, column[pattern.count])
        }
        return best <= (pattern.count + 9) / 10
    }

    func testModulesPageLoadsLocally() async throws {
        let (api, recorder) = try await seededAPI()
        let shown = try await render(ModulesPage(), api: api, recorder: recorder) { calls in calls.contains { $0.path == "/api/modules" } }
        let calls = recorder.calls
        XCTAssertTrue(calls.contains { $0.path == "/api/modules" && $0.status == 200 }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.status >= 400 }, "keine Fehlerantwort: \(calls)")
        let all = shown.joined(separator: "\n")
        XCTAssertTrue(shows(shown, "Meine Module"), all)
        for name in ["Testmathematik I", "Grundlagen der Beispieltechnik", "Probeinformatik"] {
            XCTAssertTrue(shows(shown, name), "\(name): \(all)")
        }
        XCTAssertFalse(shows(shown, "Begrüßung"), "Begrüßung ist kein Fach: \(all)")
        XCTAssertFalse(shows(shown, "Noch keine Module"), all)
    }

    /// Einstellungen ohne PC: Reiter "Module" (Anlegen, Zuordnen, automatische Zuordnung) aus der lokalen Datenbank,
    /// ohne Wochentests (keine KI); der Knopf "Module verwalten" auf Meine Module fuehrt hierher
    func testSettingsModulesTabLocally() async throws {
        let (api, recorder) = try await seededAPI()
        let shown = try await render(SettingsPage(initialTab: "modules"), api: api, recorder: recorder) { calls in
            calls.contains { $0.path == "/api/courses" }
        }
        let calls = recorder.calls
        XCTAssertTrue(calls.contains { $0.path == "/api/modules" && $0.status == 200 }, "\(calls)")
        XCTAssertTrue(calls.contains { $0.path == "/api/courses" && $0.status == 200 }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.status >= 400 }, "keine Fehlerantwort: \(calls)")
        let all = shown.joined(separator: "\n")
        for text in ["Testmathematik I", "Grundlagen der Beispieltechnik", "Probeinformatik", "3 aktiv",
                     "Ohne Modul (nicht eingeplant)", "Begrüßung der Erstsemester", "Modul anlegen", "Zuordnung automatisch prüfen"] {
            XCTAssertTrue(shows(shown, text), "\(text): \(all)")
        }
        XCTAssertFalse(shows(shown, "Wochentest"), "ohne PC keine Wochentests: \(all)")
        XCTAssertFalse(shows(shown, "Standard-Testdauer"), all)
    }

    func testModuleDetailPageLoadsLocally() async throws {
        let (api, recorder) = try await seededAPI()
        let mods = try await api.value("/api/modules").items
        let id = try XCTUnwrap(mods.first?.i("id"))
        let shown = try await render(ModulePage(id: id), api: api, recorder: recorder) { calls in calls.contains { $0.path == "/api/modules/\(id)" } }
        let calls = recorder.calls
        XCTAssertTrue(calls.contains { $0.path == "/api/modules/\(id)" && $0.status == 200 }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.status >= 400 }, "keine Fehlerantwort: \(calls)")
        let all = shown.joined(separator: "\n")
        XCTAssertTrue(shows(shown, "Testmathematik I"), all)
        for week in ["Vor Vorlesungsbeginn", "Woche 1 · 12.10. – 18.10.", "Woche 3 · 26.10. – 01.11.", "Klausuren & Altklausuren"] {
            XCTAssertTrue(shows(shown, week), "\(week): \(all)")
        }
        XCTAssertFalse(shows(shown, "Woche 4 · 02.11. – 08.11."), "keine Dateien in Woche 4: \(all)")
        XCTAssertTrue(shows(shown, "Gruppenübung"), all)
        XCTAssertTrue(shows(shown, "Altklausur"), all)
        // ohne PC keine KI-Zusammenfassung der Woche
        XCTAssertFalse(shows(shown, "Zusammenfassen"), all)

        // Gegenprobe: dieselben Antworten, aber als eigener Server (kein Netz, dieselbe lokale Weiche) zeigen den Knopf
        let server = APIClient(base: URL(string: "http://pc-server.invalid/")!, transport: recorder)
        let withServer = try await render(ModulePage(id: id), api: server, recorder: recorder) { calls in
            calls.filter { $0.path == "/api/modules/\(id)" }.count >= 2
        }
        XCTAssertTrue(shows(withServer, "Zusammenfassen"), withServer.joined(separator: "\n"))
    }
}
