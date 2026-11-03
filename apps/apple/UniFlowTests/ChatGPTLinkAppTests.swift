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
        XCTAssertEqual(TutorConnectState.reason(st(reauth: true)), .reauth)
        XCTAssertEqual(TutorConnectState.reason(st(sharing: false)), .noSharing)
        XCTAssertEqual(TutorConnectState.reason(st(use: false)), .switchedOff)
        XCTAssertEqual(TutorConnectState.reason(st(model: "")), .noModel)
        XCTAssertEqual(TutorConnectState.reason(st()), .ready)
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
}
