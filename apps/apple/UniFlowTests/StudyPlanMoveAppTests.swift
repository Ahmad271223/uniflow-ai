import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Befund des Inhabers am iPad (09.11.2026, LUH, QIS verbunden): "Im Studienverlauf kann ich Module nicht verschieben."
/// Durchgespielt mit dem echten lokalen Backend (Katalog TIBSc22 und QIS-Zeilen aus
/// fixtures/study-plan-engine/endpoints.json, dazu eine Anmeldung im WiSe 26/27, Uhr 09.11.2026):
/// - Verschieben ueber das Menue legt ein geplantes Modul wirklich ins Zielsemester (Kern und Ansicht gemeinsam)
/// - Ziehen und Ablegen klappt auch, nachdem die Seite neu aufgebaut wurde (MainView baut `StudyPlanPage` bei jeder
///   Aenderung der Sitzung neu; vorher hatte die neue Ablage keine Verbindung zur Seite und das Ablegen verpuffte still)
/// - Bestandenes und zur Pruefung Angemeldetes sind nicht verschiebbar (der Kern uebergeht dafuer jede eigene Lage);
///   die Oberflaeche nennt den Grund statt stumm nichts zu tun oder "verschoben" zu melden
/// - landet ein Modul nach dem Speichern nicht im Zielsemester, sagt die Rueckmeldung das
@MainActor
final class StudyPlanMoveAppTests: XCTestCase {

    typealias Transport = StudyPlanBoardAppTests.Transport

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    // MARK: Daten

    private func repoFile(_ path: String) throws -> Data {
        let url = ContainerTestBed.repoURL(path)
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("Fixture fehlt: \(url.path)") }
        return data
    }

    /// Lokales Backend wie am Geraet: Kataloge und QIS-Zeilen aus endpoints.json, dazu "Signale und Systeme" im
    /// WiSe 26/27 zur Pruefung angemeldet
    private func localAPI() async throws -> APIClient {
        let fx = try JSONValue.parse(repoFile("packages/shared-contracts/fixtures/study-plan-engine/endpoints.json"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("studyplan-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let host = LocalBackendHost(directory: dir.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-09T10:00:00")!)
        let backend = try await host.backend()
        // Seed und der Schritt mit den Katalogen (die anderen Schritte sind Anfragen)
        let sql = (fx["seed"]?.array ?? []) + (fx["steps"]?.array ?? []).flatMap { $0["sql"]?.array ?? [] }
        try await backend.context.database.transaction { c in
            for s in sql {
                _ = try c.execute(s["sql"]?.string ?? "", (s["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null })
            }
            _ = try c.execute("INSERT INTO grades(text, semester, status, note, versuch, pruefungsnr, credits, datum, abschluss, raw, fetched_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                              ["Signale und Systeme", "WiSe 26/27", "angemeldet", "", "1", "", "", "", "Technische Informatik (PO-Version 2017)", nil,
                               "2026-11-09T08:00:00"])
        }
        return APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
    }

    /// Die Seiten-Tests laufen synchron: nur dann arbeitet die Hauptschleife die Aufgaben der Ansicht ab
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

    private func localAPISync() throws -> APIClient { try awaiting { try await self.localAPI() } }

    /// Semester eines Moduls laut Kern
    private func termOf(_ id: String, api: APIClient, env: HostedEnvironment) -> String? {
        var out: String?
        var done = false
        Task { out = StudyPlan((try? await api.value("/api/study-plan")) ?? .null).semester(of: id)?.term; done = true }
        _ = env.wait { done }
        return out
    }

    // MARK: Hilfen

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

    private func actionNames(_ root: UIView, _ label: String) -> [String] {
        find(root, label: label)?.accessibilityCustomActions?.map(\.name) ?? []
    }

    @discardableResult
    private func perform(_ root: UIView, _ label: String, action name: String) -> Bool {
        guard let e = find(root, label: label), let a = e.accessibilityCustomActions?.first(where: { $0.name == name }) else { return false }
        if let h = a.actionHandler { return h(a) }
        guard let target = a.target else { return false }
        _ = (target as AnyObject).perform(a.selector, with: a)
        return true
    }

    private func sheet(_ env: HostedEnvironment) -> UIView? {
        guard let p = env.hosting.presentedViewController, !p.isBeingDismissed else { return nil }
        return p.view
    }

    private func dump(_ v: UIView?) -> String { v.map { labels($0).joined(separator: "\n") } ?? "(keine Ansicht)" }

    private let stochastik = "Stochastik für Ingenieure, 5 Leistungspunkte"
    private let signale = "Signale und Systeme, 6 Leistungspunkte"
    private let programmieren = "Programmieren I, 5 Leistungspunkte"

    // MARK: Verschieben ueber das Menue, Kern und Ansicht gemeinsam

    func testMoveViaMenuLandsInTargetSemesterThroughLocalBackend() throws {
        let api = try localAPISync()
        let env = try hostWithEnvironment(StudyPlanPage(), api: api)
        XCTAssertEqual(termOf("stochastik", api: api, env: env), "SoSe 27")
        XCTAssertTrue(env.wait { self.find(env.view, label: self.stochastik) != nil }, dump(env.view))
        XCTAssertTrue(perform(env.view, stochastik, action: "Verschieben nach …"), actionNames(env.view, stochastik).joined(separator: ", "))
        XCTAssertTrue(env.wait { self.sheet(env).map { self.find($0, label: "SoSe 28") != nil } ?? false }, dump(sheet(env)))
        XCTAssertTrue(tap(try XCTUnwrap(sheet(env)), "SoSe 28"))
        XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.hasPrefix("Stochastik für Ingenieure verschoben nach SoSe 28") } }, dump(env.view))
        XCTAssertEqual(termOf("stochastik", api: api, env: env), "SoSe 28", "liegt laut Kern im Zielsemester")
    }

    // MARK: Ziehen und Ablegen nach einem Neuaufbau der Seite

    /// Wie MainView: baut die Seite bei jeder Aenderung neu (mit neuer Ablage, wie der Standardwert von `dropHub`)
    final class Redraw: ObservableObject {
        @Published var tick = 0
        var hubs: [StudyPlanDropHub] = []
    }

    struct RedrawingHost: View {
        @ObservedObject var box: Redraw

        var body: some View {
            let hub = StudyPlanDropHub()
            box.hubs.append(hub)
            return StudyPlanPage(dropHub: hub).overlay(alignment: .topTrailing) { Text("\(box.tick)").hidden() }
        }
    }

    func testDropStillMovesAfterPageWasRebuilt() throws {
        let api = try localAPISync()
        let box = Redraw()
        let env = try hostWithEnvironment(RedrawingHost(box: box), api: api)
        XCTAssertTrue(env.wait { self.find(env.view, label: self.stochastik) != nil }, dump(env.view))
        let first = box.hubs.count
        box.tick += 1
        XCTAssertTrue(env.wait { box.hubs.count > first }, "Seite neu aufgebaut")
        env.pump(0.3)
        var ok: Bool?
        let hub = try XCTUnwrap(box.hubs.last)
        Task { ok = await hub.drop(["stochastik"], on: "SoSe 28") }
        XCTAssertTrue(env.wait { ok != nil })
        XCTAssertEqual(ok, true, "Ablegen nach dem Neuaufbau verschiebt")
        XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.hasPrefix("Stochastik für Ingenieure verschoben nach SoSe 28") } }, dump(env.view))
        XCTAssertEqual(termOf("stochastik", api: api, env: env), "SoSe 28")
    }

    // MARK: Nicht verschiebbar: Grund statt Stille

    func testPassedAndRegisteredAreLockedWithReason() throws {
        let api = try localAPISync()
        let hub = StudyPlanDropHub()
        let env = try hostWithEnvironment(StudyPlanPage(dropHub: hub), api: api)
        XCTAssertTrue(env.wait { self.find(env.view, label: self.signale) != nil && self.find(env.view, label: self.programmieren) != nil }, dump(env.view))
        // geplant: verschiebbar
        XCTAssertTrue(actionNames(env.view, stochastik).contains("Verschieben nach …"))
        // bestanden und angemeldet: keine Aktion, Grund im Hinweis (VoiceOver)
        for (card, reason) in [(programmieren, StudyPlanText.lockedPassed), (signale, StudyPlanText.lockedRegistered)] {
            XCTAssertFalse(actionNames(env.view, card).contains("Verschieben nach …"), card)
            XCTAssertFalse(actionNames(env.view, card).contains("Nicht belegen"), card)
            XCTAssertTrue(find(env.view, label: card)?.accessibilityHint?.contains(reason) ?? false,
                          "\(card) \(find(env.view, label: card)?.accessibilityHint ?? "-") " + labels(env.view).filter { $0.hasPrefix(card) }.joined(separator: " | "))
        }
        // Ablegen eines gesperrten Moduls: nichts gespeichert, Grund als Rueckmeldung
        var ok: Bool?
        Task { ok = await hub.drop(["signale-systeme"], on: "SoSe 28") }
        XCTAssertTrue(env.wait { ok != nil })
        XCTAssertEqual(ok, false)
        XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.contains(StudyPlanText.lockedRegistered) } }, dump(env.view))
        XCTAssertEqual(termOf("signale-systeme", api: api, env: env), "WiSe 26/27", "Angemeldetes bleibt im aktuellen Semester")
    }

    func testDetailOfLockedModuleExplainsWhy() throws {
        let api = try localAPISync()
        let env = try hostWithEnvironment(StudyPlanPage(), api: api)
        XCTAssertTrue(env.wait { self.find(env.view, label: self.signale) != nil }, dump(env.view))
        XCTAssertTrue(tap(env.view, signale))
        XCTAssertTrue(env.wait { self.sheet(env).map { self.find($0, label: StudyPlanText.lockedRegistered) != nil } ?? false }, dump(sheet(env)))
        let s = try XCTUnwrap(sheet(env))
        XCTAssertNil(find(s, label: "Verschieben nach …", exact: true))
    }

    // MARK: Ehrliche Rueckmeldung

    /// Der Kern speichert, legt das Modul aber nicht ins Ziel (hier: unveraenderter Plan): keine Erfolgsmeldung
    func testMoveThatDidNotLandSaysSo() throws {
        let engine = try JSONValue.parse(repoFile("packages/shared-contracts/fixtures/study-plan-engine/engine.json"))
        let plan = try XCTUnwrap(engine.list("cases").first { $0.s("name") == "selbst_verschoben" }?["expected"])
        let t = Transport()
        t.answer("/api/study-plan", plan)
        t.answer("POST /api/study-plan/settings", ["ok": true])
        t.answer("/api/study-catalog/status", ["state": "ready"])
        t.answer("/api/exam-registration", ["supported": false, "show_card": false, "suggestions": [], "registered": []])
        let hub = StudyPlanDropHub()
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: t)
        let env = try hostWithEnvironment(StudyPlanPage(dropHub: hub), api: api)
        XCTAssertTrue(env.wait { self.find(env.view, label: "Labor Technische Informatik,") != nil }, dump(env.view))
        Task { _ = await hub.drop(["labor"], on: "SoSe 28") }
        XCTAssertTrue(env.wait { t.count("POST", "/api/study-plan/settings") == 1 })
        XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.hasPrefix("Labor Technische Informatik bleibt in") } }, dump(env.view))
        XCTAssertFalse(labels(env.view).contains { $0.contains("verschoben nach SoSe 28") }, "keine falsche Erfolgsmeldung")
    }
}
