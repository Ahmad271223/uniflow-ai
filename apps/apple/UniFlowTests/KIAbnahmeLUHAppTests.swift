import StoreKitTest
import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// KI-Abnahme Version 1.0 im Release-Stand (nur LUH, 07.11.2026, Auftrag des Inhabers "KI fertig fuer LUH"): jede
/// KI-Funktion Ende-zu-Ende mit der echten Wurzel der App (`RootView`), dem echten Container mit Demo-Inhalten, dem
/// echten lokalen Backend und dem echten Weg der KI - nur die Gegenstellen sind Attrappen:
/// - eigenes ChatGPT: `OpenAIKeySession` ueber einen Schein-OpenAI (kein Netz, kein echter Schluessel)
/// - StudiNow-KI (Pro AI, Probe): `StudoraAccountLink` mit Dienst-Adresse `https://dienst.example` (Startargument
///   `StudoraServiceURL`), alle Anfragen beantwortet `KIServiceStub` (URLProtocol), Kauf ueber StoreKitTest
/// Je Station: Antwort sichtbar, Formeln lesbar (x²), keine Woerter aus anderen Hochschulen oder "bald verfügbar",
/// Fehler mit verstaendlichem Text. Mit UF_KI_DIR (xcodebuild: TEST_RUNNER_UF_KI_DIR) je Station ein Bild.
@MainActor
final class KIAbnahmeLUHAppTests: XCTestCase {
    static let key = "sk-proj-ERFUNDEN-abcdefghijklmnopqrstuvwxyz0123"
    static let forbidden = ["Hildesheim", "HsH", "Moodle", "Learnweb", "HISinOne", "in Vorbereitung", "bald verfügbar",
                            "Bald verfügbar", "Mit ChatGPT anmelden", "folgt mit dem StudiNow-Dienst"]
    static let size = CGSize(width: 1180, height: 820)

    /// Antwort der KI mit Formel (MathText macht daraus "x²", "½")
    static let tutorAnswer = "**Kurz erklärt:** Für die Folge gilt $a_n = x^2 + \\frac{1}{2}$, also wächst sie quadratisch."

    // MARK: Schein-OpenAI

    enum Mode: Sendable { case ok, badKey, quota, rate, timeout, offline }

    actor FakeOpenAI: AIHTTPTransport {
        var mode: Mode = .ok
        var requests: [AIHTTPRequest] = []
        func set(_ m: Mode) { mode = m }
        func count(_ url: String) -> Int { requests.filter { $0.url == url }.count }
        var last: AIHTTPRequest? { requests.last }

        func send(_ request: AIHTTPRequest) async throws -> (status: Int, body: Data) {
            requests.append(request)
            switch mode {
            case .timeout: throw URLError(.timedOut)
            case .offline: throw URLError(.notConnectedToInternet)
            case .badKey: return (401, Data(#"{"error": {"message": "Incorrect API key provided", "code": "invalid_api_key"}}"#.utf8))
            case .quota: return (429, Data(#"{"error": {"message": "You exceeded your current quota, please check your plan and billing details.", "code": "insufficient_quota"}}"#.utf8))
            case .rate: return (429, Data(#"{"error": {"message": "Rate limit reached", "code": "rate_limit_exceeded"}}"#.utf8))
            case .ok: break
            }
            guard request.headers["Authorization"] == "Bearer \(KIAbnahmeLUHAppTests.key)" else { return (401, Data()) }
            if request.url == ChatGPTConstants.modelsURL {
                return (200, JSONValue.object(["data": [["id": "gpt-4o"], ["id": "gpt-4o-mini"]]]).serialized())
            }
            let body = (try? JSONValue.parse(request.body ?? Data())) ?? .null
            let system = body["instructions"]?.string ?? ""
            let input = body["input"]?.array?.first?["content"]
            let prompt = input?.string ?? input?.array?.compactMap { $0["text"]?.string }.joined(separator: "\n") ?? ""
            let text = KIAbnahmeLUHAppTests.reply(system: system, prompt: prompt, schema: body["text"]?["format"] != nil)
            let done: JSONValue = ["type": "response.completed", "response": ["model": "gpt-4o-mini", "output": [["type": "message", "content": [["type": "output_text", "text": .string(text)]]]]]]
            return (200, Data("event: response.completed\ndata: \(String(decoding: done.serialized(), as: UTF8.self))\n\n".utf8))
        }
    }

    /// Antwort je Aufgabe (erkannt am Prompt): Karteikarten, Lernplan, Index, Wochentest, Bewertung, sonst KI-Hilfe
    nonisolated static func reply(system: String, prompt: String, schema: Bool) -> String {
        if prompt.contains("LERNTAGE") {
            let date = prompt.range(of: #"\n- \d{4}-\d{2}-\d{2}"#, options: .regularExpression).map { String(prompt[$0].dropFirst(3)) } ?? "2026-11-09"
            let module = prompt.components(separatedBy: "\n").first { $0.hasPrefix("## ") }
                .map { String($0.dropFirst(3)).components(separatedBy: " (Prioritaet").first ?? "" } ?? ""
            return JSONValue.object(["blocks": [["date": .string(date), "module": .string(module), "title": "Zahlensysteme wiederholen",
                                                 "minutes": 45, "why": "Lehrwoche 1 ist offen; 2³ = 8 üben.",
                                                 "tasks": [["type": "lesen", "title": "Skript Kapitel 1 lesen", "file": .null, "minutes": 30]]]]]).jsonString()
        }
        if system.contains("Bibliothekar") {
            return JSONValue.object(["summary": "Zahlensysteme: 13 = 1101₂.", "terms": ["Dualsystem"],
                                     "elements": [["order": 1, "type": "definition", "title": "Dualsystem", "explanation": "Basis 2, z. B. 2³ = 8.",
                                                   "position": "oben", "task": .null, "uncertain": false]],
                                     "tasks": []]).jsonString()
        }
        if prompt.contains("Karteikarten") && schema {
            return JSONValue.object(["cards": [["question": "Was ist $2^3$?", "answer": "$2^3 = 8$"],
                                               ["question": "Wie lautet 13 im Dualsystem?", "answer": "1101"],
                                               ["question": "Was ist $x^2$ für x = 3?", "answer": "9"]]]).jsonString()
        }
        if prompt.contains("Genau 15 Aufgaben") {
            let diffs = Array(repeating: "leicht", count: 4) + Array(repeating: "mittel", count: 6) + Array(repeating: "schwer", count: 5)
            let qs: [JSONValue] = diffs.enumerated().map { i, d in
                ["nr": .number(Double(i + 1)), "type": i == 0 ? "mc" : "calc", "difficulty": .string(d),
                 "question": .string(i == 0 ? "Was ist 2³?" : "Berechne x² für x = \(i + 1)."), "options": i == 0 ? ["A 6", "B 8"] : .null,
                 "answer": i == 0 ? "B" : .string("\((i + 1) * (i + 1))"), "explanation": "Weil x² = x · x.", "points": .number(i < 10 ? 6 : 8),
                 "exam_style": false]
            }
            return JSONValue.object(["title": "Wochentest Zahlensysteme", "questions": .array(qs)]).jsonString()
        }
        if prompt.contains("Bewerte diesen Wochentest") {
            return JSONValue.object(["total": 6, "max": 96, "per_question": [["nr": 1, "points": 6, "max": 6, "feedback": "Richtig: 2³ = 8."]],
                                     "summary": "Gut begonnen. Übe x² weiter.", "weak_topics": ["Potenzen"]]).jsonString()
        }
        return tutorAnswer
    }

    // MARK: Aufbau

    private var bed: ContainerTestBed!
    private var manager: ContainerManager!
    private var account: AccountStore!
    private var container: ActiveContainer?
    private var background: BackgroundSyncController!
    private var outDir: URL?
    private var findings: [String] = []
    private var fake = FakeOpenAI()
    private let overlay = UFOverlay()

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = true
        UFReleaseUniversities.shipped = UFReleaseUniversities.storeDefault
        bed = try ContainerTestBed(name: "ki-abnahme", clock: .system)
        manager = ContainerManager(
            base: bed.containers,
            legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
            keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock, publishesCurrent: true)
        account = AccountStore(secrets: ContainerTestBed.MemorySecrets(), defaults: bed.defaults, checker: ContainerTestBed.Authorized(),
                               observeRevocation: false)
        background = BackgroundSyncController(containers: manager, account: account, settings: BackgroundSyncSettings(defaults: bed.defaults))
        Entitlements.shared.setPlanForTesting(.free)
        Entitlements.shared.useLocalTrial(startedAt: nil)
        Entitlements.shared.ownChatGPTConnected = false
        UFGreeting.hourOverride = 12
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true))
        if let dir = ProcessInfo.processInfo.environment["UF_KI_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            outDir = url
        }
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        UserDefaults.standard.removeObject(forKey: StudoraAccountLink.serviceURLKey)
        URLProtocol.unregisterClass(KIServiceStub.self)
        KIServiceStub.reset()
        UFGreeting.hourOverride = nil
        if let bed { OpenAIKeyKeychainStore.remove(userScope: DataContainerKey.userScope(bed.user)) }
        if let bed { _ = KeychainStore(service: StudoraAccountKeychain.service).remove(DataContainerKey.userScope(bed.user)) }
        // nichts fuer die naechsten Tests stehen lassen: Probe des Dienstes, Kauf aus StoreKitTest
        Entitlements.shared.useServiceTrial(nil)
        Entitlements.shared.useLocalTrial(startedAt: nil)
        await Entitlements.shared.refresh()
        Entitlements.shared.setPlanForTesting(.free)
        Entitlements.shared.ownChatGPTConnected = false
        manager?.onChange = nil
        manager?.deactivate()
        await bed?.tearDown()
        UFReleaseUniversities.reset()
        print("=== KI-Abnahme \(name) ===\n" + (findings.isEmpty ? "keine Befunde" : findings.joined(separator: "\n")))
        if let outDir {
            let safe = name.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
            try? (findings.joined(separator: "\n") + "\n").write(to: outDir.appendingPathComponent("befunde-\(safe).txt"), atomically: true, encoding: .utf8)
        }
        try await super.tearDown()
    }

    private struct Root: View {
        @ObservedObject var manager: ContainerManager
        @ObservedObject var account: AccountStore
        let background: BackgroundSyncController
        /// Dialoge wie in UniFlowApp innerhalb der KI-Umgebung (UFModalHost vor UFAIAccessProvider)
        let overlay: UFOverlay

        var body: some View {
            RootView()
                .modifier(UFModalHost(overlay: overlay))
                .environmentObject(overlay)
                .environment(\.qis, manager.qis)
                .environment(\.uniMail, manager.uniMail)
                .environment(\.ufChatGPTLink, manager.chatgpt)
                .environment(\.ufStudoraAccount, manager.account)
                .modifier(UFAIAccessProvider(chatgpt: manager.chatgpt, account: manager.account))
                .environment(\.backgroundSync, background)
                .environment(\.ufDemoActive, manager.demoActive)
                .environmentObject(manager.studip)
                .environmentObject(manager)
                .environmentObject(account)
        }
    }

    private func host() throws -> HostedEnvironment {
        let env = try hostWithEnvironment(Root(manager: manager, account: account, background: background, overlay: overlay),
                                          api: container?.api ?? .local(.unavailable), size: Self.size, studip: manager.studip)
        manager.onChange = { [weak session = env.session] c in session?.useLocal(c?.api ?? .local(.unavailable)) }
        env.pump(0.5)
        return env
    }

    /// LUH, Demo-Inhalte; der Schein-OpenAI haengt am Schluessel-Anschluss, bevor der Container ihn oeffnet
    private func openDemo() async throws {
        manager.chatgpt.apiKey.transport = fake
        account.signIn(userID: bed.user, name: "Ada Erfunden", email: nil, givenName: "Ada")
        account.markPlanShown()
        account.chooseUniversity(.luh)
        container = try bed.open(manager, account)
        account.markLoginDone()
        _ = try await manager.setDemo(true)
        XCTAssertTrue(manager.demoActive)
        Rufname.write("Ada", container!.defaults)
    }

    // MARK: Hilfen

    private func elements(_ env: HostedEnvironment) -> [NSObject] {
        var all = LayoutWidthAuditTests.elements(in: env.window)
        var vc = env.hosting.presentedViewController
        while let p = vc {
            if let v = p.view, v.window == nil { all += LayoutWidthAuditTests.elements(in: v) }
            vc = p.presentedViewController
        }
        return all
    }

    private func texts(_ env: HostedEnvironment) -> [String] {
        elements(env).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
    }

    private func shows(_ env: HostedEnvironment, _ t: String) -> Bool { texts(env).contains { $0.contains(t) } }
    /// Texte ohne Seitenleiste (die steht immer vorn)
    private func dump(_ env: HostedEnvironment) -> String {
        let all = texts(env)
        let cut = all.firstIndex { $0.hasPrefix("Demo-Inhalte") }.map { all.index(after: $0) } ?? all.startIndex
        return all[cut...].joined(separator: " | ")
    }

    private func button(_ env: HostedEnvironment, _ label: String, prefix: Bool = false) -> NSObject? {
        elements(env).first { e in
            guard e.accessibilityTraits.contains(.button), let l = e.accessibilityLabel else { return false }
            return prefix ? l.hasPrefix(label) : l == label
        }
    }

    @discardableResult
    private func tap(_ env: HostedEnvironment, _ label: String, prefix: Bool = false, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        for e in elements(env) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, prefix ? l.hasPrefix(label) : l == label else { continue }
            if e.accessibilityActivate() { env.pump(0.3); return true }
        }
        note("Knopf „\(label)“ fehlt: \(dump(env).prefix(1500))", file: file, line: line)
        return false
    }

    /// Knopf antippen, sobald er bereit ist (Dialoge laden erst Module und Dokumente)
    @discardableResult
    private func tapWhenReady(_ env: HostedEnvironment, _ label: String, timeout: Double = 15, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        _ = env.wait(timeout: timeout) { self.button(env, label).map { !$0.accessibilityTraits.contains(.notEnabled) } ?? false }
        return tap(env, label, file: file, line: line)
    }

    @discardableResult
    private func expect(_ env: HostedEnvironment, _ t: String, timeout: Double = 15, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let ok = env.wait(timeout: timeout) { self.shows(env, t) }
        if !ok { note("„\(t)“ fehlt: \(dump(env).prefix(2000))", file: file, line: line) }
        return ok
    }

    private func note(_ t: String, file: StaticString = #filePath, line: UInt = #line) {
        findings.append(t)
        XCTFail(t, file: file, line: line)
    }

    /// Keine fremden Hochschulen, kein "bald", kein ChatGPT-Login auf dem Bildschirm
    private func clean(_ env: HostedEnvironment, _ station: String, file: StaticString = #filePath, line: UInt = #line) {
        for w in Self.forbidden {
            for t in Set(texts(env)) where t.contains(w) { note("\(station): „\(w)“ in „\(t.prefix(120))“", file: file, line: line) }
        }
    }

    private func shoot(_ env: HostedEnvironment, _ name: String) {
        clean(env, name)
        guard let outDir else { return }
        env.pump(0.4)
        let window = env.window
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let data = UIGraphicsImageRenderer(bounds: window.bounds, format: format).pngData { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? data.write(to: outDir.appendingPathComponent(name + ".png"))
    }

    private func pumping<T>(_ timeout: Double = 30, _ body: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
        }
        let end = Date().addingTimeInterval(timeout)
        while result == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        // Zeitueberschreitung ist ein Fehler, kein Ueberspringen (Audit P48, 08.11.2026: ein Haenger blieb sonst gruen)
        guard let result else { XCTFail("Zeitueberschreitung"); throw CancellationError() }
        return try result.get()
    }

    private func dismissPresented(_ env: HostedEnvironment) {
        env.hosting.presentedViewController?.dismiss(animated: false)
        _ = env.wait(timeout: 5) { env.hosting.presentedViewController == nil }
        env.pump(0.3)
    }

    private func closeOverlay(_ env: HostedEnvironment) {
        if button(env, "Abbrechen") != nil { tap(env, "Abbrechen") } else if button(env, "Schließen") != nil { tap(env, "Schließen") }
        dismissPresented(env)
    }

    /// Fehler aus dem lokalen Backend als Text, wie die Oberflaeche ihn zeigt
    private func apiError(_ path: String, _ body: JSONValue) throws -> String {
        let api = container!.api
        do {
            _ = try pumping(60) { try await api.value(path, method: "POST", body: body) }
            return ""
        } catch let e as APIError {
            return e.errorDescription ?? ""
        }
    }

    /// Eingeplante Lernpakete der Demo entfernen (sonst gibt es nichts mehr zu planen)
    private func freePlanFiles() throws {
        let host = container!.host
        try pumping {
            let b = try await host.backend()
            try await b.context.database.transaction { c in _ = try c.execute("DELETE FROM study_packages") }
        }
    }

    /// KI-Hilfe im Dokument oeffnen
    private func openTutor(_ env: HostedEnvironment, file: String = "demo-skript") {
        env.router.go(.dashboard)
        env.pump(0.4)
        env.router.tutorOpenRequest = file
        env.router.go(.doc(file))
        _ = env.wait(timeout: 25) { !StoreScreenshotTests.canvases(in: env.view).isEmpty }
        env.pump(1.0)
    }

    /// Modus-Chip der KI-Hilfe antippen (Reiter wechseln, wenn er dort nicht liegt)
    private func tutorMode(_ env: HostedEnvironment, _ key: String) -> Bool {
        let label = TutorPanel.modes.first { $0.key == key }?.label ?? key
        if button(env, label, prefix: true) == nil, let tab = TutorPanel.Tab.tab(for: key) { _ = tap(env, "Bereich \(tab.title)") }
        return tap(env, label, prefix: true)
    }

    // MARK: - 1 Eigenes ChatGPT (eigener OpenAI-Schluessel), Free / Plus / Pro AI

    func test1EigenerSchluesselInJedemTarif() throws {
        try pumping { try await self.openDemo() }
        let env = try host()
        let link = manager.chatgpt.apiKey

        // Einwilligung: ohne Haken bleibt "Prüfen und speichern" aus, nichts wird gesendet
        env.router.go(.settings(tab: "advanced"))
        expect(env, "Eigenes ChatGPT", timeout: 20)
        expect(env, OpenAIKeyCard.agreeText)
        if let save = button(env, "Prüfen und speichern") {
            XCTAssertTrue(save.accessibilityTraits.contains(.notEnabled), "ohne Haken gesperrt")
        } else { note("Knopf „Prüfen und speichern“ fehlt") }
        XCTAssertFalse(shows(env, "Wochentests und der KI-Lernplan – in jedem Tarif"), "Karte verspricht nichts, was der Tarif sperrt")
        expect(env, OpenAIKeyCard.introText)
        shoot(env, "01-schluessel-einwilligung-ohne-haken")
        let sent0 = try pumping { await self.fake.requests.count }
        XCTAssertEqual(sent0, 0, "ohne Haken keine Anfrage")
        // mit Haken eingetragen (das Feld ist ein sicheres Textfeld; die Karte ruft genau das auf)
        try pumping { await link.save(key: Self.key) }
        XCTAssertTrue(link.enabled, link.message ?? "")
        expect(env, "sk-…0123")
        XCTAssertEqual(OpenAIKeyKeychainStore(userScope: DataContainerKey.userScope(bed.user)).load()?.apiKey, Self.key, "im Schluesselbund")
        XCTAssertFalse(UserDefaults.standard.dictionaryRepresentation().values.contains { "\($0)".contains("ERFUNDEN-abc") }, "nicht in UserDefaults")
        shoot(env, "02-schluessel-eingetragen")

        for plan in [UFPlan.free, .plus, .proAI] {
            Entitlements.shared.setPlanForTesting(plan)
            env.pump(0.5)
            try keyRun(env, plan: plan)
        }

        // Loeschen entfernt den Schluessel, danach zeigen die KI-Stellen wieder den Weg
        Entitlements.shared.setPlanForTesting(.free)
        try pumping { await link.remove() }
        XCTAssertNil(OpenAIKeyKeychainStore(userScope: DataContainerKey.userScope(bed.user)).load())
        XCTAssertFalse(link.enabled)
        let backend = try pumping { try await self.container!.host.backend() }
        XCTAssertNil(backend.context.ai.provider)
    }

    /// Alle KI-Stellen mit dem eigenen Schluessel in einem Tarif
    private func keyRun(_ env: HostedEnvironment, plan: UFPlan) throws {
        let p = plan.rawValue
        let shots = plan == .free || plan == .proAI
        try pumping { await self.fake.set(.ok) }

        // KI-Hilfe im Dokument: jeder Modus antwortet, Formeln lesbar, Fusszeile "über dein ChatGPT" ohne Credits
        openTutor(env)
        XCTAssertFalse(shows(env, ChatGPTLink.planHint), "\(p): mit Schluessel kein Tarif-Hinweis")
        let modes = plan == .free ? ["explain", "explain_simple", "summary", "terms", "steps", "hints"] : ["explain", "steps"]
        for (i, mode) in modes.enumerated() {
            let before = try pumping { await self.fake.count(ChatGPTConstants.responsesURL) }
            guard tutorMode(env, mode) else { continue }
            let ok = env.wait(timeout: 20) { self.shows(env, "x²") && self.button(env, TutorPanel.modes.first { $0.key == mode }!.label, prefix: true)?.accessibilityTraits.contains(.notEnabled) != true }
            if !ok { note("\(p) KI-Hilfe \(mode): keine Antwort mit x²: \(dump(env).prefix(1500))") }
            let after = try pumping { await self.fake.count(ChatGPTConstants.responsesURL) }
            if plan == .free { XCTAssertGreaterThanOrEqual(after, before, mode) }
            if i == 0 {
                expect(env, "über dein ChatGPT")
                XCTAssertFalse(shows(env, "Credits ("), "\(p): eigener Schluessel kostet keine Credits")
                if shots { shoot(env, "10-\(p)-ki-hilfe-\(mode)") }
            }
        }
        if plan == .free {
            // Folgefrage (Vorschlag nach der Antwort)
            if let follow = AIFollowUps.suggest(after: "hints").first, button(env, follow.label, prefix: true) != nil {
                tap(env, follow.label, prefix: true)
                env.pump(1.5)
                shoot(env, "11-free-ki-hilfe-folgefrage")
            } else { findings.append("Hinweis: Folgefragen-Chip nicht gefunden: \(dump(env).prefix(600))") }

            // Fehler: falscher Schluessel, Guthaben leer, Rate-Limit, Zeitueberschreitung, kein Netz -> Text, kein Haengen
            for (mode, text, shot) in [(Mode.badKey, "OpenAI lehnt den Schlüssel ab", "12-fehler-401-schluessel"),
                                       (.quota, "OpenAI-Guthaben ist aufgebraucht", "13-fehler-429-guthaben"),
                                       (.rate, "zu viele Anfragen", "14-fehler-429-rate"),
                                       (.timeout, "nicht rechtzeitig geantwortet", "15-fehler-zeitueberschreitung"),
                                       (.offline, "Prüfe deine Internetverbindung", "16-fehler-kein-netz")] {
                try pumping { await self.fake.set(mode) }
                guard tutorMode(env, "similar") else { continue }
                if expect(env, text, timeout: 20) { shoot(env, shot) }
                XCTAssertFalse(shows(env, "TESTSCHLUESSEL") || shows(env, "ERFUNDEN-abc"), "Schluessel nie im Text")
                if mode == .badKey {
                    // Folgefehler: Settings-Karte zeigt den letzten Fehler; danach wieder ok
                }
            }
            try pumping { await self.fake.set(.ok) }

            // Markierter Bereich als Bild und ganze Seite ueber das Backend (gleicher Weg wie die Leiste)
            let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4])
            let api = container!.api
            let area = try pumping { try await api.value("/api/ai/tutor", method: "POST",
                                                          body: ["mode": "explain", "file_id": "demo-skript", "page": 1, "selection": "13 im Dualsystem",
                                                                 "image": .string(jpeg.base64EncodedString())]) }
            XCTAssertTrue((area.s("answer") ?? "").contains("x^2"), area.jsonString())
            let lastReq = try pumping { await self.fake.last }
            let sent = try JSONValue.parse(lastReq?.body ?? Data())
            XCTAssertEqual(sent["input"]?.array?.first?["content"]?.array?.last?["type"]?.string, "input_image", "Bereich: Bild geht mit")
            // Aufnahmen-Fragen nutzen denselben Endpunkt (mode ask, Transkript als Seitentext)
            let rec = try pumping { try await api.value("/api/ai/tutor", method: "POST",
                                                         body: ["mode": "ask", "page": 1, "page_text": "Transkript: heute Dualsystem und 2^3.",
                                                                "question": "Was war das Thema?"]) }
            XCTAssertTrue((rec.s("answer") ?? "").contains("x^2"))

            // Ganzes Dokument: Plan, dann Schritt fuer Schritt
            let plan = try pumping { try await api.value("/api/ai/document/plan", method: "POST",
                                                          body: ["file_id": "demo-skript", "mode": "lecture", "scope": ["kind": "all"]]) }
            let steps = plan.list("steps")
            XCTAssertFalse(steps.isEmpty, plan.jsonString())
            if let first = steps.first?.s("id") {
                let step = try pumping { try await api.value("/api/ai/document/step", method: "POST",
                                                              body: ["file_id": "demo-skript", "mode": "lecture", "scope": ["kind": "all"], "step": .string(first)]) }
                XCTAssertFalse(step.list("blocks").isEmpty, step.jsonString())
            }
            _ = tap(env, "Bereich Erklären")
            if tap(env, "Ganze Vorlesung erklären", prefix: true) {
                env.pump(2)
                shoot(env, "17-free-ganzes-dokument")
            }
        }
        // Seiten-Index: mit Schluessel "Seite einordnen" nach Antippen (vorher stumm, can_build=false)
        let api = container!.api
        let status = try pumping { try await api.value("/api/index/status") }
        XCTAssertEqual(status["can_build"]?.bool, true, "\(p): Seiten-Index mit eigenem Schluessel")
        if plan == .free {
            let built = try pumping(60) { try await api.value("/api/index/file/demo-skript/page/1", method: "POST", body: ["force": false]) }
            XCTAssertNotEqual(built.s("status"), "none", built.jsonString())
        }

        // KI-Start
        env.router.go(.aiStart)
        expect(env, "über dein ChatGPT", timeout: 15)
        XCTAssertFalse(shows(env, "KI kommt mit StudiNow Pro AI"), p)
        if shots { shoot(env, "20-\(p)-ki-start") }

        // Karteikarten aus Dokument: Free -> Hinweis auf Plus; Plus/Pro AI -> Vorschlag, Speichern
        _ = overlay.modal { FlashcardComposer(moduleID: 0, fileID: "demo-skript") }
        expect(env, "Karteikarten aus Dokument")
        env.pump(1.0)
        if plan == .free {
            expect(env, "Mit \(UFPlan.plus.name) freischalten")
            shoot(env, "21-free-karteikarten-gesperrt")
        } else if tapWhenReady(env, "Karten erstellen") {
            if expect(env, "2³", timeout: 20), shots { shoot(env, "22-\(p)-karteikarten-vorschlag") }
        }
        closeOverlay(env)

        // Wochentest: Free/Plus -> Hinweis auf Pro AI; Pro AI -> erstellen und bewerten
        _ = overlay.modal { QuizComposer(moduleID: 0) }
        env.pump(1.0)
        if plan != .proAI {
            expect(env, "Mit \(UFPlan.proAI.name) freischalten")
            if plan == .free { shoot(env, "23-free-wochentest-gesperrt") }
        } else {
            shoot(env, "24-proai-wochentest-dialog")
        }
        closeOverlay(env)
        if plan == .proAI {
            let modules = try pumping { try await api.value("/api/modules").items }
            let mid = modules.first?.i("id") ?? 0
            _ = try pumping { try await api.value("/api/tests/generate", method: "POST", body: ["module_id": .number(Double(mid))]) }
            var msg = ""
            _ = env.wait(timeout: 30) {
                msg = (try? self.pumping(5) { try await api.value("/api/bg") })?.s("message") ?? ""
                return msg.contains("fertig") || msg.contains("FEHLER")
            }
            XCTAssertTrue(msg.contains("fertig"), "Wochentest: \(msg)")
            let tests = try pumping { try await api.value("/api/tests").items }
            if let tid = tests.first?.i("id") {
                let graded = try pumping(60) { try await api.value("/api/tests/\(tid)/submit", method: "POST", body: ["answers": ["1": "B"]]) }
                XCTAssertEqual(graded["total"]?.double, 6, graded.jsonString())
                env.router.go(.exams)
                env.pump(1.5)
                shoot(env, "25-proai-tests-bewertet")
            } else { note("Pro AI: kein Wochentest erzeugt") }
        }

        // KI-Lernplan-Vorschlag (eigenes ChatGPT: in jedem Tarif). Die Demo plant ihre Dateien schon selbst ein
        // (study_packages) - dann sagt der Endpunkt ehrlich "Keine offenen Vorlesungen"; fuer die KI frei machen
        try freePlanFiles()
        let suggestion = try pumping(60) { try await api.value("/api/calendar/ai-suggest", method: "POST", body: [:]) }
        XCTAssertFalse(suggestion.list("blocks").isEmpty, "\(p) KI-Lernplan: \(suggestion.jsonString().prefix(500))")
        XCTAssertTrue(Entitlements.shared.allows(.autoPlan), "\(p): Lernplan mit eigenem Schluessel frei")
        if plan == .free {
            _ = overlay.modal { AIPlanSuggestDialog(api: api, start: "2026-11-09", days: 7) { _ in } }
            if expect(env, "1 Block übernehmen", timeout: 20) { shoot(env, "26-free-ki-lernplan-vorschlag") }
            closeOverlay(env)
        }
    }

    // MARK: - 2 Ohne Schluessel und ohne Pro AI: jede KI-Stelle zeigt den Weg

    func test2OhneKIZeigtDenWeg() throws {
        try pumping { try await self.openDemo() }
        let env = try host()
        for plan in [UFPlan.free, .plus] {
            Entitlements.shared.setPlanForTesting(plan)
            let p = plan.rawValue
            openTutor(env)
            expect(env, ChatGPTLink.planHint, timeout: 25)
            XCTAssertTrue(ChatGPTLink.planHint.contains("Einstellungen → Erweitert → Eigenes ChatGPT"))
            shoot(env, "30-\(p)-ki-hilfe-ohne-ki")
            env.router.go(.aiStart)
            expect(env, ChatGPTLink.planHint)
            shoot(env, "31-\(p)-ki-start-ohne-ki")
            _ = overlay.modal { FlashcardComposer(moduleID: 0, fileID: "demo-skript") }
            env.pump(1.0)
            if plan == .free { expect(env, "Mit \(UFPlan.plus.name) freischalten") } else { expect(env, ChatGPTLink.planHint) }
            shoot(env, "32-\(p)-karteikarten-ohne-ki")
            closeOverlay(env)
            _ = overlay.modal { QuizComposer(moduleID: 0) }
            env.pump(1.0)
            expect(env, "Mit \(UFPlan.proAI.name) freischalten")
            shoot(env, "33-\(p)-wochentest-ohne-ki")
            closeOverlay(env)
        }
        // Backend sendet nichts
        let n = try pumping { await self.fake.requests.count }
        XCTAssertEqual(n, 0)
        XCTAssertTrue(KIServiceStub.requests.isEmpty)
    }

    // MARK: - 3 StudiNow-KI: Kauf Pro AI -> Konto -> Beleg -> KI; Fehler; Abmelden

    func test3ProAIUeberDenDienst() throws {
        UserDefaults.standard.set(KIServiceStub.base, forKey: StudoraAccountLink.serviceURLKey)
        URLProtocol.registerClass(KIServiceStub.self)
        KIServiceStub.reset()
        let consentDefaults = UserDefaults(suiteName: "ki-abnahme-consent-\(UUID().uuidString)")!
        let link = manager.account
        link.consentCenter = AIConsentCenter(store: AIConsentStore(defaults: consentDefaults))
        try pumping { try await self.openDemo() }
        XCTAssertEqual(StudoraAccountLink.serviceURL, KIServiceStub.base)

        // Kauf Pro AI (StoreKitTest, Konfiguration der App)
        let session = try SKTestSession(configurationFileNamed: "UniFlow")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions(); _ = try? pumping { await Entitlements.shared.refresh() } }
        let store = PurchaseStore(entitlements: .shared)
        try pumping { await store.loadProducts() }
        XCTAssertTrue(store.loadedProductIDs.contains("de.uniflow.proai.monthly"), "Pro AI im Store: \(store.loadedProductIDs)")
        XCTAssertEqual(UFPlanCatalog.cards(current: .free, loaded: store.loadedProductIDs), [.free, .plus, .proAI], "Pro-AI-Karte sichtbar")
        let product = try XCTUnwrap(store.product(for: .proAI))
        let outcome = try pumping(30) { await store.purchase(product) }
        XCTAssertEqual(outcome, .success, store.lastError ?? "")
        try pumping { await Entitlements.shared.refresh() }
        if ProcessInfo.processInfo.isiOSAppOnMac, Entitlements.shared.plan != .proAI {
            // Mac ("Designed for iPad"): die StoreKit-Testsitzung bucht den Kauf (SKTestSession.allTransactions), aber
            // StoreKit 2 (Transaction.all, Transaction.currentEntitlements) sieht ihn nicht (Befund 08.11.2026)
            throw XCTSkip("StoreKit-Testsitzung auf dem Mac: Kauf gebucht, StoreKit 2 sieht ihn nicht")
        }
        XCTAssertEqual(Entitlements.shared.plan, .proAI)

        let env = try host()
        // ohne Konto: Weg zur Anmeldung
        XCTAssertEqual(link.aiAccess, .signInRequired)
        openTutor(env)
        expect(env, StudoraAccountLink.aiSignInHint, timeout: 25)
        shoot(env, "40-proai-ohne-konto")

        // Mit Apple anmelden (Token-Tausch beim Schein-Dienst), Beleg geht an den Dienst
        try pumping(30) { await link.loginWithApple(identityToken: "erfundenes-apple-token", nonce: "n", email: nil) }
        XCTAssertNotNil(link.user, link.message ?? "")
        _ = env.wait(timeout: 10) { KIServiceStub.requests.contains { $0.path == "/api/billing/apple/verify" } }
        XCTAssertTrue(KIServiceStub.requests.contains { $0.path == "/api/billing/apple/verify" }, "Beleg an den Dienst: \(KIServiceStub.requests.map(\.path))")
        XCTAssertEqual(link.aiAccess, .ready)
        XCTAssertEqual(link.planStatus?.plan, "pro_ai")

        // KI-Hilfe: Einwilligung vor der ersten Anfrage, dann Antwort mit Formel und Credits
        openTutor(env)
        expect(env, "StudiNow-KI", timeout: 25)
        _ = tutorMode(env, "explain")
        if expect(env, "Zustimmen und fortfahren", timeout: 15) {
            shoot(env, "41-proai-einwilligung")
            tap(env, "Zustimmen und fortfahren")
        }
        expect(env, "x²", timeout: 20)
        expect(env, "– 3 Credits (97 übrig)", timeout: 10)
        shoot(env, "42-proai-ki-hilfe-credits")
        XCTAssertEqual(KIServiceStub.requests.last { $0.path == "/api/ai/relay" }?.body?["task"]?.string, "tutor:explain")

        // Fehler: Credits leer, Dienst nicht erreichbar, 500, Zeitueberschreitung
        for (fail, text, shot) in [(KIServiceStub.Fail.credits, "Credits", "43-proai-credits-leer"),
                                   (.offline, StudiNowAIText.unreachable, "44-proai-dienst-nicht-erreichbar"),
                                   (.server, StudiNowAIText.unavailable, "45-proai-dienst-500"),
                                   (.timeout, StudiNowAIText.unreachable, "46-proai-zeitueberschreitung")] {
            KIServiceStub.fail = fail
            guard tutorMode(env, "steps") else { continue }
            if expect(env, text, timeout: 20) { shoot(env, shot) }
            if fail == .credits { XCTAssertNotNil(button(env, "Tarif ansehen"), "Knopf zu den Tarifen") }
        }
        KIServiceStub.fail = nil

        // KI-Start, Karteikarten, Wochentest, KI-Lernplan ueber den Dienst
        env.router.go(.aiStart)
        expect(env, "Credits", timeout: 15)
        shoot(env, "47-proai-ki-start")
        _ = overlay.modal { FlashcardComposer(moduleID: 0, fileID: "demo-skript") }
        if tapWhenReady(env, "Karten erstellen"), expect(env, "2³", timeout: 20) { shoot(env, "48-proai-karteikarten") }
        closeOverlay(env)
        let api = container!.api
        let modules = try pumping { try await api.value("/api/modules").items }
        _ = try pumping { try await api.value("/api/tests/generate", method: "POST", body: ["module_id": .number(Double(modules.first?.i("id") ?? 0))]) }
        var msg = ""
        _ = env.wait(timeout: 30) {
            msg = (try? self.pumping(5) { try await api.value("/api/bg") })?.s("message") ?? ""
            return msg.contains("fertig") || msg.contains("FEHLER")
        }
        XCTAssertTrue(msg.contains("fertig"), "Wochentest ueber den Dienst: \(msg)")
        try freePlanFiles()
        let suggestion = try pumping(60) { try await api.value("/api/calendar/ai-suggest", method: "POST", body: [:]) }
        XCTAssertFalse(suggestion.list("blocks").isEmpty, suggestion.jsonString().prefix(400).description)
        XCTAssertTrue(Set(KIServiceStub.requests.compactMap { $0.body?["task"]?.string }).isSuperset(of: ["tutor:explain", "flashcards", "week_test", "study_plan"]),
                      "\(KIServiceStub.requests.compactMap { $0.body?["task"]?.string })")

        // Abmelden: KI weg, Hinweis zur Anmeldung
        try pumping { await link.logout() }
        XCTAssertEqual(link.aiAccess, .signInRequired)
        let backend = try pumping { try await self.container!.host.backend() }
        _ = env.wait(timeout: 5) { backend.context.ai.serviceProvider == nil }
        XCTAssertNil(backend.context.ai.serviceProvider)
        openTutor(env)
        expect(env, StudoraAccountLink.aiSignInHint, timeout: 20)
    }

    // MARK: - 4 Probe: 7 Tage Pro-AI-Umfang mit 25 Credits beim Dienst

    func test4ProbeMitKonto() throws {
        UserDefaults.standard.set(KIServiceStub.base, forKey: StudoraAccountLink.serviceURLKey)
        URLProtocol.registerClass(KIServiceStub.self)
        KIServiceStub.reset()
        KIServiceStub.trial = true
        let link = manager.account
        link.consentCenter = AIConsentCenter(store: AIConsentStore(defaults: UserDefaults(suiteName: "ki-abnahme-trial-\(UUID().uuidString)")!))
        try pumping { try await self.openDemo() }
        Entitlements.shared.useLocalTrial(startedAt: Date())
        XCTAssertEqual(Entitlements.shared.plan, .proAI, "Probe = Pro-AI-Umfang")
        let env = try host()
        try pumping(30) { await link.loginWithApple(identityToken: "erfundenes-apple-token", nonce: "n", email: nil) }
        XCTAssertEqual(link.aiAccess, .ready)
        XCTAssertEqual(link.planStatus?.trialActive, true)
        openTutor(env)
        _ = tutorMode(env, "summary")
        if env.wait(timeout: 10, until: { self.shows(env, "Zustimmen und fortfahren") }) { tap(env, "Zustimmen und fortfahren") }
        expect(env, "x²", timeout: 20)
        expect(env, "(22 übrig)", timeout: 10)
        shoot(env, "50-probe-ki-hilfe-25-credits")
    }
}

/// Schein-StudiNow-Dienst fuer URLSession (nur `dienst.example`): Konto, Tarif, Beleg, Credits, KI-Relay
final class KIServiceStub: URLProtocol {
    static let base = "https://dienst.example"
    struct Seen { let method: String; let path: String; let body: JSONValue? }
    enum Fail { case credits, offline, server, timeout }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _seen: [Seen] = []
    nonisolated(unsafe) private static var _fail: Fail?
    nonisolated(unsafe) private static var _verified = false
    nonisolated(unsafe) private static var _trial = false
    nonisolated(unsafe) private static var _used = 0

    static func reset() { lock.withLock { _seen = []; _fail = nil; _verified = false; _trial = false; _used = 0 } }
    static var requests: [Seen] { lock.withLock { _seen } }
    static var fail: Fail? { get { lock.withLock { _fail } } set { lock.withLock { _fail = newValue } } }
    static var trial: Bool { get { lock.withLock { _trial } } set { lock.withLock { _trial = newValue } } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "dienst.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func credits(charged: Int? = nil) -> JSONValue {
        lock.withLock {
            let allowance = _trial ? 25 : 100
            var c: [String: JSONValue] = ["period": "2026-11", "allowance": .number(Double(allowance)), "used": .number(Double(_used)), "reserved": 0,
                                          "remaining": .number(Double(allowance - _used)), "plan": _trial ? "free" : "pro_ai",
                                          "resets_at": "2026-12-01T00:00:00+01:00"]
            if let charged { c["charged"] = .number(Double(charged)); c["replay"] = false }
            return .object(c)
        }
    }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
        }
        let path = request.url?.path ?? ""
        let body = try? JSONValue.parse(data)
        let fail = Self.lock.withLock { () -> Fail? in
            Self._seen.append(Seen(method: request.httpMethod ?? "GET", path: path, body: body))
            return path == "/api/ai/relay" ? Self._fail : nil
        }
        if fail == .offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        if fail == .timeout { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        let user: JSONValue = ["id": "konto-erfunden-1", "email": "", "email_verified": false, "university": "luh", "plan": "free", "role": "user"]
        let (status, reply): (Int, JSONValue)
        switch path {
        case "/api/account/login/apple": (status, reply) = (200, ["token": "sitzung-erfunden", "user": user, "created": true])
        case "/api/account/me": (status, reply) = (200, ["user": user, "sessions": []])
        case "/api/billing/apple/verify":
            Self.lock.withLock { Self._verified = true }
            (status, reply) = (200, ["plan": "pro_ai"])
        case "/api/entitlements":
            let (verified, trial) = Self.lock.withLock { (Self._verified, Self._trial) }
            (status, reply) = (200, ["plan": verified ? "pro_ai" : "free",
                                     "trial": trial ? ["active": true, "days_left": 7, "plan": "pro_ai"] : ["active": false],
                                     "credits": Self.credits()])
        case "/api/ai/relay":
            if fail == .credits {
                (status, reply) = (402, ["detail": ["detail": "Deine Credits für diesen Monat sind aufgebraucht. Am 1. Dezember gibt es neue.", "code": "credits_exhausted"]])
            } else if fail == .server {
                (status, reply) = (500, ["detail": ""])
            } else {
                Self.lock.withLock { Self._used += 3 }
                let task = body?["task"]?.string ?? ""
                let prompt = body?["prompt"]?.string ?? ""
                let schema = task == "flashcards" || task == "study_plan"
                (status, reply) = (200, ["answer": .string(KIAbnahmeLUHAppTests.reply(system: "", prompt: prompt, schema: schema)),
                                         "model": "erfunden", "shared": false, "credits": Self.credits(charged: 3)])
            }
        default: (status, reply) = (404, ["detail": "nicht da"])
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.serialized())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
