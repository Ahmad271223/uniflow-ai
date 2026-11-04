import Foundation
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Erklaerungsspeicher in der App (docs/ERKLAERUNGSSPEICHER-2026-11-04.md): Beschriftung und "Neu erklaeren lassen" in
/// der KI-Hilfe (reine Entscheidungen und die gerenderte Leiste gegen einen Schein-Transport), die Einstellung
/// "Vorab einordnen" und der CloudKit-Datensatz `PageExplain` gegen das nachgebildete CloudKit der Wochentests:
/// speichern, lesen, nie ueberschreiben, fremde Formen verwerfen. Kein Netz, keine KI.
@MainActor
final class PageExplainAppTests: XCTestCase {
    typealias Fake = WeeklyTestCloudKitTests.FakeWeeklyCloud

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    // MARK: KI-Hilfe

    func testTutorLabelAndRebuildDecisions() {
        XCTAssertNil(TutorPanel.storedLabel(nil), "Live-Antwort: nichts Besonderes")
        XCTAssertNil(TutorPanel.storedLabel(.null))
        XCTAssertNil(TutorPanel.storedLabel(["stored": false, "variant": 1, "shared": true]), "gerade live erzeugt: nichts Besonderes")
        XCTAssertEqual(TutorPanel.storedLabel(["stored": true, "source": "cloud", "variant": 1]), "Schon erklärt · sofort da · 0 Credits")
        XCTAssertEqual(TutorPanel.storedLabel(["stored": true, "source": "local", "variant": 0]), "Schon erklärt · 0 Credits")
        XCTAssertTrue(TutorPanel.offersRebuild(["stored": true, "source": "cloud"]))
        XCTAssertFalse(TutorPanel.offersRebuild(["stored": false]))
        XCTAssertFalse(TutorPanel.offersRebuild(nil))
        XCTAssertEqual(TutorPanel.label(mode: "explain", input: "", force: true), "Erklären (neu)")
        XCTAssertEqual(TutorPanel.label(mode: "explain", input: ""), "Erklären")
        XCTAssertEqual(TutorPanel.label(mode: "steps", input: "Teil b", force: true), "Aufgabe lösen: Teil b")
    }

    func testTutorPanelShowsStoredAnswerWithLabelAndRebuildSendsForce() throws {
        let t = AIViewsAppTests.Transport()
        t.answer("/api/index/file/f-1/page/3", ["file_id": "f-1", "page": 3, "status": "none", "can_build": false])
        t.answer("/api/ai/tutor", ["answer": "Die **Eigenwerte** sind die Nullstellen des charakteristischen Polynoms.", "cards": .null, "sources": [],
                                   "explain": ["stored": true, "source": "cloud", "variant": 1, "created_at": "2026-11-04T08:00:00Z"]])
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: t)
        let env = try hostWithEnvironment(TutorPanel(fileID: "f-1", page: { 3 }, selection: { "" }, open: { _, _ in }, close: {})
                                              .environment(\.ufAIEnabled, true), api: api)
        XCTAssertTrue(env.wait { self.button("Erklären", in: env.view) != nil }, texts(env.view).joined(separator: "\n"))
        XCTAssertFalse(shows(env.view, "Schon erklärt"), "beim Oeffnen nichts einfuegen, erst nach dem Antippen")
        XCTAssertTrue(tap("Erklären", in: env.view))
        XCTAssertTrue(env.wait { self.shows(env.view, "Schon erklärt · sofort da · 0 Credits") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "Nullstellen des charakteristischen Polynoms"))
        let first = try XCTUnwrap(t.bodies("/api/ai/tutor").first)
        XCTAssertEqual(first["mode"], "explain")
        XCTAssertNil(first["force"], "erste Anfrage ohne force: der Speicher darf antworten")
        // "Neu erklaeren lassen": dieselbe Anfrage mit force, die Antwort ist live und traegt keine Beschriftung
        t.answer("/api/ai/tutor", ["answer": "Frische Erklärung.", "cards": .null, "sources": [], "explain": ["stored": false, "variant": 2, "shared": true]])
        XCTAssertTrue(tap("Neu erklären lassen", in: env.view, exact: false))
        XCTAssertTrue(env.wait { t.count("POST", "/api/ai/tutor") == 2 })
        let second = try XCTUnwrap(t.bodies("/api/ai/tutor").last)
        XCTAssertEqual(second["force"], true)
        XCTAssertEqual(second["mode"], "explain")
        XCTAssertTrue(env.wait { self.shows(env.view, "Frische Erklärung.") })
        XCTAssertTrue(shows(env.view, "Erklären (neu)"))
        // der Baum nennt Elemente mehrfach (verschachtelte Container): die Live-Antwort steht nach der letzten Beschriftung
        let all = texts(env.view)
        let lastLabel = try XCTUnwrap(all.lastIndex { $0.contains("Schon erklärt") })
        let live = try XCTUnwrap(all.lastIndex { $0.contains("Frische Erklärung.") })
        XCTAssertGreaterThan(live, lastLabel, "die Live-Antwort traegt keine Beschriftung")
    }

    // MARK: Einstellung "Vorab einordnen"

    func testPrewarmSettingMapsValues() throws {
        XCTAssertEqual(DocIndexPrewarmSetting.key, "uniflow.docIndexPrewarmLevel")
        XCTAssertEqual(DocIndexPrewarmSetting.level(raw: nil), .basic, "Standard")
        XCTAssertEqual(DocIndexPrewarmSetting.level(raw: "basic"), .basic)
        XCTAssertEqual(DocIndexPrewarmSetting.level(raw: "full"), .full)
        XCTAssertEqual(DocIndexPrewarmSetting.level(raw: "alles"), .basic, "Unbekanntes gilt als Standard")
        let name = "uniflow.tests.prewarm.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        XCTAssertEqual(DocIndexPrewarmSetting.level(d), .basic)
        DocIndexPrewarmSetting.set(.full, d)
        XCTAssertEqual(d.string(forKey: "uniflow.docIndexPrewarmLevel"), "full")
        XCTAssertEqual(DocIndexPrewarmSetting.level(d), .full)
        XCTAssertEqual(DocIndexPrewarmSetting.label(.basic), "Zusammenfassung und Begriffe (Standard)")
        XCTAssertEqual(DocIndexPrewarmSetting.label(.full), "Alles (auch Erklärungen und Lösungen)")
        XCTAssertEqual(DocIndexPrewarmSetting.costNote, "Alles vorab kostet je Seite ein Vielfaches und löst Übungsaufgaben für alle, bevor jemand fragt.")
    }

    func testPrewarmCardRendersBothChoicesAndCostNote() throws {
        let env = try hostWithEnvironment(DocIndexPrewarmCard().padding())
        XCTAssertTrue(env.wait { self.shows(env.view, "Vorab einordnen") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "Zusammenfassung und Begriffe (Standard)"))
        XCTAssertTrue(shows(env.view, "Alles (auch Erklärungen und Lösungen)"))
        XCTAssertTrue(shows(env.view, DocIndexPrewarmSetting.costNote))
    }

    // MARK: CloudKit

    func testSaveReadNeverOverwriteAndRace() async throws {
        let store = WeeklyTestCloudKitTests.Store()
        let a = CloudKitPageExplain(cloud: Fake(store: store, user: "_a")), b = CloudKitPageExplain(cloud: Fake(store: store, user: "_b"))
        let key = String(repeating: "ab", count: 32)
        func rec(_ mode: String, _ variant: Int, _ payload: String, at: String = "2026-11-04T08:00:00Z") -> PageExplainRecord {
            PageExplainRecord(fileKey: key, page: 3, mode: mode, variant: variant, payload: payload, createdAt: at)
        }
        let saved = try await a.save(rec("explain", 1, "ZXJrbMOkcnQ="))
        XCTAssertTrue(saved)
        let savedSteps = try await a.save(rec("steps", 1, "bG9lc3VuZw=="))
        XCTAssertTrue(savedSteps)
        let read = try await b.records(fileKey: key, page: 3, mode: "explain")
        XCTAssertEqual(read.map(\.variant), [1])
        XCTAssertEqual(read.first?.payload, "ZXJrbMOkcnQ=")
        XCTAssertEqual(read.first?.ownerRecordName, "_a")
        XCTAssertEqual(read.first?.version, PageExplain.version)
        XCTAssertEqual(read.first?.recordName, "\(key)#3#explain#1")
        let steps = try await b.records(fileKey: key, page: 3, mode: "steps")
        XCTAssertEqual(steps.map(\.payload), ["bG9lc3VuZw=="], "Modi getrennt")
        let otherPage = try await b.records(fileKey: key, page: 4, mode: "explain")
        XCTAssertEqual(otherPage, [], "Seiten getrennt")
        // b will denselben Platz: nichts ueberschrieben, false; auch a ueberschreibt den eigenen nicht
        let bAgain = try await b.save(rec("explain", 1, "ZnJlbWQ=", at: "2026-11-04T09:00:00Z"))
        XCTAssertFalse(bAgain)
        let aAgain = try await a.save(rec("explain", 1, "bmV1", at: "2026-11-04T09:00:00Z"))
        XCTAssertFalse(aAgain)
        let still = try await b.records(fileKey: key, page: 3, mode: "explain")
        XCTAssertEqual(still.first?.payload, "ZXJrbMOkcnQ=")
        // Variante 2 ist frei
        let second = try await b.save(rec("explain", 2, "endlaQ==", at: "2026-11-04T09:00:00Z"))
        XCTAssertTrue(second)
        let two = try await a.records(fileKey: key, page: 3, mode: "explain")
        XCTAssertEqual(two.map(\.variant), [1, 2])
        // Wettlauf: zwischen Nachsehen und Speichern belegt ein anderes Geraet den Platz -> false, nichts kaputt
        let racer = Fake(store: store, user: "_c")
        racer.beforeSave = { _, record in
            var other = record
            other.creator = "_d"
            other[PageExplainCloudRecord.Field.owner] = .string("_d")
            other[PageExplainCloudRecord.Field.payload] = .string("ZnJlbWQ=")
            store.lock.withLock { store.records["pub|\(record.type)|\(record.name)"] = other }
        }
        let raced = try await CloudKitPageExplain(cloud: racer).save(rec("explain", 3, "Yw==", at: ""))
        XCTAssertFalse(raced)
        let three = try await a.records(fileKey: key, page: 3, mode: "explain")
        XCTAssertEqual(three.map(\.ownerRecordName), ["_a", "_b", "_d"], "der Fremde blieb")
        XCTAssertEqual(three.last?.payload, "ZnJlbWQ=")
        // ohne Konto: speichern scheitert, lesen geht
        let noAccount = Fake(store: store, user: "_e")
        noAccount.status = .noAccount
        do { _ = try await CloudKitPageExplain(cloud: noAccount).save(rec("explain", 1, "x")); XCTFail("kein Fehler") } catch {
            XCTAssertEqual(error as? CommunityCloudError, .notSignedIn)
        }
        let readable = try await CloudKitPageExplain(cloud: noAccount).records(fileKey: key, page: 3, mode: "explain")
        XCTAssertEqual(readable.count, 3)
    }

    func testForeignShapeIsIgnored() {
        let key = String(repeating: "cd", count: 32)
        func record(name: String, page: Int = 1, mode: String = "explain", variant: Int = 1, payload: String = "eA==") -> CommunityRecord {
            var r = CommunityRecord(type: PageExplainCloudRecord.type, name: name)
            r[PageExplainCloudRecord.Field.fileKey] = .string(key)
            r[PageExplainCloudRecord.Field.page] = .int(page)
            r[PageExplainCloudRecord.Field.mode] = .string(mode)
            r[PageExplainCloudRecord.Field.variant] = .int(variant)
            r[PageExplainCloudRecord.Field.payload] = .string(payload)
            r[PageExplainCloudRecord.Field.version] = .int(1)
            return r
        }
        XCTAssertNotNil(CloudKitPageExplain.record(record(name: "\(key)#1#explain#1")))
        XCTAssertNil(CloudKitPageExplain.record(record(name: "falsch#1#explain#1")), "Name passt nicht")
        XCTAssertNil(CloudKitPageExplain.record(record(name: "\(key)#1#explain#2")), "Variante im Namen passt nicht")
        XCTAssertNil(CloudKitPageExplain.record(record(name: "\(key)#1#ask#1", mode: "ask")), "Fragen werden nicht geteilt")
        XCTAssertNil(CloudKitPageExplain.record(record(name: "\(key)#1#explain#4", variant: 4)), "hoechstens drei")
        XCTAssertNil(CloudKitPageExplain.record(record(name: "\(key)#0#explain#1", page: 0)), "Seite 0 gibt es nicht")
        XCTAssertNil(CloudKitPageExplain.record(record(name: "\(key)#1#explain#1", payload: "")), "leeres Chiffrat")
        var wrongType = record(name: "\(key)#1#explain#1")
        wrongType.type = DocIndexCloudRecord.type
        XCTAssertNil(CloudKitPageExplain.record(wrongType))
    }

    // MARK: Hilfen (wie AIViewsAppTests)

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

    private func button(_ label: String, in view: UIView, exact: Bool = true) -> NSObject? {
        elements(in: view).first { e in
            guard e.accessibilityTraits.contains(.button), let l = e.accessibilityLabel else { return false }
            return exact ? l == label : l.hasPrefix(label)
        }
    }

    @discardableResult
    private func tap(_ label: String, in view: UIView, exact: Bool = true) -> Bool {
        for e in elements(in: view) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, exact ? l == label : l.contains(label) else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }
}
