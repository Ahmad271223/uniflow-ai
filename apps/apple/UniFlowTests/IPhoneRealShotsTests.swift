import PDFKit
import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// App-Store-Bilder fuer das iPhone 6,9" mit **echten Daten** statt Demo-Inhalten (Auftrag des Inhabers 14.11.2026):
/// 440 x 956 Punkte, Massstab 3 = 1320 x 2868 Pixel, hochkant, hell und dunkel.
///
/// Der Test laeuft nur mit `UF_REAL_DB` (xcodebuild: `TEST_RUNNER_UF_REAL_DB`) – dem Pfad einer **gesaeuberten Kopie**
/// der Datenbank des Inhabers – und `UF_SCREENSHOT_DIR`; sonst wird er uebersprungen. Die Kopie wird vor der ersten
/// Anfrage in den Container gelegt; das Original bleibt unberuehrt, geschrieben wird nur in die Kopie im Container.
/// Gesaeubert heisst (Skript `saeubern.py` neben der Kopie): keine Lehrenden, keine Nachrichten, keine Ankuendigungen,
/// kein Schwarzes Brett, keine Aufzeichnungen, kein Name Dritter in Modul-, Kurs- oder Dateinamen, kein Rufname.
///
/// Kein Netz: `UniStubProtocol` beantwortet jede Anfrage an eine Hochschule mit 404 und zaehlt sie mit (tearDown
/// prueft 0). Uni-Mail kommt aus einer Nachbildung im Speicher (eigener Entwurf, keine echten Mails), die KI-Antworten
/// aus Schein-Transporten.
@MainActor
final class IPhoneRealShotsTests: XCTestCase {

    /// iPhone 17 Pro Max hochkant in Punkten (x3 = 1320 x 2868 Pixel)
    static let size = CGSize(width: 440, height: 956)
    /// Modul fuer das Moduldetail und die Leseansicht (echtes Modul des Inhabers)
    static let modulName = "Grundlagen digitaler Systeme"
    /// Datei, deren Seiten der Test selbst erzeugt (die PDFs liegen nicht in der Kopie)
    static let leseDatei = "GDS_Kap_2.pdf"
    /// Fester Tag fuer alle Bilder: Montag, 16.11.2026 (Vorlesungen, Lernbloecke, Mensa offen, Meldezeitraum laeuft).
    /// Der echte Tag der Aufnahme waere ein Samstag – dann sind Startseite und Kalender leer.
    static let tag = "2026-11-16"

    private var bed: ContainerTestBed!
    private var manager: ContainerManager!
    private var account: AccountStore!
    private var container: ActiveContainer!
    private var uniMail: UniMailConnection!
    private var outDir: URL?
    /// Kennung der Datei, deren Seiten der Test geschrieben hat (Bild 5)
    private var leseDateiID = ""

    override func setUp() async throws {
        try await super.setUp()
        let env = ProcessInfo.processInfo.environment
        guard let quelle = env["UF_REAL_DB"], !quelle.isEmpty, FileManager.default.isReadableFile(atPath: quelle) else {
            throw XCTSkip("Nur mit UF_REAL_DB (Kopie der echten Datenbank); ohne sie gibt es nichts zu fotografieren.")
        }
        continueAfterFailure = true
        bed = try ContainerTestBed(name: "shots-echt", clock: .fixed(berlin: "\(Self.tag)T10:30:00")!)
        UniStubProtocol.install { _ in UniStubProtocol.Reply(status: 404) }
        UniMailConnection.readsDemoForScreenshots = true
        UFGreeting.hourOverride = 14
        UFFmt.todayOverride = Self.tag
        let sogo = EntwurfSOGo()
        manager = ContainerManager(
            base: bed.containers,
            legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
            keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock, publishesCurrent: true,
            uniMailTransport: { _ in sogo })
        account = bed.account(.luh)
        container = try bed.open(manager, account)
        account.markLoginDone()

        // Die Kopie an die Stelle der frischen Datenbank legen – vor der ersten Anfrage (das Backend oeffnet erst dann)
        let ziel = container.host.databaseURL
        let fm = FileManager.default
        try fm.createDirectory(at: ziel.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let u = URL(fileURLWithPath: ziel.path + suffix)
            if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
        }
        try fm.copyItem(at: URL(fileURLWithPath: quelle), to: ziel)

        Entitlements.shared.setPlanForTesting(.proAI)
        MessagesInbox.shared.defaultsOverride = container.defaults
        await MessagesInbox.shared.refresh(api: container.api)
        let backend = try await container.host.backend()
        backend.context.ai.set(MailKI())
        try await seiteSchreiben()
        try await planErzeugen()

        uniMail = try XCTUnwrap(manager.uniMail, "LUH hat Uni-Mail")
        uniMail.refreshesAfterSignIn = false
        let store = uniMail.websiteDataStore.httpCookieStore
        await store.setCookie(bed.cookie("0xHIGHFLYxSOGo", "erfundene-sitzung", domain: SOGoSite.luh.host, path: "/SOGo"))
        await store.setCookie(bed.cookie("XSRF-TOKEN", "erfunden", domain: SOGoSite.luh.host, path: "/SOGo"))
        uniMail.signedIn(user: Self.mailUser)

        UFCompact.phoneOverride = true
        UFEditorAvailability.forcedReaderOnlyForTesting = true
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        if let dir = env["UF_SCREENSHOT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            outDir = url
        }
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        UFCompact.phoneOverride = UniFlowTestsPrincipal.deviceDefault
        UFEditorAvailability.forcedReaderOnlyForTesting = UniFlowTestsPrincipal.readerOnlyDefault
        UniMailConnection.readsDemoForScreenshots = false
        UFGreeting.hourOverride = nil
        UFFmt.todayOverride = nil
        Entitlements.shared.setPlanForTesting(.free)
        MessagesInbox.shared.defaultsOverride = nil
        await MessagesInbox.shared.refresh(api: nil)
        XCTAssertEqual(UniStubProtocol.requests.count, 0, "keine Anfrage an eine Hochschule")
        UniStubProtocol.reset()
        manager?.deactivate()
        await bed?.tearDown()
        try await super.tearDown()
    }

    // MARK: - Vorbereiten

    /// Lernplan fuer diese Woche erzeugen (die Kopie hat keinen): `POST /api/calendar/generate` wie „Plan erstellen“
    private func planErzeugen() async throws {
        let r = try? await container.api.value("/api/calendar/generate", method: "POST",
                                               body: ["start": .string(Self.tag), "days": 7, "replace": .bool(true)])
        if r == nil { XCTFail("Lernplan konnte nicht erzeugt werden") }
    }

    /// Die PDFs liegen nicht in der Kopie (nur die Einträge). Für die Leseansicht eine Seite selbst schreiben und sie
    /// an die echte Datei des Moduls hängen; Dateiname, Kurs und Modul bleiben echt.
    private func seiteSchreiben() async throws {
        let backend = try await container.host.backend()
        let relativ = "StudIP/files/bilder/\(Self.leseDatei)"
        _ = try container.layout.files().write(Self.skriptPDF(), to: relativ)
        let jetzt = bed.clock.nowISO
        let name = Self.leseDatei
        let id: String? = try await backend.context.database.transaction { c in
            try c.execute("""
                UPDATE files SET local_path=?, downloaded_at=?, page_count=3, mime='application/pdf'
                WHERE name=? AND deleted_at IS NULL
                """, [.text(relativ), .text(jetzt), .text(name)])
            return try c.queryOne("SELECT id FROM files WHERE name=? AND deleted_at IS NULL", [.text(name)])?["id"]?.string
        }
        leseDateiID = try XCTUnwrap(id, "Datei „\(name)“ in der Kopie gefunden")
    }

    /// Drei Seiten im Stil einer Vorlesungsfolie (von uns geschrieben, weil die echten PDFs fehlen)
    private static func skriptPDF() -> Data {
        let seiten: [(String, [String])] = [
            ("2  Zahlensysteme und Codierung", [
                "2.1  Stellenwertsysteme",
                "Jede Zahl lässt sich als Summe von Potenzen der Basis schreiben.",
                "Dual (Basis 2), Oktal (Basis 8), Hexadezimal (Basis 16).",
                "Beispiel: 13 = 1101 (dual) = D (hexadezimal)",
                "",
                "2.2  Umrechnung",
                "Dezimal nach dual: fortgesetzte Division durch 2, Reste von unten lesen.",
                "Dual nach dezimal: Stellenwerte 1, 2, 4, 8, 16 ... addieren.",
            ]),
            ("2.3  Negative Zahlen", [
                "Zweierkomplement: alle Bits invertieren, dann 1 addieren.",
                "Mit 8 Bit reicht der Bereich von -128 bis 127.",
                "Ein Überlauf zeigt sich am Vorzeichenbit.",
                "",
                "Übung: Bilde das Zweierkomplement von -37 mit 8 Bit.",
            ]),
            ("2.4  Codes", [
                "BCD: jede Dezimalziffer in vier Bit.",
                "Gray-Code: zwischen zwei Nachbarn ändert sich genau ein Bit.",
                "ASCII und Unicode für Zeichen.",
            ]),
        ]
        let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: a4).pdfData { ctx in
            for (titel, zeilen) in seiten {
                ctx.beginPage()
                UIColor.white.setFill()
                ctx.fill(a4)
                let kopf: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 21), .foregroundColor: UIColor.black]
                let text: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.black]
                titel.draw(at: CGPoint(x: 56, y: 70), withAttributes: kopf)
                var y: CGFloat = 120
                for z in zeilen {
                    z.draw(at: CGPoint(x: 56, y: y), withAttributes: text)
                    y += 24
                }
            }
        }
    }

    // MARK: - Schein-Dienste

    static let mailUser = "vorname.nachname@stud.example.org"

    /// Vorschlag der KI für „Mit KI verbessern“ (erfunden, nichts verlässt den Prozess)
    private struct MailKI: AIProvider {
        func answer(system: String, prompt: String) async throws -> String {
            """
            Sehr geehrte Damen und Herren,

            ich studiere Wirtschaftsingenieurwesen im 3. Semester und habe eine Frage zur Prüfungsanmeldung für \
            „Grundlagen digitaler Systeme“: Ist eine Anmeldung noch möglich, wenn der Leistungsnachweis aus dem \
            Labor erst im Dezember eingetragen wird?

            Vielen Dank für Ihre Hilfe und viele Grüße
            """
        }
    }

    /// Postfach mit einem einzigen, selbst geschriebenen Entwurf: keine echten Mails, keine fremden Absender
    private final class EntwurfSOGo: UniTransport, @unchecked Sendable {
        static let entwurf = """
            hallo,
            ich wollte fragen ob ich mich noch für grundlagen digitaler systeme anmelden kann obwohl der laborschein \
            erst im dezember eingetragen wird.
            danke
            """

        func send(_ request: UniRequest) async throws -> UniResponse {
            let p = request.url.path
            func json(_ v: JSONValue) -> UniResponse {
                UniResponse(status: 200, headers: ["Content-Type": "application/json"], finalURL: request.url, body: v.serialized())
            }
            if p.hasSuffix("/Mail/0/view") {
                return json(["mailboxes": [["name": "INBOX", "path": "INBOX", "type": "inbox", "flags": [], "children": []],
                                           ["name": "Drafts", "path": "Drafts", "type": "draft", "flags": [], "children": []],
                                           ["name": "Sent", "path": "Sent", "type": "sent", "flags": [], "children": []]]])
            }
            if p.hasSuffix("/folderINBOX/view") { return json(["uids": [], "headers": [], "unseenCount": 0]) }
            if p.hasSuffix("/Mail/unseenCount") { return json(["0/folderINBOX": 0]) }
            if p.hasSuffix("/Mail/0/compose") { return json(["accountId": "0", "mailboxPath": "Drafts", "draftId": "7"]) }
            if p.hasSuffix("/edit") {
                return json(["from": .string(IPhoneRealShotsTests.mailUser), "to": ["pruefungsamt@example.org"], "cc": [], "bcc": [],
                             "subject": "Frage zur Prüfungsanmeldung", "text": .string(Self.entwurf), "isHTML": 0, "attachmentAttrs": []])
            }
            return json([:])
        }

        func download(_ request: UniRequest, to destination: URL) async throws -> UniResponse {
            UniResponse(status: 404, finalURL: request.url)
        }
    }

    private func tutorTransport() -> StoreScreenshotTests.Intercept {
        let t = StoreScreenshotTests.Intercept(container.host)
        t.answer("/api/ai/document/plan", StoreScreenshotTests.docPlan)
        t.answer("/api/ai/document/step", StoreScreenshotTests.docSteps[0], StoreScreenshotTests.docSteps[1])
        t.answer("/api/ai/tutor", StoreScreenshotTests.tutorAnswer)
        return t
    }

    // MARK: - Hosten und Fotografieren

    private func host<V: View>(_ view: V, api: APIClient? = nil, ai: Bool = false) throws -> HostedEnvironment {
        let root = view
            .environment(\.ufAIEnabled, ai)
            .environment(\.ufStudiNowAI, ai)
            .environment(\.ufAIAccess, ai ? .ready : .planRequired)
            .environment(\.uniMail, uniMail)
            .environmentObject(manager!)
            .environmentObject(account!)
        let env = try hostWithEnvironment(root, api: api ?? container.api, size: Self.size, studip: manager.studip)
        env.hosting.traitOverrides.horizontalSizeClass = .compact
        env.hosting.traitOverrides.verticalSizeClass = .regular
        env.pump(0.5)
        return env
    }

    private func shoot(_ env: HostedEnvironment, _ name: String, settle: Double = 1.2) {
        for wort in ["Demo", "ChatGPT", "Pro AI holen", "Fehler", "Nicht verbunden", AIConsentText.title] {
            XCTAssertFalse(shows(env, wort), "\(name): „\(wort)“ im Bild:\n" + dump(env))
        }
        guard let outDir else { return }
        StoreScreenshotTests.shoot(env, name, folder: outDir, sizes: [(Self.size, "portrait")], scale: 3, ink: false,
                                   settle: settle, cornerRadius: 36, statusBar: true)
    }

    // MARK: - Bedienungshilfen

    private func elements(_ env: HostedEnvironment) -> [NSObject] {
        env.window.layoutIfNeeded()
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: Any, depth: Int) {
            guard depth < 80 else { return }
            if let o = element as? NSObject {
                guard seen.insert(ObjectIdentifier(o)).inserted else { return }
                let id = (o as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? ""
                if o.accessibilityLabel?.isEmpty == false || o.accessibilityValue?.isEmpty == false || !id.isEmpty { out.append(o) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<min(n, 600) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } }
                }
            }
            if let v = element as? UIView, !v.isHidden { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(env.window, depth: 0)
        if let sheet = env.hosting.presentedViewController?.view { visit(sheet, depth: 0) }
        return out
    }

    private func texts(_ env: HostedEnvironment) -> [String] {
        elements(env).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
    }

    private func shows(_ env: HostedEnvironment, _ text: String) -> Bool { texts(env).contains { $0.contains(text) } }

    private func dump(_ env: HostedEnvironment) -> String { texts(env).joined(separator: " | ") }

    @discardableResult
    private func tap(_ env: HostedEnvironment, label: String, prefix: Bool = false) -> Bool {
        for e in elements(env) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, prefix ? l.hasPrefix(label) : l == label else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    @discardableResult
    private func tap(_ env: HostedEnvironment, id: String) -> Bool {
        elements(env).first { ($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier == id }?.accessibilityActivate() ?? false
    }

    @discardableResult
    private func expect(_ env: HostedEnvironment, _ text: String, timeout: Double = 20, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let ok = env.wait(timeout: timeout) { self.shows(env, text) }
        XCTAssertTrue(ok, "„\(text)“ fehlt:\n" + dump(env), file: file, line: line)
        return ok
    }

    private func sichtbar(_ env: HostedEnvironment, _ label: String) -> Bool {
        let b = env.window.bounds
        for e in elements(env) {
            guard let l = e.accessibilityLabel, l.hasPrefix(label) else { continue }
            let f = e.accessibilityFrame
            if f.minY > b.minY + 70, f.maxY < b.maxY - 90 { return true }
        }
        return false
    }

    /// Steht dieser Text im sichtbaren Teil des Fensters? (für Dinge, die auf dem Bild nicht erscheinen dürfen)
    private func imBild(_ env: HostedEnvironment, _ text: String) -> Bool {
        let b = env.window.bounds
        for e in elements(env) {
            let inhalt = [e.accessibilityLabel, e.accessibilityValue].compactMap { $0 }.joined(separator: " ")
            guard inhalt.contains(text) else { continue }
            let f = e.accessibilityFrame
            if f.intersects(b), f.height > 0 { return true }
        }
        return false
    }

    @discardableResult
    private func scrollUntil(_ env: HostedEnvironment, label: String, steps: Int = 12) -> Bool {
        func listen(_ v: UIView) -> [UIScrollView] {
            var out: [UIScrollView] = []
            if let s = v as? UIScrollView, s.contentSize.height > s.bounds.height + 20 { out.append(s) }
            for c in v.subviews where !c.isHidden { out += listen(c) }
            return out
        }
        for _ in 0..<steps {
            if sichtbar(env, label) { return true }
            guard let s = listen(env.window).max(by: { $0.bounds.height < $1.bounds.height }) else { return false }
            let maxY = max(0, s.contentSize.height - s.bounds.height)
            let next = min(maxY, s.contentOffset.y + s.bounds.height * 0.6)
            if next <= s.contentOffset.y + 1 { break }
            s.setContentOffset(CGPoint(x: s.contentOffset.x, y: next), animated: false)
            env.pump(0.5)
        }
        return sichtbar(env, label)
    }

    /// Segment des Umfangs wählen („Diese Seite | Ganzes Dokument | Seiten …“)
    private func selectScope(_ env: HostedEnvironment, _ title: String) -> Bool {
        func find(_ v: UIView) -> UISegmentedControl? {
            if let s = v as? UISegmentedControl, (0..<s.numberOfSegments).contains(where: { s.titleForSegment(at: $0) == title }) { return s }
            for c in v.subviews where !c.isHidden { if let s = find(c) { return s } }
            return nil
        }
        guard let control = find(env.window),
              let i = (0..<control.numberOfSegments).first(where: { control.titleForSegment(at: $0) == title }) else { return false }
        control.selectedSegmentIndex = i
        control.sendActions(for: .valueChanged)
        env.pump(0.3)
        return true
    }

    /// Knopf mit dieser Beschriftung unter `root` (Blatt) auslösen
    private func activate(in root: UIView?, label: String) -> Bool {
        guard let root else { return false }
        var found: NSObject?
        var seen = Set<ObjectIdentifier>()
        func visit(_ e: Any, depth: Int) {
            guard found == nil, depth < 80 else { return }
            if let o = e as? NSObject {
                guard seen.insert(ObjectIdentifier(o)).inserted else { return }
                if o.accessibilityLabel == label { found = o; return }
                for c in o.accessibilityElements ?? [] { visit(c, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 600) { if let c = o.accessibilityElement(at: i) { visit(c, depth: depth + 1) } } }
            }
            if let v = e as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return found?.accessibilityActivate() ?? false
    }

    private func modulID() throws -> Int {
        var id: Int?
        let api = container.api
        Task { @MainActor in
            let v = try? await api.value("/api/modules")
            let list = v?.items ?? []
            id = list.first(where: { $0.s("name") == Self.modulName })?.i("id") ?? list.first?.i("id")
        }
        let end = Date().addingTimeInterval(25)
        while id == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return try XCTUnwrap(id, "Modul „\(Self.modulName)“ gefunden")
    }

    // MARK: - Satz 01-07

    /// 1 Startseite mit dem echten Semester: Lernpakete von heute, Termine, Prüfungsanmeldung
    func test01Start() throws {
        let env = try host(MainView())
        expect(env, "Grundlagen digitaler Systeme")
        shoot(env, "01-start")
    }

    /// 2 Lernkalender: zwei Kandidaten in einem Lauf – „Liste“ und „3 Tage“. Für den Store den, der voller wirkt;
    /// „Woche“ zeigt am iPhone eine Tagesliste und passt nicht zum Namen (Rückmeldung des Inhabers 14.11.2026).
    func test02Lernkalender() throws {
        let env = try host(MainView())
        env.router.go(.plan(view: "list"))
        expect(env, "Lernkalender")
        env.pump(2.0)
        shoot(env, "02-lernkalender-liste", settle: 1.6)
        env.router.go(.plan(view: "3days", date: Self.tag))
        env.pump(2.0)
        shoot(env, "02-lernkalender-3tage", settle: 1.6)
    }

    /// 3 Moduldetail mit Lehrwochen und Haken „erledigt“
    func test03Modul() throws {
        let id = try modulID()
        let env = try host(MainView())
        env.router.go(.module(id))
        expect(env, Self.modulName)
        env.pump(1.5)
        _ = env.openWeeks()
        env.pump(1.0)
        for label in ["Erledigt: GDS_Einführung", "Erledigt: GDS_Kap_2"] {
            _ = tap(env, label: label, prefix: true)
            env.pump(0.8)
        }
        _ = scrollUntil(env, label: "Erledigt: ")
        env.pump(1.0)
        shoot(env, "03-modul", settle: 1.6)
    }

    /// 4 Uni-Mail „Neue E-Mail“ mit „Mit KI verbessern“ und dem Vorschlag der KI (eigener Entwurf, keine echte Mail)
    func test04UniMailKI() throws {
        let env = try host(UniMailComposeSheet(connection: uniMail, request: UniMailComposeRequest())
            .environment(\.ufCompact, true), ai: true)
        expect(env, "Frage zur Prüfungsanmeldung")
        let getippt = env.wait(timeout: 15) { self.tap(env, label: "Mit KI verbessern") || self.tap(env, id: "unimail.ai") }
        XCTAssertTrue(getippt, "„Mit KI verbessern“:\n" + dump(env))
        expect(env, "Vorschlag der KI", timeout: 25)
        _ = scrollUntil(env, label: "Übernehmen")
        env.pump(1.0)
        shoot(env, "04-uni-mail-ki", settle: 1.6)
    }

    /// 5 KI-Hilfe über der Leseansicht eines echten Skripts (Seiteninhalt von uns, die PDFs fehlen in der Kopie)
    func test05KIHilfe() throws {
        let t = tutorTransport()
        let env = try host(MainView(), api: APIClient(base: APIClient.localBase, transport: t), ai: true)
        env.router.go(.doc(leseDateiID))
        expect(env, "Zahlensysteme")
        env.pump(1.5)
        XCTAssertTrue(tap(env, id: "phoneReader.tutor") || tap(env, label: "KI-Hilfe"), "KI-Hilfe öffnen:\n" + dump(env))
        XCTAssertTrue(env.wait(timeout: 15) { self.selectScope(env, "Ganzes Dokument") }, "Umfang „Ganzes Dokument“:\n" + dump(env))
        let gestartet = env.wait(timeout: 15) {
            self.tap(env, id: "tutor.doc.lecture") || self.tap(env, label: "Ganze Vorlesung erklären")
                || self.activate(in: env.hosting.presentedViewController?.view, label: "Ganze Vorlesung erklären")
        }
        XCTAssertTrue(gestartet, dump(env))
        XCTAssertTrue(env.wait(timeout: 20) { t.count("/api/ai/document/step") == 2 }, "zwei Teile geholt")
        if let sheet = env.hosting.presentedViewController?.sheetPresentationController {
            sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
        }
        env.pump(2.0)
        shoot(env, "05-ki-hilfe", settle: 1.6)
    }

    /// 6 Studienverlauf mit Leistungspunkten (ohne einzelne Noten im Bild – Entscheidung mit dem Inhaber)
    func test06Studienverlauf() throws {
        let env = try host(MainView())
        env.router.go(.studyPlan())
        expect(env, "Studienverlauf")
        env.pump(1.5)
        // Einzelne Noten gehören nicht auf ein öffentliches Bild (Entscheidung 14.11.2026): nur Leistungspunkte
        for heikel in ["nicht bestanden", "5,0", "Note"] {
            XCTAssertFalse(imBild(env, heikel), "06: „\(heikel)“ wäre im Bild:\n" + dump(env))
        }
        shoot(env, "06-studienverlauf", settle: 1.6)
    }

    /// 7 Mensa an einem Werktag
    func test07Mensa() throws {
        let env = try host(MainView())
        env.router.go(.mensa)
        env.pump(2.0)
        XCTAssertFalse(shows(env, "Geschlossen"), "Werktag mit Speiseplan:\n" + dump(env))
        shoot(env, "07-mensa", settle: 1.6)
    }
}
