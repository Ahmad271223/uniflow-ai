import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Community auf dem iPhone (402 x 874, schmal): Diskussion (Filter unter dem Titel, Feld in voller Breite), Kanal mit
/// Wochen und Karten, Lösungen einer Person (Leiste nur mit Symbolen, in der Diskussion das Kommentarfeld unten fest),
/// Frage mit Antwortfeld unten, Korrekturhinweise. Gegenprobe iPad quer: Titel und Filter in einer Reihe. Dienst mit
/// festen erfundenen Daten (`CommunityChannelAppTests.FakeChannelService`), kein CloudKit.
@MainActor
final class IPhoneLearnCommunityTests: IPhoneLearnTestCase {

    /// Community ab Plus (Tarife nach Vorgabe des Inhabers 05.11.2026): Free sieht nur die Sperrkarte
    override func setUp() {
        super.setUp()
        let before = Entitlements.shared.plan
        Entitlements.shared.setPlanForTesting(.plus)
        addTeardownBlock { @MainActor in Entitlements.shared.setPlanForTesting(before) }
    }

    private func solution(_ id: String, _ name: String, title: String, fingerprint: String, week: Int, comments: Int = 0, own: Bool = false) -> CommunitySolutionSummary {
        var s = CommunitySolutionSummary(solutionID: id, fingerprint: fingerprint, displayName: name, createdAt: "2026-10-2\(week % 10)T10:00:00Z",
                                         pageCount: 2, title: title, week: week, ownerRecordName: "owner-\(name)", isOwn: own)
        s.commentCount = comments
        return s
    }

    private func post(_ id: String, _ name: String, _ text: String, replies: Int = 0, likes: Int = 0) -> CommunityPost {
        let q = CommunityComment(id: id, pseudonym: name, text: text, createdAt: "2026-11-01T10:00:00Z")
        let r = (0..<replies).map { CommunityComment(id: "\(id)-r\($0)", parentID: id, pseudonym: "Ben", text: "Antwort \($0 + 1): Schau dir Satz 2.4 an.", createdAt: "2026-11-01T11:00:00Z") }
        return CommunityPost(question: q, replies: r, likes: likes)
    }

    private func service() -> CommunityChannelAppTests.FakeChannelService {
        let s = CommunityChannelAppTests.FakeChannelService()
        s.spaceDiscussion = true
        s.posts = [post("q1", "Lea", "Wie geht Aufgabe 2b auf Blatt 3? Ich komme beim Induktionsschritt nicht weiter.", replies: 2, likes: 1),
                   post("q2", "Mia", "Wann ist die Klausur?")]
        s.list = [solution("1", "Lea", title: "Vorlesung 2", fingerprint: "fA", week: 2),
                  solution("2", "Ben", title: "Vorlesung 2", fingerprint: "fA", week: 2, comments: 2),
                  solution("3", "Mia", title: "Gruppenübung 2 mit einem langen Titel zum Umbrechen", fingerprint: "fB", week: 2),
                  solution("4", "Ich", title: "Meine Zusammenfassung", fingerprint: "", week: 0, own: true)]
        return s
    }

    private var space: CommunitySpace { CommunitySpace(key: "k", kind: .course, name: "Analysis I für Lehramt", joined: true) }

    private func api() -> APIClient { remote(Canned()) }

    /// Diskussion schmal: Filter unter dem Titel, Feld und Knopf in voller Breite, Fragen als Karten
    func testDiscussionFitsAndFiltersSitBelowTheTitle() throws {
        let env = try hostPhone(CommunitySpacePage(key: "k", space: space, service: service()), api: api())
        XCTAssertTrue(env.wait { self.shows(env, "Frage von Lea") }, dump(env))
        let title = frame(element(env, label: "Fragen und Antworten"))
        let chip = frame(button(env, "Unbeantwortet"))
        XCTAssertGreaterThan(chip.minY, title.maxY - 1, "Filter unter dem Titel: \(title) \(chip)")
        let field = frame(element(env, label: "Frage stellen …"))
        XCTAssertGreaterThan(field.width, Self.phone.width - 130, "Feld ohne Kreis davor: \(field)")
        assertFitsOnAllPhones(env, "community-diskussion")
        shoot(env, "iphone-community-diskussion")
    }

    /// Kanal (Reiter Dokumente): Wochen mit Karten, die seitlich scrollen; "Wer hat etwas geteilt" als Blatt passt
    func testChannelAndContributors() throws {
        let s = service()
        let env = try hostPhone(CommunitySpacePage(key: "k", space: space, service: s), api: api())
        XCTAssertTrue(env.wait { self.shows(env, "Dokumente (4)") }, dump(env))
        XCTAssertTrue(tap(env, "Dokumente (4)", prefix: true))
        XCTAssertTrue(env.wait { self.shows(env, "Woche 2") }, dump(env))
        assertFitsOnAllPhones(env, "community-kanal")
        shoot(env, "iphone-community-kanal")
        let people = s.list.filter { $0.title == "Vorlesung 2" }
        let built = CommunityChannel.build(people, skeleton: [])
        let first = try XCTUnwrap(built.first?.items.first)
        let sheet = CommunityContributorsSheet(item: first, weekLabel: "Woche 2", service: s, removed: { _, _ in }, close: {})
            .environment(\.ufLearnCompact, true)
        let contributors = try hostPhone(sheet, api: api())
        XCTAssertTrue(contributors.wait { self.shows(contributors, "2 Personen haben Notizen geteilt") }, dump(contributors))
        assertFitsOnAllPhones(contributors, "community-wer-teilt")
        shoot(contributors, "iphone-community-wer-teilt")
    }

    /// Notizen einer Person schmal: Leiste nur mit Symbolen (Beschriftung fuer VoiceOver), in der Diskussion das
    /// Kommentarfeld unten fest
    func testPersonReaderBarAndPinnedComposer() throws {
        let s = service()
        let people = s.list.filter { $0.title == "Vorlesung 2" }
        let reader = NavigationStack {
            CommunityPeopleReader(title: "Vorlesung 2", people: people, start: 0, service: s, localFile: { _ in nil }, removed: { _, _ in })
        }
        .environment(\.ufLearnCompact, true)
        let env = try hostPhone(reader, api: api())
        XCTAssertTrue(env.wait { self.element(env, label: "Lea, Person 1 von 2", prefix: true) != nil }, dump(env))
        XCTAssertNotNil(button(env, "Kommentar"), "Leiste: Kommentar als Symbol mit Beschriftung fuer VoiceOver: \(dump(env))")
        assertFitsOnAllPhones(env, "community-leser")
        shoot(env, "iphone-community-leser")
        // Reiter "Diskussion" direkt (die Leiste schaltet ihn um; hier die Ansicht der Person mit offenem Reiter)
        let pane = CommunityPersonPane(solution: people[0], service: s, tab: .constant(.discussion)).environment(\.ufLearnCompact, true)
        let discussion = try hostPhone(pane, api: api())
        XCTAssertTrue(discussion.wait { self.element(discussion, label: "Kommentar schreiben …") != nil }, dump(discussion))
        let field = frame(element(discussion, label: "Kommentar schreiben …"))
        XCTAssertGreaterThan(field.minY, Self.phone.height * 0.6, "Kommentarfeld unten fest: \(field)")
        assertFits(discussion, "community-leser-diskussion")
        shoot(discussion, "iphone-community-leser-diskussion")
    }

    /// Frage mit Antworten: Antwortfeld unten fest ueber der Tastatur
    func testThreadComposerIsPinned() throws {
        let s = service()
        let view = CommunityThreadSheet(space: space, service: s, post: s.posts[0]) {}.environment(\.ufLearnCompact, true)
        let env = try hostPhone(view, api: api())
        XCTAssertTrue(env.wait { self.shows(env, "Antwort 2: Schau dir Satz 2.4 an.") }, dump(env))
        let field = frame(element(env, label: "Antworten …"))
        XCTAssertGreaterThan(field.minY, Self.phone.height * 0.7, "Antwortfeld unten: \(field)")
        assertFits(env, "community-frage")
        shoot(env, "iphone-community-frage")
    }

    /// Korrekturhinweise: Hinweis im Posteingang (offen und gesehen) und Eintrag unter der Diskussion passen schmal
    func testCorrectionBannerAndEntryFit() throws {
        func correction(_ status: CommunityCorrection.Status) -> CommunityCorrection {
            var c = CommunityCorrection(targetSolutionID: "s-1", pseudonym: "Lea", note: "Vorzeichen in 2b prüfen, dort fehlt ein Minus vor dem Bruch",
                                        pages: [.init(pdfIndex: 1, width: 595, height: 842, strokes: [], notes: [.init(x: 0.3, y: 0.4, text: "hier")])])
            c.status = status
            return c
        }
        let open = CorrectionInboxItem(correction: correction(.open), title: "Übungsblatt 3 – Lösung mit langem Titel", fingerprint: nil)
        let seen = CorrectionInboxItem(correction: correction(.seen), title: "Vorlesung 2", fingerprint: nil)
        let view = ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CorrectionInboxBanner(item: open, open: {}, ignore: {})
                CorrectionInboxBanner(item: seen, open: {}, ignore: {})
                CorrectionEntryRow(correction: correction(.open), view: {}, delete: {}, report: {})
            }
            .padding(16)
        }
        .background(UF.bg)
        let env = try hostPhone(view, api: api())
        XCTAssertTrue(env.wait { self.button(env, "Ignorieren") != nil }, dump(env))
        assertFitsOnAllPhones(env, "community-korrektur")
        shoot(env, "iphone-community-korrektur")
    }

    /// iPad quer unveraendert: Titel und Filter in einer Reihe, Feld mit Kreis daneben
    func testPadKeepsDiscussionHeaderInOneRow() throws {
        let env = try hostPad(CommunitySpacePage(key: "k", space: space, service: service()), api: api())
        XCTAssertTrue(env.wait { self.shows(env, "Frage von Lea") }, dump(env))
        let title = frame(element(env, label: "Fragen und Antworten"))
        let chip = frame(button(env, "Unbeantwortet"))
        XCTAssertLessThan(abs(chip.midY - title.midY), 20, "eine Reihe: \(title) \(chip)")
    }
}
