import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Studienverlauf Uni Hildesheim nach einem Studiengangwechsel (07.11.2026), Ende zu Ende gegen das lokale Backend:
/// nachgebauter LSF-Notenspiegel mit zwei Abschluessen (packages/shared-contracts/fixtures/hildesheim/
/// lsf-notenspiegel-wechsel-*.html, erfundene Daten) -> Katalog aus dem Grundstock der App -> Seite zeigt den aktuellen
/// Studiengang (Sozialpaedagogik B.A.) und die Karte "Frueheres Studium". Dazu "Studiengang waehlen" von Hand, wenn
/// der Notenspiegel einen unbekannten Namen nennt. Kein Netz.
@MainActor
final class StudyProgramChangeAppTests: XCTestCase {

    /// API der App -> lokales Backend dieses Tests
    struct BackendTransport: APITransport {
        let backend: LocalBackend
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = request.url!
            let r = await backend.handle(LocalRequest(method: request.httpMethod ?? "GET", url: url,
                                                      headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody))
            return (r.body, HTTPURLResponse(url: url, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!)
        }
    }

    /// LSF-Seiten aus den Fixtures je URL-Teil
    struct LSFPages: UniTransport {
        let pages: [(String, String)]
        func send(_ request: UniRequest) async throws -> UniResponse {
            let url = request.url.absoluteString
            guard let hit = pages.first(where: { url.contains($0.0) }) else { return UniResponse(status: 404, finalURL: request.url) }
            return UniResponse(status: 200, finalURL: request.url, body: Data(hit.1.utf8))
        }
        func download(_ request: UniRequest, to destination: URL) async throws -> UniResponse { try await send(request) }
    }

    struct NoLoader: StudyCatalogLoader {
        func fetch(url: String, etag: String?, lastModified: String?) async -> StudyCatalogFetchResult {
            StudyCatalogFetchResult(status: 404, error: "kein Netz im Test")
        }
    }

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/hildesheim/\(name)"), encoding: .utf8)
    }

    /// Asynchrone Vorbereitung aus einem synchronen Test (die gehostete Seite braucht die freie Hauptschleife)
    private func block<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let done = expectation(description: "async")
        nonisolated(unsafe) var result: Result<T, Error>?
        Task.detached {
            do { result = .success(try await body()) } catch { result = .failure(error) }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(result).get()
    }

    private func env() throws -> StudyCatalogPipeline.Environment {
        let seeds = try XCTUnwrap(StudyCatalogSeed.bundledAll(Bundle.main), "Grundstock im App-Bundle")
        return StudyCatalogPipeline.Environment(loader: NoLoader(), library: nil, seed: seeds, pdfText: { _ in [] }, planText: { _ in nil },
                                                now: { Date(timeIntervalSince1970: 1_794_045_600) })
    }

    /// Backend in einer eigenen Datei (Hochschule Hildesheim); die Katalogsuche laeuft wie in der App ueber den
    /// Ausloeser, wenn GET /api/study-catalog/status geaenderte Eingaben bemerkt
    private func backend() throws -> LocalBackend {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("db.sqlite").path
        let b = try block {
            let b = try await LocalBackend.open(path: path, clock: .fixed(berlin: "2026-11-07T10:00:00")!)
            try await b.context.database.transaction { c in
                _ = try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('university', 'hildesheim')")
            }
            return b
        }
        let db = b.context.database, e = try env()
        StudyCatalogTriggers.register(databasePath: db.path) { force in
            Task { await StudyCatalogPipeline.run(db: db, env: e, force: force) }
        }
        addTeardownBlock {
            StudyCatalogTriggers.unregister(databasePath: db.path)
            try? FileManager.default.removeItem(at: dir)
        }
        return b
    }

    private func host(_ b: LocalBackend) throws -> HostedEnvironment {
        let api = APIClient(base: URL(string: "uniflow-local://device/")!, transport: BackendTransport(backend: b))
        return try hostWithEnvironment(StudyPlanPage(pollInterval: 0.3), api: api, size: CGSize(width: 1180, height: 820))
    }

    // MARK: Hilfen (wie StudyPlanBoardAppTests)

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

    private func sheet(_ env: HostedEnvironment) -> UIView? {
        guard let p = env.hosting.presentedViewController, !p.isBeingDismissed else { return nil }
        return p.view
    }

    private func dump(_ v: UIView?) -> String { v.map { labels($0).joined(separator: "\n") } ?? "(keine Ansicht)" }

    // MARK: Wechsel: aktueller Studiengang, frueheres Studium

    func testProgramChangeShowsCurrentProgramAndPreviousStudies() throws {
        let b = try backend()
        let list = "nodeID=auswahlBaum%7Cabschluss%3Aabschl%3D82%2Cstgnr%3D"
        let lsf = LSFClient(transport: LSFPages(pages: [
            ("state=user&type=0", try fixture("lsf-notenspiegel-wechsel-start.html")),
            (list + "1", try fixture("lsf-notenspiegel-wechsel-ew.html")),
            (list + "2", try fixture("lsf-notenspiegel-wechsel-sozpaed.html")),
        ]), retry: UniRetry(attempts: 1, delayNanos: { _ in 0 }))
        let e = try env()
        let (count, s) = try block {
            let grades = try await lsf.grades()
            try await b.context.database.transaction { try UniStore.storeGrades($0, grades, now: "2026-11-07T10:00:00Z") }
            return (grades.count, await StudyCatalogPipeline.run(db: b.context.database, env: e))
        }
        XCTAssertEqual(count, 8)
        XCTAssertEqual(s["code"]?.string, "sozialpaedagogik|b.a.|2025", "\(s)")

        let env = try host(b)
        XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.hasPrefix("Sozialpädagogik") } }, dump(env.view))
        XCTAssertNotNil(find(env.view, label: StudyPlanText.previousStudies, exact: true), dump(env.view))
        let l = labels(env.view)
        XCTAssertFalse(l.contains { $0.hasPrefix("Erziehungswissenschaft B.A.") }, "nicht der alte Katalog")
        // Karte zugeklappt; aufklappen zeigt die alten Leistungen, die angerechnete mit Hinweis
        XCTAssertFalse(l.contains { $0.contains("Kindheit, Jugend, Erwachsenheit") })
        XCTAssertTrue(tap(env.view, "Erziehungswissenschaft (Bachelor, PO 2022)"), dump(env.view))
        XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.contains("Kindheit, Jugend, Erwachsenheit") } }, dump(env.view))
        XCTAssertTrue(labels(env.view).contains { $0.contains("Modul 5: Soziologie") && $0.contains("angerechnet") }, dump(env.view))
        XCTAssertTrue(labels(env.view).contains { $0.contains("5 Leistungen · 4 bestanden") }, dump(env.view))
    }

    // MARK: Studiengang von Hand waehlen

    func testChooseProgramByHandWhenTheNameIsUnknown() throws {
        let b = try backend()
        let e = try env()
        _ = try block {
            try await b.context.database.transaction { c in
                _ = try c.execute("INSERT INTO grades(pruefungsnr, text, datum, status, note, abschluss) VALUES ('1', 'Modul 2: Sozialpädagogik I – Einführung', '16.02.2026', 'bestanden', '1,7', ?)",
                                  [.text("Abschluss: [82] Bachelor Studiengang: [999] B.A. Erfundenes Fach PO-Version: 2025")])
            }
            return await StudyCatalogPipeline.run(db: b.context.database, env: e)
        }
        let env = try host(b)
        XCTAssertTrue(env.wait { self.labels(env.view).contains(StudyPlanText.noCatalog) }, dump(env.view))
        XCTAssertTrue(tap(env.view, StudyPlanText.chooseProgram, exact: true), dump(env.view))
        XCTAssertTrue(env.wait { self.sheet(env).map { self.find($0, label: "Sozialpädagogik B.A.") != nil } ?? false }, dump(sheet(env)))
        let s = try XCTUnwrap(sheet(env))
        XCTAssertTrue(labels(s).contains { $0.hasPrefix("Erziehungswissenschaft B.A.") })
        XCTAssertTrue(labels(s).contains { $0.hasPrefix("Medieninformatik B.Sc.") && $0.contains(StudyPlanText.programNoCatalog) },
                      "ohne Katalog sichtbar, aber nicht waehlbar")
        XCTAssertTrue(tap(s, "Sozialpädagogik B.A."), dump(s))
        // gemerkt: Kuerzel als PO, Katalog aus dem Grundstock, Plan mit der Leistung
        XCTAssertTrue(env.wait(timeout: 15) { self.labels(env.view).contains { $0.hasPrefix("Sozialpädagogik") } && self.sheet(env) == nil },
                      dump(env.view))
        let settings = try block {
            try await b.context.database.withConnection { c in
                try c.queryOne("SELECT value FROM settings WHERE key='study_plan'")?["value"]?.string
            }
        }
        XCTAssertTrue(settings?.contains("sozialpaedagogik|b.a.|2025") == true, settings ?? "")
        XCTAssertNil(find(env.view, label: StudyPlanText.previousStudies, exact: true), "nur ein Abschluss")
    }
}
