import XCTest
import UniFlowCore
@testable import UniFlow

/// KI ueber das ChatGPT-Abo in der App: Ablage im Schluesselbund je Apple-Nutzer, Rueckleitung auf 127.0.0.1,
/// Anschluss ans lokale Backend und Loeschen mit dem Konto. Nie ins Netz (OpenAI wird nicht angefragt).
@MainActor
final class ChatGPTLinkAppTests: XCTestCase {

    func testWithAIThereAreWeeklyTestsBesideTheFlashcards() {
        let off = UFNavItem.visible(local: true, gradesOnDevice: true, community: false, flashcards: true).map(\.id)
        XCTAssertFalse(off.contains("exams"), "ohne KI keine Wochentests auf dem Geraet")
        XCTAssertTrue(off.contains("cards"))
        let on = UFNavItem.visible(local: true, gradesOnDevice: true, community: false, flashcards: true, ai: true).map(\.id)
        XCTAssertEqual(on.filter { ["exams", "cards"].contains($0) }, ["exams", "cards"])
        XCTAssertEqual(UFNoServerPage.Spec.examsWithAI.local, true)
        XCTAssertEqual(UFNoServerPage.Spec.exams.local, false)
    }

    func testTutorAsksForThePDFPageNotTheDisplayPosition() {
        XCTAssertEqual(DocumentView.pdfPage(key: "p3", index: 0), 3, "Originalseite 3, auch wenn sie vorne steht")
        XCTAssertEqual(DocumentView.pdfPage(key: "blank-1", index: 4), 5, "eingefuegte Seite: Position")
        XCTAssertEqual(DocumentView.pdfPage(key: nil, index: 0), 1)
        XCTAssertEqual(DocumentView.pdfPage(key: "p0", index: 2), 3, "kein gueltiger Seitenschluessel")
        XCTAssertEqual(TutorPanel.modes.map(\.key), AIPrompts.tutorModeKeys, "dieselben Modi wie app/ai.py")
        // Gespraech: die letzten Beitraege gehen als Verlauf mit, Karteikarten als Text
        var msgs = (0..<8).map { TutorPanel.Message(fromUser: $0 % 2 == 0, text: "B\($0)") }
        msgs.append(TutorPanel.Message(fromUser: false, text: "", cards: [["question": "F", "answer": "A"]]))
        let h = TutorPanel.history(msgs).array ?? []
        XCTAssertEqual(h.count, AIPrompts.tutorHistoryTurns)
        XCTAssertEqual(h.first?.s("text"), "B3")
        XCTAssertEqual(h.last?.s("role"), "assistant")
        XCTAssertEqual(h.last?.s("text"), "F – A")
        XCTAssertEqual(TutorPanel.label(mode: "steps", input: ""), "Aufgabe lösen")
        // verbunden heisst nicht bereit: die Leiste nennt den fehlenden Schritt
        func st(_ c: Bool = true, reauth: Bool = false, sharing: Bool = true, use: Bool = true, model: String = "gpt-x") -> ChatGPTSession.Status {
            ChatGPTSession.Status(connected: c, sharing: sharing, needsReauth: reauth, email: nil, name: nil, model: model, useForAI: use,
                                  registered: true, lastError: nil)
        }
        XCTAssertEqual(TutorConnectState.reason(nil), .notConnected)
        XCTAssertEqual(TutorConnectState.reason(st(false)), .notConnected)
        XCTAssertEqual(TutorConnectState.reason(st()), .notConnected, "Schalter aus: nie bereit, nie Neu verbinden")
        XCTAssertEqual(TutorConnectState.reason(st(reauth: true), enabled: true), .reauth)
        XCTAssertEqual(TutorConnectState.reason(st(sharing: false), enabled: true), .noSharing)
        XCTAssertEqual(TutorConnectState.reason(st(use: false), enabled: true), .switchedOff)
        XCTAssertEqual(TutorConnectState.reason(st(model: ""), enabled: true), .noModel)
        XCTAssertEqual(TutorConnectState.reason(st(), enabled: true), .ready)
        // KI-Fehler des Endpunkts ({"detail": {"detail", "code"}}): der Text von ChatGPT, nicht "Service Unavailable"
        let nested = APIError(status: 503, body: Data(#"{"detail": {"detail": "ChatGPT antwortete mit Fehler 404: model_not_found", "code": "ai_provider_error"}}"#.utf8))
        XCTAssertEqual(nested.errorDescription, "ChatGPT antwortete mit Fehler 404: model_not_found")
        // Daneben ein leeres Blatt: alle Vorlagen des Editors, Titel nach der offenen Datei
        XCTAssertEqual(CompanionPicker.blankTemplates.map(\.id), PageOrder.templates)
        XCTAssertTrue(CompanionPicker.blankTemplates.contains { $0.id == "grid" && $0.name == "Kariert" })
        XCTAssertEqual(CompanionPicker.sheetTitle(for: "Prog1-01-Introduction.pdf"), "Notizen – Prog1-01-Introduction")
        XCTAssertEqual(CompanionPicker.sheetTitle(for: " "), "Notizen")
        XCTAssertEqual(TutorPanel.label(mode: "ask", input: "Warum?"), "Warum?")
        XCTAssertEqual(DocumentView.tutorWidth(1180), 377.6, accuracy: 0.1)
        XCTAssertEqual(DocumentView.tutorWidth(700), 300)
    }

    /// KI-Leiste nennt das Modell, das geantwortet hat; ohne Modellliste des Kontos ein klarer Hinweis statt Stille
    func testTutorFooterNamesTheModelAndAMissingListGetsANote() {
        XCTAssertEqual(TutorPanel.footer(page: 3, model: "gpt-6.1-sol"), "Seite 3 · über dein ChatGPT · gpt-6.1-sol")
        XCTAssertEqual(TutorPanel.footer(page: 1, model: nil), "Seite 1 · über dein ChatGPT")
        XCTAssertEqual(TutorPanel.footer(page: 1, model: " "), "Seite 1 · über dein ChatGPT")
        XCTAssertEqual(ChatGPTLink.modelListNote(models: [], error: nil), ChatGPTLink.noModelListMessage)
        XCTAssertEqual(ChatGPTLink.modelListNote(models: [], error: AIError("chatgpt_http_error", "OpenAI antwortete mit Fehler 403: x")),
                       ChatGPTLink.noModelListMessage)
        XCTAssertNil(ChatGPTLink.modelListNote(models: ["gpt-6.1-sol"], error: nil))
        XCTAssertEqual(ChatGPTLink.modelListNote(models: [], error: AIError("chatgpt_login_needed", "neu verbinden")), "neu verbinden")
        XCTAssertEqual(ChatGPTLink.noModelListMessage, "Dein ChatGPT-Konto erlaubt keine Modellliste; StudiNow probiert die bekannten Modelle automatisch.")
    }

    func testKeychainKeepsEachAppleUserApart() throws {
        let a = ChatGPTKeychainStore(userScope: "test-a-\(UUID().uuidString)"), b = ChatGPTKeychainStore(userScope: "test-b-\(UUID().uuidString)")
        defer { ChatGPTKeychainStore.remove(userScope: a.userScope); ChatGPTKeychainStore.remove(userScope: b.userScope) }
        var s = ChatGPTState.new()
        s.clientID = "oaiapp_test"
        s.model = "gpt-test"
        try a.save(s)
        XCTAssertEqual(a.load(), s)
        XCTAssertNil(b.load(), "anderer Apple-Nutzer sieht nichts")
        XCTAssertTrue(ChatGPTKeychainStore.remove(userScope: a.userScope))
        XCTAssertNil(a.load())
        XCTAssertTrue(ChatGPTKeychainStore.remove(userScope: a.userScope), "nichts da gilt als geloescht")
    }

    func testLoopbackReceivesTheRedirectOnlyOnTheCallbackPath() async throws {
        let lb = ChatGPTLoopback()
        let port = try await lb.start()
        XCTAssertGreaterThan(port, 0)
        defer { lb.stop() }
        // falscher Pfad: 404, die Anmeldung wartet weiter
        let (_, wrong) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/anders?code=x")!)
        XCTAssertEqual((wrong as? HTTPURLResponse)?.statusCode, 404)
        let (body, ok) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)\(ChatGPTConstants.callbackPath)?code=c%2F1&state=s1&client_id=oaiapp_x")!)
        XCTAssertEqual((ok as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("StudiNow ist verbunden"))
        let q = try await lb.query()
        XCTAssertEqual(q, ["code": "c/1", "state": "s1", "client_id": "oaiapp_x"])
    }

    func testCancelledLoginEndsTheWait() async throws {
        let lb = ChatGPTLoopback()
        _ = try await lb.start()
        Task { try? await Task.sleep(nanoseconds: 100_000_000); lb.stop(AIError("chatgpt_flow", "Anmeldung abgebrochen.")) }
        do {
            _ = try await lb.query()
            XCTFail("muss abbrechen")
        } catch let e as AIError {
            XCTAssertEqual(e.message, "Anmeldung abgebrochen.")
        }
    }

    func testCardIsAvailableInEveryBuildWithoutAConfiguredClientID() {
        // dynamische Registrierung (`dynamic_agent_client`): keine vorab vergebene Client-ID noetig, auch im Release
        // (nicht mehr an `StudoraChatGPTClientID` gebunden)
        XCTAssertTrue(ChatGPTLink.available)
    }

    func testOtherAccountStartsANewRegistrationAndReconsentForcesTheConsentPage() async throws {
        let bed = try ContainerTestBed(name: "chatgpt-switch", clock: .fixed(berlin: "2026-10-30T09:00:00")!)
        let store = ChatGPTKeychainStore(userScope: DataContainerKey.userScope(bed.user))
        defer { ChatGPTKeychainStore.remove(userScope: store.userScope) }
        // bisheriges Konto: ausgestellte Client-ID und Profil (ohne Zugangsdaten, also nicht verbunden)
        var s = ChatGPTState.new()
        s.clientID = "oaiapp_alt"
        // der Memberwise-Initialisierer von `Profile` ist nicht oeffentlich: ueber Codable anlegen
        s.profile = try JSONDecoder().decode(ChatGPTState.Profile.self,
                                             from: Data(#"{"sub":"sub-alt","email":"alt@example.org","name":"Alt"}"#.utf8))
        try store.save(s)
        let m = bed.manager()
        _ = try bed.open(m, bed.account(.luh))
        await m.chatgpt.refresh()
        XCTAssertEqual(m.chatgpt.status?.registered, true)
        XCTAssertEqual(m.chatgpt.status?.email, "alt@example.org")

        // Anmeldung mit demselben Konto: ausgestellte ID und login_hint, keine Zustimmungsseite erzwungen
        let same = try await m.chatgpt.loginAttempt(port: 4321)
        XCTAssertEqual(same.clientID, "oaiapp_alt")
        XCTAssertTrue(same.url.contains("client_id=oaiapp_alt"))
        XCTAssertTrue(same.url.contains("login_hint=alt%40example.org"))
        XCTAssertFalse(same.url.contains("prompt=consent"))

        // Freigabe nachholen: Zustimmungsseite erzwingen, Konto bleibt
        let consent = try await m.chatgpt.loginAttempt(port: 4321, reconsent: true)
        XCTAssertTrue(consent.url.contains("prompt=consent"))
        XCTAssertEqual(consent.clientID, "oaiapp_alt")
        XCTAssertEqual(m.chatgpt.status?.registered, true)

        // Anderes Konto: neue Registrierung ohne Client-ID und Profil, Host-ID bleibt
        let fresh = try await m.chatgpt.loginAttempt(port: 4321, newAccount: true)
        XCTAssertNil(fresh.clientID)
        XCTAssertTrue(fresh.url.contains("client_id=\(ChatGPTConstants.firstClientID)"))
        XCTAssertTrue(fresh.url.contains("client_id=dynamic_agent_client"))
        XCTAssertFalse(fresh.url.contains("login_hint="))
        XCTAssertFalse(fresh.url.contains("prompt=consent"))
        XCTAssertEqual(m.chatgpt.status?.registered, false, "Stand nach dem Zuruecksetzen neu geladen")
        XCTAssertNil(m.chatgpt.status?.email)
        let saved = try XCTUnwrap(store.load())
        XCTAssertNil(saved.clientID)
        XCTAssertNil(saved.profile)
        XCTAssertNil(saved.credentials)
        XCTAssertEqual(saved.hostID, s.hostID, "die Geraetekennung bleibt")
        XCTAssertTrue(fresh.url.contains("ext_agent_host_id="))
        await m.chatgpt.session?.cancelLogin()
    }

    func testDebugBuildShowsTheCardAndDeleteAccountRemovesTheConnection() async throws {
        XCTAssertTrue(ChatGPTLink.available, "in jedem Build (dynamische Registrierung)")
        let bed = try ContainerTestBed(name: "chatgpt", clock: .fixed(berlin: "2026-10-29T09:00:00")!)
        // gespeicherte Verbindung des Nutzers (von einem frueheren Start), bevor sein Container aufgeht
        let store = ChatGPTKeychainStore(userScope: DataContainerKey.userScope(bed.user))
        var s = ChatGPTState.new()
        s.clientID = "oaiapp_test"
        try store.save(s)
        let m = bed.manager()
        let c = try bed.open(m, bed.account(.luh))
        XCTAssertEqual(c.key.userScope, store.userScope)
        await m.chatgpt.refresh()
        XCTAssertEqual(m.chatgpt.status?.registered, true)
        XCTAssertFalse(m.chatgpt.enabled, "ohne Anmeldung keine KI")
        let backend = try await c.host.backend()
        XCTAssertNil(backend.context.ai.provider, "nicht verbunden: das Backend bekommt keine KI")
        let problem = await m.deleteAllData(userID: bed.user)
        XCTAssertNil(problem)
        XCTAssertNil(store.load(), "Konto loeschen entfernt die ChatGPT-Verbindung")
    }

    // MARK: Schalter (05.11.2026): Sign in with ChatGPT fuer StudiNow noch nicht freigegeben

    func testSwitchOffOffersNoLoginAnywhere() async throws {
        XCTAssertFalse(ChatGPTLink.isEnabled, "bis zur Freigabe durch OpenAI aus (app/plans.py INTEGRATIONS chatgpt disabled)")
        XCTAssertEqual(ChatGPTLink.soonText, "Mit ChatGPT anmelden – bald verfügbar")
        XCTAssertEqual(ChatGPTLink.settingsTab, "account", "die KI-Stellen fuehren zu den Tarifen, nicht zur Anmeldung")
        // KI-Hilfe, KI-Start, Dialoge: Tarif-Hinweis (mit dem Weg zum eigenen OpenAI-Schluessel, 07.11.2026) und
        // "Tarife ansehen" statt "ChatGPT verbinden"
        XCTAssertEqual(TutorConnectState.Content.text(.notConnected).info, ChatGPTLink.planHint)
        XCTAssertTrue(ChatGPTLink.planHint.contains("StudiNow Pro AI") && ChatGPTLink.planHint.contains("OpenAI-Schlüssel"))
        XCTAssertEqual(TutorConnectState.Content.buttonTitle(.notConnected), "Tarife ansehen")
        XCTAssertFalse(UFNoServerContent.examsText.contains("ChatGPT"))
        XCTAssertEqual(AICost.line(chatgpt: false, plan: .plus, credits: 5), "Kommt mit StudiNow Pro AI oder deinem eigenen ChatGPT (Einstellungen → Erweitert)")

        // eine frueher gespeicherte Verbindung wird nicht benutzt und bietet kein "Neu verbinden"
        let bed = try ContainerTestBed(name: "chatgpt-off", clock: .fixed(berlin: "2026-11-05T09:00:00")!)
        let store = ChatGPTKeychainStore(userScope: DataContainerKey.userScope(bed.user))
        defer { ChatGPTKeychainStore.remove(userScope: store.userScope) }
        var s = ChatGPTState.new()
        s.clientID = "oaiapp_alt"
        try store.save(s)
        let m = bed.manager()
        let c = try bed.open(m, bed.account(.luh))
        await m.chatgpt.refresh()
        XCTAssertFalse(m.chatgpt.enabled)
        XCTAssertEqual(TutorConnectState.reason(m.chatgpt.status), .notConnected)
        let backend = try await c.host.backend()
        XCTAssertNil(backend.context.ai.provider, "das Backend bekommt keine KI ueber ChatGPT")
        // Verbinden startet keine Anmeldung (sie hinge nach der Kontowahl), nur der Hinweis
        await m.chatgpt.connect()
        XCTAssertFalse(m.chatgpt.connecting)
        XCTAssertEqual(m.chatgpt.message, ChatGPTLink.soonText + ".")
    }

    /// App-Pruefung 07.11.2026 (Richtlinie 2.1): die Einstellungen zeigen keine Karte "bald verfügbar" mehr; die
    /// Anmeldung bei ChatGPT kommt erst mit `isEnabled` (dann `ChatGPTCard`)
    func testSettingsShowNoSoonCard() throws {
        try ContainerTestBed.requireRepoSources()
        let settings = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("UniFlow/Views/Settings/SettingsPage.swift"), encoding: .utf8)
        XCTAssertFalse(settings.contains("ChatGPTSoonCard"))
        XCTAssertTrue(settings.contains("if ChatGPTLink.isEnabled { ChatGPTCard(link: chatgpt) }"))
    }
}
