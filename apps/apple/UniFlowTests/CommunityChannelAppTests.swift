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
        /// Fragen je Community (Reiter "Diskussion")
        var spaceDiscussion = false
        var posts: [CommunityPost] = []
        var joined: [String] = []
        var isConnected: Bool { true }
        var supportsDiscussion: Bool { true }
        var supportsSpaceDiscussion: Bool { spaceDiscussion }
        func solutions(in space: CommunitySpace) async throws -> [CommunitySolutionSummary] { list }
        func communities() async throws -> [CommunitySpace] { [] }
        func join(_ space: CommunitySpace) async throws { joined.append(space.key) }
        func posts(in space: CommunitySpace) async throws -> [CommunityPost] { posts }
        /// Schein-Cloud, die absichtlich so lange braucht (Sekunden) bzw. so scheitert (Beitrag erscheint trotzdem sofort)
        var postDelay: TimeInterval = 0
        var postFailure: CommunityServiceError?
        var sent: [String] = []
        func addPost(in space: CommunitySpace, text: String, parentID: String?) async throws -> CommunityComment {
            if postDelay > 0 { try await Task.sleep(nanoseconds: UInt64(postDelay * 1_000_000_000)) }
            if let postFailure { throw postFailure }
            // Datum in der Vergangenheit: der Datensatz des Dienstes heisst "vor 6 Tagen", der Platzhalter "gerade eben"
            let c = CommunityComment(id: "srv-\(sent.count + 1)", parentID: parentID, pseudonym: "Anonym", text: text,
                                     createdAt: "2026-11-02T10:00:00Z", isMine: true)
            sent.append(text)
            if let parentID, let i = posts.firstIndex(where: { $0.id == parentID }) { posts[i].replies.append(c) }
            else { posts.insert(CommunityPost(question: c), at: 0) }
            return c
        }
        func setPostLiked(in space: CommunitySpace, postID: String, _ liked: Bool) async throws -> Int {
            guard let i = posts.firstIndex(where: { $0.id == postID }) else { throw CommunityServiceError.notFound }
            posts[i].likes += liked ? 1 : -1
            posts[i].likedByMe = liked
            return posts[i].likes
        }
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
        let view = try show(CommunitySpacePage(key: "k", space: space, service: service))
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
        XCTAssertTrue(shows(view, "Diskussion (0)"), "Kommentare im eigenen Reiter neben dem Dokument")
        XCTAssertTrue(shows(view, "Dokument"))

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

    // MARK: Seite einer Community (03.11.2026)

    private func post(_ id: String, _ name: String, _ text: String, at: String, replies: Int = 0, likes: Int = 0) -> CommunityPost {
        let q = CommunityComment(id: id, pseudonym: name, text: text, createdAt: at)
        let r = (0..<replies).map { CommunityComment(id: "\(id)-r\($0)", parentID: id, pseudonym: "Ben", text: "Antwort \($0)", createdAt: at) }
        return CommunityPost(question: q, replies: r, likes: likes)
    }

    func testSpaceTextsAreCalmAndHonest() {
        var space = CommunitySpace(key: "k", kind: .course, name: "Analysis")
        XCTAssertEqual(CommunitySpaceTexts.subtitle(space, university: "Leibniz Universität Hannover"), "Leibniz Universität Hannover",
                       "ohne bekannte Mitgliederzahl keine Zahl")
        space.members = 24
        XCTAssertEqual(CommunitySpaceTexts.subtitle(space, university: "Leibniz Universität Hannover"), "Leibniz Universität Hannover · 24 Mitglieder")
        XCTAssertEqual(CommunitySpaceTexts.subtitle(CommunitySpace(key: "g", kind: .group, name: "Lerngruppe A"), university: "x"), "Lerngruppe")
        let now = ISO8601DateFormatter().date(from: "2026-11-03T15:00:00Z")!
        XCTAssertEqual(CommunitySpaceTexts.relative("2026-11-03T14:59:30Z", now: now), "gerade eben")
        XCTAssertEqual(CommunitySpaceTexts.relative("2026-11-03T12:00:00Z", now: now), "vor 3 Stunden")
        XCTAssertEqual(CommunitySpaceTexts.relative("2026-10-01T12:00:00Z", now: now), ForeignSolutionLayer.date("2026-10-01T12:00:00Z"))
        let p = post("q", "Lea", "Wie geht 2b?", at: "2026-11-03T12:00:00Z", replies: 1, likes: 2)
        XCTAssertEqual(CommunitySpaceTexts.postLabel(p, now: now), "Frage von Lea, vor 3 Stunden: Wie geht 2b?, Beantwortet, 1 Antwort, 2 Likes")
    }

    func testSpacePageHeaderTabsAndJoinButton() throws {
        let service = FakeChannelService()
        service.spaceDiscussion = true
        let space = CommunitySpace(key: "k", kind: .course, name: "Analysis")
        let view = try show(CommunitySpacePage(key: "k", space: space, service: service))
        XCTAssertTrue(pump { self.shows(view, "Beitreten") }, "\(texts(view))")
        XCTAssertTrue(shows(view, "Analysis"))
        XCTAssertTrue(shows(view, "Diskussion"))
        XCTAssertTrue(shows(view, "Dokumente (0)"))
        XCTAssertTrue(shows(view, CommunitySpaceTexts.joinHint))
        XCTAssertFalse(shows(view, "Frage stellen"), "vor dem Beitritt keine Diskussion")

        service.list = [solution("1", "Lea", title: "Vorlesung 2", fingerprint: "fA", week: 2)]
        XCTAssertTrue(tap("Beitreten", in: view))
        XCTAssertTrue(pump { !self.shows(view, "Beitreten") && self.shows(view, "Dokumente (1)") }, "\(texts(view))")
        XCTAssertEqual(service.joined, ["k"])
        XCTAssertTrue(shows(view, "Frage stellen"), "nach dem Beitritt: Diskussion mit Eingabe")
        XCTAssertTrue(shows(view, "Neueste geteilte Notizen"))
    }

    func testDiscussionTabShowsQuestionsAnsweredBadgeAndFilter() throws {
        let service = FakeChannelService()
        service.spaceDiscussion = true
        service.posts = [post("q1", "Lea", "Wie geht 2b?", at: "2026-11-01T10:00:00Z", replies: 2, likes: 1),
                         post("q2", "Mia", "Wann ist die Klausur?", at: "2026-11-02T10:00:00Z")]
        let space = CommunitySpace(key: "k", kind: .course, name: "Analysis", joined: true)
        let view = try show(CommunitySpacePage(key: "k", space: space, service: service))
        XCTAssertTrue(pump { self.shows(view, "Frage von Lea") }, "\(texts(view))")
        XCTAssertTrue(shows(view, "Wie geht 2b?, Beantwortet, 2 Antworten, 1 Like"))
        XCTAssertTrue(shows(view, "Wann ist die Klausur?, 0 Antworten"))
        XCTAssertFalse(texts(view).contains { $0.contains("Wann ist die Klausur?, Beantwortet") })
        XCTAssertTrue(shows(view, "Neueste"))

        XCTAssertTrue(tap("Unbeantwortet", in: view))
        XCTAssertTrue(pump { !self.shows(view, "Frage von Lea") }, "\(texts(view))")
        XCTAssertTrue(shows(view, "Frage von Mia"))
        XCTAssertTrue(tap("Neueste", in: view))
        XCTAssertTrue(pump { self.shows(view, "Frage von Lea") })

        // Gefaellt mir auf einer fremden Frage
        XCTAssertTrue(tap("Gefällt mir, 1 Like", in: view))
        XCTAssertTrue(pump { self.shows(view, "Gefällt dir, 2 Likes") }, "\(texts(view))")
    }

    func testWithoutSpaceDiscussionTheTabSaysSoAndDocumentsComeFirst() throws {
        let service = FakeChannelService()
        service.list = [solution("1", "Lea", title: "Vorlesung 2", fingerprint: "fA", week: 2)]
        let space = CommunitySpace(key: "k", kind: .course, name: "Analysis", joined: true)
        let view = try show(CommunitySpacePage(key: "k", space: space, service: service))
        XCTAssertTrue(pump { self.shows(view, "Woche 2") }, "Dokumente zuerst: \(texts(view))")
        XCTAssertTrue(tap("Diskussion", in: view))
        XCTAssertTrue(pump { self.shows(view, CommunitySpaceTexts.discussionUnavailable) }, "\(texts(view))")
    }

    func testDocumentsListSortsByRelevanceOrNewest() throws {
        let list = [
            solution("1", "Lea", title: "Vorlesung 1", fingerprint: "fA", week: 1, likes: 1),                        // 21.10.
            solution("2", "Ben", title: "Übungsblatt 3", fingerprint: "fB", week: 3, likes: 4, comments: 2),         // 23.10.
            solution("3", "Mia", title: "Tutorium 2", fingerprint: "fC", week: 2),                                   // 22.10.
            solution("4", "Ida", title: "Tutorium 2", fingerprint: "fC", week: 2, likes: 1),
        ]
        let weeks = CommunityChannel.build(list)
        XCTAssertEqual(CommunityChannel.rows(weeks, sort: .relevance).map(\.title), ["Übungsblatt 3", "Tutorium 2", "Vorlesung 1"])
        XCTAssertEqual(CommunityChannel.rows(weeks, sort: .newest).map(\.title), ["Übungsblatt 3", "Tutorium 2", "Vorlesung 1"])
        let tut = try XCTUnwrap(CommunityChannel.rows(weeks, sort: .newest).first { $0.title == "Tutorium 2" })
        XCTAssertEqual(tut.byline, "2 Personen")
        XCTAssertEqual(CommunityChannel.rows(weeks, sort: .newest).first { $0.title == "Vorlesung 1" }?.byline, "von Lea")
        // Relevanz zaehlt Likes und Kommentare: viele Kommentare schlagen die neueste
        let talk = CommunityChannel.build([solution("5", "Ben", title: "Alt", fingerprint: "x", week: 1, comments: 9),
                                           solution("6", "Lea", title: "Neu", fingerprint: "y", week: 5)])
        XCTAssertEqual(CommunityChannel.rows(talk, sort: .relevance).map(\.title), ["Alt", "Neu"])
        XCTAssertEqual(CommunityChannel.rows(talk, sort: .newest).map(\.title), ["Neu", "Alt"])

        let service = FakeChannelService()
        service.list = list
        let space = CommunitySpace(key: "k", kind: .course, name: "Analysis", joined: true)
        let view = try show(CommunitySpacePage(key: "k", space: space, service: service))
        XCTAssertTrue(pump { self.shows(view, "Dokumente (4)") }, "\(texts(view))")
        XCTAssertTrue(tap("Liste", in: view))
        XCTAssertTrue(pump { self.shows(view, "Tutorium: Tutorium 2, 2 Personen") }, "\(texts(view))")
        XCTAssertTrue(shows(view, "Übung: Übungsblatt 3, von Ben"))
        XCTAssertTrue(shows(view, "4 Likes, 2 Kommentare"))
        XCTAssertTrue(shows(view, "Relevanz"))
        XCTAssertTrue(tap("Neueste", in: view))
        XCTAssertTrue(tap("Wochen", in: view))
        XCTAssertTrue(pump { self.shows(view, "Woche 3") })
    }

    func testPersonNotesHaveDocumentAndDiscussionTabsAndFloatingBar() throws {
        let service = FakeChannelService()
        let people = [solution("1", "Lea", title: "B", week: 1), solution("2", "Ben", title: "B", week: 1)]
        var extraTapped = false
        let view = try show(NavigationStack {
            CommunityPeopleReader(title: "B", people: people, start: 0, service: service,
                                  extraActions: { _ in [CommunityReaderAction(id: "extra", title: "Weitere Aktion") { extraTapped = true }] },
                                  removed: { _, _ in })
        })
        XCTAssertTrue(pump { self.shows(view, "Diskussion (0)") }, "\(texts(view))")
        XCTAssertTrue(shows(view, "Dokument"))
        XCTAssertFalse(shows(view, "Noch keine Kommentare."), "Kommentare stehen im eigenen Reiter")
        XCTAssertTrue(shows(view, "Gefällt mir · 0"))
        XCTAssertTrue(shows(view, "Mehr"))
        XCTAssertTrue(tap("Kommentar", in: view))
        XCTAssertTrue(pump { self.shows(view, "Noch keine Kommentare.") }, "\(texts(view))")
        XCTAssertTrue(tap("Dokument", in: view))
        XCTAssertTrue(pump { !self.shows(view, "Noch keine Kommentare.") })
        XCTAssertTrue(tap("Weitere Aktion", in: view), "Erweiterungspunkt der Leiste")
        XCTAssertTrue(extraTapped)
    }

    // MARK: Beitrag erscheint sofort (Befund iPad 08.11.2026)

    /// Hoechstens so lange darf es von "Frage stellen" bis zur Frage in der Liste dauern, auch wenn die Cloud 2 s braucht
    static let appearLimit: TimeInterval = 0.3

    func testQuestionAppearsImmediatelyWhileCloudIsSlow() throws {
        let service = FakeChannelService()
        service.spaceDiscussion = true
        service.postDelay = 2
        service.posts = [post("q1", "Lea", "Wie geht 2b?", at: "2026-11-01T10:00:00Z")]
        let space = CommunitySpace(key: "k", kind: .course, name: "Analysis", joined: true)
        let view = try show(CommunitySpaceDiscussion(space: space, service: service, draft: "Wann ist die Klausur?"))
        XCTAssertTrue(pump { self.shows(view, "Frage von Lea") }, "\(texts(view))")
        XCTAssertEqual(postLabels(view).count, 1, "nur Leas Frage: \(postLabels(view))")

        let start = Date()
        XCTAssertTrue(tap("Frage stellen", in: view))
        XCTAssertTrue(pump(timeout: 3) { self.shows(view, "Frage von Anonym, gerade eben: Wann ist die Klausur?") }, "\(texts(view))")
        let elapsed = Date().timeIntervalSince(start)
        print("MESSUNG Frage sichtbar nach \(String(format: "%.3f", elapsed)) s (Cloud braucht \(service.postDelay) s)")
        XCTAssertLessThan(elapsed, Self.appearLimit, "die eigene Frage steht sofort in der Liste, nicht erst nach dem Save")
        XCTAssertTrue(shows(view, CommunityPendingSend.sending), "\(texts(view))")
        XCTAssertTrue(shows(view, "Frage von Lea"), "die anderen Fragen bleiben")
        XCTAssertEqual(service.sent, [], "der Save laeuft noch")
        screenshot(view, "frage-wird-gesendet")

        // nach dem Save: nur dieser Eintrag ersetzt, kein Neuladen der Liste, keine Dublette
        XCTAssertTrue(pump(timeout: 5) { !self.shows(view, CommunityPendingSend.sending) }, "\(texts(view))")
        XCTAssertEqual(service.sent, ["Wann ist die Klausur?"])
        let labels = postLabels(view)
        XCTAssertEqual(labels.count, 2, "Leas Frage und die eigene, keine Dublette: \(labels)")
        XCTAssertFalse(shows(view, "Frage von Anonym, gerade eben"), "der Platzhalter ist durch den Datensatz des Dienstes ersetzt: \(labels)")
        XCTAssertTrue(shows(view, "Wann ist die Klausur?, 0 Antworten"))
        XCTAssertTrue(shows(view, "Frage von Lea"))
        screenshot(view, "frage-gesendet")
    }

    func testFailedSendShowsRetryAndKeepsTheQuestion() throws {
        let service = FakeChannelService()
        service.spaceDiscussion = true
        service.postFailure = .offline
        let space = CommunitySpace(key: "k", kind: .course, name: "Analysis", joined: true)
        let view = try show(CommunitySpaceDiscussion(space: space, service: service, draft: "Gibt es Altklausuren?"))
        XCTAssertTrue(pump { self.shows(view, "Noch keine Fragen") }, "\(texts(view))")
        XCTAssertTrue(tap("Frage stellen", in: view))
        XCTAssertTrue(pump(timeout: 3) { self.shows(view, CommunityPendingSend.retry) }, "\(texts(view))")
        XCTAssertTrue(shows(view, "Frage von Anonym, gerade eben: Gibt es Altklausuren?"), "der Beitrag bleibt lokal stehen")
        XCTAssertTrue(shows(view, CommunityPendingSend.failed(CommunityServiceError.offline.localizedDescription)), "\(texts(view))")
        XCTAssertEqual(service.sent, [])
        screenshot(view, "frage-nicht-gesendet")

        // Netz wieder da: erneut senden ersetzt den Platzhalter
        service.postFailure = nil
        XCTAssertTrue(tap(CommunityPendingSend.retry, in: view))
        XCTAssertTrue(pump(timeout: 3) { !self.shows(view, CommunityPendingSend.retry) && !self.shows(view, CommunityPendingSend.sending) }, "\(texts(view))")
        XCTAssertEqual(service.sent, ["Gibt es Altklausuren?"])
        XCTAssertTrue(shows(view, "Gibt es Altklausuren?"))
        screenshot(view, "frage-erneut-gesendet")

        // Verwerfen nimmt einen gescheiterten Beitrag wieder heraus
        service.postFailure = .offline
        let again = try show(CommunitySpaceDiscussion(space: space, service: service, draft: "Noch eine Frage"))
        XCTAssertTrue(pump { self.shows(again, "Frage stellen") })
        XCTAssertTrue(tap("Frage stellen", in: again))
        XCTAssertTrue(pump(timeout: 3) { self.shows(again, CommunityPendingSend.discard) }, "\(texts(again))")
        XCTAssertTrue(tap(CommunityPendingSend.discard, in: again))
        XCTAssertTrue(pump { !self.shows(again, "Noch eine Frage") }, "\(texts(again))")
    }

    func testReplyAppearsImmediatelyInThread() throws {
        let service = FakeChannelService()
        service.spaceDiscussion = true
        service.postDelay = 2
        let question = post("q1", "Lea", "Wie geht 2b?", at: "2026-11-01T10:00:00Z")
        service.posts = [question]
        let space = CommunitySpace(key: "k", kind: .course, name: "Analysis", joined: true)
        var changed: [CommunityPost] = []
        let view = try show(CommunityThreadSheet(space: space, service: service, post: question, close: {}, changed: { changed.append($0) },
                                                 draft: "Mit der Kettenregel."))
        XCTAssertTrue(pump { self.shows(view, "Noch keine Antworten") }, "\(texts(view))")
        let start = Date()
        XCTAssertTrue(tap("Antworten", in: view))
        XCTAssertTrue(pump(timeout: 3) { self.shows(view, "Mit der Kettenregel.") }, "\(texts(view))")
        let elapsed = Date().timeIntervalSince(start)
        print("MESSUNG Antwort sichtbar nach \(String(format: "%.3f", elapsed)) s (Cloud braucht \(service.postDelay) s)")
        XCTAssertLessThan(elapsed, Self.appearLimit)
        XCTAssertTrue(shows(view, "1 Antwort"))
        XCTAssertTrue(shows(view, CommunityPendingSend.sending))
        screenshot(view, "antwort-wird-gesendet")
        XCTAssertTrue(pump(timeout: 5) { !self.shows(view, CommunityPendingSend.sending) })
        XCTAssertEqual(service.sent, ["Mit der Kettenregel."])
        XCTAssertTrue(pump(timeout: 2) { changed.last?.replies.map(\.id) == ["srv-1"] }, "die Liste bekommt nur diese Frage zurueck: \(changed.map { $0.replies.map(\.id) })")
        XCTAssertTrue(shows(view, "1 Antwort"))
    }

    func testPendingSendHelpersKeepOrderAndReplacePlaceholders() {
        let local = CommunityPendingSend.comment(text: "  Hallo  ", pseudonym: "  ", now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(CommunityPendingSend.isLocal(local.id))
        XCTAssertEqual(local.text, "Hallo")
        XCTAssertEqual(local.pseudonym, "Anonym")
        XCTAssertTrue(local.isMine)
        XCTAssertEqual(CommunityPendingSend.comment(text: "x", pseudonym: " Lea ").pseudonym, "Lea")

        // Antwort hinter die letzte Antwort ihres Kommentars, neuer Kommentar ans Ende
        let a = CommunityComment(id: "a", pseudonym: "Lea", text: "A", createdAt: "1")
        let a1 = CommunityComment(id: "a1", parentID: "a", pseudonym: "Ben", text: "A1", createdAt: "2")
        let b = CommunityComment(id: "b", pseudonym: "Mia", text: "B", createdAt: "3")
        var list = [a, a1, b]
        let reply = CommunityPendingSend.comment(text: "A2", parentID: "a", pseudonym: "Du")
        CommunityPendingSend.insert(reply, into: &list)
        XCTAssertEqual(list.map(\.id), ["a", "a1", reply.id, "b"])
        let top = CommunityPendingSend.comment(text: "C", pseudonym: "Du")
        CommunityPendingSend.insert(top, into: &list)
        XCTAssertEqual(list.map(\.id), ["a", "a1", reply.id, "b", top.id])

        // Ersetzen an Ort und Stelle; Neuladen behaelt die offenen Eintraege und eine offene Aenderung
        let saved = CommunityComment(id: "srv", parentID: "a", pseudonym: "Du", text: "A2", createdAt: "4", isMine: true)
        CommunityPendingSend.replace(&list, localID: reply.id, with: saved)
        XCTAssertEqual(list.map(\.id), ["a", "a1", "srv", "b", top.id])
        var edited = b
        edited.text = "B neu"
        let merged = CommunityPendingSend.merge(fresh: [a, a1, saved, b], pending: [top, edited])
        XCTAssertEqual(merged.map(\.id), ["a", "a1", "srv", "b", top.id])
        XCTAssertEqual(merged.first { $0.id == "b" }?.text, "B neu")
        XCTAssertEqual(CommunityPendingSend.merge(fresh: [a], pending: []).map(\.id), ["a"])
        // Fragen: offene zuerst, lokale aus dem frischen Stand fallen weg
        let q = CommunityPost(question: top)
        XCTAssertEqual(CommunityPendingSend.merge(fresh: [CommunityPost(question: a), q], pending: [q]).map(\.id), [top.id, "a"])
    }

    /// Beschriftungen der Fragenkarten (ohne Doppelte aus der Baumdurchquerung)
    private func postLabels(_ view: UIView) -> Set<String> {
        Set(texts(view).filter { $0.hasPrefix("Frage von") })
    }

    /// Bildschirmfoto in UF_SCREENSHOT_DIR (Abnahme), sonst nichts
    private func screenshot(_ view: UIView, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty else { return }
        pump(timeout: 0.3)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let png = UIGraphicsImageRenderer(bounds: view.bounds, format: format).pngData { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    // MARK: Werkzeuge (wie AuditRunde0910AppTests)

    private var planBefore: UFPlan = .free

    override func setUp() async throws {
        try await super.setUp()
        // Community ab Plus (05.11.2026): die Seiten pruefen den Tarif ueber Entitlements.shared
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
