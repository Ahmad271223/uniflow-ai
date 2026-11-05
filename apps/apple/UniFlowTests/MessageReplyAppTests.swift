import SwiftUI
import UIKit
import XCTest
@testable import UniFlow
import UniFlowCore

/// Auf Stud.IP-Nachrichten antworten (docs/NACHRICHTEN-ANTWORTEN-2026-11-05.md): schreibender Transport ueber
/// `UniStubProtocol` (nichts geht ins Netz), Ablauf des Antwortfensters mit Erneuerung, CSRF-Ausweg und Entwurf, das
/// Fenster selbst ueber die Bedienungshilfe, Knoepfe im Leser und die Nachbildung `DebugStubTransport`. Nur erfundene
/// Nachrichten und Namen.
@MainActor
final class MessageReplyAppTests: XCTestCase {

    nonisolated static let host = UniversityKey.luh.profile.studipBase?.host ?? ""

    override func tearDown() {
        UniStubProtocol.reset()
        super.tearDown()
    }

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

    private func defaults() throws -> UserDefaults {
        let suite = "uniflow-antworten-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return d
    }

    nonisolated static func cookie() -> HTTPCookie {
        HTTPCookie(properties: [.name: "Seminar_Session", .value: "erfunden", .domain: host, .path: "/", .secure: "TRUE"])!
    }

    nonisolated static func json(_ s: String, status: Int = 200) -> UniStubProtocol.Reply {
        .text(s, status: status, headers: ["Content-Type": "application/vnd.api+json"])
    }

    /// Erfundenes Stud.IP: users/me, Posteingang (m1 an mich und zwei weitere, m-sys Systemnachricht), Namen; schreibende
    /// Anfragen beantwortet `post`
    nonisolated static func install(post: @escaping @Sendable (UniStubProtocol.Seen) -> UniStubProtocol.Reply) {
        UniStubProtocol.install { seen in
            let p = seen.url.absoluteString.removingPercentEncoding ?? seen.url.absoluteString
            if seen.method != "GET" { return post(seen) }
            if p.contains("/users/me") { return json(#"{"data":{"type":"users","id":"u-me"}}"#) }
            if p.contains("/users/u-me/inbox") {
                return json("""
                {"data":[
                 {"type":"messages","id":"m1","attributes":{"subject":"Tutorium entfällt","message":"<p>Hallo</p>","mkdate":"2026-11-04T08:15:00+01:00"},
                  "relationships":{"sender":{"data":{"type":"users","id":"u-doz"}},
                   "recipients":{"data":[{"type":"users","id":"u-me"},{"type":"users","id":"u-a"},{"type":"users","id":"u-b"}]}}},
                 {"type":"messages","id":"m-sys","attributes":{"subject":"Bescheinigung","message":"x","mkdate":"2026-11-02T12:00:00+01:00"},
                  "relationships":{"sender":{"data":{"type":"users","id":"____%system%____"}}}}
                ],"included":[{"type":"users","id":"u-doz","attributes":{"formatted-name":"Prof. Erika Test"}}],"links":{}}
                """)
            }
            if p.contains("/users/u-a") { return json(#"{"data":{"type":"users","id":"u-a","attributes":{"formatted-name":"Anna Beispiel"}}}"#) }
            if p.contains("/users/u-b") { return json(#"{"data":{"type":"users","id":"u-b","attributes":{"formatted-name":"Ben Beispiel"}}}"#) }
            return UniStubProtocol.Reply(status: 404)
        }
    }

    nonisolated static func created(_ seen: UniStubProtocol.Seen) -> UniStubProtocol.Reply {
        json(#"{"data":{"type":"messages","id":"neu1"}}"#, status: 201)
    }

    private func client() -> StudIPClient {
        StudIPClient(base: StudIPSync.base, transport: URLSessionStudIPWriter(cookies: [Self.cookie()], host: Self.host,
                                                                             configuration: UniStubProtocol.configuration()),
                     pauseMillis: 0)
    }

    static let original = MessageReplyOriginal(localID: "sp-msg-m1", subject: "Tutorium entfällt", text: "Hallo,\ndas Tutorium fällt aus.",
                                                       senderLabel: "Lehrende", sentAt: "2026-11-04T08:15:00+01:00")

    /// Ablauf mit festen Abhaengigkeiten; `readiness` liefert die Antworten von `ensureSession` nacheinander
    private func model(defaults: UserDefaults, mode: StudIPReplyMode = .sender, original: MessageReplyOriginal = original,
                       readiness: [StudIPSync.SessionReadiness] = [.ready], connected: Bool = true) -> MessageReplyModel {
        var answers = readiness
        let deps = MessageReplyModel.Dependencies(
            connected: { connected },
            ensureSession: { _ in answers.count > 1 ? answers.removeFirst() : (answers.first ?? .ready) },
            client: { self.client() },
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_793_890_000) })
        return MessageReplyModel(original: original, mode: mode, dependencies: deps)
    }

    private var posts: [UniStubProtocol.Seen] { UniStubProtocol.requests.filter { $0.method == "POST" } }

    // MARK: Transport

    /// POST messages mit Cookie, JSON:API-Kopfzeilen und Beziehung recipients; nie GET messages/{id}; nichts verlaesst
    /// den Stub
    func testWriterPostsMessageWithSessionCookieAndRecipients() throws {
        Self.install(post: Self.created)
        let ctx = try awaiting { try await self.client().replyContext(messageID: "m1") }
        XCTAssertEqual(ctx.sender.name, "Prof. Erika Test")
        XCTAssertEqual(ctx.otherRecipientIDs, ["u-a", "u-b"])
        let id = try awaiting { try await self.client().sendMessage(subject: "RE: Tutorium entfällt", text: "Danke!", recipientIDs: ["u-doz"]) }
        XCTAssertEqual(id, "neu1")
        let post = try XCTUnwrap(posts.first)
        XCTAssertEqual(post.url.path, "/jsonapi.php/v1/messages")
        XCTAssertTrue(post.cookie.contains("Seminar_Session=erfunden"))
        XCTAssertEqual(post.headers.first { $0.key.lowercased() == "content-type" }?.value, "application/vnd.api+json")
        XCTAssertEqual(post.headers.first { $0.key.lowercased() == "x-requested-with" }?.value, "XMLHttpRequest")
        let j = try JSONValue.parse(post.body)
        XCTAssertEqual(j["data"]?["type"]?.string, "messages")
        XCTAssertEqual(j["data"]?["attributes"]?["subject"]?.string, "RE: Tutorium entfällt")
        XCTAssertEqual(j["data"]?["attributes"]?["message"]?.string, "Danke!")
        XCTAssertEqual(j["data"]?["relationships"]?["recipients"]?["data"]?.array?.map { $0["id"]?.string }, ["u-doz"])
        XCTAssertEqual(j["data"]?["relationships"]?["recipients"]?["data"]?.array?.first?["type"]?.string, "users")
        XCTAssertFalse(UniStubProtocol.requests.contains { $0.url.path.contains("/v1/messages/") }, "keine Einzelansicht")
        XCTAssertTrue(UniStubProtocol.requests.allSatisfy { $0.url.host == Self.host })
    }

    /// Weiterleitung auf die Anmeldung beim Senden = Sitzung abgelaufen (nicht verfolgt, kein zweites POST)
    func testRedirectToLoginOnSendMeansSessionExpired() throws {
        Self.install { _ in .redirect(302, to: "https://\(Self.host)/dispatch.php/login") }
        XCTAssertThrowsError(try awaiting { try await self.client().sendMessage(subject: "a", text: "b", recipientIDs: ["u"]) }) { e in
            XCTAssertEqual(e as? StudIPError, .sessionExpired)
        }
        XCTAssertEqual(posts.count, 1)
    }

    // MARK: Ablauf

    func testFlowSendsWithQuoteRecordsAndClearsDraft() throws {
        Self.install(post: Self.created)
        let d = try defaults()
        let m = model(defaults: d)
        try awaiting { await m.start() }
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.subject, "RE: Tutorium entfällt")
        XCTAssertEqual(m.recipients.map(\.name), ["Prof. Erika Test"])
        XCTAssertFalse(m.quote, "Zitat standardmaessig aus")
        XCTAssertFalse(m.canSend, "ohne Text kein Senden")
        m.text = "Danke für die Info!"
        XCTAssertNotNil(StudIPReplyDrafts.load(d).draft(for: "sp-msg-m1"), "Entwurf sofort gesichert")
        m.quote = true
        XCTAssertTrue(m.canSend)
        try awaiting { await m.send() }
        guard case .sent(let record) = m.phase else { return XCTFail("nicht gesendet: \(m.phase) \(m.errorMessage ?? "")") }
        XCTAssertEqual(record.recipients, 1)
        XCTAssertEqual(record.text, "Danke für die Info!")
        XCTAssertTrue(record.quoted)
        XCTAssertEqual(record.sentID, "neu1")
        XCTAssertEqual(StudIPReplyLog.load(d).records(for: "sp-msg-m1"), [record])
        XCTAssertNil(StudIPReplyDrafts.load(d).draft(for: "sp-msg-m1"), "Entwurf nach dem Senden weg")
        XCTAssertEqual(posts.count, 1)
        let body = try JSONValue.parse(try XCTUnwrap(posts.first).body)["data"]?["attributes"]?["message"]?.string ?? ""
        XCTAssertEqual(body, "Danke für die Info!\n\nAm 04.11.2026 um 08:15 Prof. Erika Test schrieb:\n> Hallo,\n> das Tutorium fällt aus.")
        let log = String(decoding: d.data(forKey: StudIPReplyLog.defaultsKey) ?? Data(), as: UTF8.self)
        XCTAssertFalse(log.contains("Erika"), "keine Namen im Verlauf")
    }

    func testReplyAllLoadsNamesAndSendsToEveryoneButMe() throws {
        Self.install(post: Self.created)
        let m = model(defaults: try defaults(), mode: .all)
        try awaiting { await m.start() }
        try awaiting { while m.loadingOthers { try await Task.sleep(nanoseconds: 20_000_000) } }
        XCTAssertEqual(m.recipients.map(\.name), ["Prof. Erika Test", "Anna Beispiel", "Ben Beispiel"])
        m.text = "An alle"
        try awaiting { await m.send() }
        guard case .sent(let r) = m.phase else { return XCTFail("\(m.phase)") }
        XCTAssertEqual(r.recipients, 3)
        XCTAssertEqual(r.mode, .all)
        let ids = try JSONValue.parse(try XCTUnwrap(posts.first).body)["data"]?["relationships"]?["recipients"]?["data"]?.array?
            .compactMap { $0["id"]?.string }
        XCTAssertEqual(ids, ["u-doz", "u-a", "u-b"])
    }

    /// Abgelaufen beim Senden: still erneuern, dann genau ein zweiter Versuch
    func testExpiredOnSendRenewsAndRetriesOnce() throws {
        let count = Counter()
        Self.install { seen in count.next() == 1 ? UniStubProtocol.Reply(status: 401) : Self.created(seen) }
        let m = model(defaults: try defaults(), readiness: [.ready, .renewed])
        try awaiting { await m.start() }
        m.text = "Hallo"
        try awaiting { await m.send() }
        guard case .sent = m.phase else { return XCTFail("nicht gesendet: \(m.phase)") }
        XCTAssertEqual(posts.count, 2)
    }

    /// Abgelaufen und still nicht zu erneuern: Anmeldung, Entwurf bleibt, kein zweites POST
    func testExpiredWithoutRenewalNeedsLoginAndKeepsDraft() throws {
        Self.install { _ in UniStubProtocol.Reply(status: 401) }
        let d = try defaults()
        let m = model(defaults: d, readiness: [.ready, .needsUser])
        try awaiting { await m.start() }
        m.text = "Bitte nicht verlieren"
        try awaiting { await m.send() }
        XCTAssertEqual(m.phase, .needsLogin)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(StudIPReplyDrafts.load(d).draft(for: "sp-msg-m1")?.text, "Bitte nicht verlieren")
        XCTAssertTrue(StudIPReplyLog.load(d).records.isEmpty)
    }

    /// 403 mit CSRF: klare Meldung, Ausweg "In Stud.IP antworten", nichts im Verlauf, kein zweites POST
    func testCSRFRejectionOffersStudIPFallback() throws {
        Self.install { _ in Self.json(#"{"errors":[{"status":"403","detail":"Invalid CSRF token"}]}"#, status: 403) }
        let d = try defaults()
        let m = model(defaults: d)
        try awaiting { await m.start() }
        m.text = "Hallo"
        try awaiting { await m.send() }
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.errorMessage, StudIPMessageError.securityToken.errorDescription)
        XCTAssertTrue(m.offersWebFallback)
        XCTAssertEqual(m.replyWebURL.absoluteString, "https://\(Self.host)/dispatch.php/messages/write?answer_to=m1")
        XCTAssertEqual(posts.count, 1)
        XCTAssertTrue(StudIPReplyLog.load(d).records.isEmpty)
        XCTAssertEqual(StudIPReplyDrafts.load(d).draft(for: "sp-msg-m1")?.text, "Hallo", "Text bleibt fuer den zweiten Weg")
    }

    /// Fenster versehentlich geschlossen: der naechste Aufruf hat den Text wieder; "Entwurf verwerfen" loescht ihn
    func testDraftSurvivesClosingAndCanBeDiscarded() throws {
        Self.install(post: Self.created)
        let d = try defaults()
        let first = model(defaults: d)
        first.text = "Halb geschrieben"
        first.quote = true
        first.subject = "RE: Eigener Betreff"
        // Fenster zu, neues Fenster
        let second = model(defaults: d)
        XCTAssertEqual(second.text, "Halb geschrieben")
        XCTAssertTrue(second.quote)
        XCTAssertEqual(second.subject, "RE: Eigener Betreff")
        XCTAssertEqual(second.restoredDraftAt, Date(timeIntervalSince1970: 1_793_890_000))
        second.discardDraft()
        XCTAssertEqual(second.text, "")
        XCTAssertEqual(second.subject, "RE: Tutorium entfällt")
        XCTAssertNil(StudIPReplyDrafts.load(d).draft(for: "sp-msg-m1"))
        XCTAssertNil(model(defaults: d).restoredDraftAt)
        XCTAssertTrue(UniStubProtocol.requests.isEmpty, "Entwurf braucht kein Netz")
    }

    func testSystemMessageAndNotConnectedSendNothing() throws {
        Self.install(post: Self.created)
        let sys = model(defaults: try defaults(), original: MessageReplyOriginal(localID: "sp-msg-m-sys", subject: "Bescheinigung", text: "x",
                                                                                  senderLabel: "Stud.IP", sentAt: nil))
        try awaiting { await sys.start() }
        XCTAssertEqual(sys.phase, .unavailable(StudIPMessageError.systemMessage.errorDescription ?? ""))
        let off = model(defaults: try defaults(), connected: false)
        try awaiting { await off.start() }
        XCTAssertEqual(off.phase, .notConnected)
        XCTAssertTrue(UniStubProtocol.requests.isEmpty)
    }

    // MARK: Fenster

    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private func host<V: View>(_ view: V) -> UIView {
        let frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let hosting = UIHostingController(rootView: view)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return hosting.view
    }

    private func pump(_ seconds: Double = 0.6) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

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

    private func labels(_ root: UIView) -> [String] { elements(root).compactMap(\.accessibilityLabel) }

    private func find(_ root: UIView, label: String) -> NSObject? {
        elements(root).first { ($0.accessibilityLabel ?? "").hasPrefix(label) }
    }

    private func waitFor(_ root: UIView, label: String, seconds: Double = 8) -> NSObject? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let e = find(root, label: label) { return e }
            pump(0.2)
        }
        return nil
    }

    /// Fenster mit Empfaenger, Umschalter "Alle", Betreff, Hinweis, Schalter "Original zitieren"; "Senden" erst mit Text,
    /// sendet genau einmal, danach "Gesendet"
    func testSheetShowsComposerAndSends() throws {
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        Self.install(post: Self.created)
        let m = model(defaults: try defaults())
        let root = host(MessageReplySheet(model: m))
        XCTAssertNotNil(waitFor(root, label: "An Prof. Erika Test"), "Empfänger fehlt: \(labels(root))")
        let all = labels(root)
        XCTAssertTrue(all.contains(MessageReplySheet.notice), "Hinweis fehlt: \(all)")
        XCTAssertTrue(all.contains("Original zitieren"), "\(all)")
        XCTAssertTrue(all.contains { $0.hasPrefix("Alle (3)") }, "Umschalter für alle: \(all)")
        XCTAssertFalse(all.contains { $0.hasPrefix("Zitat:") }, "Zitat aus")
        let send = try XCTUnwrap(find(root, label: "Senden"))
        XCTAssertTrue(send.accessibilityTraits.contains(.notEnabled), "ohne Text gesperrt")
        m.text = "Danke!"
        pump(0.3)
        let ready = try XCTUnwrap(find(root, label: "Senden"))
        XCTAssertFalse(ready.accessibilityTraits.contains(.notEnabled))
        XCTAssertTrue(ready.accessibilityActivate())
        XCTAssertNotNil(waitFor(root, label: "Gesendet"), "kein Ergebnis: \(labels(root))")
        XCTAssertEqual(posts.count, 1)
    }

    /// Fehler mit Ausweg im Fenster und wiederhergestellter Entwurf
    func testSheetShowsErrorFallbackAndRestoredDraft() throws {
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        Self.install { _ in Self.json(#"{"errors":[{"detail":"CSRF"}]}"#, status: 403) }
        let d = try defaults()
        model(defaults: d).text = "Entwurf von vorhin"
        let m = model(defaults: d)
        let root = host(MessageReplySheet(model: m))
        XCTAssertNotNil(waitFor(root, label: "Entwurf vom"), "Entwurf-Hinweis fehlt: \(labels(root))")
        XCTAssertNotNil(find(root, label: "Entwurf verwerfen"))
        let send = try XCTUnwrap(find(root, label: "Senden"))
        XCTAssertTrue(send.accessibilityActivate())
        XCTAssertNotNil(waitFor(root, label: MessageReplySheet.fallbackTitle), "Ausweg fehlt: \(labels(root))")
        XCTAssertTrue(labels(root).contains { $0.contains("Sicherheitsprüfung") })
    }

    // MARK: Leser

    /// Leser: "Antworten" bei Nachrichten von Personen, "Allen antworten" nur mit mehreren bekannten Empfaengern, keiner bei
    /// Systemnachrichten
    func testReaderOffersReplyButtons() throws {
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true))
        defer { HostedEnvironment.accessibilityAutomation(false) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-antworten-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let backendHost = LocalBackendHost(directory: dir.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-04T10:30:00")!)
        let inbox: JSONValue = ["data": [
            ["id": "m1", "type": "messages", "attributes": ["subject": "Gruppenarbeit", "message": "Wer macht Teil 2?", "mkdate": "2026-11-04T08:15:00+01:00"],
             "relationships": ["sender": ["data": ["type": "users", "id": "u-x"]],
                               "recipients": ["data": [["type": "users", "id": "u-me"], ["type": "users", "id": "u-a"]]]]],
            ["id": "m2", "type": "messages", "attributes": ["subject": "Systemhinweis", "message": "x", "mkdate": "2026-11-03T08:15:00+01:00"],
             "relationships": ["sender": ["data": ["type": "users", "id": "____%system%____"]]]],
        ], "included": [["id": "u-x", "type": "users", "attributes": ["permission": "autor"]]]]
        _ = try awaiting {
            let backend = try await backendHost.backend()
            var d = StudIPExtras.Download()
            d.messages = StudIPExtras.parseMessages(inbox["data"], included: inbox["included"], base: "https://studip.example", today: 20761)
            d.messageMeta = StudIPExtras.parseMessageMeta(inbox["data"])
            let clock = backend.context.clock
            try await backend.context.database.transaction { try StudIPExtras.store(d, in: $0, clock: clock) }
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: backendHost))
        let env = try hostWithEnvironment(MessagesPage(today: "2026-11-04", splitOverride: true), api: api, size: CGSize(width: 1100, height: 900))
        env.router.go(.messages)
        XCTAssertTrue(env.wait { env.labels().contains(MessagesText.replyAll) }, env.labels().joined(separator: "\n"))
        XCTAssertTrue(env.labels().contains(MessagesText.reply))
        XCTAssertTrue(env.labels().contains(MessagesText.open))
        // Systemnachricht: keine Antwort
        let sys = try XCTUnwrap(env.labels().first { $0.contains("Systemhinweis") }.flatMap { l in
            self.elementsOf(env.view).first { $0.accessibilityLabel == l }
        })
        XCTAssertTrue(sys.accessibilityActivate())
        XCTAssertTrue(env.wait { !env.labels().contains(MessagesText.reply) && env.labels().contains(MessagesText.open) },
                      env.labels().joined(separator: "\n"))
    }

    private func elementsOf(_ v: UIView) -> [NSObject] { elements(v) }

    // MARK: Bilder

    /// Mit UF_SCREENSHOT_DIR (xcodebuild: TEST_RUNNER_UF_SCREENSHOT_DIR): Antwortfenster mit Zitat, hell und dunkel
    func testScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("nur mit UF_SCREENSHOT_DIR")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.install(post: Self.created)
        let m = model(defaults: try defaults(), mode: .all)
        m.text = "Hallo Frau Test,\n\ndanke für die Info. Gibt es einen Ersatztermin?\n\nViele Grüße"
        m.quote = true
        let root = host(MessageReplySheet(model: m))
        XCTAssertNotNil(waitFor(root, label: "An Anna Beispiel"), "\(labels(root))")
        for (style, tone) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
            root.window?.overrideUserInterfaceStyle = style
            pump(0.8)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let png = UIGraphicsImageRenderer(bounds: root.bounds, format: format).pngData { _ in
                _ = root.drawHierarchy(in: root.bounds, afterScreenUpdates: true)
            }
            try png.write(to: dir.appendingPathComponent("antworten-fenster-\(tone).png"))
        }
    }

    // MARK: Nachbildung

    /// Die Debug-Nachbildung (`-UFLoginStub`) spielt das Antworten durch: Posteingang, Namen, POST mit 201
    func testDebugStubPlaysReply() throws {
        let stub = DebugStubTransport(directory: ContainerTestBed.stubDirectory)
        let c = StudIPClient(base: StudIPSync.base, transport: stub, pauseMillis: 0)
        let ctx = try awaiting { try await c.replyContext(messageID: "stub-m1") }
        XCTAssertEqual(ctx.sender.name, "Dr. Beispiel Dozentin")
        XCTAssertEqual(ctx.otherRecipientIDs, ["u-stub-kommilitonin"])
        let names = try awaiting { try await c.recipientNames(ctx.otherRecipientIDs) }
        XCTAssertEqual(names.map(\.name), ["Erfundene Kommilitonin"])
        let id = try awaiting { try await c.sendMessage(subject: "RE: Tutorium", text: "Danke", recipientIDs: [ctx.sender.id]) }
        XCTAssertEqual(id, "stub-gesendet")
        XCTAssertThrowsError(try awaiting { try await c.replyContext(messageID: "stub-m2") }) { e in
            XCTAssertEqual(e as? StudIPMessageError, .systemMessage)
        }
    }
}

/// Zaehler fuer Stub-Antworten (Lade-Thread von URLSession)
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}
