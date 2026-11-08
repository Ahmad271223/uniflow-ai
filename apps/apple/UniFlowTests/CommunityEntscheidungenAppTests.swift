import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Entscheidungen des Inhabers vom 08.11.2026 zu den Audit-Befunden P42-05 und P43-06
/// (docs/audit/AUDIT-2026-11-08-PAKET-42-43.md, Abschnitt "Entscheidungen 08.11.").
///
/// - P42-05: Der Autor einer Loesung entfernt fremde Kommentare darunter. Ueber iCloud (CloudKit) legt er nur einen
///   Entfernungs-Datensatz an, der verschluesselte Text des Verfassers bleibt gespeichert: die Aktion heisst darum
///   "Ausblenden" (mit Rueckfrage, ehrlich formuliert). Eigene Kommentare: weiter "Löschen". Im Dienst-Weg wird
///   wirklich geloescht (app/community.py, Status `deleted`, Text leer): dort bleibt "Löschen".
/// - P43-06: Das Kontingent "Karteikarten-Stapel von StudiNow" zaehlt je Konto: mit StudiNow-Konto im Dienst, sonst
///   ueber das Apple-Konto (iCloud-Schluessel-Wert-Speicher) zusammen mit dem Geraet; Monat in Europe/Berlin.
@MainActor
final class CommunityEntscheidungenAppTests: XCTestCase {

    // MARK: - P43-06 Kontingent je Konto

    /// iCloud-Schluessel-Wert-Speicher im Speicher; mehrere Geraete teilen sich eine Instanz. `dropsWrites`: iCloud
    /// nicht erreichbar (nichts kommt an)
    final class MemoryAdoptCloud: UFAdoptCloudStore {
        var values: [String: Any] = [:]
        var dropsWrites = false
        func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
        func set(_ value: Any?, forKey key: String) { if !dropsWrites { values[key] = value } }
        func removeObject(forKey key: String) { if !dropsWrites { values[key] = nil } }
        var dictionaryRepresentation: [String: Any] { values }
        func synchronize() -> Bool { !dropsWrites }
    }

    /// StudiNow-Dienst: feste Antworten, gezaehlte Aufrufe
    final class FakeAdoptService: UFAdoptQuotaService, @unchecked Sendable {
        var status = StudoraAccount.AdoptQuota(ok: true, counted: false, used: 0, limit: 4)
        var answer: StudoraAccount.AdoptQuota? = StudoraAccount.AdoptQuota(ok: true, counted: true, used: 1, limit: 4)
        var counted: [String] = []
        var statusCalls = 0
        func adoptQuotaStatus() async throws -> StudoraAccount.AdoptQuota {
            statusCalls += 1
            return status
        }
        func countAdoptedStack(ref: String) async throws -> StudoraAccount.AdoptQuota {
            counted.append(ref)
            guard let answer else { throw URLError(.notConnectedToInternet) }
            return answer
        }
    }

    private func defaults() throws -> UserDefaults {
        let name = "uf-adopt-konto-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return d
    }

    private func at(_ berlin: String) -> () -> Date { { UniFlowClock.fixed(berlin: berlin)!.now } }

    private func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testP43_06MonthIsTheCalendarMonthInBerlin() throws {
        XCTAssertEqual(UFAdoptQuota.period(utc("2026-11-30T23:30:00Z")), "2026-12", "Berlin ist schon im Dezember")
        XCTAssertEqual(UFAdoptQuota.period(utc("2026-11-30T22:30:00Z")), "2026-11", "Berlin 23:30")
        XCTAssertEqual(UFAdoptQuota.period(utc("2026-06-30T22:30:00Z")), "2026-07", "Sommerzeit: +2 h")
        XCTAssertEqual(UFAdoptQuota.period(utc("2026-03-31T21:30:00Z")), "2026-03")
        XCTAssertEqual(UFAdoptQuota.period(utc("2026-12-31T23:30:00Z")), "2027-01", "Silvester")

        // Geraet in einer anderen Zeitzone (New York): der Monat bleibt der Berliner
        let before = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        defer { NSTimeZone.default = before }
        let d = try defaults(), cloud = MemoryAdoptCloud()
        UFAdoptQuota(defaults: d, now: at("2026-12-01T00:30:00"), cloud: cloud).record("a")    // New York: 30.11. 18:30
        let later = UFAdoptQuota(defaults: d, now: at("2026-12-20T12:00:00"), cloud: cloud)
        XCTAssertEqual(later.used, ["a"], "zaehlt im Dezember, nicht im November")
        XCTAssertEqual(UFAdoptQuota(defaults: d, now: at("2026-11-30T23:00:00"), cloud: cloud).used, [])
    }

    func testP43_06CountsAcrossDevicesOfTheSameAppleAccount() throws {
        let cloud = MemoryAdoptCloud()
        let a = UFAdoptQuota(defaults: try defaults(), now: at("2026-11-08T10:00:00"), cloud: cloud)
        let b = UFAdoptQuota(defaults: try defaults(), now: at("2026-11-08T11:00:00"), cloud: cloud)
        for id in ["a", "b", "c"] { a.record(id) }
        XCTAssertEqual(Set(b.used), ["a", "b", "c"], "das zweite iPad sieht die Uebernahmen des ersten")
        XCTAssertTrue(b.allows("d", plan: .plus))
        b.record("d")
        b.record("a")
        XCTAssertEqual(b.used.count, 4, "derselbe Stapel zaehlt einmal, auch ueber Geraete")
        XCTAssertFalse(a.allows("e", plan: .plus), "fuenfter Stapel im Monat: auf keinem Geraet")
        XCTAssertFalse(b.allows("e", plan: .plus))
        XCTAssertTrue(a.allows("d", plan: .plus), "schon gezaehlt")
        XCTAssertTrue(a.allows("e", plan: .proAI))
        XCTAssertEqual(a.error(plan: .plus).errorDescription,
                       "Karteikarten-Stapel von StudiNow: Kontingent für diesen Monat aufgebraucht (4 von 4).", "Text wie bisher")
        let december = UFAdoptQuota(defaults: a.defaults, now: at("2026-12-01T00:10:00"), cloud: cloud)
        XCTAssertTrue(december.allows("e", plan: .plus), "neuer Monat, neues Kontingent")
        december.record("e")
        XCTAssertTrue(cloud.values.keys.allSatisfy { !$0.contains("2026-11") }, "alte Monate raeumt das Geraet aus iCloud: \(cloud.values.keys)")
        XCTAssertTrue(cloud.values.keys.allSatisfy { $0.utf8.count <= 64 }, "Schluessel des Schluessel-Wert-Speichers hoechstens 64 Byte")
    }

    func testP43_06WithoutICloudTheDeviceStillCountsNeverMore() throws {
        // kein iCloud (abgemeldet, ohne Berechtigung): wie bisher je Geraet
        let alone = UFAdoptQuota(defaults: try defaults(), now: at("2026-11-08T10:00:00"), cloud: nil)
        for id in ["a", "b", "c", "d"] {
            XCTAssertTrue(alone.allows(id, plan: .plus))
            alone.record(id)
        }
        XCTAssertFalse(alone.allows("e", plan: .plus))
        // iCloud nicht erreichbar: Schreiben kommt nicht an, die lokale Sicherung zaehlt weiter
        let cloud = MemoryAdoptCloud()
        cloud.dropsWrites = true
        let offline = UFAdoptQuota(defaults: try defaults(), now: at("2026-11-08T10:00:00"), cloud: cloud)
        for id in ["a", "b", "c", "d"] { offline.record(id) }
        XCTAssertEqual(offline.used.count, 4)
        XCTAssertFalse(offline.allows("e", plan: .plus), "nie mehr als je Geraet bisher")
        // Zaehlung von vor der Umstellung (gleicher Schluessel je Monat in den UserDefaults) gilt weiter
        let d = try defaults()
        d.set(["x1", "x2", "x3", "x4"], forKey: "uf.quota.card_stacks_adopted.2026-11")
        XCTAssertFalse(UFAdoptQuota(defaults: d, now: at("2026-11-08T10:00:00"), cloud: MemoryAdoptCloud()).allows("e", plan: .plus))
    }

    func testP43_06WithStudiNowAccountTheServiceCounts() async throws {
        let cloud = MemoryAdoptCloud(), service = FakeAdoptService()
        var q = UFAdoptQuota(defaults: try defaults(), now: at("2026-11-08T10:00:00"), cloud: cloud)
        q.service = service
        // Dienst kennt den Tarif (Grenze 4) und hat noch Platz: zaehlt dort
        let first = await q.reserve("community:s1", plan: .plus)
        XCTAssertTrue(first)
        XCTAssertEqual(service.counted, ["community:s1"])
        // Dienst sagt "aufgebraucht" (andere Geraete des Kontos): abgewiesen, auch wenn dieses Geraet noch nichts hat
        service.answer = StudoraAccount.AdoptQuota(ok: false, counted: false, used: 4, limit: 4)
        let full = await q.reserve("community:s2", plan: .plus)
        XCTAssertFalse(full)
        // Dienst kennt den Kauf nicht (Grenze 0 bzw. anderer Tarif): Apple-Konto und Geraet entscheiden
        service.answer = StudoraAccount.AdoptQuota(ok: false, counted: false, used: 0, limit: 0)
        let unknownPlan = await q.reserve("community:s2", plan: .plus)
        XCTAssertTrue(unknownPlan)
        // Dienst nicht erreichbar: ebenso
        service.answer = nil
        let offline = await q.reserve("community:s3", plan: .plus)
        XCTAssertTrue(offline)
        // Apple-Konto/Geraet schon voll: nie mehr als dort, der Dienst wird gar nicht gefragt
        for id in ["x1", "x2", "x3", "x4"] { q.record(id) }
        service.answer = StudoraAccount.AdoptQuota(ok: true, counted: true, used: 1, limit: 4)
        let before = service.counted.count
        let local = await q.reserve("community:s4", plan: .plus)
        XCTAssertFalse(local)
        XCTAssertEqual(service.counted.count, before)
        // Pro AI: unbegrenzt, kein Aufruf
        let pro = await q.reserve("community:s5", plan: .proAI)
        XCTAssertTrue(pro)
        XCTAssertEqual(service.counted.count, before)
    }

    func testP43_06WeekStacksCheckTheServiceFirstAndCountAfterwards() async throws {
        let service = FakeAdoptService()
        var q = UFAdoptQuota(defaults: try defaults(), now: at("2026-11-08T10:00:00"), cloud: MemoryAdoptCloud())
        q.service = service
        service.status = StudoraAccount.AdoptQuota(ok: true, counted: false, used: 4, limit: 4)
        let full = await q.check("week:7:3:vorlesung", plan: .plus)
        XCTAssertFalse(full, "Stand des Kontos: 4 von 4")
        XCTAssertTrue(service.counted.isEmpty, "Vorabpruefung zaehlt nichts")
        service.status = StudoraAccount.AdoptQuota(ok: true, counted: false, used: 2, limit: 4)
        let room = await q.check("week:7:3:vorlesung", plan: .plus)
        XCTAssertTrue(room)
        await q.recordAdopted("week:7:3:vorlesung")
        XCTAssertEqual(service.counted, ["week:7:3:vorlesung"], "uebernommen: im Dienst gezaehlt")
        XCTAssertEqual(q.used, ["week:7:3:vorlesung"], "und auf Apple-Konto und Geraet")
        service.status = StudoraAccount.AdoptQuota(ok: true, counted: false, used: 4, limit: 4)
        let counted = await q.check("week:7:3:vorlesung", plan: .plus)
        XCTAssertTrue(counted, "schon gezaehlter Stapel bleibt erlaubt")
        // Dienst kennt den Tarif nicht: Apple-Konto und Geraet
        service.status = StudoraAccount.AdoptQuota(ok: true, counted: false, used: 0, limit: 0)
        let fallback = await q.check("week:7:4:uebung", plan: .plus)
        XCTAssertTrue(fallback)
    }

    // MARK: - P42-05 Ausblenden statt Loeschen

    func testP42_05ActionNamesSayWhatReallyHappens() {
        typealias R = CommunityTexts.CommentRemoval
        XCTAssertEqual(CommunityTexts.commentRemoval(isMine: true, ownSolution: false, accountService: false), R.delete)
        XCTAssertEqual(CommunityTexts.commentRemoval(isMine: true, ownSolution: true, accountService: false), R.delete, "eigener Kommentar")
        XCTAssertEqual(CommunityTexts.commentRemoval(isMine: false, ownSolution: true, accountService: false), R.hide, "fremder unter eigener Loesung, iCloud")
        XCTAssertEqual(CommunityTexts.commentRemoval(isMine: false, ownSolution: true, accountService: true), R.delete, "Dienst loescht wirklich")
        XCTAssertNil(CommunityTexts.commentRemoval(isMine: false, ownSolution: false, accountService: false))
        XCTAssertEqual(R.delete.title, "Löschen")
        XCTAssertEqual(R.hide.title, "Ausblenden")
        XCTAssertEqual(CommunityTexts.hideCommentTitle, "Kommentar ausblenden?")
        XCTAssertEqual(CommunityTexts.hideCommentMessage,
                       "Der Kommentar verschwindet unter deiner Lösung für alle, auch für die Person, die ihn geschrieben hat; sie kann ihn danach nicht mehr bearbeiten oder löschen. Gelöscht wird er nicht: Der verschlüsselte Text bleibt in iCloud gespeichert. Antworten darauf bleiben sichtbar.")
        XCTAssertEqual(CommunityTexts.hideCommentHint, "Blendet den Kommentar für alle aus. Gelöscht wird er nicht.")
        XCTAssertEqual(CommunityTexts.removedComment(accountService: false), "Kommentar entfernt", "iCloud: geloescht oder ausgeblendet")
        XCTAssertEqual(CommunityTexts.removedComment(accountService: true), "Kommentar gelöscht")
    }

    /// Dienst mit Kommentaren (wie CloudKit: kein Konto-Dienst)
    final class FakeDiscussion: CommunityService, @unchecked Sendable {
        var list: [CommunityComment] = []
        var deleted: [String] = []
        var isConnected: Bool { true }
        var supportsDiscussion: Bool { true }
        func comments(solutionID: String) async throws -> [CommunityComment] { list }
        func deleteComment(id: String) async throws {
            deleted.append(id)
            if let i = list.firstIndex(where: { $0.id == id }) { list[i].deleted = true; list[i].text = "" }
        }
        func publish(_ package: SolutionPackage, options: CommunityPublishOptions) async throws -> CommunityPublication {
            throw CommunityServiceError.notConnected
        }
        func findMatching(fingerprint: String) async throws -> [CommunitySolutionSummary] { [] }
        func download(solutionID: String) async throws -> SolutionPackage { throw CommunityServiceError.notConnected }
        func withdraw(solutionID: String) async throws {}
        func report(solutionID: String, reason: CommunityReportReason, note: String?) async throws {}
        func sendCorrection(_ correction: CommunityCorrection) async throws -> CommunityCorrection { correction }
        func corrections(solutionID: String) async throws -> [CommunityCorrection] { [] }
        func correctionsForMyOwnSolutions() async throws -> [CommunityCorrection] { [] }
        func deleteCorrection(id: String) async throws {}
        func setCorrectionStatus(_ status: CommunityCorrection.Status, id: String) {}
        func reportCorrection(id: String, reason: CommunityReportReason) async throws {}
    }

    func testP42_05ForeignCommentUnderOwnSolutionIsHiddenAfterAHonestQuestion() throws {
        let service = FakeDiscussion()
        service.list = [
            CommunityComment(id: "c-ben", pseudonym: "Ben", text: "Fremder Kommentar", createdAt: "2026-11-08T09:00:00Z"),
            CommunityComment(id: "c-ich", pseudonym: "Ich", text: "Eigener Kommentar", createdAt: "2026-11-08T09:10:00Z", isMine: true, byAuthor: true),
        ]
        let own = CommunitySolutionSummary(solutionID: "sol-ich", fingerprint: "fA", displayName: "Ich", createdAt: "2026-11-02T10:00:00Z",
                                           pageCount: 2, title: "Blatt 3", week: 3, ownerRecordName: "owner-ich", isOwn: true)
        let view = try show(NavigationStack {
            CommunityPeopleReader(title: "Blatt 3", people: [own], start: 0, service: service,
                                  entitlements: Entitlements(observe: false, plan: .plus), localFile: { _ in nil }, leave: nil,
                                  removed: { _, _ in })
        })
        XCTAssertTrue(pump { self.shows(view, "Diskussion (2)") }, "\(texts(view))")
        XCTAssertTrue(tap("Diskussion (2)", in: view))
        XCTAssertTrue(pump { self.shows(view, "Fremder Kommentar") }, "\(texts(view))")
        XCTAssertEqual(buttons("Ausblenden", in: view), 1, "fremder Kommentar unter der eigenen Loesung: \(texts(view))")
        XCTAssertEqual(buttons("Löschen", in: view), 1, "eigener Kommentar behaelt Löschen")

        XCTAssertTrue(tap("Ausblenden", in: view))
        let alert = try XCTUnwrap(waitForAlert(view), "Rueckfrage vor dem Ausblenden")
        XCTAssertEqual(alert.title, CommunityTexts.hideCommentTitle)
        XCTAssertEqual(alert.message, CommunityTexts.hideCommentMessage)
        XCTAssertEqual(Set(alert.actions.compactMap(\.title)), ["Ausblenden", "Abbrechen"])
        XCTAssertTrue(service.deleted.isEmpty, "erst nach der Bestaetigung")
        XCTAssertTrue(press("Ausblenden", in: alert))
        XCTAssertTrue(pump { service.deleted == ["c-ben"] }, "\(service.deleted)")
        XCTAssertTrue(pump { self.shows(view, "Kommentar entfernt") }, "\(texts(view))")
    }

    // MARK: - Werkzeuge (wie CommunityCorrectionWiringAppTests)

    private var planBefore: UFPlan = .free

    override func setUp() async throws {
        try await super.setUp()
        planBefore = Entitlements.shared.plan
        Entitlements.shared.setPlanForTesting(.plus)
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
    }

    override func tearDown() async throws {
        Self.accessibilityAutomation(false)
        Entitlements.shared.setPlanForTesting(planBefore)
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
        let suite = "uniflow-entscheidungen-\(UUID().uuidString)"
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
        addTeardownBlock { @MainActor in
            hosting.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
        }
        return hosting.view
    }

    @discardableResult
    private func pump(timeout: Double = 10, until done: () -> Bool = { false }) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return done()
    }

    private func waitForAlert(_ view: UIView) -> UIAlertController? {
        var found: UIAlertController?
        _ = pump {
            var vc = view.window?.rootViewController
            while let next = vc?.presentedViewController { vc = next }
            found = vc as? UIAlertController
            return found != nil
        }
        return found
    }

    /// Knopf der Rueckfrage ausloesen (Handler der UIAlertAction)
    private func press(_ title: String, in alert: UIAlertController) -> Bool {
        guard let action = alert.actions.first(where: { $0.title == title }) else { return false }
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        guard let block = action.value(forKey: "handler") else { return false }
        let handler = unsafeBitCast(block as AnyObject, to: Handler.self)
        alert.dismiss(animated: false) { handler(action) }
        return true
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

    private func buttons(_ label: String, in view: UIView) -> Int {
        Set(elements(in: view).filter { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel == label }
            .map { ObjectIdentifier($0) }).count
    }

    @discardableResult
    private func tap(_ label: String, in view: UIView) -> Bool {
        for e in elements(in: view) where e.accessibilityTraits.contains(.button) {
            guard e.accessibilityLabel == label else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }
}
