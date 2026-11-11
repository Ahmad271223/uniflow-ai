import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Blatt, das sich beim Erscheinen oeffnet (wie aus einer Seite heraus); die Umgebung der Wurzel (`ufCompact`,
/// `openURL`) reicht hinein
private struct SheetPresenter<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var shown = false

    var body: some View {
        Color.clear
            .onAppear { shown = true }
            .sheet(isPresented: $shown) { content() }
    }
}

/// Lage der Flaeche des offenen Blatts im Fenster
@MainActor
private func sheetFrame(_ env: HostedEnvironment) -> CGRect {
    guard let presented = env.hosting.presentedViewController,
          let v = presented.presentationController?.presentedView ?? presented.view else { return .null }
    return v.convert(v.bounds, to: nil)
}

// MARK: - Pruefungsanmeldung

/// Pruefungsanmeldung auf dem iPhone (docs/IPHONE-2026-11-04.md, docs/PRUEFUNGSANMELDUNG-2026-11-05.md): Karte der
/// Uebersicht, Abschnitt im Studienverlauf und Block "Prüfung anmelden" einspaltig - Titel allein, "Im QIS anmelden"
/// in voller Breite darunter, nichts ragt bei 390, 402 und 440 pt (auch mit sehr grosser Schrift) ueber den Rand;
/// "Im QIS anmelden" oeffnet aus dem Blatt "Moduldetails" heraus. Gegenprobe iPad: Knopf rechts neben dem Titel.
/// Lokales Backend mit erfundenen Daten und eingefrorener Uhr (im Meldezeitraum), kein Netz.
final class IPhoneExamRegistrationTests: IPhoneLearnTestCase {

    private func seededAPI(now: String = "2026-11-20T10:00:00") throws -> APIClient {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-iphone-examreg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let host = LocalBackendHost(directory: dir.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: now)!)
        try awaiting { try await ExamRegistrationAppTests.seed(try await host.backend().context.database) }
        return APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
    }

    /// Ansicht in einer Seite mit 16 pt Rand und eigenem `openURL` (Aufrufe landen in `opened`)
    private final class Opened { var urls: [URL] = [] }

    private func page<V: View>(_ v: V, opened: Opened, typeSize: DynamicTypeSize = .large) -> some View {
        ScrollView { v.padding(.horizontal, UFCompactLearn.gutter).padding(.vertical, 16) }
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\.openURL, OpenURLAction { u in opened.urls.append(u); return .handled })
    }

    /// Karte der Uebersicht: eine Spalte, "Im QIS anmelden" breit unter dem Titel, "Im Studienverlauf" darunter,
    /// Abzeichen unter dem Modulnamen; oeffnet die QIS-Seite
    func testCardIsOneColumnAndOpensQIS() throws {
        let api = try seededAPI()
        let opened = Opened()
        let env = try hostPhone(page(ExamRegistrationCard(api: api, token: "t"), opened: opened), api: api)
        XCTAssertTrue(env.wait(timeout: 15) { self.shows(env, "Diese Prüfungen solltest du anmelden:") }, dump(env))
        let title = try XCTUnwrap(element(env, label: "Prüfungsanmeldung"), dump(env))
        let qis = try XCTUnwrap(button(env, ExamRegistrationAPI.openLabel("QIS")), dump(env))
        let list = try XCTUnwrap(button(env, "Im Studienverlauf"), dump(env))
        XCTAssertGreaterThan(frame(qis).minY, frame(title).maxY, "Knopf unter dem Titel, nicht daneben")
        XCTAssertGreaterThan(frame(qis).width, 300, "volle Breite: \(frame(qis))")
        XCTAssertGreaterThanOrEqual(frame(qis).height, 44, "Daumen")
        XCTAssertGreaterThan(frame(list).minY, frame(qis).maxY, "untereinander")
        XCTAssertEqual(frame(list).width, frame(qis).width, accuracy: 1)
        let row = try XCTUnwrap(element(env, label: "Algorithmen und Datenstrukturen, nicht angemeldet", prefix: true))
        XCTAssertGreaterThan(frame(row).height, 60, "Abzeichen unter dem Titel: \(frame(row))")
        assertFitsOnAllPhones(env, "Karte Prüfungsanmeldung")
        shoot(env, "iphone-pruefungsanmeldung-karte")
        XCTAssertTrue(qis.accessibilityActivate())
        env.pump()
        XCTAssertEqual(opened.urls.count, 1)
        XCTAssertTrue(opened.urls.first?.absoluteString.contains("moduleParameter=studyPOSMenu") == true)
    }

    /// Sehr grosse Schrift: Karte und Abschnitt ragen nicht ueber den Rand
    func testCardAndSectionFitWithLargeType() throws {
        let api = try seededAPI()
        let view = VStack(alignment: .leading, spacing: 16) {
            ExamRegistrationCard(api: api, token: "t")
            ExamRegistrationSection(api: api)
        }
        let env = try hostPhone(page(view, opened: Opened(), typeSize: .accessibility2), api: api)
        XCTAssertTrue(env.wait(timeout: 15) {
            self.shows(env, "Diese Prüfungen solltest du anmelden:") && self.shows(env, "Prüfungsanmeldung · WiSe 26/27")
        }, dump(env))
        assertFitsOnAllPhones(env, "Prüfungsanmeldung grosse Schrift")
    }

    /// Abschnitt im Studienverlauf: Titel mit Semester allein, Zeitraeume, Vorschlaege, "Im QIS anmelden" breit
    func testSectionIsOneColumn() throws {
        let api = try seededAPI()
        let opened = Opened()
        let env = try hostPhone(page(ExamRegistrationSection(api: api), opened: opened), api: api, size: CGSize(width: 402, height: 1800))
        XCTAssertTrue(env.wait(timeout: 15) { self.shows(env, "Prüfungsanmeldung · WiSe 26/27") }, dump(env))
        let title = try XCTUnwrap(element(env, label: "Prüfungsanmeldung · WiSe 26/27"))
        let qis = try XCTUnwrap(button(env, ExamRegistrationAPI.openLabel("QIS")), dump(env))
        XCTAssertGreaterThan(frame(qis).minY, frame(title).maxY)
        XCTAssertGreaterThan(frame(qis).width, 300)
        XCTAssertTrue(shows(env, "Diese Prüfungen solltest du anmelden"))
        XCTAssertTrue(shows(env, "An die Prüfungsanmeldung erinnern"))
        assertFitsOnAllPhones(env, "Abschnitt Prüfungsanmeldung")
        XCTAssertTrue(qis.accessibilityActivate())
        env.pump()
        XCTAssertEqual(opened.urls.count, 1)
    }

    /// Blatt "Moduldetails" (von unten): Block "Prüfung anmelden" einspaltig, "Im QIS anmelden" im Blatt erreichbar und
    /// wirksam; der In-App-Browser legt sich ueber das Blatt (oberstes Blatt = dieses)
    func testModuleBlockInSheetOpensQIS() throws {
        let api = try seededAPI()
        let opened = Opened()
        let root = SheetPresenter { StudyModuleSheet(startID: "algorithmen", api: api) { _ in } }
            .environment(\.openURL, OpenURLAction { u in opened.urls.append(u); return .handled })
        let env = try hostPhone(root, api: api)
        XCTAssertTrue(env.wait(timeout: 20) { self.sheetOpen(env) && self.button(env, ExamRegistrationAPI.openLabel("QIS")) != nil }, dump(env))
        XCTAssertTrue(shows(env, "Prüfung anmelden"))
        // ganze Hoehe: der Block steht vollstaendig im Blatt
        if let sheet = env.hosting.presentedViewController?.sheetPresentationController {
            sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
            env.pump(0.6)
        }
        let qis = try XCTUnwrap(button(env, ExamRegistrationAPI.openLabel("QIS")))
        let area = sheetFrame(env)
        XCTAssertTrue(area.contains(frame(qis)), "Knopf im Blatt: \(frame(qis)) in \(area)")
        XCTAssertGreaterThan(frame(qis).width, 280, "volle Breite im Blatt: \(frame(qis))")
        XCTAssertTrue(UniWebBrowser.topController() === env.hosting.presentedViewController, "Browser oeffnet ueber dem Blatt")
        assertFitsOnAllPhones(env, "Moduldetails mit Prüfung anmelden")
        shoot(env, "iphone-pruefungsanmeldung-modul")
        XCTAssertTrue(qis.accessibilityActivate())
        env.pump()
        XCTAssertEqual(opened.urls.count, 1, "aus dem Blatt heraus")
        XCTAssertTrue(sheetOpen(env), "Blatt bleibt offen, der Browser legt sich darueber")
        dismissSheet(env)
    }

    /// Gegenprobe iPad: Knopf rechts neben dem Titel (eine Zeile), Knoepfe darunter nebeneinander
    func testPadKeepsButtonBesideTitle() throws {
        let api = try seededAPI()
        let env = try hostPad(page(ExamRegistrationCard(api: api, token: "t"), opened: Opened()), api: api)
        XCTAssertTrue(env.wait(timeout: 15) { self.shows(env, "Diese Prüfungen solltest du anmelden:") }, dump(env))
        let title = try XCTUnwrap(element(env, label: "Prüfungsanmeldung"))
        let qis = try XCTUnwrap(button(env, ExamRegistrationAPI.openLabel("QIS")))
        XCTAssertEqual(frame(qis).midY, frame(title).midY, accuracy: 12, "neben dem Titel")
        XCTAssertLessThan(frame(qis).width, 300, "klein wie bisher (Beschriftung seit 09.11. „Im QIS zur Prüfung anmelden“)")
    }
}

// MARK: - Antworten auf Nachrichten

/// Antworten auf Stud.IP-Nachrichten auf dem iPhone (docs/NACHRICHTEN-ANTWORTEN-2026-11-05.md): "Antworten" im Leser
/// oeffnet das Fenster als Blatt von unten (halb/ganz); "Senden" steht in einer Leiste am unteren Rand, bei halber
/// Hoehe sichtbar und ueber der Tastatur; wer ins Textfeld tippt, bekommt das ganze Blatt. Gegenprobe iPad: Senden im
/// Formular wie bisher. Stud.IP als Stub (`UniStubProtocol`), erfundene Nachrichten.
final class IPhoneMessageReplyTests: IPhoneLearnTestCase {

    override func tearDown() {
        UniStubProtocol.reset()
        super.tearDown()
    }

    private func defaults() throws -> UserDefaults {
        let suite = "uniflow-iphone-antworten-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return d
    }

    private func model(defaults: UserDefaults) -> MessageReplyModel {
        let deps = MessageReplyModel.Dependencies(
            connected: { true },
            ensureSession: { _ in .ready },
            client: {
                StudIPClient(base: StudIPSync.base,
                             transport: URLSessionStudIPWriter(cookies: [MessageReplyAppTests.cookie()], host: MessageReplyAppTests.host,
                                                               configuration: UniStubProtocol.configuration()),
                             pauseMillis: 0)
            },
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_793_890_000) })
        return MessageReplyModel(original: MessageReplyAppTests.original, mode: .sender, dependencies: deps)
    }

    private var posts: Int { UniStubProtocol.requests.filter { $0.method == "POST" }.count }

    /// Erste UITextView im Blatt (das Textfeld der Antwort)
    private func textView(_ env: HostedEnvironment) -> UITextView? {
        func find(_ v: UIView) -> UITextView? {
            if let t = v as? UITextView, t.isEditable { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        return env.hosting.presentedViewController.flatMap { find($0.view) }
    }

    /// Leser schmal: "Antworten" passt, oeffnet ein Blatt von unten mit halber und ganzer Hoehe
    func testReaderReplyOpensBottomSheet() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-iphone-antworten-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let backendHost = LocalBackendHost(directory: dir.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-04T10:30:00")!)
        let inbox: JSONValue = ["data": [
            ["id": "m1", "type": "messages", "attributes": ["subject": "Gruppenarbeit", "message": "Wer macht Teil 2?", "mkdate": "2026-11-04T08:15:00+01:00"],
             "relationships": ["sender": ["data": ["type": "users", "id": "u-x"]],
                               "recipients": ["data": [["type": "users", "id": "u-me"], ["type": "users", "id": "u-a"]]]]],
        ], "included": [["id": "u-x", "type": "users", "attributes": ["permission": "autor"]]]]
        try awaiting {
            let backend = try await backendHost.backend()
            var d = StudIPExtras.Download()
            d.messages = StudIPExtras.parseMessages(inbox["data"], included: inbox["included"], base: "https://studip.example", today: 20761)
            d.messageMeta = StudIPExtras.parseMessageMeta(inbox["data"])
            let clock = backend.context.clock
            try await backend.context.database.transaction { try StudIPExtras.store(d, in: $0, clock: clock) }
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: backendHost))
        let env = try hostPhone(MessagesPage(today: "2026-11-04"), api: api)
        env.router.go(.messages)
        // Zeile: "Neu, Gruppenarbeit, von …" bzw. "Gruppenarbeit, von …"
        func row() -> NSObject? {
            elements(env).first { $0.accessibilityTraits.contains(.button) && ($0.accessibilityLabel ?? "").contains("Gruppenarbeit") }
        }
        XCTAssertTrue(env.wait(timeout: 15) { row() != nil }, dump(env))
        let row = try XCTUnwrap(row())
        XCTAssertTrue(row.accessibilityActivate())
        XCTAssertTrue(env.wait { self.button(env, MessagesText.reply) != nil }, dump(env))
        XCTAssertNotNil(button(env, MessagesText.replyAll))
        assertFitsOnAllPhones(env, "Leser mit Antworten")
        XCTAssertTrue(tap(env, MessagesText.reply))
        // ohne Stud.IP-Sitzung zeigt das Blatt den Hinweis; Blatt von unten mit halber und ganzer Hoehe
        XCTAssertTrue(waitSheet(env, showing: "Stud.IP ist nicht verbunden"), dump(env))
        let sheet = try XCTUnwrap(env.hosting.presentedViewController?.sheetPresentationController)
        XCTAssertEqual(Set(sheet.detents.map(\.identifier)), [.medium, .large])
        XCTAssertTrue(sheet.prefersGrabberVisible)
        assertFits(env, "Blatt Antworten")
        dismissSheet(env)
    }

    /// Formular schmal: "Senden" in der Leiste unten - bei halber Hoehe sichtbar, nach dem Tippen ins Textfeld ganzes
    /// Blatt, ueber der Tastatur (bzw. einem gleich hohen unteren Bereich), sendet genau einmal
    func testComposerKeepsSendReachable() throws {
        MessageReplyAppTests.install(post: MessageReplyAppTests.created)
        let m = model(defaults: try defaults())
        let env = try hostPhone(SheetPresenter { MessageReplySheet(model: m) }, api: .local(.unavailable))
        XCTAssertTrue(waitSheet(env, showing: "An Prof. Erika Test"), dump(env))
        let sheet = try XCTUnwrap(env.hosting.presentedViewController?.sheetPresentationController)
        XCTAssertEqual(Set(sheet.detents.map(\.identifier)), [.medium, .large])
        XCTAssertNotEqual(sheet.selectedDetentIdentifier, .large, "oeffnet halb")
        XCTAssertEqual(elements(env).filter { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel == "Senden" }.count, 1,
                       "Senden nur einmal (in der Leiste)")

        // halbe Hoehe: Senden sichtbar im Blatt, am unteren Rand
        var send = try XCTUnwrap(button(env, "Senden"))
        var area = sheetFrame(env)
        XCTAssertTrue(area.contains(frame(send)), "Senden im sichtbaren Blatt: \(frame(send)) in \(area)")
        XCTAssertLessThanOrEqual(frame(send).maxY, env.window.bounds.maxY)
        XCTAssertGreaterThan(frame(send).minY, area.midY, "unten im Blatt")
        XCTAssertGreaterThan(frame(send).width, 300, "volle Breite")
        XCTAssertTrue(send.accessibilityTraits.contains(.notEnabled), "ohne Text gesperrt")
        assertFitsOnAllPhones(env, "Antworten halb")

        // Tippen ins Textfeld: ganzes Blatt. Fenster so gross wie der Bildschirm des Simulators (die Tastatur rechnet
        // vom Bildschirmrand, ein groesseres Fenster laege mit seinem unteren Teil darunter)
        env.window.frame = env.window.screen.bounds
        env.view.frame = env.window.bounds
        env.pump(0.6)
        var keyboard: CGRect?
        let observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { n in
            let f = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated { keyboard = f }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let editor = try XCTUnwrap(textView(env), "Textfeld")
        XCTAssertTrue(editor.becomeFirstResponder())
        XCTAssertTrue(env.wait(timeout: 5) { sheet.selectedDetentIdentifier == .large }, "ganzes Blatt beim Schreiben")
        env.pump(0.8)
        area = sheetFrame(env)
        send = try XCTUnwrap(button(env, "Senden"))
        if let k = keyboard, k.height > 0, k.minY < env.window.bounds.maxY {
            // Bildschirmtastatur da: Senden darueber
            let above = env.wait(timeout: 4) { self.frame(self.button(env, "Senden")).maxY <= k.minY + 1 }
            XCTAssertTrue(above, "Senden über der Tastatur: \(frame(button(env, "Senden"))) / \(k) / Blatt \(sheetFrame(env)) / \(String(describing: keyboard))")
        }
        // "Tastatur ausblenden" in der Leiste neben "Senden"
        XCTAssertTrue(tap(env, MessageReplySheet.hideKeyboard), dump(env))
        XCTAssertTrue(env.wait(timeout: 3) { !editor.isFirstResponder }, "Tastatur aus")
        XCTAssertEqual(sheet.selectedDetentIdentifier, .large)
        XCTAssertTrue(env.wait(timeout: 3) { self.button(env, MessageReplySheet.hideKeyboard) == nil })
        // gleich hoher unterer Bereich (auch ohne Bildschirmtastatur, z. B. mit Hardware-Tastatur): Leiste steigt mit
        let presented = try XCTUnwrap(env.hosting.presentedViewController)
        presented.additionalSafeAreaInsets.bottom = 320
        env.pump(0.6)
        send = try XCTUnwrap(button(env, "Senden"))
        XCTAssertLessThanOrEqual(frame(send).maxY, area.maxY - 320 + 1, "Senden über dem unteren Bereich: \(frame(send)) in \(area)")
        XCTAssertGreaterThanOrEqual(frame(send).minY, area.minY)
        presented.additionalSafeAreaInsets.bottom = 0
        env.pump(0.4)

        // senden
        m.text = "Danke für die Info!"
        env.pump(0.3)
        send = try XCTUnwrap(button(env, "Senden"))
        XCTAssertFalse(send.accessibilityTraits.contains(.notEnabled))
        shoot(env, "iphone-antworten-blatt")
        XCTAssertTrue(send.accessibilityActivate())
        XCTAssertTrue(env.wait(timeout: 10) { self.shows(env, "Gesendet") }, dump(env))
        XCTAssertEqual(posts, 1)
        dismissSheet(env)
    }

    /// Gegenprobe iPad: keine Leiste, Senden im Formular, keine Hoehen von unten
    func testPadKeepsSendInForm() throws {
        MessageReplyAppTests.install(post: MessageReplyAppTests.created)
        let m = model(defaults: try defaults())
        let env = try hostPad(SheetPresenter { MessageReplySheet(model: m) }, api: .local(.unavailable))
        XCTAssertTrue(waitSheet(env, showing: "An Prof. Erika Test"), dump(env))
        // Senden steht im Formular (unten in der Liste): dorthin rollen
        func scrollViews(_ v: UIView) -> [UIScrollView] { ((v as? UIScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrollViews) }
        for sv in env.hosting.presentedViewController.map({ scrollViews($0.view) }) ?? [] {
            sv.setContentOffset(CGPoint(x: 0, y: max(0, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)), animated: false)
        }
        env.pump(0.5)
        XCTAssertNotNil(button(env, "Senden"), dump(env))
        XCTAssertNil(button(env, MessageReplySheet.hideKeyboard))
        let detents = env.hosting.presentedViewController?.sheetPresentationController?.detents.map(\.identifier) ?? [.large]
        XCTAssertFalse(detents.contains(.medium), "iPad unveraendert")
        dismissSheet(env)
    }
}
