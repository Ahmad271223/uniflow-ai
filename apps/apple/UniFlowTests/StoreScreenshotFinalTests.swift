import PencilKit
import StoreKitTest
import SwiftUI
import UIKit
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Endgueltiger Satz der App-Store-Bildschirmfotos fuer Version 1.0 (Build 11) **mit Pro AI** (Entscheidung des
/// Inhabers 07.11.2026): zehn Bilder im Hochformat, je Motiv genau eine Fassung hell oder dunkel, Dateien
/// `<nn>-<name>-<light|dark>.png` (2064 x 2752). Reihenfolge und Inhalt: docs/release/SCREENSHOTS.md (Abschnitt
/// "Endgueltiger Satz").
///
/// Tobi hat den Tarif **Pro AI** (Seitenleiste "Pro AI", kein "Pro AI holen"), die KI antwortet ueber die
/// StudiNow-KI mit Credits (Kostenzeile "StudiNow-KI · – 2 Credits (86 übrig)", Stand aus einem Schein-Dienst,
/// Rahmen 100 Credits wie `app/plans.py`), nie ueber ein eigenes ChatGPT. Die KI-Antworten kommen aus einem
/// Schein-Transport vor dem lokalen Backend (`StoreScreenshotTests.Intercept`), darum fragt kein Einwilligungs-Blatt
/// (die Einwilligung gilt als gegeben). Uebrige Technik wie `StoreScreenshotV11Tests`: ganze App-Huelle, Fenster
/// 1032 x 1376 Punkte bei Massstab 2, Demo-Inhalte mit Rufname "Tobi", Uni-Mail aus `DemoSOGo`, Lehrende und
/// Bescheinigungen aus `installV11Extras`, Raumfinder und Mensa aus den Testdaten des lokalen Backends. Neu nur hier:
/// KI-Karteikarten (Stapel "KI-Karten aus Skript Kapitel 1" ueber `/api/flashcards`) und die Diskussion einer
/// Modul-Community (`DemoCommunity`: erfundene Fragen und Antworten unter Pseudonym). "Hallo Tobi" unabhaengig von
/// der Uhrzeit ueber `UFGreeting.hourOverride` (nur `#if DEBUG`).
///
/// Mit UF_SCREENSHOT_DIR (xcodebuild: TEST_RUNNER_UF_SCREENSHOT_DIR) schreibt der Test die PNGs dorthin; ohne prueft
/// er nur, dass jede Ansicht mit den erfundenen Inhalten erscheint und dass nirgends "ChatGPT", "Pro AI holen" oder
/// das Einwilligungs-Blatt steht.
@MainActor
final class StoreScreenshotFinalTests: XCTestCase {

    private static let portrait = CGSize(width: 1032, height: 1376)
    static let demoName = "Tobi"
    /// Stand der Credits vor der Frage (Pro AI: 100 im Monat) und die Kosten der Antwort
    static let creditsBefore = 88
    static let charged = 2

    private var bed: ContainerTestBed!
    private var manager: ContainerManager!
    private var account: AccountStore!
    private var container: ActiveContainer!
    private var uniMail: UniMailConnection!
    private var studinow: StudoraAccountLink!
    private var outDir: URL?
    private var lectureID = 0

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = true
        bed = try ContainerTestBed(name: "shotsfinal", clock: .system)
        UniStubProtocol.install { _ in UniStubProtocol.Reply(status: 404) }          // jede Anfrage an eine Hochschule zaehlt
        UniMailConnection.readsDemoForScreenshots = true
        UFGreeting.hourOverride = 14                                               // "Hallo Tobi" (Wunsch des Inhabers)
        let sogo = StoreScreenshotV11Tests.DemoSOGo()
        manager = ContainerManager(
            base: bed.containers,
            legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
            keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock, publishesCurrent: true,
            uniMailTransport: { _ in sogo })
        account = bed.account(.luh)
        container = try bed.open(manager, account)
        account.markLoginDone()
        _ = try await manager.setDemo(true)
        XCTAssertTrue(manager.demoActive)
        try await StoreScreenshotTests.installStoreExtras(container.host)
        lectureID = try await StoreScreenshotV11Tests.installV11Extras(container, now: bed.clock.nowISO)
        Rufname.write(Self.demoName, container.defaults)
        MessagesInbox.shared.defaultsOverride = container.defaults
        await MessagesInbox.shared.refresh(api: container.api)
        Entitlements.shared.setPlanForTesting(.proAI)
        // StudiNow-Konto mit Credits (Schein-Dienst, nie ins Netz)
        studinow = StudoraAccountLink()
        let stub = InviteAppTests.StubTransport()
        for _ in 0..<8 { stub.on("GET", "/api/entitlements", 200, ["plan": "pro_ai", "credits": Self.balance(remaining: Self.creditsBefore)]) }
        studinow.attach(creditsClient: StudoraCredits.Client(base: "https://dienst.example", http: stub, tokens: InviteAppTests.MemoryTokens("tok")))
        await studinow.refreshCredits()
        XCTAssertEqual(studinow.credits?.remaining, Self.creditsBefore)
        let host = container.host
        let cloud = CloudKitCommunityService(
            cloud: StoreScreenshotTests.EmptyCloud(), university: .luh, membership: CommunityMembership(defaults: container.defaults),
            courseKeys: { [] }, courses: { await CommunityCourses.spaces(host: host, university: UniversityKey.luh.rawValue) })
        CommunityRoute.shared.service = DemoCommunity(inner: cloud)
        uniMail = try XCTUnwrap(manager.uniMail, "LUH hat Uni-Mail")
        uniMail.refreshesAfterSignIn = false
        let store = uniMail.websiteDataStore.httpCookieStore
        await store.setCookie(bed.cookie("0xHIGHFLYxSOGo", "erfundene-sitzung", domain: SOGoSite.luh.host, path: "/SOGo"))
        await store.setCookie(bed.cookie("XSRF-TOKEN", "erfunden", domain: SOGoSite.luh.host, path: "/SOGo"))
        uniMail.signedIn(user: StoreScreenshotV11Tests.mailUser)
        let report = await uniMail.refreshInbox()
        XCTAssertEqual(report.unseen, 2, "Posteingang der Nachbildung gelesen: \(report)")
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        if let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            outDir = url
        }
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        UniMailConnection.readsDemoForScreenshots = false
        UFFmt.todayOverride = nil
        UFGreeting.hourOverride = nil
        CommunityRoute.shared.service = nil
        Entitlements.shared.setPlanForTesting(.free)
        MessagesInbox.shared.defaultsOverride = nil
        await MessagesInbox.shared.refresh(api: nil)
        XCTAssertEqual(UniStubProtocol.requests.count, 0, "keine Anfrage an eine Hochschule")
        UniStubProtocol.reset()
        manager.deactivate()
        await bed.tearDown()
        try await super.tearDown()
    }

    // MARK: - Erfundene Inhalte (nur diese Bilder)

    /// `credits` wie `app/credits.py::_balance_dict` (Pro AI: 100 im Monat, neu am 1. Dezember)
    static func balance(remaining: Int, charged: Int? = nil) -> JSONValue {
        var v: [String: JSONValue] = ["period": "2026-11", "allowance": 100, "used": .number(Double(100 - remaining)), "reserved": 0,
                                      "remaining": .number(Double(remaining)), "plan": "pro_ai",
                                      "resets_at": "2026-12-01T00:00:00+01:00", "credit_eur": 0.01]
        if let charged { v["charged"] = .number(Double(charged)); v["replay"] = false }
        return .object(v)
    }

    /// Frage zur offenen Seite des Skripts und die Antwort der StudiNow-KI (erfunden, fachlich richtig)
    static let question = "Warum ist 13 im Dualsystem 1101?"
    static var tutorAnswer: JSONValue {
        ["answer": """
         **Stellenwerte im Dualsystem**

         Jede Stelle steht für eine Zweierpotenz – von rechts 1, 2, 4, 8. Du zerlegst 13 in diese Werte:

         - 13 = **8 + 4 + 1**
         - Stellen 8 · 4 · 2 · 1 → **1 · 1 · 0 · 1**
         - also **1101** im Dualsystem

         **Probe:** 1 · 8 + 1 · 4 + 0 · 2 + 1 · 1 = 13. Im Hexadezimalsystem ist 13 die Ziffer **D**.
         """,
         "cards": .null, "sources": [], "explain": .null,
         "credits": balance(remaining: creditsBefore - charged, charged: charged)]
    }

    /// Karten, die die KI aus dem Skript gemacht hat (die letzte erscheint in der Wiederholung zuerst)
    static let deckName = "KI-Karten aus Skript Kapitel 1"
    static let aiCards: [(String, String)] = [
        ("Woran erkennst du einen Überlauf im Zweierkomplement?",
         "Das Vorzeichen passt nicht: Zwei positive Zahlen ergeben eine negative (oder umgekehrt)."),
        ("Welcher Wertebereich passt mit 8 Bit ins Zweierkomplement?", "−128 bis 127."),
        ("Wie rechnest du 42 ins Dualsystem um?", "Fortgesetzt durch 2 teilen, die Reste von unten lesen: 42 = 32 + 8 + 2 = 101010."),
        ("Wie lautet 13 im Dual- und im Hexadezimalsystem?", "1101 (dual) und D (hexadezimal), denn 13 = 8 + 4 + 1."),
        ("Was ist der Stellenwert einer Ziffer im Dualsystem?", "Eine Zweierpotenz: von rechts 1, 2, 4, 8, 16 …"),
        ("Wie bildest du das Zweierkomplement von −37 mit 8 Bit?",
         "37 dual: 0010 0101. Alle Bits invertieren: 1101 1010. Dann 1 addieren: 1101 1011."),
    ]

    /// Community des Demo-Moduls mit Diskussion: die Kurse wie CloudKit (leere Wolke), der Demo-Kurs beigetreten,
    /// erfundene Fragen und Antworten unter Pseudonym. Schreibt nichts.
    final class DemoCommunity: CommunityService, @unchecked Sendable {
        let inner: CommunityService
        init(inner: CommunityService) { self.inner = inner }

        var isConnected: Bool { true }
        var supportsSpaceDiscussion: Bool { true }

        func communities() async throws -> [CommunitySpace] {
            try await inner.communities().map { s in
                var s = s
                if s.kind == .course && s.name.contains("Grundlagen der Informatik") { s.joined = true }
                return s
            }
        }
        func join(_ space: CommunitySpace) async throws {}
        func leave(_ space: CommunitySpace) async throws {}
        func solutions(in space: CommunitySpace) async throws -> [CommunitySolutionSummary] { [] }
        func posts(in space: CommunitySpace) async throws -> [CommunityPost] { Self.posts() }
        func setPostLiked(in space: CommunitySpace, postID: String, _ liked: Bool) async throws -> Int {
            Self.posts().first { $0.id == postID }?.likes ?? 0
        }
        func publish(_ package: SolutionPackage, options: CommunityPublishOptions) async throws -> CommunityPublication {
            throw CommunityServiceError.notConnected
        }
        func findMatching(fingerprint: String) async throws -> [CommunitySolutionSummary] { [] }
        func download(solutionID: String) async throws -> SolutionPackage { throw CommunityServiceError.notConnected }
        func withdraw(solutionID: String) async throws {}
        func report(solutionID: String, reason: CommunityReportReason, note: String?) async throws {}

        static let threadID = "demo-q1"

        /// Zeit relativ zu jetzt (ISO, UTC) fuer "vor 2 Stunden"
        static func ago(_ minutes: Double) -> String {
            ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutes * 60))
        }

        static func posts() -> [CommunityPost] {
            func c(_ id: String, _ parent: String?, _ who: String, _ text: String, _ minutes: Double) -> CommunityComment {
                CommunityComment(id: id, parentID: parent, pseudonym: who, text: text, createdAt: ago(minutes))
            }
            return [
                CommunityPost(question: c(threadID, nil, "Zahlenfuchs",
                                          "Frage zu Aufgabe 3 auf Blatt 1: Wie bilde ich das Zweierkomplement von −37 mit 8 Bit? Ich komme auf 1101 1010.", 125),
                              replies: [c("demo-q1-a1", threadID, "Bitwise_Bea",
                                          "Fast! 37 ist 0010 0101, invertiert 1101 1010 – dann fehlt noch +1: 1101 1011.", 104),
                                        c("demo-q1-a2", threadID, "Lerneule",
                                          "Probe: −128 + 64 + 16 + 8 + 2 + 1 = −37. Passt also.", 92),
                                        c("demo-q1-a3", threadID, "Zahlenfuchs", "Danke euch, das +1 hatte ich vergessen!", 80)],
                              likes: 7),
                CommunityPost(question: c("demo-q2", nil, "Mo_Info",
                                          "Kommt in der Klausur auch Hexadezimal dran oder nur das Dualsystem?", 300),
                              replies: [c("demo-q2-a1", "demo-q2", "Lerneule",
                                          "Im Skript stehen beide Umrechnungen, ich würde beides üben.", 280)],
                              likes: 4),
                CommunityPost(question: c("demo-q3", nil, "Kaffeebit",
                                          "Lust, Mittwoch nach der Übung zusammen Blatt 2 zu rechnen? Treffpunkt vor Seminarraum 3.", 1500),
                              likes: 3),
            ]
        }
    }

    // MARK: - Hosten, Warten, Fotografieren

    /// Ganze App-Huelle mit Demo-Inhalten, Uni-Mail und Pro AI; die KI antwortet ueber die StudiNow-KI (Credits)
    private func host<V: View>(_ view: V, api: APIClient? = nil) throws -> HostedEnvironment {
        let root = view
            .environment(\.ufDemoActive, true)
            .environment(\.ufDemoBarHidden, true)
            .environment(\.ufAIEnabled, true)
            .environment(\.ufStudiNowAI, true)
            .environment(\.ufAIAccess, .ready)
            .environment(\.ufStudoraAccount, studinow)
            .environment(\.uniMail, uniMail)
            .environmentObject(manager!)
            .environmentObject(account!)
        return try hostWithEnvironment(root, api: api ?? container.api, size: Self.portrait, studip: manager.studip)
    }

    private func aiTransport() -> StoreScreenshotTests.Intercept {
        let t = StoreScreenshotTests.Intercept(container.host)
        t.answer("/api/ai/tutor", Self.tutorAnswer)
        t.answer("/api/tests/18", StoreScreenshotTests.demoTest)
        return t
    }

    /// Prueft das Bild (kein ChatGPT, kein "Pro AI holen", kein Einwilligungs-Blatt, nichts laedt) und schreibt genau
    /// eine Datei `<name>-<tone>.png` im Hochformat
    private func shoot(_ env: HostedEnvironment, _ name: String, tone: String, ink: Bool = false, settle: Double = 1.0,
                       shell: Bool = true, present: (() -> Void)? = nil, sheetReady: @escaping () -> Bool = { true }) {
        check(env, name, shell: shell)
        guard let outDir else { return }
        StoreScreenshotTests.shoot(env, name, folder: outDir, sizes: [(Self.portrait, "portrait")], scale: 2, ink: ink, settle: settle,
                                   present: present, sheetReady: sheetReady, tones: [tone], fileName: { t, _ in "\(name)-\(t).png" })
        if present != nil { check(env, name + " (Blatt)", shell: false) }
    }

    private func check(_ env: HostedEnvironment, _ name: String, shell: Bool) {
        for word in ["ChatGPT", "Pro AI holen", AIConsentText.title, AIConsentText.accept, "wird geladen", "werden geladen"] {
            XCTAssertFalse(shows(env, word), "\(name): „\(word)“ im Bild:\n" + dump(env))
        }
        if shell { XCTAssertTrue(shows(env, "Tarif Pro AI"), "\(name): Seitenleiste nennt Pro AI:\n" + dump(env)) }
    }

    private func elements(in view: UIView) -> [NSObject] {
        view.layoutIfNeeded()
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: Any, depth: Int) {
            guard depth < 60 else { return }
            if let o = element as? NSObject {
                guard seen.insert(ObjectIdentifier(o)).inserted else { return }
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

    private func texts(_ env: HostedEnvironment) -> [String] {
        var all = elements(in: env.window)
        if let sheet = env.hosting.presentedViewController?.view { all += elements(in: sheet) }
        return all.flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
    }

    private func shows(_ env: HostedEnvironment, _ text: String) -> Bool { texts(env).contains { $0.contains(text) } }

    private func dump(_ env: HostedEnvironment) -> String { texts(env).joined(separator: "\n") }

    @discardableResult
    private func tap(_ label: String, in env: HostedEnvironment, exact: Bool = true) -> Bool {
        for e in elements(in: env.window) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, exact ? l == label : l.hasPrefix(label) else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    @discardableResult
    private func expect(_ env: HostedEnvironment, _ text: String, timeout: Double = 15, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let ok = env.wait(timeout: timeout) { self.shows(env, text) }
        XCTAssertTrue(ok, "„\(text)“ fehlt:\n" + dump(env), file: file, line: line)
        return ok
    }

    /// Asynchrone Arbeit bei laufender Hauptschleife (wie `StoreScreenshotV11Tests.pumping`)
    private func pumping(_ timeout: Double = 30, _ body: @escaping @MainActor () async throws -> Void) {
        var done = false
        var failure: String?
        Task { @MainActor in
            do { try await body() } catch { failure = "\(error)" }
            done = true
        }
        let end = Date().addingTimeInterval(timeout)
        while !done && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(done, "nicht fertig")
        XCTAssertNil(failure, failure ?? "")
    }

    private func waitForInk(_ env: HostedEnvironment, count: Int = 1, file: StaticString = #filePath, line: UInt = #line) {
        let ok = env.wait(timeout: 25) { StoreScreenshotTests.canvases(in: env.view).filter { !$0.drawing.strokes.isEmpty }.count >= count }
        XCTAssertTrue(ok, "Editor zeigt die Notizen nicht:\n" + dump(env), file: file, line: line)
        env.pump(2.0)
    }

    /// Text in das Eingabefeld mit dieser Beschriftung tippen wie mit der Tastatur
    private func type(_ text: String, intoFieldLabelled label: String, in env: HostedEnvironment) -> Bool {
        var fields: [UIView] = []
        func visit(_ v: UIView) {
            if v is UITextView || v is UITextField { fields.append(v); return }
            v.subviews.forEach(visit)
        }
        visit(env.window)
        let field = fields.first { $0.accessibilityLabel == label } ?? fields.last { $0 is UITextView } ?? fields.last
        guard let field, let input = field as? UIKeyInput else { return false }
        _ = field.becomeFirstResponder()
        input.insertText(text)
        env.pump(0.3)
        return true
    }

    // MARK: - Endgueltiger Satz (01-10)

    /// 1 Uebersicht hell: "Hallo Tobi – lass uns gemeinsam lernen.", Pruefungsanmeldung, Lernpaket, Seitenleiste Pro AI
    func test01Uebersicht() throws {
        let env = try host(MainView())
        expect(env, "Hallo " + Self.demoName + " – lass uns gemeinsam lernen.")
        expect(env, "Grundlagen der Informatik")
        expect(env, "Uni-Mail")
        XCTAssertFalse(shows(env, DemoTexts.barTitle), "ohne Demo-Leiste")
        if outDir != nil { expect(env, "Prüfungsanmeldung") }                     // nur im Meldezeitraum (Bilder: 09.–22.11.2026)
        env.pump(1.0)
        shoot(env, "01-uebersicht", tone: "light")
    }

    /// 2 Skript mit Handschrift, KI-Hilfe offen: Frage zur Seite und Antwort der StudiNow-KI, Kostenzeile mit Credits
    func test02KIFrage() throws {
        StoreScreenshotTests.seedNotesPumping("demo-skript", api: container.api)
        let t = aiTransport()
        let env = try host(MainView(), api: APIClient(base: APIClient.localBase, transport: t))
        env.router.tutorOpenRequest = "demo-skript"                               // wie "Im Dokument mit KI-Hilfe öffnen"
        env.router.go(.doc("demo-skript"))
        waitForInk(env)
        expect(env, "Frag etwas zur Seite")
        XCTAssertTrue(type(Self.question, intoFieldLabelled: "Frag etwas zur Seite …", in: env), dump(env))
        XCTAssertTrue(env.wait { self.tap("Senden", in: env) }, "Senden:\n" + dump(env))
        XCTAssertTrue(env.wait(timeout: 15) { t.count("/api/ai/tutor") == 1 }, "Frage gesendet")
        expect(env, "Stellenwerte im Dualsystem")
        env.window.endEditing(true)
        let footer = "Seite 1 · StudiNow-KI · – \(Self.charged) Credits (\(Self.creditsBefore - Self.charged) übrig)"
        expect(env, footer)
        env.pump(1.5)
        shoot(env, "02-ki-frage", tone: "dark", ink: true, settle: 1.5, shell: false)
    }

    /// 3 Karteikarten, die die KI aus dem Skript gemacht hat: Stapel "KI-Karten aus Skript Kapitel 1" in der
    /// Wiederholung, eine Karte aufgedeckt (Frage und Antwort)
    func test03KIKarteikarten() throws {
        let api = container.api
        pumping {
            // zuerst die Stapel lesen: die Demo-Karten ohne Stapel landen dabei in ihren eigenen Stapeln, nicht im neuen
            _ = try await api.value("/api/flashcard-stacks")
            let cards: [JSONValue] = Self.aiCards.map { ["question": .string($0.0), "answer": .string($0.1)] }
            let r = try await api.value("/api/flashcards", method: "POST",
                                        body: ["file_id": "demo-skript", "stack_name": .string(Self.deckName), "cards": .array(cards)])
            XCTAssertEqual(r["count"]?.int, Self.aiCards.count)
            // Art wie das Skript (Vorlesung, gruen), so wie KI-Karten aus einem eingeordneten Dokument
            let id = try XCTUnwrap(r["stack_id"]?.int)
            _ = try await api.value("/api/flashcard-stacks/\(id)", method: "PATCH", body: ["kind": "vorlesung"])
        }
        let env = try host(MainView())
        env.router.go(.cards)
        expect(env, "Stapel öffnen: " + Self.deckName)
        expect(env, "Üben: " + Self.deckName)
        XCTAssertTrue(tap("Üben: " + Self.deckName, in: env), dump(env))
        expect(env, "Antwort zeigen")
        XCTAssertTrue(tap("Antwort zeigen", in: env), dump(env))
        expect(env, "Antwort: 37 dual")
        expect(env, "Heute fällig (\(Self.aiCards.count))")
        env.pump(1.5)
        shoot(env, "03-ki-karteikarten", tone: "light", settle: 1.5)
    }

    /// 4 Community des Demo-Moduls, Reiter "Diskussion": Frage mit drei Antworten (Blatt), Likes und Antwortzahlen
    func test04CommunityDiskussion() throws {
        let service = try XCTUnwrap(CommunityRoute.shared.service)
        var key = ""
        pumping { key = try await service.communities().first { $0.joined }?.key ?? "" }
        XCTAssertFalse(key.isEmpty, "Community des Demo-Moduls")
        let env = try host(MainView())
        env.router.go(.communitySpace(key))
        expect(env, "Fragen und Antworten")
        expect(env, "Frage von Zahlenfuchs")
        expect(env, "Frage von Mo_Info")
        env.pump(1.5)
        let open = { _ = self.tap("Frage von Zahlenfuchs", in: env, exact: false) }
        let ready = { self.shows(env, "3 Antworten") && self.shows(env, "Probe: −128") && self.shows(env, "Danke euch") }
        shoot(env, "04-community-diskussion", tone: "dark", settle: 1.0, present: open, sheetReady: ready)
        if outDir == nil {
            open()
            XCTAssertTrue(env.wait { ready() }, "Antworten im Blatt:\n" + dump(env))
        }
    }

    /// 5 Uni-Mail: Posteingang (acht erfundene Mails) und die Mail einer erfundenen Dozentin mit Anhang
    func test05UniMail() throws {
        let env = try host(MainView())
        env.router.go(.uniMail)
        expect(env, "8 E-Mails")
        env.pump(1.5)
        XCTAssertTrue(tap("Ungelesen, Prof. Dr. Anna Beispiel", in: env, exact: false), dump(env))
        expect(env, "Anhang Probeklausur_GdI.pdf öffnen oder teilen")
        expect(env, "Antworten")
        env.pump(2.5)
        shoot(env, "05-uni-mail", tone: "light", settle: 2.0)
    }

    /// 6 Stundenplan mit Termin-Detail: Raum mit Route zu Fuss, Lehrende mit E-Mail und Sprechstunde
    func test06StundenplanTermin() throws {
        let env = try host(MainView())
        env.router.go(.timetable())
        expect(env, "Stundenplan")
        env.pump(1.0)
        env.overlay.openDrawer { EventDrawer(eventID: self.lectureID, date: StoreScreenshotV11Tests.dayThisWeek(3)) }
        expect(env, "Prof. Dr. Anna Beispiel")
        expect(env, "E-Mail an jonas.muster@example.org")
        expect(env, TerminDetailText.routeLabel("Hörsaal A"))
        expect(env, TerminDetailText.writeAll)
        env.pump(1.0)
        shoot(env, "06-stundenplan-termin", tone: "light")
    }

    /// 7 Geteilte Ansicht: Skript und Uebungsblatt nebeneinander, beide mit Apple-Pencil-Notizen
    func test07SkriptUebungStift() throws {
        StoreScreenshotTests.seedNotesPumping("demo-blatt", api: container.api)
        StoreScreenshotTests.seedNotesPumping("demo-skript", api: container.api)
        var state = ResumeState.forRoute(.doc("demo-blatt"))
        state.companionID = "demo-skript"
        let data = try JSONEncoder().encode(state)
        let env = try host(MainView())
        env.pump(0.5)
        let api = container.api, defaults = container.defaults
        pumping {
            defaults.set(data, forKey: ResumeState.lastKey)
            await env.router.resume.restoreIfNeeded(api: api, router: env.router)
        }
        XCTAssertEqual(env.router.route, .doc("demo-blatt"))
        waitForInk(env, count: 2)
        expect(env, "Teilung beenden")
        shoot(env, "07-skript-uebung-stift", tone: "dark", ink: true, settle: 1.5, shell: false)
    }

    /// 8 Wochentest mit Auswertung der KI: Punkte, Erklaerung und Rueckmeldung je Aufgabe, "Nochmal anschauen"
    func test08WochentestKI() throws {
        let t = aiTransport()
        let env = try host(MainView(), api: APIClient(base: APIClient.localBase, transport: t))
        env.router.go(.exam(18, task: nil))
        expect(env, "Punkte")
        expect(env, "Hexadezimalsystem")
        env.pump(1.0)
        shoot(env, "08-wochentest-ki", tone: "dark")
    }

    /// 9 Raumfinder: Suche "F102", Treffer, darueber das Detail mit Google Maps, Route und Apple Karten
    func test09Raumfinder() throws {
        let env = try host(MainView())
        env.router.go(.rooms)
        expect(env, "Raumfinder")
        _ = env.wait { self.tap("F102", in: env) }
        expect(env, "1 Treffer")
        env.pump(1.0)
        let open = { XCTAssertTrue(self.tap("Raum F102", in: env, exact: false), self.dump(env)) }
        let ready = { self.shows(env, "In Google Maps öffnen") && self.shows(env, "Route zu Fuß in Google Maps") }
        shoot(env, "09-raumfinder", tone: "light", present: open, sheetReady: ready)
        if outDir == nil {
            open()
            XCTAssertTrue(env.wait { ready() }, dump(env))
        }
    }

    /// 10 Mensa: Speiseplan (erfunden) an einem Werktag; am Wochenende der naechste Montag als "heute"
    func test10Mensa() throws {
        UFFmt.todayOverride = StoreScreenshotV11Tests.nextServiceDay()
        let env = try host(MainView())
        env.router.go(.mensa)
        expect(env, "Gemüse-Kichererbsen-Curry mit Reis")
        expect(env, "Hähnchenbrust mit Kräuterkartoffeln")
        XCTAssertFalse(shows(env, "Geschlossen"), "Werktag mit Speiseplan:\n" + dump(env))
        env.pump(1.0)
        shoot(env, "10-mensa", tone: "light")
    }

    // MARK: - App Review (Abos in App Store Connect)

    /// Bild fuer die App-Pruefung der beiden Abos: Blatt "Tarif wechseln" (Einstellungen -> Zugang & Darstellung ->
    /// Tarif) hell, hoch und quer, Dateien `tarif-portrait.png` (2064 x 2752) und `tarif-landscape.png` (2752 x 2064).
    /// Produkte aus der StoreKit-Testkonfiguration `UniFlow.storekit` (Plus 1,99 €, Pro AI 3,99 €), ohne Kauf: beide
    /// Kaufknoepfe, kein Hinweis "Pro AI folgt …", nichts laedt. Die Seite ist hoeher als ein Bildschirm (zwei Spalten,
    /// Pro AI darunter); damit alle drei Karten mit Knoepfen und "Käufe wiederherstellen" ganz im Bild sind, ist das
    /// Fenster so gross wie die ganze Seite im Seitenverhaeltnis 3:4 bzw. 4:3 und wird auf die Pixelgroesse gerechnet.
    func testTarifPruefung() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "UniFlow", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.resetToDefaultState()
        defer { withExtendedLifetime(session) {} }
        Entitlements.shared.setPlanForTesting(.free)
        let env = try host(ZStack { UF.bg.ignoresSafeArea(); PlanPickerView(context: .settings, entitlements: Entitlements.shared) {} })
        let plusButton = UFPlan.plus.name + " für 1,99", proAIButton = UFPlan.proAI.name + " für 3,99"
        expect(env, PlanPickerView.title(.settings))
        expect(env, UFPlan.free.name)
        expect(env, plusButton)
        expect(env, proAIButton)
        expect(env, "Käufe wiederherstellen")
        env.pump(1.0)
        func checkPage(_ name: String) {
            for word in [UFPlanCatalog.proAIMissingNote, "Preis zurzeit nicht verfügbar", "Tarife konnten nicht geladen werden",
                         "wird geladen", "werden geladen", "Pro AI holen", "Vorgemerkt"] {
                XCTAssertFalse(shows(env, word), "\(name): „\(word)“ im Bild:\n" + dump(env))
            }
            for word in [plusButton, proAIButton, "Käufe wiederherstellen"] {
                XCTAssertTrue(shows(env, word), "\(name): „\(word)“ fehlt:\n" + dump(env))
            }
        }
        checkPage("tarif")
        guard let outDir else { return }
        func scrollViews(_ v: UIView) -> [UIScrollView] { ((v as? UIScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrollViews) }
        let page = try XCTUnwrap(scrollViews(env.view).max { $0.contentSize.height < $1.contentSize.height }, "keine Seite")
        let contentHeight = page.contentSize.height
        // Seitenverhaeltnis 3:4 bzw. 4:3 in Einheiten von k Punkten, 688 Pixel je Einheit (2064 = 3 · 688, 2752 = 4 · 688)
        for (orientation, w, h) in [("portrait", 3.0, 4.0), ("landscape", 4.0, 3.0)] {
            let k = max(344, ((contentHeight + 8) / h).rounded(.up))
            let size = CGSize(width: w * k, height: h * k)
            env.window.overrideUserInterfaceStyle = .light
            env.window.frame = CGRect(origin: .zero, size: size)
            env.view.frame = env.window.bounds
            env.pump(1.5)
            XCTAssertLessThanOrEqual(page.contentSize.height, page.bounds.height + 0.5, "\(orientation): Seite passt nicht ganz ins Bild")
            checkPage("tarif-\(orientation)")
            let image = StoreScreenshotTests.pageImage(env, scale: 688 / k, ink: false)
            let file = outDir.appendingPathComponent("tarif-\(orientation).png")
            do { try XCTUnwrap(image.pngData()).write(to: file) } catch { XCTFail("\(file.lastPathComponent): \(error)") }
            let cg = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(CGSize(width: cg.width, height: cg.height), CGSize(width: w * 688, height: h * 688), file.lastPathComponent)
            print("tarif-\(orientation): Seite \(contentHeight) pt, Fenster \(size), Massstab \(688 / k)")
        }
        env.window.overrideUserInterfaceStyle = .unspecified
        env.window.frame = CGRect(origin: .zero, size: Self.portrait)
        env.view.frame = env.window.bounds
        env.pump(0.2)
    }
}
