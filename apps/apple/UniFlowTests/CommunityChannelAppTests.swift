import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Kanal einer Community nach Lehrwoche (Wunsch des Inhabers 03.11.2026): Einordnung der Blaetter, Buendeln je Blatt,
/// Wochen und Karten in der Ansicht, Personen der Reihe nach mit Pfeilen. Nur erfundene Daten, kein Netz.
@MainActor
final class CommunityChannelAppTests: XCTestCase {

    /// Dienst mit festen Loesungen; Kommentare und Likes moeglich, Pakete gibt es nicht (Leser zeigt den Fehler)
    final class FakeChannelService: CommunityService, @unchecked Sendable {
        var list: [CommunitySolutionSummary] = []
        var isConnected: Bool { true }
        var supportsDiscussion: Bool { true }
        func solutions(in space: CommunitySpace) async throws -> [CommunitySolutionSummary] { list }
        func communities() async throws -> [CommunitySpace] { [] }
        func comments(solutionID: String) async throws -> [CommunityComment] { [] }
        func publish(_ package: SolutionPackage, options: CommunityPublishOptions) async throws -> CommunityPublication {
            throw CommunityServiceError.notConnected
        }
        func findMatching(fingerprint: String) async throws -> [CommunitySolutionSummary] { [] }
        func download(solutionID: String) async throws -> SolutionPackage { throw CommunityServiceError.notConnected }
        func withdraw(solutionID: String) async throws {}
        func report(solutionID: String, reason: CommunityReportReason, note: String?) async throws {}
    }

    private func solution(_ id: String, _ name: String, title: String, fingerprint: String = "", week: Int, likes: Int = 0,
                          comments: Int = 0, own: Bool = false) -> CommunitySolutionSummary {
        var s = CommunitySolutionSummary(solutionID: id, fingerprint: fingerprint, displayName: name, createdAt: "2026-10-2\(week % 10)T10:00:00Z",
                                         pageCount: 2, title: title, week: week, ownerRecordName: "owner-\(name)", isOwn: own)
        s.likes = likes
        s.commentCount = comments
        return s
    }

    // MARK: Einordnung

    func testClassifyUsesOwnFileThenTitle() {
        typealias K = CommunityChannelKind
        XCTAssertEqual(K.classify(subLabel: "Gruppenübung", docType: "uebung", title: "Blatt 3"), .gruppenuebung)
        XCTAssertEqual(K.classify(subLabel: "Hörsaalübung", docType: "uebung", title: "x"), .hoersaaluebung)
        XCTAssertEqual(K.classify(subLabel: "Tutorium", docType: "uebung", title: "x"), .tutorium)
        XCTAssertEqual(K.classify(subLabel: "Altklausur", docType: "klausur", title: "x"), .klausur)
        XCTAssertEqual(K.classify(subLabel: "Klausur-Lösung", docType: "loesung", title: "x"), .klausur)
        XCTAssertEqual(K.classify(subLabel: "Vorlesung", docType: "vorlesung", title: "Kapitel 2"), .vorlesung)
        XCTAssertEqual(K.classify(subLabel: "Skript", docType: "skript", title: "x"), .vorlesung)
        XCTAssertEqual(K.classify(subLabel: nil, docType: "uebung", title: "Notizen"), .uebung)
        // Datei sagt nur "Übung", der Titel ist genauer
        XCTAssertEqual(K.classify(subLabel: "Übung", docType: "uebung", title: "GÜ3 Aufgaben"), .gruppenuebung)
        XCTAssertEqual(K.classify(subLabel: "Übung", docType: "uebung", title: "Tutorium 4"), .tutorium)
        // ohne eigene Datei: nur der Titel
        XCTAssertEqual(K.classify(subLabel: nil, docType: nil, title: "Vorlesung 05 – Graphen"), .vorlesung)
        XCTAssertEqual(K.classify(subLabel: nil, docType: nil, title: "VL03 Folien"), .vorlesung)
        XCTAssertEqual(K.classify(subLabel: nil, docType: nil, title: "Übungsblatt 2"), .uebung)
        XCTAssertEqual(K.classify(subLabel: nil, docType: nil, title: "Lösung Blatt 4"), .uebung)
        XCTAssertEqual(K.classify(subLabel: nil, docType: nil, title: "Hörsaalübung 6"), .hoersaaluebung)
        XCTAssertEqual(K.classify(subLabel: nil, docType: nil, title: "Probeklausur WS24"), .klausur)
        XCTAssertEqual(K.classify(subLabel: nil, docType: nil, title: "Meine Zusammenfassung"), .notizen)
        XCTAssertEqual(K.classify(subLabel: "Sonstiges", docType: "sonstiges", title: ""), .notizen)
    }

    func testBuildBundlesSheetsAndOrdersWeeks() {
        let list = [
            solution("1", "Lea", title: "Übungsblatt 2", fingerprint: "fA", week: 2, likes: 1),
            solution("2", "Ben", title: "Übungsblatt 2", fingerprint: "fA", week: 2, likes: 5),
            solution("3", "Mia", title: "Übungsblatt 2", fingerprint: "fB", week: 2),                // neue Fassung, gleicher Titel
            solution("4", "Ben", title: "Vorlesung 2", fingerprint: "fC", week: 2, comments: 3),
            solution("5", "Ich", title: "Meine Zusammenfassung", week: 0, own: true),
            solution("6", "Lea", title: "Vorlesung 1", fingerprint: "fD", week: 1),
        ]
        let weeks = CommunityChannel.build(list)
        XCTAssertEqual(weeks.map(\.week), [1, 2, 0], "Wochen aufsteigend, ohne Lehrwoche zuletzt")
        let w2 = weeks[1].items
        XCTAssertEqual(w2.map(\.kind), [.vorlesung, .uebung], "Vorlesung vor Übung")
        XCTAssertEqual(w2[1].people.map(\.displayName), ["Ben", "Lea", "Mia"], "ein Blatt, meistgelikt zuerst")
        XCTAssertEqual(w2[0].detail(discussion: true), "1 Person · 3 Kommentare")
        XCTAssertEqual(w2[1].detail(discussion: false), "3 Personen")
        XCTAssertEqual(weeks[2].items.first?.kind, .notizen)
        // eigene Datei per Fingerabdruck: Einordnung kommt aus ihr
        let withFile = CommunityChannel.build([solution("7", "Lea", title: "Blatt 3", fingerprint: "fE", week: 3)]) { _ in
            CommunityChannelFile(id: "file-1", title: "Blatt 3", subLabel: "Gruppenübung", docType: "uebung")
        }
        XCTAssertEqual(withFile.first?.items.first?.kind, .gruppenuebung)
        XCTAssertEqual(withFile.first?.items.first?.file?.id, "file-1")
        XCTAssertEqual(CommunityChannel.weekLabel(0, weeks: []), "Ohne Lehrwoche")
        XCTAssertEqual(CommunityChannel.weekLabel(4, weeks: [["week": 4, "label": "Woche 4 · 10.11."]]), "Woche 4 · 10.11.")
        XCTAssertEqual(CommunityChannel.weekLabel(5, weeks: []), "Woche 5")
    }

    /// Blaetter des eigenen Moduls stehen auch ohne Geteiltes in ihrer Woche; Geteiltes zum selben Blatt doppelt nicht
    func testModuleWeeksShowSheetsWithoutSharedNotes() {
        let weeks: [JSONValue] = [
            ["week": 1, "label": "Woche 1", "vorlesungen": [["id": "v1", "title": "Vorlesung 1", "name": "VL1.pdf", "sub_label": "Vorlesung"]],
             "uebungen": [["id": "u1", "title": "Übungsblatt 1", "name": "U1.pdf", "sub_label": "Übung"]],
             "loesungen": [["id": "l1", "title": "Lösung 1", "name": "L1.pdf"]]],
            ["week": 2, "label": "Woche 2", "vorlesungen": [["id": "v2", "title": "Vorlesung 2", "name": "VL2.pdf", "sub_label": "Vorlesung"]]],
        ]
        let skeleton = CommunityChannel.skeleton(weeks: weeks)
        XCTAssertEqual(skeleton.map(\.file.id), ["v1", "u1", "v2"], "ohne fertige Lösungen")
        let built = CommunityChannel.build([solution("1", "Lea", title: "Vorlesung 2", fingerprint: "fX", week: 2)], skeleton: skeleton)
        XCTAssertEqual(built.map(\.week), [1, 2])
        XCTAssertEqual(built[0].items.map(\.title), ["Vorlesung 1", "Übungsblatt 1"])
        XCTAssertEqual(built[0].items.first?.detail(discussion: true), "Noch niemand geteilt")
        XCTAssertEqual(built[1].items.count, 1, "geteilte Vorlesung 2 nicht doppelt")
        XCTAssertEqual(built[1].items.first?.people.count, 1)
    }

    // MARK: Ansicht

    func testChannelShowsWeeksAndCategoryCards() throws {
        let service = FakeChannelService()
        service.list = [
            solution("1", "Lea", title: "Vorlesung 2", fingerprint: "fA", week: 2),
            solution("2", "Ben", title: "Vorlesung 2", fingerprint: "fA", week: 2, comments: 2),
            solution("3", "Mia", title: "Gruppenübung 2", fingerprint: "fB", week: 2),
            solution("4", "Ben", title: "Tutorium 1", fingerprint: "fC", week: 1),
            solution("5", "Ich", title: "Meine Zusammenfassung", week: 0, own: true),
        ]
        let space = CommunitySpace(key: "k", kind: .course, name: "Analysis", joined: true)
        let view = try show(CommunitySpaceSheet(space: space, service: service) {})
        XCTAssertTrue(pump { self.shows(view, "Woche 2") }, "Wochen erscheinen: \(texts(view))")
        XCTAssertTrue(shows(view, "Woche 1"))
        XCTAssertTrue(shows(view, "Ohne Lehrwoche"))
        XCTAssertTrue(shows(view, "Vorlesung: Vorlesung 2, 2 Personen · 2 Kommentare"))
        XCTAssertTrue(shows(view, "Gruppenübung: Gruppenübung 2, 1 Person"))
        XCTAssertTrue(shows(view, "Tutorium: Tutorium 1"))
        XCTAssertTrue(shows(view, "Eigene Notizen: Meine Zusammenfassung"))
    }

    func testContributorsListOpensReaderAndArrowsStepThroughPeople() throws {
        let service = FakeChannelService()
        let item = CommunityChannel.build([
            solution("1", "Lea", title: "Blatt 1", fingerprint: "f", week: 1, likes: 3),
            solution("2", "Ben", title: "Blatt 1", fingerprint: "f", week: 1, likes: 2),
            solution("3", "Mia", title: "Blatt 1", fingerprint: "f", week: 1, likes: 1),
        ])[0].items[0]
        let view = try show(CommunityContributorsSheet(item: item, weekLabel: "Woche 1", service: service, removed: { _, _ in }, close: {}))
        XCTAssertTrue(pump { self.shows(view, "3 Personen haben Notizen geteilt") }, "\(texts(view))")
        XCTAssertTrue(shows(view, "Notizen von Lea"))
        XCTAssertTrue(shows(view, "Notizen von Mia"))
        XCTAssertTrue(tap("Notizen von Ben", in: view, prefix: true))
        XCTAssertTrue(pump { self.shows(view, "Person 2 von 3") }, "Leser beginnt bei der gewaehlten Person: \(texts(view))")
        XCTAssertTrue(shows(view, "Ben"))
        XCTAssertTrue(shows(view, "Kommentare"), "Kommentare stehen unter den Notizen")

        XCTAssertTrue(tap("Nächste Person", in: view))
        XCTAssertTrue(pump { self.shows(view, "Person 3 von 3") }, "\(texts(view))")
        XCTAssertTrue(shows(view, "Mia"))
        tap("Nächste Person", in: view)                                                          // am Ende: bleibt
        pump(timeout: 0.3)
        XCTAssertTrue(shows(view, "Person 3 von 3"))
        XCTAssertTrue(tap("Vorherige Person", in: view))
        XCTAssertTrue(pump { self.shows(view, "Person 2 von 3") }, "\(texts(view))")
        XCTAssertTrue(tap("Vorherige Person", in: view))
        XCTAssertTrue(pump { self.shows(view, "Person 1 von 3") }, "\(texts(view))")
        XCTAssertTrue(shows(view, "Lea"))
    }

    func testReaderStepStaysInRange() throws {
        let service = FakeChannelService()
        let people = [solution("1", "Lea", title: "B", week: 1), solution("2", "Ben", title: "B", week: 1)]
        let view = try show(NavigationStack {
            CommunityPeopleReader(title: "B", people: people, start: 5, service: service, removed: { _, _ in })
        })
        XCTAssertTrue(pump { self.shows(view, "Person 2 von 2") }, "Start ausserhalb wird begrenzt: \(texts(view))")
        XCTAssertTrue(tap("Vorherige Person", in: view))
        XCTAssertTrue(pump { self.shows(view, "Person 1 von 2") })
    }

    // MARK: Werkzeuge (wie AuditRunde0910AppTests)

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
    }

    override func tearDown() async throws {
        Self.accessibilityAutomation(false)
        try await super.tearDown()
    }

    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private func show<V: View>(_ view: V) throws -> UIView {
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: AuditRunde0910AppTests.FakeTransport())
        let suite = "uniflow-channel-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let overlay = UFOverlay()
        let root = view
            .modifier(UFModalHost(overlay: overlay))
            .environmentObject(Session(local: api, defaults: defaults))
            .environmentObject(AccountStore(secrets: ContainerTestBed.MemorySecrets(), defaults: defaults, checker: ContainerTestBed.Authorized(), observeRevocation: false))
            .environmentObject(UFRouter())
            .environmentObject(ShellState())
            .environmentObject(overlay)
            .environmentObject(UFToastCenter())
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

    @discardableResult
    private func tap(_ label: String, in view: UIView, prefix: Bool = false) -> Bool {
        for e in elements(in: view) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, prefix ? l.hasPrefix(label) : l == label else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }
}
