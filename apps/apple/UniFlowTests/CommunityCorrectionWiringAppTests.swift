import PDFKit
import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Korrekturvorschlag, Teil 2 (03.11.2026): "Korrektur vorschlagen" in der Leiste der Notizen einer Person (Regeln,
/// Sperre, fehlende PDF), Posteingang des Erstellers mit Öffnen / Ignorieren, Korrekturen als eigene Eintraege im Reiter
/// "Diskussion" (Ansehen, eigene loeschen), Melden ueber CloudKit. Nur erfundene Daten, kein Netz.
@MainActor
final class CommunityCorrectionWiringAppTests: XCTestCase {

    /// Dienst mit festen Loesungen, Kommentaren und Korrekturen
    final class FakeCorrectionService: CommunityService, @unchecked Sendable {
        var list: [CommunitySolutionSummary] = []
        var correctionsEnabled = true
        /// Korrekturen je Loesung (wie vom Dienst: mit `isMine` / `isForMe`)
        var bySolution: [String: [CommunityCorrection]] = [:]
        /// Posteingang (an eigene Loesungen)
        var inbox: [CommunityCorrection] = []
        var ignored: Set<String> = []
        var seen: Set<String> = []
        var deleted: [String] = []
        var reported: [String] = []
        /// Abfragen des Posteingangs (Sparsamkeit des Abzeichens)
        var inboxQueries = 0
        var isConnected: Bool { true }
        var supportsDiscussion: Bool { true }
        var supportsCorrections: Bool { correctionsEnabled }
        func solutions(in space: CommunitySpace) async throws -> [CommunitySolutionSummary] { list }
        func communities() async throws -> [CommunitySpace] { [] }
        func comments(solutionID: String) async throws -> [CommunityComment] { [] }
        func corrections(solutionID: String) async throws -> [CommunityCorrection] { bySolution[solutionID] ?? [] }
        func correctionsForMyOwnSolutions() async throws -> [CommunityCorrection] {
            inboxQueries += 1
            return inbox.map { c in var c = c; c.status = ignored.contains(c.id) ? .ignored : seen.contains(c.id) ? .seen : .open; return c }
        }
        /// wie `CommunityCorrectionStatusStore`: ignoriert geht vor gesehen, offen loescht beides
        func setCorrectionStatus(_ status: CommunityCorrection.Status, id: String) {
            switch status {
            case .ignored: ignored.insert(id)
            case .seen: ignored.remove(id); seen.insert(id)
            case .open: ignored.remove(id); seen.remove(id)
            }
        }
        func deleteCorrection(id: String) async throws {
            deleted.append(id)
            for k in bySolution.keys { bySolution[k]?.removeAll { $0.id == id } }
        }
        func reportCorrection(id: String, reason: CommunityReportReason) async throws { reported.append(id) }
        func publish(_ package: SolutionPackage, options: CommunityPublishOptions) async throws -> CommunityPublication {
            throw CommunityServiceError.notConnected
        }
        func findMatching(fingerprint: String) async throws -> [CommunitySolutionSummary] { [] }
        func download(solutionID: String) async throws -> SolutionPackage { throw CommunityServiceError.notConnected }
        func withdraw(solutionID: String) async throws {}
        func report(solutionID: String, reason: CommunityReportReason, note: String?) async throws {}
    }

    private func solution(_ id: String, _ name: String, title: String = "Blatt 3", fingerprint: String, own: Bool = false) -> CommunitySolutionSummary {
        CommunitySolutionSummary(solutionID: id, fingerprint: fingerprint, displayName: name, createdAt: "2026-11-02T10:00:00Z",
                                 pageCount: 2, title: title, week: 3, ownerRecordName: "owner-\(name)", isOwn: own)
    }

    private func correction(_ id: String, target: String, by name: String, mine: Bool = false, forMe: Bool = false, note: String = "") -> CommunityCorrection {
        var c = CommunityCorrection(id: id, targetSolutionID: target, pseudonym: name, createdAt: "2026-11-03T10:00:00Z", note: note,
                                    pages: [.init(pdfIndex: 1, width: 595, height: 842, strokes: [CommunityCorrectionAppTests.strokeJSON],
                                                  notes: [.init(x: 0.3, y: 0.4, text: "hier fehlt ein Minus")])])
        c.author = "owner-\(name)"
        c.isMine = mine
        c.isForMe = forMe
        return c
    }

    // MARK: Regeln

    func testOfferRules() {
        let other = solution("1", "Lea", fingerprint: "fA"), own = solution("2", "Ich", fingerprint: "fA", own: true)
        XCTAssertEqual(CorrectionOffer.resolve(own, supportsCorrections: true, access: .allowed, localFile: .some("f")), .hidden, "nicht unter eigenen Notizen")
        XCTAssertEqual(CorrectionOffer.resolve(other, supportsCorrections: false, access: .allowed, localFile: .some("f")), .hidden)
        XCTAssertEqual(CorrectionOffer.resolve(other, supportsCorrections: true, access: .comingSoon, localFile: .some("f")), .hidden)
        XCTAssertEqual(CorrectionOffer.resolve(other, supportsCorrections: true, access: .locked(.plus), localFile: .some("f")), .locked,
                       "Free sieht den Knopf und die Sperrkarte")
        XCTAssertEqual(CorrectionOffer.resolve(other, supportsCorrections: true, access: .allowed, localFile: nil), .checking)
        XCTAssertEqual(CorrectionOffer.resolve(other, supportsCorrections: true, access: .allowed, localFile: .some(nil)), .needsPDF)
        XCTAssertEqual(CorrectionOffer.resolve(other, supportsCorrections: true, access: .allowed, localFile: .some("f")), .ready(fileID: "f"))
        XCTAssertEqual(CorrectionTexts.discussionTab(comments: 2, corrections: 1), "Diskussion (3)")
        XCTAssertEqual(CorrectionTexts.summary(correction("c", target: "1", by: "Ben")), "1 Markierung · 1 Randnotiz")
    }

    func testInboxItemsCarryTitleAndSkipIgnoredOwnAndOtherSpaces() {
        let a = correction("a", target: "S-OWN", by: "Ben", forMe: true)
        var ignored = correction("b", target: "s-own", by: "Mia", forMe: true)
        ignored.status = .ignored
        let mine = correction("c", target: "s-own", by: "Ich", mine: true, forMe: true)
        let elsewhere = correction("d", target: "s-other", by: "Ida", forMe: true)
        let known = [solution("s-own", "Ich", title: "Übungsblatt 3", fingerprint: "fO", own: true)]
        let items = CorrectionInbox.items([a, ignored, mine, elsewhere], known: known)
        XCTAssertEqual(items.map(\.id), ["a", "d"])
        XCTAssertEqual(items[0].message, "Deine Lösung „Übungsblatt 3“ hat einen Korrekturhinweis von Ben bekommen")
        XCTAssertEqual(items[0].fingerprint, "fO")
        XCTAssertEqual(items[1].message, "Deine Lösung hat einen Korrekturhinweis von Ida bekommen", "ohne Titel der Satz aus dem Kern")
        XCTAssertNil(items[1].fingerprint)
        XCTAssertEqual(CorrectionInbox.items([a, elsewhere], known: known, only: ["s-own"]).map(\.id), ["a"], "nur diese Community")
        XCTAssertEqual(CorrectionInbox.solutionIDs(fingerprint: "fO", known: known + [solution("x", "Lea", fingerprint: "fO")], shared: []),
                       ["s-own"], "nur eigene Loesungen")
        XCTAssertEqual(CorrectionInbox.solutionIDs(fingerprint: "", known: known, shared: []), [])
    }

    // MARK: Leiste der Notizen einer Person

    private func reader(_ service: FakeCorrectionService, people: [CommunitySolutionSummary], plan: UFPlan = .plus,
                        files: [String: String] = [:], left: (() -> Void)? = nil) throws -> UIView {
        try show(NavigationStack {
            CommunityPeopleReader(title: "Blatt 3", people: people, start: 0, service: service,
                                  entitlements: Entitlements(observe: false, plan: plan), localFile: { files[$0] }, leave: left,
                                  removed: { _, _ in })
        })
    }

    func testCorrectActionOnlyUnderForeignNotesAndOpensCorrectionMode() throws {
        let service = FakeCorrectionService()
        let people = [solution("sol-lea", "Lea", fingerprint: "fA"), solution("sol-ich", "Ich", fingerprint: "fA", own: true)]
        var left = false
        let view = try reader(service, people: people, files: ["fA": "file-a"], left: { left = true })
        XCTAssertTrue(pump { self.shows(view, CorrectionTexts.action) }, "\(texts(view))")
        XCTAssertTrue(tap(CorrectionTexts.action, in: view))
        XCTAssertTrue(pump { CorrectionLaunch.shared.pending["file-a"] != nil })
        XCTAssertEqual(CorrectionLaunch.shared.take(fileID: "file-a"), .correct(solutionID: "sol-lea"))
        XCTAssertTrue(left, "Leser bzw. Blatt wird vorher verlassen")

        XCTAssertTrue(tap("Nächste Person", in: view))
        XCTAssertTrue(pump { self.shows(view, "Person 2 von 2") })
        pump(timeout: 0.3)
        XCTAssertFalse(shows(view, CorrectionTexts.action), "nicht unter eigenen Notizen")
    }

    func testWithoutPDFTheActionExplainsAndWithoutServiceItIsHidden() throws {
        let service = FakeCorrectionService()
        let view = try reader(service, people: [solution("sol-lea", "Lea", fingerprint: "fA")])
        XCTAssertTrue(pump { self.shows(view, CorrectionTexts.action) }, "\(texts(view))")
        pump(timeout: 0.3)
        XCTAssertTrue(tap(CorrectionTexts.action, in: view))
        XCTAssertTrue(pump { self.shows(view, CorrectionTexts.needsPDF) }, "\(texts(view))")
        XCTAssertTrue(CorrectionLaunch.shared.pending.isEmpty)

        let off = FakeCorrectionService()
        off.correctionsEnabled = false
        let plain = try reader(off, people: [solution("sol-lea", "Lea", fingerprint: "fA")], files: ["fA": "file-a"])
        XCTAssertTrue(pump { self.shows(plain, "Gefällt mir · 0") }, "\(texts(plain))")
        XCTAssertFalse(shows(plain, CorrectionTexts.action), "Dienst ohne Korrekturen: kein Knopf")
    }

    func testFreeTierSeesTheLockedSheet() throws {
        let service = FakeCorrectionService()
        let view = try reader(service, people: [solution("sol-lea", "Lea", fingerprint: "fA")], plan: .free, files: ["fA": "file-a"])
        XCTAssertTrue(pump { self.shows(view, CorrectionTexts.action) }, "Free sieht den Knopf: \(texts(view))")
        XCTAssertTrue(tap(CorrectionTexts.action, in: view))
        XCTAssertTrue(pump { view.window?.rootViewController?.presentedViewController != nil }, "Sperrkarte als Blatt")
        XCTAssertTrue(CorrectionLaunch.shared.pending.isEmpty, "kein Korrektur-Modus ohne Plus")
        view.window?.rootViewController?.dismiss(animated: false)
    }

    // MARK: Reiter "Diskussion"

    func testDiscussionTabListsCorrectionsViewAndDeleteOwn() throws {
        let service = FakeCorrectionService()
        let mine = correction("c-mine", target: "sol-lea", by: "Ich", mine: true)
        let ben = correction("c-ben", target: "sol-lea", by: "Ben", note: "Vorzeichen in 2b")
        service.bySolution["sol-lea"] = [ben, mine]
        let view = try reader(service, people: [solution("sol-lea", "Lea", fingerprint: "fA")], files: ["fA": "file-a"])
        XCTAssertTrue(pump { self.shows(view, "Diskussion (2)") }, "Korrekturen zaehlen im Reiter: \(texts(view))")
        XCTAssertTrue(tap("Diskussion (2)", in: view))
        XCTAssertTrue(pump { self.shows(view, "Korrekturvorschlag von Ben") }, "\(texts(view))")
        XCTAssertTrue(shows(view, "1 Markierung · 1 Randnotiz"))
        XCTAssertTrue(shows(view, "Vorzeichen in 2b"))
        XCTAssertTrue(shows(view, "Korrekturvorschläge (2)"))
        XCTAssertTrue(shows(view, "Noch keine Kommentare."), "Kommentare bleiben getrennt")
        XCTAssertEqual(buttons("Löschen", in: view), 1, "nur die eigene Korrektur hat Löschen")
        XCTAssertEqual(buttons("Melden", in: view), 1, "fremde Korrekturen lassen sich melden")

        // Ansehen: Korrektur im eigenen Dokument ueber der Loesung
        XCTAssertTrue(tap("Ansehen", in: view))
        XCTAssertTrue(pump { CorrectionLaunch.shared.pending["file-a"] != nil })
        XCTAssertEqual(CorrectionLaunch.shared.take(fileID: "file-a"), .show(ben))

        XCTAssertTrue(tap("Melden", in: view))
        XCTAssertTrue(pump { service.reported == ["c-ben"] })
        XCTAssertTrue(pump { self.shows(view, CorrectionTexts.reported) }, "\(texts(view))")

        XCTAssertTrue(tap("Löschen", in: view))
        XCTAssertTrue(pump { self.shows(view, "Diskussion (1)") }, "\(texts(view))")
        XCTAssertEqual(service.deleted, ["c-mine"])
        XCTAssertTrue(shows(view, CorrectionTexts.deleted))
        XCTAssertEqual(buttons("Löschen", in: view), 0)
    }

    func testViewWithoutPDFExplains() throws {
        let service = FakeCorrectionService()
        service.bySolution["sol-lea"] = [correction("c-ben", target: "sol-lea", by: "Ben")]
        let view = try reader(service, people: [solution("sol-lea", "Lea", fingerprint: "fA")])
        XCTAssertTrue(pump { self.shows(view, "Diskussion (1)") }, "\(texts(view))")
        XCTAssertTrue(tap("Diskussion (1)", in: view))
        XCTAssertTrue(pump { self.shows(view, "Korrekturvorschlag von Ben") })
        XCTAssertTrue(tap("Ansehen", in: view))
        XCTAssertTrue(pump { self.shows(view, CorrectionTexts.needsPDFToView) }, "\(texts(view))")
        XCTAssertTrue(CorrectionLaunch.shared.pending.isEmpty)
    }

    // MARK: Posteingang des Erstellers

    func testInboxBannerOnSpacePageOpensAndIgnores() throws {
        let service = FakeCorrectionService()
        service.list = [solution("s-own", "Ich", title: "Übungsblatt 3", fingerprint: "fO", own: true),
                        solution("s-lea", "Lea", title: "Übungsblatt 3", fingerprint: "fO")]
        let ben = correction("c1", target: "s-own", by: "Ben", forMe: true, note: "2b prüfen")
        service.inbox = [ben, correction("c2", target: "s-anders", by: "Ida", forMe: true)]
        let space = CommunitySpace(key: "k", kind: .course, name: "Analysis", joined: true)
        let view = try show(CommunitySpacePage(key: "k", space: space, service: service, localFile: { $0 == "fO" ? "file-own" : nil },
                                               shared: { [] }))
        let message = "Deine Lösung „Übungsblatt 3“ hat einen Korrekturhinweis von Ben bekommen"
        XCTAssertTrue(pump { self.shows(view, message) }, "\(texts(view))")
        XCTAssertFalse(shows(view, "von Ida"), "Hinweise anderer Communities stehen nicht hier")
        XCTAssertTrue(shows(view, "1 Markierung · 1 Randnotiz"))

        XCTAssertTrue(tap("Öffnen", in: view))
        XCTAssertTrue(pump { CorrectionLaunch.shared.pending["file-own"] != nil })
        XCTAssertEqual(CorrectionLaunch.shared.take(fileID: "file-own"), .show(ben))
        // Öffnen: gesehen, der Hinweis wandert in die zugeklappte Gruppe "Gesehen (1)"
        XCTAssertEqual(service.seen, ["c1"])
        XCTAssertTrue(pump { self.shows(view, "Gesehen (1)") }, "\(texts(view))")
        XCTAssertFalse(shows(view, message), "zugeklappt: der Hinweis selbst ist nicht zu sehen")
        XCTAssertTrue(tap("Gesehen (1)", in: view))
        XCTAssertTrue(pump { self.shows(view, message) }, "aufgeklappt: \(texts(view))")
        XCTAssertTrue(shows(view, "\(message), gesehen"), "VoiceOver nennt den Zustand")

        XCTAssertTrue(tap("Ignorieren", in: view))
        XCTAssertTrue(pump { !self.shows(view, message) }, "\(texts(view))")
        XCTAssertFalse(shows(view, "Gesehen ("), "Gruppe leer: weg")
        XCTAssertEqual(service.ignored, ["c1"])
    }

    func testInboxSeenAndIgnoredTransitionsAndBadge() async throws {
        let service = FakeCorrectionService()
        service.inbox = [correction("c1", target: "s-own", by: "Ben", forMe: true), correction("c2", target: "s-own", by: "Mia", forMe: true),
                         correction("c3", target: "s-own", by: "Ida", forMe: true)]
        service.seen = ["c3"]
        let router = UFRouter()
        let badge = CommunityBadge.shared
        badge.serviceOverride = service
        badge.defaultsOverride = suite()
        defer { badge.serviceOverride = nil; badge.defaultsOverride = nil }
        badge.attach(router)
        let model = CorrectionInboxModel(service: service, localFile: { _ in "file-own" }, shared: { [] })
        let known = [solution("s-own", "Ich", fingerprint: "fO", own: true)]
        await model.load(known: known)
        XCTAssertEqual(model.openItems.map(\.id), ["c1", "c2"])
        XCTAssertEqual(model.seenItems.map(\.id), ["c3"], "schon gesehene stehen in der Gruppe")
        XCTAssertEqual(router.badge(for: "community"), 2, "die Liste des Posteingangs setzt das Abzeichen ohne zweite Abfrage")

        // Öffnen mit PDF: gesehen, aus dem Abzeichen, weiter im Posteingang
        await model.open(model.openItems[0], router: router)
        _ = CorrectionLaunch.shared.take(fileID: "file-own")
        XCTAssertEqual(service.seen, ["c1", "c3"])
        XCTAssertEqual(model.openItems.map(\.id), ["c2"])
        XCTAssertEqual(model.seenItems.map(\.id), ["c1", "c3"])
        XCTAssertEqual(router.badge(for: "community"), 1)

        // Ignorieren einer gesehenen: weg, Abzeichen unveraendert
        model.ignore(model.seenItems[0])
        XCTAssertEqual(service.ignored, ["c1"])
        XCTAssertEqual(model.items.map(\.id), ["c2", "c3"])
        XCTAssertEqual(router.badge(for: "community"), 1)
        // Ignorieren einer offenen: weg und aus dem Abzeichen
        model.ignore(model.openItems[0])
        XCTAssertEqual(router.badge(for: "community"), 0)
        XCTAssertEqual(router.badges, [:], "0 = kein Abzeichen")

        // neu geladen: ignoriert bleibt weg, gesehen bleibt in der Gruppe
        await model.load(known: known)
        XCTAssertEqual(model.openItems, [])
        XCTAssertEqual(model.seenItems.map(\.id), ["c3"])
        let reloaded = try await service.correctionsForMyOwnSolutions()
        XCTAssertEqual(CorrectionInbox.items(reloaded).map { $0.id + ":" + $0.correction.status.rawValue }, ["c3:seen"])
    }

    // MARK: Abzeichen am Menuepunkt "Community"

    func testBadgeCountsOpenUnseenOnlyPersistsAndIsCheap() async throws {
        let service = FakeCorrectionService()
        service.inbox = [correction("a", target: "s", by: "Ben", forMe: true), correction("b", target: "s", by: "Mia", forMe: true),
                         correction("c", target: "s", by: "Ida", forMe: true), correction("d", target: "s", by: "Ole", forMe: true)]
        service.seen = ["b"]
        service.ignored = ["c"]
        let defaults = suite()
        defaults.set(7, forKey: CommunityBadge.cacheKey)
        let badge = CommunityBadge.shared
        badge.serviceOverride = service
        badge.defaultsOverride = defaults
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        badge.now = { clock }
        defer { badge.serviceOverride = nil; badge.defaultsOverride = nil; badge.now = Date.init }

        // Start: zuerst die gespeicherte Zahl, dann die vom Dienst (offen und ungesehen: a, d). `attach` fragt selbst
        // einmal nach; ein zweites Auffrischen zur selben Zeit wartet auf diese Abfrage statt noch eine zu stellen
        let router = UFRouter()
        badge.attach(router)
        XCTAssertEqual(router.badge(for: "community"), 7, "gespeicherte Zahl sofort beim Start")
        await badge.refresh(force: true)
        XCTAssertEqual(router.badge(for: "community"), 2, "nach der Abfrage: \(router.badges)")
        XCTAssertEqual(service.inboxQueries, 1)
        XCTAssertEqual(defaults.integer(forKey: CommunityBadge.cacheKey), 2, "neue Zahl gespeichert")

        // sparsam: innerhalb einer Minute keine zweite Abfrage, danach eine
        await badge.refresh()
        XCTAssertEqual(service.inboxQueries, 1)
        clock = clock.addingTimeInterval(CommunityBadge.minInterval + 1)
        service.inbox.append(correction("e", target: "s", by: "Tom", forMe: true))
        await badge.refresh()
        XCTAssertEqual(service.inboxQueries, 2)
        XCTAssertEqual(router.badge(for: "community"), 3)

        // Gesehen und Ignoriert nehmen sofort aus der Zahl, Unbekanntes aendert nichts; ohne Dienst bleibt die Zahl
        badge.resolve("A")
        XCTAssertEqual(router.badge(for: "community"), 2)
        badge.resolve("b")
        XCTAssertEqual(router.badge(for: "community"), 2, "schon gesehen: nichts zu nehmen")
        service.correctionsEnabled = false
        await badge.refresh(force: true)
        XCTAssertEqual(router.badge(for: "community"), 0, "Dienst ohne Korrekturen: kein Abzeichen")
        XCTAssertEqual(service.inboxQueries, 2)

        // Menuepunkt: VoiceOver "Community, 2 neue Hinweise" und "99+"
        XCTAssertEqual(UFNavItem.accessibilityLabel(title: "Community", key: "community", badge: 2), "Community, 2 neue Hinweise")
        XCTAssertEqual(UFNavItem.accessibilityLabel(title: "Community", key: "community", badge: 1), "Community, 1 neuer Hinweis")
        XCTAssertEqual(UFNavItem.accessibilityLabel(title: "Community", key: "community", badge: 0), "Community")
        XCTAssertEqual(UFNavItem.accessibilityLabel(title: "Tests & Wiederholung", key: "exams", badge: 3), "Tests & Wiederholung, 3 neu")
        XCTAssertEqual(UFNavItem.badgeLabel(120), "99+")
        XCTAssertEqual(UFMobileNav.drawerBadge(["community": 2, "dashboard": 1, "exams": 3]), 5, "nicht in der unteren Leiste: am Menueknopf")
        router.setBadge(-3, for: "x")
        XCTAssertEqual(router.badges, [:])
    }

    func testSidebarShowsBadgeAndNamesItForVoiceOver() throws {
        let router = UFRouter()
        router.setBadge(2, for: "community")
        let shown = try show(UFSidebar(collapsed: false, allowCollapse: true).environmentObject(StudIPSync()), router: router)
        XCTAssertTrue(pump { self.shows(shown, "Community, 2 neue Hinweise") }, "\(texts(shown))")
        XCTAssertTrue(shows(shown, "Übersicht"))
        XCTAssertFalse(texts(shown).contains { $0.hasPrefix("Übersicht,") }, "nur der Punkt mit Abzeichen")
        router.setBadge(0, for: "community")
        XCTAssertTrue(pump { !self.shows(shown, "Community, 2") }, "\(texts(shown))")
        XCTAssertTrue(shows(shown, "Community"))
    }

    func testInboxOpenWithoutPDFExplains() async throws {
        let service = FakeCorrectionService()
        service.inbox = [correction("c1", target: "s-own", by: "Ben", forMe: true)]
        let model = CorrectionInboxModel(service: service, localFile: { _ in nil }, shared: { [] })
        await model.load()
        XCTAssertEqual(model.items.map(\.id), ["c1"])
        await model.open(model.items[0], router: UFRouter())
        XCTAssertEqual(model.notice, CorrectionTexts.needsPDFToView, "ohne Fingerabdruck und ohne Paket: Hinweis statt Absturz")
        XCTAssertTrue(CorrectionLaunch.shared.pending.isEmpty)
        model.ignore(model.items[0])
        XCTAssertEqual(model.items, [])
        await model.load()
        XCTAssertEqual(model.items, [], "ignoriert bleibt weg")
    }

    // MARK: Melden ueber CloudKit

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-correction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func suite() -> UserDefaults {
        let name = "uniflow.tests.correction-wiring.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func pdfData() -> Data {
        let raw = NSMutableData()
        let size = CGSize(width: 595, height: 842)
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
        "Blatt".draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        UIGraphicsEndPDFContext()
        return raw as Data
    }

    func testReportCorrectionOverCloudKitUsesReportRecordAndHidesAfterThree() async throws {
        typealias FakeCloud = CommunityCloudKitTests.FakeCommunityCloud
        let space = CommunitySpace.course(university: "luh", id: "kurs-1", title: "Lineare Algebra")
        let cloud = FakeCloud(assetDir: try tempDir())
        func member(_ user: String, _ name: String = "") -> CloudKitCommunityService {
            cloud.user = user
            return CloudKitCommunityService(cloud: cloud, university: .luh, membership: CommunityMembership(defaults: suite()),
                                            courseKeys: { [space.key] }, courses: { [space] }, pseudonym: { name })
        }
        let lea = member("_user-ada", "Lea")
        let pdf = pdfData()
        let doc = AnnotationDocument(root: try JSONValue.parse(#"""
        {"version":2,"pageOrder":[{"key":"p1","type":"pdf","index":1}],
         "pages":{"p1":{"objects":[{"id":"s1","type":"stroke","tool":"pen","color":"#000000","width":4,"points":[10,10,50,50]}]}}}
        """#))
        let src = SolutionSource(document: doc, originalPDF: pdf, pdf: PDFDocument(data: pdf)!,
                                 fingerprint: CryptoKitSolutionCipher().sha256Hex(pdf), images: [:], title: "Blatt")
        let options = CommunityPublishOptions(visibility: .module, courseKey: space.key, title: "Blatt", communityKey: space.key)
        let sid = try await SolutionSharing.publishToCommunity(src, keys: ["p1"], displayName: "Lea", options: options, space: space,
                                                               service: lea, library: SolutionLibrary(root: try tempDir())).solutionID
        let ben = member("_user-ben", "Ben")
        let sent = try await ben.sendCorrection(correction("x", target: sid, by: "").content)

        // eigene Korrektur meldet man nicht
        do { try await ben.reportCorrection(id: sent.id, reason: .other); XCTFail("eigene gemeldet") } catch {
            XCTAssertEqual(error as? CommunityServiceError, .service("Die eigene Korrektur nimmst du zurück statt sie zu melden."))
        }

        // Mia meldet: Datensatz Report wie bei Kommentaren, einmal je Nutzer
        let mia = member("_user-mia")
        try await mia.reportCorrection(id: sent.id, reason: .other)
        let report = try XCTUnwrap(cloud.all(CommunityRecordType.report).first)
        XCTAssertEqual(report["commentID"]?.string, sent.id)
        XCTAssertEqual(report["solutionID"]?.string, sid)
        XCTAssertEqual(report["note"]?.string, "correction")
        do { try await mia.reportCorrection(id: sent.id, reason: .other); XCTFail("doppelt gemeldet") } catch {
            XCTAssertEqual(error as? CommunityServiceError, .service("Du hast diese Korrektur schon gemeldet."))
        }
        let stillThere = try await mia.corrections(solutionID: sid)
        XCTAssertEqual(stillThere.map(\.id), [sent.id])

        // ab drei Meldungen verschwindet sie (Liste und Posteingang)
        _ = member("_user-ida")
        try await CloudKitCommunityService(cloud: cloud, university: .luh, membership: CommunityMembership(defaults: suite()),
                                           courseKeys: { [space.key] }, courses: { [space] }).reportCorrection(id: sent.id, reason: .other)
        cloud.user = "_user-ole"
        try await CloudKitCommunityService(cloud: cloud, university: .luh, membership: CommunityMembership(defaults: suite()),
                                           courseKeys: { [space.key] }, courses: { [space] }).reportCorrection(id: sent.id, reason: .other)
        cloud.user = "_user-mia"
        let hidden = try await mia.corrections(solutionID: sid)
        XCTAssertEqual(hidden, [])
        cloud.user = "_user-ada"
        let inbox = try await lea.correctionsForMyOwnSolutions()
        XCTAssertEqual(inbox, [])

        // ohne Dienst: nicht verbunden
        do { try await NotConnectedCommunityService().reportCorrection(id: "x", reason: .other); XCTFail() } catch {
            XCTAssertEqual(error as? CommunityServiceError, .notConnected)
        }
    }

    // MARK: Werkzeuge (wie CommunityChannelAppTests)

    override func setUp() async throws {
        try await super.setUp()
        CorrectionLaunch.shared.pending.keys.forEach { _ = CorrectionLaunch.shared.take(fileID: $0) }
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
    }

    override func tearDown() async throws {
        CorrectionLaunch.shared.pending.keys.forEach { _ = CorrectionLaunch.shared.take(fileID: $0) }
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

    private func show<V: View>(_ view: V, router: UFRouter? = nil) throws -> UIView {
        let router = router ?? UFRouter()
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: AuditRunde0910AppTests.FakeTransport())
        let suite = "uniflow-correction-wiring-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let overlay = UFOverlay()
        let root = view
            .modifier(UFModalHost(overlay: overlay))
            .environmentObject(Session(local: api, defaults: defaults))
            .environmentObject(AccountStore(secrets: ContainerTestBed.MemorySecrets(), defaults: defaults, checker: ContainerTestBed.Authorized(), observeRevocation: false))
            .environmentObject(router)
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

    private func buttons(_ label: String, in view: UIView) -> Int {
        Set(elements(in: view).filter { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel == label }
            .map { ObjectIdentifier($0) }).count
    }

    @discardableResult
    private func tap(_ label: String, in view: UIView, prefix: Bool = false) -> Bool {
        for e in elements(in: view) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, prefix ? l.hasPrefix(label) : l == label else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }
}
