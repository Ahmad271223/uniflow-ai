import Foundation
import XCTest
@testable import UniFlowCore

// StudiNow-Wissensbank (20.11.2026, app/wissensbank.py): Die App schickt bei `explain`/`steps` die Angaben zur Stelle
// (Dateititel wie in Stud.IP, Kurs, Seite, verglichener Text) nur, wenn der Dienst die Funktion meldet; sie reicht
// Abzeichen und Ja/Nein-Kennung weiter, speichert eine Wissensbank-Antwort nie im geteilten Erklaerungsspeicher und
// laeuft mit einem alten Dienst ohne die Felder wie bisher. Gegen einen Schein-Dienst, nie ins Netz.

final class WissensbankTests: XCTestCase {
    private let base = "https://dienst.example"

    private func make() -> (StudiNowAI, FakeService) {
        let fake = FakeService()
        let ai = StudiNowAI(base: base, http: fake, tokens: MemoryTokenStore("tok"), consent: FixedConsent(true))
        return (ai, fake)
    }

    private func backend(_ ai: StudiNowAI?) async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-20T09:00:00")!)
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, kind, active, created_at) VALUES ('c1', 'Beispiel-Statik', 'vorlesung', 1, '2026-10-26')")
            try c.execute("INSERT INTO files(id, course_id, name, kind, status) VALUES ('f1', 'c1', 'Übungsblatt 03 - Balken.pdf', 'pdf', 'neu')")
        }
        if let ai { b.context.ai.setService(ai) }
        return b
    }

    private func post(_ b: LocalBackend, _ path: String, _ body: JSONValue) async -> LocalResponse {
        await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device" + path)!,
                                    headers: ["Content-Type": "application/json"], body: body.serialized()))
    }

    private let credits: JSONValue = ["period": "2026-11", "allowance": 100, "used": 1, "reserved": 0, "remaining": 99, "plan": "pro_ai",
                                      "charged": 1, "replay": false]

    private func sent(_ fake: FakeService) async throws -> JSONValue {
        let req = await fake.last("/api/ai/relay")
        return try JSONValue.parse(try XCTUnwrap(req?.body))
    }

    func testStelleGoesAlongOnlyWhenTheServiceAnnouncesIt() async throws {
        let (ai, fake) = make()
        let b = try await backend(ai)
        await fake.on("POST", "/api/ai/relay", 200, ["answer": "KI-Antwort", "credits": credits])
        var r = await post(b, "/api/ai/tutor", ["mode": "steps", "file_id": "f1", "page": 2, "page_text": "Aufgabe 1 a) Ein Träger …"])
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        var body = try await sent(fake)
        XCTAssertNil(body["wissensbank"], "ohne Meldung des Dienstes geht nichts zusaetzlich mit")
        XCTAssertEqual(r.json?["wissensbank"], .null, "alter Dienst: keine Felder, keine Frage")

        ai.wissensbankEnabled = true
        await fake.on("POST", "/api/ai/relay", 200, ["answer": "## Aufgabe 1 a)\n\nLösung …", "credits": credits, "source": "wissensbank",
                                                     "wissensbank_key": "steps:Fach/G0002/02#Q1-Aufgabe-1-a",
                                                     "wissensbank": ["badge": "Aus der StudiNow-Wissensbank", "status": "",
                                                                     "hinweise": ["KI-Lösung, ungeprüft"]]])
        r = await post(b, "/api/ai/tutor", ["mode": "steps", "file_id": "f1", "page": 2, "page_text": "Seitentext 2",
                                            "selection": "Aufgabe 1 a) markiert"])
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        body = try await sent(fake)
        XCTAssertEqual(body["wissensbank"], ["datei": "Übungsblatt 03 - Balken.pdf", "kurs": "Beispiel-Statik", "seite": 2,
                                             "text": "Aufgabe 1 a) markiert"], "markierter Text vor dem Seitentext")
        let info = r.json?["wissensbank"]
        XCTAssertTrue(Wissensbank.isFromWissensbank(info))
        XCTAssertEqual(Wissensbank.detail(info), "KI-Lösung, ungeprüft")
        XCTAssertNil(Wissensbank.feedbackToken(info))
    }

    /// Meldung des Inhabers 21.11.2026: "Seite erklären" kam nie aus der Wissensbank, weil der Erklaerungsspeicher zuerst
    /// antwortete. Die ganze Seite fragt jetzt zuerst kurz bei der Wissensbank nach: Treffer -> diese Antwort, ohne
    /// die KI zu rufen; kein Treffer (oder alter Dienst) -> kostet nichts, weiter wie bisher.
    func testWholePageAsksTheWissensbankBeforeAnythingElse() async throws {
        let (ai, fake) = make()
        ai.wissensbankEnabled = true
        let b = try await backend(ai)
        await fake.on("POST", "/api/ai/wissensbank", 200, ["treffer": true, "answer": "## Seite 2\n\nErklärung aus der Bibliothek", "credits": credits,
                                                           "source": "wissensbank", "wissensbank_key": "explain:Fach/G0001/01#Q1-Seite-2",
                                                           "wissensbank": ["badge": "Aus der StudiNow-Wissensbank", "status": "", "hinweise": []]])
        var r = await post(b, "/api/ai/tutor", ["mode": "explain", "file_id": "f1", "page": 2, "page_text": "Folientext der Seite zwei"])
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        XCTAssertEqual(r.json?["answer"]?.string, "## Seite 2\n\nErklärung aus der Bibliothek")
        XCTAssertTrue(Wissensbank.isFromWissensbank(r.json?["wissensbank"]), "Abzeichen: Antwort aus der Wissensbank")
        XCTAssertEqual(r.json?["explain"], .null, "geht nicht in den Erklaerungsspeicher")
        let probeRequest = await fake.last("/api/ai/wissensbank")
        let probe = try JSONValue.parse(try XCTUnwrap(probeRequest?.body))
        XCTAssertEqual(probe["mode"]?.string, "explain")
        XCTAssertEqual(probe["wissensbank"]?["text"]?.string, "Folientext der Seite zwei")
        XCTAssertEqual(probe["wissensbank"]?["seite"]?.double, 2)
        let relayBefore = await fake.last("/api/ai/relay")
        XCTAssertNil(relayBefore, "Treffer: die KI wird nicht gerufen")
        // kein Treffer: weiter zur KI wie bisher
        await fake.on("POST", "/api/ai/wissensbank", 200, ["treffer": false, "grund": "kein_treffer"])
        await fake.on("POST", "/api/ai/relay", 200, ["answer": "KI-Antwort", "credits": credits])
        r = await post(b, "/api/ai/tutor", ["mode": "explain", "file_id": "f1", "page": 1, "page_text": "Eine ganz andere Seite"])
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        XCTAssertEqual(r.json?["answer"]?.string, "KI-Antwort")
        XCTAssertFalse(Wissensbank.isFromWissensbank(r.json?["wissensbank"]))
        // alter Dienst (kennt die Vorab-Frage nicht): stolpert nicht
        await fake.on("POST", "/api/ai/wissensbank", 404, ["detail": "Not Found"])
        await fake.on("POST", "/api/ai/relay", 200, ["answer": "KI-Antwort 2", "credits": credits])
        r = await post(b, "/api/ai/tutor", ["mode": "explain", "file_id": "f1", "page": 3, "page_text": "Noch eine andere Seite"])
        XCTAssertEqual(r.json?["answer"]?.string, "KI-Antwort 2")
        // ohne Meldung des Dienstes: keine Vorab-Frage
        ai.wissensbankEnabled = false
        let asked = await fake.requests.filter { $0.url.hasSuffix("/api/ai/wissensbank") }.count
        await fake.on("POST", "/api/ai/relay", 200, ["answer": "KI-Antwort 3", "credits": credits])
        _ = await post(b, "/api/ai/tutor", ["mode": "explain", "file_id": "f1", "page": 4, "page_text": "Seite vier"])
        let askedAfter = await fake.requests.filter { $0.url.hasSuffix("/api/ai/wissensbank") }.count
        XCTAssertEqual(askedAfter, asked, "Wissensbank nicht gemeldet: nichts zusaetzlich")
    }

    func testOtherModesImagesAndMissingFilesSendNothing() async throws {
        let (ai, fake) = make()
        ai.wissensbankEnabled = true
        let b = try await backend(ai)
        for _ in 0..<3 { await fake.on("POST", "/api/ai/relay", 200, ["answer": "KI", "credits": credits]) }
        _ = await post(b, "/api/ai/tutor", ["mode": "hints", "file_id": "f1", "page": 1, "page_text": "Aufgabe"])
        var body = try await sent(fake)
        XCTAssertNil(body["wissensbank"], "Hinweise sind keine Wissensbank-Frage")
        _ = await post(b, "/api/ai/tutor", ["mode": "explain", "page": 1, "page_text": "Seite ohne Datei"])
        body = try await sent(fake)
        XCTAssertNil(body["wissensbank"], "ohne Datei kein Dateititel")
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: 64)).base64EncodedString()
        _ = await post(b, "/api/ai/tutor", ["mode": "explain", "file_id": "f1", "page": 1, "page_text": "Seite", "image": .string(jpeg)])
        body = try await sent(fake)
        XCTAssertNil(body["wissensbank"], "Bereich an KI ohne erkannten Text: nie der Text der ganzen Seite")
        // eingekreiste Aufgabe (Bild mit erkanntem Text): die Wissensbank wird mit diesem Text gefragt (21.11.2026)
        await fake.on("POST", "/api/ai/relay", 200, ["answer": "KI", "credits": credits])
        _ = await post(b, "/api/ai/tutor", ["mode": "explain", "file_id": "f1", "page": 1, "page_text": "Seite", "image": .string(jpeg),
                                             "selection": "Aufgabe 1 a) eingekreist"])
        body = try await sent(fake)
        XCTAssertEqual(body["wissensbank"]?["text"]?.string, "Aufgabe 1 a) eingekreist", "Bereich an KI mit Text: Ausschnitt geht an die Wissensbank")
        XCTAssertNotNil(body["image"], "das Bild geht weiter mit (fuer die KI, falls die Wissensbank nichts hat)")
    }

    func testRepeatAnswerCarriesTheQuestionAndFeedbackGoesToTheService() async throws {
        let (ai, fake) = make()
        ai.wissensbankEnabled = true
        let b = try await backend(ai)
        await fake.on("POST", "/api/ai/relay", 200, ["answer": "Neue KI-Antwort", "credits": credits, "source": "ki",
                                                     "wissensbank_key": "explain:Fach/G0001/01#Q1-Seite-2", "feedback_token": "abc",
                                                     "feedback_question": "Gefällt dir diese Antwort besser?"])
        let r = await post(b, "/api/ai/tutor", ["mode": "explain", "file_id": "f1", "page": 3, "page_text": "Seitentext"])
        let info = r.json?["wissensbank"]
        XCTAssertFalse(Wissensbank.isFromWissensbank(info))
        XCTAssertEqual(Wissensbank.feedbackToken(info), "abc")
        await fake.on("POST", "/api/ai/feedback", 200, ["ok": true, "stored": true])
        let f = await post(b, "/api/ai/feedback", ["token": "abc", "better": true])
        XCTAssertEqual(f.status, 200, String(decoding: f.body, as: UTF8.self))
        XCTAssertEqual(f.json?["stored"], true)
        let req = await fake.last("/api/ai/feedback")
        XCTAssertEqual(try JSONValue.parse(try XCTUnwrap(req?.body)), ["token": "abc", "better": true])
        XCTAssertEqual(req?.headers["Authorization"], "Bearer tok")
        let bad = await post(b, "/api/ai/feedback", ["token": "abc", "better": "ja"])
        XCTAssertEqual(bad.status, 400)
    }

    func testFeedbackWithoutStudiNowAIIsNotThere() async throws {
        let b = try await backend(nil)
        let r = await post(b, "/api/ai/feedback", ["token": "abc", "better": false])
        XCTAssertEqual(r.status, 404)
    }

    func testOfflineFeedbackFailsFriendlyWithoutCrash() async throws {
        let (ai, fake) = make()
        let b = try await backend(ai)
        await fake.setOffline(true)
        let r = await post(b, "/api/ai/feedback", ["token": "abc", "better": true])
        XCTAssertEqual(r.status, 503)
    }

    func testFieldsAndRequestHelpers() {
        XCTAssertEqual(Wissensbank.fields(in: ["answer": "x", "credits": .null]), .null)
        XCTAssertEqual(Wissensbank.fields(in: ["answer": "x", "source": "ki"]), .null, "nur 'ki' ohne Stelle: nichts anzuzeigen")
        XCTAssertEqual(Wissensbank.detail(["source": "wissensbank", "wissensbank": ["status": "geprüft", "hinweise": []]]), "geprüft")
        XCTAssertNil(Wissensbank.request(mode: "summary", fileName: "a.pdf", course: "", page: 1, pageText: "x", selection: ""))
        XCTAssertNil(Wissensbank.request(mode: "explain", fileName: "a.pdf", course: "", page: 1, pageText: "  ", selection: ""))
        let long = String(repeating: "a", count: Wissensbank.textMax + 50)
        XCTAssertEqual(Wissensbank.request(mode: "explain", fileName: "a.pdf", course: "K", page: 4, pageText: long, selection: "")?["text"]?.string?.count,
                       Wissensbank.textMax)
    }
}
