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
        XCTAssertEqual(TutorSheet.modes.map(\.key), AIPrompts.tutorModeKeys, "dieselben Modi wie app/ai.py")
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
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("Studora ist verbunden"))
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

    func testDebugBuildShowsTheCardAndDeleteAccountRemovesTheConnection() async throws {
        #if DEBUG
        XCTAssertTrue(ChatGPTLink.available, "im Debug-Build fuer die eigene Nutzung des Inhabers")
        #endif
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
