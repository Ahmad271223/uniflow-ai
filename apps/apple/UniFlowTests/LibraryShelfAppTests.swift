import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// "Mein Regal" (04.11.2026): Umschalter "Ordner | Regal" in Dokumente & Notizen, Regal aus `GET /api/index/shelf`
/// (Studiengang und Semester als Abschnitte, Module als Regale in der Fachfarbe, Wochen mit Datum, Arten als Etiketten
/// in den Farben der Community, Dateien als Buecher mit Seitenzahl, "erklärt" und eigenen Notizen), Leerzustand und
/// Hinweis, Antippen oeffnet das Dokument. Alles gegen einen Schein-Transport mit erfundenen Antworten (lokale
/// Datenquelle, kein Netz). Mit UF_SCREENSHOT_DIR schreibt der Ansichtstest Bilder in hell und dunkel.
@MainActor
final class LibraryShelfAppTests: XCTestCase {

    /// Schein-Transport: feste Antworten je Pfad, merkt sich die Pfade
    final class Transport: APITransport, @unchecked Sendable {
        private let lock = NSLock()
        private var canned: [String: JSONValue] = [:]
        private var log: [String] = []

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let answer: JSONValue? = lock.withLock { log.append(path); return canned[path] }
            let data = (answer ?? ["detail": "Testfehler"]).serialized()
            return (data, HTTPURLResponse(url: request.url!, statusCode: answer == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!)
        }

        func answer(_ path: String, _ v: JSONValue) { lock.withLock { canned[path] = v } }
        func count(_ path: String) -> Int { lock.withLock { log.filter { $0 == path }.count } }
    }

    // MARK: Erfundenes Regal

    private static func file(_ id: String, _ title: String, kind: String, label: String, status: String = "none", pages: Int? = 12,
                             date: String = "2026-10-27", notes: Int = 0, downloaded: Bool = true, indexed: Int = 0) -> JSONValue {
        ["file_id": .string(id), "name": .string(title + ".pdf"), "title": .string(title), "date": .string(date),
         "sha": .null, "page_count": pages.map { .number(Double($0)) } ?? .null, "indexed_pages": .number(Double(indexed)),
         "failed_pages": 0, "status": .string(status), "kind": .string(kind), "kind_label": .string(label),
         "note_pages": .number(Double(notes)), "downloaded": .bool(downloaded)]
    }

    /// Zwei Semester (neuestes zuerst), zwei Module, Wochen mit Arten in fester Reihenfolge
    static let shelf: JSONValue = [
        "university": ["key": "luh", "name": "Leibniz Universität Hannover"],
        "programs": [["name": "Allgemein", "semesters": [
            ["name": "WiSe 2026/27", "modules": [
                ["name": "Testanalysis I", "module_id": 1, "key": "luh:testanalysis-i", "color": "#175ee8", "weeks": [
                    ["week": 1, "label": "Woche 1 · 19.10. – 25.10.", "from": "2026-10-20", "to": "2026-10-20", "kinds": [
                        ["kind": "vorlesung", "label": "Vorlesung", "files": [
                            file("f-vl1", "VL01 Mengen", kind: "vorlesung", label: "Vorlesung", status: "ready", date: "2026-10-20", indexed: 12)]]]],
                    ["week": 2, "label": "Woche 2 · 26.10. – 01.11.", "from": "2026-10-27", "to": "2026-10-28", "kinds": [
                        ["kind": "vorlesung", "label": "Vorlesung", "files": [
                            file("f-vl2", "VL02 Folgen", kind: "vorlesung", label: "Vorlesung", notes: 3)]],
                        ["kind": "hoersaaluebung", "label": "Hörsaalübung", "files": [
                            file("f-hu2", "Hörsaalübung 2", kind: "hoersaaluebung", label: "Hörsaalübung", status: "partial", pages: 4, indexed: 2)]],
                        ["kind": "gruppenuebung", "label": "Gruppenübung", "files": [
                            file("f-ue2", "Blatt 2", kind: "gruppenuebung", label: "Gruppenübung", pages: nil, date: "2026-10-28", downloaded: false)]]]],
                    ["week": -2, "label": "Klausuren & Altklausuren", "from": "2026-10-20", "to": "2026-10-20", "kinds": [
                        ["kind": "altklausur", "label": "Altklausur", "files": [
                            file("f-alt", "Altklausur WS24", kind: "altklausur", label: "Altklausur", pages: 6, date: "2026-10-20")]]]]]],
                ["name": "Testphysik", "module_id": 2, "key": "luh:testphysik", "color": "#1f9682", "weeks": [
                    ["week": 2, "label": "Woche 2 · 26.10. – 01.11.", "from": "2026-10-29", "to": "2026-10-29", "kinds": [
                        ["kind": "skript", "label": "Skript", "files": [
                            file("f-ph", "Skript Mechanik", kind: "skript", label: "Skript", pages: 80, date: "2026-10-29")]]]]]]]],
            ["name": "SoSe 2026", "modules": [
                ["name": "Testprogrammierung", "module_id": .null, "key": "", "color": .null, "weeks": [
                    ["week": -1, "label": "Ältere Unterlagen", "from": "2026-04-20", "to": "2026-05-04", "kinds": [
                        ["kind": "sonstiges", "label": "Sonstiges", "files": [
                            file("f-alt-prog", "Einführung", kind: "sonstiges", label: "Sonstiges", pages: 1, date: "2026-04-20")]]]]]]]],
        ]]],
        "files": 7, "indexed": 2, "explained": 1,
    ]

    private func transport(shelf: JSONValue = LibraryShelfAppTests.shelf) -> Transport {
        let t = Transport()
        t.answer("/api/index/shelf", shelf)
        t.answer("/api/library", ["files": [], "modules": [["id": 1, "name": "Testanalysis I", "color": "#175ee8"]], "folders": [], "trash": []])
        t.answer("/api/courses", [])
        return t
    }

    /// Lokale Datenquelle (das Regal gibt es nur ohne eigenen Server), beantwortet vom Schein-Transport
    private func api(_ t: Transport) -> APIClient { APIClient(base: APIClient.localBase, transport: t) }

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    // MARK: Bedienungshilfen-Baum

    private func elements(in view: UIView) -> [NSObject] {
        view.layoutIfNeeded()
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
            if let o = element as? NSObject {
                if o.accessibilityLabel?.isEmpty == false { out.append(o) }
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

    /// Beschriftungen ohne Doppelte in der Reihenfolge des Baums
    private func labels(_ view: UIView) -> [String] {
        var seen = Set<String>()
        return elements(in: view).compactMap(\.accessibilityLabel).filter { seen.insert($0).inserted }
    }

    private func shows(_ view: UIView, _ text: String) -> Bool { labels(view).contains { $0.contains(text) } }

    @discardableResult
    private func tap(_ label: String, in view: UIView, prefix: Bool = false) -> Bool {
        for e in elements(in: view) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, prefix ? l.hasPrefix(label) : l == label else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    private func screenshot(_ env: HostedEnvironment, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty else { return }
        for (style, suffix) in [(UIUserInterfaceStyle.light, "hell"), (.dark, "dunkel")] {
            env.window.overrideUserInterfaceStyle = style
            env.pump(0.5)
            let view = env.view
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let png = UIGraphicsImageRenderer(bounds: view.bounds, format: format).pngData { _ in
                _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(suffix).png"))
        }
        env.window.overrideUserInterfaceStyle = .unspecified
    }

    // MARK: - Daten

    func testShelfTreeKeepsCoreOrderAndNamesEverything() throws {
        let tree = ShelfTree(json: Self.shelf)
        XCTAssertEqual(tree.university, "Leibniz Universität Hannover")
        XCTAssertEqual([tree.files, tree.indexed, tree.explained], [7, 2, 1])
        XCTAssertEqual(tree.summary, "7 Dateien · 1 erklärt")
        XCTAssertEqual(tree.programs.map(\.name), ["Allgemein"])
        XCTAssertEqual(tree.programs[0].semesters.map(\.name), ["WiSe 2026/27", "SoSe 2026"], "Reihenfolge des Kerns: neuestes Semester zuerst")
        let ana = tree.programs[0].semesters[0].modules[0]
        XCTAssertEqual(tree.programs[0].semesters[0].modules.map(\.name), ["Testanalysis I", "Testphysik"])
        XCTAssertEqual(ana.color, "#175ee8")
        XCTAssertEqual(ana.id, "m1")
        XCTAssertEqual(ana.weeks.map(\.week), [1, 2, -2])
        XCTAssertEqual(ana.weeks[1].title, "Woche 2")
        XCTAssertEqual(ana.weeks[1].dates, "26.10. – 01.11.")
        XCTAssertEqual(ana.weeks[2].title, "Klausuren & Altklausuren")
        XCTAssertEqual(ana.weeks[2].dates, "20.10.", "ohne Lehrwoche: das Datum der Dateien")
        let older = tree.programs[0].semesters[1].modules[0]
        XCTAssertEqual(older.weeks[0].dates, "20.04. – 04.05.")
        XCTAssertEqual(older.id, "n:Testprogrammierung", "ohne Modul und Schluessel: nach Name")
        XCTAssertNil(older.color)
        XCTAssertEqual(ana.weeks[1].kinds.map(\.label), ["Vorlesung", "Hörsaalübung", "Gruppenübung"])
        XCTAssertEqual(ana.files.count, 5)
        // Buecher: was VoiceOver sagt
        let vl2 = ana.weeks[1].kinds[0].files[0]
        XCTAssertEqual(ShelfTree.spoken(vl2), "VL02 Folgen, Vorlesung, 12 Seiten, Notizen auf 3 Seiten")
        XCTAssertEqual(ShelfTree.spoken(ana.weeks[0].kinds[0].files[0]), "VL01 Mengen, Vorlesung, 12 Seiten, erklärt")
        XCTAssertEqual(ShelfTree.spoken(ana.weeks[1].kinds[1].files[0]), "Hörsaalübung 2, Hörsaalübung, 4 Seiten, teilweise erklärt")
        XCTAssertEqual(ShelfTree.spoken(ana.weeks[1].kinds[2].files[0]), "Blatt 2, Gruppenübung, nicht geladen")
        XCTAssertEqual(ShelfTree.notesText(1), "Notizen auf 1 Seite")
        // Auswahl eines Moduls: nur dessen Regal, leere Semester fallen weg
        XCTAssertEqual(tree.moduleChoices.map(\.name), ["Testanalysis I", "Testphysik", "Testprogrammierung"])
        let physics = tree.only(module: "m2")
        XCTAssertEqual(physics.programs.flatMap { $0.semesters.map(\.name) }, ["WiSe 2026/27"])
        XCTAssertEqual(physics.programs[0].semesters[0].modules.map(\.name), ["Testphysik"])
        XCTAssertEqual(tree.only(module: ""), tree)
        // Daten
        XCTAssertEqual(ShelfTree.short("2026-10-27"), "27.10.")
        XCTAssertEqual(ShelfTree.short(""), "")
        XCTAssertEqual(ShelfTree.range("", ""), "")
        // fehlende neue Felder (aelterer Kern): Zaehler aus dem Baum, Dateien gelten als geladen
        let old = ShelfTree(json: ["university": ["name": "X"], "programs": [["name": "Allgemein", "semesters": [["name": "S", "modules": [
            ["name": "M", "module_id": 3, "key": "k", "weeks": [["week": 1, "label": "Woche 1", "kinds": [["kind": "uebung", "label": "Übung", "files": [
                ["file_id": "a", "name": "a.pdf", "title": "a", "status": "ready", "kind": "uebung", "kind_label": "Übung"]]]]]]]]]]]]])
        XCTAssertEqual([old.files, old.indexed, old.explained], [1, 1, 1])
        XCTAssertEqual(old.programs[0].semesters[0].modules[0].files.first?.downloaded, true)
        XCTAssertEqual(old.programs[0].semesters[0].modules[0].files.first?.notePages, 0)
    }

    /// Etiketten der Arten in den Farben der Community-Etiketten; Arten ohne Kanal aus derselben Palette
    func testKindTagsUseTheCommunityPalette() {
        XCTAssertEqual(ShelfKindStyle.pair("vorlesung"), CommunityChannelKind.vorlesung.pair)
        XCTAssertEqual(ShelfKindStyle.pair("uebung"), CommunityChannelKind.uebung.pair)
        XCTAssertEqual(ShelfKindStyle.pair("hoersaaluebung"), CommunityChannelKind.hoersaaluebung.pair)
        XCTAssertEqual(ShelfKindStyle.pair("gruppenuebung"), CommunityChannelKind.gruppenuebung.pair)
        XCTAssertEqual(ShelfKindStyle.pair("tutorium"), CommunityChannelKind.tutorium.pair)
        XCTAssertEqual(ShelfKindStyle.pair("klausur"), CommunityChannelKind.klausur.pair)
        XCTAssertEqual(ShelfKindStyle.pair("altklausur"), CommunityChannelKind.klausur.pair)
        XCTAssertEqual(ShelfKindStyle.pair("skript"), CommunityPalette.butter)
        XCTAssertEqual(ShelfKindStyle.pair("loesung"), CommunityPalette.lilac)
        XCTAssertEqual(ShelfKindStyle.pair("sonstiges"), ShelfKindStyle.neutral)
        XCTAssertEqual(ShelfKindStyle.icon("vorlesung"), CommunityChannelKind.vorlesung.icon)
        for kind in DocIndexCatalog.kindOrder { XCTAssertTrue(UFIconNames.all.contains(ShelfKindStyle.icon(kind)), kind) }
        // jede Art des Kerns hat ein eigenes Paar, nur Klausur und Altklausur teilen sich eines
        let kinds = DocIndexCatalog.kindOrder.filter { $0 != "altklausur" }
        for (i, a) in kinds.enumerated() {
            for b in kinds[(i + 1)...] { XCTAssertNotEqual(ShelfKindStyle.pair(a), ShelfKindStyle.pair(b), "\(a) und \(b)") }
        }
    }

    // MARK: - Ansicht

    /// Regal in der Bibliothek: Abschnitte in der Reihenfolge des Kerns, Etiketten je Woche, Buecher mit Stand und
    /// Notizen; Antippen oeffnet das Dokument, der Umschalter fuehrt zurueck zu den Ordnern
    func testShelfViewShowsSectionsTagsAndOpensDocument() throws {
        let t = transport()
        let env = try hostWithEnvironment(LibraryPage(section: "shelf", path: nil, q: nil), api: api(t), size: CGSize(width: 1180, height: 2400))
        XCTAssertTrue(env.wait { self.shows(env.view, "VL02 Folgen") }, labels(env.view).joined(separator: "\n"))
        let all = labels(env.view)
        XCTAssertTrue(shows(env.view, "Mein Regal"))
        XCTAssertTrue(shows(env.view, "Leibniz Universität Hannover · 7 Dateien · 1 erklärt"), all.joined(separator: "\n"))
        XCTAssertFalse(shows(env.view, LibraryShelf.emptyText), "es ist schon etwas eingeordnet")
        // Abschnitte: Studiengang und Semester, neuestes zuerst; darin die Module in ihrer Reihenfolge
        func index(_ s: String) -> Int { all.firstIndex { $0.contains(s) } ?? Int.max }
        XCTAssertLessThan(index("Allgemein, WiSe 2026/27"), index("Testanalysis I"))
        XCTAssertLessThan(index("Testanalysis I"), index("Testphysik"))
        XCTAssertLessThan(index("Testphysik"), index("Allgemein, SoSe 2026"))
        XCTAssertLessThan(index("Allgemein, SoSe 2026"), index("Testprogrammierung"))
        XCTAssertTrue(shows(env.view, "Testanalysis I, 5 Dateien · 1 erklärt"), all.joined(separator: "\n"))
        // Wochen mit Datum, in der Reihenfolge des Moduldetails
        XCTAssertLessThan(index("Woche 1, 19.10. – 25.10."), index("Woche 2, 26.10. – 01.11."))
        XCTAssertLessThan(index("Woche 2, 26.10. – 01.11."), index("Klausuren & Altklausuren, 20.10."))
        // Etiketten der Arten in fester Reihenfolge innerhalb der Woche
        XCTAssertLessThan(index("VL02 Folgen"), index("Hörsaalübung, 1 Datei"))
        XCTAssertLessThan(index("Hörsaalübung, 1 Datei"), index("Gruppenübung, 1 Datei"))
        XCTAssertTrue(shows(env.view, "Altklausur, 1 Datei"))
        XCTAssertTrue(shows(env.view, "Skript, 1 Datei"))
        // Buecher: Titel, Art, Seiten, erklaert, Notizen, nicht geladen
        XCTAssertTrue(shows(env.view, "VL01 Mengen, Vorlesung, 12 Seiten, erklärt"))
        XCTAssertTrue(shows(env.view, "VL02 Folgen, Vorlesung, 12 Seiten, Notizen auf 3 Seiten"))
        XCTAssertTrue(shows(env.view, "Blatt 2, Gruppenübung, nicht geladen"), "auch Dateien ohne Index und ohne Download stehen im Regal")
        // Umschalter: "Regal" ist gewaehlt
        let regal = elements(in: env.view).first { $0.accessibilityLabel == "Regal" && $0.accessibilityTraits.contains(.button) }
        XCTAssertEqual(regal?.accessibilityTraits.contains(.selected), true)
        screenshot(env, "regal")
        // Antippen oeffnet das Dokument
        XCTAssertTrue(tap("VL02 Folgen", in: env.view, prefix: true))
        XCTAssertTrue(env.wait { env.router.route == .doc("f-vl2") })
        // ein Modul waehlen: nur dessen Regal (die Auswahl selbst ist ein Menue; hier die Funktion dahinter)
        XCTAssertEqual(ShelfTree(json: Self.shelf).only(module: "m2").programs[0].semesters[0].modules.map(\.name), ["Testphysik"])
        // Umschalter zu den Ordnern
        XCTAssertTrue(tap("Ordner", in: env.view))
        XCTAssertTrue(env.wait { env.router.route == .files() })
        XCTAssertEqual(t.count("/api/index/shelf"), 1)
    }

    /// Grosse Schrift (Bedienungshilfen-Stufe 2) und schmales Fenster: Woche ueber den Buechern, alles bleibt lesbar
    /// und antippbar (Buecher mindestens 44 pt hoch)
    func testShelfAtLargeTextAndNarrowWidth() throws {
        let t = transport()
        let view = ScrollView { LibraryShelfView().padding(16) }
            .environment(\.ufWindowWidth, 600)
            .environment(\.dynamicTypeSize, .accessibility2)
            .background(UF.bg)
        let env = try hostWithEnvironment(view, api: api(t), size: CGSize(width: 600, height: 2400))
        XCTAssertTrue(env.wait { self.shows(env.view, "VL02 Folgen") }, labels(env.view).joined(separator: "\n"))
        let book = try XCTUnwrap(elements(in: env.view).first { $0.accessibilityLabel?.hasPrefix("VL01 Mengen") == true })
        XCTAssertGreaterThanOrEqual(book.accessibilityFrame.height, 44)
        XCTAssertLessThanOrEqual(book.accessibilityFrame.maxX, env.window.frame.maxX + 0.5, "kein Buch ragt ueber den Rand")
        let week = try XCTUnwrap(elements(in: env.view).first { $0.accessibilityLabel == "Woche 1, 19.10. – 25.10." })
        XCTAssertLessThan(week.accessibilityFrame.maxY, book.accessibilityFrame.minY + 1, "Woche ueber den Buechern")
        screenshot(env, "regal-gross-schmal")
    }

    /// Ordneransicht: der Umschalter steht oben und fuehrt zum Regal; mit eigenem Server gibt es ihn nicht
    func testFolderViewOffersTheShelf() throws {
        let t = transport()
        let env = try hostWithEnvironment(LibraryPage(section: nil, path: nil, q: nil), api: api(t))
        XCTAssertTrue(env.wait { self.tap("Regal", in: env.view) }, labels(env.view).joined(separator: "\n"))
        XCTAssertTrue(env.wait { env.router.route == .files(section: "shelf") })
        let server = try hostWithEnvironment(LibraryPage(section: nil, path: nil, q: nil),
                                             api: APIClient(base: URL(string: "http://erfunden.test/")!, transport: t))
        XCTAssertTrue(server.wait { self.shows(server.view, "Dokumente & Notizen") })
        server.pump(0.3)
        XCTAssertFalse(labels(server.view).contains("Regal"), "das Regal ist eine Abfrage des lokalen Backends")
    }

    /// Nichts im Regal: Leerzustand mit dem Weg zu den Ordnern; Dateien ohne jeden Index: Hinweis ueber dem Regal, die
    /// Dateien stehen trotzdem darin
    func testEmptyStateAndHintBeforeAnythingIsIndexed() throws {
        let empty = transport(shelf: ["university": ["key": "luh", "name": "Leibniz Universität Hannover"],
                                      "programs": [["name": "Allgemein", "semesters": []]], "files": 0, "indexed": 0, "explained": 0])
        let env = try hostWithEnvironment(LibraryShelfView().padding(), api: api(empty))
        XCTAssertTrue(env.wait { self.shows(env.view, LibraryShelf.emptyText) }, labels(env.view).joined(separator: "\n"))
        XCTAssertEqual(LibraryShelf.emptyText, "Noch nichts eingeordnet – öffne eine Datei mit KI-Hilfe")
        screenshot(env, "regal-leer")
        XCTAssertTrue(tap("Zu den Ordnern", in: env.view))
        XCTAssertTrue(env.wait { env.router.route == .files() })

        var none = Self.shelf
        none["indexed"] = 0
        none["explained"] = 0
        let hint = try hostWithEnvironment(LibraryShelfView().padding(), api: api(transport(shelf: none)))
        XCTAssertTrue(hint.wait { self.shows(hint.view, "VL02 Folgen") }, labels(hint.view).joined(separator: "\n"))
        XCTAssertTrue(shows(hint.view, LibraryShelf.emptyText), "Hinweis, solange nichts eingeordnet ist")
        XCTAssertTrue(shows(hint.view, "Blatt 2, Gruppenübung"))
    }

    /// Mit eigenem Server (kein lokales Backend) erklaert das Regal, wo es entsteht, statt eines Fehlers
    func testShelfExplainsItselfWithOwnServer() throws {
        let t = Transport()
        let env = try hostWithEnvironment(LibraryShelfView().padding(), api: APIClient(base: URL(string: "http://erfunden.test/")!, transport: t))
        XCTAssertTrue(env.wait { self.shows(env.view, LibraryShelf.serverText) }, labels(env.view).joined(separator: "\n"))
    }
}
