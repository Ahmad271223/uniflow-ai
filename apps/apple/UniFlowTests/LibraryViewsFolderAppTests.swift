import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Meldung des Inhabers 11.11.2026 zu "Dokumente & Notizen": (1) Dateien von aussen landeten nie in einem eigenen
/// Ordner eines Moduls, (2) von den Ansichten ging nur eine. Hier die Teile, die schon am alten Stand pruefbar sind:
/// Import in einen Unterordner eines Moduls (lokales Backend), Liste auf der obersten Ebene (vorher blieben Module und
/// Ordner Kacheln, der Umschalter "Kacheln | Liste" wirkte dort nicht), Unterordner im Modulordner (vorher zeigte
/// "m1/f5/f9" den Inhalt von f5) und gemerkte Wahl "Ordner | Regal".
@MainActor
final class LibraryViewsFolderAppTests: XCTestCase {

    /// Schein-Transport: feste Antworten je Pfad
    final class Transport: APITransport, @unchecked Sendable {
        private let lock = NSLock()
        private var canned: [String: JSONValue] = [:]

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let answer: JSONValue? = lock.withLock { canned[path] }
            let data = (answer ?? ["detail": "Testfehler"]).serialized()
            return (data, HTTPURLResponse(url: request.url!, statusCode: answer == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!)
        }

        func answer(_ path: String, _ v: JSONValue) { lock.withLock { canned[path] = v } }
    }

    /// Erfundene Bibliothek: Modul "Analysis" mit Ordner "Übungen" und Unterordner "Blatt 1", eigener Ordner "Privat",
    /// ein loses eigenes Dokument
    static let library: JSONValue = [
        "modules": [["id": 1, "name": "Analysis", "color": "#175ee8"]],
        "folders": [["id": 5, "name": "Übungen", "parent_id": .null, "module_id": 1, "color": .null],
                    ["id": 9, "name": "Blatt 1", "parent_id": 5, "module_id": 1, "color": .null],
                    ["id": 3, "name": "Privat", "parent_id": .null, "module_id": .null, "color": .null]],
        "files": [["id": "u1", "title": "Flach", "name": "Flach", "kind": "notebook", "course_id": "__user__", "folder_id": 5, "module_id": .null],
                  ["id": "u2", "title": "Tief", "name": "Tief", "kind": "notebook", "course_id": "__user__", "folder_id": 9, "module_id": .null],
                  ["id": "u3", "title": "Lose Notiz", "name": "Lose Notiz", "kind": "notebook", "course_id": "__user__", "folder_id": .null, "module_id": .null]],
        "trash": [],
    ]

    private func api() -> APIClient {
        let t = Transport()
        t.answer("/api/library", Self.library)
        t.answer("/api/courses", [])
        t.answer("/api/index/shelf", LibraryShelfAppTests.shelf)
        return APIClient(base: APIClient.localBase, transport: t)
    }

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    /// Gemerkte Wahl der Ansicht (`@AppStorage`, UserDefaults.standard) fuer einen Test setzen, danach wie vorher
    private func remember(_ key: String, _ value: String?) {
        let before = UserDefaults.standard.string(forKey: key)
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        addTeardownBlock { @MainActor in
            if let before { UserDefaults.standard.set(before, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func elements(_ view: UIView) -> [NSObject] {
        view.layoutIfNeeded()
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
            if let o = element as? NSObject {
                out.append(o)
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

    private func labels(_ view: UIView) -> [String] { elements(view).compactMap(\.accessibilityLabel).filter { !$0.isEmpty } }

    // MARK: Import in einen eigenen Unterordner eines Moduls

    /// Erfundene PDF von aussen in den Unterordner "Blatt 1" des Moduls: sie bleibt dort (vorher "Eigene Notizen")
    func testImportFromOutsideIntoSubfolderOfModuleStaysThere() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let host = LocalBackendHost(directory: dir.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-11T10:00:00")!,
                                    files: LocalFiles(container: dir, dataDirectory: "Library/Application Support/UniFlow", tools: AppDocumentTools()))
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let module = try await api.value("/api/modules", method: "POST", body: ["name": "Analysis"])
        let mid = try XCTUnwrap(module.i("id"))
        let topFolder = try await api.value("/api/folders", method: "POST", body: ["name": "Übungen", "module_id": .number(Double(mid))])
        let top = try XCTUnwrap(topFolder.i("id"))
        let subFolder = try await api.value("/api/folders", method: "POST",
                                            body: ["name": "Blatt 1", "parent_id": .number(Double(top)), "module_id": .number(Double(mid))])
        let sub = try XCTUnwrap(subFolder.i("id"))
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { $0.beginPage() }
        let source = dir.appendingPathComponent("Blatt 1 Lösung.pdf")
        try pdf.write(to: source)
        let staged = try ExternalFileImport.stage(source, container: nil)
        let id = try await ExternalFileImport.create(staged, api: api, moduleID: mid, folderID: sub)
        let lib = try await api.value("/api/library")
        let f = try XCTUnwrap(lib.list("files").first { $0.s("id") == id })
        XCTAssertEqual(f.i("folder_id"), sub, "im gewaehlten Unterordner, nicht in „Eigene Notizen“")
        XCTAssertFalse(lib.list("folders").contains { $0.s("name") == "Eigene Notizen" }, "kein Ordner „Eigene Notizen“ angelegt")
    }

    // MARK: Ansichten

    /// Liste auf der obersten Ebene: Module und Ordner als Zeilen (vorher immer Kacheln), Kacheln wie bisher
    func testRootListShowsModulesAndFoldersAsRows() throws {
        remember("lib-mode", "list")
        remember("lib-view", nil)
        let env = try hostWithEnvironment(LibraryPage(section: nil, path: nil, q: nil), api: api(), size: CGSize(width: 1180, height: 1600))
        XCTAssertTrue(env.wait { self.labels(env.view).contains("Analysis") }, "\(labels(env.view))")
        // Zeile = Name, dann die Spalte "Art" (Modul | Ordner); Kacheln haben keine Spalte "Art"
        func kind(after name: String, in shown: [String]) -> String? {
            shown.firstIndex(of: name).flatMap { $0 + 1 < shown.count ? shown[$0 + 1] : nil }
        }
        let list = labels(env.view)
        XCTAssertEqual(kind(after: "Analysis", in: list), "Modul", "Modul als Zeile: \(list)")
        XCTAssertEqual(kind(after: "Privat", in: list), "Ordner", "eigener Ordner als Zeile: \(list)")
        XCTAssertTrue(list.contains("Lose Notiz"))

        UserDefaults.standard.set("grid", forKey: "lib-mode")
        XCTAssertTrue(env.wait { !self.labels(env.view).contains("Modul") }, "Kacheln: \(labels(env.view))")
        let grid = labels(env.view)
        XCTAssertTrue(grid.contains("Analysis") && grid.contains("Privat"), "\(grid)")
        XCTAssertNotEqual(kind(after: "Privat", in: grid), "Ordner", "\(grid)")
    }

    /// Schmale Liste (iPad hochkant mit Seitenleiste, Split View, kleines Mac-Fenster): statt der festen Spalten
    /// (rund 460 pt, fuer den Namen blieb kaum Platz) Name mit Unterzeile; breit wie bisher in Spalten
    func testNarrowListShowsNameWithSubline() throws {
        remember("lib-mode", "list")
        remember("lib-view", nil)
        let narrow = try hostWithEnvironment(LibraryPage(section: nil, path: nil, q: nil), api: api(), size: CGSize(width: 560, height: 1600))
        XCTAssertTrue(narrow.wait { self.labels(narrow.view).contains("Analysis") }, "\(labels(narrow.view))")
        narrow.pump(0.5)
        let shown = labels(narrow.view)
        XCTAssertTrue(shown.contains("Modul · 0 Dokumente"), "\(shown)")
        XCTAssertTrue(shown.contains("Ordner · 0 Dokumente"), "\(shown)")
        XCTAssertTrue(shown.contains { $0.contains("Eigene") && $0.contains(" · ") }, "Unterzeile eines Dokuments: \(shown)")
        XCTAssertFalse(shown.contains("Eigene"), "keine eigene Spalte: \(shown)")

        let wide = try hostWithEnvironment(LibraryPage(section: nil, path: nil, q: nil), api: api(), size: CGSize(width: 1180, height: 1600))
        XCTAssertTrue(wide.wait { self.labels(wide.view).contains("Analysis") })
        wide.pump(0.5)
        let columns = labels(wide.view)
        XCTAssertTrue(columns.contains("Modul"), "\(columns)")
        XCTAssertTrue(columns.contains("Eigene"), "\(columns)")
        XCTAssertFalse(columns.contains("Modul · 0 Dokumente"), "\(columns)")
    }

    /// Unterordner eines Modulordners: "m1/f5/f9" zeigt den Inhalt von "Blatt 1" (vorher den von "Übungen")
    func testNestedFolderInModuleShowsItsOwnContent() throws {
        remember("lib-mode", "list")
        let env = try hostWithEnvironment(LibraryPage(section: nil, path: "m1/f5/f9", q: nil), api: api(), size: CGSize(width: 1180, height: 1400))
        XCTAssertTrue(env.wait { self.labels(env.view).contains("Tief") }, "\(labels(env.view))")
        let shown = labels(env.view)
        XCTAssertFalse(shown.contains("Flach"), "Inhalt des uebergeordneten Ordners: \(shown)")
        for crumb in ["Analysis", "Übungen", "Blatt 1"] { XCTAssertTrue(shown.contains(crumb), "Pfad „\(crumb)“ fehlt: \(shown)") }
        XCTAssertEqual(LibraryPage.dropFolder("m1/f5/f9"), 9)
    }

    /// "Ordner | Regal" bleibt gemerkt: "Dokumente & Notizen" aus der Seitenleiste (#/files) zeigt das zuletzt gewaehlte
    func testShelfChoiceIsRemembered() throws {
        remember("lib-view", "shelf")
        let env = try hostWithEnvironment(LibraryPage(section: nil, path: nil, q: nil), api: api(), size: CGSize(width: 1180, height: 1600))
        XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.contains("Leibniz Universität Hannover") } }, "Regal: \(labels(env.view))")
        // ein Ordnerpfad (Brotkrumen, Modulauswahl) zeigt immer die Ordner
        let folder = try hostWithEnvironment(LibraryPage(section: nil, path: "m1", q: nil), api: api(), size: CGSize(width: 1180, height: 1400))
        XCTAssertTrue(folder.wait { self.labels(folder.view).contains("Übungen") }, "\(labels(folder.view))")
    }
}
