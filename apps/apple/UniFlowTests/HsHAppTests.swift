import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Hochschule Hannover in der App: Hochschulwahl, erster Start (Moodle, Campusmanagement), Verbindung mit Abgleich
/// gegen nachgebaute Antworten (`UniStubProtocol`, packages/shared-contracts/fixtures/hsh, NACHGEBAUT), Abo-Adresse im
/// Schluesselbund, Abmelden, In-App-Browser. Kein echtes Netz, keine echten Zugangsdaten.
@MainActor
final class HsHAppTests: XCTestCase {
    private var bed: ContainerTestBed!

    override func setUp() async throws {
        bed = try ContainerTestBed(name: "hsh", clock: .fixed(berlin: "2026-11-05T10:00:00")!)
    }

    override func tearDown() async throws {
        await bed.tearDown()
        bed = nil
    }

    private func fx(_ name: String) throws -> String {
        try String(contentsOf: ContainerTestBed.repoURL("packages/shared-contracts/fixtures/hsh/\(name)"), encoding: .utf8)
    }

    private func manager() -> ContainerManager {
        let stub: @MainActor (WKWebsiteDataStore) async -> UniTransport = { store in
            await URLSessionUniTransport.make(dataStore: store, allowedDomains: HsHConnection.domains,
                                              configuration: UniStubProtocol.configuration())
        }
        return ContainerManager(base: bed.containers,
                                legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                                    studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
                                keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock,
                                publishesCurrent: false, hshTransport: stub)
    }

    // MARK: Hochschulwahl und erster Start

    func testUniversityPickerAndFirstStartSteps() {
        XCTAssertTrue(UniversityKey.allCases.contains(.hsh))
        XCTAssertTrue(UniversityOption.services(.hsh).contains("Moodle"))
        XCTAssertTrue(UniversityOption.services(.hsh).contains("Campusmanagement"))
        XCTAssertEqual(FirstLoginStep.steps(for: .hsh), [.moodle, .campus])
        XCTAssertEqual(FirstLoginStep.moodle.title, "Bei Moodle anmelden")
        XCTAssertTrue(FirstLoginStep.campus.intro.contains("keine gemeinsame Anmeldung"))
        let rows = FirstSyncProgress.hsh(moodle: .ok(Date()), campus: .needsLogin, messages: ["3 neue/geänderte Dateien aus 2 Moodle-Kursen"])
        XCTAssertEqual(rows.map(\.state), [.done, .needsLogin, .needsLogin])
        XCTAssertEqual(rows.first?.detail, "3 neue/geänderte Dateien aus 2 Moodle-Kursen")
        XCTAssertEqual(BackgroundSyncCard.notifyText(.hsh).contains("Moodle"), true)
    }

    func testContainerOpensWithHsHConnectionOnly() throws {
        let m = manager()
        _ = try bed.open(m, bed.account(.hsh))
        XCTAssertNotNil(m.hsh)
        XCTAssertNil(m.hildesheim)
        XCTAssertNil(m.qis)
        XCTAssertEqual(m.hsh?.state(.moodle), .notConnected)
        XCTAssertTrue(FirstLoginFlow.offersDemo(studip: m.studip, qis: nil, hildesheim: nil, hsh: m.hsh))
    }

    // MARK: Anmeldung erkennen

    func testSignedInDetection() throws {
        let moodleMy = URL(string: "https://moodle.hs-hannover.de/my/")!
        XCTAssertTrue(HsHConnection.isSignedIn(.moodle, html: #"<script>M.cfg = {"sesskey":"x"};</script><body class="x">"#, url: moodleMy))
        XCTAssertFalse(HsHConnection.isSignedIn(.moodle, html: #"<body class="notloggedin">"sesskey":"x"</body>"#, url: moodleMy))
        XCTAssertFalse(HsHConnection.isSignedIn(.moodle, html: #""sesskey":"x""#, url: URL(string: "https://moodle.hs-hannover.de/login/index.php")!))
        let start = UniversityProfile.hshCampusStart
        XCTAssertTrue(HsHConnection.isSignedIn(.campus, html: try fx("hisinone-start-angemeldet.html"), url: start))
        XCTAssertFalse(HsHConnection.isSignedIn(.campus, html: try fx("hisinone-start-abgemeldet.html"), url: start),
                       "das versteckte Dialogfeld zaehlt nicht")
        XCTAssertFalse(HsHConnection.isSignedIn(.campus, html: try fx("hisinone-start-angemeldet.html"), url: URL(string: "https://evil.example/")!))
    }

    // MARK: Abgleich

    private func installCampusAndMoodle() throws {
        let timetable = try fx("hisinone-stundenplan.html"), ics = try fx("stundenplan.ics"), grades = try fx("hisinone-leistungen.html")
        let exams = try fx("hisinone-pruefungen-anmelden.html")
        let link = try XCTUnwrap(HISinOne.icalLink(html: timetable)).absoluteString
        let state = #"{"section":[{"id":"11","number":1,"title":"1"}],"cm":[{"id":"7","module":"resource","name":"Folien","sectionid":"11"}]}"#
        UniStubProtocol.install { seen in
            let u = seen.url.absoluteString
            if u.hasPrefix(HISinOne.timetableURL.absoluteString) { return .text(timetable) }
            if u == link || u.hasPrefix(link) { return .text(ics, headers: ["Content-Type": "text/calendar"]) }
            if u.hasPrefix(HISinOne.gradesURL.absoluteString) { return .text(grades) }
            if u.hasPrefix(HISinOne.examRegistrationURL.absoluteString) { return .text(exams) }
            if u.hasPrefix(HISinOne.qisIframeURL.absoluteString) { return .text(#"<a href="?category=auth.logout">Abmelden</a>"#) }
            if u.hasPrefix("https://moodle.hs-hannover.de/my/courses.php") { return .text(#"<script>M.cfg = {"sesskey":"k1"};</script>"#) }
            if u.contains("info=core_course_get_enrolled_courses_by_timeline_classification") {
                return .text(#"[{"error":false,"data":{"courses":[{"id":501,"fullname":"Programmieren 1, WiSe 2026/27, Prof. Muster"}]}}]"#)
            }
            if u.contains("info=core_courseformat_get_state") {
                let escaped = state.replacingOccurrences(of: "\"", with: "\\\"")
                return .text(#"[{"error":false,"data":"\#(escaped)"}]"#)
            }
            if u.contains("/lib/ajax/service.php") { return .text(#"[{"error":false,"data":{"events":[]}}]"#) }
            if u.hasPrefix("https://moodle.hs-hannover.de/mod/resource/view.php?id=7") {
                return .redirect(303, to: "https://moodle.hs-hannover.de/pluginfile.php/5/mod_resource/content/4/Folien.pdf")
            }
            if u.hasPrefix("https://moodle.hs-hannover.de/pluginfile.php/") {
                return .text("%PDF-1.4 erfunden", headers: ["Content-Type": "application/pdf"])
            }
            return UniStubProtocol.Reply(status: 404)
        }
    }

    func testSignInBothSourcesSyncsAndRemembersSubscription() async throws {
        try installCampusAndMoodle()
        let m = manager()
        let c = try bed.open(m, bed.account(.hsh))
        let hsh = try XCTUnwrap(m.hsh)
        hsh.syncsAfterSignIn = false
        hsh.signedIn(.moodle)
        hsh.signedIn(.campus)
        let report = await hsh.run(forceGrades: true)
        let r = try XCTUnwrap(report)
        XCTAssertNil(r.refused, r.messages.joined(separator: "; "))
        XCTAssertEqual(r.courses, 1, r.messages.joined(separator: "; "))
        XCTAssertEqual(r.grades, 5)
        XCTAssertEqual(r.plan?.new, 2)
        if case .ok = hsh.state(.moodle) {} else { XCTFail("Moodle: \(hsh.state(.moodle))") }
        if case .ok = hsh.state(.campus) {} else { XCTFail("Campusmanagement: \(hsh.state(.campus))") }
        XCTAssertEqual(hsh.registrationsMessage, "2 angemeldete Prüfungen gelesen.")
        // Abo-Adresse nur im Schluesselbund, nie in den Meldungen
        XCTAssertTrue(HISinOne.isExportURL(hsh.savedICal))
        XCTAssertFalse(r.messages.joined().contains("hash="))
        XCTAssertFalse(hsh.messages.joined().contains("Learnweb"))
        // nie ein Formular abgeschickt (Pruefungsanmeldung), nur Lesen
        XCTAssertTrue(UniStubProtocol.requests.allSatisfy { $0.method == "GET" || $0.url.absoluteString.contains("/lib/ajax/") })
        // Abmelden: Abo-Adresse und Verbindungen weg, Daten bleiben
        await hsh.signOut()
        XCTAssertNil(hsh.savedICal)
        XCTAssertFalse(hsh.anyConnected)
        let backend = try await c.host.backend()
        let events = try await backend.context.database.scalar("SELECT COUNT(*) FROM course_events")?.int
        XCTAssertEqual(events, 2)
    }

    func testExpiredCampusSessionAsksForLogin() async throws {
        UniStubProtocol.install { seen in
            if seen.url.host == "campusmanagement.hs-hannover.de" {
                return .redirect(302, to: "https://idp.hs-hannover.de/simplesaml/module.php/saml/idp/singleSignOnService?x=1")
            }
            if seen.url.host == "idp.hs-hannover.de" { return .text("<form><input type=password></form>") }
            return UniStubProtocol.Reply(status: 404)
        }
        let m = manager()
        _ = try bed.open(m, bed.account(.hsh))
        let hsh = try XCTUnwrap(m.hsh)
        hsh.syncsAfterSignIn = false
        hsh.signedIn(.campus)
        let r = await hsh.run(forceGrades: true)
        XCTAssertEqual(r?.needsLogin, ["Campusmanagement"])
        XCTAssertEqual(hsh.state(.campus), .needsLogin)
        XCTAssertEqual(HsHConnection.statusText(.campus, hsh.state(.campus)), "Campusmanagement: Anmeldung nötig")
    }

    // MARK: Nachrichten, Studienservice, Hintergrund, Abgabe (nachgebaute Antworten)

    private func moodleFx(_ name: String) throws -> String {
        try String(contentsOf: ContainerTestBed.repoURL("packages/shared-contracts/fixtures/moodle/\(name)"), encoding: .utf8)
    }

    /// Moodle-Nachrichten und Studienservice zusaetzlich zu Moodle-Kurs und Campusmanagement
    private func installEverything(sent: @escaping @Sendable (String) -> Void = { _ in }) throws {
        let timetable = try fx("hisinone-stundenplan.html"), ics = try fx("stundenplan.ics"), grades = try fx("hisinone-leistungen.html")
        let exams = try fx("hisinone-pruefungen-anmelden.html"), service = try fx("hisinone-studienservice.html")
        let payments = try fx("hisinone-studienservice-zahlungen.html"), documents = try fx("hisinone-studienservice-bescheide.html")
        let conversations = try moodleFx("conversations.json"), convMessages = try JSONValue.parse(Data(try moodleFx("conversation-messages.json").utf8))
        let link = try XCTUnwrap(HISinOne.icalLink(html: timetable)).absoluteString
        let state = #"{"section":[{"id":"11","number":1,"title":"1"}],"cm":[{"id":"7","module":"resource","name":"Folien","sectionid":"11"}]}"#
        UniStubProtocol.install { seen in
            let u = seen.url.absoluteString
            if u.hasPrefix(HISinOne.timetableURL.absoluteString) { return .text(timetable) }
            if u.hasPrefix(link) { return .text(ics) }
            if u.hasPrefix(HISinOne.gradesURL.absoluteString) { return .text(grades) }
            if u.hasPrefix(HISinOne.examRegistrationURL.absoluteString) { return .text(exams) }
            if u.hasPrefix(HISinOne.qisIframeURL.absoluteString) { return .text(#"<a href="?category=auth.logout">Abmelden</a>"#) }
            if u.hasPrefix(HISinOneStudyService.url.absoluteString) { return .text(service) }
            if u.hasPrefix("https://campusmanagement.hs-hannover.de/qisserver/pages/cm/stu/studyService/start.xhtml"), seen.method == "POST" {
                return .text(seen.bodyText.contains("tab3=") ? documents : payments)
            }
            if u.hasPrefix("https://moodle.hs-hannover.de/my/courses.php") || u.hasPrefix("https://moodle.hs-hannover.de/message/index.php") {
                return .text(#"<script>M.cfg = {"sesskey":"k1"};</script><div data-userid="42"></div>"#)
            }
            if u.contains("info=core_course_get_enrolled_courses_by_timeline_classification") {
                return Self.ajax(#"{"courses":[{"id":501,"fullname":"Programmieren 1, WiSe 2026/27, Prof. Muster"}]}"#)
            }
            if u.contains("info=core_courseformat_get_state") { return Self.ajax("\"" + state.replacingOccurrences(of: "\"", with: "\\\"") + "\"") }
            if u.contains("info=core_message_get_conversations") {
                let j = try! JSONValue.parse(Data(conversations.utf8))
                return Self.ajax(j.jsonString())
            }
            if u.contains("info=core_message_get_conversation_messages") {
                let key = seen.bodyText.contains("\"convid\":13") ? "13" : "12"
                return Self.ajax((convMessages[key] ?? .null).jsonString())
            }
            if u.contains("info=core_message_get_unread_conversations_count") { return Self.ajax("1") }
            if u.contains("info=core_message_send_messages_to_conversation") { sent(seen.bodyText); return Self.ajax(#"[{"id":999}]"#) }
            if u.contains("/lib/ajax/service.php") { return Self.ajax(#"{"events":[]}"#) }
            if u.hasPrefix("https://moodle.hs-hannover.de/mod/resource/view.php?id=7") {
                return .redirect(303, to: "https://moodle.hs-hannover.de/pluginfile.php/5/mod_resource/content/4/Folien.pdf")
            }
            if u.hasPrefix("https://moodle.hs-hannover.de/pluginfile.php/") { return .text("%PDF-1.4 erfunden", headers: ["Content-Type": "application/pdf"]) }
            return UniStubProtocol.Reply(status: 404)
        }
    }

    nonisolated static func ajax(_ data: String) -> UniStubProtocol.Reply { .text(#"[{"error":false,"data":\#(data)}]"#) }

    func testMessagesStudyServiceAndReply() async throws {
        let box = SentBox()
        try installEverything(sent: { box.add($0) })
        let m = manager()
        let c = try bed.open(m, bed.account(.hsh))
        let hsh = try XCTUnwrap(m.hsh)
        hsh.syncsAfterSignIn = false
        hsh.signedIn(.moodle)
        hsh.signedIn(.campus)
        _ = await hsh.run(forceGrades: true)
        XCTAssertEqual(hsh.messagesNote, "Nachrichten: 2 (1 ungelesen in Moodle)")
        XCTAssertEqual(hsh.studyService?["reregistration"]?.string, "Rückgemeldet für Wintersemester 2026/27")
        XCTAssertEqual(hsh.studyService?["open_payments"]?.int, 0)
        let backend = try await c.host.backend()
        let list = try await backend.context.database.withConnection { try StudIPExtras.messageList($0) }
        XCTAssertEqual(list["messages"]?.array?.count, 2)
        let ab = try await backend.context.database.scalar("SELECT abschluss FROM grades LIMIT 1")?.string
        XCTAssertEqual(ab, "Bachelor Angewandte Informatik (PO-Version 2019)", "Studiengang fuer den Studienverlauf")
        // Antwort nur auf Knopfdruck, genau eine Anfrage
        XCTAssertTrue(box.bodies.isEmpty)
        let maybeWeb = await hsh.moodleWeb()
        let web = try XCTUnwrap(maybeWeb)
        try await MoodleMessagesSync.reply(web: web, conversation: 12, text: "Danke!")
        XCTAssertEqual(box.bodies.count, 1)
        XCTAssertTrue(box.bodies[0].contains("Danke!"))
    }

    func testBackgroundUsesSubscriptionWhenCampusExpired() async throws {
        try installEverything()
        let m = manager()
        _ = try bed.open(m, bed.account(.hsh))
        let hsh = try XCTUnwrap(m.hsh)
        hsh.syncsAfterSignIn = false
        hsh.signedIn(.campus)
        _ = await hsh.run(forceGrades: true)
        XCTAssertNotNil(hsh.savedICal)
        // Sitzung des Campusmanagements abgelaufen: nur noch die Abo-Adresse antwortet
        let ics = try fx("stundenplan.ics"), link = try XCTUnwrap(hsh.savedICal).absoluteString
        UniStubProtocol.install { seen in
            if seen.url.absoluteString.hasPrefix(link) { return .text(ics) }
            if seen.url.host == "campusmanagement.hs-hannover.de" {
                return .redirect(302, to: "https://idp.hs-hannover.de/simplesaml/module.php/saml/idp/singleSignOnService?x=1")
            }
            return .text("<form><input type=password></form>")
        }
        let r = await hsh.runInBackground(.refresh)
        XCTAssertEqual(r.loginNeeded, [], "Listen ohne Leistungen: Abo-Adresse genuegt")
        XCTAssertTrue(hsh.usableSources.contains("Campusmanagement"))
        XCTAssertEqual(hsh.fileSource, "Moodle")
    }

    func testSubmitModelUploadsDraftAndSubmitsOnlyOnButton() async throws {
        let edit = try moodleFx("assign-edit.html"), draft = try moodleFx("assign-view-draft.html")
        let none = try moodleFx("assign-view-none.html"), confirm = try moodleFx("assign-confirm.html")
        let submitted = try moodleFx("assign-view-submitted.html"), upload = try moodleFx("upload-ok.json")
        let box = SentBox()
        UniStubProtocol.install { seen in
            let u = seen.url.absoluteString
            if u.hasPrefix("https://moodle.hs-hannover.de/message/index.php") { return .text(#"<script>M.cfg = {"sesskey":"sk123"};</script><div data-userid="42"></div>"#) }
            if u.hasSuffix("action=editsubmission") { return .text(edit) }
            if u.hasSuffix("action=submit") { return .text(confirm) }
            if u.contains("repository_ajax.php") { box.add("upload"); return .text(upload) }
            if seen.method == "POST", seen.bodyText.contains("action=savesubmission") { box.add("save"); return .text(draft) }
            if seen.method == "POST", seen.bodyText.contains("action=confirmsubmit") { box.add("confirm"); return .text(submitted) }
            if u.hasSuffix("view.php?id=7001") { return .text(none) }
            return UniStubProtocol.Reply(status: 404)
        }
        let m = manager()
        _ = try bed.open(m, bed.account(.hsh))
        let hsh = try XCTUnwrap(m.hsh)
        hsh.syncsAfterSignIn = false
        hsh.signedIn(.moodle)
        let a = MoodleAssign.Assignment(cmid: 7001, title: "Übungsblatt 3", dueAt: "2026-11-12T23:59", course: "Programmieren 1")
        let model = MoodleSubmitModel(web: { await hsh.moodleWeb() }, fileName: MoodleSubmitEntry.fileName("Blatt 3.pdf"),
                                      loadAssignments: { [a] }, pdf: { _ in Data("%PDF-1.4 erfunden".utf8) })
        await model.start()
        XCTAssertEqual(model.assignments, [a])
        await model.choose(a)
        XCTAssertEqual(model.status?.state, MoodleAssign.State.none)
        await model.uploadDraft()
        XCTAssertEqual(box.bodies, ["upload", "save"])
        guard case .saved(let st, _) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(st.state, MoodleAssign.State.draft)
        XCTAssertEqual(model.confirm?.statement, "Diese Arbeit ist meine eigene Leistung.")
        XCTAssertFalse(box.bodies.contains("confirm"), "Entwurf ist keine Abgabe")
        model.statementAccepted = true
        await model.submitNow()
        XCTAssertEqual(box.bodies, ["upload", "save", "confirm"])
        XCTAssertEqual(model.status?.state, MoodleAssign.State.submitted)
        XCTAssertEqual(MoodleSubmitEntry.fileName("Blatt 3.pdf"), "Blatt_3.pdf")
        XCTAssertTrue(MoodleSubmitEntry.offered(api: APIClient.local(), readOnly: false, hsh: hsh))
        XCTAssertFalse(MoodleSubmitEntry.offered(api: APIClient.local(), readOnly: true, hsh: hsh))
    }

    // MARK: In-App-Browser

    func testLinksOfTheHsHOpenInApp() {
        for s in ["https://moodle.hs-hannover.de/course/view.php?id=6011", "https://campusmanagement.hs-hannover.de/qisserver/pages/x",
                  "https://icms.hs-hannover.de/qisserver/rds?state=user"] {
            guard case .inApp = UniLinks.route(URL(string: s)!, university: .hsh) else { return XCTFail(s) }
        }
        XCTAssertEqual(UniLinks.route(URL(string: "https://www.hs-hannover.de/")!, university: .hsh), .system)
        XCTAssertEqual(UniLinks.route(URL(string: "https://moodle.hs-hannover.de/")!, university: .luh), .system)
        XCTAssertTrue(UniTransportCookies.domainsContainHsH)
    }
}

/// Gesendete Koerper (Stub, mehrere Faeden)
final class SentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var bodies: [String] { lock.withLock { items } }
}

/// Domains der gemerkten Anmeldung (`UniWebSessions.domains`): die HsH-Rechner gehoeren dazu
enum UniTransportCookies {
    @MainActor static var domainsContainHsH: Bool { UniWebSessions.domains(.hsh) == ["hs-hannover.de"] }
}
