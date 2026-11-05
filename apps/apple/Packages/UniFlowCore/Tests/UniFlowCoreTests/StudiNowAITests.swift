import Foundation
import XCTest
@testable import UniFlowCore

// StudiNow-KI auf dem iPad (05.11.2026): das lokale Backend baut den Prompt, die StudiNow-KI schickt ihn mit Aufgabe und
// Sitzungs-Token an `POST /api/ai/relay` (app/ai_relay.py). Gegen einen Schein-Dienst (`FakeService`), nie ins Netz,
// keine echte KI: Form jeder Anfrage, Credits in der Antwort, Fehlercodes mit Text und Knopf, Token, Weg der KI.

final class StudiNowAITests: XCTestCase {
    private let base = "https://dienst.example"

    private func balance(remaining: Int = 37, charged: Int? = 3) -> JSONValue {
        var c: [String: JSONValue] = ["period": "2026-11", "allowance": 100, "used": .number(Double(100 - remaining)), "reserved": 0,
                                      "remaining": .number(Double(remaining)), "plan": "pro_ai", "resets_at": "2026-12-01T00:00:00+01:00"]
        if let charged { c["charged"] = .number(Double(charged)); c["replay"] = false }
        return .object(c)
    }

    private func make(token: String? = "tok", credits: CreditsBox? = nil, signedOut: CreditsBox? = nil) -> (StudiNowAI, FakeService, MemoryTokenStore) {
        let fake = FakeService(), store = MemoryTokenStore(token)
        let ai = StudiNowAI(base: base + "/", http: fake, tokens: store,
                            onCredits: { c in credits?.add(c) }, onSignedOut: { signedOut?.add(.null) })
        return (ai, fake, store)
    }

    final class CreditsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [JSONValue] = []
        func add(_ v: JSONValue) { lock.withLock { items.append(v) } }
        var all: [JSONValue] { lock.withLock { items } }
    }

    private func backend(_ ai: StudiNowAI) async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-05T09:00:00")!)
        b.context.ai.setService(ai)
        return b
    }

    private func post(_ b: LocalBackend, _ path: String, _ body: JSONValue) async -> LocalResponse {
        await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device" + path)!,
                                    headers: ["Content-Type": "application/json"], body: body.serialized()))
    }

    private func body(_ r: AIHTTPRequest?) throws -> JSONValue { try JSONValue.parse(try XCTUnwrap(r?.body)) }

    // MARK: Tutor ueber /api/ai/relay

    func testTutorGoesToTheRelayWithTaskPromptTokenAndReturnsCredits() async throws {
        let box = CreditsBox()
        let (ai, fake, _) = make(credits: box)
        await fake.on("POST", "/api/ai/relay", 200, ["answer": "Erklärung [1]", "model": "gpt-6-luna", "shared": false, "replay": false,
                                                     "credits": balance(), "task": "tutor:hints"])
        let b = try await backend(ai)
        let r = await post(b, "/api/ai/tutor", ["mode": "hints", "page_text": "Aufgabe 2", "selection": "markiert", "question": "Wie?"])
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        XCTAssertEqual(r.json?["answer"], "Erklärung [1]")
        XCTAssertEqual(r.json?["credits"]?["remaining"], 37, "Credits-Stand fuer die Kostenzeile")
        XCTAssertEqual(r.json?["credits"]?["charged"], 3)
        let lastReq = await fake.last("/api/ai/relay")
        let req = try XCTUnwrap(lastReq)
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.url, "https://dienst.example/api/ai/relay", "kein doppelter Schraegstrich")
        XCTAssertEqual(req.headers["Authorization"], "Bearer tok")
        XCTAssertEqual(req.headers["Content-Type"], "application/json")
        let sent = try body(req)
        XCTAssertEqual(sent["task"], "tutor:hints")
        XCTAssertEqual(sent["prompt"]?.string, AIPrompts.tutor(mode: "hints", pageText: "Aufgabe 2", selection: "markiert", question: "Wie?", page: .int("1")))
        XCTAssertEqual(sent["route_text"], "markiert Wie?")
        XCTAssertNil(sent["cache"], "Frage mit Markierung ist nicht geteilt")
        XCTAssertNil(sent["image"])
        XCTAssertNil(sent["system"], "System-Text waehlt der Dienst")
        XCTAssertEqual(sent["request_id"]?.string?.count, 32)
        XCTAssertEqual(box.all.first?["remaining"], 37, "App bekommt den neuen Stand")
    }

    /// "Bereich an KI": das Bild geht als `image` (Base64) mit, nie mit `cache`; zu grosse Bilder gar nicht
    func testTutorImageGoesAlongAsBase64() async throws {
        let (ai, fake, _) = make()
        await fake.on("POST", "/api/ai/relay", 200, ["answer": "Im Bild steht eine Formel.", "credits": balance()])
        let b = try await backend(ai)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 7, count: 64))
        let r = await post(b, "/api/ai/tutor", ["mode": "explain", "page_text": "Seite", "image": .string(jpeg.base64EncodedString())])
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        let sent = try body(await fake.last("/api/ai/relay"))
        XCTAssertEqual(sent["task"], "tutor:explain")
        XCTAssertEqual(sent["image"]?.string.flatMap { Data(base64Encoded: $0) }, jpeg)
        XCTAssertNil(sent["cache"])
        XCTAssertTrue(sent["prompt"]?.string?.hasSuffix(AIPrompts.tutorImageNote) == true)

        // Grenze 3 MB: direkt am Anbieter (der Endpunkt laesst groessere Bilder schon vorher weg)
        let big = Data(count: StudiNowAI.imageMaxBytes + 1)
        do {
            _ = try await AIRelayTask.run(AIRelayTask("tutor:explain", image: big)) { try await ai.answer(system: "", prompt: "x") }
            XCTFail("zu gross")
        } catch let e as LocalHTTPError {
            XCTAssertEqual(e.status, 413)
            XCTAssertEqual(e.detail["code"], "image_invalid")
        }
        do {
            _ = try await AIRelayTask.run(AIRelayTask("flashcards", image: jpeg)) { try await ai.answer(system: "", prompt: "x") }
            XCTFail("Bild nur fuer tutor:*")
        } catch let e as LocalHTTPError {
            XCTAssertEqual(e.detail["code"], "image_not_allowed")
        }
        let relays = await fake.requests.filter { $0.url.hasSuffix("/api/ai/relay") }
        XCTAssertEqual(relays.count, 1, "abgelehnte Bilder gehen nicht an den Dienst")
    }

    /// Geteilte ganze Seite: erst der eigene Speicher, dann `cache` beim Dienst; "Neu erklaeren" = `fresh` ohne `cache`
    func testWholePageAsksTheServiceCacheAndForceIsFresh() async throws {
        let (ai, fake, _) = make()
        let b = try await backend(ai)
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, kind, created_at, active) VALUES ('k1', 'Testmathe I', 'vorlesung', '2026-10-01', 1)")
            try c.execute("INSERT INTO files(id, course_id, name, chdate, kind) VALUES ('f1', 'k1', 'vl.pdf', 5, 'pdf')")
            try c.execute("INSERT INTO page_texts(file_id, page, text, chdate, search) VALUES ('f1', 1, 'Grenzwerte von Folgen', 5, 'grenzwerte von folgen')")
        }
        await fake.on("POST", "/api/ai/relay", 200, ["answer": "A", "shared": true, "credits": balance(charged: 0)])
        await fake.on("POST", "/api/ai/relay", 200, ["answer": "B", "credits": balance()])
        _ = await post(b, "/api/ai/tutor", ["mode": "summary", "file_id": "f1", "page": 1])
        _ = await post(b, "/api/ai/tutor", ["mode": "summary", "file_id": "f1", "page": 1, "force": true])
        let sent = await fake.requests.filter { $0.url.hasSuffix("/api/ai/relay") }.compactMap { $0.body.flatMap { try? JSONValue.parse($0) } }
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first?["task"], "tutor:summary")
        // ohne Datei-SHA keinen eigenen Speicher: dann fragt der Endpunkt den Dienst mit cache (gleiche Seite = 0 Credits)
        XCTAssertEqual(sent.first?["cache"]?.bool, true)
        XCTAssertNil(sent.last?["cache"])
        XCTAssertEqual(sent.last?["fresh"]?.bool, true)
    }

    // MARK: weitere Aufgaben

    func testFlashcardsWeekTestGradeAndWeeklyUseTheirTasks() async throws {
        let (ai, fake, _) = make()
        await fake.on("POST", "/api/ai/relay", 200, ["answer": #"[{"question": "Q", "answer": "A"}]"#, "credits": balance()])
        let fc = try await AIRelayTask.run(AIRelayTask("flashcards")) { try await ai.answer(system: "s", prompt: "Karten", schema: AIPrompts.flashcardsSchema) }
        XCTAssertEqual(fc.credits["charged"], 3)
        var sent = try body(await fake.last("/api/ai/relay"))
        XCTAssertEqual(sent["task"], "flashcards")
        XCTAssertNil(sent["schema"], "Schema waehlt der Dienst zur Aufgabe")

        await fake.on("POST", "/api/ai/relay", 200, ["answer": "{}", "credits": .null])
        let opts = WeekTestOptions(count: 10, difficulty: "mittel", types: ["mc"], topic: "Folgen")
        let wt = try await AIRelayTask.run(AIRelayTask("week_test", options: .object(opts.json), exam: false)) { try await ai.answer(system: "s", prompt: "Test") }
        XCTAssertEqual(wt.credits, .null, "Wochentest ohne Credits")
        sent = try body(await fake.last("/api/ai/relay"))
        XCTAssertEqual(sent["task"], "week_test")
        XCTAssertEqual(sent["options"]?["count"], 10)
        XCTAssertEqual(sent["options"]?["topic"], "Folgen")
        XCTAssertEqual(sent["exam"]?.bool, false)

        for task in ["grade", "weekly"] {
            await fake.on("POST", "/api/ai/relay", 200, ["answer": "{}"])
            _ = try await AIRelayTask.run(AIRelayTask(task)) { try await ai.answer(system: "s", prompt: "p") }
            let r = await fake.last("/api/ai/relay")
            XCTAssertEqual(try body(r)["task"]?.string, task)
        }
        XCTAssertEqual(AIRelayTask.tutor("voellig_neu"), "tutor:explain", "unbekannter Modus wie in app/ai.py")
        XCTAssertTrue(AIRelayTask.isKnown("tutor:check"))
        XCTAssertFalse(AIRelayTask.isKnown("tutor:frei"))
        XCTAssertFalse(AIRelayTask.isKnown("analysis"))
    }

    /// Ohne Aufgabe (Einordnen einer Datei, Dokument-Index) antwortet die StudiNow-KI nicht und sendet nichts
    func testWithoutTaskNothingIsSent() async throws {
        let (ai, fake, _) = make()
        let b = try await backend(ai)
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, kind, created_at, active) VALUES ('k1', 'Kurs', 'vorlesung', '2026-10-01', 1)")
            try c.execute("INSERT INTO files(id, course_id, name, chdate, kind) VALUES ('f1', 'k1', 'vl.pdf', 5, 'pdf')")
        }
        let r = await post(b, "/api/files/f1/analyze", .object([:]))
        XCTAssertEqual(r.status, 404)
        XCTAssertEqual(r.json?["detail"]?["code"], "ai_task_unsupported")
        XCTAssertEqual(r.json?["detail"]?["detail"]?.string, StudiNowAIText.unsupported)
        let n = await fake.requests.count
        XCTAssertEqual(n, 0)
        XCTAssertNil(b.context.docIndex.ai(from: ai), "kein Index mit Credits")
    }

    // MARK: Fehler des Dienstes

    private func failure(_ status: Int, _ detail: JSONValue, headers: [String: String] = [:], token: String? = "tok",
                         offline: Bool = false) async -> (LocalHTTPError?, FakeService, MemoryTokenStore, CreditsBox) {
        let gone = CreditsBox()
        let (ai, fake, store) = make(token: token, signedOut: gone)
        await fake.on("POST", "/api/ai/relay", status, ["detail": detail], headers: headers)
        if offline { await fake.setOffline(true) }
        do {
            _ = try await AIRelayTask.run(AIRelayTask("tutor:ask")) { try await ai.answer(system: "", prompt: "Frage") }
            return (nil, fake, store, gone)
        } catch let e as LocalHTTPError {
            return (e, fake, store, gone)
        } catch {
            XCTFail("\(error)")
            return (nil, fake, store, gone)
        }
    }

    func testServiceErrorsKeepStatusAndCodeWithGermanTextsAndActions() async throws {
        var (e, _, _, _) = await failure(402, ["detail": "Kein Abo", "code": "subscription_required"])
        XCTAssertEqual(e?.status, 402)
        XCTAssertEqual(e?.detail["code"], "subscription_required")
        XCTAssertEqual(e?.detail["detail"]?.string, StudiNowAIText.subscriptionRequired)
        XCTAssertEqual(StudiNowAIText.action(code: "subscription_required"), .plans)

        (e, _, _, _) = await failure(403, ["detail": "Nur Pro AI", "code": "plan_required", "required_plan": "pro_ai"])
        XCTAssertEqual(e?.status, 403)
        XCTAssertEqual(e?.detail["detail"]?.string, StudiNowAIText.planRequired("pro_ai"))
        XCTAssertEqual(e?.detail["required_plan"], "pro_ai", "Zusatzfelder bleiben")
        XCTAssertEqual(StudiNowAIText.planRequired("plus"), "Diese KI-Funktion gibt es ab StudiNow Plus.")
        XCTAssertEqual(StudiNowAIText.action(code: "plan_required"), .plans)

        (e, _, _, _) = await failure(403, ["detail": "Bitte bestätigen", "code": "email_unverified"])
        XCTAssertEqual(e?.detail["detail"]?.string, ServiceErrorText.known(code: "email_unverified"))
        XCTAssertNil(StudiNowAIText.action(code: "email_unverified"))

        // Credits aufgebraucht: Text des Dienstes (nennt den naechsten Monat) und der Stand bleiben
        (e, _, _, _) = await failure(429, ["detail": "Credits für diesen Monat aufgebraucht – am 1. gibt es neue.", "code": "credits_exhausted",
                                           "credits": balance(remaining: 2, charged: nil)])
        XCTAssertEqual(e?.status, 429)
        XCTAssertEqual(e?.detail["detail"], "Credits für diesen Monat aufgebraucht – am 1. gibt es neue.")
        XCTAssertEqual(e?.detail["credits"]?["remaining"], 2)
        XCTAssertEqual(StudiNowAIText.action(code: "credits_exhausted"), .plans)

        (e, _, _, _) = await failure(429, ["detail": "Kontingent", "code": "quota_exhausted"])
        XCTAssertEqual(e?.detail["detail"]?.string, StudiNowAIText.quotaExhausted)
        XCTAssertEqual(StudiNowAIText.action(code: "quota_exhausted"), .plans)

        (e, _, _, _) = await failure(429, ["detail": "Zu viele", "code": "rate_limited"], headers: ["Retry-After": "120"])
        XCTAssertEqual(e?.detail["detail"]?.string, StudiNowAIText.rateLimited + " (in 2 min erneut versuchen)")

        (e, _, _, _) = await failure(503, ["detail": "nicht eingerichtet", "code": "ai_not_configured_prices"])
        XCTAssertEqual(e?.status, 503)
        XCTAssertEqual(e?.detail["detail"]?.string, ServiceErrorText.known(code: "ai_not_configured_prices"))

        (e, _, _, _) = await failure(503, ["detail": "", "code": "ai_unavailable"])
        XCTAssertEqual(e?.detail["detail"]?.string, StudiNowAIText.unavailable)

        (e, _, _, _) = await failure(409, ["detail": "doppelt", "code": "duplicate_request"])
        XCTAssertEqual(e?.detail["detail"]?.string, ServiceErrorText.known(code: "duplicate_request"))
    }

    /// 401: Sitzung beendet -> Token weg, App wird abgemeldet, Text "neu anmelden" mit Knopf zur Anmeldung
    func testExpiredSessionClearsTheTokenAndAsksToSignIn() async throws {
        let (e, _, store, gone) = await failure(401, ["detail": "Anmeldung erforderlich.", "code": "unauthenticated"])
        XCTAssertEqual(e?.status, 401)
        XCTAssertEqual(e?.detail["code"], "account_required")
        XCTAssertEqual(e?.detail["detail"]?.string, StudiNowAIText.sessionExpired)
        XCTAssertNil(store.load(), "Token entfernt")
        XCTAssertEqual(gone.all.count, 1, "App erfaehrt die Abmeldung")
        XCTAssertEqual(StudiNowAIText.action(code: "account_required"), .signIn)
    }

    /// Ohne Token wird nichts gesendet; ohne Netz eine freundliche Meldung statt eines Absturzes
    func testNoTokenSendsNothingAndOfflineIsFriendly() async throws {
        var (e, fake, _, _) = await failure(200, .null, token: nil)
        XCTAssertEqual(e?.status, 401)
        XCTAssertEqual(e?.detail["code"], "account_required")
        XCTAssertEqual(e?.detail["detail"]?.string, StudiNowAIText.accountRequired)
        var n = await fake.requests.count
        XCTAssertEqual(n, 0)

        (e, fake, _, _) = await failure(200, .null, offline: true)
        XCTAssertEqual(e?.status, 503)
        XCTAssertEqual(e?.detail["code"], "service_unreachable")
        XCTAssertEqual(e?.detail["detail"]?.string, StudiNowAIText.unreachable)
        n = await fake.requests.count
        XCTAssertEqual(n, 1)

        // Antwort ohne `answer`: verstaendlicher Fehler
        let (ai, f2, _) = make()
        await f2.on("POST", "/api/ai/relay", 200, ["model": "x"])
        do {
            _ = try await AIRelayTask.run(AIRelayTask("tutor:ask")) { try await ai.answer(system: "", prompt: "p") }
            XCTFail("ohne Antwort")
        } catch let err as LocalHTTPError {
            XCTAssertEqual(err.status, 502)
        }
    }

    /// Fehler kommen ueber das lokale Backend mit Status und Code bei der App an (APIError liest `detail.code`)
    func testBackendPassesTheServiceErrorThrough() async throws {
        let (ai, fake, _) = make()
        await fake.on("POST", "/api/ai/relay", 403, ["detail": ["detail": "x", "code": "plan_required"]])
        let b = try await backend(ai)
        let r = await post(b, "/api/ai/tutor", ["mode": "ask", "page_text": "Seite", "question": "Warum?"])
        XCTAssertEqual(r.status, 403)
        XCTAssertEqual(r.json?["detail"]?["code"], "plan_required")
        XCTAssertEqual(r.json?["detail"]?["detail"]?.string, StudiNowAIText.planRequired(nil))
    }

    // MARK: Weg der KI

    func testOwnChatGPTGoesFirstAndBackgroundNeverUsesCredits() async throws {
        let (ai, _, _) = make()
        let local = LocalAI()
        XCTAssertNil(local.provider)
        local.setService(ai)
        XCTAssertTrue(local.provider is StudiNowAI)
        XCTAssertNil(local.backgroundProvider, "StudiNow-KI nie im Hintergrund")
        let own = FakeAI("eigenes ChatGPT")
        local.set(own)
        XCTAssertTrue(local.provider is FakeAI, "eigenes ChatGPT vor der StudiNow-KI")
        XCTAssertTrue(local.backgroundProvider is FakeAI)
        XCTAssertTrue(local.serviceProvider is StudiNowAI)
        local.set(nil)
        local.setService(nil)
        XCTAssertNil(local.provider)
        XCTAssertTrue(ai.isMetered)
        XCTAssertFalse(own.isMetered)
    }

    func testActivationRules() {
        func d(_ signedIn: Bool, _ local: String, _ service: String? = nil, _ trial: Bool = false, configured: Bool = true) -> StudiNowAIAccess {
            StudiNowAIAccess.decide(serviceConfigured: configured, signedIn: signedIn, localPlan: local, servicePlan: service, serviceTrialActive: trial)
        }
        XCTAssertEqual(d(true, "pro_ai", "pro_ai", configured: false), .unavailable, "ohne Dienst-Adresse nie")
        XCTAssertEqual(d(true, "pro_ai"), .ready, "Pro AI (App Store oder Probe auf dem iPad) und angemeldet")
        XCTAssertEqual(d(true, "free", "pro_ai"), .ready, "Pro AI beim Dienst (Web/Windows gekauft)")
        XCTAssertEqual(d(true, "free", "free", true), .ready, "Probe des Kontos (25 Credits)")
        XCTAssertEqual(d(false, "pro_ai"), .signInRequired, "Pro AI ohne Anmeldung")
        XCTAssertEqual(d(true, "plus", "plus"), .planRequired, "Plus: Tarif-Hinweis")
        XCTAssertEqual(d(false, "plus"), .planRequired)
        XCTAssertEqual(d(false, "free"), .planRequired)
        XCTAssertEqual(d(true, "free", nil), .planRequired, "Stand des Dienstes noch nicht geladen, Free auf dem iPad")
    }

    // MARK: Konto

    func testAppleSignInSendsUniversityEmailAndNonceAndVerifyReportsTheJWS() async throws {
        let fake = FakeService(), store = MemoryTokenStore()
        let acc = StudoraAccount(base: base, http: fake, tokens: store, deviceID: "ipad-test", deviceName: "iPad")
        await fake.on("POST", "/api/account/login/apple", 201, ["user": ["id": "u1", "email": "x@privaterelay.appleid.com", "plan": "free"],
                                                                "token": "neu", "created": true])
        let r = try await acc.loginWithApple(identityToken: "ey.jwt", nonce: "roh", university: "luh", email: "x@privaterelay.appleid.com")
        XCTAssertTrue(r.created)
        XCTAssertEqual(store.load(), "neu", "nur das Sitzungs-Token wird gespeichert")
        var sent = try body(await fake.last("/api/account/login/apple"))
        XCTAssertEqual(sent["identity_token"], "ey.jwt")
        XCTAssertEqual(sent["nonce"], "roh")
        XCTAssertEqual(sent["university"], "luh")
        XCTAssertEqual(sent["email"], "x@privaterelay.appleid.com")
        XCTAssertEqual(sent["device_id"], "ipad-test")

        await fake.on("POST", "/api/billing/apple/verify", 200, ["plan": "pro_ai", "status": "active"])
        let plan = try await acc.verifyApple(signedTransaction: "a.b.c")
        XCTAssertEqual(plan, "pro_ai")
        let lastV = await fake.last("/api/billing/apple/verify")
        let v = try XCTUnwrap(lastV)
        XCTAssertEqual(v.headers["Authorization"], "Bearer neu")
        sent = try body(v)
        XCTAssertEqual(sent["signed_transaction"], "a.b.c")
        XCTAssertNil(sent["signed_renewal"])

        await fake.on("POST", "/api/billing/apple/verify", 409, ["detail": ["detail": "anderes Konto", "code": "subscription_owned_by_other_account"]])
        do {
            try await acc.verifyApple(signedTransaction: "a.b.c", signedRenewal: "d.e.f")
            XCTFail("409")
        } catch let e as AccountError {
            XCTAssertEqual(e.code, "subscription_owned_by_other_account")
            XCTAssertEqual(e.userMessage, ServiceErrorText.known(code: "subscription_owned_by_other_account"))
        }
        let renewalReq = await fake.last("/api/billing/apple/verify")
        XCTAssertEqual(try body(renewalReq)["signed_renewal"], "d.e.f")

        await fake.on("GET", "/api/entitlements", 200, ["plan": "free", "trial": ["active": true, "days_left": 7, "plan": "pro_ai"],
                                                        "apple_account_token": "3F2504E0-4F89-11D3-9A0C-0305E82C3301"])
        let st = try await acc.planStatus()
        XCTAssertTrue(st.trialActive)
        XCTAssertEqual(st.appleAccountToken, "3F2504E0-4F89-11D3-9A0C-0305E82C3301")
    }
}
