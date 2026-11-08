import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Wochen von Hand (07.11.2026, WeekMoveViews): Verschieben einzeln und mehrfach ueber das lokale Backend, Dauerhaftigkeit
/// nach einem Neustart, Mehrfachauswahl und Menue "In Woche verschieben …" im Moduldetail, Dialog mit Wochenliste,
/// eigener Abschnitt (Anlegen, Ordnen, Loeschen), Regal. Alles mit erfundenen Kursen und Dateien in einer eigenen
/// Datenbank. Gewartet wird mit `Task.sleep` (nicht `RunLoop.run`): die Antworten des lokalen Backends kommen ueber den
/// MainActor, den eine verschachtelte RunLoop nicht abarbeitet (siehe LocalModulesAppTests). Mit
/// UF_SCREENSHOT_WAIT=<Sekunden> bleibt das geoeffnete Menue so lange stehen (fuer `simctl io screenshot`).
@MainActor
final class WeekAssignmentAppTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-weeks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        HostedEnvironment.accessibilityAutomation(true)
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    private let clock = UniFlowClock.fixed(berlin: "2026-11-20T10:00:00")!

    private func ts(_ local: String) -> SQLiteValue {
        .integer(Int64(UniFlowClock.fixed(berlin: local)!.now.timeIntervalSince1970))
    }

    /// Lokales Backend im Ordner `dir`: ein Fach mit drei Vorlesungen (Woche 1, 2, 3) und einem Blatt (Woche 2)
    private func host(seed: Bool) async throws -> (host: LocalBackendHost, api: APIClient) {
        let host = LocalBackendHost(directory: dir.appendingPathComponent("db", isDirectory: true), clock: clock)
        let backend = try await host.backend()
        let files: [(String, String, String, String)] = [
            ("f-1", "k-v", "VL01 Mengen.pdf", "2026-10-13T10:00"), ("f-2", "k-v", "VL02 Folgen.pdf", "2026-10-20T10:00"),
            ("f-3", "k-v", "VL03 Reihen.pdf", "2026-10-27T10:00"), ("f-4", "k-u", "Blatt 2.pdf", "2026-10-21T10:00"),
        ]
        let rows: [[SQLiteValue]] = files.map { [.text($0.0), .text($0.1), .text($0.2), ts($0.3)] }
        if seed {
            try await backend.context.database.transaction { c in
                for (id, title) in [("k-v", "Testmathematik I"), ("k-u", "Übung zu Testmathematik I")] {
                    let (subject, kind) = UniRules.classify(title)
                    try c.execute("INSERT INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                                  [.text(id), .text(title), .text("WiSe 2026/27"), .text(subject), .text(kind), .text("2026-10-01T08:00:00")])
                }
                for r in rows {
                    try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, mime) VALUES (?,?,?,?,'neu','pdf','application/pdf')", r)
                }
            }
        }
        return (host, APIClient(base: APIClient.localBase, transport: LocalTransport(host: host)))
    }

    private func moduleID(_ api: APIClient) async throws -> Int {
        let first = try await api.value("/api/modules").items.first
        return try XCTUnwrap(first?.i("id"))
    }

    private func labels(_ api: APIClient, _ mid: Int) async throws -> [String] {
        try await api.value("/api/modules/\(mid)").list("weeks").map { $0.s("label") ?? "" }
    }

    private func expectWeeks(_ api: APIClient, _ mid: Int, _ expected: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
        let got = try await labels(api, mid)
        XCTAssertEqual(got, expected, file: file, line: line)
    }

    /// Wartet, bis die Wochen des Moduls `ok` erfuellen; liefert den letzten Stand
    @discardableResult
    private func waitWeeks(_ api: APIClient, _ mid: Int, timeout: Double = 10, until ok: ([String]) -> Bool) async throws -> [String] {
        let end = Date().addingTimeInterval(timeout)
        var last: [String] = []
        repeat {
            last = try await labels(api, mid)
            if ok(last) { return last }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < end
        return last
    }

    // MARK: Bedienungshilfen-Baum (asynchron gewartet)

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

    private func shows(_ view: UIView, _ text: String) -> Bool {
        elements(in: view).contains { $0.accessibilityLabel?.contains(text) == true }
    }

    private func all(_ env: HostedEnvironment) -> String { env.labels().joined(separator: "\n") }

    /// Wartet asynchron (die Seite laedt ueber den MainActor), hoechstens `timeout` Sekunden
    @discardableResult
    private func wait(_ env: HostedEnvironment, timeout: Double = 10, until cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end {
            try? await Task.sleep(nanoseconds: 60_000_000)
            env.view.layoutIfNeeded()
        }
        return cond()
    }

    private func settle(_ seconds: Double = 0.4) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @discardableResult
    private func tap(_ label: String, in view: UIView, prefix: Bool = false) -> Bool {
        for e in elements(in: view) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, prefix ? l.hasPrefix(label) : l == label else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    /// Alle Fenster der Szene (ein geoeffnetes Menue liegt in einem eigenen Fenster)
    private func windows(_ env: HostedEnvironment) -> [UIView] {
        (env.window.windowScene?.windows ?? [env.window]).map { $0 as UIView }
    }

    private func screenshotWait() async {
        guard let s = ProcessInfo.processInfo.environment["UF_SCREENSHOT_WAIT"], let seconds = Double(s), seconds > 0 else { return }
        await settle(seconds)
    }

    // MARK: Verschieben und Dauerhaftigkeit

    func testMoveSingleAndMultipleAndKeepAfterRestart() async throws {
        let (_, api) = try await host(seed: true)
        let mid = try await moduleID(api)
        try await expectWeeks(api, mid, ["Woche 1 · 12.10. – 18.10.", "Woche 2 · 19.10. – 25.10.", "Woche 3 · 26.10. – 01.11."])
        // einzeln
        var r = try await api.value("/api/files/week", method: "POST", body: ["file_ids": ["f-1"], "week": 4])
        XCTAssertEqual(r.i("changed"), 1)
        // mehrere auf einmal
        r = try await api.value("/api/files/week", method: "POST", body: ["file_ids": ["f-2", "f-4"], "week": 5])
        XCTAssertEqual(r.i("changed"), 2)
        try await expectWeeks(api, mid, ["Woche 3 · 26.10. – 01.11.", "Woche 4 · 02.11. – 08.11.", "Woche 5 · 09.11. – 15.11."])
        // Neustart: neuer Host auf demselben Ordner
        let (_, again) = try await host(seed: false)
        let d = try await again.value("/api/modules/\(mid)")
        XCTAssertEqual(d.list("weeks").map { $0.s("label") ?? "" }, ["Woche 3 · 26.10. – 01.11.", "Woche 4 · 02.11. – 08.11.", "Woche 5 · 09.11. – 15.11."])
        let week5 = d.list("weeks")[2]
        XCTAssertEqual(week5.list("vorlesungen").map { $0.s("id") ?? "" }, ["f-2"])
        XCTAssertEqual(week5.list("uebungen").map { $0.s("id") ?? "" }, ["f-4"])
        XCTAssertEqual(week5.list("vorlesungen").first?["week_manual"]?.bool, true)
        XCTAssertNil(d.list("weeks")[0].list("vorlesungen").first?["week_manual"])
        // zurueck auf automatisch
        r = try await again.value("/api/files/week", method: "POST", body: ["file_ids": ["f-1", "f-2", "f-4"], "auto": true])
        XCTAssertEqual(r.i("changed"), 3)
        try await expectWeeks(again, mid, ["Woche 1 · 12.10. – 18.10.", "Woche 2 · 19.10. – 25.10.", "Woche 3 · 26.10. – 01.11."])
    }

    // MARK: Moduldetail: Auswahl und Menue

    func testModulePageSelectionAndMoveMenu() async throws {
        let (_, api) = try await host(seed: true)
        let mid = try await moduleID(api)
        let env = try hostWithEnvironment(ModulePage(id: mid), api: api, size: CGSize(width: 1180, height: 1400))
        XCTAssertTrue(await wait(env) { self.shows(env.view, "VL02 Folgen") }, all(env))
        XCTAssertTrue(shows(env.view, "Auswählen"))
        XCTAssertTrue(shows(env.view, "Abschnitte"))
        // Mehrfachauswahl: zwei Zeilen antippen
        XCTAssertTrue(tap("Auswählen", in: env.view))
        XCTAssertTrue(await wait(env) { self.shows(env.view, "Dokumente antippen") }, all(env))
        XCTAssertTrue(tap("VL01 Mengen", in: env.view, prefix: true))
        await settle(0.2)
        XCTAssertTrue(tap("VL02 Folgen", in: env.view, prefix: true))
        XCTAssertTrue(await wait(env) { self.shows(env.view, "2 ausgewählt") }, all(env))
        // Menue "In Woche verschieben …" oeffnen (eigenes Fenster) und "Woche 4" waehlen
        let menu = elements(in: env.view).first { $0.accessibilityLabel == WeekMove.menuTitle }
        XCTAssertNotNil(menu, all(env))
        XCTAssertTrue(menu?.accessibilityActivate() == true)
        await settle(1.0)
        await screenshotWait()
        let menuItem = windows(env).flatMap { elements(in: $0) }.first { $0.accessibilityLabel?.hasPrefix("Woche 4 ·") == true }
        if let menuItem {
            XCTAssertTrue(menuItem.accessibilityActivate())
            let moved = try await waitWeeks(api, mid) { $0.contains("Woche 4 · 02.11. – 08.11.") }
            XCTAssertTrue(moved.contains("Woche 4 · 02.11. – 08.11."), "die Auswahl wandert nach Woche 4: \(moved)")
            let d = try await api.value("/api/modules/\(mid)")
            XCTAssertEqual(d.list("weeks").first { $0.i("week") == 4 }?.list("vorlesungen").map { $0.s("id") ?? "" }, ["f-1", "f-2"])
            XCTAssertTrue(await wait(env) { self.shows(env.view, "Woche 4 · 02.11. – 08.11.") }, "die Seite laedt neu: \(all(env))")
            XCTAssertTrue(shows(env.view, WeekMove.manualHint))
        } else {
            // das Menue liess sich nicht ueber die Bedienungshilfen treffen (anderes Fenster): die Funktion dahinter
            try await WeekMove.move(api, ids: ["f-1", "f-2"], week: 4)
            try await expectWeeks(api, mid, ["Woche 2 · 19.10. – 25.10.", "Woche 3 · 26.10. – 01.11.", "Woche 4 · 02.11. – 08.11."])
        }
        XCTAssertTrue(await wait(env) { self.tap("Fertig", in: env.view) })
        XCTAssertTrue(await wait(env) { !self.shows(env.view, "ausgewählt") })
    }

    // MARK: Dialog mit Wochenliste (Dokumente & Notizen)

    func testMoveDialogListsWeeksAndMoves() async throws {
        let (_, api) = try await host(seed: true)
        let mid = try await moduleID(api)
        _ = try await api.value("/api/modules/\(mid)/sections", method: "POST", body: ["name": "Altklausuren", "after_week": -2])
        let env = try hostWithEnvironment(MoveToWeekDialog(fileIDs: ["f-3"], moduleID: mid, current: 3, manual: false), api: api,
                                          size: CGSize(width: 700, height: 900))
        XCTAssertTrue(await wait(env) { self.shows(env.view, "Woche 3 · 26.10. – 01.11., aktuell") }, all(env))
        let labels = env.labels()
        XCTAssertTrue(labels.contains("Allgemein"))
        XCTAssertTrue(labels.contains("Woche 14 · 11.01. – 17.01."))
        XCTAssertTrue(labels.contains("Altklausuren"), "eigener Abschnitt steht in der Liste")
        XCTAssertTrue(labels.contains("Klausuren & Altklausuren"))
        XCTAssertFalse(labels.contains(WeekMove.resetText), "nicht von Hand gesetzt: kein Zuruecksetzen")
        XCTAssertTrue(tap("Altklausuren", in: env.view))
        let after = try await waitWeeks(api, mid) { $0.last == "Altklausuren" }
        XCTAssertEqual(after, ["Woche 1 · 12.10. – 18.10.", "Woche 2 · 19.10. – 25.10.", "Altklausuren"])
        let d = try await api.value("/api/modules/\(mid)")
        XCTAssertEqual(d.list("weeks").last?["custom"]?.bool, true)
        XCTAssertEqual(d.list("weeks").last?.list("vorlesungen").map { $0.s("id") ?? "" }, ["f-3"])
    }

    // MARK: Eigene Abschnitte: Anlegen, Ordnen, Loeschen

    func testSectionsDialogCreatesOrdersAndDeletes() async throws {
        let (_, api) = try await host(seed: true)
        let mid = try await moduleID(api)
        // Anlegen ueber den Dialog: ohne Namen ist "Anlegen" aus
        let create = try hostWithEnvironment(SectionEditDialog(moduleID: mid, fileIDs: ["f-4"]), api: api, size: CGSize(width: 700, height: 700))
        XCTAssertTrue(await wait(create) { self.shows(create.view, "Neuer Abschnitt") }, all(create))
        XCTAssertTrue(shows(create.view, "Das Dokument kommt gleich in den neuen Abschnitt"), all(create))
        let save = elements(in: create.view).first { $0.accessibilityLabel == "Anlegen" }
        XCTAssertNotNil(save, all(create))
        XCTAssertTrue(save?.accessibilityTraits.contains(.notEnabled) == true, "ohne Namen nicht anlegbar")
        create.window.isHidden = true
        // mit Namen (derselbe Aufruf wie der Dialog): der Abschnitt entsteht hinter Woche 2, das Blatt darin
        _ = try await api.value("/api/modules/\(mid)/sections", method: "POST",
                                body: ["name": "Woche 2b Klausurvorbereitung", "after_week": 2, "file_ids": ["f-4"]])
        try await expectWeeks(api, mid, ["Woche 1 · 12.10. – 18.10.", "Woche 2 · 19.10. – 25.10.", "Woche 2b Klausurvorbereitung", "Woche 3 · 26.10. – 01.11."])
        // Moduldetail zeigt den Abschnitt als Block
        let page = try hostWithEnvironment(ModulePage(id: mid), api: api, size: CGSize(width: 1180, height: 1400))
        XCTAssertTrue(await wait(page) { self.shows(page.view, "Woche 2b Klausurvorbereitung") }, all(page))
        XCTAssertTrue(shows(page.view, "Eigener Abschnitt"), all(page))
        XCTAssertTrue(shows(page.view, "Blatt 2"))
        page.window.isHidden = true
        // Ordnen und Loeschen im Dialog "Wochen & Abschnitte"
        let manage = try hostWithEnvironment(SectionsManageDialog(moduleID: mid), api: api, size: CGSize(width: 760, height: 900))
        XCTAssertTrue(await wait(manage) { self.shows(manage.view, "Woche 2b Klausurvorbereitung") }, all(manage))
        XCTAssertTrue(shows(manage.view, "Wochen & Abschnitte"))
        XCTAssertTrue(tap("Nach unten", in: manage.view))
        let down = ["Woche 1 · 12.10. – 18.10.", "Woche 2 · 19.10. – 25.10.", "Woche 3 · 26.10. – 01.11.", "Woche 2b Klausurvorbereitung"]
        let afterDown = try await waitWeeks(api, mid) { $0 == down }
        XCTAssertEqual(afterDown, down)
        for expected in ["Woche 3 · 26.10. – 01.11.", "Woche 2 · 19.10. – 25.10.", "Woche 1 · 12.10. – 18.10."] {
            XCTAssertTrue(tap("Nach oben", in: manage.view))
            let now = try await waitWeeks(api, mid) { $0.firstIndex(of: "Woche 2b Klausurvorbereitung").map { $0 + 1 } == $0.firstIndex(of: expected) }
            XCTAssertEqual(now.firstIndex(of: "Woche 2b Klausurvorbereitung").map { $0 + 1 }, now.firstIndex(of: expected), "\(now)")
        }
        let top = try await labels(api, mid)
        XCTAssertEqual(top.first, "Woche 2b Klausurvorbereitung")
        // Loeschen (Rueckfrage bestaetigen): das Blatt liegt wieder automatisch in Woche 2
        XCTAssertTrue(await wait(manage) { self.tap("Löschen", in: manage.view) })
        XCTAssertTrue(await wait(manage) { manage.overlay.ask != nil })
        guard case .confirm(_, let c) = manage.overlay.ask else { return XCTFail("keine Rueckfrage") }
        manage.overlay.ask = nil
        c.resume(returning: true)
        let auto = ["Woche 1 · 12.10. – 18.10.", "Woche 2 · 19.10. – 25.10.", "Woche 3 · 26.10. – 01.11."]
        let afterDelete = try await waitWeeks(api, mid) { $0 == auto }
        XCTAssertEqual(afterDelete, auto)
        let d = try await api.value("/api/modules/\(mid)")
        XCTAssertEqual(d.list("weeks")[1].list("uebungen").map { $0.s("id") ?? "" }, ["f-4"])
        XCTAssertNil(d.list("weeks")[1].list("uebungen").first?["week_manual"])
    }

    // MARK: Regal

    func testShelfShowsSectionsAndManualWeeks() async throws {
        let (_, api) = try await host(seed: true)
        let mid = try await moduleID(api)
        _ = try await api.value("/api/modules/\(mid)/sections", method: "POST", body: ["name": "Altklausuren", "after_week": -2])
        _ = try await api.value("/api/files/week", method: "POST", body: ["file_ids": ["f-3"], "week": 6])
        let env = try hostWithEnvironment(LibraryPage(section: "shelf", path: nil, q: nil), api: api, size: CGSize(width: 1180, height: 1600))
        XCTAssertTrue(await wait(env) { self.shows(env.view, "VL03 Reihen") }, all(env))
        let labels = env.labels()
        XCTAssertTrue(labels.contains { $0.hasPrefix("Woche 6, 16.11. – 22.11.") }, labels.joined(separator: "\n"))
        XCTAssertTrue(labels.contains { $0.contains("VL03 Reihen") && $0.contains(WeekMove.manualHint) }, "Buch nennt die Woche von Hand")
        XCTAssertTrue(labels.contains { $0.hasPrefix("Altklausuren") }, "leerer Abschnitt steht als Brett im Regal")
        XCTAssertTrue(labels.contains { $0.contains("Noch leer") })
    }
}
