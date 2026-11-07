import PencilKit
import StoreKitTest
import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// App-Store-Bildschirmfotos fuer das iPad Pro 13" (2064 x 2752 hoch, 2752 x 2064 quer): die echten Ansichten der App
/// in einem Fenster von 1032 x 1376 Punkten bei Massstab 2, mit den Demo-Inhalten (`DemoContent`: erfundenes Modul
/// "Demo: Grundlagen der Informatik", kein echter Name, kein Hochschul-Logo) und den Zusaetzen nur fuer die Store-Bilder
/// (`DemoContent.installStoreExtras`: Studienverlauf mit Pruefungsanmeldung, Nachrichten) und dem erfundenen Speiseplan
/// (`MensaDemoHTTP`, unter XCTest im lokalen Backend). Mit UF_SCREENSHOT_DIR
/// (xcodebuild: TEST_RUNNER_UF_SCREENSHOT_DIR) schreibt der Test die PNGs dorthin, je Ansicht hell und dunkel, hoch und
/// quer: der Store-Satz (01-10) direkt in den Ordner, Varianten und Reserve unter `reserve/`. Reihenfolge, Dateinamen
/// und Bildunterschriften: docs/release/SCREENSHOTS.md. Ohne UF_SCREENSHOT_DIR prueft der Test nur, dass jede Ansicht
/// mit den Demo-Inhalten erscheint.
///
/// Kein Netz: UniStubProtocol zaehlt jede Anfrage an eine Hochschule (es darf keine geben), die KI antwortet aus einem
/// Schein-Transport vor dem lokalen Backend, Stud.IP (Antworten, Abgeben) aus einer Nachbildung im Speicher
/// (`DemoStudIP`), die Community aus einer leeren Wolke im Speicher (so erscheint die Seite wie im Build mit
/// iCloud-Container, mit den Communities der Demo-Kurse). Tarif Plus ueber `setPlanForTesting`, damit Notizen und
/// Karteikarten frei sind; die Tarifseite zeigt Free als gekauften Stand. Die Begruessung nennt den erfundenen Rufnamen
/// "Tobi" (`Rufname` des Test-Containers, Wunsch des Inhabers 05.11.2026).
@MainActor
final class StoreScreenshotTests: XCTestCase {

    /// iPad Pro 13" in Punkten (x2 = 2064 x 2752 bzw. 2752 x 2064 Pixel)
    private static let portrait = CGSize(width: 1032, height: 1376)
    private static let landscape = CGSize(width: 1376, height: 1032)
    /// erfundener Rufname der Begruessung
    static let demoName = "Tobi"

    private var bed: ContainerTestBed!
    private var manager: ContainerManager!
    private var account: AccountStore!
    private var container: ActiveContainer!
    /// Zielordner aus UF_SCREENSHOT_DIR; nil = nur pruefen, keine Bilder
    private var outDir: URL?

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = true
        bed = try ContainerTestBed(name: "shots", clock: .system)
        UniStubProtocol.install { _ in UniStubProtocol.Reply(status: 404) }          // jede Anfrage an eine Hochschule zaehlt
        // wie die App: der aktive Container wird veroeffentlicht, so liegen Notizen und PDF-Zwischenspeicher des
        // Editors im Container (ActiveContainer.current) und verschwinden mit dem Temp-Ordner des Tests
        manager = ContainerManager(
            base: bed.containers,
            legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
            keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock, publishesCurrent: true)
        account = bed.account(.luh)
        container = try bed.open(manager, account)
        account.markLoginDone()
        _ = try await manager.setDemo(true)
        XCTAssertTrue(manager.demoActive)
        try await Self.installStoreExtras(container.host)
        Rufname.write(Self.demoName, container.defaults)
        MessagesInbox.shared.defaultsOverride = container.defaults
        await MessagesInbox.shared.refresh(api: container.api)
        Entitlements.shared.setPlanForTesting(.plus)
        let host = container.host
        CommunityRoute.shared.service = CloudKitCommunityService(
            cloud: EmptyCloud(), university: .luh, membership: CommunityMembership(defaults: container.defaults),
            courseKeys: { [] }, courses: { await CommunityCourses.spaces(host: host, university: UniversityKey.luh.rawValue) })
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        if let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("reserve", isDirectory: true), withIntermediateDirectories: true)
            outDir = url
        }
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        CommunityRoute.shared.service = nil
        Entitlements.shared.setPlanForTesting(.free)
        MessagesInbox.shared.defaultsOverride = nil
        await MessagesInbox.shared.refresh(api: nil)
        XCTAssertEqual(UniStubProtocol.requests.count, 0, "keine Anfrage an eine Hochschule")
        manager.deactivate()
        await bed.tearDown()
        try await super.tearDown()
    }

    /// Zusaetze nur fuer die Store-Bilder (Studienverlauf, Nachrichten) in die Datenbank des Containers
    static func installStoreExtras(_ host: LocalBackendHost) async throws {
        let backend = try await host.backend()
        let clock = backend.context.clock
        try await backend.context.database.transaction { try DemoContent.installStoreExtras($0, clock: clock) }
    }

    // MARK: - Schein-Dienste

    /// Leere Wolke im Speicher: die Community gilt als verbunden (Communities aus den Demo-Kursen), ohne iCloud
    final class EmptyCloud: CommunityCloud, @unchecked Sendable {
        func accountStatus() async throws -> CommunityAccountStatus { .available }
        func userRecordName() async throws -> String { "_demo" }
        func save(_ record: CommunityRecord, in scope: CommunityScope) async throws -> CommunityRecord { record }
        func fetch(name: String, type: String, in scope: CommunityScope) async throws -> CommunityRecord? { nil }
        func query(_ q: CommunityQuery, in scope: CommunityScope) async throws -> [CommunityRecord] { [] }
        func delete(name: String, type: String, in scope: CommunityScope) async throws {}
    }

    /// Feste Antworten fuer einzelne Pfade (KI, Wochentest), alles andere beantwortet das lokale Backend des Containers.
    /// Mehrere Antworten je Pfad kommen nacheinander, die letzte bleibt.
    final class Intercept: APITransport, @unchecked Sendable {
        private let inner: LocalTransport
        private let lock = NSLock()
        private var canned: [String: [JSONValue]] = [:]
        private var hits: [String] = []

        init(_ host: LocalBackendHost) { inner = LocalTransport(host: host) }

        func answer(_ path: String, _ v: JSONValue...) { lock.withLock { canned[path] = v } }
        func count(_ path: String) -> Int { lock.withLock { hits.filter { $0 == path }.count } }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let v: JSONValue? = lock.withLock {
                guard var list = canned[path], let first = list.first else { return nil }
                if list.count > 1 { list.removeFirst(); canned[path] = list }
                hits.append(path)
                return first
            }
            guard let v else { return try await inner.send(request) }
            return (v.serialized(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                    headerFields: ["Content-Type": "application/json"])!)
        }
    }

    /// Stud.IP-Nachbildung im Speicher fuer die Blaetter "Antworten" und "In Stud.IP abgeben": eigenes Konto, Posteingang
    /// mit der Demo-Nachricht des Tutoriums, Ordner der Demo-Uebung. Keine Anfrage verlaesst den Prozess; schreibende
    /// Anfragen gibt es in den Bildern nicht (abgelehnt).
    final class DemoStudIP: StudIPWritingTransport, @unchecked Sendable {
        static let me = "u-demo"

        func get(_ url: URL, accept: String?) async throws -> HTTPReply {
            let p = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            func json(_ s: String) -> HTTPReply {
                HTTPReply(status: 200, contentType: "application/vnd.api+json", finalURL: url, body: Data(s.utf8))
            }
            if p.contains("/users/me") {
                return json(#"{"data":{"type":"users","id":"u-demo","attributes":{"family-name":"Muster","given-name":"Tobi","formatted-name":"Tobi Muster"}}}"#)
            }
            if p.contains("/users/\(Self.me)/inbox") {
                return json("""
                {"data":[{"type":"messages","id":"demo-msg-1","attributes":{"subject":"Fragen zu Übungsblatt 1","message":"Hallo zusammen","mkdate":"2026-11-05T08:15:00+01:00"},
                  "relationships":{"sender":{"data":{"type":"users","id":"u-tutorium"}},
                   "recipients":{"data":[{"type":"users","id":"u-demo"}]}}}],
                 "included":[{"type":"users","id":"u-tutorium","attributes":{"formatted-name":"Tutorium Grundlagen der Informatik"}}],"links":{}}
                """)
            }
            if p.contains("/courses/demo-uebung/folders") {
                return json("""
                {"data":[
                 {"type":"folders","id":"root","attributes":{"name":"Demo: Grundlagen der Informatik (Übung)","folder-type":"RootFolder","is-visible":true,"is-writable":false}},
                 {"type":"folders","id":"blaetter","attributes":{"name":"Übungsblätter","folder-type":"StandardFolder","is-visible":true,"is-writable":false},"relationships":{"parent":{"data":{"type":"folders","id":"root"}}}},
                 {"type":"folders","id":"abgabe1","attributes":{"name":"Abgabe Übungsblatt 1","folder-type":"HomeworkFolder","is-visible":true,"is-writable":true},"relationships":{"parent":{"data":{"type":"folders","id":"root"}}}},
                 {"type":"folders","id":"loesungen","attributes":{"name":"Eigene Lösungen","folder-type":"StandardFolder","is-visible":true,"is-writable":true},"relationships":{"parent":{"data":{"type":"folders","id":"root"}}}}
                ]}
                """)
            }
            return HTTPReply(status: 404, finalURL: url)
        }

        func send(_ url: URL, method: String, headers: [String: String], body: Data) async throws -> HTTPReply {
            HTTPReply(status: 403, finalURL: url)
        }

        static func client() -> StudIPClient { StudIPClient(base: StudIPSync.base, transport: DemoStudIP(), pauseMillis: 0) }
    }

    /// Antwort-Fenster mit der Nachbildung (verbunden, Sitzung gueltig)
    static func replyModel(defaults: UserDefaults) -> MessageReplyModel {
        let original = MessageReplyOriginal(localID: "demo-msg-1", subject: "Fragen zu Übungsblatt 1", text: "Hallo zusammen",
                                            senderLabel: "Tutorium", sentAt: nil)
        return MessageReplyModel(original: original, mode: .sender,
                                 dependencies: .init(connected: { true }, ensureSession: { _ in .ready }, client: { DemoStudIP.client() },
                                                     defaults: defaults))
    }

    /// Text der Antwort im Bild (erfunden)
    static let replyText = "Danke! Ich bringe meinen Ansatz zu Aufgabe 3 mit."

    /// Abgabe-Blatt mit der Nachbildung: Demo-Uebung vorausgewaehlt, Abgabeordner vorgeschlagen, PDF des Demo-Blatts
    static func submitModel(defaults: UserDefaults) -> StudIPSubmitModel {
        let blatt = DemoContent.files.first { $0.id == "demo-blatt" }!
        let data = DemoContent.pdf(blatt)
        return StudIPSubmitModel(
            documentID: "demo-blatt", documentTitle: "Übungsblatt 1 – Zahlensysteme", documentCourseID: "demo-uebung", moduleID: nil,
            dependencies: .init(connected: { true }, ensureSession: { _ in .ready }, client: { DemoStudIP.client() },
                                courses: { DemoContent.courses.map { .init(id: $0.id, title: $0.title, moduleID: nil, kind: $0.kind) } },
                                // Groesse wie ein Blatt mit Handschrift (die kleine Demo-PDF zeigte "0,0 MB"); hochgeladen wird nichts
                                makePDF: { withNotes in
                                    .init(data: data + Data(repeating: 0x20, count: (withNotes ? 1_250_000 : 400_000) - data.count),
                                          pages: blatt.pages.count)
                                },
                                defaults: defaults))
    }

    /// Antwort der KI-Hilfe zur Demo-Seite (erfunden, Markdown wie vom Dienst)
    static let tutorAnswer: JSONValue = [
        "answer": """
        **Zahlensysteme in Kürze**

        Jede Zahl ist eine Summe von Potenzen ihrer Basis: dezimal Basis 10, dual Basis 2, hexadezimal Basis 16.

        - **13 dezimal** = 8 + 4 + 1 = **1101 dual** = **D hexadezimal**
        - Dezimal → dual: fortgesetzt durch 2 teilen, die Reste von unten nach oben lesen
        - Dual → dezimal: die Stellenwerte 1, 2, 4, 8 … der Einsen addieren

        **Probier es mit 42:** 42 = 32 + 8 + 2, also 101010.
        """,
        "cards": .null, "sources": [], "explain": .null,
    ]

    /// Plan "Ganze Vorlesung erklären" fuer das ganze Demo-Skript (3 Seiten): zwei Teile, ohne Rueckfrage
    static let docPlan: JSONValue = [
        "intent": true, "mode": "lecture", "scope": ["kind": "all", "from": 1, "to": 3, "label": "Ganzes Dokument (Seiten 1–3)"],
        "title": "Ganze Vorlesung erklären · Ganzes Dokument (Seiten 1–3)",
        "steps": [["id": "1:lecture:1-3", "kind": "lecture", "from": 1, "to": 3, "title": "Seiten 1–3", "tasks": [], "cached": false],
                  ["id": "2:overview:1-3", "kind": "overview", "from": 1, "to": 3, "title": "Überblick und Prüfungsrelevantes", "tasks": [], "cached": false]],
        "calls": 2, "cached": 0, "estimate": ["way": "credits", "credits": 2, "calls": 2], "confirm": false, "enough": true,
        "message": "Kostet etwa 2 Credits.",
    ]

    /// Die beiden Teile der erklaerten Vorlesung (erfunden)
    static let docSteps: [JSONValue] = [
        ["step": "1:lecture:1-3", "stored": ["stored": false, "variant": 1],
         "blocks": [
            ["kind": "section", "title": "Zahlensysteme", "from": 1, "to": 1,
             "text": "Jede Zahl ist eine Summe von Potenzen ihrer Basis: dezimal 10, dual 2, hexadezimal 16.\n- **13** = 8 + 4 + 1 = **1101** (dual) = **D** (hex)"],
            ["kind": "section", "title": "Umrechnung", "from": 2, "to": 2,
             "text": "- Dezimal → dual: fortgesetzt durch 2 teilen, die Reste von unten lesen\n- Dual → dezimal: Stellenwerte 1, 2, 4, 8 … addieren\n- **42** = 32 + 8 + 2 = **101010**"],
            ["kind": "section", "title": "Zweierkomplement", "from": 3, "to": 3,
             "text": "Negative Zahlen: Bits invertieren und 1 addieren. Mit 8 Bit reicht der Bereich von **−128 bis 127**; ein Überlauf zeigt sich am Vorzeichen."],
         ]],
        ["step": "2:overview:1-3", "stored": ["stored": false, "variant": 1],
         "blocks": [
            ["kind": "overview", "title": "Überblick", "from": 1, "to": 3,
             "text": "Rote Linie: Zahlen darstellen (Basis), umrechnen (Division, Stellenwerte), negativ machen (Zweierkomplement)."],
            ["kind": "overview", "title": "Prüfungsrelevant", "from": 1, "to": 3,
             "text": "- Umrechnung dezimal ↔ dual ↔ hexadezimal\n- Zweierkomplement mit 8 Bit, Wertebereich und Überlauf"],
         ]],
    ]

    /// Abgegebener Wochentest zum Demo-Modul mit Auswertung und Erklaerungen (erfunden)
    static var demoTest: JSONValue {
        let day = UFFmt.todayISO()
        return ["id": 18, "subject": .string(DemoContent.subject), "title": "Wochentest Grundlagen der Informatik – Zahlensysteme",
                "duration_min": 15, "started_at": .string(day + "T09:48:00"), "submitted_at": .string(day + "T10:02:00"),
                "week_no": 1, "auto": 0,
                "answers": ["1": "1101", "2": "Wahr", "3": "invertiert", "4": "-128 bis 127"],
                "feedback": ["total": 60, "max": 80,
                             "summary": "Drei von vier Aufgaben richtig. Das Zweierkomplement sitzt; die Umrechnung ins Hexadezimalsystem lohnt eine Wiederholung.",
                             "weak_topics": ["Hexadezimalsystem"],
                             "per_question": [["nr": 1, "points": 20, "max": 20, "feedback": "Richtig: 13 = 8 + 4 + 1."],
                                              ["nr": 2, "points": 0, "max": 20, "feedback": "255 ist hexadezimal FF, nicht F0: 15 · 16 + 15."],
                                              ["nr": 3, "points": 20, "max": 20, "feedback": "Richtig."],
                                              ["nr": 4, "points": 20, "max": 20, "feedback": "Genau, mit 8 Bit."]]],
                "questions": [
                    ["nr": 1, "type": "mc", "difficulty": "leicht", "question": "Wie lautet die Dezimalzahl 13 im Dualsystem?",
                     "options": ["1011", "1101", "1110", "1001"], "answer": "1101", "explanation": "13 = 8 + 4 + 1, also 1101.", "points": 20],
                    ["nr": 2, "type": "tf", "difficulty": "leicht", "question": "Die Dezimalzahl 255 ist hexadezimal F0.",
                     "options": ["Wahr", "Falsch"], "answer": "Falsch", "explanation": "255 = 15 · 16 + 15, also FF.", "points": 20],
                    ["nr": 3, "type": "cloze", "difficulty": "mittel", "question": "Für das Zweierkomplement werden alle Bits ___ und anschließend wird 1 addiert.",
                     "answer": "invertiert", "blank": "invertiert", "explanation": "Bits invertieren und 1 addieren.", "points": 20],
                    ["nr": 4, "type": "short", "difficulty": "mittel", "question": "Welcher Wertebereich lässt sich mit 8 Bit im Zweierkomplement darstellen?",
                     "answer": "-128 bis 127", "explanation": "2⁷ negative Zahlen, 2⁷ − 1 positive Zahlen und die Null.", "points": 20]]]
    }

    private func aiTransport() -> Intercept {
        let t = Intercept(container.host)
        t.answer("/api/ai/tutor", Self.tutorAnswer)
        t.answer("/api/tests/18", Self.demoTest)
        t.answer("/api/ai/document/plan", Self.docPlan)
        t.answer("/api/ai/document/step", Self.docSteps[0], Self.docSteps[1])
        return t
    }

    private func aiAPI(_ t: Intercept) -> APIClient { APIClient(base: APIClient.localBase, transport: t) }

    // MARK: - Hosten und Fotografieren

    /// Schalter fuer ein Blatt ueber der Seite (Antworten, Abgeben): der Test oeffnet es, wenn die Seite steht
    final class SheetSwitch: ObservableObject {
        @Published var shown = false
    }

    /// Seite mit einem Blatt darueber, praesentiert wie in der App (`.sheet`); das Blatt erbt die Umgebung
    struct WithSheet<Base: View, Sheet: View>: View {
        let base: Base
        @ObservedObject var toggle: SheetSwitch
        let sheet: () -> Sheet

        var body: some View {
            base.sheet(isPresented: $toggle.shown) { sheet() }
        }
    }

    /// Die ganze App-Huelle (Seitenleiste, Kopfzeile, Seite) mit Demo-Inhalten; `ai`: KI verbunden (nur KI-Bilder).
    /// Die Demo-Leiste ("Demo-Inhalte – erfunden, ohne Hochschule", nur fuer Pruefer) ist in den Store-Bildern aus
    /// (`\.ufDemoBarHidden`, nur im Test).
    private func host<V: View>(_ view: V, api: APIClient? = nil, ai: Bool = false) throws -> HostedEnvironment {
        let root = view
            .environment(\.ufDemoActive, true)
            .environment(\.ufDemoBarHidden, true)
            .environment(\.ufAIEnabled, ai)
            .environmentObject(manager!)
            .environmentObject(account!)
        return try hostWithEnvironment(root, api: api ?? container.api, size: Self.portrait, studip: manager.studip)
    }

    /// Hell und dunkel, hoch und quer (Fensterrahmen umstellen, Hauptschleife laufen lassen); Pixelgroessen geprueft.
    /// `ink`: Zeichnungen der PencilKit-Canvas nachzeichnen (`drawHierarchy` nimmt ihre Kacheln nicht mit).
    /// `reserve`: Varianten und Reserve (nicht im Store-Satz) unter `reserve/`. `sheet`: Blatt ueber der Seite.
    private func shoot(_ env: HostedEnvironment, _ name: String, reserve: Bool = false, ink: Bool = false, settle: Double = 1.0,
                       sheet: SheetSwitch? = nil, sheetReady: @escaping () -> Bool = { true }) {
        guard let outDir else { return }
        let folder = reserve ? outDir.appendingPathComponent("reserve", isDirectory: true) : outDir
        Self.shoot(env, name, folder: folder, sizes: [(Self.portrait, "portrait"), (Self.landscape, "landscape")], scale: 2, ink: ink,
                   settle: settle, present: sheet.map { s in { s.shown = true } }, sheetReady: sheetReady)
    }

    /// Fotografiert das Fenster je Groesse hell und dunkel; danach wieder die erste Groesse. Mit Blatt (`present` oeffnet
    /// es): zuerst alle Seiten ohne Blatt, dann das Blatt darueber (nach einer Praesentation zeichnet `drawHierarchy` die
    /// Seite nur noch schwarz), zusammengesetzt mit der Abdunklung wie in der App. `cornerRadius`: Ecken des Blatts.
    static func shoot(_ env: HostedEnvironment, _ name: String, folder: URL, sizes: [(CGSize, String)], scale: CGFloat, ink: Bool,
                      settle: Double, present: (() -> Void)? = nil, sheetReady: @escaping () -> Bool = { true },
                      cornerRadius: CGFloat = 26, statusBar: Bool = false, tones: [String] = ["light", "dark"],
                      fileName: ((_ tone: String, _ orientation: String) -> String)? = nil) {
        typealias Variant = (size: CGSize, orientation: String, style: UIUserInterfaceStyle, tone: String)
        let variants: [Variant] = sizes.flatMap { size, o -> [Variant] in
            let both: [Variant] = [(size, o, .light, "light"), (size, o, .dark, "dark")]
            return both.filter { tones.contains($0.tone) }
        }
        func apply(_ v: (size: CGSize, orientation: String, style: UIUserInterfaceStyle, tone: String)) {
            env.window.overrideUserInterfaceStyle = v.style
            env.window.frame = CGRect(origin: .zero, size: v.size)
            env.view.frame = env.window.bounds
            env.pump(settle)
        }
        var bases: [UIImage] = []
        for v in variants {
            apply(v)
            bases.append(pageImage(env, scale: scale, ink: ink))
        }
        if let present {
            present()
            XCTAssertTrue(env.wait(timeout: 10) { env.hosting.presentedViewController != nil && sheetReady() }, "\(name): Blatt nicht bereit")
        }
        for (i, v) in variants.enumerated() {
            var data = bases[i].pngData() ?? Data()
            if present != nil {
                apply(v)
                _ = env.wait(timeout: 5) { sheetReady() }
                env.pump(settle)
                data = composite(env, base: bases[i], scale: scale, cornerRadius: cornerRadius)
            }
            if statusBar, let image = UIImage(data: data) {
                data = withStatusBar(image, bounds: env.window.bounds, scale: scale, dark: v.style == .dark)
            }
            let file = folder.appendingPathComponent(fileName?(v.tone, v.orientation) ?? "\(name)-\(v.tone)-\(v.orientation).png")
            do { try data.write(to: file) } catch { XCTFail("\(file.lastPathComponent): \(error)") }
            if let cg = UIImage(data: data)?.cgImage {
                XCTAssertEqual(CGSize(width: cg.width, height: cg.height), CGSize(width: v.size.width * scale, height: v.size.height * scale),
                               file.lastPathComponent)
            } else {
                XCTFail("\(file.lastPathComponent): kein Bild")
            }
        }
        env.window.overrideUserInterfaceStyle = .unspecified
        if let first = sizes.first {
            env.window.frame = CGRect(origin: .zero, size: first.0)
            env.view.frame = env.window.bounds
            env.pump(0.2)
        }
    }

    private static func format(_ scale: CGFloat) -> UIGraphicsImageRendererFormat {
        let f = UIGraphicsImageRendererFormat()
        f.scale = scale
        f.opaque = true
        return f
    }

    /// Die Seite (gehostete Ansicht) mit der Handschrift der Canvas darauf
    static func pageImage(_ env: HostedEnvironment, scale: CGFloat, ink: Bool) -> UIImage {
        let window = env.window, page = env.view
        window.layoutIfNeeded()
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format(scale)).image { ctx in
            _ = page.drawHierarchy(in: page.convert(page.bounds, to: window), afterScreenUpdates: true)
            if ink { for canvas in canvases(in: page) { drawInk(canvas, of: window, scale: scale, in: ctx.cgContext) } }
        }
    }

    /// Seite, Abdunklung (nicht bei einem Blatt, das die Seite bei halber Hoehe bedienbar laesst), dann das praesentierte
    /// Blatt an seiner Stelle mit runden Ecken
    static func composite(_ env: HostedEnvironment, base: UIImage, scale: CGFloat, cornerRadius: CGFloat) -> Data {
        let window = env.window
        window.layoutIfNeeded()
        let sheetView = env.hosting.presentedViewController?.view
        var radius: CGFloat = 0
        var v = sheetView
        while let x = v, x !== window {
            if x.layer.cornerRadius > 0 { radius = x.layer.cornerRadius; break }
            v = x.superview
        }
        if radius == 0 { radius = cornerRadius }               // Ecken des Blatts (iOS 26 setzt sie nicht ueber cornerRadius)
        let dark = window.traitCollection.userInterfaceStyle == .dark
        let spc = env.hosting.presentedViewController?.sheetPresentationController
        let undimmed = spc?.largestUndimmedDetentIdentifier != nil && (spc?.selectedDetentIdentifier ?? .medium) == .medium
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format(scale)).pngData { ctx in
            base.draw(in: window.bounds)
            if !undimmed {
                ctx.cgContext.setFillColor(UIColor.black.withAlphaComponent(dark ? 0.45 : 0.25).cgColor)
                ctx.cgContext.fill(window.bounds)                // nicht ctx.fill: das kopiert und macht alles schwarz
            }
            guard let sheetView else { return }
            let rect = sheetView.convert(sheetView.bounds, to: window)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
            ctx.cgContext.saveGState()
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 8), blur: 40, color: UIColor.black.withAlphaComponent(0.25).cgColor)
            (dark ? UIColor.black : UIColor.white).setFill()
            path.fill()
            ctx.cgContext.restoreGState()
            ctx.cgContext.saveGState()
            path.addClip()
            _ = sheetView.drawHierarchy(in: rect, afterScreenUpdates: true)
            ctx.cgContext.restoreGState()
        }
    }

    /// Statuszeile wie auf dem Geraet (9:41, Netz, WLAN, Akku) in den oberen sicheren Bereich (iPhone; der Testaufbau
    /// hat keine eigene, der Streifen bliebe leer)
    static func withStatusBar(_ image: UIImage, bounds: CGRect, scale: CGFloat, dark: Bool) -> Data {
        UIGraphicsImageRenderer(bounds: bounds, format: format(scale)).pngData { _ in
            image.draw(in: bounds)
            let color = dark ? UIColor.white : UIColor.black
            let time = NSAttributedString(string: "9:41", attributes: [.font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                                                                       .foregroundColor: color])
            let ts = time.size()
            let midY: CGFloat = 31
            time.draw(at: CGPoint(x: 78 - ts.width / 2, y: midY - ts.height / 2))
            var x = bounds.width - 40
            for (name, size) in [("battery.100percent", CGFloat(25)), ("wifi", CGFloat(17)), ("cellularbars", CGFloat(17))] {
                let config = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
                guard let symbol = UIImage(systemName: name, withConfiguration: config)?.withTintColor(color, renderingMode: .alwaysOriginal)
                else { continue }
                let w = symbol.size.width * (name.hasPrefix("battery") ? 1 : 0.85)
                let h = symbol.size.height * (w / symbol.size.width)
                x -= w
                symbol.draw(in: CGRect(x: x, y: midY - h / 2, width: w, height: h))
                x -= 6
            }
        }
    }

    static func canvases(in view: UIView) -> [PKCanvasView] {
        guard !view.isHidden, view.alpha > 0 else { return [] }
        return (view as? PKCanvasView).map { [$0] } ?? view.subviews.flatMap(canvases)
    }

    /// Wie InkSnapshot: die Zeichnung der Canvas an ihre Stelle im Fenster, ueber alle Transformationen dazwischen
    static func drawInk(_ canvas: PKCanvasView, of root: UIView, scale: CGFloat, in cg: CGContext) {
        let page = canvas.superview ?? canvas
        let o = page.convert(CGPoint.zero, to: root)
        let x = page.convert(CGPoint(x: 1, y: 0), to: root), y = page.convert(CGPoint(x: 0, y: 1), to: root)
        let t = CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x, ty: o.y)
        let zoom = sqrt(abs(t.a * t.d - t.b * t.c))
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = canvas.drawing.image(from: page.bounds, scale: max(1, scale * zoom))
        }
        cg.saveGState()
        // nur im sichtbaren Bereich des Dokuments (quer verschoben laege die Zeichnung sonst ueber der Werkzeugleiste)
        var clip: UIView? = canvas.superview
        while let v = clip, !(v is UIScrollView) { clip = v.superview }
        if let scroll = clip { cg.clip(to: scroll.convert(scroll.bounds, to: root)) }
        cg.concatenate(t)
        image.draw(in: page.bounds, blendMode: .multiply, alpha: 1)      // Marker lässt den Text durch, wie auf der Canvas
        cg.restoreGState()
    }

    // MARK: - Bedienungshilfen (wie AIStartPolishAppTests)

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

    /// Ganzes Fenster: Blaetter liegen ausserhalb der gehosteten Ansicht
    private func texts(_ env: HostedEnvironment) -> [String] {
        elements(in: env.window).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
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

    /// Wartet auf `text` (bis `timeout`), meldet den Baum beim Scheitern; dann die Zeit fuer Erscheinen-Animationen
    @discardableResult
    private func expect(_ env: HostedEnvironment, _ text: String, timeout: Double = 15, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let ok = env.wait(timeout: timeout) { self.shows(env, text) }
        XCTAssertTrue(ok, "„\(text)“ fehlt:\n" + dump(env), file: file, line: line)
        return ok
    }

    // MARK: - Handschrift auf der Demo-PDF

    /// Notizen anlegen und dabei die Hauptschleife laufen lassen. Die Tests bleiben synchron: aus einer async-Testmethode
    /// heraus treibt das verschachtelte Pumpen die `.task`-Ladevorgaenge der Ansichten nicht an (Lauf 1: die Bibliothek
    /// blieb beim Laden stehen, "Dokument wählen" statt Editor).
    private func seedNotesPumping(_ fileID: String = "demo-skript") {
        Self.seedNotesPumping(fileID, api: container.api)
    }

    static func seedNotesPumping(_ fileID: String, api: APIClient) {
        var done = false
        var failure: String?
        Task { @MainActor in
            do { try await seedNotes(fileID, api: api) } catch { failure = "\(error)" }
            done = true
        }
        let end = Date().addingTimeInterval(30)
        while !done && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(done, "Notizen nicht angelegt")
        XCTAssertNil(failure, failure ?? "")
    }

    /// Notizen auf Seite 1 einer Demo-Datei (Skript oder Uebungsblatt), ueber denselben DocumentStore wie der Editor
    /// (Journal im Container), vor dem Oeffnen geschlossen (sonst "anderswo geoeffnet")
    static func seedNotes(_ fileID: String, api: APIClient) async throws {
        let demo = try XCTUnwrap(DemoContent.files.first { $0.id == fileID })
        let title = String(demo.name.dropLast(4))
        let file = LibFile(id: demo.id, name: demo.name, title: title, kind: "pdf", module_id: nil, subject: DemoContent.subject,
                           doc_type: demo.courseID == "demo-uebung" ? "uebung" : "vorlesung", ai_title: nil, sub_label: nil,
                           downloaded_at: nil, has_notes: nil, page_count: demo.pages.count, studip_folder: nil)
        let store = DocumentStore(file: file, api: api)
        store.saveTiming = SaveTiming(pause: 0.05, maxDelay: 0.5)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        let key = try XCTUnwrap(store.pageKey(forPageIndex: 0), "Seite 1 von \(fileID)")
        store.canvasChanged(pageKey: key, drawing: fileID == "demo-blatt" ? sheetHandwriting() : handwriting())
        await store.flush()
        await store.close()
    }

    /// Striche in Seitenpunkten (A4 595 x 842, Ursprung oben links): Titelzeile bei y 72, Zeilen bei 112, 134, 156
    /// (`DemoContent.pdfBytes`). Marker ueber Zeile 1, Unterstreichung des Titels, Kreis um das Beispiel, Pfeil und Haken.
    static func handwriting() -> PKDrawing {
        let pen = PKInk(.pen, color: UIColor(red: 0.13, green: 0.33, blue: 0.86, alpha: 1))
        let marker = PKInk(.marker, color: UIColor(red: 1.0, green: 0.88, blue: 0.25, alpha: 0.6))
        func line(_ from: CGPoint, _ to: CGPoint, _ n: Int = 24, wobble: CGFloat = 0) -> [CGPoint] {
            (0...n).map { i in
                let f = CGFloat(i) / CGFloat(n)
                return CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f + sin(f * 7) * wobble)
            }
        }
        func ellipse(center c: CGPoint, rx: CGFloat, ry: CGFloat) -> [CGPoint] {
            (0...48).map { i in
                let a = CGFloat(i) / 48 * 2 * .pi * 1.04 - 0.4
                return CGPoint(x: c.x + cos(a) * rx + sin(a * 3) * 1.2, y: c.y + sin(a) * ry)
            }
        }
        let strokes: [PKStroke] = [
            stroke(line(CGPoint(x: 56, y: 108), CGPoint(x: 296, y: 107)), ink: marker, width: 16, t: 790_000_000),
            stroke(line(CGPoint(x: 58, y: 80), CGPoint(x: 332, y: 82), 40, wobble: 1.4), ink: pen, width: 3, t: 790_000_010),
            stroke(ellipse(center: CGPoint(x: 178, y: 151), rx: 128, ry: 13), ink: pen, width: 2.6, t: 790_000_020),
            stroke(line(CGPoint(x: 430, y: 118), CGPoint(x: 322, y: 148), 30, wobble: 1), ink: pen, width: 2.8, t: 790_000_030),
            stroke(line(CGPoint(x: 322, y: 148), CGPoint(x: 336, y: 134), 8), ink: pen, width: 2.8, t: 790_000_031),
            stroke(line(CGPoint(x: 322, y: 148), CGPoint(x: 341, y: 150), 8), ink: pen, width: 2.8, t: 790_000_032),
            stroke(line(CGPoint(x: 28, y: 132), CGPoint(x: 37, y: 142), 8) + line(CGPoint(x: 37, y: 142), CGPoint(x: 52, y: 122), 10),
                   ink: pen, width: 3, t: 790_000_040),
        ]
        return PKDrawing(strokes: strokes)
    }

    /// Uebungsblatt (Titel bei y 72, Aufgaben bei 112, 134, 156): Titel unterstrichen, Aufgabe 1 markiert, Haken vor
    /// Aufgabe 1 und 2 (erledigt), Aufgabe 3 noch offen
    static func sheetHandwriting() -> PKDrawing {
        let pen = PKInk(.pen, color: UIColor(red: 0.13, green: 0.33, blue: 0.86, alpha: 1))
        let marker = PKInk(.marker, color: UIColor(red: 1.0, green: 0.88, blue: 0.25, alpha: 0.6))
        func line(_ from: CGPoint, _ to: CGPoint, _ n: Int = 24, wobble: CGFloat = 0) -> [CGPoint] {
            (0...n).map { i in
                let f = CGFloat(i) / CGFloat(n)
                return CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f + sin(f * 7) * wobble)
            }
        }
        func check(_ x: CGFloat, _ y: CGFloat) -> [CGPoint] {
            line(CGPoint(x: x, y: y - 6), CGPoint(x: x + 8, y: y + 3), 8) + line(CGPoint(x: x + 8, y: y + 3), CGPoint(x: x + 22, y: y - 16), 10)
        }
        return PKDrawing(strokes: [
            stroke(line(CGPoint(x: 58, y: 80), CGPoint(x: 196, y: 81), 30, wobble: 1.2), ink: pen, width: 3, t: 790_000_100),
            stroke(line(CGPoint(x: 112, y: 108), CGPoint(x: 268, y: 107)), ink: marker, width: 16, t: 790_000_110),
            stroke(check(30, 112), ink: pen, width: 3, t: 790_000_120),
            stroke(check(30, 134), ink: pen, width: 3, t: 790_000_130),
        ])
    }

    static func stroke(_ points: [CGPoint], ink: PKInk, width: CGFloat, t: Double) -> PKStroke {
        let pts = points.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.012, size: CGSize(width: width, height: width),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSinceReferenceDate: t)))
    }

    /// Wartet, bis der Editor die Notizen auf einer Canvas zeigt, dann Zeit fuer die PDF-Kacheln
    private func waitForInk(_ env: HostedEnvironment, file: StaticString = #filePath, line: UInt = #line) {
        let ok = env.wait(timeout: 25) { Self.canvases(in: env.view).contains { !$0.drawing.strokes.isEmpty } }
        XCTAssertTrue(ok, "Editor zeigt die Notizen nicht:\n" + dump(env), file: file, line: line)
        env.pump(2.0)
    }

    // MARK: - Store-Satz (01-10)

    /// Begruessung mit Rufnamen und Karte "Prüfungsanmeldung" (Meldezeitraum aus dem Studienverlauf der Store-Zusaetze)
    func test01Uebersicht() throws {
        let env = try host(MainView())
        expect(env, "Grundlagen der Informatik")
        expect(env, Self.demoName + " – lass uns gemeinsam lernen.")
        expect(env, "Prüfungsanmeldung")
        expect(env, "Diese Prüfungen solltest du anmelden")
        XCTAssertFalse(shows(env, "Stud.IP verbinden"), "Demo: keine Karte zum Verbinden")
        XCTAssertFalse(shows(env, DemoTexts.barTitle), "Store-Bild ohne Demo-Leiste")
        XCTAssertFalse(shows(env, DemoTexts.barEnd), "Store-Bild ohne „Beenden“")
        shoot(env, "01-uebersicht")
    }

    /// Skript mit Handschrift und offener KI-Hilfe: Umfang "Ganzes Dokument", "Ganze Vorlesung erklären" als Lauf in
    /// zwei Teilen (Schein-Transport), Bloecke mit Seitenangaben
    func test02KIDokument() throws {
        seedNotesPumping()
        let t = aiTransport()
        let env = try host(MainView(), api: aiAPI(t), ai: true)
        env.router.tutorOpenRequest = "demo-skript"                       // wie "Im Dokument mit KI-Hilfe öffnen"
        env.router.go(.doc("demo-skript"))
        waitForInk(env)
        XCTAssertTrue(env.wait { self.shows(env, "Ganzes Dokument") }, dump(env))
        XCTAssertTrue(tap("Ganzes Dokument", in: env), "Umfang „Ganzes Dokument“:\n" + dump(env))
        env.pump(0.5)
        XCTAssertTrue(tap("Ganze Vorlesung erklären", in: env), dump(env))
        XCTAssertTrue(env.wait(timeout: 15) { t.count("/api/ai/document/step") == 2 }, "zwei Teile geholt")
        expect(env, "Prüfungsrelevant")
        expect(env, "Zweierkomplement")
        env.pump(1.0)
        shoot(env, "02-ki-dokument", ink: true)
    }

    func test03Karteikarten() throws {
        let env = try host(MainView())
        env.router.go(.cards)
        expect(env, "heute fällig")
        expect(env, "Stapel öffnen: Skript Kapitel 1 – Zahlensysteme")       // Stapel je Demo-Datei unter "Demo Informatik"
        shoot(env, "03-karteikarten")
    }

    func test04Wochentest() throws {
        let t = aiTransport()
        let env = try host(MainView(), api: aiAPI(t), ai: true)
        env.router.go(.exam(18, task: nil))
        expect(env, "Punkte")
        expect(env, "Hexadezimalsystem")
        shoot(env, "04-wochentest")
    }

    /// Studienverlauf aus dem erfundenen Katalog: Semester, Leistungen, Abschnitt Pruefungsanmeldung
    func test05Studienverlauf() throws {
        let env = try host(MainView())
        env.router.go(.studyPlan())
        expect(env, "Prüfungsanmeldung")
        expect(env, "Theoretische Informatik")
        XCTAssertFalse(shows(env, StudyPlanText.noQIS), "Studienverlauf mit Katalog")
        shoot(env, "05-studienverlauf")
    }

    /// Posteingang mit der Nachricht des Tutoriums im Leser, darueber das Antwortfenster mit Text
    func test06Nachrichten() throws {
        let toggle = SheetSwitch()
        let model = Self.replyModel(defaults: container.defaults)
        let env = try host(WithSheet(base: MainView(), toggle: toggle) { MessageReplySheet(model: model) })
        env.router.go(.messages)
        expect(env, "Fragen zu Übungsblatt 1")
        if !shows(env, "Bringt eure Lösungsansätze mit") {
            XCTAssertTrue(tap("Neu, Fragen zu Übungsblatt 1", in: env, exact: false) || tap("Fragen zu Übungsblatt 1", in: env, exact: false), dump(env))
        }
        expect(env, "Bringt eure Lösungsansätze mit")
        let ready = { () -> Bool in
            guard model.phase == .ready else { return false }
            if model.text != Self.replyText { model.text = Self.replyText }
            return true
        }
        env.pump(1.0)
        shoot(env, "06-nachrichten", sheet: toggle, sheetReady: ready)
        toggle.shown = true
        XCTAssertTrue(env.wait(timeout: 10) { ready() }, "Antwortfenster bereit: \(model.phase)")
        expect(env, "An Tutorium Grundlagen der Informatik")
    }

    /// Uebungsblatt mit Handschrift, darueber "In Stud.IP abgeben": Kurs, Abgabeordner, Dateiname, Notizen mitschicken
    func test07Abgeben() throws {
        seedNotesPumping("demo-blatt")
        let toggle = SheetSwitch()
        let model = Self.submitModel(defaults: container.defaults)
        let env = try host(WithSheet(base: MainView(), toggle: toggle) { StudIPSubmitSheet(model: model) })
        env.router.go(.doc("demo-blatt"))
        waitForInk(env)
        let ready = { model.phase == .ready && model.folderState == .loaded && model.prepared != nil }
        env.pump(1.0)
        shoot(env, "07-abgeben", ink: true, sheet: toggle, sheetReady: ready)
        toggle.shown = true
        XCTAssertTrue(env.wait(timeout: 10) { ready() }, "Abgabe bereit: \(model.phase) \(model.folderState)")
        expect(env, "Abgabe Übungsblatt 1")
    }

    func test08Community() throws {
        let env = try host(MainView())
        env.router.go(.community)
        expect(env, "Deine Communities")
        expect(env, "Grundlagen der Informatik")
        shoot(env, "08-community")
    }

    func test09Lernkalender() throws {
        let env = try host(MainView())
        env.router.go(.plan())
        expect(env, "Lernkalender")
        expect(env, "Übungsblatt 1")
        shoot(env, "09-lernkalender")
    }

    /// Mensa (05.11.2026, ersetzt den Stundenplan im Store-Satz): Speiseplan heute mit Preisen fuer Studierende,
    /// Kennzeichen und Naehrwerten aus dem erfundenen Plan (`MensaDemoHTTP`, kein Netz); an Wochenenden zeigt die Seite
    /// "Geschlossen", darum an einem Werktag aufnehmen (am Wochenende gilt der naechste Montag als heute, nur Debug)
    func test10Mensa() throws {
        UFFmt.todayOverride = StoreScreenshotV11Tests.nextServiceDay()
        defer { UFFmt.todayOverride = nil }
        let env = try host(MainView())
        env.router.go(.mensa)
        expect(env, "Gemüse-Kichererbsen-Curry mit Reis")
        expect(env, "Hähnchenbrust mit Kräuterkartoffeln")
        XCTAssertFalse(shows(env, "Geschlossen"), "Werktag mit Speiseplan:\n" + dump(env))
        env.pump(1.0)
        shoot(env, "10-mensa")
    }

    // MARK: - Reserve (nicht im Store-Satz)

    /// Ordneransicht (ohne Hochschulname); das Regal daneben nennt die Hochschule des Containers ("Mein Regal · Leibniz
    /// Universität Hannover") und einen KI-Hinweis, beides nur mit Freigabe des Inhabers
    func test11Bibliothek() throws {
        let env = try host(MainView())
        // Bereich "Neue Dateien": die drei Demo-Dokumente als Karten (die Ordnerwurzel zeigt nur den Modulordner)
        env.router.go(.files(section: "new", path: nil, q: nil))
        expect(env, "Zahlensysteme")
        shoot(env, "11-bibliothek", reserve: true)
        env.router.go(.files(section: "shelf", path: nil, q: nil))
        expect(env, "Mein Regal")
        expect(env, "Zahlensysteme")
        shoot(env, "11b-regal", reserve: true)
    }

    /// Editor mit Handschrift ohne KI (Ersatz fuer 02, wenn die KI nicht beworben wird)
    func test12Editor() throws {
        seedNotesPumping()
        let env = try host(MainView())
        env.router.go(.doc("demo-skript"))
        waitForInk(env)
        shoot(env, "12-editor", reserve: true, ink: true)
    }

    /// Tarifseite wie das Blatt "Tarif wechseln" aus den Einstellungen (UniFlowApp): Free als Stand, Plus daneben.
    /// Store-Stand zum Start: Pro AI kommt erst mit dem Dienst in den Store (docs/release/APP-STORE.md), darum eine
    /// StoreKit-Sitzung aus `UniFlow.storekit` ohne das Pro-AI-Produkt - die Seite zeigt dann Free, Plus und den Hinweis.
    func test13Tarife() throws {
        let bundled = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "UniFlow", withExtension: "storekit"))
        var config = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: bundled)) as? [String: Any])
        config["subscriptionGroups"] = (config["subscriptionGroups"] as? [[String: Any]] ?? []).map { group -> [String: Any] in
            var g = group
            g["subscriptions"] = (group["subscriptions"] as? [[String: Any]] ?? []).filter { ($0["productID"] as? String) != UFPlan.proAI.productID }
            return g
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString).storekit")
        try JSONSerialization.data(withJSONObject: config).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.resetToDefaultState()
        storeSession = session

        let page = ZStack { UF.bg.ignoresSafeArea(); PlanPickerView(context: .settings, entitlements: Entitlements.shared) {} }
        let env = try host(page)
        expect(env, UFPlan.plus.name)
        expect(env, UFPlan.free.name)
        expect(env, "1,99", timeout: 10)                                      // Preis aus der StoreKit-Sitzung
        expect(env, UFPlanCatalog.proAIMissingNote)
        XCTAssertFalse(shows(env, UFPlanCatalog.proAIServiceNote), "keine Pro-AI-Karte ohne Produkt im Store")
        shoot(env, "13-tarife", reserve: true)
    }

    /// StoreKit-Sitzung der Tarifseite (bleibt bis zum Ende des Tests)
    private var storeSession: SKTestSession?

    func test14Einstellungen() throws {
        let env = try host(MainView())
        env.router.go(.settings(tab: "account"))
        expect(env, "Zugang & Darstellung")
        shoot(env, "14-einstellungen", reserve: true)
    }

    func test15KIStart() throws {
        let t = aiTransport()
        let env = try host(MainView(), api: aiAPI(t), ai: true)
        env.router.go(.aiStart)
        XCTAssertTrue(env.wait { self.elements(in: env.view).contains { $0.accessibilityLabel?.hasPrefix("Hilfe.") == true } }, dump(env))
        XCTAssertTrue(tap("Hilfe.", in: env, exact: false))
        expect(env, AIHelpContent.title)
        // Beispielfrage ins Feld und senden: Antwort aus dem Schein-Transport
        let example = AIHelpContent.examples[0]
        if tap("Beispiel: \(example)", in: env) {
            _ = env.wait(timeout: 5) { self.elements(in: env.view).contains { $0.accessibilityLabel == "Frage senden" && !$0.accessibilityTraits.contains(.notEnabled) } }
            XCTAssertTrue(tap("Frage senden", in: env))
            XCTAssertTrue(env.wait { t.count("/api/ai/tutor") == 1 })
            expect(env, "Zahlensysteme in Kürze")
        }
        shoot(env, "15-ki-start", reserve: true)
    }

    /// Stundenplan (bis 05.11.2026 Bild 10 im Store-Satz, jetzt Reserve)
    func test16Stundenplan() throws {
        let env = try host(MainView())
        env.router.go(.timetable())
        expect(env, "Stundenplan")
        expect(env, "Grundlagen der Informatik")
        shoot(env, "16-stundenplan", reserve: true)
    }
}
